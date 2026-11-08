// Package claude drives the user's installed, unmodified `claude` binary over its stream-json
// control protocol (the same stdio protocol the official Agent SDKs use). Auth is whatever `claude`
// is logged in with. Port of AgentKit's ClaudeSession.
package claude

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
	"github.com/arbarlow/domestique/server/internal/agent/lineproc"
	ts "github.com/arbarlow/domestique/server/internal/agent/toolsummary"
	"google.golang.org/protobuf/proto"
)

// Entrypoint is reported to Claude Code as CLAUDE_CODE_ENTRYPOINT.
const Entrypoint = "sdk-go"

var allEfforts = []string{"low", "medium", "high", "xhigh", "max"}

// FallbackModels are offered before the CLI has reported its own list.
func FallbackModels() []*domestiquev1.ModelOption {
	return []*domestiquev1.ModelOption{
		{Id: "default", DisplayName: "Default", Description: "Claude Code's default model", Efforts: slices.Clone(allEfforts), DefaultEffort: "high", IsDefault: true},
		{Id: "opus", DisplayName: "Opus", Efforts: slices.Clone(allEfforts), DefaultEffort: "high"},
		{Id: "sonnet", DisplayName: "Sonnet", Efforts: slices.Clone(allEfforts), DefaultEffort: "high"},
		{Id: "haiku", DisplayName: "Haiku"},
	}
}

// Register adds the Claude factory and model lister to r.
func Register(r *agent.Registry) {
	r.Register(domestiquev1.Provider_PROVIDER_CLAUDE, New, ModelLister)
}

// proc is the subset of *lineproc.Process the session uses (faked in tests).
type proc interface {
	WriteJSON(v any) error
	CloseInput()
	Terminate()
	Running() bool
	Lines() <-chan []byte
	Done() <-chan struct{}
	ExitStatus() int
	StderrTail() string
}

type spawnFunc func(args []string) (proc, error)

type controlResult struct {
	resp ts.JSON
	err  error
}

type pendingPermission struct {
	tool      string
	input     ts.JSON
	toolUseID string
}

type streamBlock struct {
	itemID string
	kind   string
}

type task struct {
	id, toolUseID, description, subagentType, prompt string
	isBackground                                     bool
	status                                           domestiquev1.AgentTaskStatus
	startedAt, endedAt                               time.Time
	toolUses                                         int64
	totalTokens                                      int64
	activity                                         string
	steps                                            []*domestiquev1.AgentTaskStep
	output, summary                                  string
}

func (t *task) proto() *domestiquev1.AgentTask {
	out := &domestiquev1.AgentTask{
		Id: t.id, ToolUseId: t.toolUseID, Description: t.description, SubagentType: t.subagentType,
		Prompt: t.prompt, IsBackground: t.isBackground, Status: t.status, StartedAtMs: t.startedAt.UnixMilli(),
		ToolUses: int32(t.toolUses), TotalTokens: t.totalTokens, Activity: t.activity, Output: t.output,
		Summary: t.summary,
	}
	if !t.endedAt.IsZero() {
		out.EndedAtMs = t.endedAt.UnixMilli()
	}
	for _, s := range t.steps {
		out.Steps = append(out.Steps, &domestiquev1.AgentTaskStep{Name: s.Name, Summary: s.Summary})
	}
	return out
}

// Session is one Claude Code conversation.
type Session struct {
	q     *lineproc.Queue[agent.Event]
	spawn spawnFunc

	mu        sync.Mutex
	cfg       agent.Config
	closed    bool
	proc      proc
	sessionID string

	requestCounter     int
	pendingControl     map[string]chan controlResult
	pendingPermissions map[string]pendingPermission
	approvalItems      map[string]*domestiquev1.TranscriptItem

	// Streaming bookkeeping.
	currentMessageID      string
	streamedBlocks        map[string]map[int64]streamBlock
	streamedTextOrder     map[string][]string
	streamedThinkingOrder map[string][]string
	finalTextCount        map[string]int
	finalThinkingCount    map[string]int
	tools                 map[string]*domestiquev1.TranscriptItem
	toolOrder             []string
	turnRunning           bool
	interruptRequested    bool

	// Subagents.
	tasks         map[string]*task
	taskByToolUse map[string]string
	// Completion notices since the last turn started; they explain the next automatic turn.
	pendingNotices []string

	usage ts.UsageTracker
}

var _ agent.Session = (*Session)(nil)

// New creates a session. The process starts on the first Send.
func New(cfg agent.Config) (agent.Session, error) {
	exe, err := lineproc.LookPath(cfg.Executable, "claude")
	if err != nil {
		return nil, err
	}
	return newSession(cfg, func(args []string) (proc, error) {
		env := map[string]string{}
		for k, v := range cfg.Env {
			env[k] = v
		}
		env["CLAUDE_CODE_ENTRYPOINT"] = Entrypoint
		p, err := lineproc.Start(lineproc.Options{Path: exe, Args: args, Dir: cfg.Cwd, Env: lineproc.Environ(env)})
		if err != nil {
			return nil, err
		}
		return p, nil
	}), nil
}

func newSession(cfg agent.Config, spawn spawnFunc) *Session {
	return &Session{
		q:                     lineproc.NewQueue[agent.Event](),
		spawn:                 spawn,
		cfg:                   cfg,
		sessionID:             cfg.ResumeSessionID,
		pendingControl:        map[string]chan controlResult{},
		pendingPermissions:    map[string]pendingPermission{},
		approvalItems:         map[string]*domestiquev1.TranscriptItem{},
		streamedBlocks:        map[string]map[int64]streamBlock{},
		streamedTextOrder:     map[string][]string{},
		streamedThinkingOrder: map[string][]string{},
		finalTextCount:        map[string]int{},
		finalThinkingCount:    map[string]int{},
		tools:                 map[string]*domestiquev1.TranscriptItem{},
		tasks:                 map[string]*task{},
		taskByToolUse:         map[string]string{},
	}
}

func (s *Session) Provider() domestiquev1.Provider { return domestiquev1.Provider_PROVIDER_CLAUDE }

func (s *Session) Events() <-chan agent.Event { return s.q.Out() }

func (s *Session) emit(e agent.Event) { s.q.Push(e) }

// emitItem emits a copy, so later mutation of our bookkeeping never races with the reader.
func (s *Session) emitItem(item *domestiquev1.TranscriptItem) {
	s.emit(agent.Upsert{Item: proto.Clone(item).(*domestiquev1.TranscriptItem)})
}

func newItem(id string) *domestiquev1.TranscriptItem {
	return &domestiquev1.TranscriptItem{Id: id, TimestampMs: ts.NowMs()}
}

// CLIMode maps a permission mode to Claude's --permission-mode.
func CLIMode(m domestiquev1.PermissionMode) string {
	switch m {
	case domestiquev1.PermissionMode_PERMISSION_MODE_AUTO:
		return "auto"
	case domestiquev1.PermissionMode_PERMISSION_MODE_ASK:
		return "default"
	default:
		return "bypassPermissions"
	}
}

// MARK: lifecycle

func (s *Session) argsLocked() []string {
	args := []string{
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--include-partial-messages",
		"--permission-prompt-tool", "stdio",
		"--permission-mode", CLIMode(s.cfg.Mode),
		// Lets us switch into bypass mid-session without restarting.
		"--allow-dangerously-skip-permissions",
	}
	if s.cfg.Model != "" && s.cfg.Model != "default" {
		args = append(args, "--model", s.cfg.Model)
	}
	if s.cfg.Effort != "" {
		args = append(args, "--effort", s.cfg.Effort)
	}
	if s.sessionID != "" {
		args = append(args, "--resume", s.sessionID)
	}
	if s.cfg.AppendSystemPrompt != "" {
		args = append(args, "--append-system-prompt", s.cfg.AppendSystemPrompt)
	}
	for _, root := range s.cfg.ExtraWritableRoots {
		args = append(args, "--add-dir", root)
	}
	if s.cfg.McpConfigPath != "" {
		args = append(args, "--mcp-config", s.cfg.McpConfigPath)
	}
	return args
}

func (s *Session) ensureProcessLocked() error {
	if s.proc != nil {
		if s.proc.Running() {
			return nil
		}
		// Exited but the reader hasn't reported it yet: clean up now so state is consistent.
		s.cleanupExitLocked(s.proc)
	}
	p, err := s.spawn(s.argsLocked())
	if err != nil {
		return fmt.Errorf("couldn't start claude: %w", err)
	}
	s.proc = p
	go s.readLoop(p)
	// Handshake first. The response carries models, commands, account.
	ch, err := s.writeControlLocked(map[string]any{"subtype": "initialize", "hooks": nil})
	if err == nil {
		go func() {
			select {
			case r := <-ch:
				if r.err == nil {
					s.mu.Lock()
					s.handleInitializeLocked(r.resp)
					s.mu.Unlock()
				}
			case <-time.After(2 * time.Minute):
			}
		}()
	}
	return nil
}

func (s *Session) readLoop(p proc) {
	for line := range p.Lines() {
		msg, err := ts.ParseJSON(line)
		if err != nil {
			continue
		}
		s.mu.Lock()
		if s.proc == p {
			s.handleLocked(msg)
		}
		s.mu.Unlock()
	}
	<-p.Done()
	s.mu.Lock()
	if s.proc == p {
		s.cleanupExitLocked(p)
	}
	s.mu.Unlock()
}

func (s *Session) cleanupExitLocked(p proc) {
	s.proc = nil
	s.failControlsLocked(errors.New("Claude exited"))
	// Sorted, so the cancellations come out in a stable order.
	for _, id := range slices.Sorted(maps.Keys(s.approvalItems)) {
		item := s.approvalItems[id]
		if a := item.GetApproval(); a != nil && a.Resolution == domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING {
			a.Resolution = domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_CANCELLED
			s.emitItem(item)
		}
		delete(s.approvalItems, id)
	}
	clear(s.pendingPermissions)
	s.finishRunningToolsLocked(domestiquev1.ToolStatus_TOOL_STATUS_FAILED)
	if s.turnRunning {
		s.turnRunning = false
		s.emit(agent.TurnEnded{Summary: &domestiquev1.TurnSummary{IsError: true, Message: "Claude exited"}})
	}
	status := p.ExitStatus()
	// SIGINT/SIGTERM on shutdown are expected; only surface real failures.
	expected := status == 0 || status == 130 || status == 143 || status == 2
	msg := ""
	if !expected {
		trimmed := strings.TrimSpace(p.StderrTail())
		if trimmed == "" {
			msg = fmt.Sprintf("claude exited with status %d", status)
		} else {
			msg = suffix(trimmed, 2000)
		}
	}
	s.emit(agent.Exited{Message: msg})
}

func suffix(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[len(r)-n:])
}

func (s *Session) failControlsLocked(err error) {
	for id, ch := range s.pendingControl {
		ch <- controlResult{err: err}
		delete(s.pendingControl, id)
	}
}

// Shutdown stops the process and closes Events().
func (s *Session) Shutdown() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	p := s.proc
	s.proc = nil
	s.failControlsLocked(errors.New("session shut down"))
	s.mu.Unlock()
	if p != nil {
		p.CloseInput()
		p.Terminate()
	}
	s.q.Close()
}

// MARK: public API

func (s *Session) Send(ctx context.Context, text string, attachments []agent.Attachment) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("session is shut down")
	}
	if err := s.ensureProcessLocked(); err != nil {
		return err
	}
	var content []any
	for _, a := range attachments {
		if !strings.HasPrefix(a.MediaType, "image/") {
			continue
		}
		content = append(content, map[string]any{
			"type": "image",
			"source": map[string]any{
				"type": "base64", "media_type": a.MediaType, "data": base64.StdEncoding.EncodeToString(a.Data),
			},
		})
	}
	content = append(content, map[string]any{"type": "text", "text": text})
	msg := map[string]any{
		"type":               "user",
		"message":            map[string]any{"role": "user", "content": content},
		"parent_tool_use_id": nil,
		"session_id":         s.sessionID,
	}
	if !s.turnRunning {
		s.turnRunning = true
		s.emit(agent.TurnStarted{})
	}
	// While a turn runs, Claude Code queues the message and picks it up at the next step.
	return s.proc.WriteJSON(msg)
}

func (s *Session) Interrupt(ctx context.Context) {
	s.mu.Lock()
	if s.proc == nil || !s.turnRunning {
		s.mu.Unlock()
		return
	}
	s.interruptRequested = true
	s.mu.Unlock()
	_, _ = s.control(ctx, map[string]any{"subtype": "interrupt"})
}

func (s *Session) Respond(ctx context.Context, requestID string, d agent.Decision) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pending, ok := s.pendingPermissions[requestID]
	if !ok {
		return
	}
	delete(s.pendingPermissions, requestID)
	input := pending.input.Raw()
	if input == nil {
		input = map[string]any{}
	}
	var response map[string]any
	var resolution domestiquev1.ApprovalResolution
	switch d.Kind {
	case domestiquev1.Decision_DECISION_APPROVE:
		response = map[string]any{"behavior": "allow", "updatedInput": input}
		resolution = domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_APPROVED
	case domestiquev1.Decision_DECISION_APPROVE_FOR_SESSION:
		response = map[string]any{
			"behavior": "allow", "updatedInput": input,
			"updatedPermissions": []any{map[string]any{
				"type": "addRules", "behavior": "allow", "destination": "session",
				"rules": []any{map[string]any{"toolName": pending.tool}},
			}},
		}
		resolution = domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_APPROVED_FOR_SESSION
	default:
		msg := d.Message
		if msg == "" {
			msg = "The user denied this action."
		}
		response = map[string]any{"behavior": "deny", "message": msg}
		resolution = domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_DENIED
	}
	if pending.toolUseID != "" {
		response["toolUseID"] = pending.toolUseID
	}
	s.writeControlResponseLocked(requestID, response)
	s.resolveApprovalLocked(requestID, resolution, nil)
}

func (s *Session) Answer(ctx context.Context, requestID string, answers map[string]string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pending, ok := s.pendingPermissions[requestID]
	if !ok {
		return
	}
	delete(s.pendingPermissions, requestID)
	// AskUserQuestion: answers are keyed by question text.
	input := map[string]any{}
	for k, v := range pending.input.RawObj() {
		input[k] = v
	}
	byQuestion := map[string]any{}
	if item := s.approvalItems[requestID]; item != nil {
		for _, q := range item.GetApproval().GetQuestions() {
			if a, ok := answers[q.Id]; ok {
				byQuestion[q.Question] = a
			}
		}
	}
	input["answers"] = byQuestion
	s.writeControlResponseLocked(requestID, map[string]any{"behavior": "allow", "updatedInput": input})
	s.resolveApprovalLocked(requestID, domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_ANSWERED, answers)
}

func (s *Session) SetPermissionMode(ctx context.Context, mode domestiquev1.PermissionMode) {
	s.mu.Lock()
	s.cfg.Mode = mode
	running := s.proc != nil
	s.mu.Unlock()
	if running {
		_, _ = s.control(ctx, map[string]any{"subtype": "set_permission_mode", "mode": CLIMode(mode)})
	}
}

func (s *Session) SetModel(ctx context.Context, model string) {
	s.mu.Lock()
	s.cfg.Model = model
	running := s.proc != nil
	s.mu.Unlock()
	if running {
		var value any
		if model != "" && model != "default" {
			value = model
		}
		_, _ = s.control(ctx, map[string]any{"subtype": "set_model", "model": value})
	}
}

func (s *Session) SetEffort(ctx context.Context, effort string) {
	s.mu.Lock()
	s.cfg.Effort = effort
	running := s.proc != nil
	s.mu.Unlock()
	if running {
		var value any
		if effort != "" {
			value = effort
		}
		_, _ = s.control(ctx, map[string]any{"subtype": "apply_flag_settings", "settings": map[string]any{"effortLevel": value}})
	}
}

// MARK: control protocol

func (s *Session) writeControlLocked(request map[string]any) (chan controlResult, error) {
	if s.proc == nil {
		return nil, errors.New("Claude isn't running")
	}
	s.requestCounter++
	id := fmt.Sprintf("dq_%d", s.requestCounter)
	ch := make(chan controlResult, 1)
	s.pendingControl[id] = ch
	if err := s.proc.WriteJSON(map[string]any{"type": "control_request", "request_id": id, "request": request}); err != nil {
		delete(s.pendingControl, id)
		return nil, err
	}
	return ch, nil
}

func (s *Session) control(ctx context.Context, request map[string]any) (ts.JSON, error) {
	s.mu.Lock()
	ch, err := s.writeControlLocked(request)
	s.mu.Unlock()
	if err != nil {
		return ts.JSON{}, err
	}
	select {
	case r := <-ch:
		return r.resp, r.err
	case <-ctx.Done():
		return ts.JSON{}, ctx.Err()
	}
}

func (s *Session) writeControlResponseLocked(requestID string, response map[string]any) {
	if s.proc == nil {
		return
	}
	_ = s.proc.WriteJSON(map[string]any{
		"type":     "control_response",
		"response": map[string]any{"subtype": "success", "request_id": requestID, "response": response},
	})
}

func (s *Session) writeControlErrorLocked(requestID, message string) {
	if s.proc == nil {
		return
	}
	_ = s.proc.WriteJSON(map[string]any{
		"type":     "control_response",
		"response": map[string]any{"subtype": "error", "request_id": requestID, "error": message},
	})
}

func (s *Session) handleInitializeLocked(resp ts.JSON) {
	if s.closed {
		return
	}
	if options := ParseModels(resp); len(options) > 0 {
		s.emit(agent.Models{Models: options})
	}
}

// MARK: inbound

func (s *Session) handleLocked(msg ts.JSON) {
	switch msg.Get("type").S() {
	case "system":
		s.handleSystemLocked(msg)
	case "stream_event":
		s.handleStreamEventLocked(msg)
	case "assistant":
		s.handleAssistantLocked(msg)
	case "user":
		s.handleUserLocked(msg)
	case "result":
		s.handleResultLocked(msg)
	case "control_request":
		s.handleControlRequestLocked(msg)
	case "control_response":
		s.handleControlResponseLocked(msg)
	case "rate_limit_event":
		if info, ok := RateLimit(msg.Get("rate_limit_info")); ok {
			s.emit(agent.RateLimit{Info: s.usage.Merge(info, time.Now())})
		}
	case "control_cancel_request":
		if id, ok := msg.Get("request_id").Str(); ok {
			delete(s.pendingPermissions, id)
			s.resolveApprovalLocked(id, domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_CANCELLED, nil)
		}
	}
}

func (s *Session) handleSystemLocked(msg ts.JSON) {
	switch msg.Get("subtype").S() {
	case "init":
		if sid, ok := msg.Get("session_id").Str(); ok {
			s.sessionID = sid
			s.emit(agent.Started{SessionID: sid, Model: msg.Get("model").S()})
		}
	case "api_retry":
		attempt, _ := msg.Get("attempt").Int()
		maxRetries, _ := msg.Get("max_retries").Int()
		e, ok := msg.Get("error").Str()
		if !ok {
			e = "error"
		}
		s.emit(agent.Status{Text: fmt.Sprintf("API %s — retrying (%d/%d)", strings.ReplaceAll(e, "_", " "), attempt, maxRetries)})
	case "status":
		if msg.Get("status").S() == "compacting" {
			s.emit(agent.Status{Text: "Compacting context…"})
		} else {
			s.emit(agent.Status{})
		}
	case "task_started", "task_progress", "task_updated", "task_notification":
		s.handleTaskLocked(msg)
	case "compact_boundary":
		item := newItem("compact-" + ts.UUID())
		item.Kind = &domestiquev1.TranscriptItem_Notice{Notice: "Context compacted"}
		s.emit(agent.Upsert{Item: item})
	}
}

func (s *Session) handleStreamEventLocked(msg ts.JSON) {
	event := msg.Get("event")
	if !msg.Get("parent_tool_use_id").NullOrMissing() || !event.Exists() {
		return
	}
	switch event.Get("type").S() {
	case "message_start":
		s.currentMessageID = event.Path("message", "id").S()
		s.beginAutoTurnIfIdleLocked()
		s.emit(agent.Status{})
	case "content_block_start":
		mid := s.currentMessageID
		index, ok := event.Get("index").Int()
		typ, ok2 := event.Path("content_block", "type").Str()
		if mid == "" || !ok || !ok2 {
			return
		}
		itemID := fmt.Sprintf("%s-%d", mid, index)
		if s.streamedBlocks[mid] == nil {
			s.streamedBlocks[mid] = map[int64]streamBlock{}
		}
		switch typ {
		case "text":
			s.streamedBlocks[mid][index] = streamBlock{itemID, "text"}
			s.streamedTextOrder[mid] = append(s.streamedTextOrder[mid], itemID)
			item := newItem(itemID)
			item.Kind = &domestiquev1.TranscriptItem_Assistant{}
			s.emit(agent.Upsert{Item: item})
		case "thinking":
			s.streamedBlocks[mid][index] = streamBlock{itemID, "thinking"}
			s.streamedThinkingOrder[mid] = append(s.streamedThinkingOrder[mid], itemID)
			item := newItem(itemID)
			item.Kind = &domestiquev1.TranscriptItem_Reasoning{}
			s.emit(agent.Upsert{Item: item})
		}
	case "content_block_delta":
		mid := s.currentMessageID
		index, ok := event.Get("index").Int()
		if mid == "" || !ok {
			return
		}
		block, ok := s.streamedBlocks[mid][index]
		delta := event.Get("delta")
		if !ok || !delta.Exists() {
			return
		}
		switch delta.Get("type").S() {
		case "text_delta":
			if t, ok := delta.Get("text").Str(); ok {
				s.emit(agent.AppendText{ItemID: block.itemID, Delta: t})
			}
		case "thinking_delta":
			if t, ok := delta.Get("thinking").Str(); ok {
				s.emit(agent.AppendText{ItemID: block.itemID, Delta: t})
			}
		}
	}
}

func (s *Session) handleAssistantLocked(msg ts.JSON) {
	if parent, ok := msg.Get("parent_tool_use_id").Str(); ok {
		s.handleSubagentMessageLocked(msg, parent)
		return
	}
	s.beginAutoTurnIfIdleLocked()
	message := msg.Get("message")
	mid, ok := message.Get("id").Str()
	if !ok {
		mid = ts.UUID()
	}
	for _, block := range message.Get("content").Arr() {
		switch block.Get("type").S() {
		case "text":
			k := s.finalTextCount[mid]
			s.finalTextCount[mid] = k + 1
			id := fmt.Sprintf("%s-t%d", mid, k)
			if order := s.streamedTextOrder[mid]; k < len(order) {
				id = order[k]
			}
			item := newItem(id)
			item.Kind = &domestiquev1.TranscriptItem_Assistant{Assistant: block.Get("text").S()}
			s.emit(agent.Upsert{Item: item})
		case "thinking":
			text := block.Get("thinking").S()
			k := s.finalThinkingCount[mid]
			s.finalThinkingCount[mid] = k + 1
			id := fmt.Sprintf("%s-r%d", mid, k)
			if order := s.streamedThinkingOrder[mid]; k < len(order) {
				id = order[k]
			}
			if text != "" {
				item := newItem(id)
				item.Kind = &domestiquev1.TranscriptItem_Reasoning{Reasoning: text}
				s.emit(agent.Upsert{Item: item})
			}
		case "tool_use":
			id, ok := block.Get("id").Str()
			if !ok {
				continue
			}
			name, ok := block.Get("name").Str()
			if !ok {
				name = "Tool"
			}
			input := block.Get("input")
			if !input.Exists() {
				input = ts.Of(map[string]any{})
			}
			item := newItem(id)
			item.Kind = &domestiquev1.TranscriptItem_Tool{Tool: ts.ClaudeTool(name, input)}
			if _, seen := s.tools[id]; !seen {
				s.toolOrder = append(s.toolOrder, id)
			}
			s.tools[id] = item
			s.emitItem(item)
		}
	}
}

// MARK: subagents

// beginAutoTurnIfIdleLocked: Claude continued without a user message (a background agent
// finished, a wakeup fired…).
func (s *Session) beginAutoTurnIfIdleLocked() {
	if s.turnRunning {
		return
	}
	s.turnRunning = true
	// Claude Code answers each completion notice with its own turn, in order.
	reason := "Continuing in the background"
	if len(s.pendingNotices) > 0 {
		reason = s.pendingNotices[0]
		s.pendingNotices = s.pendingNotices[1:]
	}
	s.emit(agent.AutoTurnStarted{Reason: reason})
}

func (s *Session) handleTaskLocked(msg ts.JSON) {
	id, ok := msg.Get("task_id").Str()
	if !ok {
		return
	}
	t := s.tasks[id]
	if t == nil {
		desc, ok := msg.Get("description").Str()
		if !ok {
			desc = "Agent"
		}
		t = &task{id: id, description: desc, status: domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_RUNNING, startedAt: time.Now()}
	}
	if tool, ok := msg.Get("tool_use_id").Str(); ok {
		t.toolUseID = tool
		s.taskByToolUse[tool] = id
	}
	if usage := msg.Get("usage"); usage.Exists() {
		if n, ok := usage.Get("tool_uses").Int(); ok {
			t.toolUses = n
		}
		if n, ok := usage.Get("total_tokens").Int(); ok {
			t.totalTokens = n
		}
	}
	switch msg.Get("subtype").S() {
	case "task_started":
		if d, ok := msg.Get("description").Str(); ok {
			t.description = d
		}
		t.subagentType = msg.Get("subagent_type").S()
		if p, ok := msg.Get("prompt").Str(); ok {
			t.prompt = p
		}
		t.isBackground, _ = msg.Get("is_backgrounded").Bool()
		t.startedAt = time.Now()
	case "task_progress":
		if d, ok := msg.Get("description").Str(); ok {
			t.activity = d
		}
		if sum, ok := msg.Get("summary").Str(); ok {
			t.summary = sum
		}
	case "task_updated":
		if st, ok := msg.Path("patch", "status").Str(); ok {
			applyStatus(st, t)
		}
		if bg, ok := msg.Path("patch", "is_backgrounded").Bool(); ok {
			t.isBackground = bg
		}
	case "task_notification":
		st, ok := msg.Get("status").Str()
		if !ok {
			st = "completed"
		}
		applyStatus(st, t)
		if sum := msg.Get("summary").S(); sum != "" {
			t.summary = sum
		}
		verb := "stopped"
		switch t.status {
		case domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_COMPLETED:
			verb = "finished"
		case domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_FAILED:
			verb = "failed"
		}
		s.pendingNotices = append(s.pendingNotices, "Agent “"+t.description+"” "+verb)
	}
	s.tasks[id] = t
	s.emit(agent.Task{Task: t.proto()})
}

func applyStatus(status string, t *task) {
	switch status {
	case "completed":
		t.status = domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_COMPLETED
	case "failed":
		t.status = domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_FAILED
	case "stopped", "killed":
		t.status = domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_STOPPED
	default:
		t.status = domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_RUNNING
	}
	if t.status != domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_RUNNING && t.endedAt.IsZero() {
		t.endedAt = time.Now()
	}
}

const maxTaskSteps = 40

// handleSubagentMessageLocked: messages a subagent produced (tool calls, text) arrive tagged with
// its Agent tool call id.
func (s *Session) handleSubagentMessageLocked(msg ts.JSON, parentToolUseID string) {
	taskID, ok := s.taskByToolUse[parentToolUseID]
	if !ok {
		return
	}
	t := s.tasks[taskID]
	if t == nil {
		return
	}
	for _, block := range msg.Path("message", "content").Arr() {
		switch block.Get("type").S() {
		case "tool_use":
			name, ok := block.Get("name").Str()
			if !ok {
				name = "Tool"
			}
			input := block.Get("input")
			if !input.Exists() {
				input = ts.Of(map[string]any{})
			}
			call := ts.ClaudeTool(name, input)
			t.steps = append(t.steps, &domestiquev1.AgentTaskStep{Name: call.Name, Summary: call.Summary})
			if len(t.steps) > maxTaskSteps {
				t.steps = slices.Clone(t.steps[len(t.steps)-maxTaskSteps:])
			}
		case "text":
			if text := block.Get("text").S(); text != "" {
				t.output = text
			}
		}
	}
	s.emit(agent.Task{Task: t.proto()})
}

func (s *Session) handleUserLocked(msg ts.JSON) {
	if !msg.Get("parent_tool_use_id").NullOrMissing() {
		return
	}
	for _, block := range msg.Path("message", "content").Arr() {
		if block.Get("type").S() != "tool_result" {
			continue
		}
		toolID, _ := block.Get("tool_use_id").Str()
		item := s.tools[toolID]
		call := item.GetTool()
		if call == nil {
			continue
		}
		call.Output = ts.FlattenToolResult(block.Get("content"))
		call.Status = domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED
		if isErr, _ := block.Get("is_error").Bool(); isErr {
			call.Status = domestiquev1.ToolStatus_TOOL_STATUS_FAILED
		}
		if structured := msg.Get("tool_use_result"); structured.Exists() {
			if changes := ts.ClaudeFileChanges(call.Name, call.Input, structured); len(changes) > 0 {
				call.FileChanges = changes
			}
		}
		s.emitItem(item)
	}
}

func (s *Session) handleResultLocked(msg ts.JSON) {
	s.finishRunningToolsLocked(domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED)
	subtype, hasSubtype := msg.Get("subtype").Str()
	success := hasSubtype && subtype == "success"
	interrupted := s.interruptRequested && !success
	s.interruptRequested = false
	isError := !success
	if b, ok := msg.Get("is_error").Bool(); ok {
		isError = b
	}
	isError = !interrupted && isError
	usage := msg.Get("usage")
	in := func(k string) int64 { n, _ := usage.Get(k).Int(); return n }
	input := in("input_tokens") + in("cache_read_input_tokens") + in("cache_creation_input_tokens")
	summary := &domestiquev1.TurnSummary{InputTokens: proto.Int64(input), IsError: isError}
	if n, ok := msg.Get("duration_ms").Int(); ok {
		summary.DurationMs = proto.Int64(n)
	}
	if c, ok := msg.Get("total_cost_usd").Float(); ok {
		summary.CostUsd = proto.Float64(c)
	}
	if n, ok := usage.Get("output_tokens").Int(); ok {
		summary.OutputTokens = proto.Int64(n)
	}
	switch {
	case interrupted:
		summary.Message = "Interrupted"
	case isError:
		if r, ok := msg.Get("result").Str(); ok {
			summary.Message = r
		} else {
			summary.Message = subtype
		}
	}
	s.turnRunning = false
	s.emit(agent.Status{})
	s.emit(agent.TurnEnded{Summary: summary})
}

func (s *Session) finishRunningToolsLocked(status domestiquev1.ToolStatus) {
	for _, id := range s.toolOrder {
		item := s.tools[id]
		call := item.GetTool()
		if call == nil || call.Status != domestiquev1.ToolStatus_TOOL_STATUS_RUNNING {
			continue
		}
		call.Status = status
		s.emitItem(item)
	}
}

func (s *Session) handleControlResponseLocked(msg ts.JSON) {
	resp := msg.Get("response")
	id, ok := resp.Get("request_id").Str()
	if !ok {
		return
	}
	ch, ok := s.pendingControl[id]
	if !ok {
		return
	}
	delete(s.pendingControl, id)
	if resp.Get("subtype").S() == "error" {
		e, ok := resp.Get("error").Str()
		if !ok {
			e = "control request failed"
		}
		ch <- controlResult{err: errors.New(e)}
		return
	}
	r := resp.Get("response")
	if !r.Exists() {
		r = ts.Of(nil)
	}
	ch <- controlResult{resp: r}
}

var ansiRE = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]")

// StripANSI removes terminal escape sequences.
func StripANSI(s string) string { return ansiRE.ReplaceAllString(s, "") }

func (s *Session) handleControlRequestLocked(msg ts.JSON) {
	requestID, ok := msg.Get("request_id").Str()
	req := msg.Get("request")
	if !ok || !req.Exists() {
		return
	}
	switch req.Get("subtype").S() {
	case "can_use_tool":
		tool, ok := req.Get("tool_name").Str()
		if !ok {
			tool = "Tool"
		}
		input := req.Get("input")
		if !input.Exists() {
			input = ts.Of(map[string]any{})
		}
		s.pendingPermissions[requestID] = pendingPermission{tool: tool, input: input, toolUseID: req.Get("tool_use_id").S()}
		approval := &domestiquev1.ApprovalRequest{RequestId: requestID, Resolution: domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING}
		if tool == "AskUserQuestion" {
			approval.Title = "Claude has a question"
			for i, q := range input.Get("questions").Arr() {
				aq := &domestiquev1.AgentQuestion{
					Id: fmt.Sprintf("q%d", i), Header: q.Get("header").S(), Question: q.Get("question").S(),
				}
				aq.MultiSelect, _ = q.Get("multiSelect").Bool()
				for _, o := range q.Get("options").Arr() {
					aq.Options = append(aq.Options, &domestiquev1.QuestionOption{Label: o.Get("label").S(), Description: o.Get("description").S()})
				}
				approval.Questions = append(approval.Questions, aq)
			}
		} else {
			call := ts.ClaudeTool(tool, input)
			detail := call.Summary
			if reason := req.Get("decision_reason").S(); reason != "" {
				detail += "\n\n" + StripANSI(reason)
			}
			approval.Detail = detail
			if t, ok := req.Get("title").Str(); ok {
				approval.Title = t
			} else {
				name, ok := req.Get("display_name").Str()
				if !ok {
					name = tool
				}
				approval.Title = "Allow " + name + "?"
			}
		}
		item := newItem("approval-" + requestID)
		item.Kind = &domestiquev1.TranscriptItem_Approval{Approval: approval}
		s.approvalItems[requestID] = item
		s.emitItem(item)
	default:
		// Hook callbacks, MCP messages, elicitation, dialogs: not supported yet. Answer so nothing hangs.
		s.writeControlErrorLocked(requestID, "Not supported by this client")
	}
}

func (s *Session) resolveApprovalLocked(requestID string, resolution domestiquev1.ApprovalResolution, answers map[string]string) {
	item, ok := s.approvalItems[requestID]
	if !ok {
		return
	}
	delete(s.approvalItems, requestID)
	a := item.GetApproval()
	if a == nil {
		return
	}
	a.Resolution = resolution
	a.Answers = nil
	if len(answers) > 0 {
		a.Answers = map[string]string{}
		for k, v := range answers {
			a.Answers[k] = v
		}
	}
	s.emitItem(item)
}

// RateLimit parses every unified window from a rate_limit_event's rate_limit_info.
func RateLimit(info ts.JSON) (ts.RateLimitInfo, bool) {
	if !info.Exists() {
		return ts.RateLimitInfo{}, false
	}
	var windows []ts.RateLimitWindow
	for key, w := range info.Get("unifiedWindows").Obj() {
		used, ok := w.Get("utilization").Float()
		if !ok {
			continue
		}
		windows = append(windows, ts.RateLimitWindow{
			ID: key, Label: ts.WindowLabelKey(key), Duration: ts.DurationKey(key), UsedFraction: used,
			ResetsAt: ts.UnixSeconds(w.Get("resetsAt")), Status: w.Get("status").S(),
		})
	}
	if len(windows) == 0 {
		return ts.RateLimitInfo{}, false
	}
	ts.SortWindows(windows)
	out := ts.RateLimitInfo{
		Windows:               windows,
		OverageStatus:         info.Get("overageStatus").S(),
		OverageDisabledReason: info.Get("overageDisabledReason").S(),
	}
	out.UsingOverage, _ = info.Get("isUsingOverage").Bool()
	return out, true
}

package codex

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/agent"
	"github.com/arbarlow/domestique/teamcar/internal/agent/lineproc"
	ts "github.com/arbarlow/domestique/teamcar/internal/agent/toolsummary"
	"google.golang.org/protobuf/proto"
)

// Register adds the Codex factory and model lister to r.
func Register(r *agent.Registry) {
	r.Register(radiov1.Provider_PROVIDER_CODEX, New, ModelLister)
}

// ModelLister lists models via the shared app-server for `codex` on PATH.
func ModelLister(ctx context.Context) ([]*radiov1.ModelOption, error) {
	exe, err := lineproc.LookPath("", "codex")
	if err != nil {
		return nil, err
	}
	return serverFor(exe).ListModels(ctx)
}

// MARK: policy mapping

// ApprovalPolicy maps a permission mode to Codex's approvalPolicy.
func ApprovalPolicy(m radiov1.PermissionMode) string {
	if isBypass(m) {
		return "never"
	}
	return "on-request"
}

// SandboxMode maps a permission mode to thread/start's sandbox.
func SandboxMode(m radiov1.PermissionMode) string {
	if isBypass(m) {
		return "danger-full-access"
	}
	return "workspace-write"
}

// Reviewer maps a permission mode to approvalsReviewer.
func Reviewer(m radiov1.PermissionMode) string {
	if m == radiov1.PermissionMode_PERMISSION_MODE_AUTO {
		return "auto_review"
	}
	return "user"
}

func isBypass(m radiov1.PermissionMode) bool {
	return m != radiov1.PermissionMode_PERMISSION_MODE_AUTO && m != radiov1.PermissionMode_PERMISSION_MODE_ASK
}

// SandboxPolicy is turn/start's sandboxPolicy.
func SandboxPolicy(cfg agent.Config) map[string]any {
	if isBypass(cfg.Mode) {
		return map[string]any{"type": "dangerFullAccess"}
	}
	roots := []any{cfg.Cwd}
	for _, r := range cfg.ExtraWritableRoots {
		roots = append(roots, r)
	}
	return map[string]any{
		"type":                "workspaceWrite",
		"writableRoots":       roots,
		"networkAccess":       true,
		"excludeTmpdirEnvVar": false,
		"excludeSlashTmp":     false,
	}
}

type replyKind int

const (
	replyDecision replyKind = iota
	replyAnswers
	replyCancelled
)

type reply struct {
	kind     replyKind
	decision agent.Decision
	answers  map[string]string
}

type pendingApproval struct {
	method string
	item   *radiov1.TranscriptItem
	reply  chan reply
}

// Session is one Codex thread on the shared app-server.
type Session struct {
	q      *lineproc.Queue[agent.Event]
	server *AppServer

	// sendMu serialises Send so thread creation and turn/start vs turn/steer can't race.
	sendMu sync.Mutex

	mu                sync.Mutex
	cfg               agent.Config
	closed            bool
	threadID          string
	attached          bool
	turnID            string
	lastCompletedTurn string
	hasUsage          bool
	usageIn, usageOut int64
	approvalCounter   int
	pending           map[string]*pendingApproval
}

var _ agent.Session = (*Session)(nil)

// New creates a session on the shared app-server for the configured binary.
func New(cfg agent.Config) (agent.Session, error) {
	exe, err := lineproc.LookPath(cfg.Executable, "codex")
	if err != nil {
		return nil, err
	}
	return newSession(cfg, serverFor(exe)), nil
}

func newSession(cfg agent.Config, server *AppServer) *Session {
	return &Session{
		q:        lineproc.NewQueue[agent.Event](),
		server:   server,
		cfg:      cfg,
		threadID: cfg.ResumeSessionID,
		pending:  map[string]*pendingApproval{},
	}
}

func (s *Session) Provider() radiov1.Provider { return radiov1.Provider_PROVIDER_CODEX }

func (s *Session) Events() <-chan agent.Event { return s.q.Out() }

func (s *Session) emit(e agent.Event) { s.q.Push(e) }

func (s *Session) emitItem(item *radiov1.TranscriptItem) {
	s.emit(agent.Upsert{Item: proto.Clone(item).(*radiov1.TranscriptItem)})
}

func notice(prefix, text string) *radiov1.TranscriptItem {
	return &radiov1.TranscriptItem{
		Id: prefix + "-" + ts.UUID(), TimestampMs: ts.NowMs(), Kind: &radiov1.TranscriptItem_Notice{Notice: text},
	}
}

// MARK: thread

func (s *Session) ensureThread(ctx context.Context) (string, error) {
	s.mu.Lock()
	if s.threadID != "" && s.attached {
		id := s.threadID
		s.mu.Unlock()
		return id, nil
	}
	cfg := s.cfg
	resume := s.threadID
	s.mu.Unlock()

	params := map[string]any{
		"cwd":               cfg.Cwd,
		"approvalPolicy":    ApprovalPolicy(cfg.Mode),
		"approvalsReviewer": Reviewer(cfg.Mode),
		"sandbox":           SandboxMode(cfg.Mode),
	}
	if cfg.Model != "" {
		params["model"] = cfg.Model
	}
	if cfg.AppendSystemPrompt != "" {
		params["developerInstructions"] = cfg.AppendSystemPrompt
	}

	var result ts.JSON
	var err error
	if resume != "" {
		params["threadId"] = resume
		params["excludeTurns"] = true
		result, err = s.server.request(ctx, "thread/resume", params)
		if err != nil {
			if ctx.Err() != nil {
				return "", err
			}
			// Thread vanished (e.g. archived): start fresh rather than wedging the tab.
			delete(params, "threadId")
			delete(params, "excludeTurns")
			s.emit(agent.Upsert{Item: notice("notice", "Couldn't resume previous Codex thread; starting a new one.")})
			result, err = s.server.request(ctx, "thread/start", params)
		}
	} else {
		result, err = s.server.request(ctx, "thread/start", params)
	}
	if err != nil {
		return "", err
	}
	id, ok := result.Path("thread", "id").Str()
	if !ok {
		return "", errors.New("Codex didn't return a thread id")
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return "", errors.New("session is shut down")
	}
	s.threadID = id
	s.attached = true
	s.mu.Unlock()
	s.server.register(id, s)
	model, ok := result.Get("model").Str()
	if !ok {
		model = result.Path("thread", "model").S()
	}
	s.emit(agent.Started{SessionID: id, Model: model})
	return id, nil
}

// MARK: agent.Session

func (s *Session) Send(ctx context.Context, text string, attachments []agent.Attachment) error {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return errors.New("session is shut down")
	}
	tid, err := s.ensureThread(ctx)
	if err != nil {
		return err
	}
	input := []any{map[string]any{"type": "text", "text": text, "text_elements": []any{}}}
	for _, a := range attachments {
		if !strings.HasPrefix(a.MediaType, "image/") {
			continue
		}
		path := filepath.Join(os.TempDir(), "dq-"+ts.UUID()+"-"+filepath.Base(a.Filename))
		if err := os.WriteFile(path, a.Data, 0o600); err == nil {
			input = append(input, map[string]any{"type": "localImage", "path": path})
		}
	}

	s.mu.Lock()
	turnID := s.turnID
	cfg := s.cfg
	s.mu.Unlock()
	if turnID != "" {
		_, err := s.server.request(ctx, "turn/steer", map[string]any{"threadId": tid, "expectedTurnId": turnID, "input": input})
		if err == nil {
			return nil
		}
		var rpcErr *RPCError
		if !errors.As(err, &rpcErr) {
			return err
		}
		// The turn finished while we were steering: start a new one with this message instead.
		s.mu.Lock()
		if s.turnID == turnID {
			s.turnID = ""
		}
		s.mu.Unlock()
	}
	params := map[string]any{
		"threadId":          tid,
		"input":             input,
		"approvalPolicy":    ApprovalPolicy(cfg.Mode),
		"approvalsReviewer": Reviewer(cfg.Mode),
		"sandboxPolicy":     SandboxPolicy(cfg),
	}
	if cfg.Model != "" {
		params["model"] = cfg.Model
	}
	if cfg.Effort != "" {
		params["effort"] = cfg.Effort
	}
	s.emit(agent.TurnStarted{})
	result, err := s.server.request(ctx, "turn/start", params)
	if err != nil {
		s.emit(agent.TurnEnded{Summary: &radiov1.TurnSummary{IsError: true, Message: err.Error()}})
		return err
	}
	if id, ok := result.Path("turn", "id").Str(); ok {
		s.mu.Lock()
		if id != s.lastCompletedTurn {
			s.turnID = id
		}
		s.mu.Unlock()
	}
	return nil
}

func (s *Session) Interrupt(ctx context.Context) {
	s.mu.Lock()
	tid, turnID := s.threadID, s.turnID
	s.mu.Unlock()
	if tid == "" || turnID == "" {
		return
	}
	_, _ = s.server.request(ctx, "turn/interrupt", map[string]any{"threadId": tid, "turnId": turnID})
}

func (s *Session) deliver(requestID string, r reply) {
	s.mu.Lock()
	p := s.pending[requestID]
	delete(s.pending, requestID)
	s.mu.Unlock()
	if p != nil {
		p.reply <- r
	}
}

func (s *Session) Respond(ctx context.Context, requestID string, d agent.Decision) {
	s.deliver(requestID, reply{kind: replyDecision, decision: d})
}

func (s *Session) Answer(ctx context.Context, requestID string, answers map[string]string) {
	s.deliver(requestID, reply{kind: replyAnswers, answers: answers})
}

// SetPermissionMode applies on the next turn/start.
func (s *Session) SetPermissionMode(ctx context.Context, mode radiov1.PermissionMode) {
	s.mu.Lock()
	s.cfg.Mode = mode
	s.mu.Unlock()
}

// SetModel applies on the next turn/start.
func (s *Session) SetModel(ctx context.Context, model string) {
	s.mu.Lock()
	s.cfg.Model = model
	s.mu.Unlock()
}

// SetEffort applies on the next turn/start.
func (s *Session) SetEffort(ctx context.Context, effort string) {
	s.mu.Lock()
	s.cfg.Effort = effort
	s.mu.Unlock()
}

// Shutdown detaches from the shared app-server (which keeps running) and closes Events().
func (s *Session) Shutdown() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	tid := s.threadID
	attached := s.attached
	s.attached = false
	pending := s.pending
	s.pending = map[string]*pendingApproval{}
	s.mu.Unlock()
	for _, p := range pending {
		p.reply <- reply{kind: replyDecision, decision: agent.Decision{Kind: radiov1.Decision_DECISION_DENY}}
	}
	if tid != "" && attached {
		s.server.unregister(tid, s)
		if s.server.running() {
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				_, _ = s.server.rawRequest(ctx, "thread/unsubscribe", map[string]any{"threadId": tid})
			}()
		}
	}
	s.q.Close()
}

// MARK: notifications

func (s *Session) rateLimit(rl *radiov1.RateLimit) { s.emit(agent.RateLimit{Info: rl}) }

func (s *Session) handleNotification(method string, params ts.JSON) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch method {
	case "turn/started":
		if id, ok := params.Path("turn", "id").Str(); ok && id != s.lastCompletedTurn {
			s.turnID = id
		}
	case "turn/completed":
		turn := params.Get("turn")
		if id, ok := turn.Get("id").Str(); ok {
			s.lastCompletedTurn = id
		}
		s.turnID = ""
		errorMessage, hasError := turn.Path("error", "message").Str()
		status := turn.Get("status").S()
		summary := &radiov1.TurnSummary{IsError: hasError || status == "failed"}
		if n, ok := turn.Get("durationMs").Int(); ok {
			summary.DurationMs = proto.Int64(n)
		}
		if s.hasUsage {
			summary.InputTokens = proto.Int64(s.usageIn)
			summary.OutputTokens = proto.Int64(s.usageOut)
		}
		if hasError {
			summary.Message = errorMessage
		} else if status == "interrupted" {
			summary.Message = "Interrupted"
		}
		s.emit(agent.Status{})
		s.emit(agent.TurnEnded{Summary: summary})
	case "item/started", "item/completed":
		if item := ts.CodexItem(params.Get("item")); item != nil {
			s.emit(agent.Upsert{Item: item})
		}
	case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta", "item/plan/delta":
		id, ok1 := params.Get("itemId").Str()
		delta, ok2 := params.Get("delta").Str()
		if ok1 && ok2 {
			s.emit(agent.AppendText{ItemID: id, Delta: delta})
		}
	case "item/reasoning/summaryPartAdded":
		if id, ok := params.Get("itemId").Str(); ok {
			s.emit(agent.AppendText{ItemID: id, Delta: "\n\n"})
		}
	case "thread/tokenUsage/updated":
		if last := params.Path("tokenUsage", "last"); last.Exists() {
			s.hasUsage = true
			s.usageIn, _ = last.Get("inputTokens").Int()
			s.usageOut, _ = last.Get("outputTokens").Int()
		}
	case "error":
		message, ok := params.Path("error", "message").Str()
		if !ok {
			message = "Codex error"
		}
		if retry, _ := params.Get("willRetry").Bool(); retry {
			s.emit(agent.Status{Text: message + " — retrying"})
		} else {
			s.emit(agent.Upsert{Item: &radiov1.TranscriptItem{
				Id: "error-" + ts.UUID(), TimestampMs: ts.NowMs(), Kind: &radiov1.TranscriptItem_Error{Error: message},
			}})
		}
	case "model/rerouted":
		to, ok := params.Get("toModel").Str()
		if !ok {
			to, ok = params.Get("model").Str()
		}
		if ok {
			s.emit(agent.Upsert{Item: notice("notice", "Model rerouted to "+to)})
		}
	case "thread/compacted":
		s.emit(agent.Upsert{Item: notice("notice", "Context compacted")})
	}
}

func (s *Session) serverExited(message string) {
	s.mu.Lock()
	s.attached = false
	pending := s.pending
	s.pending = map[string]*pendingApproval{}
	if s.turnID != "" {
		s.turnID = ""
		s.emit(agent.TurnEnded{Summary: &radiov1.TurnSummary{IsError: true, Message: "Codex exited"}})
	}
	s.emit(agent.Exited{Message: message})
	s.mu.Unlock()
	for _, p := range pending {
		p.reply <- reply{kind: replyCancelled}
	}
}

// MARK: server requests (approvals / questions)

func (s *Session) handleServerRequest(method string, params ts.JSON) (any, bool) {
	s.mu.Lock()
	s.approvalCounter++
	requestID := fmt.Sprintf("codex-%d-%s", s.approvalCounter, params.Get("itemId").S())
	approval := &radiov1.ApprovalRequest{RequestId: requestID, Resolution: radiov1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING}
	switch method {
	case "item/commandExecution/requestApproval", "execCommandApproval":
		cmd, ok := params.Get("command").Str()
		if !ok {
			var parts []string
			for _, p := range params.Get("command").Arr() {
				if s, ok := p.Str(); ok {
					parts = append(parts, s)
				}
			}
			cmd = strings.Join(parts, " ")
		}
		detail := ts.UnwrapShell(cmd)
		if reason, ok := params.Get("reason").Str(); ok {
			detail += "\n\n" + reason
		}
		approval.Title = "Run command?"
		approval.Detail = detail
	case "item/fileChange/requestApproval", "applyPatchApproval":
		approval.Title = "Apply file changes?"
		approval.Detail = params.Get("reason").S()
	case "item/permissions/requestApproval":
		var parts []string
		if reason, ok := params.Get("reason").Str(); ok {
			parts = append(parts, reason)
		}
		if p := params.Get("permissions"); p.Exists() {
			parts = append(parts, p.Pretty())
		}
		approval.Title = "Grant extra permissions?"
		approval.Detail = strings.Join(parts, "\n\n")
	case "item/tool/requestUserInput":
		approval.Title = "Codex has a question"
		for _, q := range params.Get("questions").Arr() {
			id, ok := q.Get("id").Str()
			if !ok {
				id = ts.UUID()
			}
			aq := &radiov1.AgentQuestion{Id: id, Header: q.Get("header").S(), Question: q.Get("question").S()}
			for _, o := range q.Get("options").Arr() {
				aq.Options = append(aq.Options, &radiov1.QuestionOption{Label: o.Get("label").S(), Description: o.Get("description").S()})
			}
			approval.Questions = append(approval.Questions, aq)
		}
	default:
		s.mu.Unlock()
		return nil, false
	}
	item := &radiov1.TranscriptItem{
		Id: "approval-" + requestID, TimestampMs: ts.NowMs(), Kind: &radiov1.TranscriptItem_Approval{Approval: approval},
	}
	p := &pendingApproval{method: method, item: item, reply: make(chan reply, 1)}
	closed := s.closed
	if !closed {
		s.pending[requestID] = p
		s.emitItem(item)
	}
	s.mu.Unlock()

	var r reply
	if closed {
		r = reply{kind: replyDecision, decision: agent.Decision{Kind: radiov1.Decision_DECISION_DENY}}
	} else {
		r = <-p.reply
	}
	result, resolution, answers := resolveReply(method, params, r)
	approval.Resolution = resolution
	approval.Answers = answers
	s.emitItem(item)
	return result, true
}

func isApproval(d agent.Decision) bool {
	return d.Kind == radiov1.Decision_DECISION_APPROVE || d.Kind == radiov1.Decision_DECISION_APPROVE_FOR_SESSION
}

func isSession(d agent.Decision) bool { return d.Kind == radiov1.Decision_DECISION_APPROVE_FOR_SESSION }

func decisionResolution(d agent.Decision) radiov1.ApprovalResolution {
	switch d.Kind {
	case radiov1.Decision_DECISION_APPROVE:
		return radiov1.ApprovalResolution_APPROVAL_RESOLUTION_APPROVED
	case radiov1.Decision_DECISION_APPROVE_FOR_SESSION:
		return radiov1.ApprovalResolution_APPROVAL_RESOLUTION_APPROVED_FOR_SESSION
	}
	return radiov1.ApprovalResolution_APPROVAL_RESOLUTION_DENIED
}

// resolveReply builds the JSON-RPC result for a server request and the resolution to show.
func resolveReply(method string, params ts.JSON, r reply) (any, radiov1.ApprovalResolution, map[string]string) {
	deny := agent.Decision{Kind: radiov1.Decision_DECISION_DENY}
	resolutionOverride := radiov1.ApprovalResolution_APPROVAL_RESOLUTION_UNSPECIFIED
	if r.kind == replyCancelled {
		// The app-server went away; answer like a denial (nobody is listening) but show it as cancelled.
		r = reply{kind: replyDecision, decision: deny}
		resolutionOverride = radiov1.ApprovalResolution_APPROVAL_RESOLUTION_CANCELLED
	}
	result, resolution, answers := approvalResult(method, params, r)
	if resolutionOverride != radiov1.ApprovalResolution_APPROVAL_RESOLUTION_UNSPECIFIED {
		resolution = resolutionOverride
	}
	return result, resolution, answers
}

func approvalResult(method string, params ts.JSON, r reply) (any, radiov1.ApprovalResolution, map[string]string) {
	switch {
	case method == "item/tool/requestUserInput" && r.kind == replyAnswers:
		m := map[string]any{}
		answers := map[string]string{}
		for k, v := range r.answers {
			m[k] = map[string]any{"answers": []any{v}}
			answers[k] = v
		}
		return map[string]any{"answers": m}, radiov1.ApprovalResolution_APPROVAL_RESOLUTION_ANSWERED, answers
	case method == "item/tool/requestUserInput":
		return map[string]any{"answers": map[string]any{}}, radiov1.ApprovalResolution_APPROVAL_RESOLUTION_DENIED, nil
	case r.kind == replyAnswers:
		return map[string]any{"decision": "decline"}, radiov1.ApprovalResolution_APPROVAL_RESOLUTION_DENIED, nil
	case method == "item/permissions/requestApproval":
		if isApproval(r.decision) {
			perms := params.Get("permissions").Raw()
			if perms == nil {
				perms = map[string]any{}
			}
			scope := "turn"
			if isSession(r.decision) {
				scope = "session"
			}
			return map[string]any{"permissions": perms, "scope": scope}, radiov1.ApprovalResolution_APPROVAL_RESOLUTION_APPROVED, nil
		}
		return map[string]any{"permissions": map[string]any{}, "scope": "turn"}, radiov1.ApprovalResolution_APPROVAL_RESOLUTION_DENIED, nil
	case method == "execCommandApproval" || method == "applyPatchApproval":
		var decision any
		switch {
		case isSession(r.decision):
			decision = "approved_for_session"
		case isApproval(r.decision):
			decision = "approved"
		default:
			msg := r.decision.Message
			if msg == "" {
				msg = "User declined"
			}
			decision = map[string]any{"denied": map[string]any{"rejection": msg}}
		}
		return map[string]any{"decision": decision}, decisionResolution(r.decision), nil
	default:
		decision := "decline"
		switch {
		case isSession(r.decision):
			decision = "acceptForSession"
		case isApproval(r.decision):
			decision = "accept"
		}
		return map[string]any{"decision": decision}, decisionResolution(r.decision), nil
	}
}

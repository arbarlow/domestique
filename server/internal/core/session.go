package core

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
)

// maxToolOutput caps streamed tool output kept on an item (the tail is kept).
const (
	maxToolOutput  = 200_000
	keptToolOutput = 150_000
	// dirtyFlushDelay: how long streamed text may sit unpersisted.
	dirtyFlushDelay = time.Second
)

// Session is one agent conversation (a chat tab). It owns the agent session, folds its events into a
// persisted transcript, and fans events out to subscribers.
//
// Every persisted write gets the next seq for this session. Streamed text (AppendText) is applied to
// the cached item and persisted lazily; a subscribe flushes it first, so "items after seq N" plus the
// live stream from that moment never loses text.
type Session struct {
	server *Server
	stream *stream

	mu            sync.Mutex
	meta          *domestiquev1.Session
	session       agent.Session
	items         map[string]*domestiquev1.TranscriptItem
	dirty         map[string]bool
	flushTimer    *time.Timer
	pending       map[string]bool // pending approval request ids
	turnStartedAt time.Time
	lastCost      float64
	closed        bool
}

func newSession(server *Server, meta *domestiquev1.Session) *Session {
	return &Session{
		server:  server,
		stream:  newStream(),
		meta:    meta,
		items:   map[string]*domestiquev1.TranscriptItem{},
		dirty:   map[string]bool{},
		pending: map[string]bool{},
	}
}

// id is immutable, so it may be read without r.mu.
func (r *Session) id() string { return r.meta.Id }

// Meta returns a snapshot of the session's metadata.
func (r *Session) Meta() *domestiquev1.Session {
	r.mu.Lock()
	defer r.mu.Unlock()
	return proto.Clone(r.meta).(*domestiquev1.Session)
}

// Subscribe flushes pending text, returns every item persisted after fromSeq, and registers a live
// subscriber. Nothing published after the replay is missed.
func (r *Session) Subscribe(fromSeq uint64) ([]*domestiquev1.TranscriptEntry, *Subscriber, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil, nil, fmt.Errorf("session %s is closed", r.meta.Id)
	}
	r.flushDirtyLocked()
	replay, err := r.server.store.ItemsAfterInOrder(r.meta.Id, fromSeq)
	if err != nil {
		return nil, nil, err
	}
	return replay, r.stream.add(), nil
}

// Transcript pages through persisted items (flushing streamed text first).
func (r *Session) Transcript(afterSeq uint64, limit int) ([]*domestiquev1.TranscriptEntry, error) {
	r.mu.Lock()
	r.flushDirtyLocked()
	r.mu.Unlock()
	return r.server.store.ItemsAfter(r.meta.Id, afterSeq, limit)
}

// Send records the user's message and sends it to the agent, starting or resuming it if needed.
func (r *Session) Send(ctx context.Context, text string, atts []agent.Attachment) error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return fmt.Errorf("session is closed")
	}
	if r.meta.LastSeq == 0 && (r.meta.Title == "" || r.meta.Title == "New chat") {
		title := strings.SplitN(strings.TrimSpace(text), "\n", 2)[0]
		if len([]rune(title)) > 40 {
			title = string([]rune(title)[:40])
		}
		if title == "" {
			title = "Chat"
		}
		r.meta.Title = title
	}
	display := text
	if len(atts) > 0 {
		names := make([]string, len(atts))
		for i, a := range atts {
			names[i] = "📎 " + a.Filename
		}
		display += "\n\n" + strings.Join(names, "  ")
	}
	r.upsertLocked(&domestiquev1.TranscriptItem{
		Id: "user-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
		Kind: &domestiquev1.TranscriptItem_User{User: display},
	})
	sess, err := r.ensureSessionLocked()
	if err != nil {
		r.errorLocked(err.Error())
		r.mu.Unlock()
		return err
	}
	if r.turnStartedAt.IsZero() {
		r.turnStartedAt = time.Now()
	}
	r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_RUNNING)
	r.mu.Unlock()

	if err := sess.Send(ctx, text, atts); err != nil {
		r.mu.Lock()
		r.errorLocked(err.Error())
		r.turnStartedAt = time.Time{}
		r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE)
		r.mu.Unlock()
		return err
	}
	return nil
}

func (r *Session) currentSession() agent.Session {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.session
}

func (r *Session) Interrupt(ctx context.Context) {
	if s := r.currentSession(); s != nil {
		s.Interrupt(ctx)
	}
}

func (r *Session) Respond(ctx context.Context, requestID string, d agent.Decision) error {
	s := r.currentSession()
	if s == nil {
		return fmt.Errorf("no agent is running for this session")
	}
	s.Respond(ctx, requestID, d)
	return nil
}

func (r *Session) Answer(ctx context.Context, requestID string, answers map[string]string) error {
	s := r.currentSession()
	if s == nil {
		return fmt.Errorf("no agent is running for this session")
	}
	s.Answer(ctx, requestID, answers)
	return nil
}

// Update changes model, effort, permission mode or title.
func (r *Session) Update(ctx context.Context, u *domestiquev1.UpdateSession) {
	r.mu.Lock()
	s := r.session
	if u.Model != nil {
		r.meta.Model = u.GetModel()
	}
	if u.Effort != nil {
		r.meta.Effort = u.GetEffort()
	}
	if u.PermissionMode != nil {
		r.meta.PermissionMode = u.GetPermissionMode()
	}
	if u.Title != nil {
		r.meta.Title = u.GetTitle()
	}
	r.saveMetaLocked()
	r.mu.Unlock()
	if s == nil {
		return
	}
	if u.Model != nil {
		s.SetModel(ctx, u.GetModel())
	}
	if u.Effort != nil {
		s.SetEffort(ctx, u.GetEffort())
	}
	if u.PermissionMode != nil {
		s.SetPermissionMode(ctx, u.GetPermissionMode())
	}
}

// shutdown stops the agent and ends every subscription.
func (r *Session) shutdown() {
	r.mu.Lock()
	r.flushDirtyLocked()
	r.closed = true
	s := r.session
	r.session = nil
	r.mu.Unlock()
	if s != nil {
		s.Shutdown()
	}
	r.stream.closeAll()
}

// stopAgent stops the agent process but keeps the session usable (next Send resumes).
func (r *Session) stopAgent() {
	r.mu.Lock()
	r.flushDirtyLocked()
	s := r.session
	r.session = nil
	r.turnStartedAt = time.Time{}
	r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE)
	r.mu.Unlock()
	if s != nil {
		s.Shutdown()
	}
}

func (r *Session) ensureSessionLocked() (agent.Session, error) {
	if r.session != nil {
		return r.session, nil
	}
	ws, repo, err := r.server.workspaceAndRepo(r.meta.WorkspaceId)
	if err != nil {
		return nil, err
	}
	env := workspaceEnv(ws, repo)
	env["DOMESTIQUE_TAB"] = r.meta.Id
	cfg := agent.Config{
		Cwd:                ws.Path,
		Model:              r.meta.Model,
		Effort:             r.meta.Effort,
		Mode:               r.meta.PermissionMode,
		ResumeSessionID:    r.meta.ProviderSessionId,
		Env:                env,
		ExtraWritableRoots: []string{repo.Path + "/.git"},
		AppendSystemPrompt: systemPrompt(ws, repo),
		Executable:         r.server.executable(r.meta.Provider),
	}
	if f := r.server.opts.McpConfigFile; f != nil {
		// A broken MCP setup shouldn't stop the chat; the agent just starts without those servers.
		if path, err := f(); err != nil {
			r.server.log.Warn("mcp config", "err", err)
		} else {
			cfg.McpConfigPath = path
		}
	}
	s, err := r.server.agents.New(r.meta.Provider, cfg)
	if err != nil {
		return nil, err
	}
	r.session = s
	go r.pump(s)
	return s, nil
}

func (r *Session) pump(s agent.Session) {
	for ev := range s.Events() {
		r.handle(s, ev)
	}
}

func (r *Session) handle(s agent.Session, ev agent.Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.session != s || r.closed {
		return // a stale session's leftovers
	}
	switch e := ev.(type) {
	case agent.Started:
		if r.meta.ProviderSessionId != e.SessionID {
			r.meta.ProviderSessionId = e.SessionID
			r.saveMetaLocked()
		}
	case agent.Upsert:
		item := proto.Clone(e.Item).(*domestiquev1.TranscriptItem)
		r.upsertLocked(item)
		if ap := item.GetApproval(); ap != nil {
			if ap.Resolution == domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING {
				r.pending[ap.RequestId] = true
			} else {
				delete(r.pending, ap.RequestId)
			}
			r.refreshActivityLocked()
		}
	case agent.AppendText:
		r.appendLocked(e.ItemID, e.Delta)
	case agent.TurnStarted:
		if r.turnStartedAt.IsZero() {
			r.turnStartedAt = time.Now()
		}
		r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_RUNNING)
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_TurnStarted{TurnStarted: &domestiquev1.TurnStarted{}}})
	case agent.TurnEnded:
		sum := proto.Clone(e.Summary).(*domestiquev1.TurnSummary)
		if sum.CostUsd != nil {
			// Claude reports cumulative session cost; record the per-turn delta.
			total := sum.GetCostUsd()
			delta := max(0, total-r.lastCost)
			r.lastCost = total
			sum.CostUsd = &delta
		}
		if sum.DurationMs == nil && !r.turnStartedAt.IsZero() {
			d := time.Since(r.turnStartedAt).Milliseconds()
			sum.DurationMs = &d
		}
		r.upsertLocked(&domestiquev1.TranscriptItem{
			Id: "turn-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
			Kind: &domestiquev1.TranscriptItem_TurnSummary{TurnSummary: sum},
		})
		r.turnStartedAt = time.Time{}
		clear(r.pending)
		r.meta.Status = ""
		r.flushDirtyLocked()
		r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE)
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_TurnEnded{TurnEnded: &domestiquev1.TurnEnded{Summary: sum}}})
		r.server.markUnread(r.meta.WorkspaceId)
	case agent.Status:
		r.meta.Status = e.Text
		r.server.publishSession(proto.Clone(r.meta).(*domestiquev1.Session))
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_Status{Status: &domestiquev1.StatusLine{Text: e.Text}}})
	case agent.Models:
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_Models{Models: &domestiquev1.ModelList{Models: e.Models}}})
	case agent.Task:
		t := proto.Clone(e.Task).(*domestiquev1.AgentTask)
		if t.Status != domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_RUNNING {
			r.recordTaskResultLocked(t)
		}
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_Task{Task: t}})
	case agent.AutoTurnStarted:
		r.upsertLocked(&domestiquev1.TranscriptItem{
			Id: "trigger-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
			Kind: &domestiquev1.TranscriptItem_Trigger{Trigger: e.Reason},
		})
		r.turnStartedAt = time.Now()
		r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_RUNNING)
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_AutoTurnStarted{AutoTurnStarted: &domestiquev1.AutoTurnStarted{Reason: e.Reason}}})
	case agent.RateLimit:
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_RateLimit{RateLimit: proto.Clone(e.Info).(*domestiquev1.RateLimit)}})
	case agent.Exited:
		r.session = nil
		go s.Shutdown()
		r.turnStartedAt = time.Time{}
		clear(r.pending)
		r.meta.Status = ""
		if e.Message != "" {
			r.errorLocked(e.Message)
		}
		r.settleLocked()
		r.flushDirtyLocked()
		r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE)
		r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_Exited{Exited: &domestiquev1.AgentExited{Message: e.Message}}})
	}
}

// ---- transcript folding (all *Locked: caller holds r.mu)

func (r *Session) itemLocked(id string) *domestiquev1.TranscriptItem {
	if it, ok := r.items[id]; ok {
		return it
	}
	it, err := r.server.store.Item(r.meta.Id, id)
	if err != nil || it == nil {
		return nil
	}
	r.items[id] = it
	return it
}

// upsertLocked persists an item now and publishes it. Keeps the original timestamp on replace.
func (r *Session) upsertLocked(item *domestiquev1.TranscriptItem) {
	if r.closed {
		return // its rows are being (or have been) deleted; the id may be reused
	}
	if prev := r.itemLocked(item.Id); prev != nil && prev.TimestampMs != 0 {
		item.TimestampMs = prev.TimestampMs
	}
	if item.TimestampMs == 0 {
		item.TimestampMs = time.Now().UnixMilli()
	}
	r.items[item.Id] = item
	delete(r.dirty, item.Id)
	seq, err := r.server.store.PutItems(r.meta.Id, r.meta.LastSeq, []*domestiquev1.TranscriptItem{item})
	if err != nil {
		r.server.log.Error("persist transcript item", "session", r.meta.Id, "err", err)
		return
	}
	r.meta.LastSeq = seq
	r.publishLocked(&domestiquev1.Event{Seq: seq, Payload: &domestiquev1.Event_ItemUpserted{ItemUpserted: proto.Clone(item).(*domestiquev1.TranscriptItem)}})
}

func (r *Session) appendLocked(id, delta string) {
	it := r.itemLocked(id)
	if it == nil {
		return
	}
	switch k := it.Kind.(type) {
	case *domestiquev1.TranscriptItem_Assistant:
		k.Assistant += delta
	case *domestiquev1.TranscriptItem_Reasoning:
		k.Reasoning += delta
	case *domestiquev1.TranscriptItem_Tool:
		k.Tool.Output += delta
		if len(k.Tool.Output) > maxToolOutput {
			k.Tool.Output = k.Tool.Output[len(k.Tool.Output)-keptToolOutput:]
		}
	default:
		return
	}
	r.dirty[id] = true
	if r.flushTimer == nil {
		r.flushTimer = time.AfterFunc(dirtyFlushDelay, func() {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.flushDirtyLocked()
		})
	}
	r.publishLocked(&domestiquev1.Event{Payload: &domestiquev1.Event_AppendText{AppendText: &domestiquev1.AppendText{ItemId: id, Delta: delta}}})
}

// flushDirtyLocked persists streamed text. It doesn't publish: live subscribers already have it.
func (r *Session) flushDirtyLocked() {
	if r.flushTimer != nil {
		r.flushTimer.Stop()
		r.flushTimer = nil
	}
	if len(r.dirty) == 0 {
		return
	}
	items := make([]*domestiquev1.TranscriptItem, 0, len(r.dirty))
	for id := range r.dirty {
		if it := r.items[id]; it != nil {
			items = append(items, it)
		}
	}
	clear(r.dirty)
	seq, err := r.server.store.PutItems(r.meta.Id, r.meta.LastSeq, items)
	if err != nil {
		r.server.log.Error("flush transcript", "session", r.meta.Id, "err", err)
		return
	}
	r.meta.LastSeq = seq
}

// recordTaskResultLocked stores a finished subagent's outcome on its Agent tool item.
func (r *Session) recordTaskResultLocked(t *domestiquev1.AgentTask) {
	if t.ToolUseId == "" {
		return
	}
	it := r.itemLocked(t.ToolUseId)
	if it == nil || it.GetTool() == nil {
		return
	}
	item := proto.Clone(it).(*domestiquev1.TranscriptItem)
	call := item.GetTool()
	if t.Summary != "" {
		call.Output = t.Summary
	} else if t.Output != "" {
		call.Output = t.Output
	}
	switch t.Status {
	case domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_COMPLETED:
		call.Status = domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED
	case domestiquev1.AgentTaskStatus_AGENT_TASK_STATUS_FAILED:
		call.Status = domestiquev1.ToolStatus_TOOL_STATUS_FAILED
	default:
		call.Status = domestiquev1.ToolStatus_TOOL_STATUS_DECLINED
	}
	r.upsertLocked(item)
}

// settleLocked marks running tools failed and pending approvals cancelled (agent gone).
func (r *Session) settleLocked() {
	for _, it := range r.items {
		if s := settled(it); s != nil {
			r.upsertLocked(s)
		}
	}
}

// settled returns a fixed copy of an item left mid-flight, or nil if it's fine.
func settled(it *domestiquev1.TranscriptItem) *domestiquev1.TranscriptItem {
	if t := it.GetTool(); t != nil && t.Status == domestiquev1.ToolStatus_TOOL_STATUS_RUNNING {
		c := proto.Clone(it).(*domestiquev1.TranscriptItem)
		c.GetTool().Status = domestiquev1.ToolStatus_TOOL_STATUS_FAILED
		return c
	}
	if a := it.GetApproval(); a != nil && a.Resolution == domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING {
		c := proto.Clone(it).(*domestiquev1.TranscriptItem)
		c.GetApproval().Resolution = domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_CANCELLED
		return c
	}
	return nil
}

func (r *Session) errorLocked(msg string) {
	r.upsertLocked(&domestiquev1.TranscriptItem{
		Id: "error-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
		Kind: &domestiquev1.TranscriptItem_Error{Error: msg},
	})
}

func (r *Session) refreshActivityLocked() {
	if r.meta.Activity == domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE {
		return
	}
	if len(r.pending) > 0 {
		r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_AWAITING_INPUT)
	} else {
		r.setActivityLocked(domestiquev1.SessionActivity_SESSION_ACTIVITY_RUNNING)
	}
}

func (r *Session) setActivityLocked(a domestiquev1.SessionActivity) {
	if r.meta.Activity == a {
		r.saveMetaLocked()
		return
	}
	r.meta.Activity = a
	r.saveMetaLocked()
}

// saveMetaLocked persists the session and tells server-stream subscribers.
func (r *Session) saveMetaLocked() {
	if err := r.server.store.PutSession(r.meta); err != nil {
		r.server.log.Error("persist session", "session", r.meta.Id, "err", err)
	}
	r.server.publishSession(proto.Clone(r.meta).(*domestiquev1.Session))
}

func (r *Session) publishLocked(ev *domestiquev1.Event) {
	if ev.Seq == 0 {
		ev.Seq = r.meta.LastSeq
	}
	r.stream.publish(ev)
}

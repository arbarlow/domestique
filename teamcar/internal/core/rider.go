package core

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/agent"
)

// maxToolOutput caps streamed tool output kept on an item (the tail is kept).
const (
	maxToolOutput  = 200_000
	keptToolOutput = 150_000
	// dirtyFlushDelay: how long streamed text may sit unpersisted.
	dirtyFlushDelay = time.Second
)

// Rider is one agent conversation (a chat tab). It owns the agent session, folds its events into a
// persisted transcript, and fans events out to subscribers.
//
// Every persisted write gets the next seq for this rider. Streamed text (AppendText) is applied to
// the cached item and persisted lazily; a subscribe flushes it first, so "items after seq N" plus the
// live stream from that moment never loses text.
type Rider struct {
	car    *Car
	stream *stream

	mu            sync.Mutex
	meta          *radiov1.Rider
	session       agent.Session
	items         map[string]*radiov1.TranscriptItem
	dirty         map[string]bool
	flushTimer    *time.Timer
	pending       map[string]bool // pending approval request ids
	turnStartedAt time.Time
	lastCost      float64
	closed        bool
}

func newRider(car *Car, meta *radiov1.Rider) *Rider {
	return &Rider{
		car:     car,
		stream:  newStream(),
		meta:    meta,
		items:   map[string]*radiov1.TranscriptItem{},
		dirty:   map[string]bool{},
		pending: map[string]bool{},
	}
}

// id is immutable, so it may be read without r.mu.
func (r *Rider) id() string { return r.meta.Id }

// Meta returns a snapshot of the rider's metadata.
func (r *Rider) Meta() *radiov1.Rider {
	r.mu.Lock()
	defer r.mu.Unlock()
	return proto.Clone(r.meta).(*radiov1.Rider)
}

// Subscribe flushes pending text, returns every item persisted after fromSeq, and registers a live
// subscriber. Nothing published after the replay is missed.
func (r *Rider) Subscribe(fromSeq uint64) ([]*radiov1.TranscriptEntry, *Subscriber, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil, nil, fmt.Errorf("rider %s is closed", r.meta.Id)
	}
	r.flushDirtyLocked()
	replay, err := r.car.store.ItemsAfterInOrder(r.meta.Id, fromSeq)
	if err != nil {
		return nil, nil, err
	}
	return replay, r.stream.add(), nil
}

// Transcript pages through persisted items (flushing streamed text first).
func (r *Rider) Transcript(afterSeq uint64, limit int) ([]*radiov1.TranscriptEntry, error) {
	r.mu.Lock()
	r.flushDirtyLocked()
	r.mu.Unlock()
	return r.car.store.ItemsAfter(r.meta.Id, afterSeq, limit)
}

// Send records the user's message and sends it to the agent, starting or resuming it if needed.
func (r *Rider) Send(ctx context.Context, text string, atts []agent.Attachment) error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return fmt.Errorf("rider is closed")
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
	r.upsertLocked(&radiov1.TranscriptItem{
		Id: "user-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
		Kind: &radiov1.TranscriptItem_User{User: display},
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
	r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_RUNNING)
	r.mu.Unlock()

	if err := sess.Send(ctx, text, atts); err != nil {
		r.mu.Lock()
		r.errorLocked(err.Error())
		r.turnStartedAt = time.Time{}
		r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_IDLE)
		r.mu.Unlock()
		return err
	}
	return nil
}

func (r *Rider) currentSession() agent.Session {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.session
}

func (r *Rider) Interrupt(ctx context.Context) {
	if s := r.currentSession(); s != nil {
		s.Interrupt(ctx)
	}
}

func (r *Rider) Respond(ctx context.Context, requestID string, d agent.Decision) error {
	s := r.currentSession()
	if s == nil {
		return fmt.Errorf("no agent is running for this rider")
	}
	s.Respond(ctx, requestID, d)
	return nil
}

func (r *Rider) Answer(ctx context.Context, requestID string, answers map[string]string) error {
	s := r.currentSession()
	if s == nil {
		return fmt.Errorf("no agent is running for this rider")
	}
	s.Answer(ctx, requestID, answers)
	return nil
}

// Update changes model, effort, permission mode or title.
func (r *Rider) Update(ctx context.Context, u *radiov1.UpdateRider) {
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
func (r *Rider) shutdown() {
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

// stopAgent stops the agent process but keeps the rider usable (next Send resumes).
func (r *Rider) stopAgent() {
	r.mu.Lock()
	r.flushDirtyLocked()
	s := r.session
	r.session = nil
	r.turnStartedAt = time.Time{}
	r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_IDLE)
	r.mu.Unlock()
	if s != nil {
		s.Shutdown()
	}
}

func (r *Rider) ensureSessionLocked() (agent.Session, error) {
	if r.session != nil {
		return r.session, nil
	}
	ws, repo, err := r.car.workspaceAndRepo(r.meta.WorkspaceId)
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
		Executable:         r.car.executable(r.meta.Provider),
	}
	s, err := r.car.agents.New(r.meta.Provider, cfg)
	if err != nil {
		return nil, err
	}
	r.session = s
	go r.pump(s)
	return s, nil
}

func (r *Rider) pump(s agent.Session) {
	for ev := range s.Events() {
		r.handle(s, ev)
	}
}

func (r *Rider) handle(s agent.Session, ev agent.Event) {
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
		item := proto.Clone(e.Item).(*radiov1.TranscriptItem)
		r.upsertLocked(item)
		if ap := item.GetApproval(); ap != nil {
			if ap.Resolution == radiov1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING {
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
		r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_RUNNING)
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_TurnStarted{TurnStarted: &radiov1.TurnStarted{}}})
	case agent.TurnEnded:
		sum := proto.Clone(e.Summary).(*radiov1.TurnSummary)
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
		r.upsertLocked(&radiov1.TranscriptItem{
			Id: "turn-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
			Kind: &radiov1.TranscriptItem_TurnSummary{TurnSummary: sum},
		})
		r.turnStartedAt = time.Time{}
		clear(r.pending)
		r.meta.Status = ""
		r.flushDirtyLocked()
		r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_IDLE)
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_TurnEnded{TurnEnded: &radiov1.TurnEnded{Summary: sum}}})
		r.car.markUnread(r.meta.WorkspaceId)
	case agent.Status:
		r.meta.Status = e.Text
		r.car.publishRider(proto.Clone(r.meta).(*radiov1.Rider))
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_Status{Status: &radiov1.StatusLine{Text: e.Text}}})
	case agent.Models:
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_Models{Models: &radiov1.ModelList{Models: e.Models}}})
	case agent.Task:
		t := proto.Clone(e.Task).(*radiov1.AgentTask)
		if t.Status != radiov1.AgentTaskStatus_AGENT_TASK_STATUS_RUNNING {
			r.recordTaskResultLocked(t)
		}
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_Task{Task: t}})
	case agent.AutoTurnStarted:
		r.upsertLocked(&radiov1.TranscriptItem{
			Id: "trigger-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
			Kind: &radiov1.TranscriptItem_Trigger{Trigger: e.Reason},
		})
		r.turnStartedAt = time.Now()
		r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_RUNNING)
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_AutoTurnStarted{AutoTurnStarted: &radiov1.AutoTurnStarted{Reason: e.Reason}}})
	case agent.RateLimit:
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_RateLimit{RateLimit: proto.Clone(e.Info).(*radiov1.RateLimit)}})
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
		r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_IDLE)
		r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_Exited{Exited: &radiov1.AgentExited{Message: e.Message}}})
	}
}

// ---- transcript folding (all *Locked: caller holds r.mu)

func (r *Rider) itemLocked(id string) *radiov1.TranscriptItem {
	if it, ok := r.items[id]; ok {
		return it
	}
	it, err := r.car.store.Item(r.meta.Id, id)
	if err != nil || it == nil {
		return nil
	}
	r.items[id] = it
	return it
}

// upsertLocked persists an item now and publishes it. Keeps the original timestamp on replace.
func (r *Rider) upsertLocked(item *radiov1.TranscriptItem) {
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
	seq, err := r.car.store.PutItems(r.meta.Id, r.meta.LastSeq, []*radiov1.TranscriptItem{item})
	if err != nil {
		r.car.log.Error("persist transcript item", "rider", r.meta.Id, "err", err)
		return
	}
	r.meta.LastSeq = seq
	r.publishLocked(&radiov1.Event{Seq: seq, Payload: &radiov1.Event_ItemUpserted{ItemUpserted: proto.Clone(item).(*radiov1.TranscriptItem)}})
}

func (r *Rider) appendLocked(id, delta string) {
	it := r.itemLocked(id)
	if it == nil {
		return
	}
	switch k := it.Kind.(type) {
	case *radiov1.TranscriptItem_Assistant:
		k.Assistant += delta
	case *radiov1.TranscriptItem_Reasoning:
		k.Reasoning += delta
	case *radiov1.TranscriptItem_Tool:
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
	r.publishLocked(&radiov1.Event{Payload: &radiov1.Event_AppendText{AppendText: &radiov1.AppendText{ItemId: id, Delta: delta}}})
}

// flushDirtyLocked persists streamed text. It doesn't publish: live subscribers already have it.
func (r *Rider) flushDirtyLocked() {
	if r.flushTimer != nil {
		r.flushTimer.Stop()
		r.flushTimer = nil
	}
	if len(r.dirty) == 0 {
		return
	}
	items := make([]*radiov1.TranscriptItem, 0, len(r.dirty))
	for id := range r.dirty {
		if it := r.items[id]; it != nil {
			items = append(items, it)
		}
	}
	clear(r.dirty)
	seq, err := r.car.store.PutItems(r.meta.Id, r.meta.LastSeq, items)
	if err != nil {
		r.car.log.Error("flush transcript", "rider", r.meta.Id, "err", err)
		return
	}
	r.meta.LastSeq = seq
}

// recordTaskResultLocked stores a finished subagent's outcome on its Agent tool item.
func (r *Rider) recordTaskResultLocked(t *radiov1.AgentTask) {
	if t.ToolUseId == "" {
		return
	}
	it := r.itemLocked(t.ToolUseId)
	if it == nil || it.GetTool() == nil {
		return
	}
	item := proto.Clone(it).(*radiov1.TranscriptItem)
	call := item.GetTool()
	if t.Summary != "" {
		call.Output = t.Summary
	} else if t.Output != "" {
		call.Output = t.Output
	}
	switch t.Status {
	case radiov1.AgentTaskStatus_AGENT_TASK_STATUS_COMPLETED:
		call.Status = radiov1.ToolStatus_TOOL_STATUS_COMPLETED
	case radiov1.AgentTaskStatus_AGENT_TASK_STATUS_FAILED:
		call.Status = radiov1.ToolStatus_TOOL_STATUS_FAILED
	default:
		call.Status = radiov1.ToolStatus_TOOL_STATUS_DECLINED
	}
	r.upsertLocked(item)
}

// settleLocked marks running tools failed and pending approvals cancelled (agent gone).
func (r *Rider) settleLocked() {
	for _, it := range r.items {
		if s := settled(it); s != nil {
			r.upsertLocked(s)
		}
	}
}

// settled returns a fixed copy of an item left mid-flight, or nil if it's fine.
func settled(it *radiov1.TranscriptItem) *radiov1.TranscriptItem {
	if t := it.GetTool(); t != nil && t.Status == radiov1.ToolStatus_TOOL_STATUS_RUNNING {
		c := proto.Clone(it).(*radiov1.TranscriptItem)
		c.GetTool().Status = radiov1.ToolStatus_TOOL_STATUS_FAILED
		return c
	}
	if a := it.GetApproval(); a != nil && a.Resolution == radiov1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING {
		c := proto.Clone(it).(*radiov1.TranscriptItem)
		c.GetApproval().Resolution = radiov1.ApprovalResolution_APPROVAL_RESOLUTION_CANCELLED
		return c
	}
	return nil
}

func (r *Rider) errorLocked(msg string) {
	r.upsertLocked(&radiov1.TranscriptItem{
		Id: "error-" + uuid.NewString(), TimestampMs: time.Now().UnixMilli(),
		Kind: &radiov1.TranscriptItem_Error{Error: msg},
	})
}

func (r *Rider) refreshActivityLocked() {
	if r.meta.Activity == radiov1.RiderActivity_RIDER_ACTIVITY_IDLE {
		return
	}
	if len(r.pending) > 0 {
		r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_AWAITING_INPUT)
	} else {
		r.setActivityLocked(radiov1.RiderActivity_RIDER_ACTIVITY_RUNNING)
	}
}

func (r *Rider) setActivityLocked(a radiov1.RiderActivity) {
	if r.meta.Activity == a {
		r.saveMetaLocked()
		return
	}
	r.meta.Activity = a
	r.saveMetaLocked()
}

// saveMetaLocked persists the rider and tells server-stream subscribers.
func (r *Rider) saveMetaLocked() {
	if err := r.car.store.PutRider(r.meta); err != nil {
		r.car.log.Error("persist rider", "rider", r.meta.Id, "err", err)
	}
	r.car.publishRider(proto.Clone(r.meta).(*radiov1.Rider))
}

func (r *Rider) publishLocked(ev *radiov1.Event) {
	if ev.Seq == 0 {
		ev.Seq = r.meta.LastSeq
	}
	r.stream.publish(ev)
}

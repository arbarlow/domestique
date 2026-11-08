// Package fake is a scriptable agent for tests. It echoes prompts, streams text in chunks, and
// supports an approval round-trip:
//
//	"ask: <x>"  emits a pending approval and finishes only after Respond
//	"slow: <x>" streams 50 chunks 10ms apart (for interrupt/reconnect tests)
//	"exit"      reports the process exited
package fake

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
)

var sessions atomic.Int64

// Sessions counts sessions ever created (for tests).
func Sessions() int64 { return sessions.Load() }

type Session struct {
	cfg      agent.Config
	events   chan agent.Event
	mu       sync.Mutex
	closed   bool
	turn     int
	approval chan agent.Decision
	cancel   context.CancelFunc
	wg       sync.WaitGroup
}

func New(cfg agent.Config) (agent.Session, error) {
	sessions.Add(1)
	return &Session{cfg: cfg, events: make(chan agent.Event, 4096)}, nil
}

func Register(r *agent.Registry) {
	r.Register(domestiquev1.Provider_PROVIDER_CLAUDE, New, func(context.Context) ([]*domestiquev1.ModelOption, error) {
		return []*domestiquev1.ModelOption{{Id: "fake-1", DisplayName: "Fake 1", IsDefault: true}}, nil
	})
}

func (s *Session) Provider() domestiquev1.Provider { return domestiquev1.Provider_PROVIDER_CLAUDE }
func (s *Session) Events() <-chan agent.Event      { return s.events }

func (s *Session) emit(e agent.Event) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.events <- e
	}
}

func item(id string, k any) *domestiquev1.TranscriptItem {
	it := &domestiquev1.TranscriptItem{Id: id, TimestampMs: time.Now().UnixMilli()}
	switch v := k.(type) {
	case *domestiquev1.TranscriptItem_Assistant:
		it.Kind = v
	case *domestiquev1.TranscriptItem_Tool:
		it.Kind = v
	case *domestiquev1.TranscriptItem_Approval:
		it.Kind = v
	}
	return it
}

func (s *Session) Send(ctx context.Context, text string, _ []agent.Attachment) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return fmt.Errorf("closed")
	}
	s.turn++
	turn := s.turn
	if s.turn == 1 {
		s.mu.Unlock()
		sid := s.cfg.ResumeSessionID
		if sid == "" {
			sid = fmt.Sprintf("fake-session-%d", sessions.Load())
		}
		s.emit(agent.Started{SessionID: sid, Model: "fake-1"})
	} else {
		s.mu.Unlock()
	}
	tctx, cancel := context.WithCancel(context.Background())
	s.mu.Lock()
	s.cancel = cancel
	s.mu.Unlock()
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		s.run(tctx, turn, text)
	}()
	return nil
}

func (s *Session) run(ctx context.Context, turn int, text string) {
	s.emit(agent.TurnStarted{})
	if text == "exit" {
		s.emit(agent.Exited{Message: "fake agent exited"})
		return
	}
	msgID := fmt.Sprintf("msg-%d", turn)
	s.emit(agent.Upsert{Item: item(msgID, &domestiquev1.TranscriptItem_Assistant{Assistant: ""})})
	reply := "echo: " + text
	chunks := 4
	delay := time.Duration(0)
	if strings.HasPrefix(text, "slow: ") {
		chunks, delay = 50, 10*time.Millisecond
	}
	for i, part := range split(reply, chunks) {
		if ctx.Err() != nil {
			s.emit(agent.TurnEnded{Summary: &domestiquev1.TurnSummary{IsError: true, Message: "interrupted"}})
			return
		}
		if delay > 0 && i > 0 {
			time.Sleep(delay)
		}
		s.emit(agent.AppendText{ItemID: msgID, Delta: part})
	}
	toolID := fmt.Sprintf("tool-%d", turn)
	s.emit(agent.Upsert{Item: item(toolID, &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{Name: "Bash", Summary: "true", Status: domestiquev1.ToolStatus_TOOL_STATUS_RUNNING}})})
	s.emit(agent.Upsert{Item: item(toolID, &domestiquev1.TranscriptItem_Tool{Tool: &domestiquev1.ToolCall{Name: "Bash", Summary: "true", Output: "ok", Status: domestiquev1.ToolStatus_TOOL_STATUS_COMPLETED}})})
	if strings.HasPrefix(text, "ask: ") {
		reqID := fmt.Sprintf("req-%d", turn)
		ap := &domestiquev1.ApprovalRequest{RequestId: reqID, Title: "Run rm -rf build?", Resolution: domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING}
		ch := make(chan agent.Decision, 1)
		s.mu.Lock()
		s.approval = ch
		s.mu.Unlock()
		s.emit(agent.Upsert{Item: item("approval-"+reqID, &domestiquev1.TranscriptItem_Approval{Approval: ap})})
		var d agent.Decision
		select {
		case d = <-ch:
		case <-ctx.Done():
			return
		}
		res := domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_DENIED
		if d.Kind == domestiquev1.Decision_DECISION_APPROVE || d.Kind == domestiquev1.Decision_DECISION_APPROVE_FOR_SESSION {
			res = domestiquev1.ApprovalResolution_APPROVAL_RESOLUTION_APPROVED
		}
		done := &domestiquev1.ApprovalRequest{RequestId: reqID, Title: ap.Title, Resolution: res}
		s.emit(agent.Upsert{Item: item("approval-"+reqID, &domestiquev1.TranscriptItem_Approval{Approval: done})})
	}
	cost := 0.01 * float64(turn)
	s.emit(agent.TurnEnded{Summary: &domestiquev1.TurnSummary{CostUsd: &cost}})
}

func split(s string, n int) []string {
	if n <= 1 || len(s) < n {
		return []string{s}
	}
	size := (len(s) + n - 1) / n
	var out []string
	for i := 0; i < len(s); i += size {
		out = append(out, s[i:min(i+size, len(s))])
	}
	return out
}

func (s *Session) Interrupt(context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
	}
}

func (s *Session) Respond(_ context.Context, _ string, d agent.Decision) {
	s.mu.Lock()
	ch := s.approval
	s.approval = nil
	s.mu.Unlock()
	if ch != nil {
		ch <- d
	}
}

func (s *Session) Answer(context.Context, string, map[string]string)              {}
func (s *Session) SetPermissionMode(context.Context, domestiquev1.PermissionMode) {}
func (s *Session) SetModel(context.Context, string)                               {}
func (s *Session) SetEffort(context.Context, string)                              {}

func (s *Session) Shutdown() {
	s.Interrupt(context.Background())
	s.wg.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.closed = true
		close(s.events)
	}
}

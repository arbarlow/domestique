// Package agent defines the interface between a rider and an agent CLI (Claude Code, Codex).
//
// A Session drives one conversation with one provider and emits normalised Events. Transcript items
// use the Race Radio types directly so riders can persist and stream them without conversion.
package agent

import (
	"context"
	"fmt"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// Event is one of the concrete event types below.
type Event interface{ isEvent() }

// Started: the provider assigned or confirmed its session id (Claude session_id / Codex thread id).
type Started struct {
	SessionID string
	Model     string
}

// Upsert inserts or replaces a transcript item by id.
type Upsert struct{ Item *radiov1.TranscriptItem }

// AppendText appends streaming text to an existing item (assistant/reasoning text, or tool output).
type AppendText struct {
	ItemID string
	Delta  string
}

type TurnStarted struct{}

type TurnEnded struct{ Summary *radiov1.TurnSummary }

// Status is a transient status line ("Retrying 2/10…"). Empty clears it.
type Status struct{ Text string }

type Models struct{ Models []*radiov1.ModelOption }

// Exited: the underlying process went away. The next Send restarts and resumes.
type Exited struct{ Message string }

type RateLimit struct{ Info *radiov1.RateLimit }

// Task: a subagent started, progressed or finished.
type Task struct{ Task *radiov1.AgentTask }

// AutoTurnStarted: the agent started a turn on its own (e.g. a background subagent finished).
type AutoTurnStarted struct{ Reason string }

func (Started) isEvent()         {}
func (Upsert) isEvent()          {}
func (AppendText) isEvent()      {}
func (TurnStarted) isEvent()     {}
func (TurnEnded) isEvent()       {}
func (Status) isEvent()          {}
func (Models) isEvent()          {}
func (Exited) isEvent()          {}
func (RateLimit) isEvent()       {}
func (Task) isEvent()            {}
func (AutoTurnStarted) isEvent() {}

// Config starts or resumes a session.
type Config struct {
	Cwd    string
	Model  string // empty = provider default
	Effort string // empty = model default
	Mode   radiov1.PermissionMode
	// Resume this provider session (Claude session id / Codex thread id).
	ResumeSessionID string
	// Extra environment on top of the process environment (workspace ports etc).
	Env map[string]string
	// Extra writable roots for sandboxed modes (e.g. the main repo's .git dir, which worktrees write into).
	ExtraWritableRoots []string
	AppendSystemPrompt string
	// Path or name of the CLI binary. Empty = "claude" / "codex" on PATH.
	Executable string
}

type Attachment struct {
	Data      []byte
	MediaType string
	Filename  string
}

// Decision answers an approval request.
type Decision struct {
	Kind    radiov1.Decision
	Message string // optional reason on deny
}

// Session is one conversation with one agent. Implementations must be safe for concurrent use.
//
// Events() is read by exactly one goroutine (the rider), which drains it promptly. Implementations
// buffer and must never drop Upsert/TurnEnded events.
type Session interface {
	Provider() radiov1.Provider
	Events() <-chan Event
	// Send sends a user message. Starts (or resumes) the provider process if needed. If a turn is
	// running the message is queued or steered into it.
	Send(ctx context.Context, text string, attachments []Attachment) error
	Interrupt(ctx context.Context)
	Respond(ctx context.Context, requestID string, d Decision)
	Answer(ctx context.Context, requestID string, answers map[string]string)
	SetPermissionMode(ctx context.Context, mode radiov1.PermissionMode)
	SetModel(ctx context.Context, model string)
	SetEffort(ctx context.Context, effort string)
	// Shutdown stops the process and closes Events().
	Shutdown()
}

// Factory creates sessions. Registered by provider packages (claude, codex) and by tests.
type Factory func(cfg Config) (Session, error)

// ModelLister returns models offered before a session has started.
type ModelLister func(ctx context.Context) ([]*radiov1.ModelOption, error)

// Registry maps providers to factories.
type Registry struct {
	factories map[radiov1.Provider]Factory
	models    map[radiov1.Provider]ModelLister
}

func NewRegistry() *Registry {
	return &Registry{factories: map[radiov1.Provider]Factory{}, models: map[radiov1.Provider]ModelLister{}}
}

func (r *Registry) Register(p radiov1.Provider, f Factory, models ModelLister) {
	r.factories[p] = f
	if models != nil {
		r.models[p] = models
	}
}

func (r *Registry) New(p radiov1.Provider, cfg Config) (Session, error) {
	f, ok := r.factories[p]
	if !ok {
		return nil, fmt.Errorf("provider %s is not available on this Team Car", p)
	}
	return f(cfg)
}

func (r *Registry) Models(ctx context.Context, p radiov1.Provider) ([]*radiov1.ModelOption, error) {
	m, ok := r.models[p]
	if !ok {
		return nil, nil
	}
	return m(ctx)
}

func (r *Registry) Providers() []radiov1.Provider {
	var out []radiov1.Provider
	for _, p := range []radiov1.Provider{radiov1.Provider_PROVIDER_CLAUDE, radiov1.Provider_PROVIDER_CODEX} {
		if _, ok := r.factories[p]; ok {
			out = append(out, p)
		}
	}
	return out
}

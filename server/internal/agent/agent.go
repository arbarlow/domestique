// Package agent defines the interface between a session and an agent CLI (Claude Code, Codex).
//
// A Session drives one conversation with one provider and emits normalised Events. Transcript items
// use the Domestique protocol types directly so sessions can persist and stream them without conversion.
package agent

import (
	"context"
	"fmt"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

// Event is one of the concrete event types below.
type Event interface{ isEvent() }

// Started: the provider assigned or confirmed its session id (Claude session_id / Codex thread id).
type Started struct {
	SessionID string
	Model     string
}

// Upsert inserts or replaces a transcript item by id.
type Upsert struct{ Item *domestiquev1.TranscriptItem }

// AppendText appends streaming text to an existing item (assistant/reasoning text, or tool output).
type AppendText struct {
	ItemID string
	Delta  string
}

type TurnStarted struct{}

type TurnEnded struct{ Summary *domestiquev1.TurnSummary }

// Status is a transient status line ("Retrying 2/10…"). Empty clears it.
type Status struct{ Text string }

type Models struct{ Models []*domestiquev1.ModelOption }

// Exited: the underlying process went away. The next Send restarts and resumes.
type Exited struct{ Message string }

type RateLimit struct{ Info *domestiquev1.RateLimit }

// Task: a subagent started, progressed or finished.
type Task struct{ Task *domestiquev1.AgentTask }

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
	Mode   domestiquev1.PermissionMode
	// Resume this provider session (Claude session id / Codex thread id).
	ResumeSessionID string
	// Extra environment on top of the process environment (workspace ports etc).
	Env map[string]string
	// Extra writable roots for sandboxed modes (e.g. the main repo's .git dir, which worktrees write into).
	ExtraWritableRoots []string
	AppendSystemPrompt string
	// A Claude --mcp-config file. Empty = none; Codex ignores it.
	McpConfigPath string
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
	Kind    domestiquev1.Decision
	Message string // optional reason on deny
}

// Session is one conversation with one agent. Implementations must be safe for concurrent use.
//
// Events() is read by exactly one goroutine (the session), which drains it promptly. Implementations
// buffer and must never drop Upsert/TurnEnded events.
type Session interface {
	Provider() domestiquev1.Provider
	Events() <-chan Event
	// Send sends a user message. Starts (or resumes) the provider process if needed. If a turn is
	// running the message is queued or steered into it.
	Send(ctx context.Context, text string, attachments []Attachment) error
	Interrupt(ctx context.Context)
	Respond(ctx context.Context, requestID string, d Decision)
	Answer(ctx context.Context, requestID string, answers map[string]string)
	SetPermissionMode(ctx context.Context, mode domestiquev1.PermissionMode)
	SetModel(ctx context.Context, model string)
	SetEffort(ctx context.Context, effort string)
	// Shutdown stops the process and closes Events().
	Shutdown()
}

// Factory creates sessions. Registered by provider packages (claude, codex) and by tests.
type Factory func(cfg Config) (Session, error)

// ModelLister returns models offered before a session has started.
type ModelLister func(ctx context.Context) ([]*domestiquev1.ModelOption, error)

// Registry maps providers to factories.
type Registry struct {
	factories map[domestiquev1.Provider]Factory
	models    map[domestiquev1.Provider]ModelLister
}

func NewRegistry() *Registry {
	return &Registry{factories: map[domestiquev1.Provider]Factory{}, models: map[domestiquev1.Provider]ModelLister{}}
}

func (r *Registry) Register(p domestiquev1.Provider, f Factory, models ModelLister) {
	r.factories[p] = f
	if models != nil {
		r.models[p] = models
	}
}

func (r *Registry) New(p domestiquev1.Provider, cfg Config) (Session, error) {
	f, ok := r.factories[p]
	if !ok {
		return nil, fmt.Errorf("provider %s is not available on this server", p)
	}
	return f(cfg)
}

func (r *Registry) Models(ctx context.Context, p domestiquev1.Provider) ([]*domestiquev1.ModelOption, error) {
	m, ok := r.models[p]
	if !ok {
		return nil, nil
	}
	return m(ctx)
}

func (r *Registry) Providers() []domestiquev1.Provider {
	var out []domestiquev1.Provider
	for _, p := range []domestiquev1.Provider{domestiquev1.Provider_PROVIDER_CLAUDE, domestiquev1.Provider_PROVIDER_CODEX} {
		if _, ok := r.factories[p]; ok {
			out = append(out, p)
		}
	}
	return out
}

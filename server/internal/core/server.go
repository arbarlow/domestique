// Package core is server's engine: repositories, workspaces (git worktrees) and sessions (agent
// sessions), persisted in the store and observable through streams. The radio package exposes it
// over the Domestique protocol; nothing here knows about the network.
package core

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
	"github.com/arbarlow/domestique/server/internal/git"
	"github.com/arbarlow/domestique/server/internal/store"
)

// Typed errors the radio layer maps to error codes.
var (
	ErrNotFound     = errors.New("not found")
	ErrInvalid      = errors.New("invalid argument")
	ErrPrecondition = errors.New("failed precondition")
)

func notFound(what, id string) error { return fmt.Errorf("%w: %s %s", ErrNotFound, what, id) }
func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, a...))
}

type Options struct {
	Name    string
	Version string
	Store   *store.Store
	Agents  *agent.Registry
	// Where worktrees go: <WorkspacesRoot>/<repo>/<name>.
	WorkspacesRoot string
	// Where AddRepository{clone_url} clones to: <ReposRoot>/<name>.
	ReposRoot string
	// New branches are "<BranchPrefix>/<name>" (or just "<name>" when empty).
	BranchPrefix string
	// Port blocks for workspaces come from [PortStart, PortEnd]. Zero = 41000-50999.
	PortStart, PortEnd int32
	// Provider -> CLI path overrides.
	Executables map[domestiquev1.Provider]string
	// Writes the --mcp-config file for this server's own worktrees and returns its path ("" = no servers).
	McpConfigFile func() (string, error)
	Log           *slog.Logger
}

type Server struct {
	opts     Options
	store    *store.Store
	agents   *agent.Registry
	log      *slog.Logger
	serverID string
	server   *stream

	mu         sync.Mutex
	repos      map[string]*domestiquev1.Repository
	workspaces map[string]*domestiquev1.Workspace
	sessions   map[string]*Session
	// Latest published metadata per session. Guarded by mu (not the session's lock) so the server
	// snapshot never takes session locks: sessions lock themselves, then the server, never the reverse.
	sessionMeta  map[string]*domestiquev1.Session
	repoOrder    []string
	wsOrder      []string
	sessionOrder []string
	// Ids of sessions being torn down (CloseSession, DeleteWorkspace): not reusable until their
	// transcript is gone, so a reopened id never inherits or loses rows.
	closing map[string]bool
	// creation goroutines, so Shutdown can wait.
	wg sync.WaitGroup
}

func New(opts Options) (*Server, error) {
	if opts.Log == nil {
		opts.Log = slog.Default()
	}
	if opts.PortStart == 0 {
		opts.PortStart = DefaultPortStart
	}
	if opts.PortEnd == 0 {
		opts.PortEnd = DefaultPortEnd
	}
	if opts.PortEnd < opts.PortStart+portCount-1 || opts.PortEnd > 65535 {
		return nil, fmt.Errorf("invalid port range %d-%d", opts.PortStart, opts.PortEnd)
	}
	if opts.Agents == nil {
		opts.Agents = agent.NewRegistry()
	}
	if opts.Name == "" {
		h, _ := os.Hostname()
		opts.Name = h
	}
	c := &Server{
		opts: opts, store: opts.Store, agents: opts.Agents, log: opts.Log, server: newStream(),
		repos: map[string]*domestiquev1.Repository{}, workspaces: map[string]*domestiquev1.Workspace{}, sessions: map[string]*Session{}, sessionMeta: map[string]*domestiquev1.Session{},
		closing: map[string]bool{},
	}
	id, err := c.store.ServerID(context.Background())
	if err != nil {
		return nil, err
	}
	c.serverID = id
	if err := c.load(); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Server) load() error {
	repos, err := c.store.Repositories()
	if err != nil {
		return err
	}
	for _, r := range repos {
		c.repos[r.Id] = r
		c.repoOrder = append(c.repoOrder, r.Id)
	}
	wss, err := c.store.Workspaces()
	if err != nil {
		return err
	}
	for _, w := range wss {
		// Creation was interrupted by a restart.
		if w.State == domestiquev1.WorkspaceState_WORKSPACE_STATE_CREATING || w.State == domestiquev1.WorkspaceState_WORKSPACE_STATE_SETTING_UP {
			w.State = domestiquev1.WorkspaceState_WORKSPACE_STATE_FAILED
			w.Failure = "Server restarted while this workspace was being created"
			_ = c.store.PutWorkspace(w)
		}
		c.workspaces[w.Id] = w
		c.wsOrder = append(c.wsOrder, w.Id)
	}
	sessions, err := c.store.Sessions()
	if err != nil {
		return err
	}
	for _, m := range sessions {
		if m.ClosedAtMs != 0 {
			continue // Only ReopenSession brings these back.
		}
		last, err := c.store.LastSeq(m.Id)
		if err != nil {
			return err
		}
		m.LastSeq = last
		wasActive := m.Activity != domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE && m.Activity != domestiquev1.SessionActivity_SESSION_ACTIVITY_UNSPECIFIED
		m.Activity = domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE
		m.Status = ""
		r := newSession(c, m)
		if wasActive {
			// The agent died with the server: settle whatever it left mid-flight.
			entries, err := c.store.ItemsAfter(m.Id, 0, 0)
			if err != nil {
				return err
			}
			r.mu.Lock()
			for _, e := range entries {
				if s := settled(e.Item); s != nil {
					r.items[s.Id] = e.Item
					r.upsertLocked(s)
				}
			}
			r.mu.Unlock()
		}
		_ = c.store.PutSession(m)
		c.sessions[m.Id] = r
		c.sessionMeta[m.Id] = proto.Clone(m).(*domestiquev1.Session)
		c.sessionOrder = append(c.sessionOrder, m.Id)
	}
	return nil
}

// Shutdown stops every agent. Workspaces and transcripts stay on disk.
func (c *Server) Shutdown() {
	c.mu.Lock()
	sessions := make([]*Session, 0, len(c.sessions))
	for _, r := range c.sessions {
		sessions = append(sessions, r)
	}
	c.mu.Unlock()
	var wg sync.WaitGroup
	for _, r := range sessions {
		wg.Add(1)
		go func() { defer wg.Done(); r.shutdown() }()
	}
	wg.Wait()
	c.server.closeAll()
}

// ---- info and server stream

func (c *Server) ServerID() string   { return c.serverID }
func (c *Server) ServerName() string { return c.opts.Name }
func (c *Server) Version() string    { return c.opts.Version }

func (c *Server) Info() *domestiquev1.ServerInfo {
	return &domestiquev1.ServerInfo{
		ServerId: c.serverID, ServerName: c.opts.Name, ServerVersion: c.opts.Version,
		Platform: runtime.GOOS + "/" + runtime.GOARCH, WorkspacesRoot: c.opts.WorkspacesRoot,
		Providers: c.agents.Providers(),
	}
}

// SubscribeServer returns a consistent snapshot and a subscriber for changes after it.
func (c *Server) SubscribeServer() (*domestiquev1.ServerSnapshot, *Subscriber) {
	c.mu.Lock()
	defer c.mu.Unlock()
	snap := &domestiquev1.ServerSnapshot{}
	for _, id := range c.repoOrder {
		snap.Repositories = append(snap.Repositories, proto.Clone(c.repos[id]).(*domestiquev1.Repository))
	}
	for _, id := range c.wsOrder {
		snap.Workspaces = append(snap.Workspaces, proto.Clone(c.workspaces[id]).(*domestiquev1.Workspace))
	}
	for _, id := range c.sessionOrder {
		snap.Sessions = append(snap.Sessions, proto.Clone(c.sessionMeta[id]).(*domestiquev1.Session))
	}
	// Every server-stream publish happens under c.mu, so nothing slips between the snapshot and
	// the subscription, and nothing older than the snapshot arrives after it.
	return snap, c.server.add()
}

func (c *Server) publishServer(ev *domestiquev1.Event) { c.server.publish(ev) }

// publishSession records and broadcasts a session's metadata. Takes c.mu; sessions call it while
// holding their own lock (session -> server is the only allowed lock order).
func (c *Server) publishSession(m *domestiquev1.Session) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.publishSessionLocked(m)
}

func (c *Server) publishSessionLocked(m *domestiquev1.Session) {
	if _, ok := c.sessions[m.Id]; !ok {
		return // closed
	}
	c.sessionMeta[m.Id] = m
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_SessionUpserted{SessionUpserted: proto.Clone(m).(*domestiquev1.Session)}})
}

// ---- repositories

func (c *Server) Repositories() []*domestiquev1.Repository {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]*domestiquev1.Repository, 0, len(c.repoOrder))
	for _, id := range c.repoOrder {
		out = append(out, proto.Clone(c.repos[id]).(*domestiquev1.Repository))
	}
	return out
}

var safeName = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// repoNameFromURL turns "git@github.com:acme/api.git" into "api".
func repoNameFromURL(u string) string {
	u = strings.TrimSuffix(strings.TrimRight(u, "/"), ".git")
	if i := strings.LastIndexAny(u, "/:"); i >= 0 {
		u = u[i+1:]
	}
	return safeName.ReplaceAllString(u, "-")
}

func (c *Server) AddRepository(ctx context.Context, req *domestiquev1.AddRepository) (*domestiquev1.Repository, error) {
	path := req.Path
	switch {
	case req.Path != "" && req.CloneUrl != "":
		return nil, invalid("set path or clone_url, not both")
	case req.Path == "" && req.CloneUrl == "":
		return nil, invalid("path or clone_url is required")
	case req.CloneUrl != "":
		name := req.Name
		if name == "" {
			name = repoNameFromURL(req.CloneUrl)
		}
		if name == "" || safeName.MatchString(name) {
			return nil, invalid("invalid repository name %q", name)
		}
		path = filepath.Join(c.opts.ReposRoot, name)
		if _, err := os.Stat(path); err == nil {
			if existing := c.repoByPath(path); existing != nil {
				return existing, nil
			}
		} else if err := git.Clone(ctx, req.CloneUrl, path); err != nil {
			return nil, err
		}
	default:
		path = expandHome(path)
	}
	info, err := git.Info(ctx, path)
	if err != nil {
		return nil, invalid("%s is not a git repository: %v", path, err)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, r := range c.repos {
		if r.Path == info.Root {
			return proto.Clone(r).(*domestiquev1.Repository), nil
		}
	}
	id := req.Id
	if id == "" {
		id = uuid.NewString()
	} else if _, taken := c.repos[id]; taken {
		return nil, invalid("repository id %s is already in use", id)
	}
	repo := &domestiquev1.Repository{
		Id: id, Name: safeName.ReplaceAllString(filepath.Base(info.Root), "-"), Path: info.Root,
		RemoteUrl: info.RemoteURL, DefaultBranch: info.DefaultBranch,
		ShipMode: domestiquev1.ShipMode_SHIP_MODE_PULL_REQUEST, CreatedAtMs: time.Now().UnixMilli(),
	}
	if err := c.store.PutRepository(repo); err != nil {
		return nil, err
	}
	c.repos[repo.Id] = repo
	c.repoOrder = append(c.repoOrder, repo.Id)
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_RepositoryUpserted{RepositoryUpserted: proto.Clone(repo).(*domestiquev1.Repository)}})
	return proto.Clone(repo).(*domestiquev1.Repository), nil
}

func (c *Server) repoByPath(path string) *domestiquev1.Repository {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, r := range c.repos {
		if r.Path == path {
			return proto.Clone(r).(*domestiquev1.Repository)
		}
	}
	return nil
}

func (c *Server) RemoveRepository(id string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.repos[id]; !ok {
		return notFound("repository", id)
	}
	for _, w := range c.workspaces {
		if w.RepositoryId == id && w.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
			return fmt.Errorf("%w: archive the repository's workspaces first", ErrPrecondition)
		}
	}
	if err := c.store.DeleteRepository(id); err != nil {
		return err
	}
	delete(c.repos, id)
	c.repoOrder = remove(c.repoOrder, id)
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_RepositoryRemoved{RepositoryRemoved: id}})
	return nil
}

// ---- workspaces

func (c *Server) Workspaces(repoID string, includeArchived bool) []*domestiquev1.Workspace {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []*domestiquev1.Workspace
	for _, id := range c.wsOrder {
		w := c.workspaces[id]
		if repoID != "" && w.RepositoryId != repoID {
			continue
		}
		if !includeArchived && w.State == domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
			continue
		}
		out = append(out, proto.Clone(w).(*domestiquev1.Workspace))
	}
	return out
}

func (c *Server) Workspace(id string) (*domestiquev1.Workspace, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	w, ok := c.workspaces[id]
	if !ok {
		return nil, notFound("workspace", id)
	}
	return proto.Clone(w).(*domestiquev1.Workspace), nil
}

// WorkspaceEnv returns a workspace's path and the environment its scripts, tasks and processes
// get (DOMESTIQUE_PORT and friends).
func (c *Server) WorkspaceEnv(id string) (string, map[string]string, error) {
	ws, repo, err := c.workspaceAndRepo(id)
	if err != nil {
		return "", nil, err
	}
	return ws.Path, workspaceEnv(ws, repo), nil
}

func (c *Server) workspaceAndRepo(id string) (*domestiquev1.Workspace, *domestiquev1.Repository, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	w, ok := c.workspaces[id]
	if !ok {
		return nil, nil, notFound("workspace", id)
	}
	r, ok := c.repos[w.RepositoryId]
	if !ok {
		return nil, nil, notFound("repository", w.RepositoryId)
	}
	return proto.Clone(w).(*domestiquev1.Workspace), proto.Clone(r).(*domestiquev1.Repository), nil
}

// updateWorkspace applies fn under the lock, persists and publishes.
func (c *Server) updateWorkspace(id string, fn func(w *domestiquev1.Workspace)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	w, ok := c.workspaces[id]
	if !ok {
		return
	}
	fn(w)
	if err := c.store.PutWorkspace(w); err != nil {
		c.log.Error("persist workspace", "workspace", id, "err", err)
	}
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_WorkspaceUpserted{WorkspaceUpserted: proto.Clone(w).(*domestiquev1.Workspace)}})
}

func (c *Server) markUnread(wsID string) {
	go c.updateWorkspace(wsID, func(w *domestiquev1.Workspace) { w.HasUnread = true })
}

// CreateWorkspace registers the workspace in CREATING state and returns it at once. A goroutine
// then fetches, creates the worktree, runs setup and (when a prompt is given) sends it to the
// session. Progress arrives on the server stream.
//
// A session is opened (and returned, so callers can subscribe immediately) when req.Session is set,
// or with defaults when only a prompt is given.
func (c *Server) CreateWorkspace(ctx context.Context, req *domestiquev1.CreateWorkspace) (*domestiquev1.Workspace, *domestiquev1.Session, error) {
	if req.Branch != "" && !git.ValidBranchName(ctx, req.Branch) {
		return nil, nil, invalid("invalid branch name %q", req.Branch)
	}
	var sessionReq *domestiquev1.OpenSession
	if req.Session != nil {
		sessionReq = proto.Clone(req.Session).(*domestiquev1.OpenSession)
	} else if req.Prompt != "" {
		sessionReq = &domestiquev1.OpenSession{}
	}

	c.mu.Lock()
	repo, ok := c.repos[req.RepositoryId]
	if !ok {
		c.mu.Unlock()
		return nil, nil, notFound("repository", req.RepositoryId)
	}
	repo = proto.Clone(repo).(*domestiquev1.Repository)
	if req.Id != "" {
		if _, taken := c.workspaces[req.Id]; taken {
			c.mu.Unlock()
			return nil, nil, invalid("workspace id %s is already in use", req.Id)
		}
	}
	if sessionReq != nil && sessionReq.Id != "" {
		if err := c.sessionIDFreeLocked(sessionReq.Id); err != nil {
			c.mu.Unlock()
			return nil, nil, err
		}
	}
	used := map[string]bool{}
	usedPorts := map[int32]bool{}
	for _, w := range c.workspaces {
		if w.RepositoryId == repo.Id {
			used[w.Name] = true
		}
		if w.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
			usedPorts[w.PortBase] = true
		}
	}
	name := req.Name
	if name == "" {
		name = nextName(used)
	} else if safeName.MatchString(name) || used[name] {
		c.mu.Unlock()
		return nil, nil, invalid("workspace name %q is invalid or taken", name)
	}
	base := req.BaseBranch
	if base == "" {
		base = repo.DefaultBranch
	}
	branch := req.Branch
	if branch == "" {
		branch = name
		if p := strings.Trim(c.opts.BranchPrefix, " /"); p != "" {
			branch = p + "/" + name
		}
	}
	id := req.Id
	if id == "" {
		id = uuid.NewString()
	}
	ws := &domestiquev1.Workspace{
		Id: id, RepositoryId: repo.Id, Name: name, Branch: branch,
		Path: filepath.Join(c.opts.WorkspacesRoot, repo.Name, name), BaseBranch: base,
		PortBase: allocatePorts(usedPorts, c.opts.PortStart, c.opts.PortEnd), State: domestiquev1.WorkspaceState_WORKSPACE_STATE_CREATING,
		CreatedAtMs: time.Now().UnixMilli(),
	}
	if err := c.store.PutWorkspace(ws); err != nil {
		c.mu.Unlock()
		return nil, nil, err
	}
	c.workspaces[ws.Id] = ws
	c.wsOrder = append(c.wsOrder, ws.Id)
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_WorkspaceUpserted{WorkspaceUpserted: proto.Clone(ws).(*domestiquev1.Workspace)}})
	snapshot := proto.Clone(ws).(*domestiquev1.Workspace)
	var session *Session
	if sessionReq != nil {
		sessionReq.WorkspaceId = ws.Id
		var err error
		if session, err = c.openSessionLocked(sessionReq); err != nil {
			// Validated above, so only a store failure gets here: undo the registration.
			delete(c.workspaces, ws.Id)
			c.wsOrder = remove(c.wsOrder, ws.Id)
			_ = c.store.DeleteWorkspace(ws.Id)
			c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_WorkspaceRemoved{WorkspaceRemoved: ws.Id}})
			c.mu.Unlock()
			return nil, nil, err
		}
	}
	c.mu.Unlock()

	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		// Creation outlives the request that started it.
		bg := context.WithoutCancel(ctx)
		if err := c.provision(bg, ws.Id, repo, req.SkipSetup); err != nil {
			c.log.Warn("workspace creation failed", "workspace", ws.Name, "err", err)
			c.updateWorkspace(ws.Id, func(w *domestiquev1.Workspace) {
				w.State = domestiquev1.WorkspaceState_WORKSPACE_STATE_FAILED
				w.Failure = err.Error()
			})
			if session != nil {
				session.mu.Lock()
				session.errorLocked("Workspace creation failed: " + err.Error())
				session.mu.Unlock()
			}
			return
		}
		if session != nil && req.Prompt != "" {
			if err := session.Send(bg, req.Prompt, nil); err != nil {
				c.log.Warn("first prompt failed", "workspace", ws.Name, "err", err)
			}
		}
	}()
	var meta *domestiquev1.Session
	if session != nil {
		meta = session.Meta()
	}
	return snapshot, meta, nil
}

// provision: fresh worktree branched from a just-fetched origin/<base>, then setup. skipScript
// skips [setup].script (the client runs it) but still copies [setup].copy files.
func (c *Server) provision(ctx context.Context, wsID string, repo *domestiquev1.Repository, skipScript bool) error {
	ws, _, err := c.workspaceAndRepo(wsID)
	if err != nil {
		return err
	}
	base := ws.BaseBranch
	if git.HasRemote(ctx, repo.Path) {
		if err := git.Fetch(ctx, repo.Path, ws.BaseBranch); err != nil {
			return err
		}
		base = "origin/" + ws.BaseBranch
	}
	sha, err := git.CreateWorktree(ctx, repo.Path, ws.Path, ws.Branch, base)
	if err != nil {
		return err
	}
	c.updateWorkspace(wsID, func(w *domestiquev1.Workspace) {
		w.BaseCommit = sha
		w.State = domestiquev1.WorkspaceState_WORKSPACE_STATE_SETTING_UP
	})
	cfg, err := loadRepoConfig(ws.Path)
	if err != nil {
		return fmt.Errorf("domestique.toml: %w", err)
	}
	for _, f := range cfg.Setup.Copy {
		copyIfExists(filepath.Join(repo.Path, f), filepath.Join(ws.Path, f))
	}
	if !skipScript && strings.TrimSpace(cfg.Setup.Script) != "" {
		ws, repo, err := c.workspaceAndRepo(wsID)
		if err != nil {
			return err
		}
		if err := runScript(ctx, ws.Path, cfg.Setup.Script, workspaceEnv(ws, repo)); err != nil {
			return fmt.Errorf("setup script: %w", err)
		}
	}
	c.updateWorkspace(wsID, func(w *domestiquev1.Workspace) { w.State = domestiquev1.WorkspaceState_WORKSPACE_STATE_READY })
	return nil
}

func runScript(ctx context.Context, dir, script string, env map[string]string) error {
	shell := os.Getenv("SHELL")
	if !strings.HasSuffix(shell, "/zsh") && !strings.HasSuffix(shell, "/bash") {
		shell = "/bin/bash"
	}
	cmd := exec.CommandContext(ctx, shell, "-c", script)
	cmd.Dir = dir
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		tail := string(out)
		if len(tail) > 2000 {
			tail = tail[len(tail)-2000:]
		}
		return fmt.Errorf("%v\n%s", err, strings.TrimSpace(tail))
	}
	return nil
}

func copyIfExists(src, dst string) {
	data, err := os.ReadFile(src)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(dst), 0o755)
	_ = os.WriteFile(dst, data, 0o644)
}

// ArchiveWorkspace stops its sessions, runs the archive script (unless skipped) and removes the
// worktree.
func (c *Server) ArchiveWorkspace(ctx context.Context, req *domestiquev1.ArchiveWorkspace) (*domestiquev1.Workspace, error) {
	id, deleteBranch := req.WorkspaceId, req.DeleteBranch
	ws, repo, err := c.workspaceAndRepo(id)
	if err != nil {
		return nil, err
	}
	for _, r := range c.sessionsFor(id) {
		r.stopAgent()
	}
	if req.SkipArchiveScript {
		// The client already ran it.
	} else if cfg, err := loadRepoConfig(ws.Path); err == nil && strings.TrimSpace(cfg.Archive.Script) != "" {
		if err := runScript(ctx, ws.Path, cfg.Archive.Script, workspaceEnv(ws, repo)); err != nil {
			c.log.Warn("archive script failed", "workspace", ws.Name, "err", err)
		}
	}
	if err := git.RemoveWorktree(ctx, repo.Path, ws.Path, true); err != nil {
		return nil, err
	}
	if deleteBranch {
		if err := git.DeleteBranch(ctx, repo.Path, ws.Branch); err != nil {
			c.log.Warn("delete branch failed", "branch", ws.Branch, "err", err)
		}
	}
	c.updateWorkspace(id, func(w *domestiquev1.Workspace) { w.State = domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED })
	// An archived workspace can't reopen anything, so closed chats end here.
	if err := c.store.DeleteClosedSessions(id); err != nil {
		c.log.Warn("delete closed sessions failed", "workspace", ws.Name, "err", err)
	}
	return c.Workspace(id)
}

// DeleteWorkspace forgets an archived workspace: its sessions, their transcripts and the workspace
// itself. Removals are published on the server stream (sessions first).
func (c *Server) DeleteWorkspace(ctx context.Context, id string, deleteBranch bool) error {
	c.mu.Lock()
	w, ok := c.workspaces[id]
	if !ok {
		c.mu.Unlock()
		return notFound("workspace", id)
	}
	if w.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		c.mu.Unlock()
		return fmt.Errorf("%w: archive the workspace before deleting it", ErrPrecondition)
	}
	var sessions []*Session
	for _, rid := range slices.Clone(c.sessionOrder) {
		if m := c.sessionMeta[rid]; m == nil || m.WorkspaceId != id {
			continue
		}
		sessions = append(sessions, c.sessions[rid])
		delete(c.sessions, rid)
		delete(c.sessionMeta, rid)
		c.sessionOrder = remove(c.sessionOrder, rid)
		c.closing[rid] = true
		c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_SessionRemoved{SessionRemoved: rid}})
	}
	delete(c.workspaces, id)
	c.wsOrder = remove(c.wsOrder, id)
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_WorkspaceRemoved{WorkspaceRemoved: id}})
	var repoPath string
	if r, ok := c.repos[w.RepositoryId]; ok {
		repoPath = r.Path
	}
	c.mu.Unlock()

	// Stop the sessions (flushing any streamed text) before their rows go.
	for _, r := range sessions {
		r.shutdown()
	}
	err := c.store.DeleteWorkspace(id)
	c.mu.Lock()
	for _, r := range sessions {
		delete(c.closing, r.id())
	}
	c.mu.Unlock()
	if err != nil {
		return err
	}
	if deleteBranch && repoPath != "" && w.Branch != "" {
		if err := git.DeleteBranch(ctx, repoPath, w.Branch); err != nil {
			c.log.Warn("delete branch failed", "branch", w.Branch, "err", err)
		}
	}
	return nil
}

// ImportWorkspace registers a workspace that already exists on this host, with its sessions and
// their transcripts, keeping every id. An already-registered workspace id is returned unchanged.
func (c *Server) ImportWorkspace(req *domestiquev1.ImportWorkspace) (*domestiquev1.Workspace, error) {
	in := req.Workspace
	if in == nil || in.Id == "" {
		return nil, invalid("workspace.id is required")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if w, ok := c.workspaces[in.Id]; ok {
		return proto.Clone(w).(*domestiquev1.Workspace), nil
	}
	repo, ok := c.repos[in.RepositoryId]
	if !ok {
		return nil, notFound("repository", in.RepositoryId)
	}
	now := time.Now().UnixMilli()
	ws := &domestiquev1.Workspace{
		Id: in.Id, RepositoryId: repo.Id, Name: in.Name, Branch: in.Branch, Path: in.Path,
		BaseBranch: in.BaseBranch, BaseCommit: in.BaseCommit, PortBase: in.PortBase, State: in.State,
		CreatedAtMs: in.CreatedAtMs,
	}
	switch ws.State {
	case domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED, domestiquev1.WorkspaceState_WORKSPACE_STATE_READY:
	case domestiquev1.WorkspaceState_WORKSPACE_STATE_FAILED:
		ws.Failure = in.Failure
	default:
		// CREATING / SETTING_UP (or unset): whatever was creating it is gone; it exists now.
		ws.State = domestiquev1.WorkspaceState_WORKSPACE_STATE_READY
	}
	if ws.Name == "" && ws.Path != "" {
		ws.Name = filepath.Base(ws.Path)
	}
	if ws.Name == "" {
		return nil, invalid("workspace.name or workspace.path is required")
	}
	if ws.BaseBranch == "" {
		ws.BaseBranch = repo.DefaultBranch
	}
	if ws.CreatedAtMs == 0 {
		ws.CreatedAtMs = now
	}
	if ws.PortBase == 0 && ws.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		usedPorts := map[int32]bool{}
		for _, w := range c.workspaces {
			if w.State != domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
				usedPorts[w.PortBase] = true
			}
		}
		ws.PortBase = allocatePorts(usedPorts, c.opts.PortStart, c.opts.PortEnd)
	}

	imported := make([]store.ImportedSession, 0, len(req.Sessions))
	seen := map[string]bool{}
	for _, ir := range req.Sessions {
		m := ir.GetSession()
		if m == nil || m.Id == "" {
			return nil, invalid("every session needs an id")
		}
		if seen[m.Id] {
			return nil, invalid("session id %s appears twice", m.Id)
		}
		seen[m.Id] = true
		if err := c.sessionIDFreeLocked(m.Id); err != nil {
			return nil, err
		}
		meta := &domestiquev1.Session{
			Id: m.Id, WorkspaceId: ws.Id, Title: m.Title, Provider: m.Provider, Model: m.Model, Effort: m.Effort,
			PermissionMode: m.PermissionMode, ProviderSessionId: m.ProviderSessionId, CreatedAtMs: m.CreatedAtMs,
			Activity: domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE,
		}
		if meta.Provider == domestiquev1.Provider_PROVIDER_UNSPECIFIED {
			meta.Provider = domestiquev1.Provider_PROVIDER_CLAUDE
		}
		if meta.PermissionMode == domestiquev1.PermissionMode_PERMISSION_MODE_UNSPECIFIED {
			meta.PermissionMode = domestiquev1.PermissionMode_PERMISSION_MODE_BYPASS
		}
		if meta.Title == "" {
			meta.Title = "New chat"
		}
		if meta.CreatedAtMs == 0 {
			meta.CreatedAtMs = now
		}
		items := make([]*domestiquev1.TranscriptItem, 0, len(ir.Items))
		itemIDs := map[string]bool{}
		for _, it := range ir.Items {
			if it == nil || it.Id == "" {
				return nil, invalid("session %s: every transcript item needs an id", m.Id)
			}
			if itemIDs[it.Id] {
				return nil, invalid("session %s: item id %s appears twice", m.Id, it.Id)
			}
			itemIDs[it.Id] = true
			// No agent is running for an imported session: settle anything left mid-flight.
			if fixed := settled(it); fixed != nil {
				it = fixed
			} else {
				it = proto.Clone(it).(*domestiquev1.TranscriptItem)
			}
			items = append(items, it)
		}
		imported = append(imported, store.ImportedSession{Session: meta, Items: items})
	}

	last, err := c.store.ImportWorkspace(ws, imported)
	if err != nil {
		return nil, err
	}
	c.workspaces[ws.Id] = ws
	c.wsOrder = append(c.wsOrder, ws.Id)
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_WorkspaceUpserted{WorkspaceUpserted: proto.Clone(ws).(*domestiquev1.Workspace)}})
	for i, ir := range imported {
		meta := ir.Session
		meta.LastSeq = last[i]
		c.sessions[meta.Id] = newSession(c, meta)
		c.sessionOrder = append(c.sessionOrder, meta.Id)
		c.publishSessionLocked(proto.Clone(meta).(*domestiquev1.Session))
	}
	return proto.Clone(ws).(*domestiquev1.Workspace), nil
}

// ---- sessions

func (c *Server) Sessions(workspaceID string) []*domestiquev1.Session {
	var out []*domestiquev1.Session
	for _, r := range c.sessionsFor(workspaceID) {
		out = append(out, r.Meta())
	}
	return out
}

func (c *Server) sessionsFor(workspaceID string) []*Session {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []*Session
	for _, id := range c.sessionOrder {
		if r := c.sessions[id]; workspaceID == "" || r.meta.WorkspaceId == workspaceID {
			out = append(out, r)
		}
	}
	return out
}

func (c *Server) Session(id string) (*Session, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.sessions[id]
	if !ok {
		return nil, notFound("session", id)
	}
	return r, nil
}

func (c *Server) OpenSession(req *domestiquev1.OpenSession) (*domestiquev1.Session, error) {
	r, err := c.openSession(req)
	if err != nil {
		return nil, err
	}
	return r.Meta(), nil
}

func (c *Server) openSession(req *domestiquev1.OpenSession) (*Session, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.openSessionLocked(req)
}

// sessionIDFreeLocked checks a client-chosen session id isn't in use.
func (c *Server) sessionIDFreeLocked(id string) error {
	if _, taken := c.sessions[id]; taken {
		return invalid("session id %s is already in use", id)
	}
	if c.closing[id] {
		return invalid("session %s is still closing", id)
	}
	return nil
}

// openSessionLocked validates, persists, registers and publishes a new session. Caller holds c.mu.
func (c *Server) openSessionLocked(req *domestiquev1.OpenSession) (*Session, error) {
	provider := req.Provider
	if provider == domestiquev1.Provider_PROVIDER_UNSPECIFIED {
		provider = domestiquev1.Provider_PROVIDER_CLAUDE
	}
	mode := req.PermissionMode
	if mode == domestiquev1.PermissionMode_PERMISSION_MODE_UNSPECIFIED {
		mode = domestiquev1.PermissionMode_PERMISSION_MODE_BYPASS
	}
	title := req.Title
	if title == "" {
		title = "New chat"
	}
	id := req.Id
	if id == "" {
		id = uuid.NewString()
	} else if err := c.sessionIDFreeLocked(id); err != nil {
		return nil, err
	}
	meta := &domestiquev1.Session{
		Id: id, WorkspaceId: req.WorkspaceId, Title: title, Provider: provider,
		Model: req.Model, Effort: req.Effort, PermissionMode: mode, CreatedAtMs: time.Now().UnixMilli(),
		Activity: domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE,
	}
	w, ok := c.workspaces[req.WorkspaceId]
	if !ok {
		return nil, notFound("workspace", req.WorkspaceId)
	}
	if w.State == domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		return nil, fmt.Errorf("%w: workspace is archived", ErrPrecondition)
	}
	if err := c.store.PutSession(meta); err != nil {
		return nil, err
	}
	r := newSession(c, meta)
	c.sessions[meta.Id] = r
	c.sessionOrder = append(c.sessionOrder, meta.Id)
	c.publishSessionLocked(proto.Clone(meta).(*domestiquev1.Session))
	return r, nil
}

// CloseSession stops a session and deletes it, or with keepHistory sets it aside for ReopenSession.
func (c *Server) CloseSession(id string, keepHistory bool) error {
	c.mu.Lock()
	r, ok := c.sessions[id]
	if ok {
		delete(c.sessions, id)
		delete(c.sessionMeta, id)
		c.sessionOrder = remove(c.sessionOrder, id)
		c.closing[id] = true
		c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_SessionRemoved{SessionRemoved: id}})
	}
	c.mu.Unlock()
	if !ok {
		return notFound("session", id)
	}
	r.shutdown()
	var err error
	if keepHistory {
		meta := r.Meta()
		meta.ClosedAtMs = time.Now().UnixMilli()
		meta.Activity = domestiquev1.SessionActivity_SESSION_ACTIVITY_IDLE
		meta.Status = ""
		err = c.store.PutSession(meta)
	} else {
		err = c.store.DeleteSession(id)
	}
	c.mu.Lock()
	delete(c.closing, id)
	c.mu.Unlock()
	return err
}

// ReopenSession brings back a session closed with its history kept.
func (c *Server) ReopenSession(id string) (*domestiquev1.Session, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.sessionIDFreeLocked(id); err != nil {
		return nil, err
	}
	meta, err := c.store.Session(id)
	if err != nil {
		return nil, err
	}
	if meta == nil || meta.ClosedAtMs == 0 {
		return nil, notFound("session", id)
	}
	w, ok := c.workspaces[meta.WorkspaceId]
	if !ok {
		return nil, notFound("workspace", meta.WorkspaceId)
	}
	if w.State == domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		return nil, fmt.Errorf("%w: workspace is archived", ErrPrecondition)
	}
	if meta.LastSeq, err = c.store.LastSeq(id); err != nil {
		return nil, err
	}
	meta.ClosedAtMs = 0
	if err := c.store.PutSession(meta); err != nil {
		return nil, err
	}
	r := newSession(c, meta)
	c.sessions[id] = r
	c.sessionOrder = append(c.sessionOrder, id)
	c.publishSessionLocked(proto.Clone(meta).(*domestiquev1.Session))
	return r.Meta(), nil
}

func (c *Server) Models(ctx context.Context, p domestiquev1.Provider) ([]*domestiquev1.ModelOption, error) {
	return c.agents.Models(ctx, p)
}

func (c *Server) executable(p domestiquev1.Provider) string { return c.opts.Executables[p] }

// ---- code

func (c *Server) Diff(ctx context.Context, wsID, path string) (*domestiquev1.Diff, error) {
	ws, _, err := c.workspaceAndRepo(wsID)
	if err != nil {
		return nil, err
	}
	base := ws.BaseBranch
	if git.HasRemote(ctx, ws.Path) {
		base = "origin/" + ws.BaseBranch
	}
	mb, files, err := git.Diff(ctx, ws.Path, base)
	if err != nil {
		return nil, err
	}
	out := &domestiquev1.Diff{Base: mb}
	if a, b, err := git.AheadBehind(ctx, ws.Path, base); err == nil {
		out.Ahead, out.Behind = int32(a), int32(b)
	}
	for _, f := range files {
		if path != "" && f.Path != path {
			continue
		}
		out.Files = append(out.Files, &domestiquev1.FileDiff{
			Path: f.Path, OldPath: f.OldPath, Status: diffStatus(f.Status), Additions: int32(f.Additions),
			Deletions: int32(f.Deletions), Patch: f.Patch, Binary: f.Binary,
		})
	}
	return out, nil
}

func diffStatus(s git.FileStatus) domestiquev1.FileDiffStatus {
	switch s {
	case git.Added:
		return domestiquev1.FileDiffStatus_FILE_DIFF_STATUS_ADDED
	case git.Deleted:
		return domestiquev1.FileDiffStatus_FILE_DIFF_STATUS_DELETED
	case git.Renamed:
		return domestiquev1.FileDiffStatus_FILE_DIFF_STATUS_RENAMED
	default:
		return domestiquev1.FileDiffStatus_FILE_DIFF_STATUS_MODIFIED
	}
}

func (c *Server) ListFiles(ctx context.Context, wsID string) ([]string, error) {
	ws, err := c.Workspace(wsID)
	if err != nil {
		return nil, err
	}
	return git.ListFiles(ctx, ws.Path)
}

// DefaultMaxRead caps ReadFile when the client doesn't ask for less.
const DefaultMaxRead = 2 << 20

// ReadFile reads a file inside the workspace. Paths may not escape the worktree.
func (c *Server) ReadFile(wsID, rel string, maxBytes int64) (*domestiquev1.FileContent, error) {
	ws, err := c.Workspace(wsID)
	if err != nil {
		return nil, err
	}
	if maxBytes <= 0 || maxBytes > DefaultMaxRead {
		maxBytes = DefaultMaxRead
	}
	root, err := filepath.EvalSymlinks(ws.Path)
	if err != nil {
		return nil, err
	}
	full, err := filepath.EvalSymlinks(filepath.Join(root, filepath.Clean("/"+rel)))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, notFound("file", rel)
		}
		return nil, err
	}
	if full != root && !strings.HasPrefix(full, root+string(filepath.Separator)) {
		return nil, invalid("path escapes the workspace")
	}
	st, err := os.Stat(full)
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		return nil, invalid("%s is a directory", rel)
	}
	if st.Size() > maxBytes {
		return nil, fmt.Errorf("%w: file is %d bytes (limit %d)", ErrPrecondition, st.Size(), maxBytes)
	}
	data, err := os.ReadFile(full)
	if err != nil {
		return nil, err
	}
	return &domestiquev1.FileContent{Path: rel, Data: data, Size: st.Size()}, nil
}

// ---- helpers

func remove(s []string, id string) []string {
	out := s[:0]
	for _, v := range s {
		if v != id {
			out = append(out, v)
		}
	}
	return out
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if h, err := os.UserHomeDir(); err == nil {
			return filepath.Join(h, strings.TrimPrefix(p, "~"))
		}
	}
	return p
}

// Package core is Team Car's engine: repositories, workspaces (git worktrees) and riders (agent
// sessions), persisted in the store and observable through streams. The radio package exposes it
// over Race Radio; nothing here knows about the network.
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

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/agent"
	"github.com/arbarlow/domestique/teamcar/internal/git"
	"github.com/arbarlow/domestique/teamcar/internal/store"
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
	Executables map[radiov1.Provider]string
	Log         *slog.Logger
}

type Car struct {
	opts     Options
	store    *store.Store
	agents   *agent.Registry
	log      *slog.Logger
	serverID string
	server   *stream

	mu         sync.Mutex
	repos      map[string]*radiov1.Repository
	workspaces map[string]*radiov1.Workspace
	riders     map[string]*Rider
	// Latest published metadata per rider. Guarded by mu (not the rider's lock) so the server
	// snapshot never takes rider locks: riders lock themselves, then the car, never the reverse.
	riderMeta  map[string]*radiov1.Rider
	repoOrder  []string
	wsOrder    []string
	riderOrder []string
	// Ids of riders being torn down (CloseRider, DeleteWorkspace): not reusable until their
	// transcript is gone, so a reopened id never inherits or loses rows.
	closing map[string]bool
	// creation goroutines, so Shutdown can wait.
	wg sync.WaitGroup
}

func New(opts Options) (*Car, error) {
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
	c := &Car{
		opts: opts, store: opts.Store, agents: opts.Agents, log: opts.Log, server: newStream(),
		repos: map[string]*radiov1.Repository{}, workspaces: map[string]*radiov1.Workspace{}, riders: map[string]*Rider{}, riderMeta: map[string]*radiov1.Rider{},
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

func (c *Car) load() error {
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
		if w.State == radiov1.WorkspaceState_WORKSPACE_STATE_CREATING || w.State == radiov1.WorkspaceState_WORKSPACE_STATE_SETTING_UP {
			w.State = radiov1.WorkspaceState_WORKSPACE_STATE_FAILED
			w.Failure = "Team Car restarted while this workspace was being created"
			_ = c.store.PutWorkspace(w)
		}
		c.workspaces[w.Id] = w
		c.wsOrder = append(c.wsOrder, w.Id)
	}
	riders, err := c.store.Riders()
	if err != nil {
		return err
	}
	for _, m := range riders {
		last, err := c.store.LastSeq(m.Id)
		if err != nil {
			return err
		}
		m.LastSeq = last
		wasActive := m.Activity != radiov1.RiderActivity_RIDER_ACTIVITY_IDLE && m.Activity != radiov1.RiderActivity_RIDER_ACTIVITY_UNSPECIFIED
		m.Activity = radiov1.RiderActivity_RIDER_ACTIVITY_IDLE
		m.Status = ""
		r := newRider(c, m)
		if wasActive {
			// The agent died with Team Car: settle whatever it left mid-flight.
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
		_ = c.store.PutRider(m)
		c.riders[m.Id] = r
		c.riderMeta[m.Id] = proto.Clone(m).(*radiov1.Rider)
		c.riderOrder = append(c.riderOrder, m.Id)
	}
	return nil
}

// Shutdown stops every agent. Workspaces and transcripts stay on disk.
func (c *Car) Shutdown() {
	c.mu.Lock()
	riders := make([]*Rider, 0, len(c.riders))
	for _, r := range c.riders {
		riders = append(riders, r)
	}
	c.mu.Unlock()
	var wg sync.WaitGroup
	for _, r := range riders {
		wg.Add(1)
		go func() { defer wg.Done(); r.shutdown() }()
	}
	wg.Wait()
	c.server.closeAll()
}

// ---- info and server stream

func (c *Car) ServerID() string   { return c.serverID }
func (c *Car) ServerName() string { return c.opts.Name }
func (c *Car) Version() string    { return c.opts.Version }

func (c *Car) Info() *radiov1.ServerInfo {
	return &radiov1.ServerInfo{
		ServerId: c.serverID, ServerName: c.opts.Name, ServerVersion: c.opts.Version,
		Platform: runtime.GOOS + "/" + runtime.GOARCH, WorkspacesRoot: c.opts.WorkspacesRoot,
		Providers: c.agents.Providers(),
	}
}

// SubscribeServer returns a consistent snapshot and a subscriber for changes after it.
func (c *Car) SubscribeServer() (*radiov1.ServerSnapshot, *Subscriber) {
	c.mu.Lock()
	defer c.mu.Unlock()
	snap := &radiov1.ServerSnapshot{}
	for _, id := range c.repoOrder {
		snap.Repositories = append(snap.Repositories, proto.Clone(c.repos[id]).(*radiov1.Repository))
	}
	for _, id := range c.wsOrder {
		snap.Workspaces = append(snap.Workspaces, proto.Clone(c.workspaces[id]).(*radiov1.Workspace))
	}
	for _, id := range c.riderOrder {
		snap.Riders = append(snap.Riders, proto.Clone(c.riderMeta[id]).(*radiov1.Rider))
	}
	// Every server-stream publish happens under c.mu, so nothing slips between the snapshot and
	// the subscription, and nothing older than the snapshot arrives after it.
	return snap, c.server.add()
}

func (c *Car) publishServer(ev *radiov1.Event) { c.server.publish(ev) }

// publishRider records and broadcasts a rider's metadata. Takes c.mu; riders call it while
// holding their own lock (rider -> car is the only allowed lock order).
func (c *Car) publishRider(m *radiov1.Rider) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.publishRiderLocked(m)
}

func (c *Car) publishRiderLocked(m *radiov1.Rider) {
	if _, ok := c.riders[m.Id]; !ok {
		return // closed
	}
	c.riderMeta[m.Id] = m
	c.publishServer(&radiov1.Event{Payload: &radiov1.Event_RiderUpserted{RiderUpserted: proto.Clone(m).(*radiov1.Rider)}})
}

// ---- repositories

func (c *Car) Repositories() []*radiov1.Repository {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]*radiov1.Repository, 0, len(c.repoOrder))
	for _, id := range c.repoOrder {
		out = append(out, proto.Clone(c.repos[id]).(*radiov1.Repository))
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

func (c *Car) AddRepository(ctx context.Context, req *radiov1.AddRepository) (*radiov1.Repository, error) {
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
			return proto.Clone(r).(*radiov1.Repository), nil
		}
	}
	id := req.Id
	if id == "" {
		id = uuid.NewString()
	} else if _, taken := c.repos[id]; taken {
		return nil, invalid("repository id %s is already in use", id)
	}
	repo := &radiov1.Repository{
		Id: id, Name: safeName.ReplaceAllString(filepath.Base(info.Root), "-"), Path: info.Root,
		RemoteUrl: info.RemoteURL, DefaultBranch: info.DefaultBranch,
		ShipMode: radiov1.ShipMode_SHIP_MODE_PULL_REQUEST, CreatedAtMs: time.Now().UnixMilli(),
	}
	if err := c.store.PutRepository(repo); err != nil {
		return nil, err
	}
	c.repos[repo.Id] = repo
	c.repoOrder = append(c.repoOrder, repo.Id)
	c.publishServer(&radiov1.Event{Payload: &radiov1.Event_RepositoryUpserted{RepositoryUpserted: proto.Clone(repo).(*radiov1.Repository)}})
	return proto.Clone(repo).(*radiov1.Repository), nil
}

func (c *Car) repoByPath(path string) *radiov1.Repository {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, r := range c.repos {
		if r.Path == path {
			return proto.Clone(r).(*radiov1.Repository)
		}
	}
	return nil
}

func (c *Car) RemoveRepository(id string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.repos[id]; !ok {
		return notFound("repository", id)
	}
	for _, w := range c.workspaces {
		if w.RepositoryId == id && w.State != radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
			return fmt.Errorf("%w: archive the repository's workspaces first", ErrPrecondition)
		}
	}
	if err := c.store.DeleteRepository(id); err != nil {
		return err
	}
	delete(c.repos, id)
	c.repoOrder = remove(c.repoOrder, id)
	c.publishServer(&radiov1.Event{Payload: &radiov1.Event_RepositoryRemoved{RepositoryRemoved: id}})
	return nil
}

// ---- workspaces

func (c *Car) Workspaces(repoID string, includeArchived bool) []*radiov1.Workspace {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []*radiov1.Workspace
	for _, id := range c.wsOrder {
		w := c.workspaces[id]
		if repoID != "" && w.RepositoryId != repoID {
			continue
		}
		if !includeArchived && w.State == radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
			continue
		}
		out = append(out, proto.Clone(w).(*radiov1.Workspace))
	}
	return out
}

func (c *Car) Workspace(id string) (*radiov1.Workspace, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	w, ok := c.workspaces[id]
	if !ok {
		return nil, notFound("workspace", id)
	}
	return proto.Clone(w).(*radiov1.Workspace), nil
}

// WorkspaceEnv returns a workspace's path and the environment its scripts, tasks and processes
// get (DOMESTIQUE_PORT and friends).
func (c *Car) WorkspaceEnv(id string) (string, map[string]string, error) {
	ws, repo, err := c.workspaceAndRepo(id)
	if err != nil {
		return "", nil, err
	}
	return ws.Path, workspaceEnv(ws, repo), nil
}

func (c *Car) workspaceAndRepo(id string) (*radiov1.Workspace, *radiov1.Repository, error) {
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
	return proto.Clone(w).(*radiov1.Workspace), proto.Clone(r).(*radiov1.Repository), nil
}

// updateWorkspace applies fn under the lock, persists and publishes.
func (c *Car) updateWorkspace(id string, fn func(w *radiov1.Workspace)) {
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
	c.publishServer(&radiov1.Event{Payload: &radiov1.Event_WorkspaceUpserted{WorkspaceUpserted: proto.Clone(w).(*radiov1.Workspace)}})
}

func (c *Car) markUnread(wsID string) {
	go c.updateWorkspace(wsID, func(w *radiov1.Workspace) { w.HasUnread = true })
}

// CreateWorkspace registers the workspace in CREATING state and returns it at once. A goroutine
// then fetches, creates the worktree, runs setup and (when a prompt is given) sends it to the
// rider. Progress arrives on the server stream.
//
// A rider is opened (and returned, so callers can subscribe immediately) when req.Rider is set,
// or with defaults when only a prompt is given.
func (c *Car) CreateWorkspace(ctx context.Context, req *radiov1.CreateWorkspace) (*radiov1.Workspace, *radiov1.Rider, error) {
	if req.Branch != "" && !git.ValidBranchName(ctx, req.Branch) {
		return nil, nil, invalid("invalid branch name %q", req.Branch)
	}
	var riderReq *radiov1.OpenRider
	if req.Rider != nil {
		riderReq = proto.Clone(req.Rider).(*radiov1.OpenRider)
	} else if req.Prompt != "" {
		riderReq = &radiov1.OpenRider{}
	}

	c.mu.Lock()
	repo, ok := c.repos[req.RepositoryId]
	if !ok {
		c.mu.Unlock()
		return nil, nil, notFound("repository", req.RepositoryId)
	}
	repo = proto.Clone(repo).(*radiov1.Repository)
	if req.Id != "" {
		if _, taken := c.workspaces[req.Id]; taken {
			c.mu.Unlock()
			return nil, nil, invalid("workspace id %s is already in use", req.Id)
		}
	}
	if riderReq != nil && riderReq.Id != "" {
		if err := c.riderIDFreeLocked(riderReq.Id); err != nil {
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
		if w.State != radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
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
	ws := &radiov1.Workspace{
		Id: id, RepositoryId: repo.Id, Name: name, Branch: branch,
		Path: filepath.Join(c.opts.WorkspacesRoot, repo.Name, name), BaseBranch: base,
		PortBase: allocatePorts(usedPorts, c.opts.PortStart, c.opts.PortEnd), State: radiov1.WorkspaceState_WORKSPACE_STATE_CREATING,
		CreatedAtMs: time.Now().UnixMilli(),
	}
	if err := c.store.PutWorkspace(ws); err != nil {
		c.mu.Unlock()
		return nil, nil, err
	}
	c.workspaces[ws.Id] = ws
	c.wsOrder = append(c.wsOrder, ws.Id)
	c.publishServer(&radiov1.Event{Payload: &radiov1.Event_WorkspaceUpserted{WorkspaceUpserted: proto.Clone(ws).(*radiov1.Workspace)}})
	snapshot := proto.Clone(ws).(*radiov1.Workspace)
	var rider *Rider
	if riderReq != nil {
		riderReq.WorkspaceId = ws.Id
		var err error
		if rider, err = c.openRiderLocked(riderReq); err != nil {
			// Validated above, so only a store failure gets here: undo the registration.
			delete(c.workspaces, ws.Id)
			c.wsOrder = remove(c.wsOrder, ws.Id)
			_ = c.store.DeleteWorkspace(ws.Id)
			c.publishServer(&radiov1.Event{Payload: &radiov1.Event_WorkspaceRemoved{WorkspaceRemoved: ws.Id}})
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
			c.updateWorkspace(ws.Id, func(w *radiov1.Workspace) {
				w.State = radiov1.WorkspaceState_WORKSPACE_STATE_FAILED
				w.Failure = err.Error()
			})
			if rider != nil {
				rider.mu.Lock()
				rider.errorLocked("Workspace creation failed: " + err.Error())
				rider.mu.Unlock()
			}
			return
		}
		if rider != nil && req.Prompt != "" {
			if err := rider.Send(bg, req.Prompt, nil); err != nil {
				c.log.Warn("first prompt failed", "workspace", ws.Name, "err", err)
			}
		}
	}()
	var meta *radiov1.Rider
	if rider != nil {
		meta = rider.Meta()
	}
	return snapshot, meta, nil
}

// provision: fresh worktree branched from a just-fetched origin/<base>, then setup. skipScript
// skips [setup].script (the client runs it) but still copies [setup].copy files.
func (c *Car) provision(ctx context.Context, wsID string, repo *radiov1.Repository, skipScript bool) error {
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
	c.updateWorkspace(wsID, func(w *radiov1.Workspace) {
		w.BaseCommit = sha
		w.State = radiov1.WorkspaceState_WORKSPACE_STATE_SETTING_UP
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
	c.updateWorkspace(wsID, func(w *radiov1.Workspace) { w.State = radiov1.WorkspaceState_WORKSPACE_STATE_READY })
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

// ArchiveWorkspace stops its riders, runs the archive script (unless skipped) and removes the
// worktree.
func (c *Car) ArchiveWorkspace(ctx context.Context, req *radiov1.ArchiveWorkspace) (*radiov1.Workspace, error) {
	id, deleteBranch := req.WorkspaceId, req.DeleteBranch
	ws, repo, err := c.workspaceAndRepo(id)
	if err != nil {
		return nil, err
	}
	for _, r := range c.ridersFor(id) {
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
	c.updateWorkspace(id, func(w *radiov1.Workspace) { w.State = radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED })
	return c.Workspace(id)
}

// DeleteWorkspace forgets an archived workspace: its riders, their transcripts and the workspace
// itself. Removals are published on the server stream (riders first).
func (c *Car) DeleteWorkspace(ctx context.Context, id string, deleteBranch bool) error {
	c.mu.Lock()
	w, ok := c.workspaces[id]
	if !ok {
		c.mu.Unlock()
		return notFound("workspace", id)
	}
	if w.State != radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		c.mu.Unlock()
		return fmt.Errorf("%w: archive the workspace before deleting it", ErrPrecondition)
	}
	var riders []*Rider
	for _, rid := range slices.Clone(c.riderOrder) {
		if m := c.riderMeta[rid]; m == nil || m.WorkspaceId != id {
			continue
		}
		riders = append(riders, c.riders[rid])
		delete(c.riders, rid)
		delete(c.riderMeta, rid)
		c.riderOrder = remove(c.riderOrder, rid)
		c.closing[rid] = true
		c.publishServer(&radiov1.Event{Payload: &radiov1.Event_RiderRemoved{RiderRemoved: rid}})
	}
	delete(c.workspaces, id)
	c.wsOrder = remove(c.wsOrder, id)
	c.publishServer(&radiov1.Event{Payload: &radiov1.Event_WorkspaceRemoved{WorkspaceRemoved: id}})
	var repoPath string
	if r, ok := c.repos[w.RepositoryId]; ok {
		repoPath = r.Path
	}
	c.mu.Unlock()

	// Stop the riders (flushing any streamed text) before their rows go.
	for _, r := range riders {
		r.shutdown()
	}
	err := c.store.DeleteWorkspace(id)
	c.mu.Lock()
	for _, r := range riders {
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

// ImportWorkspace registers a workspace that already exists on this host, with its riders and
// their transcripts, keeping every id. An already-registered workspace id is returned unchanged.
func (c *Car) ImportWorkspace(req *radiov1.ImportWorkspace) (*radiov1.Workspace, error) {
	in := req.Workspace
	if in == nil || in.Id == "" {
		return nil, invalid("workspace.id is required")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if w, ok := c.workspaces[in.Id]; ok {
		return proto.Clone(w).(*radiov1.Workspace), nil
	}
	repo, ok := c.repos[in.RepositoryId]
	if !ok {
		return nil, notFound("repository", in.RepositoryId)
	}
	now := time.Now().UnixMilli()
	ws := &radiov1.Workspace{
		Id: in.Id, RepositoryId: repo.Id, Name: in.Name, Branch: in.Branch, Path: in.Path,
		BaseBranch: in.BaseBranch, BaseCommit: in.BaseCommit, PortBase: in.PortBase, State: in.State,
		CreatedAtMs: in.CreatedAtMs,
	}
	switch ws.State {
	case radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED, radiov1.WorkspaceState_WORKSPACE_STATE_READY:
	case radiov1.WorkspaceState_WORKSPACE_STATE_FAILED:
		ws.Failure = in.Failure
	default:
		// CREATING / SETTING_UP (or unset): whatever was creating it is gone; it exists now.
		ws.State = radiov1.WorkspaceState_WORKSPACE_STATE_READY
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
	if ws.PortBase == 0 && ws.State != radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		usedPorts := map[int32]bool{}
		for _, w := range c.workspaces {
			if w.State != radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
				usedPorts[w.PortBase] = true
			}
		}
		ws.PortBase = allocatePorts(usedPorts, c.opts.PortStart, c.opts.PortEnd)
	}

	imported := make([]store.ImportedRider, 0, len(req.Riders))
	seen := map[string]bool{}
	for _, ir := range req.Riders {
		m := ir.GetRider()
		if m == nil || m.Id == "" {
			return nil, invalid("every rider needs an id")
		}
		if seen[m.Id] {
			return nil, invalid("rider id %s appears twice", m.Id)
		}
		seen[m.Id] = true
		if err := c.riderIDFreeLocked(m.Id); err != nil {
			return nil, err
		}
		meta := &radiov1.Rider{
			Id: m.Id, WorkspaceId: ws.Id, Title: m.Title, Provider: m.Provider, Model: m.Model, Effort: m.Effort,
			PermissionMode: m.PermissionMode, ProviderSessionId: m.ProviderSessionId, CreatedAtMs: m.CreatedAtMs,
			Activity: radiov1.RiderActivity_RIDER_ACTIVITY_IDLE,
		}
		if meta.Provider == radiov1.Provider_PROVIDER_UNSPECIFIED {
			meta.Provider = radiov1.Provider_PROVIDER_CLAUDE
		}
		if meta.PermissionMode == radiov1.PermissionMode_PERMISSION_MODE_UNSPECIFIED {
			meta.PermissionMode = radiov1.PermissionMode_PERMISSION_MODE_BYPASS
		}
		if meta.Title == "" {
			meta.Title = "New chat"
		}
		if meta.CreatedAtMs == 0 {
			meta.CreatedAtMs = now
		}
		items := make([]*radiov1.TranscriptItem, 0, len(ir.Items))
		itemIDs := map[string]bool{}
		for _, it := range ir.Items {
			if it == nil || it.Id == "" {
				return nil, invalid("rider %s: every transcript item needs an id", m.Id)
			}
			if itemIDs[it.Id] {
				return nil, invalid("rider %s: item id %s appears twice", m.Id, it.Id)
			}
			itemIDs[it.Id] = true
			// No agent is running for an imported rider: settle anything left mid-flight.
			if fixed := settled(it); fixed != nil {
				it = fixed
			} else {
				it = proto.Clone(it).(*radiov1.TranscriptItem)
			}
			items = append(items, it)
		}
		imported = append(imported, store.ImportedRider{Rider: meta, Items: items})
	}

	last, err := c.store.ImportWorkspace(ws, imported)
	if err != nil {
		return nil, err
	}
	c.workspaces[ws.Id] = ws
	c.wsOrder = append(c.wsOrder, ws.Id)
	c.publishServer(&radiov1.Event{Payload: &radiov1.Event_WorkspaceUpserted{WorkspaceUpserted: proto.Clone(ws).(*radiov1.Workspace)}})
	for i, ir := range imported {
		meta := ir.Rider
		meta.LastSeq = last[i]
		c.riders[meta.Id] = newRider(c, meta)
		c.riderOrder = append(c.riderOrder, meta.Id)
		c.publishRiderLocked(proto.Clone(meta).(*radiov1.Rider))
	}
	return proto.Clone(ws).(*radiov1.Workspace), nil
}

// ---- riders

func (c *Car) Riders(workspaceID string) []*radiov1.Rider {
	var out []*radiov1.Rider
	for _, r := range c.ridersFor(workspaceID) {
		out = append(out, r.Meta())
	}
	return out
}

func (c *Car) ridersFor(workspaceID string) []*Rider {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []*Rider
	for _, id := range c.riderOrder {
		if r := c.riders[id]; workspaceID == "" || r.meta.WorkspaceId == workspaceID {
			out = append(out, r)
		}
	}
	return out
}

func (c *Car) Rider(id string) (*Rider, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	r, ok := c.riders[id]
	if !ok {
		return nil, notFound("rider", id)
	}
	return r, nil
}

func (c *Car) OpenRider(req *radiov1.OpenRider) (*radiov1.Rider, error) {
	r, err := c.openRider(req)
	if err != nil {
		return nil, err
	}
	return r.Meta(), nil
}

func (c *Car) openRider(req *radiov1.OpenRider) (*Rider, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.openRiderLocked(req)
}

// riderIDFreeLocked checks a client-chosen rider id isn't in use.
func (c *Car) riderIDFreeLocked(id string) error {
	if _, taken := c.riders[id]; taken {
		return invalid("rider id %s is already in use", id)
	}
	if c.closing[id] {
		return invalid("rider %s is still closing", id)
	}
	return nil
}

// openRiderLocked validates, persists, registers and publishes a new rider. Caller holds c.mu.
func (c *Car) openRiderLocked(req *radiov1.OpenRider) (*Rider, error) {
	provider := req.Provider
	if provider == radiov1.Provider_PROVIDER_UNSPECIFIED {
		provider = radiov1.Provider_PROVIDER_CLAUDE
	}
	mode := req.PermissionMode
	if mode == radiov1.PermissionMode_PERMISSION_MODE_UNSPECIFIED {
		mode = radiov1.PermissionMode_PERMISSION_MODE_BYPASS
	}
	title := req.Title
	if title == "" {
		title = "New chat"
	}
	id := req.Id
	if id == "" {
		id = uuid.NewString()
	} else if err := c.riderIDFreeLocked(id); err != nil {
		return nil, err
	}
	meta := &radiov1.Rider{
		Id: id, WorkspaceId: req.WorkspaceId, Title: title, Provider: provider,
		Model: req.Model, Effort: req.Effort, PermissionMode: mode, CreatedAtMs: time.Now().UnixMilli(),
		Activity: radiov1.RiderActivity_RIDER_ACTIVITY_IDLE,
	}
	w, ok := c.workspaces[req.WorkspaceId]
	if !ok {
		return nil, notFound("workspace", req.WorkspaceId)
	}
	if w.State == radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED {
		return nil, fmt.Errorf("%w: workspace is archived", ErrPrecondition)
	}
	if err := c.store.PutRider(meta); err != nil {
		return nil, err
	}
	r := newRider(c, meta)
	c.riders[meta.Id] = r
	c.riderOrder = append(c.riderOrder, meta.Id)
	c.publishRiderLocked(proto.Clone(meta).(*radiov1.Rider))
	return r, nil
}

func (c *Car) CloseRider(id string) error {
	c.mu.Lock()
	r, ok := c.riders[id]
	if ok {
		delete(c.riders, id)
		delete(c.riderMeta, id)
		c.riderOrder = remove(c.riderOrder, id)
		c.closing[id] = true
		c.publishServer(&radiov1.Event{Payload: &radiov1.Event_RiderRemoved{RiderRemoved: id}})
	}
	c.mu.Unlock()
	if !ok {
		return notFound("rider", id)
	}
	r.shutdown()
	err := c.store.DeleteRider(id)
	c.mu.Lock()
	delete(c.closing, id)
	c.mu.Unlock()
	return err
}

func (c *Car) Models(ctx context.Context, p radiov1.Provider) ([]*radiov1.ModelOption, error) {
	return c.agents.Models(ctx, p)
}

func (c *Car) executable(p radiov1.Provider) string { return c.opts.Executables[p] }

// ---- code

func (c *Car) Diff(ctx context.Context, wsID, path string) (*radiov1.Diff, error) {
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
	out := &radiov1.Diff{Base: mb}
	if a, b, err := git.AheadBehind(ctx, ws.Path, base); err == nil {
		out.Ahead, out.Behind = int32(a), int32(b)
	}
	for _, f := range files {
		if path != "" && f.Path != path {
			continue
		}
		out.Files = append(out.Files, &radiov1.FileDiff{
			Path: f.Path, OldPath: f.OldPath, Status: diffStatus(f.Status), Additions: int32(f.Additions),
			Deletions: int32(f.Deletions), Patch: f.Patch, Binary: f.Binary,
		})
	}
	return out, nil
}

func diffStatus(s git.FileStatus) radiov1.FileDiffStatus {
	switch s {
	case git.Added:
		return radiov1.FileDiffStatus_FILE_DIFF_STATUS_ADDED
	case git.Deleted:
		return radiov1.FileDiffStatus_FILE_DIFF_STATUS_DELETED
	case git.Renamed:
		return radiov1.FileDiffStatus_FILE_DIFF_STATUS_RENAMED
	default:
		return radiov1.FileDiffStatus_FILE_DIFF_STATUS_MODIFIED
	}
}

func (c *Car) ListFiles(ctx context.Context, wsID string) ([]string, error) {
	ws, err := c.Workspace(wsID)
	if err != nil {
		return nil, err
	}
	return git.ListFiles(ctx, ws.Path)
}

// DefaultMaxRead caps ReadFile when the client doesn't ask for less.
const DefaultMaxRead = 2 << 20

// ReadFile reads a file inside the workspace. Paths may not escape the worktree.
func (c *Car) ReadFile(wsID, rel string, maxBytes int64) (*radiov1.FileContent, error) {
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
	return &radiov1.FileContent{Path: rel, Data: data, Size: st.Size()}, nil
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

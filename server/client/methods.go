package client

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

// CallOption modifies one request.
type CallOption func(*domestiquev1.Request)

// Idempotent sets an idempotency key: retrying with the same key within 10 minutes returns the
// original result instead of running twice.
func Idempotent(key string) CallOption {
	return func(r *domestiquev1.Request) { r.IdempotencyKey = key }
}

func (c *Client) call(ctx context.Context, req *domestiquev1.Request, opts []CallOption) (*domestiquev1.Response, error) {
	for _, o := range opts {
		o(req)
	}
	return c.Do(ctx, req)
}

// ---- server

func (c *Client) ServerInfo(ctx context.Context) (*domestiquev1.ServerInfo, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_GetServerInfo{GetServerInfo: &domestiquev1.GetServerInfo{}}})
	if err != nil {
		return nil, err
	}
	return r.GetServerInfo(), nil
}

// ---- repositories

func (c *Client) Repositories(ctx context.Context) ([]*domestiquev1.Repository, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListRepositories{ListRepositories: &domestiquev1.ListRepositories{}}})
	if err != nil {
		return nil, err
	}
	return r.GetRepositories().GetRepositories(), nil
}

// AddRepository registers an existing clone on the server's host (Path) or clones one (CloneUrl).
// Adding the same repository twice returns the existing one.
func (c *Client) AddRepository(ctx context.Context, req *domestiquev1.AddRepository, opts ...CallOption) (*domestiquev1.Repository, error) {
	r, err := c.call(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_AddRepository{AddRepository: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetRepository(), nil
}

func (c *Client) RemoveRepository(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_RemoveRepository{RemoveRepository: &domestiquev1.RemoveRepository{RepositoryId: id}}})
	return err
}

// ---- workspaces

func (c *Client) Workspaces(ctx context.Context, repositoryID string, includeArchived bool) ([]*domestiquev1.Workspace, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListWorkspaces{ListWorkspaces: &domestiquev1.ListWorkspaces{
		RepositoryId: repositoryID, IncludeArchived: includeArchived}}})
	if err != nil {
		return nil, err
	}
	return r.GetWorkspaces().GetWorkspaces(), nil
}

// CreateWorkspace starts creating a workspace and returns it in CREATING state; watch the server
// stream (or use WaitWorkspace) for READY or FAILED. When req.Session is set, that session is opened
// right away (set req.Session.Id to know its id up front); when only req.Prompt is set, a default
// session is opened. A prompt is sent once the worktree is ready; find the session with Sessions.
func (c *Client) CreateWorkspace(ctx context.Context, req *domestiquev1.CreateWorkspace, opts ...CallOption) (*domestiquev1.Workspace, error) {
	r, err := c.call(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_CreateWorkspace{CreateWorkspace: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

func (c *Client) ArchiveWorkspace(ctx context.Context, id string, deleteBranch bool) (*domestiquev1.Workspace, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ArchiveWorkspace{ArchiveWorkspace: &domestiquev1.ArchiveWorkspace{
		WorkspaceId: id, DeleteBranch: deleteBranch}}})
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

// ArchiveWorkspaceWith archives with every option of domestiquev1.ArchiveWorkspace (e.g.
// SkipArchiveScript when the client already ran domestique.toml's [archive] script).
func (c *Client) ArchiveWorkspaceWith(ctx context.Context, req *domestiquev1.ArchiveWorkspace) (*domestiquev1.Workspace, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ArchiveWorkspace{ArchiveWorkspace: req}})
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

// DeleteWorkspace forgets an archived workspace, its sessions and their transcripts (needs the
// operate scope). Optionally deletes its local branch too.
func (c *Client) DeleteWorkspace(ctx context.Context, id string, deleteBranch bool) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_DeleteWorkspace{DeleteWorkspace: &domestiquev1.DeleteWorkspace{
		WorkspaceId: id, DeleteBranch: deleteBranch}}})
	return err
}

// ImportWorkspace registers a workspace that already exists on the server's host, with its
// sessions and transcripts, keeping their ids. Importing an already-registered workspace id returns
// it unchanged.
func (c *Client) ImportWorkspace(ctx context.Context, req *domestiquev1.ImportWorkspace, opts ...CallOption) (*domestiquev1.Workspace, error) {
	r, err := c.call(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ImportWorkspace{ImportWorkspace: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

// WaitWorkspace blocks until the workspace is READY (nil), FAILED (error) or ctx ends.
func (c *Client) WaitWorkspace(ctx context.Context, id string) (*domestiquev1.Workspace, error) {
	sub, err := c.SubscribeServer(ctx)
	if err != nil {
		return nil, err
	}
	defer sub.Close()
	check := func(w *domestiquev1.Workspace) (*domestiquev1.Workspace, bool, error) {
		if w == nil || w.Id != id {
			return nil, false, nil
		}
		switch w.State {
		case domestiquev1.WorkspaceState_WORKSPACE_STATE_READY:
			return w, true, nil
		case domestiquev1.WorkspaceState_WORKSPACE_STATE_FAILED:
			return w, true, fmt.Errorf("workspace %s failed: %s", w.Name, w.Failure)
		case domestiquev1.WorkspaceState_WORKSPACE_STATE_ARCHIVED:
			return w, true, fmt.Errorf("workspace %s is archived", w.Name)
		}
		return nil, false, nil
	}
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case ev, ok := <-sub.Events():
			if !ok {
				return nil, errors.Join(ErrDisconnected, sub.Err())
			}
			if snap := ev.GetServerSnapshot(); snap != nil {
				found := false
				for _, w := range snap.Workspaces {
					if w.Id == id {
						found = true
					}
					if w, done, err := check(w); done {
						return w, err
					}
				}
				if !found {
					return nil, &Error{Code: domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND, Message: "workspace " + id}
				}
			}
			if w, done, err := check(ev.GetWorkspaceUpserted()); done {
				return w, err
			}
		}
	}
}

// ---- sessions

func (c *Client) OpenSession(ctx context.Context, req *domestiquev1.OpenSession, opts ...CallOption) (*domestiquev1.Session, error) {
	r, err := c.call(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_OpenSession{OpenSession: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetSession(), nil
}

// Sessions lists sessions, optionally only one workspace's.
func (c *Client) Sessions(ctx context.Context, workspaceID string) ([]*domestiquev1.Session, error) {
	sub, err := c.SubscribeServer(ctx)
	if err != nil {
		return nil, err
	}
	defer sub.Close()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case ev, ok := <-sub.Events():
		if !ok {
			return nil, errors.Join(ErrDisconnected, sub.Err())
		}
		var out []*domestiquev1.Session
		for _, r := range ev.GetServerSnapshot().GetSessions() {
			if workspaceID == "" || r.WorkspaceId == workspaceID {
				out = append(out, r)
			}
		}
		return out, nil
	}
}

func (c *Client) CloseSession(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_CloseSession{CloseSession: &domestiquev1.CloseSession{SessionId: id}}})
	return err
}

// CloseSessionKeepingHistory closes a session so ReopenSession can bring it back.
func (c *Client) CloseSessionKeepingHistory(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_CloseSession{CloseSession: &domestiquev1.CloseSession{SessionId: id, KeepHistory: true}}})
	return err
}

// ReopenSession brings back a session closed with its history kept.
func (c *Client) ReopenSession(ctx context.Context, id string) (*domestiquev1.Session, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ReopenSession{ReopenSession: &domestiquev1.ReopenSession{SessionId: id}}})
	if err != nil {
		return nil, err
	}
	return r.GetSession(), nil
}

// Send sends a message to a session. It returns once the agent accepted it; the reply streams on a
// session subscription (or use Prompt).
func (c *Client) Send(ctx context.Context, sessionID, text string, attachments []*domestiquev1.Attachment, opts ...CallOption) error {
	_, err := c.call(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_SendMessage{SendMessage: &domestiquev1.SendMessage{
		SessionId: sessionID, Text: text, Attachments: attachments}}}, opts)
	return err
}

func (c *Client) Interrupt(ctx context.Context, sessionID string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_Interrupt{Interrupt: &domestiquev1.Interrupt{SessionId: sessionID}}})
	return err
}

func (c *Client) RespondApproval(ctx context.Context, sessionID, requestID string, d domestiquev1.Decision, message string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_RespondApproval{RespondApproval: &domestiquev1.RespondApproval{
		SessionId: sessionID, RequestId: requestID, Decision: d, Message: message}}})
	return err
}

func (c *Client) AnswerQuestion(ctx context.Context, sessionID, requestID string, answers map[string]string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_AnswerQuestion{AnswerQuestion: &domestiquev1.AnswerQuestion{
		SessionId: sessionID, RequestId: requestID, Answers: answers}}})
	return err
}

func (c *Client) UpdateSession(ctx context.Context, req *domestiquev1.UpdateSession) (*domestiquev1.Session, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_UpdateSession{UpdateSession: req}})
	if err != nil {
		return nil, err
	}
	return r.GetSession(), nil
}

func (c *Client) Models(ctx context.Context, p domestiquev1.Provider) ([]*domestiquev1.ModelOption, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListModels{ListModels: &domestiquev1.ListModels{Provider: p}}})
	if err != nil {
		return nil, err
	}
	return r.GetModels().GetModels(), nil
}

// Transcript fetches the whole persisted transcript (paging internally).
func (c *Client) Transcript(ctx context.Context, sessionID string) (*Transcript, error) {
	var entries []*domestiquev1.TranscriptEntry
	var after uint64
	for {
		r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_GetTranscript{GetTranscript: &domestiquev1.GetTranscript{SessionId: sessionID, AfterSeq: after}}})
		if err != nil {
			return nil, err
		}
		page := r.GetTranscript()
		entries = append(entries, page.Entries...)
		if !page.HasMore {
			// Pages come in write order; display in creation order.
			slices.SortFunc(entries, func(a, b *domestiquev1.TranscriptEntry) int { return cmp.Compare(a.Position, b.Position) })
			t := NewTranscript()
			for _, e := range entries {
				t.Upsert(e.Item)
				t.LastSeq = max(t.LastSeq, e.Seq)
			}
			return t, nil
		}
		after = page.NextSeq
	}
}

// ---- code

func (c *Client) Diff(ctx context.Context, workspaceID, path string) (*domestiquev1.Diff, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_GetDiff{GetDiff: &domestiquev1.GetDiff{WorkspaceId: workspaceID, Path: path}}})
	if err != nil {
		return nil, err
	}
	return r.GetDiff(), nil
}

func (c *Client) Files(ctx context.Context, workspaceID string) ([]string, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListFiles{ListFiles: &domestiquev1.ListFiles{WorkspaceId: workspaceID}}})
	if err != nil {
		return nil, err
	}
	return r.GetFiles().GetPaths(), nil
}

func (c *Client) ReadFile(ctx context.Context, workspaceID, path string, maxBytes int64) (*domestiquev1.FileContent, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ReadFile{ReadFile: &domestiquev1.ReadFile{
		WorkspaceId: workspaceID, Path: path, MaxBytes: maxBytes}}})
	if err != nil {
		return nil, err
	}
	return r.GetFile(), nil
}

// ---- tokens (admin)

func (c *Client) CreateToken(ctx context.Context, name string, scope domestiquev1.TokenScope) (*domestiquev1.CreatedToken, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_CreateToken{CreateToken: &domestiquev1.CreateToken{Name: name, Scope: scope}}})
	if err != nil {
		return nil, err
	}
	return r.GetCreatedToken(), nil
}

func (c *Client) Tokens(ctx context.Context) ([]*domestiquev1.TokenInfo, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListTokens{ListTokens: &domestiquev1.ListTokens{}}})
	if err != nil {
		return nil, err
	}
	return r.GetTokens().GetTokens(), nil
}

func (c *Client) RevokeToken(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_RevokeToken{RevokeToken: &domestiquev1.RevokeToken{TokenId: id}}})
	return err
}

// ---- sandboxes

// SandboxProviders lists this server's sandbox providers. checkAccount also reads each account.
func (c *Client) SandboxProviders(ctx context.Context, checkAccount bool) ([]*domestiquev1.SandboxProvider, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListSandboxProviders{ListSandboxProviders: &domestiquev1.ListSandboxProviders{CheckAccount: checkAccount}}})
	if err != nil {
		return nil, err
	}
	return r.GetSandboxProviders().GetProviders(), nil
}

// SaveSandboxProvider creates or replaces a provider (ADMIN). apiKey nil keeps the stored key; ""
// deletes it.
func (c *Client) SaveSandboxProvider(ctx context.Context, p *domestiquev1.SandboxProvider, apiKey *string) (*domestiquev1.SandboxProvider, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_SaveSandboxProvider{SaveSandboxProvider: &domestiquev1.SaveSandboxProvider{Provider: p, ApiKey: apiKey}}})
	if err != nil {
		return nil, err
	}
	return r.GetSandboxProvider(), nil
}

func (c *Client) RemoveSandboxProvider(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_RemoveSandboxProvider{RemoveSandboxProvider: &domestiquev1.RemoveSandboxProvider{ProviderId: id}}})
	return err
}

func (c *Client) Sandboxes(ctx context.Context, providerID string) ([]*domestiquev1.Sandbox, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListSandboxes{ListSandboxes: &domestiquev1.ListSandboxes{ProviderId: providerID}}})
	if err != nil {
		return nil, err
	}
	return r.GetSandboxes().GetSandboxes(), nil
}

func (c *Client) Sandbox(ctx context.Context, providerID, sandboxID string) (*domestiquev1.Sandbox, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_GetSandbox{GetSandbox: &domestiquev1.GetSandbox{ProviderId: providerID, SandboxId: sandboxID}}})
	if err != nil {
		return nil, err
	}
	return r.GetSandbox(), nil
}

// CreateSandbox starts a sandbox on one of the server's providers. Pass Idempotent(key): the key
// also reaches the sandbox service, so a retry never makes two machines.
func (c *Client) CreateSandbox(ctx context.Context, req *domestiquev1.CreateSandbox, opts ...CallOption) (*domestiquev1.Sandbox, error) {
	r, err := c.call(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_CreateSandbox{CreateSandbox: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetSandbox(), nil
}

// ChangeSandbox resumes, stops, renames, deletes or recovers a sandbox, or sets its auto-stop.
func (c *Client) ChangeSandbox(ctx context.Context, req *domestiquev1.ChangeSandbox) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ChangeSandbox{ChangeSandbox: req}})
	return err
}

// OpenSandboxAccess authorizes an SSH key, or returns a desktop or port URL (OPERATE).
func (c *Client) OpenSandboxAccess(ctx context.Context, req *domestiquev1.OpenSandboxAccess) (*domestiquev1.SandboxAccess, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_OpenSandboxAccess{OpenSandboxAccess: req}})
	if err != nil {
		return nil, err
	}
	return r.GetSandboxAccess(), nil
}

// McpServers lists this server's MCP servers (names of secrets only).
func (c *Client) McpServers(ctx context.Context) ([]*domestiquev1.McpServer, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ListMcpServers{ListMcpServers: &domestiquev1.ListMcpServers{}}})
	if err != nil {
		return nil, err
	}
	return r.GetMcpServers().GetServers(), nil
}

// SaveMcpServer creates or replaces an MCP server (ADMIN).
func (c *Client) SaveMcpServer(ctx context.Context, req *domestiquev1.SaveMcpServer) (*domestiquev1.McpServer, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_SaveMcpServer{SaveMcpServer: req}})
	if err != nil {
		return nil, err
	}
	return r.GetMcpServer(), nil
}

// RemoveMcpServer deletes an MCP server (ADMIN).
func (c *Client) RemoveMcpServer(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_RemoveMcpServer{RemoveMcpServer: &domestiquev1.RemoveMcpServer{ServerId: id}}})
	return err
}

// ResolveMcpConfig returns every enabled server, secrets included, as a Claude --mcp-config file.
func (c *Client) ResolveMcpConfig(ctx context.Context) (*domestiquev1.McpConfig, error) {
	r, err := c.Do(ctx, &domestiquev1.Request{Command: &domestiquev1.Request_ResolveMcpConfig{ResolveMcpConfig: &domestiquev1.ResolveMcpConfig{}}})
	if err != nil {
		return nil, err
	}
	return r.GetMcpConfig(), nil
}

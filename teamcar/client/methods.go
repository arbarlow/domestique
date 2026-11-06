package client

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// CallOption modifies one request.
type CallOption func(*radiov1.Request)

// Idempotent sets an idempotency key: retrying with the same key within 10 minutes returns the
// original result instead of running twice.
func Idempotent(key string) CallOption { return func(r *radiov1.Request) { r.IdempotencyKey = key } }

func (c *Client) call(ctx context.Context, req *radiov1.Request, opts []CallOption) (*radiov1.Response, error) {
	for _, o := range opts {
		o(req)
	}
	return c.Do(ctx, req)
}

// ---- server

func (c *Client) ServerInfo(ctx context.Context) (*radiov1.ServerInfo, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_GetServerInfo{GetServerInfo: &radiov1.GetServerInfo{}}})
	if err != nil {
		return nil, err
	}
	return r.GetServerInfo(), nil
}

// ---- repositories

func (c *Client) Repositories(ctx context.Context) ([]*radiov1.Repository, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ListRepositories{ListRepositories: &radiov1.ListRepositories{}}})
	if err != nil {
		return nil, err
	}
	return r.GetRepositories().GetRepositories(), nil
}

// AddRepository registers an existing clone on the Team Car's host (Path) or clones one (CloneUrl).
// Adding the same repository twice returns the existing one.
func (c *Client) AddRepository(ctx context.Context, req *radiov1.AddRepository, opts ...CallOption) (*radiov1.Repository, error) {
	r, err := c.call(ctx, &radiov1.Request{Command: &radiov1.Request_AddRepository{AddRepository: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetRepository(), nil
}

func (c *Client) RemoveRepository(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_RemoveRepository{RemoveRepository: &radiov1.RemoveRepository{RepositoryId: id}}})
	return err
}

// ---- workspaces

func (c *Client) Workspaces(ctx context.Context, repositoryID string, includeArchived bool) ([]*radiov1.Workspace, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ListWorkspaces{ListWorkspaces: &radiov1.ListWorkspaces{
		RepositoryId: repositoryID, IncludeArchived: includeArchived}}})
	if err != nil {
		return nil, err
	}
	return r.GetWorkspaces().GetWorkspaces(), nil
}

// CreateWorkspace starts creating a workspace and returns it in CREATING state; watch the server
// stream (or use WaitWorkspace) for READY or FAILED. When req.Rider is set, that rider is opened
// right away (set req.Rider.Id to know its id up front); when only req.Prompt is set, a default
// rider is opened. A prompt is sent once the worktree is ready; find the rider with Riders.
func (c *Client) CreateWorkspace(ctx context.Context, req *radiov1.CreateWorkspace, opts ...CallOption) (*radiov1.Workspace, error) {
	r, err := c.call(ctx, &radiov1.Request{Command: &radiov1.Request_CreateWorkspace{CreateWorkspace: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

func (c *Client) ArchiveWorkspace(ctx context.Context, id string, deleteBranch bool) (*radiov1.Workspace, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ArchiveWorkspace{ArchiveWorkspace: &radiov1.ArchiveWorkspace{
		WorkspaceId: id, DeleteBranch: deleteBranch}}})
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

// ArchiveWorkspaceWith archives with every option of radiov1.ArchiveWorkspace (e.g.
// SkipArchiveScript when the client already ran domestique.toml's [archive] script).
func (c *Client) ArchiveWorkspaceWith(ctx context.Context, req *radiov1.ArchiveWorkspace) (*radiov1.Workspace, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ArchiveWorkspace{ArchiveWorkspace: req}})
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

// DeleteWorkspace forgets an archived workspace, its riders and their transcripts (needs the
// operate scope). Optionally deletes its local branch too.
func (c *Client) DeleteWorkspace(ctx context.Context, id string, deleteBranch bool) error {
	_, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_DeleteWorkspace{DeleteWorkspace: &radiov1.DeleteWorkspace{
		WorkspaceId: id, DeleteBranch: deleteBranch}}})
	return err
}

// ImportWorkspace registers a workspace that already exists on the Team Car's host, with its
// riders and transcripts, keeping their ids. Importing an already-registered workspace id returns
// it unchanged.
func (c *Client) ImportWorkspace(ctx context.Context, req *radiov1.ImportWorkspace, opts ...CallOption) (*radiov1.Workspace, error) {
	r, err := c.call(ctx, &radiov1.Request{Command: &radiov1.Request_ImportWorkspace{ImportWorkspace: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetWorkspace(), nil
}

// WaitWorkspace blocks until the workspace is READY (nil), FAILED (error) or ctx ends.
func (c *Client) WaitWorkspace(ctx context.Context, id string) (*radiov1.Workspace, error) {
	sub, err := c.SubscribeServer(ctx)
	if err != nil {
		return nil, err
	}
	defer sub.Close()
	check := func(w *radiov1.Workspace) (*radiov1.Workspace, bool, error) {
		if w == nil || w.Id != id {
			return nil, false, nil
		}
		switch w.State {
		case radiov1.WorkspaceState_WORKSPACE_STATE_READY:
			return w, true, nil
		case radiov1.WorkspaceState_WORKSPACE_STATE_FAILED:
			return w, true, fmt.Errorf("workspace %s failed: %s", w.Name, w.Failure)
		case radiov1.WorkspaceState_WORKSPACE_STATE_ARCHIVED:
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
					return nil, &Error{Code: radiov1.ErrorCode_ERROR_CODE_NOT_FOUND, Message: "workspace " + id}
				}
			}
			if w, done, err := check(ev.GetWorkspaceUpserted()); done {
				return w, err
			}
		}
	}
}

// ---- riders

func (c *Client) OpenRider(ctx context.Context, req *radiov1.OpenRider, opts ...CallOption) (*radiov1.Rider, error) {
	r, err := c.call(ctx, &radiov1.Request{Command: &radiov1.Request_OpenRider{OpenRider: req}}, opts)
	if err != nil {
		return nil, err
	}
	return r.GetRider(), nil
}

// Riders lists riders, optionally only one workspace's.
func (c *Client) Riders(ctx context.Context, workspaceID string) ([]*radiov1.Rider, error) {
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
		var out []*radiov1.Rider
		for _, r := range ev.GetServerSnapshot().GetRiders() {
			if workspaceID == "" || r.WorkspaceId == workspaceID {
				out = append(out, r)
			}
		}
		return out, nil
	}
}

func (c *Client) CloseRider(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_CloseRider{CloseRider: &radiov1.CloseRider{RiderId: id}}})
	return err
}

// Send sends a message to a rider. It returns once the agent accepted it; the reply streams on a
// rider subscription (or use Prompt).
func (c *Client) Send(ctx context.Context, riderID, text string, attachments []*radiov1.Attachment, opts ...CallOption) error {
	_, err := c.call(ctx, &radiov1.Request{Command: &radiov1.Request_SendMessage{SendMessage: &radiov1.SendMessage{
		RiderId: riderID, Text: text, Attachments: attachments}}}, opts)
	return err
}

func (c *Client) Interrupt(ctx context.Context, riderID string) error {
	_, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_Interrupt{Interrupt: &radiov1.Interrupt{RiderId: riderID}}})
	return err
}

func (c *Client) RespondApproval(ctx context.Context, riderID, requestID string, d radiov1.Decision, message string) error {
	_, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_RespondApproval{RespondApproval: &radiov1.RespondApproval{
		RiderId: riderID, RequestId: requestID, Decision: d, Message: message}}})
	return err
}

func (c *Client) AnswerQuestion(ctx context.Context, riderID, requestID string, answers map[string]string) error {
	_, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_AnswerQuestion{AnswerQuestion: &radiov1.AnswerQuestion{
		RiderId: riderID, RequestId: requestID, Answers: answers}}})
	return err
}

func (c *Client) UpdateRider(ctx context.Context, req *radiov1.UpdateRider) (*radiov1.Rider, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_UpdateRider{UpdateRider: req}})
	if err != nil {
		return nil, err
	}
	return r.GetRider(), nil
}

func (c *Client) Models(ctx context.Context, p radiov1.Provider) ([]*radiov1.ModelOption, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ListModels{ListModels: &radiov1.ListModels{Provider: p}}})
	if err != nil {
		return nil, err
	}
	return r.GetModels().GetModels(), nil
}

// Transcript fetches the whole persisted transcript (paging internally).
func (c *Client) Transcript(ctx context.Context, riderID string) (*Transcript, error) {
	var entries []*radiov1.TranscriptEntry
	var after uint64
	for {
		r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_GetTranscript{GetTranscript: &radiov1.GetTranscript{RiderId: riderID, AfterSeq: after}}})
		if err != nil {
			return nil, err
		}
		page := r.GetTranscript()
		entries = append(entries, page.Entries...)
		if !page.HasMore {
			// Pages come in write order; display in creation order.
			slices.SortFunc(entries, func(a, b *radiov1.TranscriptEntry) int { return cmp.Compare(a.Position, b.Position) })
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

func (c *Client) Diff(ctx context.Context, workspaceID, path string) (*radiov1.Diff, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_GetDiff{GetDiff: &radiov1.GetDiff{WorkspaceId: workspaceID, Path: path}}})
	if err != nil {
		return nil, err
	}
	return r.GetDiff(), nil
}

func (c *Client) Files(ctx context.Context, workspaceID string) ([]string, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ListFiles{ListFiles: &radiov1.ListFiles{WorkspaceId: workspaceID}}})
	if err != nil {
		return nil, err
	}
	return r.GetFiles().GetPaths(), nil
}

func (c *Client) ReadFile(ctx context.Context, workspaceID, path string, maxBytes int64) (*radiov1.FileContent, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ReadFile{ReadFile: &radiov1.ReadFile{
		WorkspaceId: workspaceID, Path: path, MaxBytes: maxBytes}}})
	if err != nil {
		return nil, err
	}
	return r.GetFile(), nil
}

// ---- tokens (admin)

func (c *Client) CreateToken(ctx context.Context, name string, scope radiov1.TokenScope) (*radiov1.CreatedToken, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_CreateToken{CreateToken: &radiov1.CreateToken{Name: name, Scope: scope}}})
	if err != nil {
		return nil, err
	}
	return r.GetCreatedToken(), nil
}

func (c *Client) Tokens(ctx context.Context) ([]*radiov1.TokenInfo, error) {
	r, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_ListTokens{ListTokens: &radiov1.ListTokens{}}})
	if err != nil {
		return nil, err
	}
	return r.GetTokens().GetTokens(), nil
}

func (c *Client) RevokeToken(ctx context.Context, id string) error {
	_, err := c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_RevokeToken{RevokeToken: &radiov1.RevokeToken{TokenId: id}}})
	return err
}

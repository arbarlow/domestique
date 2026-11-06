package radio

import (
	"context"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
	"github.com/arbarlow/domestique/teamcar/internal/agent"
)

// Scopes are ordered: each one includes everything below it.
//
//	READ     watch: subscriptions, lists, transcripts, diffs, files
//	TRIGGER  + create, import and archive workspaces, open riders, prompt, approve, add repositories
//	OPERATE  + remove repositories, delete workspaces, run processes (Subscribe{process} and its
//	         input, resize and signal requests)
//	ADMIN    + tokens, sandbox providers
//
// Sandboxes: list/get are READ; create, resume, stop, rename and auto-stop are TRIGGER; delete,
// recover and access (SSH keys, desktop, port URLs) are OPERATE.
func required(req *radiov1.Request) radiov1.TokenScope {
	switch cmd := req.Command.(type) {
	case *radiov1.Request_CreateToken, *radiov1.Request_ListTokens, *radiov1.Request_RevokeToken,
		*radiov1.Request_SaveSandboxProvider, *radiov1.Request_RemoveSandboxProvider:
		return radiov1.TokenScope_TOKEN_SCOPE_ADMIN
	case *radiov1.Request_OpenSandboxAccess:
		return radiov1.TokenScope_TOKEN_SCOPE_OPERATE
	case *radiov1.Request_CreateSandbox:
		return radiov1.TokenScope_TOKEN_SCOPE_TRIGGER
	case *radiov1.Request_ChangeSandbox:
		switch cmd.ChangeSandbox.Action {
		case radiov1.SandboxAction_SANDBOX_ACTION_DELETE, radiov1.SandboxAction_SANDBOX_ACTION_RECOVER:
			return radiov1.TokenScope_TOKEN_SCOPE_OPERATE
		}
		return radiov1.TokenScope_TOKEN_SCOPE_TRIGGER
	case *radiov1.Request_RemoveRepository, *radiov1.Request_DeleteWorkspace,
		*radiov1.Request_ProcessInput, *radiov1.Request_ResizeProcess, *radiov1.Request_SignalProcess:
		return radiov1.TokenScope_TOKEN_SCOPE_OPERATE
	case *radiov1.Request_Subscribe:
		// Subscriptions only watch, except a process one, which runs a command.
		if cmd.Subscribe.GetProcess() != nil {
			return radiov1.TokenScope_TOKEN_SCOPE_OPERATE
		}
		return radiov1.TokenScope_TOKEN_SCOPE_READ
	case *radiov1.Request_AddRepository, *radiov1.Request_CreateWorkspace, *radiov1.Request_ArchiveWorkspace,
		*radiov1.Request_ImportWorkspace,
		*radiov1.Request_OpenRider, *radiov1.Request_CloseRider, *radiov1.Request_SendMessage,
		*radiov1.Request_Interrupt, *radiov1.Request_RespondApproval, *radiov1.Request_AnswerQuestion,
		*radiov1.Request_UpdateRider:
		return radiov1.TokenScope_TOKEN_SCOPE_TRIGGER
	default:
		return radiov1.TokenScope_TOKEN_SCOPE_READ
	}
}

func (c *conn) dispatch(req *radiov1.Request) {
	if req.Command == nil {
		c.respond(req.Id, errResponse(radiov1.ErrorCode_ERROR_CODE_UNIMPLEMENTED, "unknown or empty command"))
		return
	}
	if need := required(req); c.scope < need {
		c.respond(req.Id, errResponse(radiov1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "this token's scope (%v) doesn't allow this request (needs %v)", c.scope, need))
		return
	}
	// Subscriptions answer themselves (the response must precede the first event).
	switch cmd := req.Command.(type) {
	case *radiov1.Request_Subscribe:
		switch t := cmd.Subscribe.Target.(type) {
		case *radiov1.Subscribe_Server:
			c.subscribeServer(req.Id)
		case *radiov1.Subscribe_Rider:
			c.subscribeRider(req.Id, t.Rider)
		case *radiov1.Subscribe_Process:
			c.subscribeProcess(req.Id, t.Process)
		default:
			c.respond(req.Id, errResponse(radiov1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "subscribe target is required"))
		}
		return
	}
	run := func() *radiov1.Response { return c.execute(c.ctx, req) }
	var resp *radiov1.Response
	if req.IdempotencyKey != "" {
		resp = c.s.idem.do(c.tokenID+"\x00"+req.IdempotencyKey, run)
	} else {
		resp = run()
	}
	c.respond(req.Id, resp)
}

func (c *conn) execute(ctx context.Context, req *radiov1.Request) *radiov1.Response {
	car := c.s.car
	switch cmd := req.Command.(type) {
	case *radiov1.Request_GetServerInfo:
		info := car.Info()
		if m := c.s.sandboxes; m != nil {
			if ps, err := m.Providers(ctx, false); err == nil {
				info.SandboxProviders = ps
			} else {
				c.s.log.Warn("sandbox providers", "err", err)
			}
		}
		return &radiov1.Response{Result: &radiov1.Response_ServerInfo{ServerInfo: info}}
	case *radiov1.Request_Unsubscribe:
		if !c.endSub(cmd.Unsubscribe.SubscriptionId) {
			return errResponse(radiov1.ErrorCode_ERROR_CODE_NOT_FOUND, "no subscription %d", cmd.Unsubscribe.SubscriptionId)
		}
		return empty()

	case *radiov1.Request_ListRepositories:
		return &radiov1.Response{Result: &radiov1.Response_Repositories{Repositories: &radiov1.RepositoryList{Repositories: car.Repositories()}}}
	case *radiov1.Request_AddRepository:
		r, err := car.AddRepository(ctx, cmd.AddRepository)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Repository{Repository: r}}
	case *radiov1.Request_RemoveRepository:
		if err := car.RemoveRepository(cmd.RemoveRepository.RepositoryId); err != nil {
			return fromError(err)
		}
		return empty()

	case *radiov1.Request_ListWorkspaces:
		ws := car.Workspaces(cmd.ListWorkspaces.RepositoryId, cmd.ListWorkspaces.IncludeArchived)
		return &radiov1.Response{Result: &radiov1.Response_Workspaces{Workspaces: &radiov1.WorkspaceList{Workspaces: ws}}}
	case *radiov1.Request_CreateWorkspace:
		ws, _, err := car.CreateWorkspace(ctx, cmd.CreateWorkspace)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Workspace{Workspace: ws}}
	case *radiov1.Request_ArchiveWorkspace:
		ws, err := car.ArchiveWorkspace(ctx, cmd.ArchiveWorkspace)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Workspace{Workspace: ws}}
	case *radiov1.Request_DeleteWorkspace:
		if err := car.DeleteWorkspace(ctx, cmd.DeleteWorkspace.WorkspaceId, cmd.DeleteWorkspace.DeleteBranch); err != nil {
			return fromError(err)
		}
		return empty()
	case *radiov1.Request_ImportWorkspace:
		ws, err := car.ImportWorkspace(cmd.ImportWorkspace)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Workspace{Workspace: ws}}

	case *radiov1.Request_OpenRider:
		r, err := car.OpenRider(cmd.OpenRider)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Rider{Rider: r}}
	case *radiov1.Request_CloseRider:
		if err := car.CloseRider(cmd.CloseRider.RiderId); err != nil {
			return fromError(err)
		}
		return empty()
	case *radiov1.Request_SendMessage:
		r, err := car.Rider(cmd.SendMessage.RiderId)
		if err != nil {
			return fromError(err)
		}
		atts := make([]agent.Attachment, len(cmd.SendMessage.Attachments))
		for i, a := range cmd.SendMessage.Attachments {
			atts[i] = agent.Attachment{Data: a.Data, MediaType: a.MediaType, Filename: a.Filename}
		}
		// The agent outlives this connection.
		if err := r.Send(context.WithoutCancel(ctx), cmd.SendMessage.Text, atts); err != nil {
			return fromError(err)
		}
		return empty()
	case *radiov1.Request_Interrupt:
		r, err := car.Rider(cmd.Interrupt.RiderId)
		if err != nil {
			return fromError(err)
		}
		r.Interrupt(ctx)
		return empty()
	case *radiov1.Request_RespondApproval:
		r, err := car.Rider(cmd.RespondApproval.RiderId)
		if err != nil {
			return fromError(err)
		}
		d := agent.Decision{Kind: cmd.RespondApproval.Decision, Message: cmd.RespondApproval.Message}
		if err := r.Respond(ctx, cmd.RespondApproval.RequestId, d); err != nil {
			return errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "%v", err)
		}
		return empty()
	case *radiov1.Request_AnswerQuestion:
		r, err := car.Rider(cmd.AnswerQuestion.RiderId)
		if err != nil {
			return fromError(err)
		}
		if err := r.Answer(ctx, cmd.AnswerQuestion.RequestId, cmd.AnswerQuestion.Answers); err != nil {
			return errResponse(radiov1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "%v", err)
		}
		return empty()
	case *radiov1.Request_UpdateRider:
		r, err := car.Rider(cmd.UpdateRider.RiderId)
		if err != nil {
			return fromError(err)
		}
		r.Update(ctx, cmd.UpdateRider)
		return &radiov1.Response{Result: &radiov1.Response_Rider{Rider: r.Meta()}}
	case *radiov1.Request_ListModels:
		ms, err := car.Models(ctx, cmd.ListModels.Provider)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Models{Models: &radiov1.ModelList{Models: ms}}}
	case *radiov1.Request_GetTranscript:
		r, err := car.Rider(cmd.GetTranscript.RiderId)
		if err != nil {
			return fromError(err)
		}
		limit := int(cmd.GetTranscript.Limit)
		if limit <= 0 || limit > 5000 {
			limit = defaultTranscript
		}
		entries, err := r.Transcript(cmd.GetTranscript.AfterSeq, limit+1)
		if err != nil {
			return fromError(err)
		}
		page := &radiov1.TranscriptPage{NextSeq: cmd.GetTranscript.AfterSeq}
		if len(entries) > limit {
			entries, page.HasMore = entries[:limit], true
		}
		page.Entries = entries
		if n := len(entries); n > 0 {
			page.NextSeq = entries[n-1].Seq
		}
		return &radiov1.Response{Result: &radiov1.Response_Transcript{Transcript: page}}

	case *radiov1.Request_GetDiff:
		d, err := car.Diff(ctx, cmd.GetDiff.WorkspaceId, cmd.GetDiff.Path)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Diff{Diff: d}}
	case *radiov1.Request_ListFiles:
		files, err := car.ListFiles(ctx, cmd.ListFiles.WorkspaceId)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Files{Files: &radiov1.FileList{Paths: files}}}
	case *radiov1.Request_ReadFile:
		f, err := car.ReadFile(cmd.ReadFile.WorkspaceId, cmd.ReadFile.Path, cmd.ReadFile.MaxBytes)
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_File{File: f}}

	case *radiov1.Request_ResizeProcess:
		return c.resizeProcess(cmd.ResizeProcess)
	case *radiov1.Request_SignalProcess:
		return c.signalProcess(cmd.SignalProcess)

	case *radiov1.Request_CreateToken:
		info, secret, err := c.s.store.CreateToken(cmd.CreateToken.Name, cmd.CreateToken.Scope)
		if err != nil {
			return errResponse(radiov1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "%v", err)
		}
		return &radiov1.Response{Result: &radiov1.Response_CreatedToken{CreatedToken: &radiov1.CreatedToken{Info: info, Secret: secret}}}
	case *radiov1.Request_ListTokens:
		ts, err := c.s.store.Tokens()
		if err != nil {
			return fromError(err)
		}
		return &radiov1.Response{Result: &radiov1.Response_Tokens{Tokens: &radiov1.TokenList{Tokens: ts}}}
	case *radiov1.Request_RevokeToken:
		if err := c.s.store.RevokeToken(cmd.RevokeToken.TokenId); err != nil {
			return fromError(err)
		}
		return empty()
	}
	if resp, ok := c.executeSandbox(ctx, req); ok {
		return resp
	}
	return errResponse(radiov1.ErrorCode_ERROR_CODE_UNIMPLEMENTED, "command not implemented")
}

// executeSandbox handles the sandbox commands (80-87). ok is false for any other command.
func (c *conn) executeSandbox(ctx context.Context, req *radiov1.Request) (resp *radiov1.Response, ok bool) {
	switch req.Command.(type) {
	case *radiov1.Request_ListSandboxProviders, *radiov1.Request_SaveSandboxProvider, *radiov1.Request_RemoveSandboxProvider,
		*radiov1.Request_ListSandboxes, *radiov1.Request_GetSandbox, *radiov1.Request_CreateSandbox,
		*radiov1.Request_ChangeSandbox, *radiov1.Request_OpenSandboxAccess:
	default:
		return nil, false
	}
	m := c.s.sandboxes
	if m == nil {
		return errResponse(radiov1.ErrorCode_ERROR_CODE_UNIMPLEMENTED, "this Team Car has no sandbox providers"), true
	}
	switch cmd := req.Command.(type) {
	case *radiov1.Request_ListSandboxProviders:
		ps, err := m.Providers(ctx, cmd.ListSandboxProviders.CheckAccount)
		if err != nil {
			return fromError(err), true
		}
		return &radiov1.Response{Result: &radiov1.Response_SandboxProviders{SandboxProviders: &radiov1.SandboxProviderList{Providers: ps}}}, true
	case *radiov1.Request_SaveSandboxProvider:
		p, err := m.Save(cmd.SaveSandboxProvider.Provider, cmd.SaveSandboxProvider.ApiKey)
		if err != nil {
			return fromError(err), true
		}
		return &radiov1.Response{Result: &radiov1.Response_SandboxProvider{SandboxProvider: p}}, true
	case *radiov1.Request_RemoveSandboxProvider:
		if err := m.Remove(cmd.RemoveSandboxProvider.ProviderId); err != nil {
			return fromError(err), true
		}
		return empty(), true
	case *radiov1.Request_ListSandboxes:
		ss, err := m.List(ctx, cmd.ListSandboxes.ProviderId)
		if err != nil {
			return fromError(err), true
		}
		return &radiov1.Response{Result: &radiov1.Response_Sandboxes{Sandboxes: &radiov1.SandboxList{Sandboxes: ss}}}, true
	case *radiov1.Request_GetSandbox:
		s, err := m.Get(ctx, cmd.GetSandbox.ProviderId, cmd.GetSandbox.SandboxId)
		if err != nil {
			return fromError(err), true
		}
		return &radiov1.Response{Result: &radiov1.Response_Sandbox{Sandbox: s}}, true
	case *radiov1.Request_CreateSandbox:
		// The request's idempotency key also goes to the service, so a retry after a lost answer
		// (or a reconnect) never makes a second machine.
		s, err := m.Create(ctx, cmd.CreateSandbox, req.IdempotencyKey)
		if err != nil {
			return fromError(err), true
		}
		return &radiov1.Response{Result: &radiov1.Response_Sandbox{Sandbox: s}}, true
	case *radiov1.Request_ChangeSandbox:
		if err := m.Change(ctx, cmd.ChangeSandbox); err != nil {
			return fromError(err), true
		}
		return empty(), true
	case *radiov1.Request_OpenSandboxAccess:
		a, err := m.Access(ctx, cmd.OpenSandboxAccess)
		if err != nil {
			return fromError(err), true
		}
		return &radiov1.Response{Result: &radiov1.Response_SandboxAccess{SandboxAccess: a}}, true
	}
	return nil, false
}

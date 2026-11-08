package rpc

import (
	"context"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent"
)

// Scopes are ordered: each one includes everything below it.
//
//	READ     watch: subscriptions, lists, transcripts, diffs, files
//	TRIGGER  + create, import and archive workspaces, open sessions, prompt, approve, add repositories
//	OPERATE  + remove repositories, delete workspaces, run processes (Subscribe{process} and its
//	         input, resize and signal requests)
//	ADMIN    + tokens, sandbox providers, saving MCP servers
//
// Sandboxes: list/get are READ; create, resume, stop, rename and auto-stop are TRIGGER; delete,
// recover and access (SSH keys, desktop, port URLs) are OPERATE.
func required(req *domestiquev1.Request) domestiquev1.TokenScope {
	switch cmd := req.Command.(type) {
	case *domestiquev1.Request_CreateToken, *domestiquev1.Request_ListTokens, *domestiquev1.Request_RevokeToken,
		*domestiquev1.Request_SaveSandboxProvider, *domestiquev1.Request_RemoveSandboxProvider,
		*domestiquev1.Request_SaveMcpServer, *domestiquev1.Request_RemoveMcpServer:
		return domestiquev1.TokenScope_TOKEN_SCOPE_ADMIN
	case *domestiquev1.Request_OpenSandboxAccess, *domestiquev1.Request_ListMcpServers, *domestiquev1.Request_ResolveMcpConfig:
		return domestiquev1.TokenScope_TOKEN_SCOPE_OPERATE
	case *domestiquev1.Request_CreateSandbox:
		return domestiquev1.TokenScope_TOKEN_SCOPE_TRIGGER
	case *domestiquev1.Request_ChangeSandbox:
		switch cmd.ChangeSandbox.Action {
		case domestiquev1.SandboxAction_SANDBOX_ACTION_DELETE, domestiquev1.SandboxAction_SANDBOX_ACTION_RECOVER:
			return domestiquev1.TokenScope_TOKEN_SCOPE_OPERATE
		}
		return domestiquev1.TokenScope_TOKEN_SCOPE_TRIGGER
	case *domestiquev1.Request_RemoveRepository, *domestiquev1.Request_DeleteWorkspace,
		*domestiquev1.Request_ProcessInput, *domestiquev1.Request_ResizeProcess, *domestiquev1.Request_SignalProcess:
		return domestiquev1.TokenScope_TOKEN_SCOPE_OPERATE
	case *domestiquev1.Request_Subscribe:
		// Subscriptions only watch, except a process one, which runs a command.
		if cmd.Subscribe.GetProcess() != nil {
			return domestiquev1.TokenScope_TOKEN_SCOPE_OPERATE
		}
		return domestiquev1.TokenScope_TOKEN_SCOPE_READ
	case *domestiquev1.Request_AddRepository, *domestiquev1.Request_CreateWorkspace, *domestiquev1.Request_ArchiveWorkspace,
		*domestiquev1.Request_ImportWorkspace,
		*domestiquev1.Request_OpenSession, *domestiquev1.Request_CloseSession, *domestiquev1.Request_SendMessage,
		*domestiquev1.Request_Interrupt, *domestiquev1.Request_RespondApproval, *domestiquev1.Request_AnswerQuestion,
		*domestiquev1.Request_UpdateSession:
		return domestiquev1.TokenScope_TOKEN_SCOPE_TRIGGER
	default:
		return domestiquev1.TokenScope_TOKEN_SCOPE_READ
	}
}

func (c *conn) dispatch(req *domestiquev1.Request) {
	if req.Command == nil {
		c.respond(req.Id, errResponse(domestiquev1.ErrorCode_ERROR_CODE_UNIMPLEMENTED, "unknown or empty command"))
		return
	}
	if need := required(req); c.scope < need {
		c.respond(req.Id, errResponse(domestiquev1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "this token's scope (%v) doesn't allow this request (needs %v)", c.scope, need))
		return
	}
	// Subscriptions answer themselves (the response must precede the first event).
	switch cmd := req.Command.(type) {
	case *domestiquev1.Request_Subscribe:
		switch t := cmd.Subscribe.Target.(type) {
		case *domestiquev1.Subscribe_Server:
			c.subscribeServer(req.Id)
		case *domestiquev1.Subscribe_Session:
			c.subscribeSession(req.Id, t.Session)
		case *domestiquev1.Subscribe_Process:
			c.subscribeProcess(req.Id, t.Process)
		default:
			c.respond(req.Id, errResponse(domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "subscribe target is required"))
		}
		return
	}
	run := func() *domestiquev1.Response { return c.execute(c.ctx, req) }
	var resp *domestiquev1.Response
	if req.IdempotencyKey != "" {
		resp = c.s.idem.do(c.tokenID+"\x00"+req.IdempotencyKey, run)
	} else {
		resp = run()
	}
	c.respond(req.Id, resp)
}

func (c *conn) execute(ctx context.Context, req *domestiquev1.Request) *domestiquev1.Response {
	server := c.s.server
	switch cmd := req.Command.(type) {
	case *domestiquev1.Request_GetServerInfo:
		info := server.Info()
		if m := c.s.sandboxes; m != nil {
			if ps, err := m.Providers(ctx, false); err == nil {
				info.SandboxProviders = ps
			} else {
				c.s.log.Warn("sandbox providers", "err", err)
			}
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_ServerInfo{ServerInfo: info}}
	case *domestiquev1.Request_Unsubscribe:
		if !c.endSub(cmd.Unsubscribe.SubscriptionId) {
			return errResponse(domestiquev1.ErrorCode_ERROR_CODE_NOT_FOUND, "no subscription %d", cmd.Unsubscribe.SubscriptionId)
		}
		return empty()

	case *domestiquev1.Request_ListRepositories:
		return &domestiquev1.Response{Result: &domestiquev1.Response_Repositories{Repositories: &domestiquev1.RepositoryList{Repositories: server.Repositories()}}}
	case *domestiquev1.Request_AddRepository:
		r, err := server.AddRepository(ctx, cmd.AddRepository)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Repository{Repository: r}}
	case *domestiquev1.Request_RemoveRepository:
		if err := server.RemoveRepository(cmd.RemoveRepository.RepositoryId); err != nil {
			return fromError(err)
		}
		return empty()

	case *domestiquev1.Request_ListWorkspaces:
		ws := server.Workspaces(cmd.ListWorkspaces.RepositoryId, cmd.ListWorkspaces.IncludeArchived)
		return &domestiquev1.Response{Result: &domestiquev1.Response_Workspaces{Workspaces: &domestiquev1.WorkspaceList{Workspaces: ws}}}
	case *domestiquev1.Request_CreateWorkspace:
		ws, _, err := server.CreateWorkspace(ctx, cmd.CreateWorkspace)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Workspace{Workspace: ws}}
	case *domestiquev1.Request_ArchiveWorkspace:
		ws, err := server.ArchiveWorkspace(ctx, cmd.ArchiveWorkspace)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Workspace{Workspace: ws}}
	case *domestiquev1.Request_DeleteWorkspace:
		if err := server.DeleteWorkspace(ctx, cmd.DeleteWorkspace.WorkspaceId, cmd.DeleteWorkspace.DeleteBranch); err != nil {
			return fromError(err)
		}
		return empty()
	case *domestiquev1.Request_ImportWorkspace:
		ws, err := server.ImportWorkspace(cmd.ImportWorkspace)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Workspace{Workspace: ws}}

	case *domestiquev1.Request_OpenSession:
		r, err := server.OpenSession(cmd.OpenSession)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Session{Session: r}}
	case *domestiquev1.Request_CloseSession:
		if err := server.CloseSession(cmd.CloseSession.SessionId); err != nil {
			return fromError(err)
		}
		return empty()
	case *domestiquev1.Request_SendMessage:
		r, err := server.Session(cmd.SendMessage.SessionId)
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
	case *domestiquev1.Request_Interrupt:
		r, err := server.Session(cmd.Interrupt.SessionId)
		if err != nil {
			return fromError(err)
		}
		r.Interrupt(ctx)
		return empty()
	case *domestiquev1.Request_RespondApproval:
		r, err := server.Session(cmd.RespondApproval.SessionId)
		if err != nil {
			return fromError(err)
		}
		d := agent.Decision{Kind: cmd.RespondApproval.Decision, Message: cmd.RespondApproval.Message}
		if err := r.Respond(ctx, cmd.RespondApproval.RequestId, d); err != nil {
			return errResponse(domestiquev1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "%v", err)
		}
		return empty()
	case *domestiquev1.Request_AnswerQuestion:
		r, err := server.Session(cmd.AnswerQuestion.SessionId)
		if err != nil {
			return fromError(err)
		}
		if err := r.Answer(ctx, cmd.AnswerQuestion.RequestId, cmd.AnswerQuestion.Answers); err != nil {
			return errResponse(domestiquev1.ErrorCode_ERROR_CODE_FAILED_PRECONDITION, "%v", err)
		}
		return empty()
	case *domestiquev1.Request_UpdateSession:
		r, err := server.Session(cmd.UpdateSession.SessionId)
		if err != nil {
			return fromError(err)
		}
		r.Update(ctx, cmd.UpdateSession)
		return &domestiquev1.Response{Result: &domestiquev1.Response_Session{Session: r.Meta()}}
	case *domestiquev1.Request_ListModels:
		ms, err := server.Models(ctx, cmd.ListModels.Provider)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Models{Models: &domestiquev1.ModelList{Models: ms}}}
	case *domestiquev1.Request_GetTranscript:
		r, err := server.Session(cmd.GetTranscript.SessionId)
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
		page := &domestiquev1.TranscriptPage{NextSeq: cmd.GetTranscript.AfterSeq}
		if len(entries) > limit {
			entries, page.HasMore = entries[:limit], true
		}
		page.Entries = entries
		if n := len(entries); n > 0 {
			page.NextSeq = entries[n-1].Seq
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Transcript{Transcript: page}}

	case *domestiquev1.Request_GetDiff:
		d, err := server.Diff(ctx, cmd.GetDiff.WorkspaceId, cmd.GetDiff.Path)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Diff{Diff: d}}
	case *domestiquev1.Request_ListFiles:
		files, err := server.ListFiles(ctx, cmd.ListFiles.WorkspaceId)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Files{Files: &domestiquev1.FileList{Paths: files}}}
	case *domestiquev1.Request_ReadFile:
		f, err := server.ReadFile(cmd.ReadFile.WorkspaceId, cmd.ReadFile.Path, cmd.ReadFile.MaxBytes)
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_File{File: f}}

	case *domestiquev1.Request_ResizeProcess:
		return c.resizeProcess(cmd.ResizeProcess)
	case *domestiquev1.Request_SignalProcess:
		return c.signalProcess(cmd.SignalProcess)

	case *domestiquev1.Request_CreateToken:
		info, secret, err := c.s.store.CreateToken(cmd.CreateToken.Name, cmd.CreateToken.Scope)
		if err != nil {
			return errResponse(domestiquev1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "%v", err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_CreatedToken{CreatedToken: &domestiquev1.CreatedToken{Info: info, Secret: secret}}}
	case *domestiquev1.Request_ListTokens:
		ts, err := c.s.store.Tokens()
		if err != nil {
			return fromError(err)
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Tokens{Tokens: &domestiquev1.TokenList{Tokens: ts}}}
	case *domestiquev1.Request_RevokeToken:
		if err := c.s.store.RevokeToken(cmd.RevokeToken.TokenId); err != nil {
			return fromError(err)
		}
		return empty()
	}
	if resp, ok := c.executeSandbox(ctx, req); ok {
		return resp
	}
	if resp, ok := c.executeMcp(req); ok {
		return resp
	}
	return errResponse(domestiquev1.ErrorCode_ERROR_CODE_UNIMPLEMENTED, "command not implemented")
}

// executeSandbox handles the sandbox commands (80-87). ok is false for any other command.
func (c *conn) executeSandbox(ctx context.Context, req *domestiquev1.Request) (resp *domestiquev1.Response, ok bool) {
	switch req.Command.(type) {
	case *domestiquev1.Request_ListSandboxProviders, *domestiquev1.Request_SaveSandboxProvider, *domestiquev1.Request_RemoveSandboxProvider,
		*domestiquev1.Request_ListSandboxes, *domestiquev1.Request_GetSandbox, *domestiquev1.Request_CreateSandbox,
		*domestiquev1.Request_ChangeSandbox, *domestiquev1.Request_OpenSandboxAccess:
	default:
		return nil, false
	}
	m := c.s.sandboxes
	if m == nil {
		return errResponse(domestiquev1.ErrorCode_ERROR_CODE_UNIMPLEMENTED, "this server has no sandbox providers"), true
	}
	switch cmd := req.Command.(type) {
	case *domestiquev1.Request_ListSandboxProviders:
		ps, err := m.Providers(ctx, cmd.ListSandboxProviders.CheckAccount)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_SandboxProviders{SandboxProviders: &domestiquev1.SandboxProviderList{Providers: ps}}}, true
	case *domestiquev1.Request_SaveSandboxProvider:
		p, err := m.Save(cmd.SaveSandboxProvider.Provider, cmd.SaveSandboxProvider.ApiKey)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_SandboxProvider{SandboxProvider: p}}, true
	case *domestiquev1.Request_RemoveSandboxProvider:
		if err := m.Remove(cmd.RemoveSandboxProvider.ProviderId); err != nil {
			return fromError(err), true
		}
		return empty(), true
	case *domestiquev1.Request_ListSandboxes:
		ss, err := m.List(ctx, cmd.ListSandboxes.ProviderId)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Sandboxes{Sandboxes: &domestiquev1.SandboxList{Sandboxes: ss}}}, true
	case *domestiquev1.Request_GetSandbox:
		s, err := m.Get(ctx, cmd.GetSandbox.ProviderId, cmd.GetSandbox.SandboxId)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Sandbox{Sandbox: s}}, true
	case *domestiquev1.Request_CreateSandbox:
		// The request's idempotency key also goes to the service, so a retry after a lost answer
		// (or a reconnect) never makes a second machine.
		s, err := m.Create(ctx, cmd.CreateSandbox, req.IdempotencyKey)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_Sandbox{Sandbox: s}}, true
	case *domestiquev1.Request_ChangeSandbox:
		if err := m.Change(ctx, cmd.ChangeSandbox); err != nil {
			return fromError(err), true
		}
		return empty(), true
	case *domestiquev1.Request_OpenSandboxAccess:
		a, err := m.Access(ctx, cmd.OpenSandboxAccess)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_SandboxAccess{SandboxAccess: a}}, true
	}
	return nil, false
}

// executeMcp handles the MCP server commands (100-103). ok is false for any other command.
func (c *conn) executeMcp(req *domestiquev1.Request) (resp *domestiquev1.Response, ok bool) {
	m := c.s.mcp
	unavailable := errResponse(domestiquev1.ErrorCode_ERROR_CODE_UNIMPLEMENTED, "this server has no MCP servers")
	switch cmd := req.Command.(type) {
	case *domestiquev1.Request_ListMcpServers:
		if m == nil {
			return unavailable, true
		}
		list, err := m.List()
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_McpServers{McpServers: &domestiquev1.McpServerList{Servers: list}}}, true
	case *domestiquev1.Request_SaveMcpServer:
		if m == nil {
			return unavailable, true
		}
		s, err := m.Save(cmd.SaveMcpServer)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_McpServer{McpServer: s}}, true
	case *domestiquev1.Request_RemoveMcpServer:
		if m == nil {
			return unavailable, true
		}
		if err := m.Remove(cmd.RemoveMcpServer.ServerId); err != nil {
			return fromError(err), true
		}
		return empty(), true
	case *domestiquev1.Request_ResolveMcpConfig:
		if m == nil {
			return unavailable, true
		}
		config, n, err := m.Render(false)
		if err != nil {
			return fromError(err), true
		}
		return &domestiquev1.Response{Result: &domestiquev1.Response_McpConfig{McpConfig: &domestiquev1.McpConfig{Json: string(config), ServerCount: uint32(n)}}}, true
	}
	return nil, false
}

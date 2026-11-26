package core

import (
	"context"
	"time"

	"google.golang.org/protobuf/proto"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
)

// nameTimeout bounds one naming call; the placeholder title stays if it runs out.
const nameTimeout = 60 * time.Second

// autoName asks Options.Namer for names once a session's first prompt is sent. The chat gets its
// name unless it was renamed meanwhile (its title is no longer placeholder); the workspace gets one
// only if it has none yet, so the first prompt in a workspace names it and later chats don't.
func (c *Server) autoName(r *Session, placeholder, prompt string) {
	if c.opts.Namer == nil {
		return
	}
	ctx, cancel := context.WithTimeout(c.bg, nameTimeout)
	defer cancel()
	wsName, chatName, err := c.opts.Namer(ctx, prompt)
	if err != nil {
		if c.bg.Err() == nil {
			c.log.Warn("auto-name", "session", r.id(), "err", err)
		}
		return
	}
	r.mu.Lock()
	wsID := r.meta.WorkspaceId
	if chatName != "" && !r.closed && r.meta.Title == placeholder {
		r.meta.Title = chatName
		r.saveMetaLocked()
	}
	r.mu.Unlock()
	if wsName != "" {
		c.nameWorkspace(wsID, wsName)
	}
}

// nameWorkspace sets a workspace's title if it has none.
func (c *Server) nameWorkspace(id, title string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	w, ok := c.workspaces[id]
	if !ok || w.Title != "" {
		return
	}
	w.Title = title
	if err := c.store.PutWorkspace(w); err != nil {
		c.log.Error("persist workspace", "workspace", id, "err", err)
	}
	c.publishServer(&domestiquev1.Event{Payload: &domestiquev1.Event_WorkspaceUpserted{WorkspaceUpserted: proto.Clone(w).(*domestiquev1.Workspace)}})
}

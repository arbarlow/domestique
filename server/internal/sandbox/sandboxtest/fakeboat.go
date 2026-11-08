// Package sandboxtest is an in-memory boat.dev API for tests.
package sandboxtest

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// Boat fakes the parts of boat.dev's REST API that the server calls.
type Boat struct {
	*httptest.Server
	// The only API key it accepts.
	Key string

	mu        sync.Mutex
	sandboxes map[string]map[string]any
	order     []string
	byIdem    map[string]string
	// Every create body, in order.
	Creates []map[string]any
	// Public keys authorized per sandbox.
	SSHKeys map[string][]string
	Deleted []string
	next    int
}

func New(t *testing.T, key string) *Boat {
	b := &Boat{Key: key, sandboxes: map[string]map[string]any{}, byIdem: map[string]string{}, SSHKeys: map[string][]string{}}
	b.Server = httptest.NewServer(http.HandlerFunc(b.serve))
	t.Cleanup(b.Close)
	return b
}

// URL is the API base to give server.
func (b *Boat) URL() string { return b.Server.URL + "/api/v1" }

// SetState changes a sandbox's state (e.g. "archived").
func (b *Boat) SetState(id, state string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if s := b.sandboxes[id]; s != nil {
		s["state"] = state
	}
}

func (b *Boat) State(id string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if s := b.sandboxes[id]; s != nil {
		st, _ := s["state"].(string)
		return st
	}
	return ""
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func errorJSON(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": msg}})
}

func (b *Boat) serve(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer "+b.Key {
		errorJSON(w, 401, "unauthorized", "invalid API key")
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/api/v1")
	var body map[string]any
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "/me" && r.Method == http.MethodGet:
		writeJSON(w, 200, map[string]any{"user": map[string]any{"login": "session", "email": "session@example.com"}})
	case path == "/limits" && r.Method == http.MethodGet:
		writeJSON(w, 200, map[string]any{"canStart": true, "machineTypes": []any{map[string]any{"type": "default", "available": true}}})
	case path == "/sandboxes" && r.Method == http.MethodGet:
		list := []any{}
		for _, id := range b.order {
			if s := b.sandboxes[id]; s != nil {
				list = append(list, s)
			}
		}
		writeJSON(w, 200, map[string]any{"sandboxes": list})
	case path == "/sandboxes" && r.Method == http.MethodPost:
		b.Creates = append(b.Creates, body)
		if k := r.Header.Get("Idempotency-Key"); k != "" {
			if id, ok := b.byIdem[k]; ok {
				writeJSON(w, 201, map[string]any{"sandbox": map[string]any{"id": id}})
				return
			}
		}
		b.next++
		id := fmt.Sprintf("bx_%08d", b.next)
		s := map[string]any{"id": id, "state": "provisioning", "ip": "10.0.0.1", "createdAt": "2026-11-06T10:00:00Z"}
		for _, k := range []string{"name", "type", "environment"} {
			if v, ok := body[k]; ok {
				s[k] = v
			}
		}
		if v, ok := body["ttlSeconds"]; ok {
			s["ttlSeconds"] = v
		}
		b.sandboxes[id] = s
		b.order = append(b.order, id)
		if k := r.Header.Get("Idempotency-Key"); k != "" {
			b.byIdem[k] = id
		}
		writeJSON(w, 201, map[string]any{"sandbox": map[string]any{"id": id}})
	case len(parts) >= 2 && parts[0] == "sandboxes":
		id := parts[1]
		s := b.sandboxes[id]
		if s == nil {
			errorJSON(w, 404, "not_found", "no sandbox "+id)
			return
		}
		action := ""
		if len(parts) == 3 {
			action = parts[2]
		}
		switch {
		case action == "" && r.Method == http.MethodGet:
			writeJSON(w, 200, map[string]any{"sandbox": s})
		case action == "" && r.Method == http.MethodPatch:
			for k, v := range body {
				s[k] = v
			}
			writeJSON(w, 200, map[string]any{"sandbox": s})
		case action == "" && r.Method == http.MethodDelete:
			if r.Header.Get("X-Ascii-Confirm-Delete") != id {
				errorJSON(w, 400, "confirm", "missing delete confirmation")
				return
			}
			delete(b.sandboxes, id)
			b.Deleted = append(b.Deleted, id)
			w.WriteHeader(204)
		case action == "stop":
			s["state"] = "archived"
			writeJSON(w, 200, map[string]any{})
		case action == "resume":
			s["state"] = "ready"
			if v, ok := body["ttlSeconds"]; ok {
				s["ttlSeconds"] = v
			}
			writeJSON(w, 200, map[string]any{})
		case action == "recover":
			s["state"] = "ready"
			writeJSON(w, 200, map[string]any{})
		case action == "sshkey":
			k, _ := body["key"].(string)
			b.SSHKeys[id] = append(b.SSHKeys[id], k)
			writeJSON(w, 200, map[string]any{"machineIp": "10.0.0.1", "sshUser": "user", "hostKey": "ssh-ed25519 AAAAhost"})
		case action == "desktop":
			writeJSON(w, 200, map[string]any{"desktopUrl": "https://desk.example/" + id + "?" + r.URL.RawQuery})
		case action == "host":
			writeJSON(w, 200, map[string]any{"url": fmt.Sprintf("https://%v-%s.example", body["port"], id)})
		default:
			errorJSON(w, 404, "not_found", "no route")
		}
	default:
		errorJSON(w, 404, "not_found", "no route")
	}
}

package sandbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// DefaultBoatURL is boat.dev's REST API.
const DefaultBoatURL = "https://boat.dev/api/v1"

// APIError is a non-2xx answer from the service.
type APIError struct {
	Status  int
	Code    string
	Message string
	// A setup or billing page the user should open, when the service names one.
	URL string
}

func (e *APIError) Error() string { return e.Message }

// boatClient is one boat.dev account.
type boatClient struct {
	base  string
	token string
	http  *http.Client
}

func newBoatClient(base, token string, hc *http.Client) *boatClient {
	if base == "" {
		base = DefaultBoatURL
	}
	if hc == nil {
		hc = &http.Client{Timeout: 60 * time.Second}
	}
	return &boatClient{base: strings.TrimRight(base, "/"), token: token, http: hc}
}

// boatSandbox is the subset of boat's sandbox object Team Car passes on.
type boatSandbox struct {
	ID               string  `json:"id"`
	Name             string  `json:"name"`
	State            string  `json:"state"`
	Error            string  `json:"error"`
	Type             string  `json:"type"`
	VCPU             int32   `json:"vcpu"`
	MemoryGB         int32   `json:"memoryGB"`
	IP               string  `json:"ip"`
	SSHEndpoint      string  `json:"sshEndpoint"`
	URL              string  `json:"url"`
	DesktopAvailable *bool   `json:"desktopAvailable"`
	ArchiveAfter     string  `json:"archiveAfter"`
	TTLSeconds       *int32  `json:"ttlSeconds"`
	Health           string  `json:"health"`
	HealthReason     string  `json:"healthReason"`
	Hydrated         *bool   `json:"hydrated"`
	CreatedAt        string  `json:"createdAt"`
	StoppedAt        string  `json:"stoppedAt"`
	Environment      *string `json:"environment"`
}

// Phase normalises boat's state strings. Keep in step with BoatPhase in the Mac app (HostKit).
func Phase(state string) radiov1.SandboxPhase {
	switch state {
	case "init", "provisioning", "provisioned", "cloning":
		return radiov1.SandboxPhase_SANDBOX_PHASE_STARTING
	case "ready", "idle", "running":
		return radiov1.SandboxPhase_SANDBOX_PHASE_RUNNING
	case "archiving":
		return radiov1.SandboxPhase_SANDBOX_PHASE_STOPPING
	case "archived":
		return radiov1.SandboxPhase_SANDBOX_PHASE_STOPPED
	case "cancelled":
		return radiov1.SandboxPhase_SANDBOX_PHASE_GONE
	}
	return radiov1.SandboxPhase_SANDBOX_PHASE_ERROR
}

func millis(s string) int64 {
	if s == "" {
		return 0
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.UnixMilli()
		}
	}
	return 0
}

func (b boatSandbox) proto(providerID string) *radiov1.Sandbox {
	s := &radiov1.Sandbox{
		Id: b.ID, ProviderId: providerID, Name: b.Name, State: b.State, Phase: Phase(b.State), Error: b.Error,
		MachineType: b.Type, Vcpu: b.VCPU, MemoryGb: b.MemoryGB, Ip: b.IP, SshEndpoint: b.SSHEndpoint, Url: b.URL,
		DesktopAvailable: b.DesktopAvailable, ArchiveAfterMs: millis(b.ArchiveAfter), TtlSeconds: b.TTLSeconds,
		Health: b.Health, HealthReason: b.HealthReason, Hydrated: b.Hydrated,
		CreatedAtMs: millis(b.CreatedAt), StoppedAtMs: millis(b.StoppedAt),
	}
	if b.Environment != nil {
		s.Environment = *b.Environment
	}
	return s
}

func (c *boatClient) do(ctx context.Context, method, path string, body any, headers map[string]string, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	for attempt := 1; ; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, c.base+path, rd)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+c.token)
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", "Team Car (Domestique)")
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		resp, err := c.http.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			// Network trouble: status 0 reaches clients as UNAVAILABLE (try again).
			return &APIError{Message: "Couldn't reach boat.dev: " + err.Error()}
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		resp.Body.Close()
		if err != nil {
			return err
		}
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			if out == nil || len(data) == 0 {
				return nil
			}
			return json.Unmarshal(data, out)
		}
		// Transient: capacity, and rate limits / server errors on reads.
		retry := resp.StatusCode == 503 || (method == http.MethodGet && (resp.StatusCode == 429 || resp.StatusCode >= 500))
		if retry && attempt < 4 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(attempt) * 1500 * time.Millisecond):
			}
			if body != nil {
				b, _ := json.Marshal(body)
				rd = bytes.NewReader(b)
			}
			continue
		}
		return parseError(resp.StatusCode, data)
	}
}

func parseError(status int, data []byte) *APIError {
	var obj struct {
		Code    string `json:"code"`
		Message string `json:"message"`
		URL     string `json:"url"`
		Error   *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
			Details struct {
				SetupURL   string `json:"setupUrl"`
				BillingURL string `json:"billingUrl"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(data, &obj)
	e := &APIError{Status: status, Code: obj.Code, Message: obj.Message, URL: obj.URL}
	if obj.Error != nil {
		if e.Code == "" {
			e.Code = obj.Error.Code
		}
		if e.Message == "" {
			e.Message = obj.Error.Message
		}
		if u := obj.Error.Details.SetupURL; u != "" {
			e.URL = u
		} else if u := obj.Error.Details.BillingURL; u != "" {
			e.URL = u
		}
	}
	if e.Message == "" {
		e.Message = strings.TrimSpace(string(data[:min(len(data), 300)]))
	}
	if e.Message == "" {
		e.Message = fmt.Sprintf("HTTP %d", status)
	}
	if status == 401 {
		e.Message = "boat.dev rejected the API key (" + e.Message + ")"
	}
	return e
}

func (c *boatClient) sandbox(ctx context.Context, id string) (boatSandbox, error) {
	var out struct {
		Sandbox boatSandbox `json:"sandbox"`
	}
	err := c.do(ctx, http.MethodGet, "/sandboxes/"+url.PathEscape(id), nil, nil, &out)
	return out.Sandbox, err
}

func (c *boatClient) list(ctx context.Context) ([]boatSandbox, error) {
	var out struct {
		Sandboxes []boatSandbox `json:"sandboxes"`
	}
	err := c.do(ctx, http.MethodGet, "/sandboxes?limit=200", nil, nil, &out)
	return out.Sandboxes, err
}

type boatCreate struct {
	Name string
	Type string
	// nil = boat's default window. Ignored when DisableAutoStop.
	TTLSeconds      *int64
	DisableAutoStop bool
	Environment     string
	From            string
	Labels          map[string]string
}

// MarshalJSON sends "ttlSeconds": null for "never auto-stop", which is how boat spells it.
func (b boatCreate) MarshalJSON() ([]byte, error) {
	m := map[string]any{}
	if b.Name != "" {
		m["name"] = b.Name
	}
	if b.Type != "" {
		m["type"] = b.Type
	}
	if b.DisableAutoStop {
		m["ttlSeconds"] = nil
	} else if b.TTLSeconds != nil {
		m["ttlSeconds"] = *b.TTLSeconds
	}
	if b.Environment != "" {
		m["environment"] = b.Environment
	}
	if b.From != "" {
		m["from"] = b.From
	}
	if len(b.Labels) > 0 {
		m["labels"] = b.Labels
	}
	return json.Marshal(m)
}

// create starts a sandbox and returns its id (still starting).
func (c *boatClient) create(ctx context.Context, req boatCreate, idempotencyKey string) (string, error) {
	var out struct {
		ID      string `json:"id"`
		Sandbox struct {
			ID string `json:"id"`
		} `json:"sandbox"`
	}
	var h map[string]string
	if idempotencyKey != "" {
		h = map[string]string{"Idempotency-Key": idempotencyKey}
	}
	if err := c.do(ctx, http.MethodPost, "/sandboxes", req, h, &out); err != nil {
		return "", err
	}
	if out.Sandbox.ID != "" {
		return out.Sandbox.ID, nil
	}
	if out.ID != "" {
		return out.ID, nil
	}
	return "", &APIError{Message: "boat.dev didn't return a sandbox id"}
}

func (c *boatClient) post(ctx context.Context, id, action string, body any) error {
	if body == nil {
		body = map[string]any{}
	}
	return c.do(ctx, http.MethodPost, "/sandboxes/"+url.PathEscape(id)+"/"+action, body, nil, nil)
}

func (c *boatClient) patch(ctx context.Context, id string, body map[string]any) error {
	return c.do(ctx, http.MethodPatch, "/sandboxes/"+url.PathEscape(id), body, nil, nil)
}

func (c *boatClient) delete(ctx context.Context, id string) error {
	return c.do(ctx, http.MethodDelete, "/sandboxes/"+url.PathEscape(id), nil, map[string]string{"X-Ascii-Confirm-Delete": id}, nil)
}

func (c *boatClient) sshKey(ctx context.Context, id, publicKey string) (*radiov1.SandboxAccess, error) {
	var out struct {
		MachineIP   string `json:"machineIp"`
		SSHUser     string `json:"sshUser"`
		SSHEndpoint string `json:"sshEndpoint"`
		HostKey     string `json:"hostKey"`
	}
	if err := c.do(ctx, http.MethodPost, "/sandboxes/"+url.PathEscape(id)+"/sshkey", map[string]string{"key": publicKey}, nil, &out); err != nil {
		return nil, err
	}
	return &radiov1.SandboxAccess{SshUser: out.SSHUser, MachineIp: out.MachineIP, SshEndpoint: out.SSHEndpoint, HostKey: out.HostKey}, nil
}

func (c *boatClient) desktop(ctx context.Context, id string, dark *bool) (string, error) {
	path := "/sandboxes/" + url.PathEscape(id) + "/desktop"
	if dark != nil {
		if *dark {
			path += "?theme=dark"
		} else {
			path += "?theme=light"
		}
	}
	var out struct {
		DesktopURL string `json:"desktopUrl"`
		ViewerURL  string `json:"viewerUrl"`
		URL        string `json:"url"`
	}
	if err := c.do(ctx, http.MethodPost, path, map[string]any{}, nil, &out); err != nil {
		return "", err
	}
	for _, u := range []string{out.DesktopURL, out.ViewerURL, out.URL} {
		if u != "" {
			return u, nil
		}
	}
	return "", &APIError{Message: "The desktop isn't available yet. Try again in a few seconds."}
}

func (c *boatClient) host(ctx context.Context, id string, port uint32, public bool, title string) (string, error) {
	body := map[string]any{"port": port, "public": public, "localhost": true}
	if title != "" {
		body["title"] = title
	}
	var out struct {
		URL string `json:"url"`
	}
	if err := c.do(ctx, http.MethodPost, "/sandboxes/"+url.PathEscape(id)+"/host", body, nil, &out); err != nil {
		return "", err
	}
	if out.URL == "" {
		return "", &APIError{Message: fmt.Sprintf("boat.dev didn't return a URL for port %d", port)}
	}
	return out.URL, nil
}

func (c *boatClient) account(ctx context.Context) *radiov1.SandboxAccount {
	acct := &radiov1.SandboxAccount{}
	var me struct {
		User struct {
			Login       string `json:"login"`
			Email       string `json:"email"`
			DisplayName string `json:"displayName"`
		} `json:"user"`
	}
	if err := c.do(ctx, http.MethodGet, "/me", nil, nil, &me); err != nil {
		acct.Error = err.Error()
		return acct
	}
	acct.Login, acct.Email, acct.DisplayName = me.User.Login, me.User.Email, me.User.DisplayName
	var lim struct {
		CanStart           *bool  `json:"canStart"`
		TrialLine          string `json:"trialLine"`
		StartBlockedReason string `json:"startBlockedReason"`
		MachineTypes       []struct {
			Type      string `json:"type"`
			Available bool   `json:"available"`
			Reason    string `json:"reason"`
		} `json:"machineTypes"`
	}
	if err := c.do(ctx, http.MethodGet, "/limits", nil, nil, &lim); err != nil {
		acct.CanStart = true // limits are advisory
		return acct
	}
	acct.CanStart = lim.CanStart == nil || *lim.CanStart
	acct.TrialLine, acct.StartBlockedReason = lim.TrialLine, lim.StartBlockedReason
	for _, m := range lim.MachineTypes {
		acct.MachineTypes = append(acct.MachineTypes, &radiov1.SandboxMachineType{Type: m.Type, Available: m.Available, Reason: m.Reason})
	}
	return acct
}

package claude

import (
	"context"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/agent/lineproc"
	ts "github.com/arbarlow/domestique/server/internal/agent/toolsummary"
	"google.golang.org/protobuf/proto"
)

// shortName trims "Default (recommended)" style names for the compact picker.
func shortName(s string) string { return strings.ReplaceAll(s, " (recommended)", "") }

// ParseModels reads the model list from an `initialize` response. The "default" entry is named
// after the model it resolves to ("Opus 5.5") rather than "Default".
func ParseModels(resp ts.JSON) []*domestiquev1.ModelOption {
	models := resp.Get("models").Arr()
	nameByResolved := map[string]string{}
	for _, m := range models {
		r, ok1 := m.Get("resolvedModel").Str()
		n, ok2 := m.Get("displayName").Str()
		if m.Get("value").S() == "default" || !ok1 || !ok2 {
			continue
		}
		if _, dup := nameByResolved[r]; !dup {
			nameByResolved[r] = n
		}
	}
	var out []*domestiquev1.ModelOption
	for _, m := range models {
		value, ok := m.Get("value").Str()
		if !ok {
			continue
		}
		var efforts []string
		for _, e := range m.Get("supportedEffortLevels").Arr() {
			if s, ok := e.Str(); ok {
				efforts = append(efforts, s)
			}
		}
		display, ok := m.Get("displayName").Str()
		if !ok {
			display = value
		}
		name := shortName(display)
		description, hasDescription := m.Get("description").Str()
		if value == "default" {
			resolvedName := ""
			if r, ok := m.Get("resolvedModel").Str(); ok {
				resolvedName = nameByResolved[r]
			}
			if resolvedName == "" && hasDescription {
				resolvedName, _, _ = strings.Cut(description, " · ")
			}
			if resolvedName != "" {
				name = resolvedName
			}
			if _, after, found := strings.Cut(description, " · "); found {
				description = after
			}
		}
		defaultEffort := ""
		if slices.Contains(efforts, "high") {
			defaultEffort = "high"
		} else if len(efforts) > 0 {
			defaultEffort = efforts[len(efforts)-1]
		}
		out = append(out, &domestiquev1.ModelOption{
			Id: value, DisplayName: name, Description: description, Efforts: efforts,
			DefaultEffort: defaultEffort, IsDefault: value == "default",
		})
	}
	return out
}

// ProbeModels asks the installed `claude` for its model list without starting a conversation.
func ProbeModels(ctx context.Context, executable string) ([]*domestiquev1.ModelOption, error) {
	exe, err := lineproc.LookPath(executable, "claude")
	if err != nil {
		return nil, err
	}
	p, err := lineproc.Start(lineproc.Options{
		Path: exe,
		Args: []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"},
		Dir:  os.TempDir(),
		Env:  lineproc.Environ(map[string]string{"CLAUDE_CODE_ENTRYPOINT": Entrypoint}),
	})
	if err != nil {
		return nil, err
	}
	defer func() {
		p.CloseInput()
		p.Terminate()
		go func() {
			for range p.Lines() {
			}
		}()
	}()
	if err := p.WriteJSON(map[string]any{
		"type": "control_request", "request_id": "dq_probe",
		"request": map[string]any{"subtype": "initialize", "hooks": nil},
	}); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case line, ok := <-p.Lines():
			if !ok {
				return nil, errProbeFailed
			}
			msg, err := ts.ParseJSON(line)
			if err != nil || msg.Get("type").S() != "control_response" || msg.Path("response", "request_id").S() != "dq_probe" {
				continue
			}
			options := ParseModels(msg.Path("response", "response"))
			if len(options) == 0 {
				return nil, errProbeFailed
			}
			return options, nil
		}
	}
}

type probeError string

func (e probeError) Error() string { return string(e) }

const errProbeFailed = probeError("claude didn't report its models")

var modelCache struct {
	sync.Mutex
	models []*domestiquev1.ModelOption
	at     time.Time
}

const modelCacheTTL = 10 * time.Minute

// ModelLister probes the installed CLI (cached for a few minutes) and falls back to
// FallbackModels when it can't.
func ModelLister(ctx context.Context) ([]*domestiquev1.ModelOption, error) {
	modelCache.Lock()
	if modelCache.models != nil && time.Since(modelCache.at) < modelCacheTTL {
		out := cloneModels(modelCache.models)
		modelCache.Unlock()
		return out, nil
	}
	modelCache.Unlock()
	models, err := ProbeModels(ctx, "")
	if err != nil {
		return FallbackModels(), nil
	}
	modelCache.Lock()
	modelCache.models = models
	modelCache.at = time.Now()
	modelCache.Unlock()
	return cloneModels(models), nil
}

func cloneModels(in []*domestiquev1.ModelOption) []*domestiquev1.ModelOption {
	out := make([]*domestiquev1.ModelOption, len(in))
	for i, m := range in {
		out[i] = proto.Clone(m).(*domestiquev1.ModelOption)
	}
	return out
}

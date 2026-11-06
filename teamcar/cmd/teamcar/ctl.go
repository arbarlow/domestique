package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/arbarlow/domestique/teamcar/client"
	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

const ctlUsage = `teamcar ctl: drive a Team Car from the terminal (built on the Go SDK)

Global flags (before the command):
  --url URL      unix:///path.sock, ws://host:port or wss://host:port (default: local socket, or $TEAMCAR_URL)
  --token TOKEN  bearer token (default: $TEAMCAR_TOKEN)

Commands:
  info                                   server info
  repos                                  list repositories
  add-repo PATH|URL                      add a local clone or clone a URL on the server
  workspaces [--all]                     list workspaces
  new REPO [--name N] [--base B] [--prompt P] [--provider claude|codex] [--mode bypass|auto|ask]
                                         create a workspace (waits until it's ready)
  archive WORKSPACE [--delete-branch]
  riders [WORKSPACE]                     list riders (chat tabs)
  open WORKSPACE [--provider P] [--mode M] [--model M]
                                         open a rider and print its id
  chat RIDER [--approve] PROMPT [FOLLOW-UP...]
                                         send prompts one turn at a time, streaming events
  watch RIDER [--from SEQ]               stream a rider's transcript and live events
  diff WORKSPACE [PATH]                  changes against the merge base
  files WORKSPACE
  cat WORKSPACE PATH
  models claude|codex
`

func ctl(args []string) error {
	fs := flag.NewFlagSet("ctl", flag.ExitOnError)
	fs.Usage = func() { fmt.Fprint(os.Stderr, ctlUsage) }
	urlFlag := fs.String("url", os.Getenv("TEAMCAR_URL"), "Team Car URL")
	token := fs.String("token", os.Getenv("TEAMCAR_TOKEN"), "bearer token")
	_ = fs.Parse(args)
	rest := fs.Args()
	if len(rest) == 0 || rest[0] == "help" {
		fs.Usage()
		return nil
	}
	u := *urlFlag
	if u == "" {
		u = "unix://" + defaultSocket(homeDir())
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	c, err := client.Dial(ctx, u, client.WithToken(*token), client.WithClientName("teamcar ctl "+version))
	if err != nil {
		return err
	}
	defer c.Close()
	cmd, cargs := rest[0], rest[1:]
	switch cmd {
	case "info":
		info, err := c.ServerInfo(ctx)
		if err != nil {
			return err
		}
		var ps []string
		for _, p := range info.Providers {
			ps = append(ps, providerName(p))
		}
		fmt.Printf("name:       %s\nid:         %s\nversion:    %s\nplatform:   %s\nworkspaces: %s\nproviders:  %s\nscope:      %s\n",
			info.ServerName, info.ServerId, info.ServerVersion, info.Platform, info.WorkspacesRoot, strings.Join(ps, ", "), scopeName(c.Welcome().Scope))
	case "repos":
		repos, err := c.Repositories(ctx)
		if err != nil {
			return err
		}
		for _, r := range repos {
			fmt.Printf("%s\t%s\t%s\t%s\n", r.Id, r.Name, r.DefaultBranch, r.Path)
		}
	case "add-repo":
		if len(cargs) != 1 {
			return errors.New("usage: add-repo PATH|URL")
		}
		req := &radiov1.AddRepository{Path: cargs[0]}
		if strings.Contains(cargs[0], "://") || strings.HasPrefix(cargs[0], "git@") {
			req = &radiov1.AddRepository{CloneUrl: cargs[0]}
		}
		r, err := c.AddRepository(ctx, req)
		if err != nil {
			return err
		}
		fmt.Printf("%s\t%s\t%s\n", r.Id, r.Name, r.Path)
	case "workspaces":
		f := flag.NewFlagSet("workspaces", flag.ExitOnError)
		all := f.Bool("all", false, "include archived")
		_ = f.Parse(cargs)
		ws, err := c.Workspaces(ctx, "", *all)
		if err != nil {
			return err
		}
		for _, w := range ws {
			state := strings.ToLower(strings.TrimPrefix(w.State.String(), "WORKSPACE_STATE_"))
			fmt.Printf("%s\t%s\t%s\t%s\t%s\n", w.Id, w.Name, state, w.Branch, w.Path)
		}
	case "new":
		return ctlNew(ctx, c, cargs)
	case "archive":
		f := flag.NewFlagSet("archive", flag.ExitOnError)
		del := f.Bool("delete-branch", false, "also delete the branch")
		_ = f.Parse(reorder(cargs))
		if f.NArg() != 1 {
			return errors.New("usage: archive WORKSPACE [--delete-branch]")
		}
		ws, err := findWorkspace(ctx, c, f.Arg(0))
		if err != nil {
			return err
		}
		_, err = c.ArchiveWorkspace(ctx, ws.Id, *del)
		return err
	case "riders":
		wsID := ""
		if len(cargs) > 0 {
			ws, err := findWorkspace(ctx, c, cargs[0])
			if err != nil {
				return err
			}
			wsID = ws.Id
		}
		riders, err := c.Riders(ctx, wsID)
		if err != nil {
			return err
		}
		for _, r := range riders {
			act := strings.ToLower(strings.TrimPrefix(r.Activity.String(), "RIDER_ACTIVITY_"))
			fmt.Printf("%s\t%s\t%s\t%s\tseq %d\n", r.Id, providerName(r.Provider), act, r.Title, r.LastSeq)
		}
	case "open":
		f := flag.NewFlagSet("open", flag.ExitOnError)
		provider := f.String("provider", "claude", "claude or codex")
		mode := f.String("mode", "bypass", "bypass, auto or ask")
		model := f.String("model", "", "model id (default: provider default)")
		_ = f.Parse(reorder(cargs))
		if f.NArg() != 1 {
			return errors.New("usage: open WORKSPACE")
		}
		ws, err := findWorkspace(ctx, c, f.Arg(0))
		if err != nil {
			return err
		}
		p, m, err := parseProviderMode(*provider, *mode)
		if err != nil {
			return err
		}
		r, err := c.OpenRider(ctx, &radiov1.OpenRider{WorkspaceId: ws.Id, Provider: p, PermissionMode: m, Model: *model})
		if err != nil {
			return err
		}
		fmt.Println(r.Id)
	case "chat":
		return ctlChat(ctx, c, cargs)
	case "watch":
		f := flag.NewFlagSet("watch", flag.ExitOnError)
		from := f.Uint64("from", 0, "replay items after this seq")
		_ = f.Parse(reorder(cargs))
		if f.NArg() != 1 {
			return errors.New("usage: watch RIDER")
		}
		sub, err := c.SubscribeRider(ctx, f.Arg(0), client.RiderOptions{FromSeq: *from})
		if err != nil {
			return err
		}
		defer sub.Close()
		p := newPrinter()
		for ev := range sub.Events() {
			p.print(ev)
		}
		return sub.Err()
	case "diff":
		if len(cargs) < 1 {
			return errors.New("usage: diff WORKSPACE [PATH]")
		}
		ws, err := findWorkspace(ctx, c, cargs[0])
		if err != nil {
			return err
		}
		path := ""
		if len(cargs) > 1 {
			path = cargs[1]
		}
		d, err := c.Diff(ctx, ws.Id, path)
		if err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "base %s, ahead %d, behind %d, %d files\n", short(d.Base, 12), d.Ahead, d.Behind, len(d.Files))
		for _, f := range d.Files {
			if f.Patch != "" {
				fmt.Print(f.Patch)
			} else {
				fmt.Printf("# %s (%s, no text diff)\n", f.Path, strings.ToLower(strings.TrimPrefix(f.Status.String(), "FILE_DIFF_STATUS_")))
			}
		}
	case "files":
		if len(cargs) != 1 {
			return errors.New("usage: files WORKSPACE")
		}
		ws, err := findWorkspace(ctx, c, cargs[0])
		if err != nil {
			return err
		}
		files, err := c.Files(ctx, ws.Id)
		if err != nil {
			return err
		}
		fmt.Println(strings.Join(files, "\n"))
	case "cat":
		if len(cargs) != 2 {
			return errors.New("usage: cat WORKSPACE PATH")
		}
		ws, err := findWorkspace(ctx, c, cargs[0])
		if err != nil {
			return err
		}
		f, err := c.ReadFile(ctx, ws.Id, cargs[1], 0)
		if err != nil {
			return err
		}
		_, err = os.Stdout.Write(f.Data)
		return err
	case "models":
		if len(cargs) != 1 {
			return errors.New("usage: models claude|codex")
		}
		p, _, err := parseProviderMode(cargs[0], "bypass")
		if err != nil {
			return err
		}
		ms, err := c.Models(ctx, p)
		if err != nil {
			return err
		}
		for _, m := range ms {
			def := ""
			if m.IsDefault {
				def = " (default)"
			}
			fmt.Printf("%s\t%s%s\t%s\n", m.Id, m.DisplayName, def, strings.Join(m.Efforts, ","))
		}
	default:
		fs.Usage()
		return fmt.Errorf("unknown command %q", cmd)
	}
	return nil
}

// reorder moves flags before positional args so "archive ws --delete-branch" works.
func reorder(args []string) []string {
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if strings.HasPrefix(a, "-") && len(a) > 1 {
			flags = append(flags, a)
			if !strings.Contains(a, "=") && i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") && !isBoolFlag(a) {
				flags = append(flags, args[i+1])
				i++
			}
			continue
		}
		pos = append(pos, a)
	}
	return append(flags, pos...)
}

func isBoolFlag(a string) bool {
	switch strings.TrimLeft(a, "-") {
	case "all", "delete-branch", "approve", "wait":
		return true
	}
	return false
}

func ctlNew(ctx context.Context, c *client.Client, args []string) error {
	f := flag.NewFlagSet("new", flag.ExitOnError)
	name := f.String("name", "", "workspace name (default: a random climb)")
	base := f.String("base", "", "base branch (default: the repository's default)")
	prompt := f.String("prompt", "", "first prompt for a new rider")
	provider := f.String("provider", "claude", "claude or codex")
	mode := f.String("mode", "bypass", "bypass, auto or ask")
	_ = f.Parse(reorder(args))
	if f.NArg() != 1 {
		return errors.New("usage: new REPO [flags]")
	}
	repo, err := findRepo(ctx, c, f.Arg(0))
	if err != nil {
		return err
	}
	p, m, err := parseProviderMode(*provider, *mode)
	if err != nil {
		return err
	}
	req := &radiov1.CreateWorkspace{RepositoryId: repo.Id, Name: *name, BaseBranch: *base, Prompt: *prompt,
		Rider: &radiov1.OpenRider{Provider: p, PermissionMode: m}}
	ws, err := c.CreateWorkspace(ctx, req)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "creating %s on branch %s…\n", ws.Name, ws.Branch)
	ws, err = c.WaitWorkspace(ctx, ws.Id)
	if err != nil {
		return err
	}
	fmt.Printf("%s\t%s\t%s\n", ws.Id, ws.Name, ws.Path)
	if *prompt != "" {
		riders, err := c.Riders(ctx, ws.Id)
		if err == nil && len(riders) > 0 {
			fmt.Fprintf(os.Stderr, "rider %s is working on it: teamcar ctl watch %s\n", riders[0].Id, riders[0].Id)
		}
	}
	return nil
}

func ctlChat(ctx context.Context, c *client.Client, args []string) error {
	f := flag.NewFlagSet("chat", flag.ExitOnError)
	approve := f.Bool("approve", false, "approve every approval request (default: deny)")
	_ = f.Parse(reorder(args))
	if f.NArg() < 2 {
		return errors.New("usage: chat RIDER PROMPT [FOLLOW-UP...]")
	}
	rider := f.Arg(0)
	p := newPrinter()
	for _, prompt := range f.Args()[1:] {
		fmt.Printf("%s → %s\n", p.t(), prompt)
		turn, err := c.Prompt(ctx, rider, prompt, client.PromptOptions{
			OnEvent: p.print,
			OnApproval: func(a *radiov1.ApprovalRequest) radiov1.Decision {
				if *approve {
					fmt.Printf("%s ✓ approving %s\n", p.t(), a.Title)
					return radiov1.Decision_DECISION_APPROVE
				}
				fmt.Printf("%s ✗ denying %s\n", p.t(), a.Title)
				return radiov1.Decision_DECISION_DENY
			},
		})
		if err != nil {
			return err
		}
		_ = turn
	}
	return nil
}

// printer renders events compactly, like dq.
type printer struct {
	start    time.Time
	streamed map[string]bool
}

func newPrinter() *printer { return &printer{start: time.Now(), streamed: map[string]bool{}} }

func (p *printer) t() string { return fmt.Sprintf("%6.2fs", time.Since(p.start).Seconds()) }

func (p *printer) print(ev *radiov1.Event) {
	switch e := ev.Payload.(type) {
	case *radiov1.Event_ItemUpserted:
		it := e.ItemUpserted
		switch k := it.Kind.(type) {
		case *radiov1.TranscriptItem_User:
			fmt.Printf("%s [%d] » %s\n", p.t(), ev.Seq, short(k.User, 160))
		case *radiov1.TranscriptItem_Assistant:
			if k.Assistant != "" {
				fmt.Printf("%s [%d] ◆ %s\n", p.t(), ev.Seq, short(k.Assistant, 160))
			}
		case *radiov1.TranscriptItem_Reasoning:
			if k.Reasoning != "" {
				fmt.Printf("%s [%d] ∴ %s\n", p.t(), ev.Seq, short(k.Reasoning, 80))
			}
		case *radiov1.TranscriptItem_Tool:
			st := strings.ToLower(strings.TrimPrefix(k.Tool.Status.String(), "TOOL_STATUS_"))
			out := ""
			if k.Tool.Output != "" {
				out = " → " + short(k.Tool.Output, 80)
			}
			fmt.Printf("%s [%d] ⚙ %s [%s] %s%s\n", p.t(), ev.Seq, k.Tool.Name, st, short(k.Tool.Summary, 100), out)
		case *radiov1.TranscriptItem_Approval:
			res := strings.ToLower(strings.TrimPrefix(k.Approval.Resolution.String(), "APPROVAL_RESOLUTION_"))
			fmt.Printf("%s [%d] ? %s (%s)\n", p.t(), ev.Seq, k.Approval.Title, res)
		case *radiov1.TranscriptItem_Notice:
			fmt.Printf("%s [%d] ℹ %s\n", p.t(), ev.Seq, short(k.Notice, 160))
		case *radiov1.TranscriptItem_Error:
			fmt.Printf("%s [%d] ✖ %s\n", p.t(), ev.Seq, short(k.Error, 300))
		case *radiov1.TranscriptItem_TurnSummary:
			s := k.TurnSummary
			fmt.Printf("%s [%d] ■ turn done %dms $%.4f in=%d out=%d%s\n", p.t(), ev.Seq, s.GetDurationMs(), s.GetCostUsd(),
				s.GetInputTokens(), s.GetOutputTokens(), map[bool]string{true: " (error: " + s.Message + ")", false: ""}[s.IsError])
		case *radiov1.TranscriptItem_Trigger:
			fmt.Printf("%s [%d] ↻ %s\n", p.t(), ev.Seq, k.Trigger)
		}
	case *radiov1.Event_AppendText:
		if !p.streamed[e.AppendText.ItemId] {
			p.streamed[e.AppendText.ItemId] = true
			fmt.Printf("%s … streaming %s\n", p.t(), e.AppendText.ItemId)
		}
	case *radiov1.Event_TurnStarted:
		fmt.Printf("%s ▶ turn started\n", p.t())
	case *radiov1.Event_Status:
		if e.Status.Text != "" {
			fmt.Printf("%s ~ %s\n", p.t(), e.Status.Text)
		}
	case *radiov1.Event_Task:
		fmt.Printf("%s ⑂ subagent %s: %s\n", p.t(), strings.ToLower(strings.TrimPrefix(e.Task.Status.String(), "AGENT_TASK_STATUS_")), e.Task.Description)
	case *radiov1.Event_Exited:
		fmt.Printf("%s ⏻ agent exited %s\n", p.t(), e.Exited.Message)
	case *radiov1.Event_ReplayDone:
		fmt.Printf("%s — live (seq %d) —\n", p.t(), ev.Seq)
	}
}

func short(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", "⏎")
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}

func providerName(p radiov1.Provider) string {
	return strings.ToLower(strings.TrimPrefix(p.String(), "PROVIDER_"))
}

func parseProviderMode(provider, mode string) (radiov1.Provider, radiov1.PermissionMode, error) {
	var p radiov1.Provider
	switch provider {
	case "claude":
		p = radiov1.Provider_PROVIDER_CLAUDE
	case "codex":
		p = radiov1.Provider_PROVIDER_CODEX
	default:
		return 0, 0, fmt.Errorf("unknown provider %q", provider)
	}
	var m radiov1.PermissionMode
	switch mode {
	case "bypass":
		m = radiov1.PermissionMode_PERMISSION_MODE_BYPASS
	case "auto":
		m = radiov1.PermissionMode_PERMISSION_MODE_AUTO
	case "ask":
		m = radiov1.PermissionMode_PERMISSION_MODE_ASK
	default:
		return 0, 0, fmt.Errorf("unknown mode %q", mode)
	}
	return p, m, nil
}

func findRepo(ctx context.Context, c *client.Client, ref string) (*radiov1.Repository, error) {
	repos, err := c.Repositories(ctx)
	if err != nil {
		return nil, err
	}
	for _, r := range repos {
		if r.Id == ref || r.Name == ref || strings.HasPrefix(r.Id, ref) {
			return r, nil
		}
	}
	return nil, fmt.Errorf("no repository %q", ref)
}

func findWorkspace(ctx context.Context, c *client.Client, ref string) (*radiov1.Workspace, error) {
	ws, err := c.Workspaces(ctx, "", true)
	if err != nil {
		return nil, err
	}
	for _, w := range ws {
		if w.Id == ref || w.Name == ref || strings.HasPrefix(w.Id, ref) {
			return w, nil
		}
	}
	return nil, fmt.Errorf("no workspace %q", ref)
}

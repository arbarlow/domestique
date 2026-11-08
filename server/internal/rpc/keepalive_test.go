package rpc

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"github.com/arbarlow/domestique/server/client"
	domestiquev1 "github.com/arbarlow/domestique/server/gen/domestique/v1"
	"github.com/arbarlow/domestique/server/internal/core"
	"github.com/arbarlow/domestique/server/internal/store"
)

func TestMain(m *testing.M) {
	// Fast keepalive, set before any connection exists.
	pingInterval, pingTimeout = 20*time.Millisecond, 150*time.Millisecond
	os.Exit(m.Run())
}

func startServer(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "tck")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	st, err := store.Open(filepath.Join(dir, "tc.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	server, err := core.New(core.Options{Store: st, Log: quiet, WorkspacesRoot: filepath.Join(dir, "ws"), ReposRoot: filepath.Join(dir, "repos")})
	if err != nil {
		t.Fatal(err)
	}
	l, err := net.Listen("unix", filepath.Join(dir, "s.sock"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); _ = NewServer(server, st, quiet).Serve(ctx, l, true) }()
	t.Cleanup(func() { cancel(); wg.Wait(); server.Shutdown(); st.Close() })
	return "unix://" + l.Addr().String()
}

// A client that stops reading to push back on a process can't answer pings; its own Pings keep
// the connection.
func TestBackpressureSurvivesKeepalive(t *testing.T) {
	url := startServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c, err := client.Dial(ctx, url, client.WithoutReconnect(), client.WithKeepalive(pingInterval),
		client.WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	const n = 1_500_000
	p, err := c.StartProcess(ctx, &domestiquev1.ProcessTarget{Argv: []string{"awk", "BEGIN { for (i = 1; i <= " + strconv.Itoa(n) + "; i++) print i }"}})
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	first := true
	for o := range p.Output() {
		out.Write(o.Data)
		if first {
			first = false
			time.Sleep(10 * pingTimeout)
		}
	}
	ex, err := p.Wait()
	if err != nil || ex.ExitCode != 0 {
		t.Fatalf("exit %v %v", ex, err)
	}
	lines := bytes.Count(out.Bytes(), []byte("\n"))
	if lines != n || !bytes.HasSuffix(out.Bytes(), []byte("\n"+strconv.Itoa(n)+"\n")) {
		t.Fatalf("got %d lines", lines)
	}
}

// A client that goes silent (no frames, no pongs) with nothing being written to it is dropped.
func TestSilentClientIsDropped(t *testing.T) {
	url := startServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	path := url[len("unix://"):]
	hc := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", path)
	}}}
	ws, _, err := websocket.Dial(ctx, "ws://localhost"+Path, &websocket.DialOptions{HTTPClient: hc})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	hello, _ := proto.Marshal(&domestiquev1.ClientFrame{Frame: &domestiquev1.ClientFrame_Hello{Hello: &domestiquev1.Hello{ProtocolVersion: domestiquev1.ProtocolVersion_PROTOCOL_VERSION_1}}})
	if err := ws.Write(ctx, websocket.MessageBinary, hello); err != nil {
		t.Fatal(err)
	}
	if _, _, err := ws.Read(ctx); err != nil { // Welcome
		t.Fatal(err)
	}
	// Don't read (so pings go unanswered) and don't send.
	time.Sleep(5 * pingTimeout)
	rctx, rcancel := context.WithTimeout(ctx, 2*time.Second)
	defer rcancel()
	for {
		if _, _, err := ws.Read(rctx); err != nil {
			if rctx.Err() != nil {
				t.Fatal("the server kept a silent client")
			}
			return
		}
	}
}

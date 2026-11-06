package client

import (
	"context"
	"sync"
	"time"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// Subscription is a live stream of events. Events() never drops events and never blocks the
// client: undelivered events queue in memory, so drain it promptly.
//
// After a reconnect or a server-side Gap the client resubscribes automatically:
//   - a server subscription receives a fresh ServerSnapshot (replace your state with it);
//   - a rider subscription replays items persisted after the last seq you received, then
//     ReplayDone, then live events again. Upserts are idempotent, so folding stays correct.
type Subscription struct {
	c      *Client
	target *radiov1.Subscribe
	// Process subscriptions: never resubscribed (that would run the command again), and their
	// queue is bounded so a slow reader pushes back on the server instead of buffering forever.
	noResume bool
	maxBytes int
	space    chan struct{}

	quitOnce sync.Once
	mu       sync.Mutex
	serverID uint64
	lastSeq  uint64
	queue    []*radiov1.Event
	queued   int // payload bytes in queue (bounded subscriptions)
	wake     chan struct{}
	done     bool
	err      error

	out  chan *radiov1.Event
	quit chan struct{} // closed by Close: stop delivering at once
}

// Events delivers events in order. Closed when the subscription ends (see Err).
func (s *Subscription) Events() <-chan *radiov1.Event { return s.out }

// Err is why the subscription ended (nil while running or after Close).
func (s *Subscription) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

// LastSeq is the highest rider seq received; resubscribe from it to resume elsewhere.
func (s *Subscription) LastSeq() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastSeq
}

// Close ends the subscription.
func (s *Subscription) Close() {
	id := s.release()
	// Stop delivering first: the read loop may be blocked handing this subscription an event, and
	// it must be free to read the Unsubscribe response.
	s.finish(nil)
	s.quitOnce.Do(func() { close(s.quit) })
	if id != 0 {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_, _ = s.c.Do(ctx, &radiov1.Request{Command: &radiov1.Request_Unsubscribe{Unsubscribe: &radiov1.Unsubscribe{SubscriptionId: id}}})
		cancel()
	}
}

// drop ends s locally, without telling the server (whose side already ended).
func (s *Subscription) drop() {
	s.release()
	s.finish(nil)
	s.quitOnce.Do(func() { close(s.quit) })
}

// release forgets s locally (no more events are routed to it) and returns its server id.
func (s *Subscription) release() uint64 {
	s.c.mu.Lock()
	delete(s.c.subs, s)
	s.mu.Lock()
	id := s.serverID
	s.mu.Unlock()
	if s.c.bySubID[id] == s {
		delete(s.c.bySubID, id)
	}
	s.c.mu.Unlock()
	return id
}

func newSubscription(c *Client, target *radiov1.Subscribe) *Subscription {
	s := &Subscription{c: c, target: target, wake: make(chan struct{}, 1), space: make(chan struct{}, 1), out: make(chan *radiov1.Event), quit: make(chan struct{})}
	if r := target.GetRider(); r != nil {
		s.lastSeq = r.FromSeq
	}
	go s.pump()
	return s
}

func eventBytes(ev *radiov1.Event) int { return len(ev.GetProcessOutput().GetData()) }

// deliver queues ev. On a bounded subscription it blocks (holding up the connection's read loop,
// and so, through TCP, the server) while the queue is full.
func (s *Subscription) deliver(ev *radiov1.Event) {
	s.mu.Lock()
	n := eventBytes(ev)
	for s.maxBytes > 0 && s.queued > 0 && s.queued+n > s.maxBytes && !s.done {
		s.mu.Unlock()
		select {
		case <-s.space:
		case <-s.quit:
			return
		case <-s.c.ctx.Done():
			return
		}
		s.mu.Lock()
	}
	if s.done {
		s.mu.Unlock()
		return
	}
	s.queued += n
	if s.target.GetRider() != nil && ev.Seq > s.lastSeq {
		s.lastSeq = ev.Seq
	}
	s.queue = append(s.queue, ev)
	s.mu.Unlock()
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *Subscription) finish(err error) {
	s.mu.Lock()
	if s.done {
		s.mu.Unlock()
		return
	}
	s.done, s.err = true, err
	s.mu.Unlock()
	select {
	case s.wake <- struct{}{}:
	default:
	}
	select {
	case s.space <- struct{}{}:
	default:
	}
}

func (s *Subscription) pump() {
	defer close(s.out)
	for {
		s.mu.Lock()
		if len(s.queue) == 0 {
			if s.done {
				s.mu.Unlock()
				return
			}
			s.mu.Unlock()
			select {
			case <-s.wake:
			case <-s.quit:
				return
			}
			continue
		}
		ev := s.queue[0]
		s.queue[0] = nil
		s.queue = s.queue[1:]
		s.queued -= eventBytes(ev)
		s.mu.Unlock()
		select {
		case s.space <- struct{}{}:
		default:
		}
		select {
		case s.out <- ev:
		case <-s.quit:
			return
		}
	}
}

// subscribe registers s on the current connection. The id mapping is installed in the read loop
// before any event for it can be read.
func (c *Client) subscribe(ctx context.Context, s *Subscription) error {
	target := s.target
	if r := target.GetRider(); r != nil {
		target = &radiov1.Subscribe{Target: &radiov1.Subscribe_Rider{Rider: &radiov1.RiderTarget{
			RiderId: r.RiderId, FromSeq: s.LastSeq(), CoalesceMs: r.CoalesceMs}}}
	}
	hook := func(resp *radiov1.Response) {
		res := resp.GetSubscribe()
		if res == nil {
			return
		}
		c.mu.Lock()
		c.bySubID[res.SubscriptionId] = s
		c.mu.Unlock()
		s.mu.Lock()
		s.serverID = res.SubscriptionId
		s.mu.Unlock()
	}
	_, err := c.do(ctx, &radiov1.Request{Command: &radiov1.Request_Subscribe{Subscribe: target}}, hook)
	return err
}

func (c *Client) resubscribeAll() {
	c.mu.Lock()
	subs := make([]*Subscription, 0, len(c.subs))
	for s := range c.subs {
		subs = append(subs, s)
	}
	c.mu.Unlock()
	for _, s := range subs {
		go c.resubscribe(s)
	}
}

func (c *Client) resubscribe(s *Subscription) {
	for attempt := 0; ; attempt++ {
		c.mu.Lock()
		_, live := c.subs[s]
		c.mu.Unlock()
		if !live || c.ctx.Err() != nil {
			return
		}
		if s.noResume {
			s.release()
			s.finish(ErrProcessLost)
			return
		}
		ctx, cancel := context.WithTimeout(c.ctx, 30*time.Second)
		err := c.subscribe(ctx, s)
		cancel()
		if err == nil {
			return
		}
		if Code(err) != 0 {
			// The server refused (e.g. the rider was closed): the subscription is over.
			c.mu.Lock()
			delete(c.subs, s)
			c.mu.Unlock()
			s.finish(err)
			return
		}
		select {
		case <-c.ctx.Done():
			return
		case <-time.After(time.Duration(min(attempt+1, 20)) * 250 * time.Millisecond):
		}
	}
}

func (c *Client) newSub(ctx context.Context, target *radiov1.Subscribe) (*Subscription, error) {
	return c.startSub(ctx, newSubscription(c, target))
}

func (c *Client) startSub(ctx context.Context, s *Subscription) (*Subscription, error) {
	c.mu.Lock()
	c.subs[s] = struct{}{}
	c.mu.Unlock()
	if err := c.subscribe(ctx, s); err != nil {
		c.mu.Lock()
		delete(c.subs, s)
		c.mu.Unlock()
		s.finish(err)
		return nil, err
	}
	return s, nil
}

// SubscribeServer streams repositories, workspaces and riders. The first event is a ServerSnapshot.
func (c *Client) SubscribeServer(ctx context.Context) (*Subscription, error) {
	return c.newSub(ctx, &radiov1.Subscribe{Target: &radiov1.Subscribe_Server{Server: &radiov1.ServerTarget{}}})
}

// RiderOptions tune a rider subscription.
type RiderOptions struct {
	// Replay items persisted after this seq (0 = the whole transcript).
	FromSeq uint64
	// Merge streamed text for up to this long (0 = server default, 33ms).
	Coalesce time.Duration
}

// SubscribeRider streams one rider: replayed items, ReplayDone, then live events.
func (c *Client) SubscribeRider(ctx context.Context, riderID string, o RiderOptions) (*Subscription, error) {
	return c.newSub(ctx, &radiov1.Subscribe{Target: &radiov1.Subscribe_Rider{Rider: &radiov1.RiderTarget{
		RiderId: riderID, FromSeq: o.FromSeq, CoalesceMs: uint32(o.Coalesce / time.Millisecond),
	}}})
}

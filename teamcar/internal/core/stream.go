package core

import (
	"sync"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// SubscriberBuffer is how many events a subscriber may lag behind before it is dropped.
const SubscriberBuffer = 1024

// Subscriber receives events from one stream. When it falls more than SubscriberBuffer events
// behind, C is closed and Dropped reports true; the client must resubscribe from its cursor.
type Subscriber struct {
	C       chan *radiov1.Event
	mu      sync.Mutex
	closed  bool
	dropped bool
	stream  *stream
}

// Dropped reports whether the subscriber was cut off for lagging.
func (s *Subscriber) Dropped() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dropped
}

// Close unregisters the subscriber. Safe to call more than once.
func (s *Subscriber) Close() { s.stream.remove(s, false) }

// stream fans events out to subscribers without ever blocking the publisher.
type stream struct {
	mu   sync.Mutex
	subs map[*Subscriber]struct{}
}

func newStream() *stream { return &stream{subs: map[*Subscriber]struct{}{}} }

func (st *stream) add() *Subscriber {
	s := &Subscriber{C: make(chan *radiov1.Event, SubscriberBuffer), stream: st}
	st.mu.Lock()
	st.subs[s] = struct{}{}
	st.mu.Unlock()
	return s
}

func (st *stream) remove(s *Subscriber, dropped bool) {
	st.mu.Lock()
	delete(st.subs, s)
	st.mu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.closed = true
		s.dropped = dropped
		close(s.C)
	}
}

// publish delivers ev to every subscriber. Events must not be mutated after publishing.
func (st *stream) publish(ev *radiov1.Event) {
	st.mu.Lock()
	var lagging []*Subscriber
	for s := range st.subs {
		select {
		case s.C <- ev:
		default:
			lagging = append(lagging, s)
		}
	}
	st.mu.Unlock()
	for _, s := range lagging {
		st.remove(s, true)
	}
}

// closeAll ends every subscription (stream gone, e.g. rider closed).
func (st *stream) closeAll() {
	st.mu.Lock()
	subs := make([]*Subscriber, 0, len(st.subs))
	for s := range st.subs {
		subs = append(subs, s)
	}
	st.mu.Unlock()
	for _, s := range subs {
		st.remove(s, false)
	}
}

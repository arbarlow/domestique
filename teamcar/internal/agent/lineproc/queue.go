package lineproc

import "sync"

// Queue is an unbounded FIFO feeding a channel. Push never blocks and never drops; a single pump
// goroutine forwards items to Out() in order. Close stops accepting pushes, lets the pump deliver
// what is buffered, then closes Out() exactly once. Agent sessions use it for Events().
type Queue[T any] struct {
	mu     sync.Mutex
	items  []T
	closed bool
	wake   chan struct{}
	out    chan T
}

func NewQueue[T any]() *Queue[T] {
	q := &Queue[T]{wake: make(chan struct{}, 1), out: make(chan T)}
	go q.pump()
	return q
}

// Out is the delivery channel. Closed after Close once the buffer has drained.
func (q *Queue[T]) Out() <-chan T { return q.out }

// Push appends v. It is a no-op after Close.
func (q *Queue[T]) Push(v T) {
	q.mu.Lock()
	if q.closed {
		q.mu.Unlock()
		return
	}
	q.items = append(q.items, v)
	q.mu.Unlock()
	q.signal()
}

// Close is idempotent.
func (q *Queue[T]) Close() {
	q.mu.Lock()
	q.closed = true
	q.mu.Unlock()
	q.signal()
}

func (q *Queue[T]) signal() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

func (q *Queue[T]) pump() {
	for {
		q.mu.Lock()
		if len(q.items) == 0 {
			closed := q.closed
			q.mu.Unlock()
			if closed {
				close(q.out)
				return
			}
			<-q.wake
			continue
		}
		v := q.items[0]
		var zero T
		q.items[0] = zero
		q.items = q.items[1:]
		if len(q.items) == 0 {
			q.items = nil
		}
		q.mu.Unlock()
		q.out <- v
	}
}

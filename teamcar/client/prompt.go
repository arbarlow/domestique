package client

import (
	"context"
	"errors"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// PromptOptions control Prompt.
type PromptOptions struct {
	// OnApproval answers approval requests (Ask mode). Nil leaves them pending for another client.
	OnApproval func(*radiov1.ApprovalRequest) radiov1.Decision
	// OnQuestion answers agent questions, keyed by question id. Nil leaves them pending.
	OnQuestion func(*radiov1.ApprovalRequest) map[string]string
	// OnEvent sees every live event (for progress output).
	OnEvent func(*radiov1.Event)
	// Attachments to send with the prompt.
	Attachments []*radiov1.Attachment
	// IdempotencyKey makes the send safe to retry.
	IdempotencyKey string
}

// Turn is the outcome of one prompt.
type Turn struct {
	Summary *radiov1.TurnSummary
	// Items persisted or updated during the turn, in order.
	Items []*radiov1.TranscriptItem
	// Text is the last assistant message of the turn.
	Text string
}

// Prompt sends text to a rider and waits until the turn ends.
func (c *Client) Prompt(ctx context.Context, riderID, text string, o PromptOptions) (*Turn, error) {
	riders, err := c.Riders(ctx, "")
	if err != nil {
		return nil, err
	}
	var from uint64
	found := false
	for _, r := range riders {
		if r.Id == riderID {
			from, found = r.LastSeq, true
		}
	}
	if !found {
		return nil, &Error{Code: radiov1.ErrorCode_ERROR_CODE_NOT_FOUND, Message: "rider " + riderID}
	}
	sub, err := c.SubscribeRider(ctx, riderID, RiderOptions{FromSeq: from})
	if err != nil {
		return nil, err
	}
	defer sub.Close()

	t := NewTranscript()
	answered := map[string]bool{}
	sent := false
	var opts []CallOption
	if o.IdempotencyKey != "" {
		opts = append(opts, Idempotent(o.IdempotencyKey))
	}
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case ev, ok := <-sub.Events():
			if !ok {
				return nil, errors.Join(ErrDisconnected, sub.Err())
			}
			t.Apply(ev)
			if sent && o.OnEvent != nil {
				o.OnEvent(ev)
			}
			switch p := ev.Payload.(type) {
			case *radiov1.Event_ReplayDone:
				if !sent {
					sent = true
					// Anything replayed predates this prompt.
					t = NewTranscript()
					if err := c.Send(ctx, riderID, text, o.Attachments, opts...); err != nil {
						return nil, err
					}
				}
			case *radiov1.Event_ItemUpserted:
				ap := p.ItemUpserted.GetApproval()
				if ap == nil || ap.Resolution != radiov1.ApprovalResolution_APPROVAL_RESOLUTION_PENDING || answered[ap.RequestId] {
					continue
				}
				if len(ap.Questions) > 0 && o.OnQuestion != nil {
					answered[ap.RequestId] = true
					if err := c.AnswerQuestion(ctx, riderID, ap.RequestId, o.OnQuestion(ap)); err != nil {
						return nil, err
					}
				} else if len(ap.Questions) == 0 && o.OnApproval != nil {
					answered[ap.RequestId] = true
					if err := c.RespondApproval(ctx, riderID, ap.RequestId, o.OnApproval(ap), ""); err != nil {
						return nil, err
					}
				}
			case *radiov1.Event_TurnEnded:
				if sent {
					return &Turn{Summary: p.TurnEnded.Summary, Items: t.Items, Text: t.LastAssistantText()}, nil
				}
			case *radiov1.Event_Exited:
				if sent {
					return &Turn{Items: t.Items, Text: t.LastAssistantText()}, errors.New("agent exited: " + p.Exited.Message)
				}
			}
		}
	}
}

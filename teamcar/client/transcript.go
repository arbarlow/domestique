package client

import (
	"google.golang.org/protobuf/proto"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// Transcript folds rider events into an ordered list of items, the same way the apps do: upserts
// insert or replace by id (keeping the first timestamp), AppendText extends assistant, reasoning
// and tool-output text.
type Transcript struct {
	Items   []*radiov1.TranscriptItem
	LastSeq uint64
	index   map[string]int
}

func NewTranscript() *Transcript { return &Transcript{index: map[string]int{}} }

// Apply folds one event. Returns true if the transcript changed.
func (t *Transcript) Apply(ev *radiov1.Event) bool {
	if ev.Seq > t.LastSeq {
		t.LastSeq = ev.Seq
	}
	switch p := ev.Payload.(type) {
	case *radiov1.Event_ItemUpserted:
		t.Upsert(p.ItemUpserted)
		return true
	case *radiov1.Event_AppendText:
		return t.Append(p.AppendText.ItemId, p.AppendText.Delta)
	}
	return false
}

func (t *Transcript) Upsert(item *radiov1.TranscriptItem) {
	item = proto.Clone(item).(*radiov1.TranscriptItem)
	if i, ok := t.index[item.Id]; ok {
		if ts := t.Items[i].TimestampMs; ts != 0 {
			item.TimestampMs = ts
		}
		t.Items[i] = item
		return
	}
	t.index[item.Id] = len(t.Items)
	t.Items = append(t.Items, item)
}

func (t *Transcript) Append(id, delta string) bool {
	i, ok := t.index[id]
	if !ok {
		return false
	}
	switch k := t.Items[i].Kind.(type) {
	case *radiov1.TranscriptItem_Assistant:
		k.Assistant += delta
	case *radiov1.TranscriptItem_Reasoning:
		k.Reasoning += delta
	case *radiov1.TranscriptItem_Tool:
		k.Tool.Output += delta
	default:
		return false
	}
	return true
}

// Item returns the item with id, or nil.
func (t *Transcript) Item(id string) *radiov1.TranscriptItem {
	if i, ok := t.index[id]; ok {
		return t.Items[i]
	}
	return nil
}

// LastAssistantText returns the text of the most recent assistant message.
func (t *Transcript) LastAssistantText() string {
	for i := len(t.Items) - 1; i >= 0; i-- {
		if a, ok := t.Items[i].Kind.(*radiov1.TranscriptItem_Assistant); ok {
			return a.Assistant
		}
	}
	return ""
}

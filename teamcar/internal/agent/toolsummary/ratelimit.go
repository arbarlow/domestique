package toolsummary

import (
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

// RateLimitWindow is one usage window (5-hour session, weekly, weekly per-model, …).
type RateLimitWindow struct {
	// Stable key ("five_hour", "seven_day_opus", "primary", …), used to merge partial updates.
	ID string
	// "Current session", "Weekly", "Weekly · Opus", …
	Label string
	// "5 hours" / "7 days", when known.
	Duration string
	// 0..1 of the window used.
	UsedFraction float64
	// Zero when unknown.
	ResetsAt time.Time
	// Provider status ("allowed", "allowed_warning", "rejected").
	Status string
}

// Order sorts session first, then weekly, then per-model weeklies.
func (w RateLimitWindow) Order() int {
	switch w.ID {
	case "five_hour", "primary":
		return 0
	case "seven_day", "secondary":
		return 1
	}
	return 2
}

// RateLimitInfo is one usage update. Updates can be partial; merge by window ID.
type RateLimitInfo struct {
	Windows               []RateLimitWindow
	UsingOverage          bool
	OverageStatus         string
	OverageDisabledReason string
	Plan                  string
}

// SortWindows orders windows by (Order, ID).
func SortWindows(ws []RateLimitWindow) {
	sort.SliceStable(ws, func(i, j int) bool {
		if ws[i].Order() != ws[j].Order() {
			return ws[i].Order() < ws[j].Order()
		}
		return ws[i].ID < ws[j].ID
	})
}

// Worst is the most-used window (the first one on ties).
func (r RateLimitInfo) Worst() (RateLimitWindow, bool) {
	return worst(r.Windows, func(w RateLimitWindow) float64 { return w.UsedFraction })
}

func worst(ws []RateLimitWindow, used func(RateLimitWindow) float64) (RateLimitWindow, bool) {
	if len(ws) == 0 {
		return RateLimitWindow{}, false
	}
	best := ws[0]
	for _, w := range ws[1:] {
		if used(w) > used(best) {
			best = w
		}
	}
	return best, true
}

// UsageTracker merges partial updates by window ID (as Domestique's UsageInfo does) and reports
// the most-used window, treating a window whose reset time has passed as empty.
type UsageTracker struct {
	Windows []RateLimitWindow
}

// Proto converts a window to its Race Radio form.
func (w RateLimitWindow) Proto() *radiov1.RateLimitWindow {
	out := &radiov1.RateLimitWindow{Id: w.ID, Label: w.Label, Duration: w.Duration, UsedFraction: w.UsedFraction, Status: w.Status}
	if !w.ResetsAt.IsZero() {
		out.ResetsAtMs = w.ResetsAt.UnixMilli()
	}
	return out
}

// ProtoWindows converts windows to their Race Radio form, in order.
func ProtoWindows(ws []RateLimitWindow) []*radiov1.RateLimitWindow {
	out := make([]*radiov1.RateLimitWindow, len(ws))
	for i, w := range ws {
		out[i] = w.Proto()
	}
	return out
}

// Merge folds info in and returns the Race Radio rate limit for it: every window and the
// overage/plan fields this update reported (clients merge windows by id), plus the legacy
// used_fraction/window/resets_at_ms from the most-used window of the merged state.
func (u *UsageTracker) Merge(info RateLimitInfo, now time.Time) *radiov1.RateLimit {
	out := u.mergeLegacy(info, now)
	windows := slices.Clone(info.Windows)
	SortWindows(windows)
	out.Windows = ProtoWindows(windows)
	out.UsingOverage = info.UsingOverage
	out.OverageStatus = info.OverageStatus
	out.OverageDisabledReason = info.OverageDisabledReason
	out.Plan = info.Plan
	return out
}

// mergeLegacy folds info in and returns the legacy fields for the merged state.
func (u *UsageTracker) mergeLegacy(info RateLimitInfo, now time.Time) *radiov1.RateLimit {
	for _, w := range info.Windows {
		replaced := false
		for i := range u.Windows {
			if u.Windows[i].ID == w.ID {
				u.Windows[i] = w
				replaced = true
				break
			}
		}
		if !replaced {
			u.Windows = append(u.Windows, w)
		}
	}
	SortWindows(u.Windows)
	used := func(w RateLimitWindow) float64 {
		if !w.ResetsAt.IsZero() && !w.ResetsAt.After(now) {
			return 0
		}
		return w.UsedFraction
	}
	w, ok := worst(u.Windows, used)
	if !ok {
		return &radiov1.RateLimit{Window: "Usage"}
	}
	out := &radiov1.RateLimit{UsedFraction: used(w), Window: w.Label}
	if !w.ResetsAt.IsZero() {
		out.ResetsAtMs = w.ResetsAt.UnixMilli()
	}
	return out
}

// UnixSeconds converts a JSON seconds timestamp (zero time when missing).
func UnixSeconds(v JSON) time.Time {
	f, ok := v.Float()
	if !ok {
		return time.Time{}
	}
	return time.UnixMilli(int64(f * 1000))
}

// WindowLabelMinutes labels a Codex window by its length.
func WindowLabelMinutes(minutes int64, known bool) string {
	switch {
	case !known:
		return "Usage"
	case minutes <= 300:
		return "Current session"
	case minutes >= 10080:
		return "Weekly"
	}
	return fmt.Sprintf("%d-hour", minutes/60)
}

// DurationMinutes renders a window length ("5 hours", "7 days", "90 min"); "" when unknown.
func DurationMinutes(m int64, known bool) string {
	if !known {
		return ""
	}
	if m%1440 == 0 {
		if m == 1440 {
			return "1 day"
		}
		return fmt.Sprintf("%d days", m/1440)
	}
	if m%60 == 0 {
		if m == 60 {
			return "1 hour"
		}
		return fmt.Sprintf("%d hours", m/60)
	}
	return fmt.Sprintf("%d min", m)
}

// WindowLabelKey labels a Claude unified window key.
func WindowLabelKey(key string) string {
	switch key {
	case "five_hour":
		return "Current session"
	case "seven_day":
		return "Weekly · all models"
	case "seven_day_opus":
		return "Weekly · Opus"
	case "seven_day_sonnet":
		return "Weekly · Sonnet"
	}
	if rest, ok := strings.CutPrefix(key, "seven_day_"); ok {
		return "Weekly · " + capitalized(strings.ReplaceAll(rest, "_", " "))
	}
	return capitalized(strings.ReplaceAll(key, "_", " "))
}

// DurationKey is the window length implied by a Claude key.
func DurationKey(key string) string {
	switch {
	case strings.HasPrefix(key, "five_hour"):
		return "5 hours"
	case strings.HasPrefix(key, "seven_day"):
		return "7 days"
	}
	return ""
}

// capitalized mirrors Foundation's String.capitalized for space-separated words.
func capitalized(s string) string {
	words := strings.Split(s, " ")
	for i, w := range words {
		r := []rune(strings.ToLower(w))
		if len(r) > 0 {
			r[0] = []rune(strings.ToUpper(string(r[0])))[0]
		}
		words[i] = string(r)
	}
	return strings.Join(words, " ")
}

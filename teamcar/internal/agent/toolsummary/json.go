package toolsummary

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

// JSON is a loosely-typed view of a decoded JSON value (port of DQCore.JSONValue). Both agent
// protocols evolve quickly, so we decode into this and pick out the fields we care about rather
// than failing on unknown shapes. The zero value is "missing". Accessors never panic.
type JSON struct {
	v       any
	present bool
}

// ParseJSON decodes data. Numbers are kept exact (json.Number).
func ParseJSON(data []byte) (JSON, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return JSON{}, err
	}
	return JSON{v: v, present: true}, nil
}

// MustJSON parses s and panics on error. For tests and literals.
func MustJSON(s string) JSON {
	j, err := ParseJSON([]byte(s))
	if err != nil {
		panic(err)
	}
	return j
}

// Of wraps an already-decoded Go value (map[string]any, []any, string, float64, json.Number, bool, nil).
func Of(v any) JSON { return JSON{v: v, present: true} }

// Exists reports whether the value is present (it may be null).
func (j JSON) Exists() bool { return j.present }

// IsNull reports an explicit JSON null.
func (j JSON) IsNull() bool { return j.present && j.v == nil }

// NullOrMissing mirrors Swift's `value?.isNull ?? true`.
func (j JSON) NullOrMissing() bool { return !j.present || j.v == nil }

// Raw returns the underlying Go value (nil when missing or null).
func (j JSON) Raw() any { return j.v }

// Get returns the member key of an object, or missing.
func (j JSON) Get(key string) JSON {
	if m, ok := j.v.(map[string]any); ok {
		if v, ok := m[key]; ok {
			return JSON{v: v, present: true}
		}
	}
	return JSON{}
}

// Path follows nested object keys.
func (j JSON) Path(keys ...string) JSON {
	for _, k := range keys {
		j = j.Get(k)
	}
	return j
}

// At returns element i of an array, or missing.
func (j JSON) At(i int) JSON {
	if a, ok := j.v.([]any); ok && i >= 0 && i < len(a) {
		return JSON{v: a[i], present: true}
	}
	return JSON{}
}

// Str returns a string value.
func (j JSON) Str() (string, bool) {
	s, ok := j.v.(string)
	return s, ok
}

// S returns a string value or "".
func (j JSON) S() string {
	s, _ := j.v.(string)
	return s
}

// Float returns a numeric value.
func (j JSON) Float() (float64, bool) {
	switch n := j.v.(type) {
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}

// Int returns a numeric value truncated to an integer (like Swift's `Int(double)`).
func (j JSON) Int() (int64, bool) {
	if n, ok := j.v.(json.Number); ok {
		if i, err := n.Int64(); err == nil {
			return i, true
		}
	}
	f, ok := j.Float()
	if !ok || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, false
	}
	return int64(f), true
}

// Bool returns a boolean value.
func (j JSON) Bool() (bool, bool) {
	b, ok := j.v.(bool)
	return b, ok
}

// Arr returns array elements (nil if not an array).
func (j JSON) Arr() []JSON {
	a, ok := j.v.([]any)
	if !ok {
		return nil
	}
	out := make([]JSON, len(a))
	for i, v := range a {
		out[i] = JSON{v: v, present: true}
	}
	return out
}

// IsArray reports whether the value is an array.
func (j JSON) IsArray() bool { _, ok := j.v.([]any); return ok }

// Obj returns object members (nil if not an object).
func (j JSON) Obj() map[string]JSON {
	m, ok := j.v.(map[string]any)
	if !ok {
		return nil
	}
	out := make(map[string]JSON, len(m))
	for k, v := range m {
		out[k] = JSON{v: v, present: true}
	}
	return out
}

// RawObj returns the underlying object map (nil if not an object).
func (j JSON) RawObj() map[string]any {
	m, _ := j.v.(map[string]any)
	return m
}

// Pretty renders the value as indented JSON with sorted keys ("null" when missing).
func (j JSON) Pretty() string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(j.v); err != nil {
		return "null"
	}
	return strings.TrimSuffix(buf.String(), "\n")
}

// Compact renders the value as compact JSON.
func (j JSON) Compact() string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(j.v); err != nil {
		return "null"
	}
	return strings.TrimSuffix(buf.String(), "\n")
}

// UUID returns a random RFC 4122 v4 UUID in Foundation's uppercase form.
func UUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

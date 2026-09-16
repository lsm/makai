package makai

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// jsonObject is a decoded JSON object. Runtime payloads are read through it
// because several frame types carry the same logical field under different
// names, and because unknown fields must be ignored rather than rejected.
type jsonObject map[string]any

func decodeObject(raw json.RawMessage) (jsonObject, bool) {
	if len(raw) == 0 {
		return nil, false
	}
	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return nil, false
	}
	obj, ok := decoded.(map[string]any)
	if !ok {
		return nil, false
	}
	return jsonObject(obj), true
}

// str returns the first key that holds a string value, or "".
func (o jsonObject) str(keys ...string) string {
	for _, key := range keys {
		if value, ok := o[key].(string); ok && value != "" {
			return value
		}
	}
	return ""
}

// strOrDefault is str with a fallback for when no key held a non-empty string.
func (o jsonObject) strOrDefault(fallback string, keys ...string) string {
	if value := o.str(keys...); value != "" {
		return value
	}
	return fallback
}

// num returns the first key that holds a JSON number, and whether one was
// found. JSON numbers decode as float64; callers convert as needed.
func (o jsonObject) num(keys ...string) (float64, bool) {
	for _, key := range keys {
		if value, ok := o[key].(float64); ok {
			return value, true
		}
	}
	return 0, false
}

// intOr returns the first key that holds a JSON number, truncated to int, or
// the fallback.
func (o jsonObject) intOr(fallback int, keys ...string) int {
	if value, ok := o.num(keys...); ok {
		return int(value)
	}
	return fallback
}

// boolean returns the first key that holds a JSON bool, and whether one was
// found.
func (o jsonObject) boolean(keys ...string) (bool, bool) {
	for _, key := range keys {
		if value, ok := o[key].(bool); ok {
			return value, true
		}
	}
	return false, false
}

// obj returns the first key that holds a nested JSON object, or nil.
func (o jsonObject) obj(keys ...string) jsonObject {
	for _, key := range keys {
		if value, ok := o[key].(map[string]any); ok {
			return jsonObject(value)
		}
	}
	return nil
}

// arr returns the first key that holds a JSON array, or nil.
func (o jsonObject) arr(keys ...string) []any {
	for _, key := range keys {
		if value, ok := o[key].([]any); ok {
			return value
		}
	}
	return nil
}

// soleKey returns the object's only key when it has exactly one.
//
// The runtime serializes Zig tagged unions as single-key objects
// ({"agent_start": {...}}), so an event with neither "type" nor "event_type"
// is identified by that key. Go maps have no key order, so this deliberately
// only answers for the single-key case rather than guessing a "first" key.
func (o jsonObject) soleKey() string {
	if len(o) != 1 {
		return ""
	}
	for key := range o {
		return key
	}
	return ""
}

// bufferedLineReader reads newline-terminated lines with an explicit size cap.
//
// bufio.Scanner is not used because its token limit is a hard failure for the
// whole stream; this reader reports an over-long line as an error the caller
// can attribute to one frame.
type bufferedLineReader struct {
	reader *bufio.Reader
	limit  int
}

func newBufferedLineReader(r io.Reader, limit int) *bufferedLineReader {
	return &bufferedLineReader{reader: bufio.NewReaderSize(r, 64<<10), limit: limit}
}

// readLine returns the next line without its trailing newline. A final line
// with no newline is returned before io.EOF.
func (lr *bufferedLineReader) readLine() ([]byte, error) {
	var accumulated []byte
	for {
		chunk, err := lr.reader.ReadSlice('\n')
		if len(accumulated)+len(chunk) > lr.limit {
			return nil, fmt.Errorf("makai: frame exceeds the %d byte limit", lr.limit)
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			accumulated = append(accumulated, chunk...)
			continue
		}
		if err != nil {
			if len(accumulated)+len(chunk) == 0 {
				return nil, err
			}
			// Trailing data with no newline: hand it back, then report the
			// underlying error on the next call.
			accumulated = append(accumulated, chunk...)
			lr.reader = bufio.NewReaderSize(errReader{err}, 16)
			return accumulated, nil
		}
		return append(accumulated, chunk...), nil
	}
}

// errReader yields a fixed error, used to replay the underlying stream's
// error after a trailing unterminated line has been delivered.
type errReader struct{ err error }

func (r errReader) Read([]byte) (int, error) { return 0, r.err }

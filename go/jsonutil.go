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
// whole stream; this reader discards an over-long line and resynchronizes on
// the next newline, so one oversized frame costs that frame and nothing else.
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
			if discardErr := lr.discardLine(err); discardErr != nil {
				return nil, discardErr
			}
			return nil, fmt.Errorf("%w: frame exceeds the %d byte limit", errMalformedFrame, lr.limit)
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

// discardLine consumes the remainder of an over-long line so the next read
// starts at a frame boundary instead of in the middle of one.
//
// err is what the read that tripped the limit returned: a newline was already
// consumed when it is nil, and there is more of the line to drop when it is
// bufio.ErrBufferFull. A read failure is reported; end of stream is not,
// since the caller still has an oversized-frame error to return.
func (lr *bufferedLineReader) discardLine(err error) error {
	for errors.Is(err, bufio.ErrBufferFull) {
		_, err = lr.reader.ReadSlice('\n')
	}
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

// errReader yields a fixed error, used to replay the underlying stream's
// error after a trailing unterminated line has been delivered.
type errReader struct{ err error }

func (r errReader) Read([]byte) (int, error) { return 0, r.err }

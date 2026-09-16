package makai

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"time"
)

// envelopeVersion is the protocol envelope version the SDK emits. V1 keeps
// this pinned at 1; changes to the wire format are additive.
const envelopeVersion = 1

// frame is one newline-delimited JSON envelope, in either direction.
//
// Payload shapes vary per frame type and some runtime frames carry their
// fields at the top level rather than under "payload", so the payload is kept
// as raw JSON and interpreted by each namespace.
type frame struct {
	Type      string          `json:"type"`
	StreamID  string          `json:"stream_id,omitempty"`
	SessionID string          `json:"session_id,omitempty"`
	MessageID string          `json:"message_id,omitempty"`
	Sequence  int64           `json:"sequence"`
	Timestamp int64           `json:"timestamp"`
	Version   int             `json:"version"`
	InReplyTo string          `json:"in_reply_to,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`

	// ProtocolVersion appears on the "ready" handshake frame only.
	ProtocolVersion string `json:"protocol_version,omitempty"`

	// raw is the full envelope as received. It backs the fallback for
	// frames whose fields sit at the top level instead of under "payload".
	raw json.RawMessage
}

// payload returns the frame's payload object, falling back to the whole
// envelope when the frame carries no payload object. This mirrors the
// TypeScript SDK's readPayloadOrFrame, which the runtime's mixed frame
// shapes require.
func (f *frame) payload() jsonObject {
	if obj, ok := decodeObject(f.Payload); ok {
		return obj
	}
	obj, _ := decodeObject(f.raw)
	return obj
}

// mergedPayload overlays the payload object on the envelope's own fields, so
// normalization can read both an event's payload and its envelope metadata.
func (f *frame) mergedPayload() jsonObject {
	payload, ok := decodeObject(f.Payload)
	if !ok {
		obj, _ := decodeObject(f.raw)
		return obj
	}
	merged, _ := decodeObject(f.raw)
	if merged == nil {
		return payload
	}
	for k, v := range payload {
		merged[k] = v
	}
	return merged
}

// jsonPayload reads a payload field that holds a JSON object encoded as a
// string (the runtime's config_json / message_json / event_json / result_json
// convention) and decodes it. It falls back to event_json and result_json for
// the same reason the TypeScript SDK does: some frames name the field
// differently than the caller expects.
func (f *frame) jsonPayload(key string) (jsonObject, error) {
	payload := f.payload()
	raw, ok := payload[key]
	if !ok {
		if raw, ok = payload["event_json"]; !ok {
			raw, ok = payload["result_json"]
		}
	}
	if !ok {
		return payload, nil
	}
	text, isString := raw.(string)
	if !isString {
		return payload, nil
	}
	var decoded any
	if err := json.Unmarshal([]byte(text), &decoded); err != nil {
		return nil, transportErrorf(err, "malformed JSON in %s", key)
	}
	obj, ok := decoded.(map[string]any)
	if !ok {
		return jsonObject{}, nil
	}
	return jsonObject(obj), nil
}

// newStreamEnvelope builds a stream-scoped request envelope. Stream-scoped
// requests carry a single frame, so their sequence is always 1.
func newStreamEnvelope(frameType, streamID string, payload any) *frame {
	return &frame{
		Type:      frameType,
		StreamID:  streamID,
		MessageID: streamID,
		Sequence:  1,
		Timestamp: time.Now().UnixMilli(),
		Version:   envelopeVersion,
		Payload:   mustMarshal(payload),
	}
}

// newFlowEnvelope builds an auth-flow envelope. Auth login flows carry
// several outbound frames whose sequence advances per frame within the flow.
func newFlowEnvelope(frameType, flowID string, sequence int64, payload any) *frame {
	return &frame{
		Type:      frameType,
		StreamID:  flowID,
		MessageID: newULID(),
		Sequence:  sequence,
		Timestamp: time.Now().UnixMilli(),
		Version:   envelopeVersion,
		Payload:   mustMarshal(payload),
	}
}

// newSessionEnvelope builds a session-scoped agent envelope. Sequence is the
// session's next expected inbound value, starting at 1 for agent_start.
func newSessionEnvelope(frameType, sessionID string, sequence int64, payload any) *frame {
	return &frame{
		Type:      frameType,
		SessionID: sessionID,
		MessageID: newULID(),
		Sequence:  sequence,
		Timestamp: time.Now().UnixMilli(),
		Version:   envelopeVersion,
		Payload:   mustMarshal(payload),
	}
}

// newReplyEnvelope builds a session-scoped reply to a runtime request, used
// for tool_result. Tool replies do not consume an inbound sequence number, so
// the sequence is derived from the request rather than the session counter.
func newReplyEnvelope(frameType string, request *frame, payload any) *frame {
	return &frame{
		Type:      frameType,
		SessionID: request.SessionID,
		MessageID: newULID(),
		Sequence:  request.Sequence + 1,
		Timestamp: time.Now().UnixMilli(),
		Version:   envelopeVersion,
		InReplyTo: request.MessageID,
		Payload:   mustMarshal(payload),
	}
}

// mustMarshal encodes a payload the SDK itself constructed. Every payload
// type passed here is a map or struct of strings, numbers, bools and nested
// values of the same kinds, none of which can fail to encode.
func mustMarshal(payload any) json.RawMessage {
	if payload == nil {
		return json.RawMessage("{}")
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		// Unreachable for the payload types the SDK builds. Degrade to an
		// empty object rather than panicking in library code; the runtime
		// rejects the request and the caller sees a protocol failure.
		return json.RawMessage("{}")
	}
	return encoded
}

// maxFrameBytes caps a single inbound envelope. The runtime's own session
// records cap at 8 MiB, so 16 MiB leaves headroom while keeping a hostile or
// wedged host from exhausting memory on one line.
const maxFrameBytes = 16 << 20

// frameReader decodes newline-delimited JSON envelopes from a stream.
type frameReader struct {
	reader *bufferedLineReader
}

func newFrameReader(r io.Reader) *frameReader {
	return &frameReader{reader: newBufferedLineReader(r, maxFrameBytes)}
}

// errMalformedFrame reports a line that was not a JSON object. The reader
// surfaces it without ending the stream so a single bad line does not kill an
// otherwise healthy session.
var errMalformedFrame = errors.New("makai: malformed JSON frame")

// next returns the next envelope. It returns errMalformedFrame for a line
// that did not decode, io.EOF at end of stream, and any other error for a
// read failure.
func (fr *frameReader) next() (*frame, error) {
	line, err := fr.reader.readLine()
	if err != nil {
		return nil, err
	}
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil, errMalformedFrame
	}
	var f frame
	if err := json.Unmarshal(line, &f); err != nil {
		return nil, errMalformedFrame
	}
	f.raw = json.RawMessage(append([]byte(nil), line...))
	return &f, nil
}

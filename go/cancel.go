package makai

import (
	"context"
	"errors"
	"time"
)

// Best-effort teardown budgets. Cancellation and teardown frames are
// advisory: the call has already decided its outcome, and these bounds keep
// cleanup from delaying the caller.
const (
	drainIdle   = 50 * time.Millisecond
	drainBudget = 250 * time.Millisecond
)

// cancelStream asks the runtime to abandon a provider or models stream.
func cancelStream(t *transport, streamID string) {
	t.sendBestEffort(&frame{
		Type:      "abort_request",
		StreamID:  streamID,
		MessageID: newULID(),
		Sequence:  2,
		Timestamp: time.Now().UnixMilli(),
		Version:   envelopeVersion,
		Payload:   mustMarshal(map[string]any{"target_stream_id": streamID, "reason": "client aborted"}),
	})
}

// stopAgent removes an agent session and returns the stop frame's message id.
//
// The sequence must be the session's next expected inbound value; a stop
// carrying the wrong sequence is rejected and leaves the session registered
// until the runtime's idle TTL evicts it.
func stopAgent(t *transport, sessionID string, sequence int64, reason string) string {
	envelope := newSessionEnvelope("agent_stop", sessionID, sequence, map[string]any{
		"session_id": sessionID,
		"reason":     reason,
	})
	t.sendBestEffort(envelope)
	return envelope.MessageID
}

// isAbort reports whether an error came from context cancellation rather than
// from the runtime.
func isAbort(err error) bool {
	var streamErr *StreamError
	if errors.As(err, &streamErr) && streamErr.Kind == KindAborted {
		return true
	}
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

// asStreamError is errors.As specialized to *StreamError, kept as a helper so
// call sites read the same way across namespaces.
func asStreamError(err error, target **StreamError) bool { return errors.As(err, target) }

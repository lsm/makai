package makai

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// ProviderService runs completions straight against a provider, without the
// agent loop. Tool calls come back to the caller as content; nothing is
// executed on the caller's behalf.
type ProviderService struct {
	transport *transport
	timeout   time.Duration
}

// Complete runs one buffered completion and returns the whole response.
//
// Failures are [*StreamError], or [*AuthRequiredError] when the provider has
// no usable credentials. Cancelling ctx aborts the call, asks the runtime to
// abandon the stream, and returns an error wrapping ctx.Err().
func (s *ProviderService) Complete(ctx context.Context, req CompletionRequest) (*CompletionResponse, error) {
	if err := validateExecutionRequest(req.ModelRef, req.Messages); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, abortError(err, "provider complete")
	}

	fallbackProvider := providerIDFromRef(req.ModelRef)
	streamID := newULID()
	sub := s.transport.subscribeStream(streamID)
	defer sub.close()

	payload := buildExecutionPayload(req.ModelRef, req.Messages, req.Tools, req.Options, false)
	if err := s.transport.send(newStreamEnvelope("complete_request", streamID, payload)); err != nil {
		return nil, err
	}

	for {
		f, err := sub.next(ctx, s.timeout, "provider complete_response")
		if err != nil {
			// Every failure here leaves the completion running upstream,
			// not just a cancelled context: a frame timeout or a dropped
			// frame would otherwise keep generating billable tokens with
			// no handle left for the caller to abandon it with.
			cancelStream(s.transport, streamID)
			sub.drain(drainIdle, drainBudget)
			return nil, withStreamID(err, streamID)
		}
		switch f.Type {
		case "ack":
			continue
		case "nack":
			return nil, nackToError(f, fallbackProvider, streamID, "")
		case "stream_error":
			return nil, errorFrameToError(f, fallbackProvider, streamID, "")
		case "result", "complete_response":
			return responseOrAuthError(parseCompletionResponse(f.payload()), fallbackProvider)
		default:
			cancelStream(s.transport, streamID)
			sub.drain(drainIdle, drainBudget)
			return nil, &StreamError{
				Kind:     KindTransportError,
				Message:  fmt.Sprintf("unexpected frame type %q while awaiting a provider result", f.Type),
				StreamID: streamID,
			}
		}
	}
}

// Stream runs one streaming completion.
//
// The returned [*ProviderStream] must be closed when the caller is done with
// it, which the usual pattern does:
//
//	stream, err := client.Provider.Stream(ctx, req)
//	if err != nil {
//		return err
//	}
//	defer stream.Close()
//	for stream.Next() {
//		switch event := stream.Event().(type) {
//		case *makai.TextDelta:
//			fmt.Print(event.Delta)
//		}
//	}
//	return stream.Err()
//
// Stream itself only fails on request validation and on the initial write, so
// most failures surface from [ProviderStream.Err] after the loop ends.
func (s *ProviderService) Stream(ctx context.Context, req CompletionRequest) (*ProviderStream, error) {
	if err := validateExecutionRequest(req.ModelRef, req.Messages); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, abortError(err, "provider stream")
	}

	streamID := newULID()
	sub := s.transport.subscribeStream(streamID)

	payload := buildExecutionPayload(req.ModelRef, req.Messages, req.Tools, req.Options, true)
	if err := s.transport.send(newStreamEnvelope("stream_request", streamID, payload)); err != nil {
		sub.close()
		return nil, err
	}

	return &ProviderStream{
		ctx:              ctx,
		transport:        s.transport,
		sub:              sub,
		streamID:         streamID,
		timeout:          s.timeout,
		fallbackProvider: providerIDFromRef(req.ModelRef),
		tools:            newToolBuffer(),
	}, nil
}

// ProviderStream iterates the events of one provider stream.
//
// It is not safe for concurrent use: drive it from one goroutine.
type ProviderStream struct {
	ctx              context.Context
	transport        *transport
	sub              *subscription
	streamID         string
	timeout          time.Duration
	fallbackProvider string
	tools            *toolBuffer

	current  ProviderEvent
	err      error
	done     bool
	finished bool
}

// Next advances to the next event, reporting whether one is available.
// It returns false at the end of the stream and on failure; check
// [ProviderStream.Err] to tell the two apart.
func (s *ProviderStream) Next() bool {
	if s.done {
		return false
	}
	for {
		f, err := s.sub.next(s.ctx, s.timeout, "provider stream event")
		if err != nil {
			s.fail(err)
			return false
		}
		switch f.Type {
		case "ack":
			continue
		case "nack":
			s.fail(nackToError(f, s.fallbackProvider, s.streamID, ""))
			return false
		}

		event := normalizeProviderFrame(f, s.tools)
		if event == nil {
			continue
		}
		if errEvent, ok := event.(*ErrorEvent); ok {
			// An auth failure ends the stream as a typed error rather than
			// as an event, so callers can branch on it with errors.As.
			if errEvent.Code == CodeAuthRequired {
				s.fail(newAuthRequiredError(firstNonEmpty(errEvent.ProviderID, s.fallbackProvider), errEvent.Message))
				return false
			}
			s.current = event
			s.done = true
			s.finished = true
			return true
		}
		if _, ok := event.(*MessageEnd); ok {
			s.done = true
			s.finished = true
		}
		s.current = event
		return true
	}
}

// Event returns the event [ProviderStream.Next] just advanced to.
func (s *ProviderStream) Event() ProviderEvent { return s.current }

// Err returns the failure that ended the stream, or nil if it ended normally.
func (s *ProviderStream) Err() error { return s.err }

// Close releases the stream's route and, when the stream did not run to
// completion, asks the runtime to abandon it. Close is idempotent and returns
// the same error as [ProviderStream.Err].
func (s *ProviderStream) Close() error {
	if s.sub == nil {
		return s.err
	}
	if !s.finished {
		cancelStream(s.transport, s.streamID)
		s.sub.drain(drainIdle, drainBudget)
	}
	s.sub.close()
	s.sub = nil
	s.done = true
	return s.err
}

func (s *ProviderStream) fail(err error) {
	s.err = withStreamID(err, s.streamID)
	s.done = true
	s.current = nil
}

func nackToError(f *frame, fallbackProvider, streamID, sessionID string) error {
	payload := f.payload()
	code := payload.str("error_code", "code")
	providerID := payload.str("provider_id")
	if providerID == "" && isAuthCode(code) {
		providerID = fallbackProvider
	}
	message := payload.strOrDefault("request rejected", "reason", "message")
	if code == CodeAuthRequired {
		return newAuthRequiredError(providerID, message)
	}
	return &StreamError{
		Kind:       KindProviderError,
		Code:       code,
		ProviderID: providerID,
		Message:    message,
		StreamID:   streamID,
		SessionID:  sessionID,
	}
}

func errorFrameToError(f *frame, fallbackProvider, streamID, sessionID string) error {
	payload := f.payload()
	code := payload.str("code", "error_code")
	providerID := payload.str("provider_id")
	if providerID == "" && isAuthCode(code) {
		providerID = fallbackProvider
	}
	message := payload.strOrDefault("stream error", "message", "reason")
	if code == CodeAuthRequired {
		return newAuthRequiredError(providerID, message)
	}
	return &StreamError{
		Kind:       KindProviderError,
		Code:       code,
		ProviderID: providerID,
		Message:    message,
		StreamID:   streamID,
		SessionID:  sessionID,
	}
}

func isAuthCode(code string) bool {
	return code == CodeAuthRequired || code == CodeAuthExpired || code == CodeAuthRefreshFailed
}

// responseOrAuthError converts a settled response that reported a provider
// auth failure into an [*AuthRequiredError].
//
// A failed provider turn still settles through the normal result path,
// carrying StopReason "error" and the provider's detail. Surfacing that as an
// auth error keeps an expired credential recoverable through the auth
// namespace instead of looking like a completion that happens to have failed.
func responseOrAuthError(response *CompletionResponse, fallbackProvider string) (*CompletionResponse, error) {
	if response.StopReason != "error" || !isAuthFailureMessage(response.ErrorMessage, response.API) {
		return response, nil
	}
	providerID := firstNonEmpty(response.ProviderID, fallbackProvider)
	message := response.ErrorMessage
	if message == "" {
		message = CodeAuthRequired
	}
	return nil, newAuthRequiredError(providerID, message)
}

// isAuthFailureMessage mirrors the runtime's auth-failure detector, so the
// SDK classifies a failed turn the same way the spec requires.
func isAuthFailureMessage(message, api string) bool {
	if message == "" {
		return false
	}
	normalized := strings.ToLower(message)
	switch normalized {
	case CodeAuthRequired, CodeAuthExpired, CodeAuthRefreshFailed:
		return true
	}
	for _, needle := range []string{"authentication required", "401", "403", "unauthorized", "forbidden"} {
		if strings.Contains(normalized, needle) {
			return true
		}
	}
	if api == "anthropic-messages" {
		for _, needle := range []string{"authentication_error", "permission_error", "invalid api key"} {
			if strings.Contains(normalized, needle) {
				return true
			}
		}
	}
	return false
}

func withStreamID(err error, streamID string) error {
	var streamErr *StreamError
	if asStreamError(err, &streamErr) && streamErr.StreamID == "" {
		streamErr.StreamID = streamID
	}
	return err
}

func withSessionID(err error, sessionID string) error {
	var streamErr *StreamError
	if asStreamError(err, &streamErr) && streamErr.SessionID == "" {
		streamErr.SessionID = sessionID
	}
	return err
}

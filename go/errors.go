package makai

import (
	"errors"
	"fmt"
	"strings"
)

// Sentinel errors returned by the SDK. They are comparable with [errors.Is].
var (
	// ErrClosed is returned when a call is made on a client whose transport
	// has already been closed, or whose runtime process has exited.
	ErrClosed = errors.New("makai: client is closed")

	// ErrBinaryNotFound is returned by binary resolution when no makai
	// runtime could be located through any of the configured candidates.
	ErrBinaryNotFound = errors.New("makai: makai binary not found")

	// ErrChecksumRequired is returned when a binary URL is configured
	// without the SHA-256 checksum that downloading requires.
	ErrChecksumRequired = errors.New("makai: sha256 checksum is required when resolving the makai binary from a URL")

	// ErrChecksumMismatch is returned when a downloaded or cached binary
	// does not match its configured SHA-256 checksum.
	ErrChecksumMismatch = errors.New("makai: binary checksum mismatch")

	// ErrProtocolVersion is returned when the runtime announces an envelope
	// protocol version the SDK was not configured to speak.
	ErrProtocolVersion = errors.New("makai: protocol version mismatch")
)

// ErrorKind classifies a [StreamError].
type ErrorKind string

// Stream error kinds, mirroring the runtime's failure surfaces.
const (
	// KindProviderError covers failures reported by the runtime or the
	// upstream provider, including request rejections (nack) and terminal
	// stream error events.
	KindProviderError ErrorKind = "provider_error"
	// KindTransportError covers framing, routing, timeout and child-process
	// failures between the SDK and the runtime.
	KindTransportError ErrorKind = "transport_error"
	// KindAborted marks a call ended by its context being cancelled or
	// exceeding its deadline.
	KindAborted ErrorKind = "aborted"
	// KindUnknown is the fallback for failures that fit no other kind.
	KindUnknown ErrorKind = "unknown"
)

// StreamError is the failure type for provider and agent calls. Retrieve it
// with [errors.As].
type StreamError struct {
	// Kind classifies the failure. See [ErrorKind].
	Kind ErrorKind
	// Code is the runtime's machine-readable error code when one was
	// supplied, for example "auth_required", "agent_busy" or
	// "invalid_request". It is empty otherwise.
	Code string
	// ProviderID names the provider the failure is attributed to, when the
	// runtime reported one or it could be derived from the request.
	ProviderID string
	// Message is the human-readable failure detail.
	Message string
	// StreamID and SessionID carry the correlation ids of the failed call,
	// for matching against runtime logs. Each is empty when not applicable.
	StreamID  string
	SessionID string

	err error
}

func (e *StreamError) Error() string {
	var b strings.Builder
	b.WriteString("makai: ")
	b.WriteString(string(e.Kind))
	if e.Code != "" {
		b.WriteString("/")
		b.WriteString(e.Code)
	}
	b.WriteString(": ")
	b.WriteString(e.Message)
	if e.ProviderID != "" {
		fmt.Fprintf(&b, " (provider_id=%s)", e.ProviderID)
	}
	if ids := formatIDs(e.StreamID, e.SessionID); ids != "" {
		b.WriteString(" ")
		b.WriteString(ids)
	}
	return b.String()
}

// Unwrap exposes the underlying cause, which is the context error for
// [KindAborted] failures and nil for most others.
func (e *StreamError) Unwrap() error { return e.err }

// AuthRequiredError reports that a provider call could not run because the
// provider has no usable credentials. It unwraps to a [StreamError] with
// Code "auth_required", so [errors.As] against either type matches.
//
// Callers recover by running [AuthService.Login] for [AuthRequiredError].ProviderID
// and retrying the request.
type AuthRequiredError struct {
	*StreamError
}

// Unwrap returns the embedded [StreamError] so that errors.As against
// *StreamError matches an *AuthRequiredError.
func (e *AuthRequiredError) Unwrap() error { return e.StreamError }

func newAuthRequiredError(providerID, message string) *AuthRequiredError {
	if message == "" {
		message = "authentication required for provider " + providerID
	}
	return &AuthRequiredError{StreamError: &StreamError{
		Kind:       KindProviderError,
		Code:       CodeAuthRequired,
		ProviderID: providerID,
		Message:    message,
	}}
}

// ProtocolError is the failure type for the model-discovery namespace:
// invalid requests, request rejections and malformed responses. Retrieve it
// with [errors.As].
type ProtocolError struct {
	// Code is the runtime's error code, or one of the SDK-assigned codes
	// CodeInvalidRequest and CodeMalformedResponse. It may be empty.
	Code string
	// Message is the human-readable failure detail.
	Message string
	// StreamID correlates the failed request with runtime logs.
	StreamID string

	err error
}

func (e *ProtocolError) Error() string {
	var b strings.Builder
	b.WriteString("makai: protocol error")
	if e.Code != "" {
		b.WriteString(" (")
		b.WriteString(e.Code)
		b.WriteString(")")
	}
	b.WriteString(": ")
	b.WriteString(e.Message)
	if ids := formatIDs(e.StreamID, ""); ids != "" {
		b.WriteString(" ")
		b.WriteString(ids)
	}
	return b.String()
}

// Unwrap exposes the underlying cause, which is the context error for
// cancelled requests and nil otherwise.
func (e *ProtocolError) Unwrap() error { return e.err }

// AuthErrorKind classifies an [AuthError].
type AuthErrorKind string

// Auth error kinds.
const (
	// AuthKindProviderError marks a login the provider rejected.
	AuthKindProviderError AuthErrorKind = "provider_error"
	// AuthKindCancelled marks a login cancelled by the user, by the SDK
	// (no prompt handler was configured), or by context cancellation.
	AuthKindCancelled AuthErrorKind = "cancelled"
	// AuthKindTransportError marks framing, routing or timeout failures
	// during an auth call.
	AuthKindTransportError AuthErrorKind = "transport_error"
	// AuthKindUnknown is the fallback for failures that fit no other kind,
	// including errors returned by a caller's own handlers.
	AuthKindUnknown AuthErrorKind = "unknown"
)

// AuthError is the failure type for the auth namespace: provider listing and
// interactive login flows. Retrieve it with [errors.As].
type AuthError struct {
	// Kind classifies the failure. See [AuthErrorKind].
	Kind AuthErrorKind
	// Code is the provider's error code from the terminal auth error event,
	// when one was reported.
	Code string
	// Message is the human-readable failure detail.
	Message string
	// ProviderID names the provider whose flow failed, when known.
	ProviderID string
	// FlowID correlates the failed login flow with runtime logs.
	FlowID string

	err error
}

func (e *AuthError) Error() string {
	var b strings.Builder
	b.WriteString("makai: auth ")
	b.WriteString(string(e.Kind))
	if e.Code != "" {
		b.WriteString("/")
		b.WriteString(e.Code)
	}
	b.WriteString(": ")
	b.WriteString(e.Message)
	if e.ProviderID != "" {
		fmt.Fprintf(&b, " (provider_id=%s)", e.ProviderID)
	}
	if e.FlowID != "" {
		fmt.Fprintf(&b, " (flow_id=%s)", e.FlowID)
	}
	return b.String()
}

// Unwrap exposes the underlying cause, which is the context error for
// cancelled flows and the handler's error when a caller handler failed.
func (e *AuthError) Unwrap() error { return e.err }

// Error codes the SDK recognizes or assigns. The runtime may return codes
// beyond this set; treat [StreamError].Code and [ProtocolError].Code as open
// strings and compare against these constants only for the cases you handle.
const (
	// CodeAuthRequired marks a call that needs an interactive login first.
	CodeAuthRequired = "auth_required"
	// CodeAuthExpired marks credentials that expired with no refresh path.
	CodeAuthExpired = "auth_expired"
	// CodeAuthRefreshFailed marks a credential refresh that failed.
	CodeAuthRefreshFailed = "auth_refresh_failed"
	// CodeAgentBusy marks an agent session id that is already in use by a
	// live run. The rejected attempt owns nothing and must not stop it.
	CodeAgentBusy = "agent_busy"
	// CodeInvalidRequest marks a request the runtime or the SDK rejected as
	// malformed or unsatisfiable.
	CodeInvalidRequest = "invalid_request"
	// CodeNotImplemented marks a capability the runtime does not provide.
	CodeNotImplemented = "not_implemented"
	// CodeMalformedResponse is assigned by the SDK when the runtime's reply
	// does not match the shape the protocol defines.
	CodeMalformedResponse = "malformed_response"
)

func formatIDs(streamID, sessionID string) string {
	var parts []string
	if streamID != "" {
		parts = append(parts, "stream_id="+streamID)
	}
	if sessionID != "" {
		parts = append(parts, "session_id="+sessionID)
	}
	if len(parts) == 0 {
		return ""
	}
	return "(" + strings.Join(parts, ", ") + ")"
}

func transportErrorf(cause error, format string, args ...any) *StreamError {
	return &StreamError{
		Kind:    KindTransportError,
		Message: fmt.Sprintf(format, args...),
		err:     cause,
	}
}

func abortError(cause error, operation string) *StreamError {
	return &StreamError{
		Kind:    KindAborted,
		Message: operation + " aborted: " + cause.Error(),
		err:     cause,
	}
}

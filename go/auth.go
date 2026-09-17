package makai

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// ProviderAuthInfo is one provider's credential state.
type ProviderAuthInfo struct {
	// ID is the provider id to pass to [AuthService.Login].
	ID string
	// Name is the provider's display name.
	Name string
	// Status is the provider's credential state. It is [AuthUnknown] when
	// the runtime reported a status the SDK does not recognize.
	Status AuthStatus
	// LastError is the most recent failure detail for this provider, or "".
	LastError string
}

// AuthEventType discriminates an [AuthEvent].
type AuthEventType string

// Auth event types.
const (
	// AuthEventURL carries a URL the user must open to continue the flow.
	AuthEventURL AuthEventType = "auth_url"
	// AuthEventPrompt asks the user for input. The SDK answers it through
	// [LoginHandlers].OnPrompt rather than expecting OnEvent to reply.
	AuthEventPrompt AuthEventType = "prompt"
	// AuthEventProgress reports flow progress.
	AuthEventProgress AuthEventType = "progress"
	// AuthEventSuccess reports that the flow's credentials were stored.
	AuthEventSuccess AuthEventType = "success"
	// AuthEventError reports a recoverable failure inside the flow. The
	// flow continues; the terminal outcome arrives separately.
	AuthEventError AuthEventType = "error"
)

// AuthEvent is one event of an interactive login flow. Which fields carry
// meaning depends on Type.
type AuthEvent struct {
	Type AuthEventType
	// FlowID correlates every event of one login flow.
	FlowID string
	// ProviderID names the provider being logged into.
	ProviderID string

	// URL and Instructions apply to AuthEventURL.
	URL          string
	Instructions string
	// PromptID applies to AuthEventPrompt.
	PromptID string
	// Message applies to AuthEventPrompt, AuthEventProgress and
	// AuthEventError.
	Message string
	// AllowEmpty applies to AuthEventPrompt and reports whether an empty
	// answer is acceptable.
	AllowEmpty bool
	// Code applies to AuthEventError.
	Code string
}

// AuthPrompt is a request for user input during a login flow.
type AuthPrompt struct {
	FlowID     string
	PromptID   string
	ProviderID string
	// Message is the question to put to the user.
	Message string
	// AllowEmpty reports whether an empty answer is acceptable.
	AllowEmpty bool
}

// LoginHandlers receives a login flow's events and answers its prompts.
type LoginHandlers struct {
	// OnEvent receives every event of the flow, including prompts. It is
	// called from the goroutine driving the login, so it should not block
	// for long. A nil OnEvent drops events.
	OnEvent func(AuthEvent)

	// OnPrompt answers a prompt. The returned string is sent back to the
	// runtime as the user's answer.
	//
	// A nil OnPrompt cancels any flow that asks for input, because there is
	// no way to answer it; the login then fails with an [*AuthError] of kind
	// [AuthKindCancelled]. Returning an error cancels the flow and fails the
	// login with that error as the cause.
	OnPrompt func(ctx context.Context, prompt AuthPrompt) (string, error)
}

// AuthService inspects provider credential state and runs interactive login
// flows. Token material stays inside the runtime and is never returned here.
type AuthService struct {
	transport *transport
	timeout   time.Duration
}

// ListProviders returns every provider the runtime can authenticate, with its
// current credential state.
func (s *AuthService) ListProviders(ctx context.Context) ([]ProviderAuthInfo, error) {
	if err := ctx.Err(); err != nil {
		return nil, &AuthError{Kind: AuthKindCancelled, Message: "auth provider listing aborted", err: err}
	}

	streamID := newULID()
	sub := s.transport.subscribeStream(streamID)
	defer sub.close()

	if err := s.transport.send(newStreamEnvelope("auth_providers_request", streamID, map[string]any{})); err != nil {
		return nil, authErrorFrom(err, "", "")
	}

	for {
		f, err := sub.next(ctx, s.timeout, "auth_providers_response")
		if err != nil {
			return nil, authErrorFrom(err, "", streamID)
		}
		switch f.Type {
		case "ack":
			continue
		case "nack":
			return nil, nackToAuthError(f, "", streamID)
		case "auth_providers_response":
			return parseProviders(f, streamID)
		default:
			return nil, &AuthError{
				Kind:    AuthKindTransportError,
				Message: fmt.Sprintf("unexpected frame type %q while awaiting auth_providers_response", f.Type),
				FlowID:  streamID,
			}
		}
	}
}

// Login runs one interactive login flow for providerID and returns when the
// runtime has stored the resulting credentials.
//
// Flow events reach handlers.OnEvent; prompts are answered through
// handlers.OnPrompt. A flow that asks for input with no OnPrompt configured
// is cancelled, because it cannot be completed.
//
// Failures are [*AuthError]: [AuthKindCancelled] when the user or the SDK
// cancelled the flow, [AuthKindProviderError] when the provider rejected it,
// and [AuthKindTransportError] for framing and timeout failures. Cancelling
// ctx cancels the flow with the runtime before returning.
func (s *AuthService) Login(ctx context.Context, providerID string, handlers LoginHandlers) error {
	if providerID == "" {
		return &AuthError{Kind: AuthKindUnknown, Message: "login requires a provider id"}
	}
	if err := ctx.Err(); err != nil {
		return &AuthError{Kind: AuthKindCancelled, ProviderID: providerID, Message: "auth login aborted", err: err}
	}

	flowID := newULID()
	sub := s.transport.subscribeStream(flowID)
	defer sub.close()

	// Outbound frames of one flow share the flow's sequence space, starting
	// at 1 for the login start.
	sequence := int64(1)
	nextSequence := func() int64 {
		current := sequence
		sequence++
		return current
	}

	if err := s.transport.send(newFlowEnvelope("auth_login_start", flowID, nextSequence(), map[string]any{
		"provider_id": providerID,
	})); err != nil {
		return authErrorFrom(err, providerID, flowID)
	}

	var lastError struct {
		code    string
		message string
	}
	cancelledLocally := false

	for {
		f, err := sub.next(ctx, s.timeout, "auth_login_result")
		if err != nil {
			if isAbort(err) {
				s.cancelFlow(flowID, providerID, nextSequence())
				return &AuthError{Kind: AuthKindCancelled, ProviderID: providerID, FlowID: flowID,
					Message: "auth login aborted", err: contextCause(err)}
			}
			return authErrorFrom(err, providerID, flowID)
		}

		switch f.Type {
		case "ack":
			continue
		case "nack":
			return nackToAuthError(f, providerID, flowID)

		case "auth_event":
			event, err := parseAuthEvent(f, providerID, flowID)
			if err != nil {
				return err
			}
			if handlers.OnEvent != nil {
				handlers.OnEvent(event)
			}
			switch event.Type {
			case AuthEventError:
				lastError.code, lastError.message = event.Code, event.Message
				continue
			case AuthEventPrompt:
				if handlers.OnPrompt == nil {
					cancelledLocally = true
					s.cancelFlow(flowID, providerID, nextSequence())
					continue
				}
				answer, err := handlers.OnPrompt(ctx, AuthPrompt{
					FlowID:     event.FlowID,
					PromptID:   event.PromptID,
					ProviderID: event.ProviderID,
					Message:    event.Message,
					AllowEmpty: event.AllowEmpty,
				})
				if err != nil {
					s.cancelFlow(flowID, providerID, nextSequence())
					kind := AuthKindUnknown
					if ctx.Err() != nil {
						kind = AuthKindCancelled
					}
					return &AuthError{Kind: kind, ProviderID: providerID, FlowID: flowID,
						Message: "auth prompt handler failed: " + err.Error(), err: err}
				}
				if err := s.transport.send(newFlowEnvelope("auth_prompt_response", flowID, nextSequence(), map[string]any{
					"flow_id":   flowID,
					"prompt_id": event.PromptID,
					"answer":    answer,
				})); err != nil {
					return authErrorFrom(err, providerID, flowID)
				}
				continue
			default:
				continue
			}

		case "auth_login_result":
			switch status := f.payload().str("status"); status {
			case "success":
				return nil
			case "cancelled":
				message := lastError.message
				if message == "" {
					message = "auth login cancelled"
					if cancelledLocally {
						message = "auth login cancelled: no OnPrompt handler is configured"
					}
				}
				return &AuthError{Kind: AuthKindCancelled, Code: lastError.code,
					ProviderID: providerID, FlowID: flowID, Message: message}
			case "failed":
				message := lastError.message
				if message == "" {
					message = "auth login failed"
				}
				return &AuthError{Kind: AuthKindProviderError, Code: lastError.code,
					ProviderID: providerID, FlowID: flowID, Message: message}
			default:
				return &AuthError{Kind: AuthKindUnknown, ProviderID: providerID, FlowID: flowID,
					Message: fmt.Sprintf("unexpected auth_login_result status %q", status)}
			}

		default:
			return &AuthError{Kind: AuthKindTransportError, ProviderID: providerID, FlowID: flowID,
				Message: fmt.Sprintf("unexpected frame type %q during the login flow", f.Type)}
		}
	}
}

func (s *AuthService) cancelFlow(flowID, providerID string, sequence int64) {
	s.transport.sendBestEffort(newFlowEnvelope("auth_cancel", flowID, sequence, map[string]any{
		"flow_id":     flowID,
		"provider_id": providerID,
	}))
}

// authEventVariants are the payload keys an auth_event uses to name its
// variant, in the order the runtime's tagged union declares them.
var authEventVariants = []AuthEventType{
	AuthEventURL, AuthEventPrompt, AuthEventProgress, AuthEventSuccess, AuthEventError,
}

func parseAuthEvent(f *frame, providerID, flowID string) (AuthEvent, error) {
	payload := f.payload()
	for _, variant := range authEventVariants {
		data := payload.obj(string(variant))
		if data == nil {
			continue
		}
		event := AuthEvent{
			Type:       variant,
			FlowID:     data.str("flow_id"),
			ProviderID: data.str("provider_id"),
		}
		if event.FlowID == "" || event.ProviderID == "" {
			return AuthEvent{}, &AuthError{Kind: AuthKindTransportError, ProviderID: providerID, FlowID: flowID,
				Message: fmt.Sprintf("auth_event %q is missing flow_id or provider_id", variant)}
		}
		switch variant {
		case AuthEventURL:
			event.URL = data.str("url")
			event.Instructions = data.str("instructions")
		case AuthEventPrompt:
			event.PromptID = data.str("prompt_id")
			event.Message = data.str("message")
			event.AllowEmpty, _ = data.boolean("allow_empty")
		case AuthEventProgress:
			event.Message = data.str("message")
		case AuthEventError:
			event.Message = data.str("message")
			event.Code = data.str("code")
		}
		return event, nil
	}
	return AuthEvent{}, &AuthError{Kind: AuthKindUnknown, ProviderID: providerID, FlowID: flowID,
		Message: "auth_event carries no known variant"}
}

type wireProviderAuthInfo struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	AuthStatus string `json:"auth_status"`
	LastError  string `json:"last_error"`
}

func parseProviders(f *frame, streamID string) ([]ProviderAuthInfo, error) {
	var payload struct {
		Providers *[]wireProviderAuthInfo `json:"providers"`
	}
	if len(f.Payload) == 0 || json.Unmarshal(f.Payload, &payload) != nil || payload.Providers == nil {
		return nil, &AuthError{Kind: AuthKindTransportError, FlowID: streamID,
			Message: "auth_providers_response is missing its providers array"}
	}
	providers := make([]ProviderAuthInfo, 0, len(*payload.Providers))
	for index, raw := range *payload.Providers {
		if raw.ID == "" || raw.Name == "" {
			return nil, &AuthError{Kind: AuthKindTransportError, FlowID: streamID,
				Message: fmt.Sprintf("provider entry at index %d is missing id or name", index)}
		}
		status := AuthStatus(raw.AuthStatus)
		if !knownAuthStatuses[status] {
			status = AuthUnknown
		}
		providers = append(providers, ProviderAuthInfo{
			ID: raw.ID, Name: raw.Name, Status: status, LastError: raw.LastError,
		})
	}
	return providers, nil
}

func nackToAuthError(f *frame, providerID, flowID string) *AuthError {
	payload := f.payload()
	return &AuthError{
		Kind:       AuthKindTransportError,
		Code:       payload.str("error_code", "code"),
		ProviderID: providerID,
		FlowID:     flowID,
		Message:    payload.strOrDefault("auth request rejected", "reason", "message"),
	}
}

// authErrorFrom converts a transport-layer failure into the auth namespace's
// error type, preserving the cause for errors.Is.
func authErrorFrom(err error, providerID, flowID string) *AuthError {
	kind := AuthKindTransportError
	if isAbort(err) {
		kind = AuthKindCancelled
	}
	message := err.Error()
	var streamErr *StreamError
	if asStreamError(err, &streamErr) {
		message = streamErr.Message
	}
	return &AuthError{Kind: kind, ProviderID: providerID, FlowID: flowID, Message: message, err: contextCause(err)}
}

// contextCause unwraps a transport failure down to its context error when it
// has one, so errors.Is against context.Canceled works through AuthError.
func contextCause(err error) error {
	var streamErr *StreamError
	if asStreamError(err, &streamErr) && streamErr.err != nil {
		return streamErr.err
	}
	return err
}

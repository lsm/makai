package makai

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func TestAuthRequiredErrorUnwrapsToStreamError(t *testing.T) {
	var err error = newAuthRequiredError("anthropic", "login required")

	var authErr *AuthRequiredError
	if !errors.As(err, &authErr) {
		t.Fatal("expected errors.As to find *AuthRequiredError")
	}
	var streamErr *StreamError
	if !errors.As(err, &streamErr) {
		t.Fatal("expected errors.As to find the embedded *StreamError")
	}
	if streamErr.Code != CodeAuthRequired {
		t.Errorf("Code = %q, want %q", streamErr.Code, CodeAuthRequired)
	}
	if streamErr.Kind != KindProviderError {
		t.Errorf("Kind = %q, want %q", streamErr.Kind, KindProviderError)
	}
	if authErr.ProviderID != "anthropic" {
		t.Errorf("ProviderID = %q", authErr.ProviderID)
	}
}

func TestAuthRequiredErrorHasADefaultMessage(t *testing.T) {
	err := newAuthRequiredError("anthropic", "")
	if !strings.Contains(err.Error(), "authentication required for provider anthropic") {
		t.Errorf("Error() = %q", err.Error())
	}
}

func TestErrorsWrapThroughWrappedContexts(t *testing.T) {
	// A typed error must still be reachable after a caller wraps it.
	inner := newAuthRequiredError("anthropic", "login required")
	wrapped := fmt.Errorf("while running the agent: %w", inner)

	var authErr *AuthRequiredError
	if !errors.As(wrapped, &authErr) {
		t.Fatal("expected *AuthRequiredError through a wrapping error")
	}
	var streamErr *StreamError
	if !errors.As(wrapped, &streamErr) {
		t.Fatal("expected *StreamError through a wrapping error")
	}
}

func TestAbortErrorWrapsTheContextCause(t *testing.T) {
	for _, cause := range []error{context.Canceled, context.DeadlineExceeded} {
		err := abortError(cause, "agent run")
		if !errors.Is(err, cause) {
			t.Errorf("errors.Is(%v, %v) = false", err, cause)
		}
		var streamErr *StreamError
		if !errors.As(err, &streamErr) || streamErr.Kind != KindAborted {
			t.Errorf("expected an aborted *StreamError, got %v", err)
		}
		if !isAbort(err) {
			t.Errorf("isAbort(%v) = false", err)
		}
	}
}

func TestIsAbortIgnoresOtherFailures(t *testing.T) {
	if isAbort(transportErrorf(nil, "boom")) {
		t.Error("a transport failure is not an abort")
	}
	if isAbort(errors.New("plain")) {
		t.Error("a plain error is not an abort")
	}
}

func TestStreamErrorMessageIncludesContext(t *testing.T) {
	err := &StreamError{
		Kind:       KindProviderError,
		Code:       CodeAgentBusy,
		ProviderID: "anthropic",
		Message:    "session already exists",
		SessionID:  "testNanoIdSess1234567",
	}
	message := err.Error()
	for _, want := range []string{"provider_error", "agent_busy", "session already exists", "anthropic", "testNanoIdSess1234567"} {
		if !strings.Contains(message, want) {
			t.Errorf("Error() = %q; it should mention %q", message, want)
		}
	}
}

func TestProtocolErrorMessageIncludesContext(t *testing.T) {
	err := &ProtocolError{Code: CodeMalformedResponse, Message: "bad payload", StreamID: "01ABC"}
	message := err.Error()
	for _, want := range []string{"malformed_response", "bad payload", "01ABC"} {
		if !strings.Contains(message, want) {
			t.Errorf("Error() = %q; it should mention %q", message, want)
		}
	}
}

func TestAuthErrorMessageIncludesContext(t *testing.T) {
	err := &AuthError{
		Kind: AuthKindProviderError, Code: "invalid_code",
		Message: "rejected", ProviderID: "test-fixture", FlowID: "01ABC",
	}
	message := err.Error()
	for _, want := range []string{"provider_error", "invalid_code", "rejected", "test-fixture", "01ABC"} {
		if !strings.Contains(message, want) {
			t.Errorf("Error() = %q; it should mention %q", message, want)
		}
	}
}

func TestIsAuthFailureMessage(t *testing.T) {
	for message, want := range map[string]bool{
		"auth_required":            true,
		"AUTH_EXPIRED":             true,
		"auth_refresh_failed":      true,
		"authentication required":  true,
		"HTTP 401 from upstream":   true,
		"received 403 Forbidden":   true,
		"Unauthorized":             true,
		"":                         false,
		"rate limit exceeded":      false,
		"upstream timeout":         false,
		"model not found":          false,
		"invalid api key supplied": false,
	} {
		if got := isAuthFailureMessage(message, "openai-completions"); got != want {
			t.Errorf("isAuthFailureMessage(%q) = %v, want %v", message, got, want)
		}
	}

	// Anthropic's wire errors are recognized only for its own API.
	for _, message := range []string{"authentication_error", "permission_error", "invalid api key supplied"} {
		if !isAuthFailureMessage(message, "anthropic-messages") {
			t.Errorf("isAuthFailureMessage(%q, anthropic-messages) = false", message)
		}
		if isAuthFailureMessage(message, "ollama") {
			t.Errorf("isAuthFailureMessage(%q, ollama) = true; it is Anthropic-specific", message)
		}
	}
}

func TestIsAuthCode(t *testing.T) {
	for code, want := range map[string]bool{
		CodeAuthRequired:      true,
		CodeAuthExpired:       true,
		CodeAuthRefreshFailed: true,
		CodeAgentBusy:         false,
		CodeInvalidRequest:    false,
		"":                    false,
	} {
		if got := isAuthCode(code); got != want {
			t.Errorf("isAuthCode(%q) = %v, want %v", code, got, want)
		}
	}
}

func TestNackToErrorClassifiesCodes(t *testing.T) {
	makeFrame := func(payload string) *frame {
		return &frame{Type: "nack", Payload: []byte(payload)}
	}

	authFailure := nackToError(makeFrame(`{"error_code":"auth_required","reason":"login"}`), "anthropic", "S1", "")
	var authErr *AuthRequiredError
	if !errors.As(authFailure, &authErr) {
		t.Fatalf("expected *AuthRequiredError, got %T", authFailure)
	}
	if authErr.ProviderID != "anthropic" {
		t.Errorf("fallback provider was not applied: %+v", authErr)
	}

	plain := nackToError(makeFrame(`{"error_code":"invalid_request","reason":"bad filter"}`), "anthropic", "S1", "")
	var streamErr *StreamError
	if !errors.As(plain, &streamErr) {
		t.Fatalf("expected *StreamError, got %T", plain)
	}
	if streamErr.ProviderID != "" {
		t.Errorf("a non-auth rejection should not be attributed to a provider, got %q", streamErr.ProviderID)
	}
	if streamErr.StreamID != "S1" {
		t.Errorf("StreamID = %q", streamErr.StreamID)
	}

	bare := nackToError(makeFrame(`{}`), "", "", "")
	if !errors.As(bare, &streamErr) || streamErr.Message != "request rejected" {
		t.Errorf("expected a default message, got %v", bare)
	}
}

func TestSentinelErrorsAreDistinct(t *testing.T) {
	sentinels := []error{ErrClosed, ErrBinaryNotFound, ErrChecksumRequired, ErrChecksumMismatch, ErrProtocolVersion}
	for i, a := range sentinels {
		for j, b := range sentinels {
			if i != j && errors.Is(a, b) {
				t.Errorf("sentinels %v and %v are not distinct", a, b)
			}
		}
	}
}

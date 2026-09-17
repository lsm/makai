package makai

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestAuthListProviders(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	providers, err := client.Auth.ListProviders(testContext(t))
	if err != nil {
		t.Fatalf("ListProviders: %v", err)
	}
	if len(providers) != 2 {
		t.Fatalf("got %d providers, want 2", len(providers))
	}
	if providers[0].ID != "anthropic" || providers[0].Status != AuthLoginRequired {
		t.Errorf("first provider = %+v", providers[0])
	}
	if providers[1].Status != AuthAuthenticated {
		t.Errorf("second provider status = %q", providers[1].Status)
	}

	requests := framesOfType(readLog(), "auth_providers_request")
	if len(requests) != 1 {
		t.Fatalf("got %d requests, want 1", len(requests))
	}
	if requests[0].Sequence != 1 {
		t.Errorf("Sequence = %d, want 1", requests[0].Sequence)
	}
}

func TestAuthListProvidersNormalizesUnknownStatus(t *testing.T) {
	client := newTestClient(t, scenarioProtocol,
		envAuthProviders+`={"providers":[{"id":"p","name":"P","auth_status":"quantum","last_error":"boom"}]}`)

	providers, err := client.Auth.ListProviders(testContext(t))
	if err != nil {
		t.Fatalf("ListProviders: %v", err)
	}
	if providers[0].Status != AuthUnknown {
		t.Errorf("Status = %q, want %q", providers[0].Status, AuthUnknown)
	}
	if providers[0].LastError != "boom" {
		t.Errorf("LastError = %q", providers[0].LastError)
	}
}

func TestAuthListProvidersRejectsMalformedPayloads(t *testing.T) {
	for name, payload := range map[string]string{
		"no providers array": `{}`,
		"entry missing id":   `{"providers":[{"name":"P"}]}`,
		"entry missing name": `{"providers":[{"id":"p"}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			client := newTestClient(t, scenarioProtocol, envAuthProviders+"="+payload)

			_, err := client.Auth.ListProviders(testContext(t))
			var authErr *AuthError
			if !errors.As(err, &authErr) {
				t.Fatalf("expected *AuthError, got %T: %v", err, err)
			}
			if authErr.Kind != AuthKindTransportError {
				t.Errorf("Kind = %q, want %q", authErr.Kind, AuthKindTransportError)
			}
		})
	}
}

func TestAuthListProvidersSurfacesNack(t *testing.T) {
	client := newTestClient(t, scenarioProtocol,
		envNack+`=auth_providers_request:{"error_code":"not_implemented","reason":"no auth runtime"}`)

	_, err := client.Auth.ListProviders(testContext(t))
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthError, got %T: %v", err, err)
	}
	if authErr.Code != CodeNotImplemented || authErr.Message != "no auth runtime" {
		t.Errorf("error = %+v", authErr)
	}
}

func TestAuthLoginSucceedsAndReportsEvents(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	var events []AuthEvent
	err := client.Auth.Login(testContext(t), "anthropic", LoginHandlers{
		OnEvent: func(event AuthEvent) { events = append(events, event) },
	})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}

	if len(events) != 2 {
		t.Fatalf("got %d events, want 2: %+v", len(events), events)
	}
	if events[0].Type != AuthEventURL {
		t.Errorf("first event type = %q", events[0].Type)
	}
	if events[0].URL != "https://example.invalid/login" || events[0].Instructions != "open the link" {
		t.Errorf("auth_url event = %+v", events[0])
	}
	if events[0].ProviderID != "anthropic" || events[0].FlowID == "" {
		t.Errorf("auth_url identity = %+v", events[0])
	}
	if events[1].Type != AuthEventSuccess {
		t.Errorf("second event type = %q", events[1].Type)
	}

	starts := framesOfType(readLog(), "auth_login_start")
	if len(starts) != 1 {
		t.Fatalf("got %d auth_login_start frames, want 1", len(starts))
	}
	if starts[0].Sequence != 1 {
		t.Errorf("Sequence = %d; a flow starts at 1", starts[0].Sequence)
	}
	if len(starts[0].StreamID) != ulidLength {
		t.Errorf("flow id %q is not a 26-character ULID", starts[0].StreamID)
	}
	if starts[0].payload().str("provider_id") != "anthropic" {
		t.Errorf("provider_id = %q", starts[0].payload().str("provider_id"))
	}
}

func TestAuthLoginAnswersPrompts(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath, envAuthPrompt+"=letmein")

	var prompt AuthPrompt
	err := client.Auth.Login(testContext(t), "test-fixture", LoginHandlers{
		OnPrompt: func(ctx context.Context, p AuthPrompt) (string, error) {
			prompt = p
			return "letmein", nil
		},
	})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if prompt.PromptID != "code" || prompt.Message != "Enter the code" {
		t.Errorf("prompt = %+v", prompt)
	}
	if prompt.AllowEmpty {
		t.Error("AllowEmpty should be false")
	}

	responses := framesOfType(readLog(), "auth_prompt_response")
	if len(responses) != 1 {
		t.Fatalf("got %d prompt responses, want 1", len(responses))
	}
	// Outbound flow frames share the flow's sequence space: start is 1, so
	// the prompt response is 2.
	if responses[0].Sequence != 2 {
		t.Errorf("Sequence = %d, want 2", responses[0].Sequence)
	}
	payload := responses[0].payload()
	if payload.str("answer") != "letmein" || payload.str("prompt_id") != "code" {
		t.Errorf("payload = %v", payload)
	}
	if payload.str("flow_id") != responses[0].StreamID {
		t.Errorf("flow_id %q should match the stream id %q", payload.str("flow_id"), responses[0].StreamID)
	}
}

func TestAuthLoginFailsWithTheProvidersDetail(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envAuthPrompt+"=letmein")

	err := client.Auth.Login(testContext(t), "test-fixture", LoginHandlers{
		OnPrompt: func(ctx context.Context, p AuthPrompt) (string, error) { return "wrong", nil },
	})
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthError, got %T: %v", err, err)
	}
	if authErr.Kind != AuthKindProviderError {
		t.Errorf("Kind = %q, want %q", authErr.Kind, AuthKindProviderError)
	}
	// The terminal error event's code and message are carried into the
	// failure, not just the bare "failed" status.
	if authErr.Code != "invalid_code" {
		t.Errorf("Code = %q", authErr.Code)
	}
	if !strings.Contains(authErr.Message, "rejected that code") {
		t.Errorf("Message = %q", authErr.Message)
	}
}

func TestAuthLoginCancelsWhenNoPromptHandlerIsConfigured(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath, envAuthPrompt+"=letmein")

	err := client.Auth.Login(testContext(t), "test-fixture", LoginHandlers{})
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthError, got %T: %v", err, err)
	}
	if authErr.Kind != AuthKindCancelled {
		t.Errorf("Kind = %q, want %q", authErr.Kind, AuthKindCancelled)
	}
	if !strings.Contains(authErr.Message, "OnPrompt") {
		t.Errorf("Message = %q; it should explain why the flow was cancelled", authErr.Message)
	}
	waitForFrameType(t, readLog, "auth_cancel")
}

func TestAuthLoginPropagatesHandlerErrors(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath, envAuthPrompt+"=letmein")

	sentinel := errors.New("the terminal is gone")
	err := client.Auth.Login(testContext(t), "test-fixture", LoginHandlers{
		OnPrompt: func(ctx context.Context, p AuthPrompt) (string, error) {
			return "", fmt.Errorf("cannot ask: %w", sentinel)
		},
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("expected the handler error to be wrapped, got %v", err)
	}
	var authErr *AuthError
	if !errors.As(err, &authErr) || authErr.Kind != AuthKindUnknown {
		t.Fatalf("expected an unknown-kind *AuthError, got %v", err)
	}
	waitForFrameType(t, readLog, "auth_cancel")
}

func TestAuthLoginSurfacesCancellationStatus(t *testing.T) {
	client := newTestClient(t, scenarioProtocol,
		envNack+`=auth_login_start:{"error_code":"invalid_request","reason":"unknown provider"}`)

	err := client.Auth.Login(testContext(t), "nope", LoginHandlers{})
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthError, got %T: %v", err, err)
	}
	if authErr.Code != CodeInvalidRequest {
		t.Errorf("Code = %q", authErr.Code)
	}
	if authErr.ProviderID != "nope" {
		t.Errorf("ProviderID = %q", authErr.ProviderID)
	}
}

func TestAuthLoginRespectsContextCancellation(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath, envAuthPrompt+"=letmein")

	ctx, cancel := context.WithCancel(context.Background())
	err := client.Auth.Login(ctx, "test-fixture", LoginHandlers{
		OnPrompt: func(ctx context.Context, p AuthPrompt) (string, error) {
			cancel()
			<-ctx.Done()
			return "", ctx.Err()
		},
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected a context.Canceled-wrapped error, got %v", err)
	}
	var authErr *AuthError
	if !errors.As(err, &authErr) || authErr.Kind != AuthKindCancelled {
		t.Fatalf("expected a cancelled *AuthError, got %v", err)
	}
	waitForFrameType(t, readLog, "auth_cancel")
}

func TestAuthLoginCancelsWhenWaitingIsCancelled(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath, envSuppress+"=auth_login_start")

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(60 * time.Millisecond)
		cancel()
	}()

	err := client.Auth.Login(ctx, "anthropic", LoginHandlers{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected a context.Canceled-wrapped error, got %v", err)
	}
	waitForFrameType(t, readLog, "auth_cancel")
}

func TestAuthLoginRequiresAProviderID(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)

	err := client.Auth.Login(testContext(t), "", LoginHandlers{})
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthError, got %T: %v", err, err)
	}
}

func TestAuthEventParsingCoversEveryVariant(t *testing.T) {
	for name, tc := range map[string]struct {
		payload string
		check   func(*testing.T, AuthEvent)
	}{
		"auth_url": {
			`{"auth_url":{"flow_id":"F","provider_id":"P","url":"https://x.invalid","instructions":"go"}}`,
			func(t *testing.T, event AuthEvent) {
				if event.Type != AuthEventURL || event.URL != "https://x.invalid" || event.Instructions != "go" {
					t.Errorf("event = %+v", event)
				}
			},
		},
		"prompt": {
			`{"prompt":{"flow_id":"F","provider_id":"P","prompt_id":"code","message":"m","allow_empty":true}}`,
			func(t *testing.T, event AuthEvent) {
				if event.Type != AuthEventPrompt || event.PromptID != "code" || !event.AllowEmpty {
					t.Errorf("event = %+v", event)
				}
			},
		},
		"progress": {
			`{"progress":{"flow_id":"F","provider_id":"P","message":"working"}}`,
			func(t *testing.T, event AuthEvent) {
				if event.Type != AuthEventProgress || event.Message != "working" {
					t.Errorf("event = %+v", event)
				}
			},
		},
		"success": {
			`{"success":{"flow_id":"F","provider_id":"P"}}`,
			func(t *testing.T, event AuthEvent) {
				if event.Type != AuthEventSuccess {
					t.Errorf("event = %+v", event)
				}
			},
		},
		"error": {
			`{"error":{"flow_id":"F","provider_id":"P","code":"bad","message":"nope"}}`,
			func(t *testing.T, event AuthEvent) {
				if event.Type != AuthEventError || event.Code != "bad" || event.Message != "nope" {
					t.Errorf("event = %+v", event)
				}
			},
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := &frame{Type: "auth_event", Payload: []byte(tc.payload)}
			event, err := parseAuthEvent(f, "P", "F")
			if err != nil {
				t.Fatalf("parseAuthEvent: %v", err)
			}
			if event.FlowID != "F" || event.ProviderID != "P" {
				t.Errorf("identity = %+v", event)
			}
			tc.check(t, event)
		})
	}
}

func TestAuthEventParsingRejectsUnknownVariants(t *testing.T) {
	f := &frame{Type: "auth_event", Payload: []byte(`{"teleport":{"flow_id":"F","provider_id":"P"}}`)}
	if _, err := parseAuthEvent(f, "P", "F"); err == nil {
		t.Fatal("expected an unknown variant to be rejected")
	}
}

func TestAuthEventParsingRequiresIdentity(t *testing.T) {
	f := &frame{Type: "auth_event", Payload: []byte(`{"progress":{"message":"working"}}`)}
	_, err := parseAuthEvent(f, "P", "F")
	var authErr *AuthError
	if !errors.As(err, &authErr) || authErr.Kind != AuthKindTransportError {
		t.Fatalf("expected a transport *AuthError, got %v", err)
	}
}

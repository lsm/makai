package makai

import (
	"context"
	"errors"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"
)

// These tests drive a real `makai --stdio` runtime. They are skipped unless
// MAKAI_BINARY_PATH names one:
//
//	zig build install --prefix /tmp/makai-go
//	MAKAI_BINARY_PATH=/tmp/makai-go/bin/makai go test -race ./...
//
// Everything covered here works without provider credentials: model
// discovery falls back to the runtime's static catalog, auth listing reports
// login state without touching tokens, and the runtime's own test-fixture
// provider completes an offline login flow.

// newSmokeClient starts a client against the real runtime, with its
// credential storage isolated from the developer's own.
func newSmokeClient(t *testing.T) *Client {
	t.Helper()
	binary := os.Getenv(EnvBinaryPath)
	if binary == "" {
		t.Skip("MAKAI_BINARY_PATH is not set")
	}

	// The runtime reads and writes real credential storage. Point it at a
	// scratch home, and on macOS at a keychain service that does not exist,
	// so a smoke run cannot read, write or prompt for the developer's own
	// credentials. Without the keychain override the runtime blocks on an
	// interactive keychain prompt that a test process cannot answer.
	home := t.TempDir()
	env := append(os.Environ(),
		"HOME="+home,
		"XDG_CONFIG_HOME="+home,
		"MAKAI_KEYCHAIN_SERVICE=com.makai.go-sdk-test."+newULID(),
	)

	client, err := New(context.Background(), &Options{
		BinaryPath:       binary,
		Env:              env,
		HandshakeTimeout: 15 * time.Second,
		RequestTimeout:   30 * time.Second,
	})
	if err != nil {
		t.Fatalf("New against the real runtime: %v", err)
	}
	t.Cleanup(func() {
		if err := client.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return client
}

func TestSmokeHandshakeAndClose(t *testing.T) {
	client := newSmokeClient(t)
	if client.transport.cmd.Process == nil {
		t.Fatal("expected a running runtime process")
	}
}

func TestSmokeModelsList(t *testing.T) {
	client := newSmokeClient(t)

	response, err := client.Models.List(testContext(t), ListModelsRequest{})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(response.Models) == 0 {
		t.Fatal("expected the runtime's catalog to list at least one model")
	}
	if response.FetchedAt.IsZero() {
		t.Error("FetchedAt was not populated")
	}

	for _, model := range response.Models {
		if model.ModelRef == "" || model.ModelID == "" || model.ProviderID == "" || model.API == "" {
			t.Fatalf("incomplete descriptor: %+v", model)
		}
		if !knownAuthStatuses[model.AuthStatus] {
			t.Errorf("unknown auth status %q on %s", model.AuthStatus, model.ModelRef)
		}
	}
}

func TestSmokeModelsListFiltersByProvider(t *testing.T) {
	client := newSmokeClient(t)
	ctx := testContext(t)

	all, err := client.Models.List(ctx, ListModelsRequest{})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	provider := all.Models[0].ProviderID

	filtered, err := client.Models.List(ctx, ListModelsRequest{ProviderID: provider})
	if err != nil {
		t.Fatalf("filtered List: %v", err)
	}
	if len(filtered.Models) == 0 {
		t.Fatalf("filtering by %q returned nothing", provider)
	}
	for _, model := range filtered.Models {
		if model.ProviderID != provider {
			t.Errorf("filter leaked %q into a %q listing", model.ProviderID, provider)
		}
	}
}

func TestSmokeModelsResolveRoundTrip(t *testing.T) {
	client := newSmokeClient(t)
	ctx := testContext(t)

	all, err := client.Models.List(ctx, ListModelsRequest{})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	want := all.Models[0]

	resolved, err := client.Models.Resolve(ctx, ResolveModelRequest{
		ProviderID: want.ProviderID, API: want.API, ModelID: want.ModelID,
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	// A ref from the catalog resolves back to the same opaque handle.
	if resolved.ModelRef != want.ModelRef {
		t.Errorf("ModelRef = %q, want %q", resolved.ModelRef, want.ModelRef)
	}
}

func TestSmokeModelsResolveRejectsAnUnknownModel(t *testing.T) {
	client := newSmokeClient(t)

	_, err := client.Models.Resolve(testContext(t), ResolveModelRequest{
		ProviderID: "anthropic", ModelID: "no-such-model-" + newULID(),
	})
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) {
		t.Fatalf("expected *ProtocolError, got %T: %v", err, err)
	}
	if protocolErr.Code != CodeInvalidRequest {
		t.Errorf("Code = %q, want %q (message %q)", protocolErr.Code, CodeInvalidRequest, protocolErr.Message)
	}
}

func TestSmokeAuthListProviders(t *testing.T) {
	client := newSmokeClient(t)

	providers, err := client.Auth.ListProviders(testContext(t))
	if err != nil {
		t.Fatalf("ListProviders: %v", err)
	}
	if len(providers) == 0 {
		t.Fatal("expected the runtime to list auth providers")
	}
	for _, provider := range providers {
		if provider.ID == "" || provider.Name == "" {
			t.Errorf("incomplete provider entry: %+v", provider)
		}
		if !knownAuthStatuses[provider.Status] {
			t.Errorf("unknown status %q on %q", provider.Status, provider.ID)
		}
	}
}

// requireFixtureAuthProvider skips unless the runtime offers its offline
// test-fixture auth provider.
func requireFixtureAuthProvider(t *testing.T, client *Client) {
	t.Helper()
	providers, err := client.Auth.ListProviders(testContext(t))
	if err != nil {
		t.Fatalf("ListProviders: %v", err)
	}
	for _, provider := range providers {
		if provider.ID == "test-fixture" {
			return
		}
	}
	t.Skip("the runtime does not offer the test-fixture auth provider")
}

func TestSmokeAuthLoginWithTheFixtureProvider(t *testing.T) {
	if runtime.GOOS == "darwin" {
		// A successful login persists credentials, and on macOS the runtime
		// writes them to the login keychain. Adding an item under a fresh
		// service name from an unsigned local build raises a keychain
		// authorization prompt that a test process cannot answer, so the
		// call blocks. The flow itself is covered on every platform by
		// TestSmokeAuthLoginRetriesAnInvalidFixtureCode, which exercises the
		// same prompt round trip without reaching the save.
		t.Skip("a macOS keychain write needs interactive authorization")
	}
	client := newSmokeClient(t)
	requireFixtureAuthProvider(t, client)

	// The runtime's fixture provider runs a complete login flow offline: it
	// emits an auth URL, prompts for a code, and accepts "ok".
	var events []AuthEventType
	var promptMessage string
	err := client.Auth.Login(testContext(t), "test-fixture", LoginHandlers{
		OnEvent: func(event AuthEvent) { events = append(events, event.Type) },
		OnPrompt: func(ctx context.Context, prompt AuthPrompt) (string, error) {
			promptMessage = prompt.Message
			return "ok", nil
		},
	})
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if promptMessage == "" {
		t.Error("expected the fixture flow to prompt for a code")
	}
	var sawURL, sawSuccess bool
	for _, event := range events {
		switch event {
		case AuthEventURL:
			sawURL = true
		case AuthEventSuccess:
			sawSuccess = true
		}
	}
	if !sawURL || !sawSuccess {
		t.Errorf("events = %v; expected an auth_url and a success", events)
	}
}

func TestSmokeAuthLoginRetriesAnInvalidFixtureCode(t *testing.T) {
	client := newSmokeClient(t)
	requireFixtureAuthProvider(t, client)

	// The fixture provider re-prompts after a wrong code. Answering wrong
	// once and then failing the handler exercises the whole prompt round
	// trip -- event delivery, the answer going back on the flow's sequence,
	// and the runtime reacting to it -- without completing a login, so no
	// credentials are written.
	sentinel := errors.New("no more answers")
	var events []AuthEventType
	var prompts, progress int

	err := client.Auth.Login(testContext(t), "test-fixture", LoginHandlers{
		OnEvent: func(event AuthEvent) {
			events = append(events, event.Type)
			if event.Type == AuthEventProgress {
				progress++
			}
		},
		OnPrompt: func(ctx context.Context, prompt AuthPrompt) (string, error) {
			prompts++
			if prompts == 1 {
				if prompt.Message == "" || prompt.PromptID == "" {
					t.Errorf("incomplete prompt: %+v", prompt)
				}
				return "definitely-not-ok", nil
			}
			return "", sentinel
		},
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("expected the handler error to be wrapped, got %v", err)
	}
	if prompts < 2 {
		t.Errorf("got %d prompts, want at least 2: the wrong code should be rejected and re-prompted", prompts)
	}
	if progress == 0 {
		t.Errorf("expected a progress event after the wrong code; events = %v", events)
	}
	// The runtime may emit progress before the URL, so look for the URL
	// anywhere rather than pinning it to the first position.
	var sawURL bool
	for _, event := range events {
		if event == AuthEventURL {
			sawURL = true
		}
	}
	if !sawURL {
		t.Errorf("events = %v; the flow should publish an auth_url", events)
	}
}

func TestSmokeAuthLoginCancelsWithoutAPromptHandler(t *testing.T) {
	client := newSmokeClient(t)

	err := client.Auth.Login(testContext(t), "test-fixture", LoginHandlers{})
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthError, got %T: %v", err, err)
	}
	if authErr.Kind != AuthKindCancelled {
		t.Errorf("Kind = %q, want %q (message %q)", authErr.Kind, AuthKindCancelled, authErr.Message)
	}
}

func TestSmokeAuthLoginRejectsAnUnknownProvider(t *testing.T) {
	client := newSmokeClient(t)

	err := client.Auth.Login(testContext(t), "definitely-not-a-provider", LoginHandlers{})
	var authErr *AuthError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthError, got %T: %v", err, err)
	}
	if authErr.Kind == AuthKindTransportError && strings.Contains(authErr.Message, "timed out") {
		t.Errorf("an unknown provider should be rejected, not time out: %v", authErr)
	}
}

func TestSmokeProviderCompleteWithoutCredentials(t *testing.T) {
	client := newSmokeClient(t)
	ctx := testContext(t)

	models, err := client.Models.List(ctx, ListModelsRequest{ProviderID: "anthropic"})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(models.Models) == 0 {
		t.Skip("the runtime lists no anthropic models")
	}

	// With no credentials in the scratch home, the call must fail cleanly
	// rather than hanging or panicking. Which failure it is depends on how
	// far the runtime gets, so this asserts the shape, not the code.
	_, err = client.Provider.Complete(ctx, CompletionRequest{
		ModelRef: models.Models[0].ModelRef,
		Messages: []Message{UserMessage("hello")},
		Options:  &RunOptions{MaxTokens: MaxTokens(16)},
	})
	if err == nil {
		t.Skip("the runtime completed the call, so credentials were available after all")
	}
	var streamErr *StreamError
	if !errors.As(err, &streamErr) {
		t.Fatalf("expected *StreamError, got %T: %v", err, err)
	}
	assertAuthFailureIsTyped(t, err, streamErr)
	t.Logf("uncredentialed completion failed as expected: kind=%s code=%s", streamErr.Kind, streamErr.Code)
}

// assertAuthFailureIsTyped checks that a runtime failure carrying an auth
// code reaches the caller as the recoverable typed error, not just as a
// generic stream failure.
func assertAuthFailureIsTyped(t *testing.T, err error, streamErr *StreamError) {
	t.Helper()
	if streamErr.Code != CodeAuthRequired {
		return
	}
	var authErr *AuthRequiredError
	if !errors.As(err, &authErr) {
		t.Fatalf("an auth_required failure should surface as *AuthRequiredError, got %T", err)
	}
	if authErr.ProviderID == "" {
		t.Error("an *AuthRequiredError must name the provider to log in to")
	}
}

func TestSmokeAgentRunWithoutCredentials(t *testing.T) {
	client := newSmokeClient(t)
	ctx := testContext(t)

	models, err := client.Models.List(ctx, ListModelsRequest{ProviderID: "anthropic"})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(models.Models) == 0 {
		t.Skip("the runtime lists no anthropic models")
	}

	// Without credentials the run cannot reach a provider, but getting a
	// clean failure proves the whole session exchange works against the real
	// server: agent_start, the correlated agent_started, agent_message on
	// sequence 2, and a settled failure instead of a hang.
	_, err = client.Agent.Run(ctx, AgentRequest{
		ModelRef: models.Models[0].ModelRef,
		Messages: []Message{UserMessage("hello")},
		Options:  &RunOptions{MaxTokens: MaxTokens(16)},
	})
	if err == nil {
		t.Skip("the runtime completed the run, so credentials were available after all")
	}
	var streamErr *StreamError
	if !errors.As(err, &streamErr) {
		t.Fatalf("expected *StreamError, got %T: %v", err, err)
	}
	if streamErr.Kind == KindTransportError && strings.Contains(streamErr.Message, "timed out") {
		t.Fatalf("the run should fail, not time out: %v", streamErr)
	}
	assertAuthFailureIsTyped(t, err, streamErr)
	t.Logf("uncredentialed agent run failed as expected: kind=%s code=%s", streamErr.Kind, streamErr.Code)

	// The session was released, so the same client can start another run.
	if _, err := client.Models.List(ctx, ListModelsRequest{}); err != nil {
		t.Fatalf("the client should stay usable after a failed run: %v", err)
	}
}

func TestSmokeIgnoresMalformedInboundFrames(t *testing.T) {
	client := newSmokeClient(t)
	ctx := testContext(t)

	// A line the runtime cannot parse must not wedge the session.
	if _, err := client.transport.stdin.Write([]byte("this is not a frame\n")); err != nil {
		t.Fatalf("writing junk: %v", err)
	}
	if _, err := client.transport.stdin.Write([]byte("{\"type\":\"nonsense_frame\"}\n")); err != nil {
		t.Fatalf("writing an unknown frame: %v", err)
	}

	if _, err := client.Models.List(ctx, ListModelsRequest{}); err != nil {
		t.Fatalf("List after malformed input: %v", err)
	}
}

func TestSmokeConcurrentRequests(t *testing.T) {
	client := newSmokeClient(t)
	ctx := testContext(t)

	const calls = 4
	errs := make(chan error, calls*2)
	for i := 0; i < calls; i++ {
		go func() {
			_, err := client.Models.List(ctx, ListModelsRequest{})
			errs <- err
		}()
		go func() {
			_, err := client.Auth.ListProviders(ctx)
			errs <- err
		}()
	}
	for i := 0; i < calls*2; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent request: %v", err)
		}
	}
}

func TestSmokeCloseTerminatesTheRuntime(t *testing.T) {
	binary := os.Getenv(EnvBinaryPath)
	if binary == "" {
		t.Skip("MAKAI_BINARY_PATH is not set")
	}
	home := t.TempDir()

	client, err := New(context.Background(), &Options{
		BinaryPath: binary,
		Env: append(os.Environ(),
			"HOME="+home,
			"MAKAI_KEYCHAIN_SERVICE=com.makai.go-sdk-test."+newULID(),
		),
		HandshakeTimeout: 15 * time.Second,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if client.transport.cmd.ProcessState == nil {
		t.Fatal("expected the runtime to be reaped")
	}

	if _, err := client.Models.List(testContext(t), ListModelsRequest{}); !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed after Close, got %v", err)
	}
}

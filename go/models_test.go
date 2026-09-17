package makai

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestModelsListDecodesDescriptors(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	response, err := client.Models.List(testContext(t), ListModelsRequest{
		ProviderID:           "anthropic",
		API:                  "anthropic-messages",
		IncludeDeprecated:    Bool(true),
		IncludeLoginRequired: Bool(false),
	})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(response.Models) != 1 {
		t.Fatalf("got %d models, want 1", len(response.Models))
	}

	model := response.Models[0]
	if model.ModelRef != "anthropic/anthropic-messages@claude-sonnet-4-5" {
		t.Errorf("ModelRef = %q", model.ModelRef)
	}
	if model.AuthStatus != AuthAuthenticated {
		t.Errorf("AuthStatus = %q, want %q", model.AuthStatus, AuthAuthenticated)
	}
	if model.Lifecycle != LifecycleStable || model.Source != SourceDynamic {
		t.Errorf("Lifecycle/Source = %q/%q", model.Lifecycle, model.Source)
	}
	if model.ContextWindow != 200000 || model.MaxOutputTokens != 8192 {
		t.Errorf("limits = %d/%d", model.ContextWindow, model.MaxOutputTokens)
	}
	if model.ReasoningDefault != ReasoningMedium {
		t.Errorf("ReasoningDefault = %q", model.ReasoningDefault)
	}
	if want := time.UnixMilli(1_700_000_000_000); !response.FetchedAt.Equal(want) {
		t.Errorf("FetchedAt = %s, want %s", response.FetchedAt, want)
	}
	if response.CacheMaxAge != 5*time.Minute {
		t.Errorf("CacheMaxAge = %s, want 5m", response.CacheMaxAge)
	}

	requests := framesOfType(readLog(), "models_request")
	if len(requests) != 1 {
		t.Fatalf("got %d models_request frames, want 1", len(requests))
	}
	request := requests[0]
	if request.Sequence != 1 {
		t.Errorf("Sequence = %d; a stream-scoped request starts at 1", request.Sequence)
	}
	if request.Version != 1 {
		t.Errorf("Version = %d, want 1", request.Version)
	}
	if request.StreamID == "" || request.StreamID != request.MessageID {
		t.Errorf("stream_id %q and message_id %q should match for a single-frame request", request.StreamID, request.MessageID)
	}
	if len(request.StreamID) != ulidLength {
		t.Errorf("stream_id %q is not a 26-character ULID", request.StreamID)
	}

	payload := request.payload()
	if payload.str("provider_id") != "anthropic" || payload.str("api") != "anthropic-messages" {
		t.Errorf("filters were not serialized: %v", payload)
	}
	if deprecated, ok := payload.boolean("include_deprecated"); !ok || !deprecated {
		t.Error("include_deprecated was not serialized as true")
	}
	if login, ok := payload.boolean("include_login_required"); !ok || login {
		t.Error("include_login_required was not serialized as false")
	}
}

func TestModelsListOmitsUnsetFilters(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	if _, err := client.Models.List(testContext(t), ListModelsRequest{}); err != nil {
		t.Fatalf("List: %v", err)
	}
	payload := framesOfType(readLog(), "models_request")[0].payload()
	for _, key := range []string{"provider_id", "api", "model_id", "include_deprecated", "include_login_required"} {
		if _, present := payload[key]; present {
			t.Errorf("unset filter %q should not be serialized", key)
		}
	}
}

func TestModelsListSurfacesNack(t *testing.T) {
	client := newTestClient(t, scenarioProtocol,
		envNack+`=models_request:{"error_code":"not_implemented","reason":"listing is unavailable"}`)

	_, err := client.Models.List(testContext(t), ListModelsRequest{})
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) {
		t.Fatalf("expected *ProtocolError, got %T: %v", err, err)
	}
	if protocolErr.Code != CodeNotImplemented {
		t.Errorf("Code = %q, want %q", protocolErr.Code, CodeNotImplemented)
	}
	if protocolErr.Message != "listing is unavailable" {
		t.Errorf("Message = %q", protocolErr.Message)
	}
	if protocolErr.StreamID == "" {
		t.Error("expected the failing stream id to be attached")
	}
}

func TestModelsListRejectsMalformedResponses(t *testing.T) {
	descriptor := func(overrides map[string]any) string {
		model := map[string]any{
			"model_ref": "p/a@m", "model_id": "m", "display_name": "M",
			"provider_id": "p", "api": "a", "auth_status": "authenticated",
			"lifecycle": "stable", "capabilities": []any{"chat"}, "source": "dynamic",
		}
		for key, value := range overrides {
			if value == nil {
				delete(model, key)
				continue
			}
			model[key] = value
		}
		encoded, err := json.Marshal(map[string]any{
			"fetched_at_ms": float64(1), "cache_max_age_ms": float64(1000),
			"models": []any{model},
		})
		if err != nil {
			t.Fatal(err)
		}
		return string(encoded)
	}

	for name, response := range map[string]string{
		"missing models array":  `{"fetched_at_ms":1}`,
		"missing fetched_at_ms": `{"models":[]}`,
		"unknown auth status":   descriptor(map[string]any{"auth_status": "who-knows"}),
		"unknown lifecycle":     descriptor(map[string]any{"lifecycle": "experimental"}),
		"unknown source":        descriptor(map[string]any{"source": "guessed"}),
		"unknown capability":    descriptor(map[string]any{"capabilities": []any{"telepathy"}}),
		"missing capabilities":  descriptor(map[string]any{"capabilities": nil}),
		"missing model_ref":     descriptor(map[string]any{"model_ref": nil}),
		"unknown reasoning":     descriptor(map[string]any{"reasoning_default": "extreme"}),
	} {
		t.Run(name, func(t *testing.T) {
			client := newTestClient(t, scenarioProtocol, envModelsResponse+"="+response)

			_, err := client.Models.List(testContext(t), ListModelsRequest{})
			var protocolErr *ProtocolError
			if !errors.As(err, &protocolErr) {
				t.Fatalf("expected *ProtocolError, got %T: %v", err, err)
			}
			if protocolErr.Code != CodeMalformedResponse {
				t.Errorf("Code = %q, want %q (message %q)", protocolErr.Code, CodeMalformedResponse, protocolErr.Message)
			}
		})
	}
}

func TestModelsListRejectsOversizedFilters(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)
	long := strings.Repeat("p", maxProviderIDLength+1)

	_, err := client.Models.List(testContext(t), ListModelsRequest{ProviderID: long})
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || protocolErr.Code != CodeInvalidRequest {
		t.Fatalf("expected an invalid_request *ProtocolError, got %v", err)
	}
}

func TestModelsResolveRequiresIdentity(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)

	for name, request := range map[string]ResolveModelRequest{
		"no provider": {ModelID: "claude-sonnet-4-5"},
		"no model":    {ProviderID: "anthropic"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := client.Models.Resolve(testContext(t), request)
			var protocolErr *ProtocolError
			if !errors.As(err, &protocolErr) || protocolErr.Code != CodeInvalidRequest {
				t.Fatalf("expected an invalid_request *ProtocolError, got %v", err)
			}
		})
	}
}

func TestModelsResolveReturnsTheSingleMatch(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	model, err := client.Models.Resolve(testContext(t), ResolveModelRequest{
		ProviderID: "anthropic",
		API:        "anthropic-messages",
		ModelID:    "claude-sonnet-4-5",
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if model.ModelRef != "anthropic/anthropic-messages@claude-sonnet-4-5" {
		t.Errorf("ModelRef = %q", model.ModelRef)
	}

	// Resolve is a models_request with an exact model_id filter, not a
	// separate envelope type.
	requests := framesOfType(readLog(), "models_request")
	if len(requests) != 1 {
		t.Fatalf("got %d models_request frames, want 1", len(requests))
	}
	if got := requests[0].payload().str("model_id"); got != "claude-sonnet-4-5" {
		t.Errorf("model_id filter = %q", got)
	}
}

func TestModelsResolveRejectsAmbiguousAndMissingMatches(t *testing.T) {
	model := func(modelID, api string) map[string]any {
		return map[string]any{
			"model_ref": "anthropic/" + api + "@" + modelID, "model_id": modelID,
			"display_name": modelID, "provider_id": "anthropic", "api": api,
			"auth_status": "authenticated", "lifecycle": "stable",
			"capabilities": []any{"chat"}, "source": "dynamic",
		}
	}
	encode := func(models ...map[string]any) string {
		list := make([]any, 0, len(models))
		for _, m := range models {
			list = append(list, m)
		}
		encoded, err := json.Marshal(map[string]any{
			"fetched_at_ms": float64(1), "cache_max_age_ms": float64(1000), "models": list,
		})
		if err != nil {
			t.Fatal(err)
		}
		return string(encoded)
	}

	for name, tc := range map[string]struct {
		response string
		want     string
	}{
		"no match": {encode(), "model not found"},
		"two matches": {
			encode(model("claude-sonnet-4-5", "anthropic-messages"), model("claude-sonnet-4-5", "openai-completions")),
			"expected exactly 1",
		},
		"provider mismatch": {
			encode(map[string]any{
				"model_ref": "other/anthropic-messages@claude-sonnet-4-5", "model_id": "claude-sonnet-4-5",
				"display_name": "x", "provider_id": "other", "api": "anthropic-messages",
				"auth_status": "authenticated", "lifecycle": "stable",
				"capabilities": []any{"chat"}, "source": "dynamic",
			}),
			"provider_id mismatch",
		},
		"model mismatch": {
			encode(model("claude-opus-4", "anthropic-messages")),
			"model_id mismatch",
		},
	} {
		t.Run(name, func(t *testing.T) {
			client := newTestClient(t, scenarioProtocol, envModelsResponse+"="+tc.response)

			_, err := client.Models.Resolve(testContext(t), ResolveModelRequest{
				ProviderID: "anthropic", ModelID: "claude-sonnet-4-5",
			})
			var protocolErr *ProtocolError
			if !errors.As(err, &protocolErr) {
				t.Fatalf("expected *ProtocolError, got %T: %v", err, err)
			}
			if protocolErr.Code != CodeInvalidRequest {
				t.Errorf("Code = %q, want %q", protocolErr.Code, CodeInvalidRequest)
			}
			if !strings.Contains(protocolErr.Message, tc.want) {
				t.Errorf("Message = %q, want it to mention %q", protocolErr.Message, tc.want)
			}
		})
	}
}

func TestModelsResolveRejectsApiMismatch(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)

	_, err := client.Models.Resolve(testContext(t), ResolveModelRequest{
		ProviderID: "anthropic", API: "openai-completions", ModelID: "claude-sonnet-4-5",
	})
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || !strings.Contains(protocolErr.Message, "api mismatch") {
		t.Fatalf("expected an api mismatch error, got %v", err)
	}
}

func TestModelsListRespectsContextCancellation(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envSuppress+"=models_request", envRequestLog+"="+logPath)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	_, err := client.Models.List(ctx, ListModelsRequest{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected a context.Canceled-wrapped error, got %v", err)
	}
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) {
		t.Fatalf("expected *ProtocolError, got %T", err)
	}

	// A cancelled request tells the runtime to abandon the stream.
	waitForFrameType(t, readLog, "abort_request")
}

func TestModelsListTimesOut(t *testing.T) {
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath:     osArgsZero(),
		Env:            fakeHostEnv(scenarioProtocol, envSuppress+"=models_request"),
		RequestTimeout: 200 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	_, listErr := client.Models.List(testContext(t), ListModelsRequest{})
	var protocolErr *ProtocolError
	if !errors.As(listErr, &protocolErr) {
		t.Fatalf("expected *ProtocolError, got %T: %v", listErr, listErr)
	}
	if !strings.Contains(protocolErr.Message, "timed out") {
		t.Errorf("Message = %q, want a timeout", protocolErr.Message)
	}
}

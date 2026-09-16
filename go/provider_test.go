package makai

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

const testModelRef = "anthropic/anthropic-messages@claude-sonnet-4-5"

func TestProviderCompleteReturnsTheResponse(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	response, err := client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef,
		Messages: []Message{SystemMessage("be brief"), UserMessage("hello")},
		Options:  &RunOptions{MaxTokens: MaxTokens(128), Temperature: Temperature(0.2)},
	})
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if response.Message.Text != "hello" {
		t.Errorf("Text = %q, want hello", response.Message.Text)
	}
	if response.Message.Role != RoleAssistant {
		t.Errorf("Role = %q", response.Message.Role)
	}
	if response.ProviderID != "anthropic" || response.API != "anthropic-messages" {
		t.Errorf("identity = %q/%q", response.ProviderID, response.API)
	}
	if response.StopReason != "end_turn" {
		t.Errorf("StopReason = %q", response.StopReason)
	}
	if response.Usage == nil || response.Usage.Input != 3 || response.Usage.Output != 5 || response.Usage.CacheRead != 1 {
		t.Errorf("Usage = %+v", response.Usage)
	}

	requests := framesOfType(readLog(), "complete_request")
	if len(requests) != 1 {
		t.Fatalf("got %d complete_request frames, want 1", len(requests))
	}
	payload := requests[0].payload()

	// The V1 provider protocol carries an execution-plane model object; the
	// SDK derives it from the opaque ref and also passes the ref through.
	model := payload.obj("model")
	if model == nil || model.str("provider") != "anthropic" || model.str("api") != "anthropic-messages" {
		t.Errorf("model object = %v", model)
	}
	if model.str("id") != "claude-sonnet-4-5" {
		t.Errorf("model id = %q", model.str("id"))
	}
	if payload.str("model_ref") != testModelRef {
		t.Errorf("model_ref = %q", payload.str("model_ref"))
	}

	// System messages become the system prompt rather than list entries.
	context := payload.obj("context")
	if context.str("system_prompt") != "be brief" {
		t.Errorf("system_prompt = %q", context.str("system_prompt"))
	}
	messages := context.arr("messages")
	if len(messages) != 1 {
		t.Fatalf("got %d wire messages, want 1", len(messages))
	}

	options := payload.obj("options")
	if value, ok := options.num("max_tokens"); !ok || value != 128 {
		t.Errorf("max_tokens = %v", options["max_tokens"])
	}
	if value, ok := options.num("temperature"); !ok || value != 0.2 {
		t.Errorf("temperature = %v", options["temperature"])
	}
}

func TestProviderCompleteRejectsInvalidRequests(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)

	for name, request := range map[string]CompletionRequest{
		"no model ref": {Messages: []Message{UserMessage("hi")}},
		"no messages":  {ModelRef: testModelRef},
		"oversized model ref": {
			ModelRef: strings.Repeat("x", maxModelRefLength+1),
			Messages: []Message{UserMessage("hi")},
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := client.Provider.Complete(testContext(t), request)
			var protocolErr *ProtocolError
			if !errors.As(err, &protocolErr) || protocolErr.Code != CodeInvalidRequest {
				t.Fatalf("expected an invalid_request *ProtocolError, got %v", err)
			}
		})
	}
}

func TestProviderCompleteMapsAuthRequiredNack(t *testing.T) {
	client := newTestClient(t, scenarioProtocol,
		envNack+`=complete_request:{"error_code":"auth_required","reason":"login required","provider_id":"anthropic"}`)

	_, err := client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})

	var authErr *AuthRequiredError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthRequiredError, got %T: %v", err, err)
	}
	if authErr.ProviderID != "anthropic" {
		t.Errorf("ProviderID = %q", authErr.ProviderID)
	}
	// The auth error is a specialization of the stream error, so code that
	// only handles *StreamError still matches it.
	var streamErr *StreamError
	if !errors.As(err, &streamErr) {
		t.Fatal("expected *AuthRequiredError to unwrap to *StreamError")
	}
	if streamErr.Code != CodeAuthRequired || streamErr.Kind != KindProviderError {
		t.Errorf("unwrapped error = %+v", streamErr)
	}
}

func TestProviderCompleteDerivesProviderIDFromTheRef(t *testing.T) {
	// The runtime rejected the call without naming a provider, so the SDK
	// attributes it using the request's own model ref.
	client := newTestClient(t, scenarioProtocol,
		envNack+`=complete_request:{"error_code":"auth_required","reason":"login required"}`)

	_, err := client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	var authErr *AuthRequiredError
	if !errors.As(err, &authErr) || authErr.ProviderID != "anthropic" {
		t.Fatalf("expected the provider to be derived from the ref, got %v", err)
	}
}

func TestProviderCompleteMapsProviderNack(t *testing.T) {
	client := newTestClient(t, scenarioProtocol,
		envNack+`=complete_request:{"error_code":"invalid_request","reason":"unsupported model"}`)

	_, err := client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	var streamErr *StreamError
	if !errors.As(err, &streamErr) {
		t.Fatalf("expected *StreamError, got %T: %v", err, err)
	}
	if streamErr.Kind != KindProviderError || streamErr.Code != CodeInvalidRequest {
		t.Errorf("error = %+v", streamErr)
	}
	var authErr *AuthRequiredError
	if errors.As(err, &authErr) {
		t.Error("a non-auth rejection must not surface as *AuthRequiredError")
	}
}

func TestProviderCompleteMapsSettledAuthFailure(t *testing.T) {
	// A provider turn that failed for lack of credentials still settles
	// through the result path; the SDK re-raises it as an auth error.
	client := newTestClient(t, scenarioProtocol, envProviderResult+`={
		"role":"assistant","content":"","provider_id":"anthropic","api":"anthropic-messages",
		"model_id":"claude-sonnet-4-5","stop_reason":"error","error_message":"auth_required"
	}`)

	_, err := client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	var authErr *AuthRequiredError
	if !errors.As(err, &authErr) {
		t.Fatalf("expected *AuthRequiredError, got %T: %v", err, err)
	}
	if authErr.ProviderID != "anthropic" {
		t.Errorf("ProviderID = %q", authErr.ProviderID)
	}
}

func TestProviderCompleteKeepsNonAuthFailuresAsResponses(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envProviderResult+`={
		"role":"assistant","content":"","provider_id":"anthropic","api":"anthropic-messages",
		"stop_reason":"error","error_message":"upstream timeout"
	}`)

	response, err := client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if response.StopReason != "error" || response.ErrorMessage != "upstream timeout" {
		t.Errorf("response = %+v", response)
	}
}

func TestProviderStreamNormalizesEvents(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	stream, err := client.Provider.Stream(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	var text, thinking strings.Builder
	var kinds []string
	for stream.Next() {
		switch event := stream.Event().(type) {
		case *MessageStart:
			kinds = append(kinds, "message_start")
			if event.ModelID != "claude-sonnet-4-5" {
				t.Errorf("ModelID = %q", event.ModelID)
			}
		case *TextDelta:
			kinds = append(kinds, "text_delta")
			text.WriteString(event.Delta)
		case *ThinkingDelta:
			kinds = append(kinds, "thinking_delta")
			thinking.WriteString(event.Delta)
		case *MessageEnd:
			kinds = append(kinds, "message_end")
			if event.Usage == nil || event.Usage.Output != 5 {
				t.Errorf("Usage = %+v", event.Usage)
			}
			if event.StopReason != "end_turn" {
				t.Errorf("StopReason = %q", event.StopReason)
			}
		default:
			t.Fatalf("unexpected event %T", event)
		}
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("Err: %v", err)
	}
	if text.String() != "hello" {
		t.Errorf("text = %q, want hello", text.String())
	}
	// A provider that names reasoning output "reasoning" is normalized.
	if thinking.String() != "thinking" {
		t.Errorf("thinking = %q", thinking.String())
	}
	want := []string{"message_start", "text_delta", "thinking_delta", "text_delta", "message_end"}
	if strings.Join(kinds, ",") != strings.Join(want, ",") {
		t.Errorf("event order = %v, want %v", kinds, want)
	}

	// Streaming requests suppress partial message snapshots.
	payload := framesOfType(readLog(), "stream_request")[0].payload()
	if partial, ok := payload.boolean("include_partial"); !ok || partial {
		t.Error("expected include_partial=false on a stream request")
	}
}

func TestProviderStreamBuffersToolCalls(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envProviderEvents+`=[
		{"type":"message_start","provider_id":"anthropic","api":"anthropic-messages","model_id":"m"},
		{"type":"toolcall_start","content_index":0,"id":"call-1","name":"lookup"},
		{"type":"toolcall_delta","content_index":0,"delta":"{\"city\":"},
		{"type":"toolcall_delta","content_index":0,"delta":"\"SF\"}"},
		{"type":"toolcall_end","content_index":0},
		{"type":"message_end","stop_reason":"tool_use"}
	]`)

	stream, err := client.Provider.Stream(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	var calls []*ToolCallEvent
	for stream.Next() {
		if call, ok := stream.Event().(*ToolCallEvent); ok {
			calls = append(calls, call)
		}
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("Err: %v", err)
	}
	if len(calls) != 1 {
		t.Fatalf("got %d tool calls, want 1", len(calls))
	}
	// Fragments are buffered and emitted once, complete.
	if calls[0].ToolCallID != "call-1" || calls[0].Name != "lookup" {
		t.Errorf("call identity = %+v", calls[0])
	}
	if calls[0].ArgumentsJSON != `{"city":"SF"}` {
		t.Errorf("ArgumentsJSON = %q", calls[0].ArgumentsJSON)
	}
}

func TestProviderStreamEndsOnTerminalError(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envProviderEvents+`=[
		{"type":"text_delta","delta":"partial"},
		{"type":"error","message":"upstream exploded","code":"provider_error"}
	]`)

	stream, err := client.Provider.Stream(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	var last ProviderEvent
	count := 0
	for stream.Next() {
		last = stream.Event()
		count++
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("a terminal error event should end the stream cleanly, got %v", err)
	}
	if count != 2 {
		t.Fatalf("got %d events, want 2", count)
	}
	errEvent, ok := last.(*ErrorEvent)
	if !ok {
		t.Fatalf("last event = %T, want *ErrorEvent", last)
	}
	if errEvent.Message != "upstream exploded" || errEvent.Code != "provider_error" {
		t.Errorf("error event = %+v", errEvent)
	}
}

func TestProviderStreamRaisesAuthRequired(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envProviderEvents+`=[
		{"type":"error","message":"login required","code":"auth_required","provider_id":"anthropic"}
	]`)

	stream, err := client.Provider.Stream(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	if stream.Next() {
		t.Fatalf("expected no events, got %#v", stream.Event())
	}
	var authErr *AuthRequiredError
	if !errors.As(stream.Err(), &authErr) {
		t.Fatalf("expected *AuthRequiredError, got %T: %v", stream.Err(), stream.Err())
	}
	if authErr.ProviderID != "anthropic" {
		t.Errorf("ProviderID = %q", authErr.ProviderID)
	}
}

func TestProviderStreamSurfacesNack(t *testing.T) {
	client := newTestClient(t, scenarioProtocol,
		envNack+`=stream_request:{"error_code":"not_implemented","reason":"streaming is unavailable"}`)

	stream, err := client.Provider.Stream(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	// A rejection arrives as a frame, so Stream itself succeeds and the
	// failure surfaces from the iterator.
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	if stream.Next() {
		t.Fatalf("expected no events after a rejection, got %#v", stream.Event())
	}
	var streamErr *StreamError
	if !errors.As(stream.Err(), &streamErr) {
		t.Fatalf("expected *StreamError, got %T: %v", stream.Err(), stream.Err())
	}
	if streamErr.Code != CodeNotImplemented || streamErr.Message != "streaming is unavailable" {
		t.Errorf("error = %+v", streamErr)
	}
	if streamErr.StreamID == "" {
		t.Error("expected the failing stream id to be attached")
	}
}

func TestProviderStreamCloseAbandonsAnUnfinishedStream(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath,
		envProviderEvents+`=[{"type":"text_delta","delta":"one"},{"type":"text_delta","delta":"two"},{"type":"message_end"}]`)

	stream, err := client.Provider.Stream(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	if !stream.Next() {
		t.Fatalf("expected a first event: %v", stream.Err())
	}
	if err := stream.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	// Closing again is a no-op.
	if err := stream.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}

	waitForFrameType(t, readLog, "abort_request")
}

func TestProviderStreamCloseAfterCompletionDoesNotAbort(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	stream, err := client.Provider.Stream(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	for stream.Next() {
	}
	if err := stream.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if got := len(framesOfType(readLog(), "abort_request")); got != 0 {
		t.Errorf("got %d abort_request frames after a complete stream, want 0", got)
	}
}

func TestProviderCompleteRespectsContextCancellation(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envSuppress+"=complete_request", envRequestLog+"="+logPath)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	_, err := client.Provider.Complete(ctx, CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected a context.Canceled-wrapped error, got %v", err)
	}
	var streamErr *StreamError
	if !errors.As(err, &streamErr) || streamErr.Kind != KindAborted {
		t.Fatalf("expected an aborted *StreamError, got %v", err)
	}
	waitForFrameType(t, readLog, "abort_request")
}

func TestProviderCompleteHonoursDeadline(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envSuppress+"=complete_request")

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	_, err := client.Provider.Complete(ctx, CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected a context.DeadlineExceeded-wrapped error, got %v", err)
	}
}

func TestProviderCompleteSerializesStructuredContent(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	_, err := client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef,
		Messages: []Message{
			{Role: RoleUser, Parts: []ContentPart{
				{Type: PartText, Text: "describe this"},
				{Type: PartImage, Data: "aGk=", MimeType: "image/png"},
			}},
			ToolMessage("call-1", "lookup", "sunny"),
		},
		Tools: []Tool{{Name: "lookup", Description: "look things up", ParametersSchemaJSON: `{"type":"object"}`}},
	})
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}

	context := framesOfType(readLog(), "complete_request")[0].payload().obj("context")
	messages := context.arr("messages")
	if len(messages) != 2 {
		t.Fatalf("got %d wire messages, want 2", len(messages))
	}

	first := jsonObject(messages[0].(map[string]any))
	parts := first.arr("content")
	if len(parts) != 2 {
		t.Fatalf("got %d content parts, want 2", len(parts))
	}
	if kind := jsonObject(parts[1].(map[string]any)).str("type"); kind != "image" {
		t.Errorf("second part type = %q", kind)
	}

	// A tool result always travels as structured parts, with its tool name.
	second := jsonObject(messages[1].(map[string]any))
	if second.str("tool_call_id") != "call-1" || second.str("tool_name") != "lookup" {
		t.Errorf("tool message = %v", second)
	}
	if second.arr("content") == nil {
		t.Errorf("tool message content should be a part list, got %v", second["content"])
	}

	tools := context.arr("tools")
	if len(tools) != 1 {
		t.Fatalf("got %d tools, want 1", len(tools))
	}
	if got := jsonObject(tools[0].(map[string]any)).str("parameters_schema_json"); got != `{"type":"object"}` {
		t.Errorf("schema = %q", got)
	}
}

func TestProviderCompleteAbandonsTheStreamOnATimeout(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath:     os.Args[0],
		Env:            fakeHostEnv(scenarioProtocol, envRequestLog+"="+logPath, envSuppress+"=complete_request"),
		RequestTimeout: 200 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	_, err = client.Provider.Complete(testContext(t), CompletionRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err == nil {
		t.Fatal("expected a timeout error")
	}
	var streamErr *StreamError
	if !errors.As(err, &streamErr) || streamErr.Kind != KindTransportError {
		t.Fatalf("expected a transport error, got %v", err)
	}

	// The completion is still running upstream, so the SDK must abandon it
	// rather than leave it generating tokens with no handle to stop it.
	waitForFrameType(t, readLog, "abort_request")
}

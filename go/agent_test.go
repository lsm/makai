package makai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestAgentRunAssemblesTheResponseFromEvents(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol, envRequestLog+"="+logPath)

	response, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef,
		Messages: []Message{UserMessage("hello")},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if response.Message.Text != "agent" {
		t.Errorf("Text = %q, want agent", response.Message.Text)
	}
	if response.StopReason != "end_turn" {
		t.Errorf("StopReason = %q", response.StopReason)
	}
	if response.Usage == nil || response.Usage.Input != 7 || response.Usage.Output != 9 {
		t.Errorf("Usage = %+v", response.Usage)
	}
	if response.ProviderID != "anthropic" || response.ModelID != "claude-sonnet-4-5" {
		t.Errorf("identity = %q/%q", response.ProviderID, response.ModelID)
	}

	frames := readLog()
	starts := framesOfType(frames, "agent_start")
	messages := framesOfType(frames, "agent_message")
	if len(starts) != 1 || len(messages) != 1 {
		t.Fatalf("got %d starts and %d messages, want 1 each", len(starts), len(messages))
	}

	// Per-session sequencing starts at 1 and advances by one per inbound
	// request frame.
	if starts[0].Sequence != 1 {
		t.Errorf("agent_start sequence = %d, want 1", starts[0].Sequence)
	}
	if messages[0].Sequence != 2 {
		t.Errorf("agent_message sequence = %d, want 2", messages[0].Sequence)
	}
	if starts[0].SessionID != messages[0].SessionID {
		t.Error("both frames should carry the same session id")
	}
	if !isNanoID(starts[0].SessionID) {
		t.Errorf("session id %q is not a 21-character NanoID", starts[0].SessionID)
	}
	if starts[0].MessageID == messages[0].MessageID {
		t.Error("each envelope needs its own message id")
	}

	// The start carries the session id under both the canonical key and the
	// pre-rename alias.
	startPayload := starts[0].payload()
	if startPayload.str("session_id") != starts[0].SessionID {
		t.Errorf("session_id payload = %q", startPayload.str("session_id"))
	}
	if startPayload.str("resume_session_id") != starts[0].SessionID {
		t.Errorf("resume_session_id payload = %q", startPayload.str("resume_session_id"))
	}

	// The agent path passes model_ref through untouched, unlike the direct
	// provider path.
	var messageJSON map[string]any
	if err := json.Unmarshal([]byte(messages[0].payload().str("message_json")), &messageJSON); err != nil {
		t.Fatalf("message_json did not decode: %v", err)
	}
	if messageJSON["model_ref"] != testModelRef {
		t.Errorf("model_ref = %v", messageJSON["model_ref"])
	}
}

func TestAgentRunSettlesThroughAResultFrame(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envAgentResult+`={
		"message":{"role":"assistant","content":[{"type":"text","text":"done"}],
		"provider_id":"anthropic","api":"anthropic-messages","model_id":"m"},
		"usage":{"input":11,"output":13},"stop_reason":"end_turn"
	}`)

	response, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hello")},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if response.Message.Text != "done" {
		t.Errorf("Text = %q", response.Message.Text)
	}
	if response.Usage == nil || response.Usage.Input != 11 {
		t.Errorf("Usage = %+v", response.Usage)
	}
}

func TestAgentRunExecutesToolsInClientCode(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	toolLog := t.TempDir() + "/tool-results.jsonl"

	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath,
		envToolResultLog+"="+toolLog,
		envToolCalls+`=[{"tool_call_id":"call-1","tool_name":"lookup","args_json":"{\"city\":\"SF\"}"}]`)

	var seen ToolInvocation
	_, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef,
		Messages: []Message{UserMessage("weather?")},
		Tools: []Tool{{
			Name:                 "lookup",
			Description:          "look up the weather",
			ParametersSchemaJSON: `{"type":"object"}`,
			Execute: func(ctx context.Context, call ToolInvocation) (string, error) {
				seen = call
				return "sunny", nil
			},
		}},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if seen.ToolCallID != "call-1" || seen.ToolName != "lookup" {
		t.Errorf("invocation = %+v", seen)
	}
	if seen.ArgumentsJSON != `{"city":"SF"}` {
		t.Errorf("ArgumentsJSON = %q", seen.ArgumentsJSON)
	}

	results := framesOfType(readLog(), "tool_result")
	if len(results) != 1 {
		t.Fatalf("got %d tool_result frames, want 1", len(results))
	}
	result := results[0]

	// A tool reply is correlated to the tool_execute it answers.
	toolExecutes := framesOfType(readLog(), "tool_execute")
	if len(toolExecutes) != 0 {
		t.Error("tool_execute is inbound; it should not appear in the request log")
	}
	if result.InReplyTo == "" {
		t.Error("tool_result must carry in_reply_to")
	}
	payload := result.payload()
	if payload.str("tool_call_id") != "call-1" {
		t.Errorf("tool_call_id = %q", payload.str("tool_call_id"))
	}
	if isError, _ := payload.boolean("is_error"); isError {
		t.Error("a successful tool must not be reported as an error")
	}
	var parts []map[string]any
	if err := json.Unmarshal([]byte(payload.str("result_json")), &parts); err != nil {
		t.Fatalf("result_json did not decode: %v", err)
	}
	if len(parts) != 1 || parts[0]["text"] != "sunny" {
		t.Errorf("result_json = %v", parts)
	}
}

func TestAgentRunReportsToolFailuresToTheModel(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath,
		envToolCalls+`=[{"tool_call_id":"call-1","tool_name":"lookup","args_json":"{}"}]`)

	_, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef,
		Messages: []Message{UserMessage("weather?")},
		Tools: []Tool{{
			Name: "lookup",
			Execute: func(ctx context.Context, call ToolInvocation) (string, error) {
				return "", fmt.Errorf("the weather service is down")
			},
		}},
	})
	// A failing tool is reported to the model, not raised to the caller.
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	payload := framesOfType(readLog(), "tool_result")[0].payload()
	if isError, _ := payload.boolean("is_error"); !isError {
		t.Error("a failing tool must be reported with is_error")
	}
	if !strings.Contains(payload.str("result_json"), "weather service is down") {
		t.Errorf("result_json = %q", payload.str("result_json"))
	}
}

func TestAgentRunReportsUnknownTools(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath,
		envToolCalls+`=[{"tool_call_id":"call-1","tool_name":"mystery","args_json":"{}"}]`)

	if _, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef,
		Messages: []Message{UserMessage("hi")},
		// A definition with no Execute cannot run here.
		Tools: []Tool{{Name: "mystery"}},
	}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	payload := framesOfType(readLog(), "tool_result")[0].payload()
	if isError, _ := payload.boolean("is_error"); !isError {
		t.Error("an unexecutable tool must be reported with is_error")
	}
	if !strings.Contains(payload.str("result_json"), "not executable") {
		t.Errorf("result_json = %q", payload.str("result_json"))
	}
}

func TestAgentRunStopsItsSessionWhenDone(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath, envTrackSessions+"=1")

	if _, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	stops := waitForFrameType(t, readLog, "agent_stop")
	// The stop carries the session's next expected inbound sequence: one
	// start plus one message means 3.
	if stops[0].Sequence != 3 {
		t.Errorf("agent_stop sequence = %d, want 3", stops[0].Sequence)
	}
	if stops[0].payload().str("reason") != "completed" {
		t.Errorf("reason = %q", stops[0].payload().str("reason"))
	}
}

func TestAgentRunReusesASessionIdOnlyAfterItIsStopped(t *testing.T) {
	// A tracked fake host rejects a second start on a live session id, so
	// two runs in a row prove the first one actually released its id.
	client := newTestClient(t, scenarioProtocol, envTrackSessions+"=1")
	ctx := testContext(t)
	sessionID := newNanoID()

	for attempt := 1; attempt <= 2; attempt++ {
		if _, err := client.Agent.Run(ctx, AgentRequest{
			ModelRef: testModelRef,
			Messages: []Message{UserMessage("hi")},
			Options:  &RunOptions{SessionID: sessionID},
		}); err != nil {
			t.Fatalf("run %d: %v", attempt, err)
		}
	}
}

func TestAgentRunDoesNotStopAForeignSession(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath,
		envNack+`=agent_start:{"error_code":"agent_busy","reason":"session already exists"}`)

	_, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	var streamErr *StreamError
	if !errors.As(err, &streamErr) || streamErr.Code != CodeAgentBusy {
		t.Fatalf("expected an agent_busy *StreamError, got %v", err)
	}

	// The id belongs to another live run; stopping it would cancel that run.
	if got := len(framesOfType(readLog(), "agent_stop")); got != 0 {
		t.Errorf("got %d agent_stop frames after agent_busy, want 0", got)
	}
}

func TestAgentRunDoesNotStopACallerSuppliedIdWithNoStartReply(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath: osArgsZero(),
		Env: fakeHostEnv(scenarioProtocol,
			envRequestLog+"="+logPath, envSuppress+"=agent_start"),
		RequestTimeout: 200 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	// The start drew no reply, so this attempt cannot prove it owns the id.
	if _, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef,
		Messages: []Message{UserMessage("hi")},
		Options:  &RunOptions{SessionID: newNanoID()},
	}); err == nil {
		t.Fatal("expected the suppressed start to fail the run")
	}
	if got := len(framesOfType(readLog(), "agent_stop")); got != 0 {
		t.Errorf("got %d agent_stop frames for an unowned session, want 0", got)
	}
}

func TestAgentRunStopsAClientGeneratedIdWithNoStartReply(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath: osArgsZero(),
		Env: fakeHostEnv(scenarioProtocol,
			envRequestLog+"="+logPath, envSuppress+"=agent_start"),
		RequestTimeout: 200 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	// An id this client generated cannot belong to another caller, so
	// stopping it is safe even with the start's outcome unknown.
	if _, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	}); err == nil {
		t.Fatal("expected the suppressed start to fail the run")
	}
	waitForFrameType(t, readLog, "agent_stop")
}

func TestAgentRunRejectsAnInvalidSessionID(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)

	_, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef,
		Messages: []Message{UserMessage("hi")},
		Options:  &RunOptions{SessionID: "too-short"},
	})
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || protocolErr.Code != CodeInvalidRequest {
		t.Fatalf("expected an invalid_request *ProtocolError, got %v", err)
	}
	if !strings.Contains(protocolErr.Message, "NanoID") {
		t.Errorf("Message = %q", protocolErr.Message)
	}
}

func TestAgentRunSurfacesSettlementErrors(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envAgentEvents+`=[
		{"type":"error","message":"the loop gave up","code":"internal_error"}
	]`)

	_, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	var streamErr *StreamError
	if !errors.As(err, &streamErr) {
		t.Fatalf("expected *StreamError, got %T: %v", err, err)
	}
	if streamErr.Code != "internal_error" || streamErr.Message != "the loop gave up" {
		t.Errorf("error = %+v", streamErr)
	}
	if streamErr.SessionID == "" {
		t.Error("expected the session id to be attached")
	}
}

func TestAgentRunMapsSettledAuthFailure(t *testing.T) {
	// A provider turn that failed on credentials settles through agent_end
	// with stop_reason "error"; the SDK re-raises it as an auth error.
	client := newTestClient(t, scenarioProtocol, envAgentEvents+`=[
		{"type":"turn_start"},
		{"type":"turn_end","stop_reason":"error","error_message":"auth_required"},
		{"type":"agent_end","stop_reason":"error","error_message":"auth_required","provider_id":"anthropic"}
	]`)

	_, err := client.Agent.Run(testContext(t), AgentRequest{
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

func TestAgentRunRejectsMalformedEventJSON(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envAgentResult+"=not-json")

	_, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	var streamErr *StreamError
	if !errors.As(err, &streamErr) || streamErr.Kind != KindTransportError {
		t.Fatalf("expected a transport *StreamError, got %v", err)
	}
	if !strings.Contains(streamErr.Message, "malformed JSON") {
		t.Errorf("Message = %q", streamErr.Message)
	}
}

func TestAgentStreamEmitsLifecycleEvents(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envAgentEvents+`=[
		{"type":"agent_start","session_id":"ignored"},
		{"type":"turn_start"},
		{"type":"message_start","provider_id":"anthropic","api":"anthropic-messages","model_id":"m"},
		{"type":"text_delta","delta":"one"},
		{"type":"tool_execution_start","tool_call_id":"call-1","tool_name":"lookup"},
		{"type":"tool_execution_end","tool_call_id":"call-1","is_error":false},
		{"type":"message_end","usage":{"input":1,"output":2},"stop_reason":"end_turn"},
		{"type":"turn_end","stop_reason":"end_turn"},
		{"type":"agent_end","stop_reason":"end_turn"}
	]`)

	stream, err := client.Agent.Stream(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	var kinds []string
	var end *AgentEnd
	for stream.Next() {
		switch event := stream.Event().(type) {
		case *AgentStart:
			kinds = append(kinds, "agent_start")
		case *TurnStart:
			kinds = append(kinds, "turn_start")
		case *MessageStart:
			kinds = append(kinds, "message_start")
		case *TextDelta:
			kinds = append(kinds, "text_delta")
		case *ToolExecutionStart:
			kinds = append(kinds, "tool_execution_start")
			if event.ToolName != "lookup" {
				t.Errorf("ToolName = %q", event.ToolName)
			}
		case *ToolExecutionEnd:
			kinds = append(kinds, "tool_execution_end")
		case *MessageEnd:
			kinds = append(kinds, "message_end")
		case *TurnEnd:
			kinds = append(kinds, "turn_end")
		case *AgentEnd:
			kinds = append(kinds, "agent_end")
			end = event
		default:
			t.Fatalf("unexpected event %T", event)
		}
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("Err: %v", err)
	}

	want := "agent_start,turn_start,message_start,text_delta,tool_execution_start," +
		"tool_execution_end,message_end,turn_end,agent_end"
	if got := strings.Join(kinds, ","); got != want {
		t.Errorf("event order =\n  %s\nwant\n  %s", got, want)
	}
	if end == nil {
		t.Fatal("expected a terminal agent_end")
	}
	// agent_end reports only the last turn, so the SDK aggregates usage
	// across the run's provider turns.
	if end.Usage == nil || end.Usage.Input != 1 || end.Usage.Output != 2 {
		t.Errorf("aggregate usage = %+v", end.Usage)
	}
}

func TestAgentStreamAggregatesUsageAcrossTurns(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envAgentEvents+`=[
		{"type":"message_start"},
		{"type":"message_end","usage":{"input":3,"output":4,"cache_read":1}},
		{"type":"message_start"},
		{"type":"message_end","usage":{"input":5,"output":6,"cache_read":2}},
		{"type":"agent_end","stop_reason":"end_turn","usage":{"input":5,"output":6}}
	]`)

	stream, err := client.Agent.Stream(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	var end *AgentEnd
	for stream.Next() {
		if value, ok := stream.Event().(*AgentEnd); ok {
			end = value
		}
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("Err: %v", err)
	}
	if end == nil || end.Usage == nil {
		t.Fatal("expected a terminal agent_end with usage")
	}
	if end.Usage.Input != 8 || end.Usage.Output != 10 || end.Usage.CacheRead != 3 {
		t.Errorf("aggregate usage = %+v, want the sum of both turns", end.Usage)
	}
}

func TestAgentStreamSynthesizesAgentStart(t *testing.T) {
	// The runtime does not always open a run with agent_start.
	client := newTestClient(t, scenarioProtocol, envAgentEvents+`=[
		{"type":"text_delta","delta":"straight to content"},
		{"type":"agent_end","stop_reason":"end_turn"}
	]`)

	stream, err := client.Agent.Stream(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	if !stream.Next() {
		t.Fatalf("expected a first event: %v", stream.Err())
	}
	start, ok := stream.Event().(*AgentStart)
	if !ok {
		t.Fatalf("first event = %T, want *AgentStart", stream.Event())
	}
	if !isNanoID(start.SessionID) {
		t.Errorf("synthesized session id %q is not a NanoID", start.SessionID)
	}

	// The event that actually arrived first is not lost.
	if !stream.Next() {
		t.Fatalf("expected the original first event: %v", stream.Err())
	}
	if delta, ok := stream.Event().(*TextDelta); !ok || delta.Delta != "straight to content" {
		t.Errorf("second event = %#v", stream.Event())
	}
}

func TestAgentStreamCloseStopsAnAbandonedRun(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath, envTrackSessions+"=1")

	stream, err := client.Agent.Stream(testContext(t), AgentRequest{
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
	if err := stream.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}

	waitForFrameType(t, readLog, "agent_stop")
}

func TestAgentStreamRespectsContextCancellation(t *testing.T) {
	client := newTestClient(t, scenarioProtocol, envSuppress+"=agent_message")

	ctx, cancel := context.WithCancel(context.Background())
	stream, err := client.Agent.Stream(ctx, AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	defer stream.Close()

	go func() {
		time.Sleep(80 * time.Millisecond)
		cancel()
	}()
	for stream.Next() {
	}
	if !errors.Is(stream.Err(), context.Canceled) {
		t.Fatalf("expected a context.Canceled-wrapped error, got %v", stream.Err())
	}
}

func TestAgentRunRollsBackTheSequenceOnARejectedMessage(t *testing.T) {
	logPath, readLog := requestLogPath(t)
	client := newTestClient(t, scenarioProtocol,
		envRequestLog+"="+logPath,
		envNack+`=agent_message:{"error_code":"invalid_request","reason":"invalid sequence"}`)

	if _, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	}); err == nil {
		t.Fatal("expected the rejected message to fail the run")
	}

	stops := waitForFrameType(t, readLog, "agent_stop")
	// A rejected message admits nothing, so the runtime's expected sequence
	// is still 2 and the stop must carry that rather than 3.
	if stops[0].Sequence != 2 {
		t.Errorf("agent_stop sequence = %d, want 2 after a rejected message", stops[0].Sequence)
	}
}

func TestAgentRunSkipsFramesRepliedToAnotherRequest(t *testing.T) {
	run := &agentRun{
		sessionID:        "testNanoIdSess1234567",
		startMessageID:   "MINE",
		fallbackProvider: "anthropic",
		toolBuf:          newToolBuffer(),
		nextSequence:     2,
	}
	tr := &transport{
		logger:     discardLogger,
		streams:    map[string][]*subscription{},
		sessions:   map[string][]*subscription{},
		correlates: map[string]*subscription{},
		done:       make(chan struct{}),
		exited:     make(chan struct{}),
	}
	run.transport = tr
	run.sub = tr.subscribeSession(run.sessionID)
	run.ctx = testContext(t)
	run.timeout = time.Second

	// A pre-acceptance reply naming a different request belongs to another
	// attempt and must not be consumed here.
	tr.dispatch(&frame{Type: "agent_started", SessionID: run.sessionID, InReplyTo: "THEIRS",
		Payload: mustMarshal(map[string]any{"session_id": run.sessionID})})
	// Uncorrelated run output before acceptance is not this attempt's.
	tr.dispatch(&frame{Type: "agent_event", SessionID: run.sessionID,
		Payload: mustMarshal(map[string]any{"event_json": `{"type":"text_delta","delta":"stale"}`})})
	// The attempt's own reply settles the start.
	tr.dispatch(&frame{Type: "nack", SessionID: run.sessionID, InReplyTo: "MINE",
		Payload: mustMarshal(map[string]any{"error_code": "agent_busy", "reason": "session already exists"})})

	_, err := run.pump()
	var streamErr *StreamError
	if !errors.As(err, &streamErr) || streamErr.Code != CodeAgentBusy {
		t.Fatalf("expected the attempt's own agent_busy rejection, got %v", err)
	}
	if !run.foreignSession {
		t.Error("an agent_busy rejection should mark the session as foreign")
	}
}

func TestAgentRunToolCallSeesTheCallersContext(t *testing.T) {
	type ctxKey struct{}
	client := newTestClient(t, scenarioProtocol,
		envToolCalls+`=[{"tool_call_id":"call-1","tool_name":"probe","args_json":"{}"}]`)

	ctx := context.WithValue(testContext(t), ctxKey{}, "carried")
	var observed any
	if _, err := client.Agent.Run(ctx, AgentRequest{
		ModelRef: testModelRef,
		Messages: []Message{UserMessage("hi")},
		Tools: []Tool{{
			Name: "probe",
			Execute: func(ctx context.Context, call ToolInvocation) (string, error) {
				observed = ctx.Value(ctxKey{})
				return "ok", nil
			},
		}},
	}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if observed != "carried" {
		t.Errorf("tool context value = %v, want carried", observed)
	}
}

func TestAgentRunAcceptsTaggedUnionEvents(t *testing.T) {
	// The runtime serializes its event union as a single-key object.
	client := newTestClient(t, scenarioProtocol, envAgentEvents+`=[
		{"turn_start":{}},
		{"agent_end":{"stop_reason":"end_turn","usage":{"input":2,"output":3}}}
	]`)

	response, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if response.StopReason != "end_turn" {
		t.Errorf("StopReason = %q", response.StopReason)
	}
	if response.Usage == nil || response.Usage.Input != 2 {
		t.Errorf("Usage = %+v", response.Usage)
	}
}

func TestAgentRunIgnoresUnprojectedEvents(t *testing.T) {
	// tool_execution_update is deferred from the V1 surface; it must be
	// skipped rather than treated as an unknown frame.
	client := newTestClient(t, scenarioProtocol, envAgentEvents+`=[
		{"type":"tool_execution_update","tool_call_id":"call-1"},
		{"type":"context_usage","used":10},
		{"type":"agent_end","stop_reason":"end_turn"}
	]`)

	if _, err := client.Agent.Run(testContext(t), AgentRequest{
		ModelRef: testModelRef, Messages: []Message{UserMessage("hi")},
	}); err != nil {
		t.Fatalf("Run: %v", err)
	}
}

func TestMain_FakeHostIsNotTheRealRuntime(t *testing.T) {
	// Guards the test harness itself: a stray MAKAI_BINARY_PATH must not
	// silently replace the fake host and make these tests hit a real binary.
	if os.Getenv(envFakeHost) != "" {
		t.Fatal("the test process should not be running as a fake host")
	}
}

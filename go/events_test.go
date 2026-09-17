package makai

import (
	"encoding/json"
	"errors"
	"testing"
)

// The runtime carries the same logical event in several frame shapes: some
// frames name their kind in "type", some in "event_type", some nest the event
// under "event" or "message", and some arrive as a Zig tagged union. These
// tests pin the normalization for the shapes the integration tests do not
// reach.

func makeFrame(t *testing.T, frameType, payload string) *frame {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"type": frameType, "payload": json.RawMessage(payload)})
	if err != nil {
		t.Fatal(err)
	}
	return &frame{Type: frameType, Payload: json.RawMessage(payload), raw: raw}
}

func TestNormalizeProviderFrameCoversFrameShapes(t *testing.T) {
	for name, tc := range map[string]struct {
		frameType string
		payload   string
		check     func(*testing.T, ProviderEvent)
	}{
		"start frame": {"start", `{"provider_id":"anthropic","api":"anthropic-messages","model_id":"m"}`,
			func(t *testing.T, event ProviderEvent) {
				start, ok := event.(*MessageStart)
				if !ok || start.ProviderID != "anthropic" || start.ModelID != "m" {
					t.Errorf("event = %#v", event)
				}
			}},
		"start frame with legacy field names": {"message_start", `{"provider":"anthropic","model":"m"}`,
			func(t *testing.T, event ProviderEvent) {
				start, ok := event.(*MessageStart)
				if !ok || start.ProviderID != "anthropic" || start.ModelID != "m" {
					t.Errorf("event = %#v", event)
				}
			}},
		"event envelope": {"event", `{"event":{"type":"text_delta","delta":"hi"}}`,
			func(t *testing.T, event ProviderEvent) {
				delta, ok := event.(*TextDelta)
				if !ok || delta.Delta != "hi" {
					t.Errorf("event = %#v", event)
				}
			}},
		"event envelope with event_type": {"event", `{"event_type":"text_delta","delta":"hi"}`,
			func(t *testing.T, event ProviderEvent) {
				delta, ok := event.(*TextDelta)
				if !ok || delta.Delta != "hi" {
					t.Errorf("event = %#v", event)
				}
			}},
		"reasoning becomes thinking": {"reasoning", `{"reasoning":"pondering"}`,
			func(t *testing.T, event ProviderEvent) {
				delta, ok := event.(*ThinkingDelta)
				if !ok || delta.Delta != "pondering" {
					t.Errorf("event = %#v", event)
				}
			}},
		"reasoning_delta becomes thinking": {"reasoning_delta", `{"delta":"pondering"}`,
			func(t *testing.T, event ProviderEvent) {
				if delta, ok := event.(*ThinkingDelta); !ok || delta.Delta != "pondering" {
					t.Errorf("event = %#v", event)
				}
			}},
		"done frame closes the message": {"done", `{"stop_reason":"end_turn","usage":{"input":1,"output":2}}`,
			func(t *testing.T, event ProviderEvent) {
				end, ok := event.(*MessageEnd)
				if !ok || end.StopReason != "end_turn" {
					t.Fatalf("event = %#v", event)
				}
				if end.Usage == nil || end.Usage.Output != 2 {
					t.Errorf("Usage = %+v", end.Usage)
				}
			}},
		"result frame closes the message": {"result", `{"reason":"max_tokens"}`,
			func(t *testing.T, event ProviderEvent) {
				if end, ok := event.(*MessageEnd); !ok || end.StopReason != "max_tokens" {
					t.Errorf("event = %#v", event)
				}
			}},
		"stream_error frame": {"stream_error", `{"message":"boom","code":"provider_error","provider_id":"anthropic"}`,
			func(t *testing.T, event ProviderEvent) {
				errEvent, ok := event.(*ErrorEvent)
				if !ok || errEvent.Message != "boom" || errEvent.Code != "provider_error" {
					t.Fatalf("event = %#v", event)
				}
				if errEvent.ProviderID != "anthropic" {
					t.Errorf("ProviderID = %q", errEvent.ProviderID)
				}
			}},
		"error frame with legacy field names": {"error", `{"error_message":"boom","error_code":"internal"}`,
			func(t *testing.T, event ProviderEvent) {
				errEvent, ok := event.(*ErrorEvent)
				if !ok || errEvent.Message != "boom" || errEvent.Code != "internal" {
					t.Errorf("event = %#v", event)
				}
			}},
		"tool_call with an id field": {"tool_call", `{"id":"call-1","name":"lookup","arguments_json":"{}"}`,
			func(t *testing.T, event ProviderEvent) {
				call, ok := event.(*ToolCallEvent)
				if !ok || call.ToolCallID != "call-1" || call.Name != "lookup" {
					t.Errorf("event = %#v", event)
				}
			}},
	} {
		t.Run(name, func(t *testing.T) {
			event := normalizeProviderFrame(makeFrame(t, tc.frameType, tc.payload), newToolBuffer())
			if event == nil {
				t.Fatal("expected an event")
			}
			tc.check(t, event)
		})
	}
}

func TestNormalizeProviderFrameIgnoresUnknownFrames(t *testing.T) {
	for _, frameType := range []string{"ack", "nack", "heartbeat", "keepalive"} {
		if event := normalizeProviderFrame(makeFrame(t, frameType, `{}`), newToolBuffer()); event != nil {
			t.Errorf("frame %q produced %#v, want no event", frameType, event)
		}
	}
}

func TestNormalizeProviderFrameFallsBackToTheEnvelope(t *testing.T) {
	// Some runtime frames carry their fields at the top level rather than
	// under "payload".
	raw := json.RawMessage(`{"type":"text_delta","delta":"top level"}`)
	event := normalizeProviderFrame(&frame{Type: "text_delta", raw: raw}, newToolBuffer())
	if delta, ok := event.(*TextDelta); !ok || delta.Delta != "top level" {
		t.Errorf("event = %#v", event)
	}
}

func TestToolBufferTracksSeveralCalls(t *testing.T) {
	tools := newToolBuffer()

	tools.start(0, "call-0", "first")
	tools.start(1, "call-1", "second")
	tools.delta(0, `{"a":`)
	tools.delta(1, `{"b":`)
	tools.delta(0, `1}`)
	tools.delta(1, `2}`)
	if tools.size() != 2 {
		t.Fatalf("size = %d, want 2", tools.size())
	}

	first := bufferedToolCall(jsonObject{"content_index": float64(0)}, tools)
	if first.ToolCallID != "call-0" || first.Name != "first" || first.ArgumentsJSON != `{"a":1}` {
		t.Errorf("first call = %+v", first)
	}
	second := bufferedToolCall(jsonObject{"content_index": float64(1)}, tools)
	if second.ToolCallID != "call-1" || second.ArgumentsJSON != `{"b":2}` {
		t.Errorf("second call = %+v", second)
	}
	if tools.size() != 0 {
		t.Errorf("size = %d after both ends, want 0", tools.size())
	}
}

func TestBufferedToolCallPrefersExplicitFields(t *testing.T) {
	// A toolcall_end that repeats the identity wins over the buffer.
	tools := newToolBuffer()
	tools.start(0, "buffered-id", "buffered-name")
	tools.delta(0, "buffered-args")

	call := bufferedToolCall(jsonObject{
		"content_index": float64(0), "tool_call_id": "explicit-id",
		"name": "explicit-name", "arguments_json": "explicit-args",
	}, tools)
	if call.ToolCallID != "explicit-id" || call.Name != "explicit-name" || call.ArgumentsJSON != "explicit-args" {
		t.Errorf("call = %+v", call)
	}
}

func TestBufferedToolCallSurvivesAMissingStart(t *testing.T) {
	// Deltas can arrive without a start if the stream was joined late.
	tools := newToolBuffer()
	tools.delta(3, "{}")
	call := bufferedToolCall(jsonObject{"content_index": float64(3)}, tools)
	if call.ArgumentsJSON != "{}" {
		t.Errorf("ArgumentsJSON = %q", call.ArgumentsJSON)
	}
}

func TestNormalizeAgentFrameCoversFrameShapes(t *testing.T) {
	events, err := normalizeAgentFrame(
		makeFrame(t, "agent_result", `{"result_json":"{\"stop_reason\":\"end_turn\",\"usage\":{\"input\":1,\"output\":2}}"}`),
		newToolBuffer())
	if err != nil {
		t.Fatalf("agent_result: %v", err)
	}
	end, ok := events[0].(*AgentEnd)
	if !ok || end.StopReason != "end_turn" {
		t.Fatalf("agent_result produced %#v", events)
	}
	if end.Usage == nil || end.Usage.Output != 2 {
		t.Errorf("Usage = %+v", end.Usage)
	}

	events, err = normalizeAgentFrame(
		makeFrame(t, "agent_error", `{"message":"loop failed","code":"internal_error"}`),
		newToolBuffer())
	if err != nil {
		t.Fatalf("agent_error: %v", err)
	}
	if errEvent, ok := events[0].(*ErrorEvent); !ok || errEvent.Code != "internal_error" {
		t.Errorf("agent_error produced %#v", events)
	}

	// An "event" envelope carrying an agent-level kind is routed to the
	// agent normalizer, not the provider one.
	events, err = normalizeAgentFrame(
		makeFrame(t, "event", `{"event":{"type":"turn_start"}}`),
		newToolBuffer())
	if err != nil {
		t.Fatalf("event envelope: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("event envelope produced %#v", events)
	}
	if _, ok := events[0].(*TurnStart); !ok {
		t.Errorf("event envelope produced %#v", events[0])
	}
}

func TestNormalizeAgentFrameRejectsMalformedJSONPayloads(t *testing.T) {
	for _, tc := range []struct{ frameType, payload string }{
		{"agent_result", `{"result_json":"not json"}`},
		{"agent_event", `{"event_json":"not json"}`},
	} {
		_, err := normalizeAgentFrame(makeFrame(t, tc.frameType, tc.payload), newToolBuffer())
		var streamErr *StreamError
		if !errors.As(err, &streamErr) || streamErr.Kind != KindTransportError {
			t.Errorf("%s: expected a transport *StreamError, got %v", tc.frameType, err)
		}
	}
}

func TestNormalizeAgentPayloadUnwrapsTaggedUnions(t *testing.T) {
	events := normalizeAgentPayload(jsonObject{
		"tool_execution_start": map[string]any{"tool_call_id": "call-1", "tool_name": "lookup"},
	}, newToolBuffer())
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1", len(events))
	}
	start, ok := events[0].(*ToolExecutionStart)
	if !ok || start.ToolCallID != "call-1" || start.ToolName != "lookup" {
		t.Errorf("event = %#v", events[0])
	}
}

func TestNormalizeAgentPayloadProjectsMessageUpdates(t *testing.T) {
	events := normalizeAgentPayload(jsonObject{
		"type":  "message_update",
		"event": map[string]any{"type": "text_delta", "delta": "inner"},
	}, newToolBuffer())
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1", len(events))
	}
	if delta, ok := events[0].(*TextDelta); !ok || delta.Delta != "inner" {
		t.Errorf("event = %#v", events[0])
	}
}

func TestEventKindPrefersExplicitTypes(t *testing.T) {
	for name, tc := range map[string]struct {
		event jsonObject
		want  string
	}{
		"type wins":                {jsonObject{"type": "text_delta", "event_type": "other"}, "text_delta"},
		"event_type fills in":      {jsonObject{"event_type": "turn_start"}, "turn_start"},
		"event unwraps event_type": {jsonObject{"type": "event", "event_type": "turn_end"}, "turn_end"},
		"tagged union":             {jsonObject{"agent_start": map[string]any{}}, "agent_start"},
		// Go maps have no key order, so a multi-key object with no explicit
		// type is deliberately not guessed at.
		"ambiguous object": {jsonObject{"a": 1, "b": 2}, ""},
		"empty object":     {jsonObject{}, ""},
	} {
		t.Run(name, func(t *testing.T) {
			if got := eventKind(tc.event); got != tc.want {
				t.Errorf("eventKind = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestUsageFromAcceptsBothSpellings(t *testing.T) {
	if usage := usageFrom(jsonObject{"input": float64(1), "output": float64(2)}); usage == nil || usage.Input != 1 {
		t.Errorf("usage = %+v", usage)
	}
	if usage := usageFrom(jsonObject{"input_tokens": float64(3), "output_tokens": float64(4)}); usage == nil || usage.Output != 4 {
		t.Errorf("usage = %+v", usage)
	}
	// A half-reported usage is not usage.
	if usage := usageFrom(jsonObject{"input": float64(1)}); usage != nil {
		t.Errorf("usage = %+v, want nil", usage)
	}
	if usage := usageFrom(nil); usage != nil {
		t.Errorf("usage = %+v, want nil", usage)
	}
}

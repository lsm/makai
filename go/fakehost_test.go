package makai

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// The fake host is a stand-in for `makai --stdio`. It runs inside the test
// binary, re-executed as a child process, which keeps protocol-level tests
// free of both API keys and an external runtime.
//
// A test picks a scenario with fakeHostEnv and tunes it with the knobs below;
// TestMain routes a child process carrying envFakeHost into runFakeHost
// instead of into the test suite.

const (
	envFakeHost = "MAKAI_GO_FAKE_HOST"

	// envRequestLog names a file the host appends every inbound envelope to,
	// so a test can assert on what the SDK actually put on the wire.
	envRequestLog = "MAKAI_GO_FAKE_REQUEST_LOG"

	// envProviderEvents replaces the provider stream's event list with a
	// JSON array of event objects.
	envProviderEvents = "MAKAI_GO_FAKE_PROVIDER_EVENTS"
	// envProviderResult replaces the buffered completion result payload.
	envProviderResult = "MAKAI_GO_FAKE_PROVIDER_RESULT"
	// envAgentEvents replaces the agent run's event list.
	envAgentEvents = "MAKAI_GO_FAKE_AGENT_EVENTS"
	// envAgentResult settles the agent run with an agent_result frame
	// carrying this payload instead of running the event list.
	envAgentResult = "MAKAI_GO_FAKE_AGENT_RESULT"
	// envModelsResponse replaces the models_response payload.
	envModelsResponse = "MAKAI_GO_FAKE_MODELS_RESPONSE"
	// envNack makes the host reject the named frame type with a payload:
	// "<frame_type>:<json payload>".
	envNack = "MAKAI_GO_FAKE_NACK"
	// envSuppress makes the host acknowledge the named frame types but send
	// no response, as a comma-separated list.
	envSuppress = "MAKAI_GO_FAKE_SUPPRESS"
	// envTrackSessions makes the host enforce the agent session lifecycle:
	// a live id rejects agent_start with agent_busy, and only a
	// sequence-valid agent_stop removes it.
	envTrackSessions = "MAKAI_GO_FAKE_TRACK_SESSIONS"
	// envToolCalls makes the agent run ask the client to execute tools. It
	// is a JSON array of {tool_call_id, tool_name, args_json} objects.
	envToolCalls = "MAKAI_GO_FAKE_TOOL_CALLS"
	// envToolResultLog names a file the host appends each tool_result
	// payload to.
	envToolResultLog = "MAKAI_GO_FAKE_TOOL_RESULT_LOG"
	// envAuthPrompt makes the login flow ask for a code before succeeding;
	// its value is the answer that completes the flow.
	envAuthPrompt = "MAKAI_GO_FAKE_AUTH_PROMPT"
	// envAuthProviders replaces the auth_providers_response payload.
	envAuthProviders = "MAKAI_GO_FAKE_AUTH_PROVIDERS"
	// envSlowResponse delays every response by this many milliseconds.
	envSlowResponse = "MAKAI_GO_FAKE_SLOW_MS"
)

// Scenario names for envFakeHost.
const (
	// scenarioProtocol is the full protocol host used by most tests.
	scenarioProtocol = "protocol"
	// scenarioSilent never writes anything, so the handshake times out.
	scenarioSilent = "silent"
	// scenarioBadVersion announces a protocol version the SDK rejects.
	scenarioBadVersion = "bad-version"
	// scenarioHandshakeError replies to the handshake with an error frame.
	scenarioHandshakeError = "handshake-error"
	// scenarioExitAfterReady exits as soon as it has shaken hands.
	scenarioExitAfterReady = "exit-after-ready"
	// scenarioExitMidRequest acknowledges one request, then exits without
	// answering it.
	scenarioExitMidRequest = "exit-mid-request"
	// scenarioGarbage emits unparsable lines around its real frames.
	scenarioGarbage = "garbage"
	// scenarioIgnoreStdin keeps running after its stdin closes, so Close has
	// to kill it.
	scenarioIgnoreStdin = "ignore-stdin"
)

// fakeHostEnv returns the environment for a child running the given scenario,
// with any extra KEY=VALUE knobs appended.
func fakeHostEnv(scenario string, knobs ...string) []string {
	env := append(os.Environ(), envFakeHost+"="+scenario)
	return append(env, knobs...)
}

var fakeStdoutMu sync.Mutex

func fakeEmit(value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	fakeStdoutMu.Lock()
	defer fakeStdoutMu.Unlock()
	os.Stdout.Write(append(encoded, '\n'))
}

func fakeEmitRaw(line string) {
	fakeStdoutMu.Lock()
	defer fakeStdoutMu.Unlock()
	os.Stdout.WriteString(line + "\n")
}

func fakeReady() { fakeEmitRaw(`{"type":"ready","protocol_version":"1"}`) }

// blockForever parks the fake host without letting Go's deadlock detector
// tear it down, which an empty select would.
func blockForever() {
	for {
		time.Sleep(time.Hour)
	}
}

// runFakeHost is the child process entry point. It never returns.
func runFakeHost(scenario string) {
	switch scenario {
	case scenarioSilent:
		blockForever()
	case scenarioBadVersion:
		fakeEmitRaw(`{"type":"ready","protocol_version":"2"}`)
		blockForever()
	case scenarioHandshakeError:
		fakeEmitRaw(`{"type":"error","code":"startup_failed","message":"runtime could not start"}`)
		blockForever()
	case scenarioExitAfterReady:
		fakeReady()
		os.Exit(0)
	case scenarioGarbage:
		fakeEmitRaw("this is not json")
		fakeReady()
		fakeEmitRaw("{ broken")
		runProtocolHost(false)
	case scenarioExitMidRequest:
		fakeReady()
		runProtocolHost(true)
	case scenarioIgnoreStdin:
		fakeReady()
		blockForever()
	default:
		fakeReady()
		runProtocolHost(false)
	}
	os.Exit(0)
}

// fakeReply builds a reply correlated to the request that prompted it.
func fakeReply(request *frame, frameType string, sequence int64, payload any) *frame {
	reply := &frame{
		Type:      frameType,
		StreamID:  request.StreamID,
		SessionID: request.SessionID,
		MessageID: newULID(),
		Sequence:  sequence,
		Timestamp: time.Now().UnixMilli(),
		Version:   envelopeVersion,
		InReplyTo: request.MessageID,
		Payload:   mustMarshal(payload),
	}
	return reply
}

// fakeAsync builds run output, which the real runtime publishes on the
// session route without an in_reply_to.
func fakeAsync(request *frame, frameType string, sequence int64, payload any) *frame {
	async := fakeReply(request, frameType, sequence, payload)
	async.InReplyTo = ""
	return async
}

// runProtocolHost answers protocol requests until stdin closes.
func runProtocolHost(exitAfterFirstAck bool) {
	reader := newFrameReader(os.Stdin)
	sessions := map[string]int64{}
	trackSessions := os.Getenv(envTrackSessions) != ""
	slow := envDuration(envSlowResponse)
	suppressed := map[string]bool{}
	for _, value := range strings.Split(os.Getenv(envSuppress), ",") {
		if value != "" {
			suppressed[value] = true
		}
	}
	nackType, nackPayload := parseNackKnob()

	for {
		f, err := reader.next()
		if errors.Is(err, errMalformedFrame) {
			continue
		}
		if err != nil {
			return
		}
		appendLog(envRequestLog, string(f.raw))

		fakeEmit(fakeReply(f, "ack", 1, map[string]any{"acknowledged_id": f.MessageID}))
		if exitAfterFirstAck {
			os.Exit(0)
		}
		if slow > 0 {
			time.Sleep(slow)
		}
		if suppressed[f.Type] {
			continue
		}
		if nackType == f.Type {
			fakeEmit(fakeReply(f, "nack", 2, nackPayload))
			continue
		}

		switch f.Type {
		case "models_request":
			fakeEmit(fakeReply(f, "models_response", 2, jsonKnob(envModelsResponse, defaultModelsResponse())))
		case "auth_providers_request":
			fakeEmit(fakeReply(f, "auth_providers_response", 2, jsonKnob(envAuthProviders, defaultAuthProviders())))
		case "auth_login_start":
			handleFakeLogin(f)
		case "auth_prompt_response":
			handleFakePromptResponse(f)
		case "auth_cancel":
			fakeEmit(fakeReply(f, "auth_login_result", 3, map[string]any{
				"status": "cancelled", "flow_id": f.StreamID,
			}))
		case "complete_request":
			fakeEmit(fakeReply(f, "result", 2, jsonKnob(envProviderResult, defaultProviderResult())))
		case "stream_request":
			for i, event := range jsonArrayKnob(envProviderEvents, defaultProviderEvents()) {
				eventType, _ := event["type"].(string)
				fakeEmit(fakeReply(f, eventType, int64(i)+2, event))
			}
		case "agent_start":
			handleFakeAgentStart(f, sessions, trackSessions)
		case "agent_message":
			handleFakeAgentMessage(f, sessions, trackSessions)
		case "agent_stop":
			handleFakeAgentStop(f, sessions, trackSessions)
		case "tool_result":
			appendLog(envToolResultLog, string(f.Payload))
		}
	}
}

func handleFakeAgentStart(f *frame, sessions map[string]int64, track bool) {
	if track {
		if _, live := sessions[f.SessionID]; live {
			fakeEmit(fakeReply(f, "nack", 2, map[string]any{
				"error_code": "agent_busy", "reason": "session already exists",
			}))
			return
		}
		sessions[f.SessionID] = 2
	}
	fakeEmit(fakeReply(f, "agent_started", 2, map[string]any{"session_id": f.SessionID}))
}

func handleFakeAgentMessage(f *frame, sessions map[string]int64, track bool) {
	if track {
		expected, known := sessions[f.SessionID]
		if !known {
			fakeEmit(fakeReply(f, "agent_error", 0, map[string]any{
				"code": "agent_not_found", "message": "unknown session",
			}))
			return
		}
		if f.Sequence != expected {
			fakeEmit(fakeReply(f, "agent_error", 0, map[string]any{
				"code": "invalid_request", "message": "invalid sequence",
			}))
			return
		}
		sessions[f.SessionID] = expected + 1
	}

	sequence := int64(2)
	for _, call := range jsonArrayKnob(envToolCalls, nil) {
		fakeEmit(fakeAsync(f, "tool_execute", sequence, call))
		sequence++
		// The runtime waits for the correlated tool_result before it
		// continues the turn; the fake host reads it from the same stdin
		// loop, so just give the SDK a beat to answer.
		time.Sleep(20 * time.Millisecond)
	}

	if raw := os.Getenv(envAgentResult); raw != "" {
		fakeEmit(fakeReply(f, "agent_result", sequence, map[string]any{"result_json": raw}))
		fakeEmit(fakeAsync(f, "agent_event", sequence+1, map[string]any{
			"event_json": `{"type":"agent_end","stop_reason":"end_turn"}`,
		}))
		return
	}
	for _, event := range jsonArrayKnob(envAgentEvents, defaultAgentEvents()) {
		encoded, err := json.Marshal(event)
		if err != nil {
			continue
		}
		fakeEmit(fakeAsync(f, "agent_event", sequence, map[string]any{"event_json": string(encoded)}))
		sequence++
	}
}

func handleFakeAgentStop(f *frame, sessions map[string]int64, track bool) {
	if !track {
		fakeEmit(fakeReply(f, "agent_stopped", 2, map[string]any{"session_id": f.SessionID}))
		return
	}
	expected, known := sessions[f.SessionID]
	if !known {
		fakeEmit(fakeReply(f, "agent_error", 0, map[string]any{
			"code": "agent_not_found", "message": "unknown session",
		}))
		return
	}
	if f.Sequence != expected {
		fakeEmit(fakeReply(f, "agent_error", 0, map[string]any{
			"code": "invalid_request", "message": "invalid sequence",
		}))
		return
	}
	delete(sessions, f.SessionID)
	fakeEmit(fakeReply(f, "agent_stopped", 2, map[string]any{"session_id": f.SessionID}))
}

func handleFakeLogin(f *frame) {
	providerID := f.payload().str("provider_id")
	fakeEmit(fakeReply(f, "auth_event", 2, map[string]any{
		"auth_url": map[string]any{
			"flow_id": f.StreamID, "provider_id": providerID,
			"url": "https://example.invalid/login", "instructions": "open the link",
		},
	}))
	if os.Getenv(envAuthPrompt) != "" {
		fakeEmit(fakeReply(f, "auth_event", 3, map[string]any{
			"prompt": map[string]any{
				"flow_id": f.StreamID, "prompt_id": "code", "provider_id": providerID,
				"message": "Enter the code", "allow_empty": false,
			},
		}))
		return
	}
	fakeEmit(fakeReply(f, "auth_event", 3, map[string]any{
		"success": map[string]any{"flow_id": f.StreamID, "provider_id": providerID},
	}))
	fakeEmit(fakeReply(f, "auth_login_result", 4, map[string]any{
		"status": "success", "flow_id": f.StreamID, "provider_id": providerID,
	}))
}

func handleFakePromptResponse(f *frame) {
	payload := f.payload()
	if payload.str("answer") == os.Getenv(envAuthPrompt) {
		fakeEmit(fakeReply(f, "auth_event", 4, map[string]any{
			"success": map[string]any{"flow_id": f.StreamID, "provider_id": "test-fixture"},
		}))
		fakeEmit(fakeReply(f, "auth_login_result", 5, map[string]any{
			"status": "success", "flow_id": f.StreamID,
		}))
		return
	}
	fakeEmit(fakeReply(f, "auth_event", 4, map[string]any{
		"error": map[string]any{
			"flow_id": f.StreamID, "provider_id": "test-fixture",
			"code": "invalid_code", "message": "the fixture rejected that code",
		},
	}))
	fakeEmit(fakeReply(f, "auth_login_result", 5, map[string]any{
		"status": "failed", "flow_id": f.StreamID,
	}))
}

func defaultModelsResponse() map[string]any {
	return map[string]any{
		"fetched_at_ms":    float64(1_700_000_000_000),
		"cache_max_age_ms": float64(300000),
		"models": []any{map[string]any{
			"model_ref":         "anthropic/anthropic-messages@claude-sonnet-4-5",
			"model_id":          "claude-sonnet-4-5",
			"display_name":      "Claude Sonnet 4.5",
			"provider_id":       "anthropic",
			"api":               "anthropic-messages",
			"base_url":          "https://api.anthropic.com",
			"auth_status":       "authenticated",
			"lifecycle":         "stable",
			"capabilities":      []any{"chat", "streaming", "tools", "reasoning"},
			"source":            "dynamic",
			"context_window":    float64(200000),
			"max_output_tokens": float64(8192),
			"reasoning_default": "medium",
		}},
	}
}

func defaultAuthProviders() map[string]any {
	return map[string]any{"providers": []any{
		map[string]any{"id": "anthropic", "name": "Anthropic", "auth_status": "login_required"},
		map[string]any{"id": "test-fixture", "name": "Test Fixture (CI)", "auth_status": "authenticated"},
	}}
}

func defaultProviderResult() map[string]any {
	return map[string]any{
		"role":        "assistant",
		"content":     []any{map[string]any{"type": "text", "text": "hello"}},
		"usage":       map[string]any{"input": float64(3), "output": float64(5), "cache_read": float64(1)},
		"provider_id": "anthropic",
		"api":         "anthropic-messages",
		"model_id":    "claude-sonnet-4-5",
		"stop_reason": "end_turn",
	}
}

func defaultProviderEvents() []map[string]any {
	return []map[string]any{
		{"type": "message_start", "provider_id": "anthropic", "api": "anthropic-messages", "model_id": "claude-sonnet-4-5"},
		{"type": "text_delta", "delta": "hel"},
		{"type": "reasoning", "delta": "thinking"},
		{"type": "text_delta", "delta": "lo"},
		{"type": "message_end", "usage": map[string]any{"input": float64(3), "output": float64(5)}, "stop_reason": "end_turn"},
	}
}

func defaultAgentEvents() []map[string]any {
	return []map[string]any{
		{"type": "agent_start", "session_id": "testNanoIdSess1234567"},
		{"type": "turn_start"},
		{"type": "message_start", "provider_id": "anthropic", "api": "anthropic-messages", "model_id": "claude-sonnet-4-5"},
		{"type": "text_delta", "delta": "agent"},
		{"type": "message_end", "usage": map[string]any{"input": float64(7), "output": float64(9)}, "stop_reason": "end_turn"},
		{"type": "turn_end", "stop_reason": "end_turn"},
		{"type": "agent_end", "usage": map[string]any{"input": float64(7), "output": float64(9)}, "stop_reason": "end_turn"},
	}
}

func jsonKnob(name string, fallback map[string]any) map[string]any {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return fallback
	}
	return decoded
}

func jsonArrayKnob(name string, fallback []map[string]any) []map[string]any {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}
	var decoded []map[string]any
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return fallback
	}
	return decoded
}

func parseNackKnob() (string, map[string]any) {
	raw := os.Getenv(envNack)
	frameType, payloadJSON, ok := strings.Cut(raw, ":")
	if !ok || frameType == "" {
		return "", nil
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
		return "", nil
	}
	return frameType, payload
}

func envDuration(name string) time.Duration {
	raw := os.Getenv(name)
	if raw == "" {
		return 0
	}
	var millis int
	if _, err := fmt.Sscanf(raw, "%d", &millis); err != nil {
		return 0
	}
	return time.Duration(millis) * time.Millisecond
}

func appendLog(envName, line string) {
	path := os.Getenv(envName)
	if path == "" {
		return
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	file.WriteString(line + "\n")
}

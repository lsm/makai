package makai

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseModelRefHandlesCanonicalRefs(t *testing.T) {
	for ref, want := range map[string]parsedModelRef{
		"anthropic/anthropic-messages@claude-sonnet-4-5": {"anthropic", "anthropic-messages", "claude-sonnet-4-5"},
		// A colon in a model id travels percent-encoded.
		"ollama/ollama@gemma4%3A31b": {"ollama", "ollama", "gemma4:31b"},
		"p/a@m":                      {"p", "a", "m"},
	} {
		got, ok := parseModelRef(ref)
		if !ok {
			t.Errorf("parseModelRef(%q) failed", ref)
			continue
		}
		if got != want {
			t.Errorf("parseModelRef(%q) = %+v, want %+v", ref, got, want)
		}
	}
}

func TestParseModelRefRejectsNonCanonicalRefs(t *testing.T) {
	for _, ref := range []string{
		"",
		"no-separators",
		"/anthropic-messages@model",
		"@anthropic/anthropic-messages",
		"anthropic/anthropic-messages",
		"anthropic/anthropic-messages@model@extra",
		"anthropic/anthropic-messages@model/extra",
		// A raw colon is not canonical encoding.
		"ollama/ollama@gemma4:31b",
		"anthropic/anthropic-messages@",
	} {
		if _, ok := parseModelRef(ref); ok {
			t.Errorf("parseModelRef(%q) should have failed", ref)
		}
	}
}

func TestProviderIDFromRefFallsBackToALooseSplit(t *testing.T) {
	// A hand-written ref is still usable for error attribution.
	if got := providerIDFromRef("ollama/ollama@gemma4:31b"); got != "ollama" {
		t.Errorf("providerIDFromRef = %q, want ollama", got)
	}
	if got := providerIDFromRef("opaque-handle"); got != "" {
		t.Errorf("providerIDFromRef = %q, want empty for an opaque ref", got)
	}
}

func TestModelFromRefFallsBackToAnOpaqueModel(t *testing.T) {
	// A ref the SDK cannot decompose is still sent, whole, as the model id,
	// so the runtime can resolve it itself.
	model := modelFromRef("opaque-handle")
	if model["id"] != "opaque-handle" || model["provider"] != "" || model["api"] != "" {
		t.Errorf("modelFromRef = %v", model)
	}
}

func TestValidateExecutionRequestEnforcesSegmentLimits(t *testing.T) {
	messages := []Message{UserMessage("hi")}

	longProvider := strings.Repeat("p", maxIdentifierLength+1) + "/a@m"
	if err := validateExecutionRequest(longProvider, messages); err == nil {
		t.Error("an oversized provider segment should be rejected")
	}
	longAPI := "p/" + strings.Repeat("a", maxIdentifierLength+1) + "@m"
	if err := validateExecutionRequest(longAPI, messages); err == nil {
		t.Error("an oversized api segment should be rejected")
	}
	longModel := "p/a@" + strings.Repeat("m", maxModelFieldLength+1)
	if err := validateExecutionRequest(longModel, messages); err == nil {
		t.Error("an oversized model segment should be rejected")
	}
	longOpaque := strings.Repeat("x", maxOpaqueRefLength+1)
	if err := validateExecutionRequest(longOpaque, messages); err == nil {
		t.Error("an oversized opaque ref should be rejected")
	}
	if err := validateExecutionRequest("p/a@m", messages); err != nil {
		t.Errorf("a valid ref was rejected: %v", err)
	}
	if err := validateExecutionRequest("opaque", messages); err != nil {
		t.Errorf("a short opaque ref was rejected: %v", err)
	}
}

func TestExecutionContextFoldsSystemAndDeveloperMessages(t *testing.T) {
	context := executionContext([]Message{
		SystemMessage("rule one"),
		{Role: RoleDeveloper, Text: "rule two"},
		UserMessage("question"),
	}, nil)

	if got := context["system_prompt"]; got != "rule one\n\nrule two" {
		t.Errorf("system_prompt = %q", got)
	}
	messages := context["messages"].([]map[string]any)
	if len(messages) != 1 || messages[0]["role"] != string(RoleUser) {
		t.Errorf("messages = %v", messages)
	}
}

func TestExecutionContextFlattensStructuredSystemContent(t *testing.T) {
	context := executionContext([]Message{{
		Role: RoleSystem,
		Parts: []ContentPart{
			{Type: PartText, Text: "first"},
			{Type: PartThinking, Thinking: "second"},
			{Type: PartImage, Data: "aGk=", MimeType: "image/png"},
		},
	}}, nil)

	// Images carry no prompt text and are dropped from the system prompt.
	if got := context["system_prompt"]; got != "first\nsecond" {
		t.Errorf("system_prompt = %q", got)
	}
}

func TestExecutionContextOmitsToolsWhenUnset(t *testing.T) {
	context := executionContext([]Message{UserMessage("hi")}, nil)
	if _, present := context["tools"]; present {
		t.Error("tools should be omitted when the request has none")
	}
	withTools := executionContext([]Message{UserMessage("hi")}, []Tool{{Name: "t"}})
	if _, present := withTools["tools"]; !present {
		t.Error("tools should be present when the request has some")
	}
}

func TestSerializeOptionsOmitsUnsetFields(t *testing.T) {
	if got := serializeOptions(nil); len(got) != 0 {
		t.Errorf("serializeOptions(nil) = %v", got)
	}
	if got := serializeOptions(&RunOptions{}); len(got) != 0 {
		t.Errorf("an empty RunOptions should serialize to nothing, got %v", got)
	}
	// A zero temperature is meaningful and must survive.
	got := serializeOptions(&RunOptions{Temperature: Temperature(0), MaxTokens: MaxTokens(0)})
	if got["temperature"] != 0.0 {
		t.Errorf("temperature = %v, want 0", got["temperature"])
	}
	if got["max_tokens"] != 0 {
		t.Errorf("max_tokens = %v, want 0", got["max_tokens"])
	}
}

func TestParseContentHandlesBothShapes(t *testing.T) {
	text, parts := parseContent("plain string")
	if text != "plain string" || parts != nil {
		t.Errorf("string content = (%q, %v)", text, parts)
	}

	var decoded any
	if err := json.Unmarshal([]byte(`[
		{"type":"text","text":"one "},
		{"type":"thinking","thinking":"pondering","thinking_signature":"sig"},
		{"type":"tool_call","id":"call-1","name":"lookup","arguments_json":"{}"},
		{"type":"text","text":"two"}
	]`), &decoded); err != nil {
		t.Fatal(err)
	}
	text, parts = parseContent(decoded)
	if text != "one two" {
		t.Errorf("concatenated text = %q", text)
	}
	if len(parts) != 4 {
		t.Fatalf("got %d parts, want 4", len(parts))
	}
	if parts[1].ThinkingSignature != "sig" {
		t.Errorf("thinking signature = %q", parts[1].ThinkingSignature)
	}
	// A tool call may name its id "id" rather than "tool_call_id".
	if parts[2].ToolCallID != "call-1" || parts[2].Name != "lookup" {
		t.Errorf("tool call part = %+v", parts[2])
	}
}

func TestParseContentNormalizesStringToolResults(t *testing.T) {
	var decoded any
	if err := json.Unmarshal([]byte(`[{"type":"tool_result","tool_call_id":"c","tool_name":"t","content":"sunny"}]`), &decoded); err != nil {
		t.Fatal(err)
	}
	_, parts := parseContent(decoded)
	if len(parts) != 1 {
		t.Fatalf("got %d parts, want 1", len(parts))
	}
	// A string tool_result becomes a single text part, matching the
	// structured field's type.
	if len(parts[0].Content) != 1 || parts[0].Content[0].Text != "sunny" {
		t.Errorf("tool result content = %+v", parts[0].Content)
	}
}

func TestParseCompletionResponseHandlesNestedAndFlatShapes(t *testing.T) {
	flat := jsonObject{
		"role": "assistant", "content": "hi",
		"provider_id": "anthropic", "api": "anthropic-messages", "model_id": "m",
		"stop_reason": "end_turn",
		"usage":       map[string]any{"input": float64(1), "output": float64(2)},
	}
	response := parseCompletionResponse(flat)
	if response.Message.Text != "hi" || response.ProviderID != "anthropic" {
		t.Errorf("flat response = %+v", response)
	}
	if response.Usage == nil || response.Usage.Output != 2 {
		t.Errorf("flat usage = %+v", response.Usage)
	}

	nested := jsonObject{
		"message": map[string]any{"role": "assistant", "content": "hi", "model": "m"},
		"usage":   map[string]any{"input_tokens": float64(3), "output_tokens": float64(4)},
		"reason":  "max_tokens",
	}
	response = parseCompletionResponse(nested)
	if response.Message.Text != "hi" || response.ModelID != "m" {
		t.Errorf("nested response = %+v", response)
	}
	// "reason" and the *_tokens spellings are both accepted.
	if response.StopReason != "max_tokens" {
		t.Errorf("StopReason = %q", response.StopReason)
	}
	if response.Usage == nil || response.Usage.Input != 3 {
		t.Errorf("nested usage = %+v", response.Usage)
	}
}

func TestParseAgentRunResponsePicksTheLastAssistantMessage(t *testing.T) {
	data := jsonObject{
		"messages": []any{
			map[string]any{"role": "user", "content": "hi"},
			map[string]any{"role": "assistant", "content": "first"},
			map[string]any{"role": "user", "content": "more"},
			map[string]any{"role": "assistant", "content": "final", "provider_id": "anthropic"},
		},
		"result": map[string]any{"stop_reason": "end_turn", "usage": map[string]any{"input": float64(5), "output": float64(6)}},
	}
	response := parseAgentRunResponse(data)
	if response.Message.Text != "final" {
		t.Errorf("Text = %q, want final", response.Message.Text)
	}
	if response.StopReason != "end_turn" {
		t.Errorf("StopReason = %q", response.StopReason)
	}
	if response.Usage == nil || response.Usage.Input != 5 {
		t.Errorf("Usage = %+v", response.Usage)
	}
}

func TestBuildResponseFromEventsUsesTheFinalMessage(t *testing.T) {
	events := []AgentEvent{
		&AgentStart{SessionID: "s"},
		&MessageStart{ProviderID: "anthropic", API: "anthropic-messages", ModelID: "m"},
		&TextDelta{Delta: "first turn"},
		&MessageEnd{Usage: &Usage{Input: 1, Output: 2}},
		&MessageStart{ProviderID: "anthropic", API: "anthropic-messages", ModelID: "m"},
		&TextDelta{Delta: "second "},
		&TextDelta{Delta: "turn"},
		&MessageEnd{Usage: &Usage{Input: 3, Output: 4}, StopReason: "end_turn"},
		&AgentEnd{StopReason: "end_turn", Usage: &Usage{Input: 4, Output: 6}},
	}
	response := buildResponseFromEvents(events)

	// Only the final assistant message becomes the response content.
	if response.Message.Text != "second turn" {
		t.Errorf("Text = %q", response.Message.Text)
	}
	if response.Message.Parts != nil {
		t.Errorf("plain text should not produce parts, got %v", response.Message.Parts)
	}
	if response.StopReason != "end_turn" {
		t.Errorf("StopReason = %q", response.StopReason)
	}
	if response.Usage == nil || response.Usage.Input != 4 || response.Usage.Output != 6 {
		t.Errorf("Usage = %+v", response.Usage)
	}
	if response.ProviderID != "anthropic" || response.ModelID != "m" {
		t.Errorf("identity = %q/%q", response.ProviderID, response.ModelID)
	}
}

func TestBuildResponseFromEventsKeepsStructuredContent(t *testing.T) {
	events := []AgentEvent{
		&MessageStart{},
		&TextDelta{Delta: "thinking about it"},
		&ThinkingDelta{Delta: "reasoning"},
		&ToolCallEvent{ToolCallID: "call-1", Name: "lookup", ArgumentsJSON: "{}"},
		&TextDelta{Delta: " done"},
		&AgentEnd{StopReason: "tool_use"},
	}
	response := buildResponseFromEvents(events)

	if len(response.Message.Parts) != 4 {
		t.Fatalf("got %d parts, want 4: %+v", len(response.Message.Parts), response.Message.Parts)
	}
	kinds := make([]string, 0, 4)
	for _, part := range response.Message.Parts {
		kinds = append(kinds, string(part.Type))
	}
	want := "text,thinking,tool_call,text"
	if got := strings.Join(kinds, ","); got != want {
		t.Errorf("part kinds = %s, want %s", got, want)
	}
	// Text is still available as a flat string alongside the parts.
	if response.Message.Text != "thinking about it done" {
		t.Errorf("Text = %q", response.Message.Text)
	}
}

func TestUsageAddHandlesNils(t *testing.T) {
	var nilUsage *Usage
	if got := nilUsage.add(nil); got != nil {
		t.Errorf("nil.add(nil) = %+v, want nil", got)
	}
	if got := nilUsage.add(&Usage{Input: 1}); got == nil || got.Input != 1 {
		t.Errorf("nil.add(x) = %+v", got)
	}
	base := &Usage{Input: 1, Output: 2, CacheRead: 3}
	if got := base.add(nil); got != base {
		t.Errorf("x.add(nil) should return x unchanged")
	}
	sum := base.add(&Usage{Input: 10, Output: 20, CacheWrite: 5})
	if sum.Input != 11 || sum.Output != 22 || sum.CacheRead != 3 || sum.CacheWrite != 5 {
		t.Errorf("sum = %+v", sum)
	}
	// Adding must not mutate either operand.
	if base.Input != 1 {
		t.Errorf("add mutated the receiver: %+v", base)
	}
}

func TestBuildResponseFromEventsAggregatesUsageAcrossTurns(t *testing.T) {
	events := []AgentEvent{
		&MessageStart{ProviderID: "anthropic", API: "anthropic-messages", ModelID: "m"},
		&TextDelta{Delta: "first"},
		&MessageEnd{Usage: &Usage{Input: 10, Output: 4, CacheRead: 1}},
		&MessageStart{ProviderID: "anthropic", API: "anthropic-messages", ModelID: "m"},
		&TextDelta{Delta: "second"},
		&MessageEnd{Usage: &Usage{Input: 20, Output: 6, CacheWrite: 2}},
		&AgentEnd{StopReason: "end_turn", Usage: &Usage{Input: 20, Output: 6, CacheWrite: 2}},
	}

	response := buildResponseFromEvents(events)

	if response.Message.Text != "second" {
		t.Errorf("Text = %q, want second", response.Message.Text)
	}
	if response.Usage == nil {
		t.Fatal("Usage should be aggregated, got nil")
	}
	want := Usage{Input: 30, Output: 10, CacheRead: 1, CacheWrite: 2}
	if *response.Usage != want {
		t.Errorf("Usage = %+v, want %+v", *response.Usage, want)
	}
}

func TestBuildResponseFromEventsFallsBackToTheAgentEndUsage(t *testing.T) {
	events := []AgentEvent{
		&MessageStart{ModelID: "m"},
		&TextDelta{Delta: "only"},
		&AgentEnd{StopReason: "end_turn", Usage: &Usage{Input: 7, Output: 3}},
	}

	response := buildResponseFromEvents(events)

	if response.Usage == nil {
		t.Fatal("Usage should come from agent_end when no message_end carried one")
	}
	if want := (Usage{Input: 7, Output: 3}); *response.Usage != want {
		t.Errorf("Usage = %+v, want %+v", *response.Usage, want)
	}
}

package makai

import (
	"encoding/json"
	"net/url"
	"strings"
)

// Request field limits. They match the TypeScript SDK so both SDKs reject the
// same oversized inputs locally instead of round-tripping them.
const (
	maxModelRefLength     = 4096
	maxIdentifierLength   = 256
	maxModelFieldLength   = 512
	maxProviderIDLength   = 256
	maxModelIDLength      = 256
	maxOpaqueRefLength    = maxModelFieldLength
	systemPromptSeparator = "\n\n"
)

// validateExecutionRequest checks a provider or agent request before it goes
// on the wire.
func validateExecutionRequest(modelRef string, messages []Message) error {
	if modelRef == "" {
		return &ProtocolError{Code: CodeInvalidRequest, Message: "request requires an opaque model_ref"}
	}
	if len(modelRef) > maxModelRefLength {
		return &ProtocolError{
			Code:    CodeInvalidRequest,
			Message: "model_ref exceeds the maximum length of 4096 characters",
		}
	}
	if messages == nil {
		return &ProtocolError{Code: CodeInvalidRequest, Message: "request requires messages"}
	}
	parsed, ok := parseModelRef(modelRef)
	if !ok {
		parsed, ok = splitModelRefLoosely(modelRef)
	}
	if !ok {
		if len(modelRef) > maxOpaqueRefLength {
			return &ProtocolError{
				Code:    CodeInvalidRequest,
				Message: "model_ref exceeds the maximum length of 512 characters for opaque refs",
			}
		}
		return nil
	}
	switch {
	case len(parsed.providerID) > maxIdentifierLength:
		return &ProtocolError{Code: CodeInvalidRequest, Message: "model_ref provider segment exceeds the maximum length of 256 characters"}
	case len(parsed.api) > maxIdentifierLength:
		return &ProtocolError{Code: CodeInvalidRequest, Message: "model_ref api segment exceeds the maximum length of 256 characters"}
	case len(parsed.modelID) > maxModelFieldLength:
		return &ProtocolError{Code: CodeInvalidRequest, Message: "model_ref model_id segment exceeds the maximum length of 512 characters"}
	}
	return nil
}

// buildExecutionPayload builds the payload for a direct provider request.
//
// The V1 provider protocol still carries an execution-plane model object
// rather than the discovery-plane ref, so the SDK decomposes model_ref here.
// That decomposition is an SDK-internal protocol detail: application code
// still treats model_ref as opaque, and the agent path passes it through
// untouched.
func buildExecutionPayload(modelRef string, messages []Message, tools []Tool, options *RunOptions, suppressPartial bool) map[string]any {
	payload := map[string]any{
		"model":     modelFromRef(modelRef),
		"context":   executionContext(messages, tools),
		"model_ref": modelRef,
	}
	if serialized := serializeOptions(options); len(serialized) > 0 {
		payload["options"] = serialized
	}
	if suppressPartial {
		payload["include_partial"] = false
	}
	return payload
}

func executionContext(messages []Message, tools []Tool) map[string]any {
	serialized := make([]map[string]any, 0, len(messages))
	var systemPrompts []string
	for _, message := range messages {
		if message.Role == RoleSystem || message.Role == RoleDeveloper {
			if text := messagePromptText(message); text != "" {
				systemPrompts = append(systemPrompts, text)
			}
			continue
		}
		serialized = append(serialized, serializeMessage(message))
	}

	context := map[string]any{"messages": serialized}
	if len(systemPrompts) > 0 {
		context["system_prompt"] = strings.Join(systemPrompts, systemPromptSeparator)
	}
	if tools != nil {
		context["tools"] = serializeTools(tools)
	}
	return context
}

func serializeMessage(message Message) map[string]any {
	out := map[string]any{"role": string(message.Role)}
	if message.Role == RoleTool {
		// Tool results always travel as structured parts.
		out["content"] = messageParts(message)
		out["tool_name"] = message.Name
	} else if len(message.Parts) > 0 {
		out["content"] = message.Parts
	} else {
		out["content"] = message.Text
	}
	if message.Name != "" {
		out["name"] = message.Name
	}
	if message.ToolCallID != "" {
		out["tool_call_id"] = message.ToolCallID
	}
	return out
}

func messageParts(message Message) []ContentPart {
	if len(message.Parts) > 0 {
		return message.Parts
	}
	return []ContentPart{{Type: PartText, Text: message.Text}}
}

func messagePromptText(message Message) string {
	if len(message.Parts) == 0 {
		return message.Text
	}
	var texts []string
	for _, part := range message.Parts {
		if text := contentPartText(part); text != "" {
			texts = append(texts, text)
		}
	}
	return strings.Join(texts, "\n")
}

func contentPartText(part ContentPart) string {
	switch part.Type {
	case PartText:
		return part.Text
	case PartThinking:
		return part.Thinking
	case PartToolResult:
		var texts []string
		for _, nested := range part.Content {
			if text := contentPartText(nested); text != "" {
				texts = append(texts, text)
			}
		}
		return strings.Join(texts, "\n")
	default:
		return ""
	}
}

func serializeTools(tools []Tool) []map[string]any {
	out := make([]map[string]any, 0, len(tools))
	for _, tool := range tools {
		out = append(out, map[string]any{
			"name":                   tool.Name,
			"description":            tool.Description,
			"parameters_schema_json": tool.ParametersSchemaJSON,
		})
	}
	return out
}

func serializeOptions(options *RunOptions) map[string]any {
	out := map[string]any{}
	if options == nil {
		return out
	}
	if options.Temperature != nil {
		out["temperature"] = *options.Temperature
	}
	if options.MaxTokens != nil {
		out["max_tokens"] = *options.MaxTokens
	}
	if options.ReasoningEffort != "" {
		out["reasoning_effort"] = string(options.ReasoningEffort)
	}
	if options.SessionID != "" {
		out["session_id"] = options.SessionID
	}
	if len(options.Metadata) > 0 {
		out["metadata"] = options.Metadata
	}
	return out
}

type parsedModelRef struct {
	providerID string
	api        string
	modelID    string
}

// parseModelRef decomposes the runtime's canonical
// provider_id/api@percent-encoded-model-id form. It is SDK-internal: callers
// must treat a model ref as opaque.
func parseModelRef(modelRef string) (parsedModelRef, bool) {
	slash := strings.Index(modelRef, "/")
	if slash <= 0 {
		return parsedModelRef{}, false
	}
	if at := strings.Index(modelRef, "@"); at != -1 && at < slash {
		return parsedModelRef{}, false
	}
	rest := modelRef[slash+1:]
	atOffset := strings.Index(rest, "@")
	if atOffset == -1 {
		return parsedModelRef{}, false
	}
	api := rest[:atOffset]
	encodedID := rest[atOffset+1:]
	providerID := modelRef[:slash]

	if api == "" || encodedID == "" {
		return parsedModelRef{}, false
	}
	if strings.ContainsAny(api, "/@%") || strings.ContainsAny(providerID, "/@%") {
		return parsedModelRef{}, false
	}
	if !isCanonicallyEncoded(encodedID) {
		return parsedModelRef{}, false
	}
	modelID, err := url.PathUnescape(encodedID)
	if err != nil {
		return parsedModelRef{}, false
	}
	return parsedModelRef{providerID: providerID, api: api, modelID: modelID}, true
}

// isCanonicallyEncoded reports whether a model id segment is percent-encoded
// the way the runtime's formatModelRef writes it: every byte outside the
// unreserved set escaped. A raw ':' is therefore not canonical, which is what
// keeps "ollama/ollama@gemma4:31b" from being mistaken for a canonical ref.
func isCanonicallyEncoded(segment string) bool {
	for i := 0; i < len(segment); i++ {
		char := segment[i]
		if char == '%' {
			if i+2 >= len(segment) || !isHexDigit(segment[i+1]) || !isHexDigit(segment[i+2]) {
				return false
			}
			i += 2
			continue
		}
		if !isUnreserved(char) {
			return false
		}
	}
	return true
}

func isHexDigit(char byte) bool {
	return (char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')
}

func isUnreserved(char byte) bool {
	switch {
	case char >= 'A' && char <= 'Z', char >= 'a' && char <= 'z', char >= '0' && char <= '9':
		return true
	case char == '-' || char == '.' || char == '_' || char == '~':
		return true
	default:
		return false
	}
}

// splitModelRefLoosely accepts a ref that is shaped like the canonical form
// but is not canonically encoded, matching the TypeScript SDK's fallback so
// both SDKs accept the same hand-written refs.
func splitModelRefLoosely(modelRef string) (parsedModelRef, bool) {
	slash := strings.Index(modelRef, "/")
	at := strings.Index(modelRef, "@")
	if slash == -1 || at == -1 || slash >= at {
		return parsedModelRef{}, false
	}
	providerID := modelRef[:slash]
	api := modelRef[slash+1 : at]
	if providerID == "" || api == "" {
		return parsedModelRef{}, false
	}
	return parsedModelRef{providerID: providerID, api: api, modelID: modelRef[at+1:]}, true
}

// providerIDFromRef derives a provider id for error attribution when the
// runtime did not name one. It returns "" for refs it cannot decompose.
func providerIDFromRef(modelRef string) string {
	if parsed, ok := parseModelRef(modelRef); ok {
		return parsed.providerID
	}
	if parsed, ok := splitModelRefLoosely(modelRef); ok {
		return parsed.providerID
	}
	return ""
}

func modelFromRef(modelRef string) map[string]any {
	parsed, ok := parseModelRef(modelRef)
	if !ok {
		parsed, ok = splitModelRefLoosely(modelRef)
	}
	if !ok {
		return map[string]any{"id": modelRef, "name": modelRef, "api": "", "provider": "", "base_url": ""}
	}
	return map[string]any{
		"id":       parsed.modelID,
		"name":     parsed.modelID,
		"api":      parsed.api,
		"provider": parsed.providerID,
		"base_url": "",
	}
}

// parseCompletionResponse reads a provider result payload, tolerating both
// the nested {"message": {...}} shape and the flattened one.
func parseCompletionResponse(data jsonObject) *CompletionResponse {
	if data == nil {
		data = jsonObject{}
	}
	message := data.obj("message")
	if message == nil {
		message = data
	}
	return buildResponseFrom(message, data)
}

// parseAgentRunResponse reads an agent result payload, which may carry a
// message, a message list, or a flattened terminal result.
func parseAgentRunResponse(data jsonObject) *CompletionResponse {
	if data == nil {
		data = jsonObject{}
	}
	if data.obj("message") != nil {
		return parseCompletionResponse(data)
	}
	terminal := data.obj("result")
	if terminal == nil {
		terminal = data
	}
	assistant := lastAssistantMessage(data.arr("messages"))
	if assistant == nil {
		assistant = data
	}
	return buildResponseFrom(assistant, terminal)
}

func lastAssistantMessage(messages []any) jsonObject {
	for i := len(messages) - 1; i >= 0; i-- {
		entry, ok := messages[i].(map[string]any)
		if !ok {
			continue
		}
		if obj := jsonObject(entry); obj.str("role") == string(RoleAssistant) {
			return obj
		}
	}
	return nil
}

func buildResponseFrom(message, terminal jsonObject) *CompletionResponse {
	text, parts := parseContent(message["content"])
	usage := usageFrom(message.obj("usage"))
	if usage == nil {
		usage = usageFrom(terminal.obj("usage"))
	}
	if usage == nil {
		usage = usageFrom(terminal)
	}
	return &CompletionResponse{
		Message:      ResponseMessage{Role: RoleAssistant, Text: text, Parts: parts},
		Usage:        usage,
		ProviderID:   firstNonEmpty(message.str("provider_id", "provider"), terminal.str("provider_id", "provider")),
		API:          firstNonEmpty(message.str("api"), terminal.str("api")),
		ModelID:      firstNonEmpty(message.str("model_id", "model"), terminal.str("model_id", "model")),
		StopReason:   firstNonEmpty(message.str("stop_reason"), terminal.str("stop_reason", "reason")),
		ErrorMessage: firstNonEmpty(message.str("error_message"), terminal.str("error_message")),
	}
}

// parseContent reads message content, which is either a plain string or a
// list of content parts. It always returns the message's text, and returns
// parts only when the provider sent structured content.
func parseContent(raw any) (string, []ContentPart) {
	switch value := raw.(type) {
	case string:
		return value, nil
	case []any:
		parts := make([]ContentPart, 0, len(value))
		var text strings.Builder
		for _, entry := range value {
			part := parseContentPart(entry)
			parts = append(parts, part)
			if part.Type == PartText {
				text.WriteString(part.Text)
			}
		}
		return text.String(), parts
	default:
		return "", nil
	}
}

func parseContentPart(raw any) ContentPart {
	entry, ok := raw.(map[string]any)
	if !ok {
		return ContentPart{Type: PartText}
	}
	obj := jsonObject(entry)
	if obj.str("type") == string(PartToolCall) {
		return ContentPart{
			Type:          PartToolCall,
			ToolCallID:    obj.str("tool_call_id", "id"),
			Name:          obj.str("name"),
			ArgumentsJSON: obj.str("arguments_json"),
		}
	}
	// tool_result content is a string or a part list on the wire; normalize
	// the string form so it decodes into the structured field.
	if obj.str("type") == string(PartToolResult) {
		if text, isString := entry["content"].(string); isString {
			entry["content"] = []any{map[string]any{"type": "text", "text": text}}
		}
	}
	encoded, err := json.Marshal(entry)
	if err != nil {
		return ContentPart{Type: ContentPartType(obj.str("type"))}
	}
	var part ContentPart
	if err := json.Unmarshal(encoded, &part); err != nil {
		return ContentPart{Type: ContentPartType(obj.str("type")), Text: obj.str("text")}
	}
	return part
}

// buildResponseFromEvents assembles a run response from the agent stream's
// events, for runtimes that settle a run through events rather than a result
// frame.
func buildResponseFromEvents(events []AgentEvent) *CompletionResponse {
	response := &CompletionResponse{Message: ResponseMessage{Role: RoleAssistant}}

	// The response reflects the run's final assistant message, so restart
	// the content accumulation at the last message_start.
	start := 0
	for i, event := range events {
		if _, ok := event.(*MessageStart); ok {
			start = i
		}
	}

	var text strings.Builder
	var parts []ContentPart
	flushText := func() {
		if text.Len() > 0 {
			parts = append(parts, ContentPart{Type: PartText, Text: text.String()})
			text.Reset()
		}
	}
	for _, event := range events[start:] {
		switch value := event.(type) {
		case *MessageStart:
			response.ProviderID = firstNonEmpty(value.ProviderID, response.ProviderID)
			response.API = firstNonEmpty(value.API, response.API)
			response.ModelID = firstNonEmpty(value.ModelID, response.ModelID)
		case *TextDelta:
			text.WriteString(value.Delta)
		case *ThinkingDelta:
			flushText()
			parts = append(parts, ContentPart{Type: PartThinking, Thinking: value.Delta})
		case *ToolCallEvent:
			flushText()
			parts = append(parts, ContentPart{
				Type:          PartToolCall,
				ToolCallID:    value.ToolCallID,
				Name:          value.Name,
				ArgumentsJSON: value.ArgumentsJSON,
			})
		case *MessageEnd:
			// Reached below when building the terminal fields.
		}
	}

	// Terminal fields come from the last agent_end, falling back to the last
	// message_end of the run.
	//
	// Usage is the exception: the runtime's agent_end reports only the last
	// provider turn, so a multi-turn run is summed from every message_end,
	// which is what AgentStream.Next does for the streamed path.
	var messageEnd *MessageEnd
	var aggregated *Usage
	for _, event := range events {
		if value, ok := event.(*MessageEnd); ok {
			messageEnd = value
			aggregated = aggregated.add(value.Usage)
		}
	}
	for i := len(events) - 1; i >= 0; i-- {
		if value, ok := events[i].(*AgentEnd); ok {
			response.StopReason = value.StopReason
			response.ErrorMessage = value.ErrorMessage
			response.Usage = value.Usage
			response.ProviderID = firstNonEmpty(response.ProviderID, value.ProviderID)
			response.API = firstNonEmpty(response.API, value.API)
			break
		}
	}
	if aggregated != nil {
		response.Usage = aggregated
	}
	if response.Usage == nil && messageEnd != nil {
		response.Usage = messageEnd.Usage
	}
	if response.StopReason == "" && messageEnd != nil {
		response.StopReason = messageEnd.StopReason
	}

	if len(parts) == 0 {
		response.Message.Text = text.String()
		return response
	}
	flushText()
	response.Message.Parts = parts
	var combined strings.Builder
	for _, part := range parts {
		if part.Type == PartText {
			combined.WriteString(part.Text)
		}
	}
	response.Message.Text = combined.String()
	return response
}

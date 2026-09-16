package makai

import "context"

// Role identifies the author of a [Message].
type Role string

// Message roles. System and developer messages are folded into the request's
// system prompt by the runtime rather than appearing in the message list.
const (
	RoleSystem    Role = "system"
	RoleDeveloper Role = "developer"
	RoleUser      Role = "user"
	RoleAssistant Role = "assistant"
	RoleTool      Role = "tool"
)

// ContentPartType discriminates a [ContentPart].
type ContentPartType string

// Content part types.
const (
	PartText       ContentPartType = "text"
	PartThinking   ContentPartType = "thinking"
	PartImage      ContentPartType = "image"
	PartToolCall   ContentPartType = "tool_call"
	PartToolResult ContentPartType = "tool_result"
)

// ContentPart is one piece of structured message content. Which fields carry
// meaning depends on Type; the rest are omitted on the wire.
type ContentPart struct {
	Type ContentPartType `json:"type"`

	// Text and TextSignature apply to PartText.
	Text          string `json:"text,omitempty"`
	TextSignature string `json:"text_signature,omitempty"`

	// Thinking and ThinkingSignature apply to PartThinking. The signature
	// is provider-issued and must be replayed verbatim when the same
	// reasoning is sent back.
	Thinking          string `json:"thinking,omitempty"`
	ThinkingSignature string `json:"thinking_signature,omitempty"`

	// Data and MimeType apply to PartImage. Data is base64-encoded.
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mime_type,omitempty"`

	// ToolCallID, Name and ArgumentsJSON apply to PartToolCall.
	ToolCallID    string `json:"tool_call_id,omitempty"`
	Name          string `json:"name,omitempty"`
	ArgumentsJSON string `json:"arguments_json,omitempty"`

	// ToolName, Content, IsError and DetailsJSON apply to PartToolResult.
	ToolName    string        `json:"tool_name,omitempty"`
	Content     []ContentPart `json:"content,omitempty"`
	IsError     bool          `json:"is_error,omitempty"`
	DetailsJSON string        `json:"details_json,omitempty"`
}

// Message is one turn of conversation input.
//
// Use Text for plain text, or Parts for structured content. Parts takes
// precedence when both are set.
type Message struct {
	Role  Role
	Text  string
	Parts []ContentPart

	// Name identifies the speaker, and for RoleTool names the tool that
	// produced the result.
	Name string
	// ToolCallID links a RoleTool message to the call it answers.
	ToolCallID string
}

// UserMessage builds a plain-text user message.
func UserMessage(text string) Message { return Message{Role: RoleUser, Text: text} }

// SystemMessage builds a plain-text system message. The runtime folds system
// and developer messages into the request's system prompt.
func SystemMessage(text string) Message { return Message{Role: RoleSystem, Text: text} }

// AssistantMessage builds a plain-text assistant message, for replaying prior
// turns back to the model.
func AssistantMessage(text string) Message { return Message{Role: RoleAssistant, Text: text} }

// ToolMessage builds a tool-result message answering a specific tool call.
// Use it on the provider path, where the caller drives the tool loop; the
// agent path answers tool calls through [Tool].Execute instead.
func ToolMessage(toolCallID, toolName, result string) Message {
	return Message{Role: RoleTool, Name: toolName, ToolCallID: toolCallID, Text: result}
}

// ToolInvocation describes one tool call the agent loop asked the client to
// run.
type ToolInvocation struct {
	// ToolCallID correlates this invocation with the model's tool call and
	// with the tool_execution events on the stream.
	ToolCallID string
	// ToolName is the name of the tool the model asked for.
	ToolName string
	// ArgumentsJSON is the model's arguments, as a JSON document. It is not
	// validated against the tool's schema by the SDK.
	ArgumentsJSON string
}

// ToolFunc runs one tool invocation and returns its textual result.
//
// A returned error is reported to the model as a failed tool result rather
// than aborting the run, so a tool can surface a recoverable problem by
// returning an error and let the model react to it. The context is the one
// passed to [AgentService.Run] or [AgentService.Stream].
type ToolFunc func(ctx context.Context, call ToolInvocation) (string, error)

// Tool is a tool definition offered to the model.
type Tool struct {
	// Name is the identifier the model calls.
	Name string
	// Description tells the model what the tool does.
	Description string
	// ParametersSchemaJSON is the tool's JSON Schema, as a JSON document.
	ParametersSchemaJSON string
	// Execute runs the tool. On the agent path a tool with no Execute is
	// reported to the model as not executable by this client. It is unused
	// on the provider path, where tool calls are returned to the caller.
	Execute ToolFunc
}

// ReasoningLevel selects how much reasoning effort a model should spend.
type ReasoningLevel string

// Reasoning levels.
const (
	ReasoningOff     ReasoningLevel = "off"
	ReasoningMinimal ReasoningLevel = "minimal"
	ReasoningLow     ReasoningLevel = "low"
	ReasoningMedium  ReasoningLevel = "medium"
	ReasoningHigh    ReasoningLevel = "high"
	ReasoningXHigh   ReasoningLevel = "xhigh"
)

// RunOptions tunes one provider or agent call. All fields are optional.
type RunOptions struct {
	// Temperature overrides the model's sampling temperature.
	Temperature *float64
	// MaxTokens caps the response length.
	MaxTokens *int
	// ReasoningEffort selects a reasoning level on models that support one.
	ReasoningEffort ReasoningLevel
	// Metadata is passed through to the runtime.
	Metadata map[string]string

	// SessionID sets the correlation key for an agent run's session. It must
	// be a 21-character alphanumeric NanoID. Leave it empty to have the SDK
	// generate one.
	//
	// It is not a resume handle: sessions are not resumable, and reusing the
	// id of a live run is rejected with [CodeAgentBusy]. Supplying an id only
	// makes the run's frames easier to correlate with runtime logs.
	SessionID string
}

// Temperature returns a pointer to t, for [RunOptions].Temperature.
func Temperature(t float64) *float64 { return &t }

// MaxTokens returns a pointer to n, for [RunOptions].MaxTokens.
func MaxTokens(n int) *int { return &n }

// Usage reports token consumption. Cache counts are totals across a run, not
// counts of unique cached content.
type Usage struct {
	Input      int64 `json:"input"`
	Output     int64 `json:"output"`
	CacheRead  int64 `json:"cache_read,omitempty"`
	CacheWrite int64 `json:"cache_write,omitempty"`
}

func (u *Usage) add(other *Usage) *Usage {
	if other == nil {
		return u
	}
	if u == nil {
		clone := *other
		return &clone
	}
	return &Usage{
		Input:      u.Input + other.Input,
		Output:     u.Output + other.Output,
		CacheRead:  u.CacheRead + other.CacheRead,
		CacheWrite: u.CacheWrite + other.CacheWrite,
	}
}

// ResponseMessage is the assistant message a completed call produced.
type ResponseMessage struct {
	// Role is always RoleAssistant.
	Role Role
	// Text is the message's text: the plain string the provider returned,
	// or the concatenation of its text parts.
	Text string
	// Parts is the structured content when the provider returned parts, and
	// nil when it returned a plain string.
	Parts []ContentPart
}

// CompletionResponse is the result of a completed provider or agent call.
type CompletionResponse struct {
	// Message is the assistant's reply.
	Message ResponseMessage
	// Usage is the call's token usage, or nil when the provider reported
	// none. An agent run that settles through events sums every provider
	// turn, matching AgentStream; one that settles through a result frame
	// reports whatever that frame carried.
	Usage *Usage
	// ProviderID, API and ModelID identify what actually served the call.
	ProviderID string
	API        string
	ModelID    string
	// StopReason is why generation stopped, for example "end_turn",
	// "max_tokens", "tool_use" or the agent-level "max_turns".
	StopReason string
	// ErrorMessage carries provider error detail on a failed turn that still
	// settled through the normal result path.
	ErrorMessage string
}

// CompletionRequest is a direct provider call. It bypasses the agent loop:
// tool calls come back to the caller as content rather than being executed.
type CompletionRequest struct {
	// ModelRef is an opaque model handle from the models namespace.
	ModelRef string
	// Messages is the conversation to send.
	Messages []Message
	// Tools are the tool definitions offered to the model. Execute is
	// ignored here; the model's tool calls are returned to the caller.
	Tools []Tool
	// Options tunes the call.
	Options *RunOptions
}

// AgentRequest is an agent-loop call. The runtime drives provider turns and
// asks the client to run tools through [Tool].Execute.
type AgentRequest struct {
	// ModelRef is an opaque model handle from the models namespace.
	ModelRef string
	// Messages is the conversation to send.
	Messages []Message
	// Tools are the tools the agent may call. A tool the model calls but
	// that has no Execute is reported back as not executable.
	Tools []Tool
	// Options tunes the run.
	Options *RunOptions
}

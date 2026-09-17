package makai

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// AuthStatus reports whether a provider's credentials are usable.
type AuthStatus string

// Auth statuses.
const (
	AuthAuthenticated   AuthStatus = "authenticated"
	AuthLoginRequired   AuthStatus = "login_required"
	AuthExpired         AuthStatus = "expired"
	AuthRefreshing      AuthStatus = "refreshing"
	AuthLoginInProgress AuthStatus = "login_in_progress"
	AuthFailed          AuthStatus = "failed"
	AuthUnknown         AuthStatus = "unknown"
)

// ModelLifecycle reports how settled a model is.
type ModelLifecycle string

// Model lifecycles.
const (
	LifecycleStable     ModelLifecycle = "stable"
	LifecyclePreview    ModelLifecycle = "preview"
	LifecycleDeprecated ModelLifecycle = "deprecated"
)

// ModelCapability is one capability a model supports.
type ModelCapability string

// Model capabilities.
const (
	CapabilityChat        ModelCapability = "chat"
	CapabilityStreaming   ModelCapability = "streaming"
	CapabilityTools       ModelCapability = "tools"
	CapabilityVision      ModelCapability = "vision"
	CapabilityReasoning   ModelCapability = "reasoning"
	CapabilityPromptCache ModelCapability = "prompt_cache"
	CapabilityAudioInput  ModelCapability = "audio_input"
	CapabilityAudioOutput ModelCapability = "audio_output"
)

// ModelSource reports whether a descriptor came from a live provider listing
// or from the runtime's static catalog.
type ModelSource string

// Model sources.
const (
	SourceDynamic        ModelSource = "dynamic"
	SourceStaticFallback ModelSource = "static_fallback"
)

// ModelDescriptor is the discovery-plane metadata for one model.
type ModelDescriptor struct {
	// ModelRef is the opaque handle to pass to provider and agent calls.
	// Do not parse it or construct it.
	ModelRef string
	// ModelID is the provider's own model identifier, preserved verbatim.
	ModelID string
	// DisplayName is a human-readable name.
	DisplayName string
	// ProviderID and API identify the provider and wire format serving it.
	ProviderID string
	API        string
	// BaseURL is the endpoint the runtime will call, when it reported one.
	BaseURL string
	// AuthStatus is the provider's credential state for this model.
	AuthStatus AuthStatus
	// Lifecycle reports whether the model is stable, preview or deprecated.
	Lifecycle ModelLifecycle
	// Capabilities lists what the model supports.
	Capabilities []ModelCapability
	// Source reports whether the descriptor is dynamic or a static fallback.
	Source ModelSource
	// ContextWindow and MaxOutputTokens are token limits, or 0 when the
	// runtime reported none.
	ContextWindow   int
	MaxOutputTokens int
	// ReasoningDefault is the model's default reasoning level, or "".
	ReasoningDefault ReasoningLevel
	// Metadata is provider-specific detail, or nil.
	Metadata map[string]string
}

// ListModelsRequest filters a model listing. Every field is optional; the
// zero value lists everything the runtime knows about.
type ListModelsRequest struct {
	// ProviderID limits the listing to one provider.
	ProviderID string
	// API limits the listing to one wire format.
	API string
	// ModelID is an exact-match filter applied by the runtime.
	ModelID string
	// IncludeDeprecated includes deprecated models. The runtime's default
	// is false.
	IncludeDeprecated *bool
	// IncludeLoginRequired includes models whose provider is not logged in.
	// The runtime's default is true.
	IncludeLoginRequired *bool
}

// ListModelsResponse is a model listing plus its cache metadata.
type ListModelsResponse struct {
	// Models is the matching set. It is empty, never nil, when nothing
	// matched.
	Models []ModelDescriptor
	// FetchedAt is when the runtime produced this listing.
	FetchedAt time.Time
	// CacheMaxAge is how long the listing stays fresh.
	CacheMaxAge time.Duration
}

// ResolveModelRequest asks the runtime for exactly one model.
type ResolveModelRequest struct {
	// ProviderID is required.
	ProviderID string
	// API disambiguates when one provider serves the same model id through
	// several wire formats. Omitting it and matching more than one model is
	// an error.
	API string
	// ModelID is required and matched exactly.
	ModelID string
}

// Bool returns a pointer to b, for the optional booleans in
// [ListModelsRequest].
func Bool(b bool) *bool { return &b }

// ModelsService discovers the models a runtime can serve.
type ModelsService struct {
	transport *transport
	timeout   time.Duration
}

// List returns the models matching req.
//
// Failures are [*ProtocolError]: [CodeInvalidRequest] for a request the SDK
// or runtime rejected, [CodeMalformedResponse] for a reply that did not match
// the protocol, or the runtime's own code for a rejection.
func (s *ModelsService) List(ctx context.Context, req ListModelsRequest) (*ListModelsResponse, error) {
	if len(req.ProviderID) > maxProviderIDLength {
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "provider_id exceeds the maximum length of 256 characters"}
	}
	if len(req.ModelID) > maxModelIDLength {
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "model_id exceeds the maximum length of 256 characters"}
	}
	return s.dispatch(ctx, req)
}

// Resolve returns the single model matching req, for turning a provider and
// model id into an opaque [ModelDescriptor].ModelRef.
//
// It is an error for the runtime to match no model or more than one; both
// surface as a [*ProtocolError] with [CodeInvalidRequest].
func (s *ModelsService) Resolve(ctx context.Context, req ResolveModelRequest) (*ModelDescriptor, error) {
	switch {
	case req.ProviderID == "":
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "resolve requires provider_id"}
	case len(req.ProviderID) > maxProviderIDLength:
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "provider_id exceeds the maximum length of 256 characters"}
	case req.ModelID == "":
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "resolve requires model_id"}
	case len(req.ModelID) > maxModelIDLength:
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "model_id exceeds the maximum length of 256 characters"}
	}

	response, err := s.dispatch(ctx, ListModelsRequest{
		ProviderID: req.ProviderID,
		API:        req.API,
		ModelID:    req.ModelID,
	})
	if err != nil {
		return nil, err
	}
	switch {
	case len(response.Models) == 0:
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "model not found"}
	case len(response.Models) > 1:
		return nil, &ProtocolError{
			Code:    CodeInvalidRequest,
			Message: fmt.Sprintf("resolve matched %d models; expected exactly 1", len(response.Models)),
		}
	}

	model := response.Models[0]
	switch {
	case model.ProviderID != req.ProviderID:
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "resolved model provider_id mismatch"}
	case model.ModelID != req.ModelID:
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "resolved model_id mismatch"}
	case req.API != "" && model.API != req.API:
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "resolved model api mismatch"}
	}
	return &model, nil
}

func (s *ModelsService) dispatch(ctx context.Context, req ListModelsRequest) (*ListModelsResponse, error) {
	if err := ctx.Err(); err != nil {
		return nil, &ProtocolError{Code: CodeInvalidRequest, Message: "models request aborted before start", err: err}
	}

	streamID := newULID()
	sub := s.transport.subscribeStream(streamID)
	defer sub.close()

	envelope := newStreamEnvelope("models_request", streamID, modelsRequestPayload(req))
	if err := s.transport.send(envelope); err != nil {
		return nil, protocolErrorFrom(err, streamID)
	}

	for {
		f, err := sub.next(ctx, s.timeout, "models_response")
		if err != nil {
			if isAbort(err) {
				cancelStream(s.transport, streamID)
			}
			return nil, protocolErrorFrom(err, streamID)
		}
		switch f.Type {
		case "ack":
			continue
		case "nack":
			payload := f.payload()
			return nil, &ProtocolError{
				Code:     payload.str("error_code", "code"),
				Message:  payload.strOrDefault("models request rejected", "reason", "message"),
				StreamID: streamID,
			}
		case "models_response":
			return parseModelsResponse(f, streamID)
		default:
			return nil, &ProtocolError{
				Code:     CodeMalformedResponse,
				Message:  fmt.Sprintf("unexpected frame type %q while awaiting models_response", f.Type),
				StreamID: streamID,
			}
		}
	}
}

func modelsRequestPayload(req ListModelsRequest) map[string]any {
	payload := map[string]any{}
	if req.ProviderID != "" {
		payload["provider_id"] = req.ProviderID
	}
	if req.API != "" {
		payload["api"] = req.API
	}
	if req.ModelID != "" {
		payload["model_id"] = req.ModelID
	}
	if req.IncludeDeprecated != nil {
		payload["include_deprecated"] = *req.IncludeDeprecated
	}
	if req.IncludeLoginRequired != nil {
		payload["include_login_required"] = *req.IncludeLoginRequired
	}
	return payload
}

// defaultCacheMaxAge is used when a models_response omits cache_max_age_ms,
// matching the TypeScript SDK's fallback.
const defaultCacheMaxAge = 5 * time.Minute

// wireModelsResponse is the strict decoding of a models_response payload.
// Unlike event payloads, this shape is fixed by the spec, so it is validated
// rather than pattern-matched.
type wireModelsResponse struct {
	Models        []wireModelDescriptor `json:"models"`
	FetchedAtMs   *float64              `json:"fetched_at_ms"`
	CacheMaxAgeMs *float64              `json:"cache_max_age_ms"`
}

type wireModelDescriptor struct {
	ModelRef         string            `json:"model_ref"`
	ModelID          string            `json:"model_id"`
	DisplayName      string            `json:"display_name"`
	ProviderID       string            `json:"provider_id"`
	API              string            `json:"api"`
	BaseURL          string            `json:"base_url"`
	AuthStatus       string            `json:"auth_status"`
	Lifecycle        string            `json:"lifecycle"`
	Capabilities     *[]string         `json:"capabilities"`
	Source           string            `json:"source"`
	ContextWindow    *float64          `json:"context_window"`
	MaxOutputTokens  *float64          `json:"max_output_tokens"`
	ReasoningDefault *string           `json:"reasoning_default"`
	Metadata         map[string]string `json:"metadata"`
}

func parseModelsResponse(f *frame, streamID string) (*ListModelsResponse, error) {
	malformed := func(format string, args ...any) error {
		return &ProtocolError{Code: CodeMalformedResponse, Message: fmt.Sprintf(format, args...), StreamID: streamID}
	}
	if len(f.Payload) == 0 {
		return nil, malformed("models_response is missing its payload object")
	}
	var wire wireModelsResponse
	if err := json.Unmarshal(f.Payload, &wire); err != nil {
		return nil, malformed("models_response payload did not decode: %v", err)
	}
	if wire.Models == nil {
		return nil, malformed("models_response is missing its 'models' array")
	}
	if wire.FetchedAtMs == nil {
		return nil, malformed("models_response is missing a numeric 'fetched_at_ms'")
	}

	cacheMaxAge := defaultCacheMaxAge
	if wire.CacheMaxAgeMs != nil {
		cacheMaxAge = time.Duration(*wire.CacheMaxAgeMs) * time.Millisecond
	}

	models := make([]ModelDescriptor, 0, len(wire.Models))
	for i, raw := range wire.Models {
		model, err := parseModelDescriptor(raw, i, streamID)
		if err != nil {
			return nil, err
		}
		models = append(models, model)
	}
	return &ListModelsResponse{
		Models:      models,
		FetchedAt:   time.UnixMilli(int64(*wire.FetchedAtMs)),
		CacheMaxAge: cacheMaxAge,
	}, nil
}

func parseModelDescriptor(raw wireModelDescriptor, index int, streamID string) (ModelDescriptor, error) {
	malformed := func(format string, args ...any) error {
		return &ProtocolError{Code: CodeMalformedResponse, Message: fmt.Sprintf(format, args...), StreamID: streamID}
	}
	for name, value := range map[string]string{
		"model_ref":    raw.ModelRef,
		"model_id":     raw.ModelID,
		"display_name": raw.DisplayName,
		"provider_id":  raw.ProviderID,
		"api":          raw.API,
	} {
		if value == "" {
			return ModelDescriptor{}, malformed("models[%d].%s must be a non-empty string", index, name)
		}
	}
	if !knownAuthStatuses[AuthStatus(raw.AuthStatus)] {
		return ModelDescriptor{}, malformed("models[%d].auth_status has unknown value: %q", index, raw.AuthStatus)
	}
	if !knownLifecycles[ModelLifecycle(raw.Lifecycle)] {
		return ModelDescriptor{}, malformed("models[%d].lifecycle has unknown value: %q", index, raw.Lifecycle)
	}
	if !knownSources[ModelSource(raw.Source)] {
		return ModelDescriptor{}, malformed("models[%d].source has unknown value: %q", index, raw.Source)
	}
	if raw.Capabilities == nil {
		return ModelDescriptor{}, malformed("models[%d].capabilities must be an array", index)
	}

	capabilities := make([]ModelCapability, 0, len(*raw.Capabilities))
	for i, capability := range *raw.Capabilities {
		if !knownCapabilities[ModelCapability(capability)] {
			return ModelDescriptor{}, malformed("models[%d].capabilities[%d] has unknown value: %q", index, i, capability)
		}
		capabilities = append(capabilities, ModelCapability(capability))
	}

	model := ModelDescriptor{
		ModelRef:     raw.ModelRef,
		ModelID:      raw.ModelID,
		DisplayName:  raw.DisplayName,
		ProviderID:   raw.ProviderID,
		API:          raw.API,
		BaseURL:      raw.BaseURL,
		AuthStatus:   AuthStatus(raw.AuthStatus),
		Lifecycle:    ModelLifecycle(raw.Lifecycle),
		Capabilities: capabilities,
		Source:       ModelSource(raw.Source),
		Metadata:     raw.Metadata,
	}
	if raw.ContextWindow != nil {
		model.ContextWindow = int(*raw.ContextWindow)
	}
	if raw.MaxOutputTokens != nil {
		model.MaxOutputTokens = int(*raw.MaxOutputTokens)
	}
	if raw.ReasoningDefault != nil {
		if !knownReasoningLevels[ReasoningLevel(*raw.ReasoningDefault)] {
			return ModelDescriptor{}, malformed("models[%d].reasoning_default has unknown value: %q", index, *raw.ReasoningDefault)
		}
		model.ReasoningDefault = ReasoningLevel(*raw.ReasoningDefault)
	}
	return model, nil
}

var (
	knownAuthStatuses = map[AuthStatus]bool{
		AuthAuthenticated: true, AuthLoginRequired: true, AuthExpired: true,
		AuthRefreshing: true, AuthLoginInProgress: true, AuthFailed: true, AuthUnknown: true,
	}
	knownLifecycles = map[ModelLifecycle]bool{
		LifecycleStable: true, LifecyclePreview: true, LifecycleDeprecated: true,
	}
	knownSources = map[ModelSource]bool{
		SourceDynamic: true, SourceStaticFallback: true,
	}
	knownCapabilities = map[ModelCapability]bool{
		CapabilityChat: true, CapabilityStreaming: true, CapabilityTools: true,
		CapabilityVision: true, CapabilityReasoning: true, CapabilityPromptCache: true,
		CapabilityAudioInput: true, CapabilityAudioOutput: true,
	}
	knownReasoningLevels = map[ReasoningLevel]bool{
		ReasoningOff: true, ReasoningMinimal: true, ReasoningLow: true,
		ReasoningMedium: true, ReasoningHigh: true, ReasoningXHigh: true,
	}
)

// protocolErrorFrom converts a transport-layer failure into the model
// namespace's error type, preserving the cause for errors.Is.
func protocolErrorFrom(err error, streamID string) error {
	var streamErr *StreamError
	if asStreamError(err, &streamErr) {
		return &ProtocolError{Message: streamErr.Message, StreamID: streamID, err: streamErr.err}
	}
	return &ProtocolError{Message: err.Error(), StreamID: streamID, err: err}
}

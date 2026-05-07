export {
  MakaiStdioClient,
  StdioProtocolError,
  createMakaiStdioClient,
  type CreateMakaiStdioClientOptions,
  type MakaiStdioClientOptions,
  type StdioFrame,
  // Deprecated aliases retained under transport-specific names to avoid
  // colliding with the unified high-level client factory options.
  type CreateMakaiClientOptions as DeprecatedCreateMakaiStdioClientOptions,
  type MakaiClientOptions as DeprecatedMakaiStdioClientOptions,
} from "./stdio_client";

export { resolveMakaiBinary, type BinaryResolverOptions } from "./binary_resolver";

export {
  MakaiAuthClient,
  MakaiAuthError,
  createMakaiAuthClient,
  flattenAuthEvent,
  type AuthFlowHandlers,
  type AuthStatus,
  type CreateMakaiAuthClientOptions,
  type MakaiAuthApi,
  type MakaiAuthClientHandle,
  type MakaiAuthClientOptions,
  type MakaiAuthErrorKind,
  type MakaiAuthEvent,
  type ProviderAuthInfo,
  type ProviderId,
} from "./auth_protocol";

export {
  createMakaiModelsApi,
  type ModelsApiOptions,
} from "./models_client";

export {
  createMakaiAgentApi,
  createMakaiClient,
  createMakaiProviderApi,
  type CreateMakaiClientOptions,
  type MakaiClient,
} from "./execution_client";

export {
  MakaiAuthRequiredError,
  MakaiStreamError,
  type AgentRunRequest,
  type AgentRunResponse,
  type AgentStreamEvent,
  type AuthRetryPolicy,
  type ChatMessage,
  type CompletionResponse,
  type ContentPart,
  type ImageContentPart,
  type MakaiAgentApi,
  type MakaiClientOptions,
  type MakaiProviderApi,
  type MakaiStreamErrorKind,
  type ProviderCompleteRequest,
  type ProviderCompleteResponse,
  type ProviderStreamEvent,
  type RunOptions,
  type StopReason,
  type TextContentPart,
  type ThinkingContentPart,
  type ToolCallContentPart,
  type ToolDefinition,
  type ToolResultContentPart,
  type UsageSummary,
} from "./execution_types";

export {
  MakaiProtocolError,
  // Note: `AuthStatus` and `ProviderId` are re-exported from `./auth_protocol`
  // above. The structurally-identical aliases in `./models_types` are kept
  // for internal use but intentionally not surfaced here to avoid duplicate
  // member exports.
  type ApiId,
  type ListModelsRequest,
  type ListModelsResponse,
  type MakaiModelsApi,
  type ModelCapability,
  type ModelDescriptor,
  type ModelLifecycle,
  type ModelSource,
  type ReasoningLevel,
  type ResolveModelRequest,
  type ResolveModelResponse,
} from "./models_types";

export {
  MakaiStdioClient,
  StdioProtocolError,
  createMakaiStdioClient,
  type CreateMakaiStdioClientOptions,
  type MakaiStdioClientOptions,
  type StdioFrame,
  // Deprecated aliases retained for backward compatibility with older imports.
  type CreateMakaiClientOptions,
  type MakaiClientOptions,
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

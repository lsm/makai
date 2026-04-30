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

export {
  MakaiStdioClient,
  StdioProtocolError,
  createMakaiStdioClient,
  type CreateMakaiClientOptions,
  type MakaiClientOptions,
  type StdioFrame,
} from "./stdio_client";

export { resolveMakaiBinary, type BinaryResolverOptions } from "./binary_resolver";
export {
  MakaiAuthError,
  listMakaiAuthProviders,
  loginWithMakaiAuth,
  type AuthProviderInfo,
  type ListMakaiAuthProvidersOptions,
  type LoginWithMakaiAuthOptions,
  type MakaiAuthEvent,
} from "./auth_client";

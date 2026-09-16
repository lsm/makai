//! The client: one runtime process, four namespaces.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crate::agent::AgentApi;
use crate::auth::{AuthApi, AuthHandlers};
use crate::binary::BinaryResolver;
use crate::error::Result;
use crate::models::ModelsApi;
use crate::provider::ProviderApi;
use crate::transport::{Transport, TransportOptions};
use crate::types::AuthRetryPolicy;

const DEFAULT_HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(1_500);
const DEFAULT_RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);
const DEFAULT_FRAME_TIMEOUT: Duration = Duration::from_secs(30);

/// Builds a [`Client`].
#[derive(Debug, Clone)]
pub struct ClientBuilder {
    command: Option<PathBuf>,
    resolver: BinaryResolver,
    args: Vec<String>,
    cwd: Option<PathBuf>,
    env: BTreeMap<String, String>,
    env_clear: bool,
    expected_protocol_version: String,
    handshake_timeout: Duration,
    response_timeout: Duration,
    frame_timeout: Duration,
    auth_retry_policy: Option<AuthRetryPolicy>,
    auth_handlers: AuthHandlers,
}

impl Default for ClientBuilder {
    fn default() -> Self {
        Self {
            command: None,
            resolver: BinaryResolver::default(),
            args: vec!["--stdio".to_owned()],
            cwd: None,
            env: BTreeMap::new(),
            env_clear: false,
            expected_protocol_version: "1".to_owned(),
            handshake_timeout: DEFAULT_HANDSHAKE_TIMEOUT,
            response_timeout: DEFAULT_RESPONSE_TIMEOUT,
            frame_timeout: DEFAULT_FRAME_TIMEOUT,
            auth_retry_policy: None,
            auth_handlers: AuthHandlers::new(),
        }
    }
}

impl ClientBuilder {
    /// A builder with the defaults.
    pub fn new() -> Self {
        Self::default()
    }

    /// Runs this exact executable, bypassing binary resolution entirely.
    ///
    /// Unlike [`ClientBuilder::binary_path`], nothing overrides this — not even
    /// `MAKAI_BINARY_PATH`. Use it when the caller, not the operator, decides
    /// which process to run: a test harness pointing at a protocol fake, or an
    /// application shipping its own runtime.
    pub fn command(mut self, path: impl Into<PathBuf>) -> Self {
        self.command = Some(path.into());
        self
    }

    /// Prefers this binary when resolving.
    ///
    /// `MAKAI_BINARY_PATH` still wins, matching the TypeScript SDK, so an
    /// operator can redirect an application that hardcoded a path. Use
    /// [`ClientBuilder::command`] when that override is not wanted.
    pub fn binary_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.resolver.binary_path = Some(path.into());
        self
    }

    /// Downloads the binary from `url`, verifying it against `checksum_sha256`.
    ///
    /// Fetching needs the `download` feature; without it an already-cached file
    /// is verified and used, and a cache miss is an error.
    pub fn binary_url(
        mut self,
        url: impl Into<String>,
        checksum_sha256: impl Into<String>,
    ) -> Self {
        self.resolver.binary_url = Some(url.into());
        self.resolver.checksum_sha256 = Some(checksum_sha256.into());
        self
    }

    /// Where downloaded binaries are cached.
    pub fn cache_dir(mut self, path: impl Into<PathBuf>) -> Self {
        self.resolver.cache_dir = Some(path.into());
        self
    }

    /// Replaces the whole resolver configuration.
    pub fn resolver(mut self, resolver: BinaryResolver) -> Self {
        self.resolver = resolver;
        self
    }

    /// Replaces the runtime's arguments. Defaults to `["--stdio"]`.
    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args = args.into_iter().map(Into::into).collect();
        self
    }

    /// The working directory for the runtime process.
    pub fn current_dir(mut self, path: impl Into<PathBuf>) -> Self {
        self.cwd = Some(path.into());
        self
    }

    /// Sets one environment variable for the runtime process.
    pub fn env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.env.insert(key.into(), value.into());
        self
    }

    /// Starts the runtime with an empty environment, plus whatever
    /// [`ClientBuilder::env`] adds.
    pub fn env_clear(mut self) -> Self {
        self.env_clear = true;
        self
    }

    /// The protocol version the `ready` frame must advertise. Defaults to `"1"`.
    pub fn expected_protocol_version(mut self, version: impl Into<String>) -> Self {
        self.expected_protocol_version = version.into();
        self
    }

    /// How long to wait for the `ready` handshake.
    pub fn handshake_timeout(mut self, timeout: Duration) -> Self {
        self.handshake_timeout = timeout;
        self
    }

    /// How long to wait between frames on a provider or agent call.
    pub fn response_timeout(mut self, timeout: Duration) -> Self {
        self.response_timeout = timeout;
        self
    }

    /// How long to wait between frames on an auth call.
    pub fn frame_timeout(mut self, timeout: Duration) -> Self {
        self.frame_timeout = timeout;
        self
    }

    /// What `provider` and `agent` calls do when the runtime answers
    /// `auth_required`.
    pub fn auth_retry_policy(mut self, policy: AuthRetryPolicy) -> Self {
        self.auth_retry_policy = Some(policy);
        self
    }

    /// The handlers used by [`AuthApi::login`] when a call does not supply its
    /// own, and by [`AuthRetryPolicy::AutoOnce`].
    pub fn auth_handlers(mut self, handlers: AuthHandlers) -> Self {
        self.auth_handlers = handlers;
        self
    }

    /// Starts the runtime and completes the handshake.
    pub async fn connect(self) -> Result<Client> {
        let command = match &self.command {
            Some(command) => command.clone(),
            None => self.resolver.resolve().await?,
        };
        let transport = Transport::connect(TransportOptions {
            command,
            args: self.args.clone(),
            cwd: self.cwd.clone(),
            env: self
                .env
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
            env_clear: self.env_clear,
            expected_protocol_version: self.expected_protocol_version.clone(),
            handshake_timeout: self.handshake_timeout,
        })
        .await?;

        let transport = Arc::new(transport);
        let auth = AuthApi::new(
            Arc::clone(&transport),
            self.auth_handlers.clone(),
            self.frame_timeout,
        );
        let models = ModelsApi::new(Arc::clone(&transport), self.response_timeout);

        Ok(Client {
            provider: ProviderApi {
                transport: Arc::clone(&transport),
                auth: auth.clone(),
                auth_retry_policy: self.auth_retry_policy,
                response_timeout: self.response_timeout,
            },
            agent: AgentApi {
                transport: Arc::clone(&transport),
                auth: auth.clone(),
                auth_retry_policy: self.auth_retry_policy,
                response_timeout: self.response_timeout,
                models: models.clone(),
            },
            auth,
            models,
            transport,
        })
    }
}

/// A connected Makai runtime.
///
/// Holds one `makai --stdio` child process. All four namespaces multiplex over
/// it, so one client serves concurrent calls.
///
/// Dropping the client terminates the child. [`Client::close`] does the same
/// thing but waits for the process to exit first, which is what you want at the
/// end of a program.
#[derive(Debug, Clone)]
pub struct Client {
    transport: Arc<Transport>,
    auth: AuthApi,
    models: ModelsApi,
    provider: ProviderApi,
    agent: AgentApi,
}

impl std::fmt::Debug for Transport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Transport")
            .field("closed", &self.is_closed())
            .finish()
    }
}

impl Client {
    /// Connects with the default configuration.
    pub async fn connect() -> Result<Self> {
        ClientBuilder::new().connect().await
    }

    /// A builder for a configured client.
    pub fn builder() -> ClientBuilder {
        ClientBuilder::new()
    }

    /// Provider authentication.
    pub fn auth(&self) -> AuthApi {
        self.auth.clone()
    }

    /// Model discovery.
    pub fn models(&self) -> ModelsApi {
        self.models.clone()
    }

    /// The direct provider path.
    pub fn provider(&self) -> ProviderApi {
        self.provider.clone()
    }

    /// The agent loop.
    pub fn agent(&self) -> AgentApi {
        self.agent.clone()
    }

    /// Whether the runtime process has exited or the client has been closed.
    pub fn is_closed(&self) -> bool {
        self.transport.is_closed()
    }

    /// Closes stdin, waits for the runtime to exit, and reaps it.
    ///
    /// Namespace handles cloned out of this client keep the transport alive
    /// until they too are dropped, but every call on them fails once the client
    /// is closed.
    pub async fn close(&self) {
        self.transport.close().await;
    }
}

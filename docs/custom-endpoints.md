# Custom OpenAI- and Anthropic-compatible endpoints

`~/.makai/providers.json` declares endpoints the runtime does not ship knowledge
of: a self-hosted vLLM or llama.cpp server, an aggregator such as OpenRouter, a
corporate gateway that speaks the Anthropic wire format, or any vendor with an
OpenAI-compatible API.

Declared providers appear in `/model`, the status bar and print mode alongside
the built-in ones.

```json
{
  "providers": [
    {
      "id": "groq",
      "name": "Groq",
      "api": "openai-completions",
      "base_url": "https://api.groq.com/openai/v1",
      "auth": { "env": "GROQ_API_KEY" },
      "models": ["llama-3.3-70b-versatile"]
    },
    {
      "id": "gateway",
      "name": "Internal Gateway",
      "api": "anthropic-messages",
      "base_url": "https://gw.internal/anthropic",
      "headers": { "X-Tenant": "acme" },
      "capabilities": { "cache_ttl": true }
    },
    {
      "id": "local",
      "api": "openai-completions",
      "base_url": "http://localhost:8000/v1",
      "auth": "none"
    }
  ]
}
```

## Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Provider id. Letters, digits, `-`, `_`, `.`. Becomes the provider half of a model ref and the keychain account, so it must not collide with a built-in id. |
| `base_url` | yes | Endpoint origin. A trailing `/v1` is stripped; see Base URLs below. |
| `api` | no | `openai-completions` (default), `openai-responses` or `anthropic-messages`. |
| `name` | no | Display name; defaults to the id. |
| `auth` | no | Either `{ "env": "VAR" }` naming a non-empty environment variable, or the string `"none"` to send no credential at all. Anything else is a load error, including an object with no `env`, a non-string `env`, an empty `env`, and any other string. Omitting `auth` is fine and means the key comes from the keychain. |
| `headers` | no | Extra request headers, as a flat object of strings. |
| `models` | no | Allowlist and fallback list; strings, or objects with `id`, `name`, `context_window`, `max_tokens`. |
| `capabilities` | no | Overrides for what the endpoint supports; see below. |
| `reasoning` | no | Whether models expose reasoning. Default `false`. |
| `context_window`, `max_tokens` | no | Defaults for models that do not state their own. Default 128000 and 8192. |

A malformed entry fails the whole file rather than being skipped, so a typo
cannot silently drop one provider while the rest keep working. Reserved ids,
unparseable base URLs, unsupported `api` values and duplicate ids are each
rejected by name. Because that disables every custom provider at once, the TUI
reports it on startup as an error row naming the file and the reason, for
example `InvalidBaseUrl` or `ReservedProviderId`. Without that row a typo would
look identical to having no config at all: nothing in `/model`, and
`/login <id>` answering "unknown login provider".

## Base URLs

Paste whichever form the vendor documents. A trailing `/v1` is stripped when the
file is read, because the providers append their own versioned path. Both of
these reach `https://api.groq.com/openai/v1/chat/completions`:

```
"base_url": "https://api.groq.com/openai/v1"
"base_url": "https://api.groq.com/openai"
```

Without that normalisation the first form would produce `/v1/v1/chat/completions`
and a 404, since the OpenAI request builder concatenates without checking.

## Credentials

**Keys are never read from this file.** There are two supported sources:

- **Keychain**, which is preferred. `/login <id>` prompts for the key and stores
  it under that provider id, the same path Kimi uses. The input is masked.
- **Environment**, by naming a variable in `auth.env`. The name is not a secret;
  the value never enters the file.

The keychain is checked first. A provider with neither source still appears in
`/model` and still lists its models, but by default it cannot complete a turn:
the providers raise `MissingApiKey` before a request leaves the process when no
key resolves. That default is deliberate, so that forgetting to log in fails
loudly instead of quietly sending an unauthenticated request.

An `auth` block that is present must be one of the two valid shapes. A typo such
as `{ "environment": "KEY" }`, or a `{ "env": 5 }`, used to parse as "no key" and
surface much later as a confusing `MissingApiKey`; both are now load errors. A
load error disables **all** custom providers until the file parses, and the TUI
prints a startup row naming the file and the error rather than failing silently.

A server that wants no credential at all, such as a local llama.cpp, vLLM or
LM Studio, says so with `"auth": "none"`. It is an opt-in and nothing else
implies it: an absent `auth` block still means "a key is required and none was
found". A provider that declares it still prefers a real key when one resolves,
from the keychain or from a request, and only falls back to sending nothing.

`/login` with no argument shows the built-in providers. Custom providers are
reached by naming them, `/login gateway`, and only if they are declared in the
file. Listing them in the picker is not implemented yet.

## Model discovery

Startup never touches the network. Loading the catalog reads
`~/.makai/model_catalog/custom-<id>.json`, preferring a copy younger than 24
hours and still using an older one rather than nothing, and falls through to the
declared `models` list when there is no cache at all. Keeping the network off
the startup path is worth doing on its own, and the discovery fetch is now
bounded as well: it runs through `compat.http.fetch`, which gives up after
`catalog_fetch_timeout_ms` and reports `error.Timeout` rather than waiting on
the peer.

Bounding it took a detour worth recording, because the two obvious mechanisms
do not work. `std.http.Client.ConnectTcpOptions` in Zig 0.16.0 declares a
`timeout` field, but that is the only mention of it anywhere under `std/http/`
and `connectTcpOptions` never reads it, so it is inert. Setting `SO_RCVTIMEO`
on the connected socket is worse than useless: the timeout does fire, but
`netReadPosix` in `std.Io.Threaded` treats the resulting `EAGAIN` as a
programmer bug and panics in debug builds. What `compat.http.fetch` does
instead is run the whole request on its own thread that owns its client, its
allocations and a copy of every input, and wait on a `std.Io.Event` with a
deadline. On expiry the caller abandons the thread and returns; the thread
frees everything it owns whenever the peer finally answers or the connection
drops, so nothing the caller owns is touched afterwards.

That primitive covers requests that read one whole response: catalog discovery,
and the OAuth device-code, token-poll and token-exchange calls. **It does not
cover provider streaming**, deliberately. A streaming response has no whole-body
read to bound, and a read deadline there would kill a turn whenever a model
thinks for longer than the timeout.

The fetch happens off that path. A successful `/login <id>` refreshes every
catalog, which is what populates the cache the first time, and a refresh
requests `<base_url>/v1/models`, writes the cache, and falls back to the cached
copy however old when it fails. An endpoint keyed from `auth` rather than the keychain has
no login step, so it serves its declared `models` list until some other login
triggers a refresh.

The declared list is a fallback **only** when discovery produced nothing at all.
When discovery succeeds, its result is filtered by the list and that is what you
get, even if the filter removes everything. A provider that discovers only models
you did not allow therefore contributes nothing, rather than quietly falling back
to its declared entries.

A declared `models` list acts as an **allowlist** over whatever discovery
returns. This is what keeps an aggregator usable: OpenRouter lists hundreds of
models, and naming three keeps `/model` readable. Omit the list entirely and
every model the endpoint advertises is offered, which is what you want for a
server hosting one.

## Capabilities

Capability detection is otherwise a hostname guess, which cannot work for an
endpoint on your own domain. Anything you declare wins; anything you leave out
falls back to that guess, so existing providers are unaffected.

That fallback is per key, not per block. Declaring one capability does not opt
the others into anything: every key you leave out stays genuinely unset and is
answered by the guess on its own. In particular `max_tokens_field` stays
`max_tokens` and strict tool schemas stay off for an endpoint the guess does not
recognise, so declaring `cache_ttl` on a gateway cannot quietly start sending
`max_completion_tokens` and `strict` to an endpoint that implements neither.

An endpoint the guess *does* recognise keeps what it detects, for the keys you
did not declare. A custom entry pointing at a host the guess knows to want the
`zai` or `qwen` thinking format still gets that format, and declaring an
unrelated capability no longer resets it. Declare a key explicitly when you want
to override the guess, not to protect the rest of the block from it.

| Key | Effect |
| --- | --- |
| `cache_ttl` | Endpoint honours long Anthropic prompt-cache TTL. This is the one that matters for an Anthropic-compatible gateway, which otherwise silently loses long cache TTL because `isAnthropicHost` matches on hostname. |
| `reasoning_effort` | Accepts a reasoning-effort parameter. |
| `developer_role` | Accepts the `developer` role. |
| `store` | Supports the `store` parameter. |
| `strict_mode` | Supports strict tool schemas. |
| `thinking_as_text` | Requires thinking to be sent as plain text. |
| `usage_in_streaming` | Reports usage in streaming responses. |
| `max_tokens_field` | `max_tokens` or `max_completion_tokens`. |
| `thinking_format` | `openai`, `zai` or `qwen`. |

Every key in the table is optional in the same sense: on the provider protocol,
an absent capability field means *unset, detect*, never a default value. A
capability block travelling between an SDK client and a provider server carries
only the keys that were declared, and the receiving side resolves the rest from
the model's base URL exactly as if no block had been sent.

## Headers

`headers` entries are sent on every request to that provider. A header whose
name already exists is skipped rather than duplicated, so an `Authorization` or
`anthropic-version` in configuration cannot shadow the credential the runtime
resolved or the API version it requires.

## The Anthropic wire format and vendor credentials

The provider protocol refuses to use a vendor OAuth credential for a provider it
was not issued to, which is why an Anthropic subscription token cannot be pointed
at a third-party endpoint. A custom provider on `anthropic-messages` is not that
case: it authenticates with its own key, resolved from the keychain under its id
or from its declared environment variable, and the vendor token is never
consulted.

A provider that declares `"auth": "none"` sends no credential: no
`Authorization` header on the OpenAI formats, no `x-api-key` on the Anthropic
one. The rest of the request is unchanged, so `anthropic-version` and
`content-type` still go out.

The opt-in cannot be turned against a vendor. It is carried on the model as
`allows_anonymous`, and each provider refuses to honour it for the vendor ids it
serves: `anthropic` on the Anthropic format, and `openai`, `deepseek`, `kimi`,
`github-copilot`, `openai-codex` and `azure` on the OpenAI ones. A declared
provider can never hold one of those ids anyway, since they are reserved, so the
check only matters for a request arriving over the protocol. Honouring it there
would cost nothing more than an unauthenticated request to a URL the caller
already chose, but refusing keeps the vendor paths uniformly credentialed.

Four rules keep those apart. `base_url` arrives from the request, so the first
three bound which credential a request can name and the fourth bounds where an
OAuth credential may be sent. When a request names a vendor wire
format (`anthropic-messages`, `openai-codex-responses`) but a different
`provider`, the server refuses outright if that `provider` is itself a vendor id,
so claiming `provider: "openai-codex"` on `anthropic-messages` cannot pull the
stored Codex token. Otherwise it resolves the credential for that id under an
api-key-only rule that skips OAuth entries entirely. A custom provider's
credential is always a stored API key or an environment variable, so the rule
costs it nothing, and the `anthropic` and `openai-codex` OAuth tokens cannot be
resolved under a borrowed identity.

The third rule covers the wire formats that have no vendor of their own. Only
`anthropic-messages` and `openai-codex-responses` declare an `auth_provider_id`;
the other six registered APIs leave it null, so the credential is resolved under
whatever id the request's `provider` field claims. That id used to be honoured
for OAuth entries as well, which meant a request naming `openai-completions`
with `provider: "anthropic"` and any `base_url` resolved the stored Anthropic
OAuth token and sent it there, bypassing the first two rules entirely. A request
claiming a vendor id on an API that is not that vendor's now resolves under the
same api-key-only rule, so the token stays put and an ordinary custom provider
with a stored key is unaffected.

The fourth rule bounds the destination, which the first three deliberately do
not. A stored OAuth credential is now bound to the origins its provider is
expected to serve: before the token is handed to a provider, `model.base_url` is
compared against an allowed set, and a request pointing somewhere else is
refused with `auth_required` rather than being sent the token. Origin means
scheme, host and port; the path is not compared, so a proxy route under an
allowed host stays usable. An empty `base_url` is allowed, because the server
then fills in the endpoint itself from the same defaults and overrides.

The allowed set for a provider is built from three sources, and the split
between them is the whole point of the rule: an environment variable is set by
whoever runs the process, while `base_url` can arrive from a remote protocol
client.

- The vendor's own origin. `anthropic` is bound to `https://api.anthropic.com`
  and `openai-codex` to `https://chatgpt.com`. `github-copilot` is bound to any
  host under `githubcopilot.com`, which covers both the individual endpoint and
  an `api.<tenant>.githubcopilot.com` enterprise tenant.
- Whatever the environment names for that provider: `MAKAI_BASE_URL`, and the
  per-provider variable where one exists (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`,
  `DEEPSEEK_BASE_URL`). An operator who can already route a vendor through a
  corporate proxy can still reach it; nothing new has to be configured, and no
  new variable was added to relax the check. Codex and Copilot have no
  per-provider variable, so `MAKAI_BASE_URL` is their override here exactly as it
  already is for routing.
- The endpoint the credential itself recorded at login. GitHub Copilot writes the
  base URL it was issued into the credential's `provider_data`, so an enterprise
  deployment that does not sit under `githubcopilot.com` keeps working without
  configuration.

A provider id with none of the above — today only `test-fixture`, tomorrow any
OAuth provider added without an entry — has **no** allowed origin, so a stored
OAuth token under that id is withheld from every non-empty `base_url`. That is
deliberate: a new OAuth provider fails loudly at its first request rather than
silently reopening the gap.

The rule reaches API keys stored in the OAuth shape, which is why "an `.oauth`
entry" is not the same as "an OAuth credential" here. `/login kimi` records a
region, and a credential carrying `provider_data` is persisted as `.oauth` with
an empty `refresh` and `expires` at `maxInt` rather than as `.api_key` — the
same shape the legacy `region` field migrates into. Those are API keys, so an
entry with no refresh token under a provider id with no policy is exempt and
goes wherever the user pointed it. A missing refresh token does **not** exempt
`anthropic`, `openai-codex` or `github-copilot`: an id with a policy is always
bound, so the exemption cannot be used to unbind a vendor token. What the
fail-closed rule above therefore covers is an entry that has a refresh token and
no policy.

Plain `.api_key` entries, and keys from a declared provider's environment
variable, are not checked at all. That pairing is the user's own; constraining
it would break custom endpoints for no gain.

`github-copilot` is why this could not be fixed by widening the refused set
instead. Copilot is stored as an OAuth credential and its models genuinely run
on `openai-completions`, an API that declares no `auth_provider_id`, so the
legitimate request and the exfiltrating one are the same request with a
different `base_url`; adding `github-copilot` to the refused set would make
Copilot resolve no credential at all. The test in
`protocol/provider/server.zig` that pins Copilot resolving its stored token on
`openai-completions` still does so, now against a `githubcopilot.com` base URL
rather than an arbitrary one, and a sibling test pins the refusal at any other
origin.

**What this still does not do.** It bounds where a credential goes, not what a
request may ask for. A caller that legitimately holds a vendor credential can
still drive it with any prompt, and the origin set is per provider rather than
per credential, so two logins to the same vendor are interchangeable. It also
takes the environment and `provider_data` at face value: anything that can write
those already runs as the user.

Each provider's own environment fallback is scoped the same way. When the server
resolves nothing it still calls the provider without a key, and the provider then
looks at its own variables; the Anthropic provider used to read
`ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` without checking which provider
the model belonged to, so a custom endpoint could be handed the vendor key that
happened to be in the environment. It now reads them only when
`model.provider` is `anthropic`, matching what the OpenAI providers already did,
and a custom provider that resolves no key of its own fails with `MissingApiKey`
instead of borrowing one.

## Limits

- Custom providers reach the TUI and the CLI. The TypeScript SDK's `models.list`
  is served by a separate catalog and does not show them. SDK consumers are not
  blocked: the provider server already accepts a client-supplied `base_url`, so
  they can stream against any endpoint by passing it explicitly.
- Only the three wire formats above are accepted. Google, Bedrock and Azure
  shapes are not expressible here.
- Pricing is not declared, so the status bar hides cost for custom models rather
  than guessing a rate.

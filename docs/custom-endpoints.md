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
      "base_url": "http://localhost:8000/v1"
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
| `auth.env` | no | Environment variable to read the key from. |
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

The keychain is checked first. A provider with neither still lists its models,
because a local llama.cpp or vLLM usually needs no key at all; a request to an
endpoint that does need one then fails with the endpoint's own auth error.

`/login` with no argument shows the built-in providers. Custom providers are
reached by naming them, `/login gateway`, and only if they are declared in the
file. Listing them in the picker is not implemented yet.

## Model discovery

Startup never touches the network. Loading the catalog reads
`~/.makai/model_catalog/custom-<id>.json`, preferring a copy younger than 24
hours and still using an older one rather than nothing, and falls through to the
declared `models` list when there is no cache at all. This matters because
`compat.http` sets no connect or read timeout: a declared endpoint that is down,
or that accepts the connection and then stalls, would otherwise hold up
`makai --tui` and print-mode model resolution for as long as the peer cared to
wait, and again every day once the cache went stale. Nor can it simply set one.
`std.http.Client.ConnectTcpOptions` in Zig 0.16.0 declares a `timeout` field,
but that is the only mention of it anywhere under `std/http/`, and
`connectTcpOptions` never reads it, so it is inert. Bounding a request means
either driving the connection setup below `Client.request` or running the fetch
on a thread with a timed wait, which is why no request in this tree is bounded
today and why keeping the fetch off the startup path is the fix that was
available here.

The fetch happens off that path. A successful `/login <id>` refreshes every
catalog, which is what populates the cache the first time, and a refresh
requests `<base_url>/v1/models`, writes the cache, and falls back to the cached
copy however old when it fails. A keyless endpoint has no login step, so it
serves its declared `models` list until some other login triggers a refresh.

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
the others into anything: the undeclared keys are seeded with the same generic
values the guess produces for an endpoint it does not recognise, which is what a
declared endpoint always is. In particular `max_tokens_field` stays `max_tokens`
and strict tool schemas stay off unless you ask for them, so declaring
`cache_ttl` on a gateway cannot quietly start sending `max_completion_tokens`
and `strict` to an endpoint that implements neither.

The one case worth knowing: an endpoint that would have been *recognised* by the
guess gets the generic seed anyway once you declare any capability. That means a
custom entry pointing at `api.openai.com`, or at a host the guess knows to want
the `zai` or `qwen` thinking format, should state `max_tokens_field` or
`thinking_format` explicitly rather than relying on detection.

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

A provider with no credential at all is **not** supported on these wire formats.
Both the OpenAI and the Anthropic provider return `MissingApiKey` when neither
the request nor their own environment variable supplies a key, so a keyless
local server needs an `env_key` naming a variable (its value may be a dummy the
server ignores) or a key stored by `/login <id>`. Letting a declared endpoint be
genuinely keyless is a follow-up, not something this feature does today.

Two rules keep those apart, because `base_url` arrives from the request and the
server does not police where a model points. When a request names a vendor wire
format (`anthropic-messages`, `openai-codex-responses`) but a different
`provider`, the server refuses outright if that `provider` is itself a vendor id,
so claiming `provider: "openai-codex"` on `anthropic-messages` cannot pull the
stored Codex token. Otherwise it resolves the credential for that id under an
api-key-only rule that skips OAuth entries entirely. A custom provider's
credential is always a stored API key or an environment variable, so the rule
costs it nothing, and no OAuth access token can leave through this path whatever
id the request claims.

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

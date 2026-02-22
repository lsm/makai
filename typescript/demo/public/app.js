const state = {
  meta: null,
  authSessionId: null,
  authPollTimer: null,
};

const authProviderSelect = document.getElementById("authProvider");
const authStartBtn = document.getElementById("authStartBtn");
const authStatus = document.getElementById("authStatus");
const authUrlBox = document.getElementById("authUrlBox");
const authUrlLink = document.getElementById("authUrlLink");
const authUrlInstructions = document.getElementById("authUrlInstructions");
const authEvents = document.getElementById("authEvents");
const authPromptBox = document.getElementById("authPromptBox");
const authPromptLabel = document.getElementById("authPromptLabel");
const authPromptInput = document.getElementById("authPromptInput");
const authPromptSubmit = document.getElementById("authPromptSubmit");

const chatProviderSelect = document.getElementById("chatProvider");
const chatModelSelect = document.getElementById("chatModel");
const chatAuthBadge = document.getElementById("chatAuthBadge");
const chatTranscript = document.getElementById("chatTranscript");
const chatInput = document.getElementById("chatInput");
const chatSendBtn = document.getElementById("chatSendBtn");
const refreshMetaBtn = document.getElementById("refreshMetaBtn");

function appendAuthLine(line) {
  authEvents.textContent += `${line}\n`;
  authEvents.scrollTop = authEvents.scrollHeight;
}

function setAuthPrompt(promptEvent) {
  if (!promptEvent) {
    authPromptBox.classList.add("hidden");
    authPromptInput.value = "";
    return;
  }
  authPromptLabel.textContent = promptEvent.message;
  authPromptBox.classList.remove("hidden");
  authPromptInput.focus();
}

function setAuthUrl(urlEvent) {
  if (!urlEvent || !urlEvent.url) {
    authUrlBox.classList.add("hidden");
    authUrlLink.removeAttribute("href");
    authUrlLink.textContent = "";
    authUrlInstructions.textContent = "";
    return;
  }
  authUrlLink.href = urlEvent.url;
  authUrlLink.textContent = urlEvent.url;
  authUrlInstructions.textContent = urlEvent.instructions ?? "";
  authUrlBox.classList.remove("hidden");
}

function normalizePromptAnswer(rawInput) {
  const raw = (rawInput ?? "").trim();
  if (!raw) return raw;

  try {
    const parsed = new URL(raw);
    const hash = parsed.hash.startsWith("#") ? parsed.hash.slice(1) : parsed.hash;
    const hashParams = new URLSearchParams(hash);
    const hashCode = hashParams.get("code");
    if (hashCode) return hashCode;
    const queryCode = parsed.searchParams.get("code");
    if (queryCode) return queryCode;
  } catch {}

  const fragmentLike = raw.startsWith("#") ? raw.slice(1) : raw;
  if (fragmentLike.includes("code=")) {
    const params = new URLSearchParams(fragmentLike);
    const code = params.get("code");
    if (code) return code;
  }

  return raw;
}

function renderProviderModels() {
  const selectedProvider = chatProviderSelect.value;
  const provider = state.meta?.chatProviders?.find((item) => item.id === selectedProvider);
  chatModelSelect.innerHTML = "";
  if (!provider) return;
  for (const model of provider.models) {
    const option = document.createElement("option");
    option.value = model;
    option.textContent = model;
    chatModelSelect.appendChild(option);
  }
  chatAuthBadge.textContent = provider.authenticated ? "authenticated" : "not authenticated";
}

function renderMeta() {
  authProviderSelect.innerHTML = "";
  for (const provider of state.meta.oauthProviders) {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = `${provider.name} (${provider.id})`;
    authProviderSelect.appendChild(option);
  }

  chatProviderSelect.innerHTML = "";
  for (const provider of state.meta.chatProviders) {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = `${provider.name} (${provider.id})`;
    chatProviderSelect.appendChild(option);
  }
  renderProviderModels();
}

async function fetchMeta() {
  const response = await fetch("/api/meta");
  const payload = await response.json();
  state.meta = payload;
  renderMeta();
}

async function pollAuthSession() {
  if (!state.authSessionId) return;
  const response = await fetch(`/api/auth/sessions/${state.authSessionId}`);
  const payload = await response.json();

  authStatus.textContent = `Auth status: ${payload.status}`;
  authEvents.textContent = "";
  let latestAuthUrl = null;
  for (const event of payload.events) {
    if (event.type === "auth_url") latestAuthUrl = event;
    appendAuthLine(JSON.stringify(event));
  }
  setAuthUrl(latestAuthUrl);

  setAuthPrompt(payload.pendingPrompt);

  if (payload.status === "success" || payload.status === "error") {
    clearInterval(state.authPollTimer);
    state.authPollTimer = null;
    state.authSessionId = null;
    if (payload.error) appendAuthLine(`error: ${payload.error}`);
    await fetchMeta();
  }
}

function addMessage(role, text) {
  const div = document.createElement("div");
  div.className = `bubble ${role}`;
  div.textContent = text;
  chatTranscript.appendChild(div);
  chatTranscript.scrollTop = chatTranscript.scrollHeight;
}

authStartBtn.addEventListener("click", async () => {
  authEvents.textContent = "";
  setAuthUrl(null);
  setAuthPrompt(null);
  authStatus.textContent = "Starting auth session...";

  const response = await fetch("/api/auth/sessions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ provider: authProviderSelect.value }),
  });
  const payload = await response.json();
  if (!response.ok) {
    authStatus.textContent = `Failed: ${payload.error ?? "unknown error"}`;
    return;
  }

  state.authSessionId = payload.sessionId;
  if (state.authPollTimer) clearInterval(state.authPollTimer);
  state.authPollTimer = setInterval(() => {
    pollAuthSession().catch((error) => {
      authStatus.textContent = `Poll failed: ${error.message}`;
    });
  }, 1000);
  await pollAuthSession();
});

authPromptSubmit.addEventListener("click", async () => {
  if (!state.authSessionId) return;
  const answer = normalizePromptAnswer(authPromptInput.value);
  if (answer !== authPromptInput.value.trim()) {
    appendAuthLine("info: extracted code from pasted callback URL");
  }
  const response = await fetch(`/api/auth/sessions/${state.authSessionId}/respond`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ answer }),
  });
  const payload = await response.json();
  if (!response.ok) {
    appendAuthLine(`prompt submit failed: ${payload.error ?? "unknown error"}`);
    return;
  }
  authPromptInput.value = "";
  setAuthPrompt(null);
  await pollAuthSession();
});

chatProviderSelect.addEventListener("change", renderProviderModels);

chatSendBtn.addEventListener("click", async () => {
  const message = chatInput.value.trim();
  if (!message) return;

  const provider = chatProviderSelect.value;
  const model = chatModelSelect.value;
  addMessage("user", message);
  chatInput.value = "";

  const response = await fetch("/api/chat", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ provider, model, message }),
  });
  const payload = await response.json();
  if (!response.ok) {
    addMessage("assistant", `Error: ${payload.error ?? "unknown error"}`);
    return;
  }
  addMessage("assistant", payload.reply);
});

refreshMetaBtn.addEventListener("click", () => {
  fetchMeta().catch((error) => {
    addMessage("assistant", `Failed to refresh meta: ${error.message}`);
  });
});

fetchMeta().catch((error) => {
  authStatus.textContent = `Failed to load metadata: ${error.message}`;
});

const messages = document.querySelector("#messages");
const composer = document.querySelector("#composer");
const input = document.querySelector("#message-input");
const sendButton = document.querySelector("#send-button");
const resetButton = document.querySelector("#reset-button");

let previousResponseId = null;
let busy = false;

function appendMessage(kind, text, options = {}) {
  const article = document.createElement("article");
  article.className = `message message-${kind}`;
  if (options.loading) {
    article.classList.add("message-loading");
  }

  const label = document.createElement("div");
  label.className = "message-label";
  label.textContent = kind === "user" ? "You" : "Agent";

  const body = document.createElement("p");
  body.textContent = text;

  article.append(label, body);
  messages.append(article);
  messages.scrollTop = messages.scrollHeight;
  return article;
}

function appendConsentActions(article, action, message, diagnosticId) {
  const actions = document.createElement("div");
  actions.className = "message-actions";

  const consentLink = document.createElement("a");
  consentLink.className = "action-link";
  consentLink.href = action.url;
  consentLink.target = "_blank";
  consentLink.rel = "noopener noreferrer";
  consentLink.textContent = "アクセスを許可";
  consentLink.addEventListener("click", () => {
    const body = new Blob([JSON.stringify({ diagnosticId })], {
      type: "application/json",
    });
    navigator.sendBeacon("/api/diagnostics/consent-opened", body);
  });

  const retryButton = document.createElement("button");
  retryButton.className = "retry-button";
  retryButton.type = "button";
  retryButton.textContent = "許可後に再試行";
  retryButton.addEventListener("click", () => sendMessage(message, false));

  actions.append(consentLink, retryButton);
  article.append(actions);

  const diagnosticReference = document.createElement("div");
  diagnosticReference.className = "diagnostic-reference";
  diagnosticReference.textContent = `診断 ID: ${diagnosticId}`;
  article.append(diagnosticReference);
}

function setBusy(value) {
  busy = value;
  input.disabled = value;
  sendButton.disabled = value;
  resetButton.disabled = value;
}

async function sendMessage(message, renderUser = true) {
  if (busy) {
    return;
  }
  const normalized = message.trim();
  if (!normalized) {
    return;
  }

  if (renderUser) {
    appendMessage("user", normalized);
  }
  setBusy(true);
  const loading = appendMessage("assistant", "考えています", { loading: true });

  try {
    const response = await fetch("/api/chat", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: normalized,
        previousResponseId,
      }),
    });
    const payload = await response.json();
    loading.remove();

    if (!response.ok || payload.status === "error") {
      const text = payload.error?.message || "リクエストを完了できませんでした。";
      appendMessage("error", text);
      return;
    }

    previousResponseId = payload.responseId;
    const article = appendMessage("assistant", payload.message);
    if (payload.status === "consent_required" && payload.action) {
      appendConsentActions(
        article,
        payload.action,
        normalized,
        payload.diagnosticId,
      );
    }
  } catch (_error) {
    loading.remove();
    appendMessage("error", "接続を確認して、もう一度お試しください。");
  } finally {
    setBusy(false);
    input.focus();
  }
}

function resetConversation() {
  previousResponseId = null;
  messages.replaceChildren();
  appendMessage("assistant", "プロフィールについて聞いてください。");
  input.value = "";
  input.focus();
}

composer.addEventListener("submit", (event) => {
  event.preventDefault();
  const message = input.value;
  input.value = "";
  sendMessage(message);
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    composer.requestSubmit();
  }
});

input.addEventListener("input", () => {
  input.style.height = "auto";
  input.style.height = `${Math.min(input.scrollHeight, 132)}px`;
});

resetButton.addEventListener("click", resetConversation);
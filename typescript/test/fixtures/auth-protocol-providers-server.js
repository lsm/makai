// Fixture stdio server that emulates the auth protocol path of `makai --stdio`
// for the `auth_providers_request` envelope. Used by typescript SDK tests.
const readline = require("node:readline");
const { ulid } = require("ulid");

process.stdout.write(JSON.stringify({ type: "ready", protocol_version: "1" }) + "\n");

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

const outboundSequences = new Map();
function nextSeq(streamId) {
  const next = (outboundSequences.get(streamId) ?? 0) + 1;
  outboundSequences.set(streamId, next);
  return next;
}

function send(envelope) {
  process.stdout.write(JSON.stringify(envelope) + "\n");
}

rl.on("line", (line) => {
  let envelope;
  try {
    envelope = JSON.parse(line);
  } catch {
    return;
  }

  if (envelope.type === "auth_providers_request") {
    send({
      type: "ack",
      stream_id: envelope.stream_id,
      message_id: ulid(),
      sequence: nextSeq(envelope.stream_id),
      in_reply_to: envelope.message_id,
      timestamp: Date.now(),
      version: 1,
      payload: { acknowledged_id: envelope.message_id },
    });
    send({
      type: "auth_providers_response",
      stream_id: envelope.stream_id,
      message_id: ulid(),
      sequence: nextSeq(envelope.stream_id),
      in_reply_to: envelope.message_id,
      timestamp: Date.now(),
      version: 1,
      payload: {
        providers: [
          { id: "anthropic", name: "Anthropic", auth_status: "login_required" },
          { id: "github-copilot", name: "GitHub Copilot", auth_status: "authenticated" },
          {
            id: "test-fixture",
            name: "Test Fixture (CI)",
            auth_status: "failed",
            last_error: "previous attempt rejected",
          },
        ],
      },
    });
  }
});

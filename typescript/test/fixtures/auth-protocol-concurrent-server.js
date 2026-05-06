// Fixture stdio server that intentionally interleaves responses for concurrent
// auth protocol streams. Used to verify the SDK routes frames by stream_id
// instead of discarding frames that belong to another in-flight auth call.
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

const pendingProviderRequests = [];

function providerResponseEnvelope(envelope) {
  return {
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
      ],
    },
  };
}

rl.on("line", (line) => {
  let envelope;
  try {
    envelope = JSON.parse(line);
  } catch {
    return;
  }

  if (envelope.type !== "auth_providers_request") return;

  pendingProviderRequests.push(envelope);
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

  if (pendingProviderRequests.length === 2) {
    const [first, second] = pendingProviderRequests;
    // Deliberately send the second stream's terminal response first. Without
    // per-stream routing, the first caller can consume and drop this frame.
    send(providerResponseEnvelope(second));
    setImmediate(() => send(providerResponseEnvelope(first)));
  }
});

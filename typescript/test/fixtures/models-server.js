// Generic protocol fixture for `client.models.*` tests.
//
// Behavior:
//   - emit a `ready` handshake (protocol_version "1") on startup.
//   - on each line of stdin, parse it as a `models_request` envelope.
//   - log the parsed request payload (one JSON line per request) to
//     `MAKAI_TEST_REQUEST_LOG` if set (used by tests to assert what the
//     client put on the wire).
//   - emit an `ack` envelope referencing the request's `message_id`.
//   - emit a configured response: either `models_response` with a payload
//     loaded from `MAKAI_TEST_RESPONSE_PATH`, or a `nack` with a payload
//     loaded from `MAKAI_TEST_NACK_PATH`.
//   - exit cleanly when stdin closes.
//
// The same fixture is reused across the test scenarios by toggling env vars,
// keeping the matrix of fixture files small.

const fs = require("node:fs");
const readline = require("node:readline");

function emit(frame) {
  process.stdout.write(JSON.stringify(frame) + "\n");
}

function loadJson(path) {
  if (!path) return null;
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

function appendLog(path, line) {
  if (!path) return;
  fs.appendFileSync(path, line + "\n");
}

function buildResponse(env, type, payload) {
  return {
    type,
    stream_id: env.stream_id,
    message_id: `${env.stream_id}-reply`,
    sequence: (env.sequence || 0) + 1,
    timestamp: Date.now(),
    version: 1,
    in_reply_to: env.message_id,
    payload,
  };
}

function buildAck(env) {
  return {
    type: "ack",
    stream_id: env.stream_id,
    message_id: `${env.stream_id}-ack`,
    sequence: (env.sequence || 0) + 1,
    timestamp: Date.now(),
    version: 1,
    in_reply_to: env.message_id,
    payload: { acknowledged_id: env.message_id },
  };
}

emit({ type: "ready", protocol_version: "1" });

const requestLog = process.env.MAKAI_TEST_REQUEST_LOG || "";
const modelsResponse = loadJson(process.env.MAKAI_TEST_RESPONSE_PATH);
const nackPayload = loadJson(process.env.MAKAI_TEST_NACK_PATH);

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on("line", (line) => {
  let env;
  try {
    env = JSON.parse(line);
  } catch (err) {
    process.stderr.write(`fixture: invalid JSON frame: ${line}\n`);
    return;
  }

  if (env.type !== "models_request") {
    // Echo unsupported frames into the log so tests can detect drift.
    appendLog(requestLog, JSON.stringify({ unexpected_type: env.type, raw: env }));
    return;
  }

  appendLog(requestLog, JSON.stringify(env));

  emit(buildAck(env));

  if (nackPayload) {
    emit(
      buildResponse(env, "nack", {
        rejected_id: env.message_id,
        ...nackPayload,
      }),
    );
    return;
  }

  if (!modelsResponse) {
    process.stderr.write("fixture: no MAKAI_TEST_RESPONSE_PATH or MAKAI_TEST_NACK_PATH set\n");
    process.exit(1);
  }

  emit(buildResponse(env, "models_response", modelsResponse));
});

rl.on("close", () => {
  process.exit(0);
});

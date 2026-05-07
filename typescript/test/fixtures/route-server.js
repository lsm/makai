const readline = require("node:readline");

process.stdout.write(JSON.stringify({ type: "ready", protocol_version: "1" }) + "\n");

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

function write(frame) {
  process.stdout.write(JSON.stringify(frame) + "\n");
}

rl.on("line", (line) => {
  try {
    const msg = JSON.parse(line);
    if (msg.type === "stream_request") {
      write({ type: "event", stream_id: msg.stream_id ?? "unknown", event_type: "text_delta", delta: "ok" });
    } else if (msg.type === "agent_message") {
      write({ type: "agent_event", session_id: msg.session_id ?? "unknown", payload: { event_json: JSON.stringify({ type: "text_delta", delta: "ok" }) } });
    }
  } catch {
    // ignore malformed frames in fixture
  }
});

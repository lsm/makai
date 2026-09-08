const readline = require("node:readline");

process.stdout.write(JSON.stringify({ type: "ready", protocol_version: "1" }) + "\n");

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

function write(frame) {
  process.stdout.write(JSON.stringify(frame) + "\n");
}

// Echo server for reply-correlation coverage: every request is answered with
// one frame whose in_reply_to is the request's message_id, so tests control
// exactly which outstanding request each reply correlates with. A request
// payload of { omit_in_reply_to: true } answers without in_reply_to.
rl.on("line", (line) => {
  try {
    const msg = JSON.parse(line);
    if (msg.type === "agent_message" || msg.type === "stream_request") {
      const reply = {
        type: msg.type === "agent_message" ? "agent_event" : "event",
        ...(msg.stream_id ? { stream_id: msg.stream_id } : { session_id: msg.session_id }),
        payload: { event_json: JSON.stringify({ type: "text_delta", delta: "ok" }) },
      };
      if (!msg.payload?.omit_in_reply_to) reply.in_reply_to = msg.message_id;
      write(reply);
    }
  } catch {
    // ignore malformed frames in fixture
  }
});

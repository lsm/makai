const readline = require("node:readline");

process.stdout.write(
  JSON.stringify({
    type: "auth_url",
    provider: "fixture",
    url: "https://example.invalid/fixture-login",
    instructions: "enter fixture code",
  }) + "\n",
);
process.stdout.write(
  JSON.stringify({
    type: "prompt",
    provider: "fixture",
    message: "Enter fixture code:",
    allow_empty: false,
  }) + "\n",
);

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on("line", (line) => {
  if (line.trim() === "letmein") {
    process.stdout.write(JSON.stringify({ type: "success", provider: "fixture" }) + "\n");
    process.exit(0);
    return;
  }
  process.stdout.write(
    JSON.stringify({
      type: "error",
      provider: "fixture",
      code: "invalid_code",
      message: "invalid fixture code",
    }) + "\n",
  );
  process.exit(1);
});

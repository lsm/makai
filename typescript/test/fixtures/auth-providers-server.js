process.stdout.write(
  JSON.stringify({
    type: "providers",
    providers: [
      { id: "anthropic", name: "Anthropic" },
      { id: "github-copilot", name: "GitHub Copilot" },
    ],
  }) + "\n",
);
process.exit(0);

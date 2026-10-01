import { loadConfig } from "./config.js";
import { Daemon } from "./daemon.js";
import { createLogger } from "./log.js";
import { userPath } from "./providers/common/shell-path.js";

async function main(): Promise<void> {
  // A game opened from Finder or a desktop launcher passes on a minimal PATH (macOS, Linux).
  if (process.platform !== "win32") {
    const full = userPath(process.env);
    if (full) process.env.PATH = full;
  }
  const config = loadConfig();
  const log = createLogger(config.logLevel);
  // The `shutdown` command stops the daemon (tasks pause, runtime files go) and then exits here.
  const daemon = await Daemon.start({ config, log, onShutdown: () => process.exit(0) });
  process.stdout.write(`AgentEmpire Town Hall is ready.\nWeb client: ${daemon.url}\nruntime.json: ${daemon.runtimeFile}\n`);

  let stopping = false;
  const shutdown = async (signal: string) => {
    if (stopping) return;
    stopping = true;
    log.info({ signal }, "shutting down");
    try {
      await daemon.stop();
    } finally {
      process.exit(0);
    }
  };
  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  if (process.platform === "win32") process.on("SIGBREAK", () => void shutdown("SIGBREAK"));
}

main().catch((err: unknown) => {
  process.stderr.write(`The Town Hall could not start: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});

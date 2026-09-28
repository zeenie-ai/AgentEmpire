import { pino, type Logger } from "pino";

export type { Logger };

export function createLogger(level: string): Logger {
  return pino({
    name: "townhall",
    level,
    base: { pid: process.pid },
    redact: {
      paths: ["token", "*.token", "payload.token", "headers.authorization", "env"],
      censor: "[REDACTED]",
    },
  });
}

export function silentLogger(): Logger {
  return pino({ level: "silent" });
}

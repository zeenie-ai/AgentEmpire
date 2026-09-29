import { defineConfig } from "vitest/config";

// Opt-in smoke tests against the real harnesses and real models. Each file runs only when its
// switch is set: AURELHAVEN_SMOKE_CLAUDE=1, AURELHAVEN_SMOKE_CODEX=1, AURELHAVEN_SMOKE_PI=1.
export default defineConfig({
  test: {
    include: ["test/smoke/**/*.smoke.test.ts"],
    pool: "forks",
    fileParallelism: false,
    testTimeout: 900_000,
    hookTimeout: 60_000,
    environment: "node",
    // Print each run's report even when the test passes.
    silent: false,
  },
});

// A scripted model provider for the real pi process in tests, built on pi-ai's faux provider
// (packages/ai/src/providers/faux.ts): no network, no cost, deterministic replies. Loaded with
// `pi -e <this file>`; the model is "faux/faux-1".
//
//   AURELHAVEN_PI_FAUX_SCRIPT  JSON file: {"responses":[step, ...]}, one step per model call:
//     {"text":"..."}                              a plain reply
//     {"text":"...","tool":"write","args":{...}}  a reply that calls a tool
//     {"sleep":500,"text":"..."}                  a reply that takes a while
//     {"hang":true}                               a reply that waits until the run is aborted
//     {"error":"429 rate limit"}                  a provider error
//     {"echo":true}                               replies with what it was sent (see the log)
//   AURELHAVEN_PI_FAUX_LOG     JSON-lines file: one entry per model call (the last user text,
//                              the last tool result, the system prompt, the priced cost)
import { appendFileSync, readFileSync } from "node:fs";
import {
  calculateCost,
  createAssistantMessageEventStream,
  createFauxCore,
  createProvider,
  fauxAssistantMessage,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai";

function log(entry) {
  if (process.env.AURELHAVEN_PI_FAUX_LOG) appendFileSync(process.env.AURELHAVEN_PI_FAUX_LOG, `${JSON.stringify(entry)}\n`);
}

function textOf(content) {
  if (typeof content === "string") return content;
  return (content ?? []).map((b) => (b.type === "text" ? b.text : "")).join("");
}

function describe(context) {
  const messages = context.messages ?? [];
  const users = messages.filter((m) => m.role === "user");
  const results = messages.filter((m) => m.role === "toolResult");
  const system = messages.filter((m) => m.role === "system").map((m) => JSON.stringify(m.sections ?? m.content)).join("\n");
  return {
    lastUser: users.length ? textOf(users[users.length - 1].content) : null,
    users: users.length,
    lastToolResult: results.length ? { tool: results[results.length - 1].toolName, text: textOf(results[results.length - 1].content), isError: results[results.length - 1].isError } : null,
    system,
  };
}

function waitAbort(signal, ms) {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const timer = ms === undefined ? null : setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      if (timer) clearTimeout(timer);
      resolve();
    });
  });
}

function toStep(step) {
  return async (context, options) => {
    const seen = describe(context);
    log({ kind: "call", step, ...seen, system: seen.system.slice(0, 4000) });
    if (step.hang) await waitAbort(options?.signal);
    if (step.sleep) await waitAbort(options?.signal, step.sleep);
    if (step.error) return fauxAssistantMessage([], { stopReason: "error", errorMessage: step.error });
    if (step.echo) return fauxAssistantMessage(`Echo: ${seen.lastUser}`);
    if (step.tool) {
      const blocks = [];
      if (step.text) blocks.push(fauxText(step.text));
      blocks.push(fauxToolCall(step.tool, step.args ?? {}));
      return fauxAssistantMessage(blocks, { stopReason: "toolUse" });
    }
    return fauxAssistantMessage(step.text ?? "");
  };
}

export default function (pi) {
  const script = process.env.AURELHAVEN_PI_FAUX_SCRIPT ? JSON.parse(readFileSync(process.env.AURELHAVEN_PI_FAUX_SCRIPT, "utf8")) : { responses: [] };
  const core = createFauxCore({
    provider: "faux",
    models: [{ id: "faux-1", name: "Faux One", cost: { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 }, contextWindow: 128000, maxTokens: 16384 }],
    tokenSize: { min: 4, max: 4 },
  });
  core.setResponses((script.responses ?? []).map(toStep));
  // The faux provider reports token counts but no cost; price them like a real provider would.
  const stream = (model, context, options) => {
    const inner = core.streamSimple(model, context, options);
    const outer = createAssistantMessageEventStream();
    void (async () => {
      for await (const event of inner) {
        if (event.type === "done") {
          event.message.usage.cost = calculateCost(model, event.message.usage);
          log({ kind: "cost", total: event.message.usage.cost.total });
        }
        outer.push(event);
      }
      outer.end(await inner.result());
    })();
    return outer;
  };
  pi.registerProvider(
    createProvider({
      id: "faux",
      auth: { apiKey: { name: "Faux", resolve: async () => ({ auth: {} }) } },
      models: core.models,
      api: { stream, streamSimple: stream },
    }),
  );
}

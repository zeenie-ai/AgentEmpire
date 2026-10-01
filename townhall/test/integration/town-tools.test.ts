import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { afterEach, describe, expect, it } from "vitest";
import { srcPath } from "../../src/paths.js";
import { fail } from "../../src/protocol/errors.js";
import { TownToolsBridge } from "../../src/providers/common/town-tools.js";
import type { RunParty, SubtaskInfo } from "../../src/providers/types.js";
import { MockHost } from "../helpers/run-host.js";

const PARTY: RunParty = {
  partyId: "pty_1",
  members: [
    { agentId: "agt_q", name: "Quill", provider: "codex", role: "scribe" },
    { agentId: "agt_r", name: "Rune", provider: "claude", role: "artificer" },
  ],
};

const DONE: SubtaskInfo = {
  taskId: "tsk_child",
  memberId: "agt_q",
  memberName: "Quill",
  title: "Write the docs",
  size: "S",
  state: "awaiting_review",
  status: "done",
  reason: null,
  budgetMana: 40,
  spentMana: 3.5,
  summary: "Wrote docs.md.",
  diffStat: { files: 1, added: 1, removed: 0 },
  files: ["docs.md"],
};

/** A JSON-RPC client for town-mcp.mjs over stdio. */
class McpClient {
  private nextId = 1;
  private buffer = "";
  private readonly waiting = new Map<number, (msg: any) => void>();
  constructor(readonly child: ChildProcessWithoutNullStreams) {
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      this.buffer += chunk;
      let i;
      while ((i = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, i);
        this.buffer = this.buffer.slice(i + 1);
        if (!line.trim()) continue;
        const msg = JSON.parse(line) as { id?: number };
        if (typeof msg.id === "number") this.waiting.get(msg.id)?.(msg);
      }
    });
  }

  request(method: string, params: unknown): Promise<any> {
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.waiting.set(id, resolve);
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  async call(name: string, args: unknown): Promise<{ text: string; isError: boolean }> {
    const res = await this.request("tools/call", { name, arguments: args });
    return { text: res.result.content.map((c: { text: string }) => c.text).join("\n"), isError: res.result.isError === true };
  }
}

describe("the town MCP server and its bridge", () => {
  const children: ChildProcessWithoutNullStreams[] = [];
  const bridges: TownToolsBridge[] = [];

  afterEach(() => {
    for (const c of children.splice(0)) c.stdin.end();
    for (const b of bridges.splice(0)) b.close();
  });

  async function connect(host: MockHost, tokenOverride?: string): Promise<McpClient> {
    const bridge = await TownToolsBridge.open(host, PARTY);
    bridges.push(bridge);
    const child = spawn(process.execPath, [srcPath("providers", "common", "town-mcp.mjs")], {
      env: { ...process.env, AURELHAVEN_TOWN_URL: bridge.url, AURELHAVEN_TOWN_TOKEN: tokenOverride ?? bridge.token },
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    child.stderr.resume();
    children.push(child);
    const client = new McpClient(child);
    const init = await client.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
    expect(init.result.serverInfo.name).toBe("town");
    return client;
  }

  it("lists the three tools with the party's members, and checks every argument", async () => {
    const host = new MockHost();
    const mcp = await connect(host);
    const list = await mcp.request("tools/list", {});
    expect(list.result.tools.map((t: { name: string }) => t.name)).toEqual(["delegate", "check_status", "collect_results"]);
    expect(list.result.tools[0].inputSchema.properties.member.enum).toEqual(["Quill", "Rune"]);
    expect(list.result.tools[0].description).toContain("Quill (scribe, codex), Rune (artificer, claude)");

    const missing = await mcp.call("delegate", { member: "Quill", prompt: "Write docs." });
    expect(missing.isError).toBe(true);
    expect(missing.text).toMatch(/^Could not delegate: title:/);
    expect(host.delegations).toHaveLength(0);
    const tooLong = await mcp.call("collect_results", { wait_seconds: 4000 });
    expect(tooLong).toMatchObject({ isError: true });
    const unknown = await mcp.call("burn_the_town", {});
    expect(unknown).toEqual({ text: "There is no town tool named burn_the_town.", isError: true });
    const lost = await mcp.call("check_status", { task_id: "tsk_nope" });
    expect(lost).toEqual({ text: "tsk_nope is not one of this task's sub-tasks.", isError: true });
  });

  it("delegates with the defaults, passes Town Hall refusals back as tool errors, and collects", async () => {
    const host = new MockHost();
    host.onDelegate = (req) => {
      if (req.to === "Rune") throw fail.mana("this task's Mana Seal cannot cover that budget: 3 Mana is left");
      host.party = { sealLeftMana: 110, subtasks: [{ ...DONE, status: "queued", state: "queued", summary: null, diffStat: null, files: undefined }] };
      return { taskId: "tsk_child", wait: async () => ({ taskId: "tsk_child", status: "done", summary: "", diffStat: null }) };
    };
    const waits: Array<[string[] | null, number]> = [];
    host.onWait = (ids, timeoutMs) => {
      waits.push([ids, timeoutMs]);
      return { sealLeftMana: 110, subtasks: [DONE] };
    };
    const mcp = await connect(host);

    const ok = await mcp.call("delegate", { member: "Quill", title: "Write the docs", prompt: "Write docs.md." });
    expect(ok.isError).toBe(false);
    expect(JSON.parse(ok.text)).toMatchObject({ task_id: "tsk_child", member: "Quill", size: "S", budget_mana: 40, status: "queued" });
    expect(host.delegations[0]).toEqual({ to: "Quill", title: "Write the docs", prompt: "Write docs.md.", size: "S" });

    const refused = await mcp.call("delegate", { member: "Rune", title: "More", prompt: "More.", budget_mana: 50 });
    expect(refused).toEqual({ text: "The Town Hall refused: this task's Mana Seal cannot cover that budget: 3 Mana is left", isError: true });

    const collected = await mcp.call("collect_results", { wait_seconds: 30 });
    expect(waits).toEqual([[null, 30_000]]);
    expect(JSON.parse(collected.text)).toEqual({
      all_finished: true,
      seal_left_mana: 110,
      subtasks: [
        {
          task_id: "tsk_child",
          member: "Quill",
          title: "Write the docs",
          status: "done",
          spent_mana: 3.5,
          budget_mana: 40,
          summary: "Wrote docs.md.",
          changes: { files: 1, added: 1, removed: 0 },
          files: ["docs.md"],
        },
      ],
      note: "Every sub-task has finished. Their changes are merged with yours when the player accepts the party's task.",
    });
  });

  it("refuses a caller without the run's secret", async () => {
    const host = new MockHost();
    const mcp = await connect(host, "not-the-secret");
    const list = await mcp.request("tools/list", {});
    expect(list.result.tools).toEqual([]);
    const call = await mcp.call("check_status", {});
    expect(call).toEqual({ text: "The Town Hall refused the request (HTTP 401).", isError: true });
  });
});

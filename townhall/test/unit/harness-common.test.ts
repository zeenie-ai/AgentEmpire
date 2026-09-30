import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Economy } from "../../src/core/economy.js";
import { defaultEconomyPath, defaultPricingPath } from "../../src/paths.js";
import { approvalFor, claudeCategory, commandRisk, describeToolCall, piCategory } from "../../src/providers/common/approvals.js";
import { claudePlan, codexPlan, piPlan, type EconomyTools } from "../../src/providers/common/capabilities.js";
import { harnessEnv } from "../../src/providers/common/env.js";
import {
  bundledPiCli,
  codexNativeFromPackage,
  findOnPath,
  launchFor,
  readCmdShimTarget,
  resolveClaude,
  resolveCodex,
  resolvePi,
} from "../../src/providers/common/exec.js";
import { encodeJsonl, JsonlDecoder } from "../../src/providers/common/jsonl.js";
import { Pricing, RunningTotal } from "../../src/providers/common/pricing.js";
import { feedbackMessage, firstMessageFor, systemPromptFor } from "../../src/providers/common/prompt.js";
import { classifyFailure } from "../../src/providers/common/support.js";
import { claudeMcpServer, codexMcpOverrides, mcpServerName, piMcpServer, usableWaygates } from "../../src/providers/common/waygates.js";
import { insideWorkspace, parsePermissionRequest, permissionApproval } from "../../src/providers/codex/permissions.js";
import { framingNames } from "../../src/providers/real.js";
import { removeRoot, tempRoot } from "../helpers/harness.js";
import { runRequest } from "../helpers/run-host.js";

const econ = Economy.load(defaultEconomyPath());
const tools = econ.data.tools as unknown as EconomyTools;

describe("strict JSONL framing", () => {
  it("splits on LF only, strips CR, keeps U+2028 inside strings and joins split UTF-8", () => {
    const seen: unknown[] = [];
    const bad: string[] = [];
    const d = new JsonlDecoder((v) => seen.push(v), (l) => bad.push(l));
    const record = { text: "line separator para", emoji: "été" };
    const bytes = Buffer.from(`${JSON.stringify(record)}\r\n{"a":1}\nnot json\n{"b":`, "utf8");
    const cut = bytes.indexOf(0xc3) + 1; // split inside a two-byte character
    d.push(bytes.subarray(0, cut));
    d.push(bytes.subarray(cut));
    d.push("2}");
    d.end();
    expect(seen).toEqual([record, { a: 1 }, { b: 2 }]);
    expect(bad).toEqual(["not json"]);
    expect(encodeJsonl({ x: " " })).toBe('{"x":" "}\n');
  });

  it("drops a record longer than the limit and recovers at the next line", () => {
    const seen: unknown[] = [];
    const bad: string[] = [];
    const d = new JsonlDecoder((v) => seen.push(v), (l) => bad.push(l), 32);
    d.push(`{"big":"${"x".repeat(40)}`);
    d.push(`${"y".repeat(10)}"}\n{"ok":true}\n`);
    expect(seen).toEqual([{ ok: true }]);
    expect(bad).toEqual(["[oversized record dropped]"]);
  });
});

describe("harness executables resolve without a shell", () => {
  let root: string;
  beforeAll(() => {
    root = tempRoot("exec");
  });
  afterAll(() => removeRoot(root));

  const touch = (file: string, content = "") => {
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, content);
    return file;
  };

  it("follows npm .cmd shims to the real program", () => {
    const npm = path.join(root, "npm");
    const exe = touch(path.join(npm, "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe"), "MZ");
    const shim = touch(
      path.join(npm, "claude.cmd"),
      '@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe"   %*\r\n',
    );
    expect(readCmdShimTarget(shim)).toBe(exe);
    const launch = launchFor(shim, "path");
    expect(launch).toMatchObject({ file: exe, prefix: [], source: "path", display: shim });

    const js = touch(path.join(npm, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "bundle", "cli.js"), "#!/usr/bin/env node\n");
    const piShim = touch(
      path.join(npm, "pi.cmd"),
      '@ECHO off\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\@earendil-works\\pi-coding-agent\\dist\\bundle\\cli.js" %*\r\n',
    );
    expect(launchFor(piShim, "path")).toMatchObject({ file: process.execPath, prefix: [js] });
  });

  it("finds a harness on PATH, preferring a real executable on Windows", () => {
    const bin = path.join(root, "bin");
    touch(path.join(bin, "tool.cmd"), "@echo off\r\n");
    const exe = touch(path.join(bin, process.platform === "win32" ? "tool.exe" : "tool"), "x");
    expect(findOnPath("tool", { PATH: bin })).toBe(exe);
    expect(findOnPath("absent", { PATH: bin })).toBeNull();
  });

  it("maps the Codex launcher to its native binary", () => {
    const pkg = path.join(root, "g", "node_modules", "@openai", "codex");
    touch(path.join(pkg, "package.json"), JSON.stringify({ name: "@openai/codex" }));
    const script = touch(path.join(pkg, "bin", "codex.js"), "");
    const native = touch(
      path.join(pkg, "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe"),
      "MZ",
    );
    expect(codexNativeFromPackage(pkg, "win32", "x64")).toBe(native);
    if (process.platform === "win32" && process.arch === "x64") {
      const res = resolveCodex({ PATH: "", AURELHAVEN_CODEX_BIN: script });
      expect(res.launch).toMatchObject({ file: native, prefix: [], source: "env" });
    }
  });

  it("honours overrides and reports a bad one", () => {
    const script = touch(path.join(root, "fake", "claude.mjs"), "");
    expect(resolveClaude({ PATH: "", AURELHAVEN_CLAUDE_BIN: script }).launch).toMatchObject({ file: process.execPath, prefix: [script] });
    const bad = resolveClaude({ PATH: "", AURELHAVEN_CLAUDE_BIN: path.join(root, "nope.exe") });
    expect(bad.launch).toBeNull();
    expect(bad.problem).toMatch(/AURELHAVEN_CLAUDE_BIN/);
    expect(resolvePi({ PATH: "", AURELHAVEN_PI_BIN: path.join(root, "nope.js") }).launch).toBeNull();
  });

  it("falls back to the pi bundled with the Town Hall", () => {
    const cli = bundledPiCli();
    expect(cli).toMatch(/pi-coding-agent[\\/]dist[\\/]bundle[\\/]cli\.js$/);
    expect(resolvePi({ PATH: "" }).launch).toMatchObject({ file: process.execPath, prefix: [cli], source: "bundled" });
  });

  it("strips a parent agent session's markers from the harness environment", () => {
    const env = harnessEnv(
      { PATH: "p", CLAUDECODE: "1", CLAUDE_CODE_SESSION_ID: "s", CLAUDE_CODE_MESSAGING_TOKEN: "t", CLAUDE_CODE_GIT_BASH_PATH: "b", PI_SESSION_ID: "x", HOME: "h" },
      { EXTRA: "1" },
    );
    expect(env).toEqual({ PATH: "p", CLAUDE_CODE_GIT_BASH_PATH: "b", HOME: "h", EXTRA: "1" });
  });
});

describe("approval categories and summaries", () => {
  it("maps Claude Code tools", () => {
    for (const t of ["Read", "Glob", "Grep"]) expect(claudeCategory(t)).toBe("read");
    for (const t of ["Edit", "Write", "NotebookEdit", "MultiEdit"]) expect(claudeCategory(t)).toBe("write");
    expect(claudeCategory("Bash")).toBe("command");
    expect(claudeCategory("WebSearch")).toBe("network");
    expect(claudeCategory("WebFetch")).toBe("network");
    expect(claudeCategory("mcp__github__search")).toBe("mcp");
    expect(claudeCategory("SomethingNew")).toBe("command");
  });

  it("maps pi tools", () => {
    for (const t of ["read", "grep", "find", "ls"]) expect(piCategory(t)).toBe("read");
    for (const t of ["edit", "write"]) expect(piCategory(t)).toBe("write");
    expect(piCategory("bash")).toBe("command");
    expect(piCategory("powershell")).toBe("command");
    expect(piCategory("mcp__docs__lookup")).toBe("mcp");
  });

  it("describes calls and marks destructive commands high risk", () => {
    const cwd = path.resolve("/work/app");
    expect(describeToolCall("Write", { file_path: path.join(cwd, "src", "a.ts") }, cwd)).toBe("Write: src/a.ts");
    expect(describeToolCall("Grep", { pattern: "TODO" }, cwd)).toBe("Search files for: TODO");
    expect(describeToolCall("WebFetch", { url: "https://example.org" }, cwd)).toBe("Fetch: https://example.org");
    expect(describeToolCall("mcp__github__search", {}, cwd)).toBe("Use search on github");
    expect(commandRisk("rm -rf build")).toBe("high");
    expect(commandRisk("Remove-Item -Recurse -Force out")).toBe("high");
    expect(commandRisk("git push origin main")).toBe("high");
    expect(commandRisk("npm test")).toBeUndefined();
    expect(approvalFor("Bash", "command", { command: "npm test" }, cwd)).toEqual({
      tool: "Bash",
      category: "command",
      input: { command: "npm test" },
      summary: "Run: npm test",
    });
  });

  it("classifies harness failures", () => {
    expect(classifyFailure("Claude AI usage limit reached|1790")).toEqual({ code: "provider_limit", transient: true });
    expect(classifyFailure("429 Too Many Requests")).toEqual({ code: "provider_limit", transient: true });
    expect(classifyFailure("authentication_failed: please log in again")).toEqual({ code: "auth", transient: true });
    expect(classifyFailure("segfault")).toEqual({ code: "crash", transient: true });
  });
});

describe("pricing", () => {
  const pricing = Pricing.load(defaultPricingPath());

  it("normalises harness model names", () => {
    expect(pricing.canonical("claude-haiku-4-5-20251001")).toBe("claude-haiku-4-5");
    expect(pricing.canonical("claude-opus-5-5[1m]")).toBe("claude-opus-5-5");
    expect(pricing.canonical("Haiku")).toBe("claude-haiku-4-5");
    expect(pricing.canonical("gpt-5.6-luna")).toBe("gpt-5.6-luna");
    expect(pricing.canonical("mystery")).toBeNull();
  });

  it("prices Codex tokens with cached input at the cache-read rate, and falls back per provider", () => {
    // gpt-5.6-luna: 0.20 in, 0.02 cache read, 1.20 out per 1M tokens.
    const usd = pricing.costUsd("codex", "gpt-5.6-luna", { input: 600_000, cacheRead: 400_000, cacheWrite: 0, output: 100_000 });
    expect(usd).toBeCloseTo(0.12 + 0.008 + 0.12, 9);
    expect(pricing.match("codex", "gpt-unknown")).toMatchObject({ id: "gpt-6-sol", fallback: true });
    expect(pricing.costHint("claude", "haiku")).toBe("$1.00 in / $5.00 out per 1M tokens");
    expect(pricing.models("codex")[0]).toBe("gpt-6-luna");
  });

  it("turns a running total into deltas", () => {
    const t = new RunningTotal(0.5);
    expect(t.update(0.5)).toBe(0);
    expect(t.update(0.5125)).toBe(12_500);
    expect(t.update(0.4)).toBe(0);
    expect(t.update(0.41)).toBe(10_000);
  });
});

describe("add-ons map to harness tools through economy.json", () => {
  it("Claude", () => {
    expect(claudePlan(tools, ["lectern"])).toEqual({ tools: ["Read", "Glob", "Grep"], charter: false, mcp: false });
    expect(claudePlan(tools, ["lectern", "quillworks", "forge", "rookery", "archive", "waygate"])).toEqual({
      tools: ["Read", "Glob", "Grep", "Edit", "Write", "Bash", "WebSearch", "WebFetch"],
      charter: true,
      mcp: true,
    });
  });

  it("Codex", () => {
    expect(codexPlan(tools, ["lectern"])).toEqual({ sandbox: "read-only", commands: false, webSearch: "disabled", charter: false, mcp: false });
    expect(codexPlan(tools, ["lectern", "quillworks", "forge", "rookery", "waygate"])).toEqual({
      sandbox: "workspace-write",
      commands: true,
      webSearch: "live",
      charter: false,
      mcp: true,
    });
  });

  it("pi", () => {
    const plan = piPlan(tools, ["lectern", "quillworks", "forge", "rookery", "archive"]);
    expect(plan.tools).toEqual(["read", "grep", "find", "ls", "edit", "write", "bash"]);
    expect(plan.charter).toBe(true);
    expect(plan.unavailable).toEqual([{ type: "rookery", note: expect.stringMatching(/no built-in web/) }]);
  });
});

describe("Waygate configs name secrets, never copy them", () => {
  const stdio = { server_name: "github", transport: "stdio" as const, command: "npx", args: ["-y", "gh-mcp"], env_refs: ["GH_TOKEN"], allowed_tools: ["search"] };
  const http = { server_name: "docs.site", transport: "http" as const, url: "https://mcp.example.invalid", header_refs: { Authorization: "DOCS_AUTH" } };

  it("Claude Code and pi use ${VAR} references", () => {
    expect(claudeMcpServer(stdio)).toEqual({ type: "stdio", command: "npx", args: ["-y", "gh-mcp"], env: { GH_TOKEN: "${GH_TOKEN}" } });
    expect(claudeMcpServer(http)).toEqual({ type: "http", url: "https://mcp.example.invalid", headers: { Authorization: "${DOCS_AUTH}" } });
    expect(piMcpServer(http)).toEqual({ name: "docs_site", config: { url: "https://mcp.example.invalid", headers: { Authorization: "${DOCS_AUTH}" }, exposure: "direct" } });
  });

  it("Codex forwards variables by name and asks before every tool", () => {
    expect(codexMcpOverrides(stdio)).toEqual([
      'mcp_servers.github.command="npx"',
      'mcp_servers.github.args=["-y", "gh-mcp"]',
      'mcp_servers.github.env_vars=["GH_TOKEN"]',
      'mcp_servers.github.enabled_tools=["search"]',
      'mcp_servers.github.default_tools_approval_mode="prompt"',
    ]);
    expect(codexMcpOverrides(http)).toEqual([
      'mcp_servers.docs_site.url="https://mcp.example.invalid"',
      'mcp_servers.docs_site.env_http_headers={ "Authorization" = "DOCS_AUTH" }',
      'mcp_servers.docs_site.default_tools_approval_mode="prompt"',
    ]);
  });

  it("skips reserved, duplicate and incomplete Waygates", () => {
    const { usable, skipped } = usableWaygates([stdio, { ...stdio }, { server_name: "aurelhaven", transport: "stdio", command: "x" }, { server_name: "empty", transport: "http" }]);
    expect(usable).toEqual([stdio]);
    expect(skipped.map((s) => s.name)).toEqual(["github", "aurelhaven", "empty"]);
  });

  it("compares names the way the harnesses see them", () => {
    expect(mcpServerName("docs.site")).toBe("docs_site");
    const clash = { ...http, server_name: "docs_site" };
    const { usable, skipped } = usableWaygates([http, clash, { ...stdio, server_name: "Aurel.haven" }, { ...stdio, server_name: "AURELHAVEN" }]);
    expect(usable).toEqual([http, { ...stdio, server_name: "Aurel.haven" }]);
    expect(skipped).toEqual([
      { name: "docs_site", reason: "another Waygate has the same name" },
      { name: "AURELHAVEN", reason: "the name is reserved" },
    ]);
  });
});

describe("Codex permission requests", () => {
  const work = path.resolve("/work/app");
  const parse = (raw: unknown) => parsePermissionRequest(raw, work, work);
  const entry = (p: unknown, access = "read") => ({ network: null, fileSystem: { read: null, write: null, entries: [{ path: p, access }] } });

  it("treats only plain paths inside the work folder as inside", () => {
    expect(insideWorkspace("src/a.ts", work, work)).toBe(true);
    expect(insideWorkspace(path.join(work, "..", "other"), work, work)).toBe(false);
    expect(insideWorkspace("~/.ssh", work, work)).toBe(false);
    expect(insideWorkspace("$HOME/x", work, work)).toBe(false);
    expect(insideWorkspace("%USERPROFILE%\\x", work, work)).toBe(false);
    expect(parse(entry({ type: "glob_pattern", pattern: "src/**" }))!.files).toEqual([{ access: "read", label: "files matching src/**", inside: false }]);
    expect(parse(entry({ type: "special", value: { kind: "project_roots", subpath: "docs" } }))!.files[0]).toMatchObject({ label: "the project roots (docs)", inside: false });
  });

  it("returns null for anything it does not understand", () => {
    expect(parse(null)).toBeNull();
    expect(parse({ network: { enabled: "yes" }, fileSystem: null })).toBeNull();
    expect(parse({ network: { enabled: true, proxy: "x" }, fileSystem: null })).toBeNull();
    expect(parse({ network: null, fileSystem: { read: [3], write: null } })).toBeNull();
    expect(parse(entry({ type: "special", value: { kind: "everything" } }))).toBeNull();
    expect(parse(entry({ type: "path", path: "a" }, "execute"))).toBeNull();
    expect(parse({ network: null, fileSystem: { read: null, write: null, extra: [] } })).toBeNull();
  });

  it("keeps blocked paths in the grant and out of the category", () => {
    const req = parse({
      network: null,
      fileSystem: {
        read: null,
        write: ["src"],
        entries: [{ path: { type: "path", path: path.resolve("/etc/secrets") }, access: "deny" }],
        globScanMaxDepth: 3,
      },
    })!;
    expect(req.profile).toEqual({
      fileSystem: { read: null, write: ["src"], entries: [{ path: { type: "path", path: path.resolve("/etc/secrets") }, access: "deny" }], globScanMaxDepth: 3 },
    });
    const approval = permissionApproval(req, "to build");
    expect(approval).toMatchObject({ tool: "file_access", category: "write", reason: "to build" });
    expect(approval.summary).toMatch(/^Allow write access to src for this turn \(keeping .*secrets blocked\)$/);
    expect(parse({ network: { enabled: false }, fileSystem: null })).toEqual({ network: false, files: [], profile: {} });
  });
});

describe("task framing", () => {
  const names = framingNames(econ.data);

  it("appends the role, rules, task, acceptance criteria and the Oath", () => {
    const text = systemPromptFor(runRequest(path.resolve("/work/app")), { names, notes: ["Commands run in PowerShell 7."] });
    expect(text).toContain("You are an agent of the town of Aurelhaven. Your role: Artificer (Coding).");
    expect(text).toContain("## Task: Greet the town");
    expect(text).toContain("Size: Errand.");
    expect(text).toContain("- hello.txt exists");
    expect(text).toContain("- Commands run in PowerShell 7.");
    expect(text).toMatch(/## Your Oath \(the player's standing instructions\)\nBe careful\.$/);
  });

  it("chooses the first message for fresh, resumed and restarted attempts", () => {
    const req = runRequest("/w");
    expect(firstMessageFor(req, false)).toBe("Write hello.txt");
    const resumed = { ...req, resume: { sessionId: "s", state: null, feedback: "Warmer" } };
    expect(firstMessageFor(resumed, true)).toBe(feedbackMessage("Warmer"));
    expect(firstMessageFor(resumed, false)).toMatch(/^Write hello\.txt\n\nThe player reviewed an earlier attempt/);
    expect(firstMessageFor({ ...req, resume: { sessionId: "s", state: null, feedback: null } }, true)).toMatch(/resumed it/);
  });
});

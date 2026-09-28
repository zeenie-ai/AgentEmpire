import { describe, expect, it } from "vitest";
import { canonicalJson, inputHash, signatureOf, autoAllowed } from "../../src/core/approvals.js";
import { Economy } from "../../src/core/economy.js";
import { compileFormula } from "../../src/core/expr.js";
import { TestClock } from "../../src/core/clock.js";
import { parseNameStatusZ, parseNumstatZ } from "../../src/core/workspace.js";
import { defaultEconomyPath } from "../../src/paths.js";
import { capBytes, Redactor, tailBytes } from "../../src/security/redact.js";
import { generateToken, tokensEqual } from "../../src/security/token.js";
import { renderGd } from "../../scripts/gen-gd.js";

describe("economy.json", () => {
  it("loads and validates", () => {
    const econ = Economy.load(defaultEconomyPath());
    expect(econ.agentLimit(1)).toBe(2);
    expect(econ.toolSlots(2)).toBe(5);
    expect(econ.queueLimit(2)).toBe(3);
    expect(econ.storageCap(1, 2)).toBe(800 + 600);
    expect(econ.manaToMicros(1)).toBe(10_000);
  });
});

describe("formula evaluator", () => {
  it("evaluates the economy.json formulas", () => {
    expect(compileFormula("50 * L * (L - 1)")({ L: 3 })).toBe(300);
    const bounty = compileFormula("RP = min(BASE * (1 + Q + E + P) * D, CEIL)");
    expect(bounty({ BASE: 100, Q: 0.5, E: 0, P: 0, D: 1, CEIL: 120 })).toBe(120);
    expect(compileFormula("-2 + 3 * (4 - 1) / 3")({})).toBe(1);
  });

  it("rejects unknown variables and bad syntax", () => {
    expect(() => compileFormula("L +")).toThrow();
    expect(() => compileFormula("50 * X")({ L: 1 })).toThrow(/unknown variable/);
    expect(() => compileFormula("process.exit(1)")).toThrow();
  });
});

describe("redaction", () => {
  const r = new Redactor(["launch-token-1234567890"], {});

  it("removes keys, bearer tokens, passwords and the launch token", () => {
    const text = [
      "key sk-ant-api03-abcdefghijklmnopqrstuv",
      "openai sk-proj-abcdefghijklmnopqrstuvwxyz123456",
      "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
      "password=hunter22",
      "ghp_abcdefghijklmnopqrstuvwxyz0123",
      "token launch-token-1234567890",
    ].join("\n");
    const out = r.redact(text);
    expect(out).not.toMatch(/sk-ant-api03|sk-proj-abc|abcdefghijklmnopqrstuvwxyz\b|hunter22|ghp_|launch-token/);
    expect(out).toContain("[REDACTED]");
    expect(r.redact("npm test -- --watch")).toBe("npm test -- --watch");
  });

  it("caps text by bytes from the front or the back", () => {
    expect(capBytes("abcdef", 100)).toBe("abcdef");
    expect(Buffer.byteLength(capBytes("x".repeat(5000), 2048))).toBeLessThanOrEqual(2048);
    expect(tailBytes("abcdef", 3)).toBe("def");
    // Each e-acute is two UTF-8 bytes; a 3-byte tail must not start with half a character.
    const eAcute = String.fromCharCode(0xe9);
    expect(tailBytes(eAcute.repeat(3), 3)).toBe(eAcute);
  });
});

describe("tokens", () => {
  it("are 32 random bytes in base64url and compare in constant time", () => {
    const t = generateToken();
    expect(t).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(Buffer.from(t, "base64url")).toHaveLength(32);
    expect(generateToken()).not.toBe(t);
    expect(tokensEqual(t, t)).toBe(true);
    expect(tokensEqual(t, `${t}x`)).toBe(false);
    expect(tokensEqual(t, undefined)).toBe(false);
  });
});

describe("approval helpers", () => {
  it("hashes inputs canonically", () => {
    expect(canonicalJson({ b: 1, a: [2, { d: 1, c: 2 }] })).toBe('{"a":[2,{"c":2,"d":1}],"b":1}');
    expect(inputHash("Bash", { command: "x", cwd: "y" })).toBe(inputHash("Bash", { cwd: "y", command: "x" }));
    expect(inputHash("Bash", { command: "x" })).not.toBe(inputHash("Bash", { command: "y" }));
  });

  it("derives rule signatures and mode policies", () => {
    expect(signatureOf("Bash", "command", { command: "npm   test --watch" })).toBe("npm test");
    expect(signatureOf("WebFetch", "network", { url: "https://Docs.Example.com/a" })).toBe("docs.example.com");
    expect(autoAllowed("trusted_edits", "write")).toBe(true);
    expect(autoAllowed("trusted_edits", "command")).toBe(false);
    expect(autoAllowed("ask_every_time", "read")).toBe(false);
    expect(autoAllowed("free_hand", "outside_workspace")).toBe(false);
  });
});

describe("git output parsers", () => {
  it("parses numstat with renames and binaries", () => {
    const out = "3\t1\tsrc/a.ts\0-\t-\timg.png\0" + "2\t0\t\0old.txt\0new.txt\0";
    const m = parseNumstatZ(out);
    expect(m.get("src/a.ts")).toEqual({ added: 3, removed: 1 });
    expect(m.get("img.png")).toEqual({ added: 0, removed: 0 });
    expect(m.get("new.txt")).toEqual({ added: 2, removed: 0 });
  });

  it("parses name-status with renames", () => {
    const out = "M\0src/a.ts\0A\0b.txt\0R087\0old.txt\0new.txt\0D\0gone.md\0";
    expect(parseNameStatusZ(out)).toEqual([
      { status: "modified", path: "src/a.ts" },
      { status: "added", path: "b.txt" },
      { status: "renamed", from: "old.txt", path: "new.txt" },
      { status: "deleted", path: "gone.md" },
    ]);
  });
});

describe("test clock", () => {
  it("fires due timers in order when advanced", () => {
    const clock = new TestClock(() => 1_000);
    const fired: string[] = [];
    clock.setTimeout(() => fired.push("b"), 200);
    clock.setTimeout(() => fired.push("a"), 100);
    const h = clock.setTimeout(() => fired.push("never"), 150);
    clock.clearTimeout(h);
    clock.advance(250);
    expect(fired).toEqual(["a", "b"]);
    expect(clock.now()).toBe(1_250);
  });
});

describe("gen:gd", () => {
  it("renders GDScript constants from the schemas", () => {
    const gd = renderGd();
    expect(gd).toContain('const CMD_HELLO := "hello"');
    expect(gd).toContain('const EVT_TASK_UPDATED := "task_updated"');
    expect(gd).toContain('const ERR_SESSION_BUSY := "SESSION_BUSY"');
    expect(gd).toContain("const CLOSE_BAD_TOKEN := 4001");
    expect(gd).toContain("class TaskState:\n\tconst IN_TRANSIT := \"in_transit\"");
    expect(gd).toContain("class IncidentKind:");
    expect(gd).toContain("class ApprovalCategory:");
    expect(gd).toContain("class AgentLifecycle:");
    expect(gd).toContain("\tconst XL := \"XL\"");
    expect(gd).not.toMatch(/[\u{1F300}-\u{1FAFF}]/u);
  });
});

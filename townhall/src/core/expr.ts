/**
 * A tiny arithmetic evaluator for the formula strings in economy.json
 * (for example "50 * L * (L - 1)" or "RP = min(BASE * (1 + Q + E + P) * D, CEIL)").
 * Supports numbers, variables, + - * /, parentheses, unary minus and min/max/floor/ceil/round.
 */

type Token =
  | { kind: "num"; value: number }
  | { kind: "id"; value: string }
  | { kind: "op"; value: string };

const FUNCTIONS: Record<string, (...args: number[]) => number> = {
  min: (...a) => Math.min(...a),
  max: (...a) => Math.max(...a),
  floor: (a) => Math.floor(a ?? 0),
  ceil: (a) => Math.ceil(a ?? 0),
  round: (a) => Math.round(a ?? 0),
};

function tokenize(src: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < src.length) {
    const ch = src[i]!;
    if (/\s/.test(ch)) {
      i++;
    } else if (/[0-9.]/.test(ch)) {
      let j = i;
      while (j < src.length && /[0-9.]/.test(src[j]!)) j++;
      const value = Number(src.slice(i, j));
      if (!Number.isFinite(value)) throw new Error(`bad number in formula: ${src.slice(i, j)}`);
      tokens.push({ kind: "num", value });
      i = j;
    } else if (/[A-Za-z_]/.test(ch)) {
      let j = i;
      while (j < src.length && /[A-Za-z0-9_]/.test(src[j]!)) j++;
      tokens.push({ kind: "id", value: src.slice(i, j) });
      i = j;
    } else if ("+-*/(),".includes(ch)) {
      tokens.push({ kind: "op", value: ch });
      i++;
    } else {
      throw new Error(`unexpected character in formula: ${ch}`);
    }
  }
  return tokens;
}

export type Formula = (vars: Record<string, number>) => number;

/** Compiles a formula; a leading `NAME =` is ignored. */
export function compileFormula(source: string): Formula {
  const body = source.replace(/^\s*[A-Za-z_][A-Za-z0-9_]*\s*=(?!=)/, "");
  const tokens = tokenize(body);
  // Validate by parsing once with every identifier bound to 1.
  const probe = new Parser(tokens, new Proxy({}, { get: () => 1 }));
  probe.parseAll();
  return (vars) => new Parser(tokens, vars).parseAll();
}

class Parser {
  private pos = 0;

  constructor(
    private readonly tokens: Token[],
    private readonly vars: Record<string, number>,
  ) {}

  parseAll(): number {
    const v = this.expr();
    if (this.pos !== this.tokens.length) throw new Error("unexpected trailing tokens in formula");
    return v;
  }

  private peek(): Token | undefined {
    return this.tokens[this.pos];
  }

  private takeOp(op: string): boolean {
    const t = this.peek();
    if (t && t.kind === "op" && t.value === op) {
      this.pos++;
      return true;
    }
    return false;
  }

  private expr(): number {
    let v = this.term();
    for (;;) {
      if (this.takeOp("+")) v += this.term();
      else if (this.takeOp("-")) v -= this.term();
      else return v;
    }
  }

  private term(): number {
    let v = this.unary();
    for (;;) {
      if (this.takeOp("*")) v *= this.unary();
      else if (this.takeOp("/")) v /= this.unary();
      else return v;
    }
  }

  private unary(): number {
    if (this.takeOp("-")) return -this.unary();
    if (this.takeOp("+")) return this.unary();
    return this.primary();
  }

  private primary(): number {
    const t = this.tokens[this.pos++];
    if (!t) throw new Error("unexpected end of formula");
    if (t.kind === "num") return t.value;
    if (t.kind === "op" && t.value === "(") {
      const v = this.expr();
      if (!this.takeOp(")")) throw new Error("missing ) in formula");
      return v;
    }
    if (t.kind === "id") {
      const fn = FUNCTIONS[t.value];
      if (fn && this.takeOp("(")) {
        const args: number[] = [];
        if (!this.takeOp(")")) {
          do {
            args.push(this.expr());
          } while (this.takeOp(","));
          if (!this.takeOp(")")) throw new Error("missing ) after function arguments");
        }
        return fn(...args);
      }
      const value = this.vars[t.value];
      if (typeof value !== "number") throw new Error(`unknown variable in formula: ${t.value}`);
      return value;
    }
    throw new Error(`unexpected token in formula: ${t.value}`);
  }
}

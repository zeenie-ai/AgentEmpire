import { StringDecoder } from "node:string_decoder";

/** Records longer than this are dropped rather than buffered without bound. */
export const MAX_RECORD_CHARS = 64 * 1024 * 1024;

/**
 * Strict JSON Lines decoder for harness stdout: one JSON value per line, split on LF only.
 * A CR before the LF is stripped. Unicode line and paragraph separators (U+2028, U+2029) are
 * valid inside JSON strings and never end a record, which is why Node's readline is not used.
 */
export class JsonlDecoder {
  private readonly decoder = new StringDecoder("utf8");
  private buffer = "";
  /** Where the next search for "\n" starts, so long records are not rescanned per chunk. */
  private scanFrom = 0;
  private dropping = false;

  constructor(
    private readonly onRecord: (value: unknown) => void,
    private readonly onBadLine: (line: string) => void = () => undefined,
    private readonly maxRecordChars = MAX_RECORD_CHARS,
  ) {}

  push(chunk: Buffer | string): void {
    this.buffer += typeof chunk === "string" ? chunk : this.decoder.write(chunk);
    for (;;) {
      const newline = this.buffer.indexOf("\n", this.scanFrom);
      if (newline < 0) break;
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      this.scanFrom = 0;
      if (this.dropping) {
        this.dropping = false;
        continue;
      }
      this.emit(line);
    }
    this.scanFrom = this.buffer.length;
    if (this.buffer.length > this.maxRecordChars) {
      // Skip the rest of an oversized record up to its newline.
      this.buffer = "";
      this.scanFrom = 0;
      this.dropping = true;
      this.onBadLine("[oversized record dropped]");
    }
  }

  /** Flushes a final record that had no trailing newline. */
  end(): void {
    this.buffer += this.decoder.end();
    const rest = this.buffer;
    this.buffer = "";
    this.scanFrom = 0;
    if (!this.dropping && rest.length > 0) this.emit(rest);
    this.dropping = false;
  }

  private emit(raw: string): void {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (line.trim() === "") return;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch {
      this.onBadLine(line);
      return;
    }
    this.onRecord(value);
  }
}

/** One JSON Lines record: the value as JSON plus a single LF. */
export function encodeJsonl(value: unknown): string {
  return `${JSON.stringify(value)}\n`;
}

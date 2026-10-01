// Downloads with a progress line and checksum verification, for the setup and release scripts.
import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync, mkdirSync, renameSync, rmSync } from 'node:fs';
import { basename, dirname } from 'node:path';

/** The hex digest of a file, read in chunks (archives can be over a gigabyte). */
export async function fileHash(file, algorithm) {
  const hash = createHash(algorithm);
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

/** Fetches a small text file (a checksum list). */
export async function fetchText(url) {
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(`could not download ${url} (HTTP ${res.status})`);
  return res.text();
}

/** The checksum for `name` in a "<hex>  <file name>" list (SHA512-SUMS.txt, SHASUMS256.txt). */
export function checksumFor(list, name) {
  for (const line of list.split(/\r?\n/)) {
    const m = /^([0-9a-f]{64,128})\s+\*?(.+)$/i.exec(line.trim());
    if (m && m[2].trim() === name) return m[1].toLowerCase();
  }
  throw new Error(`no checksum listed for ${name}`);
}

/**
 * Downloads `url` to `dest` and checks it against `expected` ({ algorithm, digest }). A file
 * already at `dest` with the right digest is reused, so interrupted setups resume cheaply.
 */
export async function download(url, dest, expected) {
  if (existsSync(dest) && (await fileHash(dest, expected.algorithm)) === expected.digest) return dest;
  mkdirSync(dirname(dest), { recursive: true });
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok || !res.body) throw new Error(`could not download ${url} (HTTP ${res.status})`);
  const total = Number(res.headers.get('content-length') ?? 0);
  const part = `${dest}.part`;
  const out = createWriteStream(part);
  const hash = createHash(expected.algorithm);
  let received = 0;
  let shown = 0;
  const label = basename(dest);
  for await (const chunk of res.body) {
    hash.update(chunk);
    received += chunk.length;
    if (!out.write(chunk)) await new Promise((resolve) => out.once('drain', resolve));
    if (process.stdout.isTTY && Date.now() - shown > 500) {
      shown = Date.now();
      const mb = (n) => (n / 1048576).toFixed(0);
      const pct = total ? ` (${Math.floor((received / total) * 100)}%)` : '';
      process.stdout.write(`\r   ${label}: ${mb(received)}${total ? ` of ${mb(total)}` : ''} MB${pct}   `);
    }
  }
  await new Promise((resolve, reject) => out.end((err) => (err ? reject(err) : resolve())));
  if (process.stdout.isTTY) process.stdout.write('\n');
  const digest = hash.digest('hex');
  if (digest !== expected.digest) {
    rmSync(part, { force: true });
    throw new Error(`${label} failed its ${expected.algorithm} check; the download may be corrupt, try again`);
  }
  renameSync(part, dest);
  return dest;
}

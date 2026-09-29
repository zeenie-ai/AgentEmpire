#!/usr/bin/env node
// Copies the shared protocol files into the Godot client, byte for byte:
// - protocol/economy.json (every cost, rate and threshold) -> client/data/economy.json,
//   loaded as res://data/economy.json;
// - protocol/generated/protocol.gd (message types and enums, generated from the Town Hall's
//   schemas by `npm run gen:gd` in townhall/) -> client/net/protocol.gd.
//
// Run it after EVERY change to either file:
//   node scripts/sync-economy.mjs          copy
//   node scripts/sync-economy.mjs --check  exit 1 if a client copy is out of date
//
// The client's GUT suite also compares the files (tests/unit/test_economy_data.gd).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const pairs = [
  { src: 'protocol/economy.json', dst: 'client/data/economy.json', json: true },
  { src: 'protocol/generated/protocol.gd', dst: 'client/net/protocol.gd', json: false },
];

const check = process.argv.includes('--check');
let stale = 0;
for (const p of pairs) {
  const text = readFileSync(resolve(root, p.src), 'utf8');
  if (p.json) {
    try {
      JSON.parse(text);
    } catch (err) {
      console.error(`${p.src} is not valid JSON: ${err.message}`);
      process.exit(2);
    }
  }
  const dst = resolve(root, p.dst);
  if (check) {
    const current = existsSync(dst) ? readFileSync(dst, 'utf8') : '';
    if (current !== text) {
      console.error(`${p.dst} is out of date. Run: node scripts/sync-economy.mjs`);
      stale++;
    } else {
      console.log(`${p.dst} is up to date.`);
    }
    continue;
  }
  mkdirSync(dirname(dst), { recursive: true });
  writeFileSync(dst, text);
  console.log(`Synced ${p.src} -> ${p.dst} (${text.length} bytes).`);
}
process.exit(stale > 0 ? 1 : 0);

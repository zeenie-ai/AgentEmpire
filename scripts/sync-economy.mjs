#!/usr/bin/env node
// Copies protocol/economy.json (the single source of truth for every cost, rate and
// threshold) to client/data/economy.json, which the Godot client loads as
// res://data/economy.json.
//
// Run it after EVERY change to protocol/economy.json:
//   node scripts/sync-economy.mjs          copy (byte-for-byte)
//   node scripts/sync-economy.mjs --check  exit 1 if the client copy is out of date
//
// The client's GUT suite also compares the two files (tests/unit/test_economy_data.gd).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const src = resolve(root, 'protocol', 'economy.json');
const dst = resolve(root, 'client', 'data', 'economy.json');

const text = readFileSync(src, 'utf8');
try {
  JSON.parse(text);
} catch (err) {
  console.error(`protocol/economy.json is not valid JSON: ${err.message}`);
  process.exit(2);
}

if (process.argv.includes('--check')) {
  const current = existsSync(dst) ? readFileSync(dst, 'utf8') : '';
  if (current !== text) {
    console.error('client/data/economy.json is out of date. Run: node scripts/sync-economy.mjs');
    process.exit(1);
  }
  console.log('client/data/economy.json is up to date.');
  process.exit(0);
}

mkdirSync(dirname(dst), { recursive: true });
writeFileSync(dst, text);
console.log(`Synced protocol/economy.json -> client/data/economy.json (${text.length} bytes).`);

#!/usr/bin/env node
// Writes the decoded call table of the vote script into README.md, between its two marker comments. The script is
// built from the source at a pinned block by CreateVote.s.sol, so the table is reproducible and CI fails when the
// source and the README disagree.
//
//   node scripts/update-readme.mjs <block>    builds at that block and names it in the table's header
//   node scripts/update-readme.mjs            builds at the block the header names, what CI runs
//
// Needs forge and the RPC from foundry.toml (FOUNDRY_ETH_RPC_URL overrides it), an archive one once the block is old.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';

const ROOT = new URL('..', import.meta.url);
const README = new URL('README.md', ROOT);
const START = '<!-- script-table -->';
const END = '<!-- /script-table -->';

const readme = readFileSync(README, 'utf8');
const start = readme.indexOf(START);
const end = readme.indexOf(END);
if (start === -1 || end === -1) {
  console.error(`README.md needs the markers ${START} and ${END}`);
  process.exit(1);
}
const block = process.argv[2] ?? readme.slice(start, end).match(/Built at block (\d+)/)?.[1];
if (!/^\d+$/.test(block ?? '')) {
  console.error('usage: node scripts/update-readme.mjs [block], or a "Built at block <n>" header between the markers');
  process.exit(1);
}

const run = (file, args) => execFileSync(file, args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
const rpcUrl = JSON.parse(run('forge', ['config', '--json'])).eth_rpc_url;
run('forge', ['script', 'script/CreateVote.s.sol', '--rpc-url', rpcUrl, '--fork-block-number', block]);
const [summary, ...table] = run('node', ['scripts/decode-script.mjs', 'proposal/generated/script.hex']).trim().split('\n');

const updated =
  readme.slice(0, start) +
  [START, '', `Built at block ${block}, ${summary}.`, ...table, '', END].join('\n') +
  readme.slice(end + END.length);
if (updated === readme) {
  console.log(`README.md table is current, block ${block}`);
} else {
  writeFileSync(README, updated);
  console.log(`README.md table updated, block ${block}`);
}

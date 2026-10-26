#!/usr/bin/env node
// Writes the decoded call table of proposal/generated/script.hex into README.md, between its two marker comments, so
// that the README always shows the committed bytes. CI runs it and fails when the README changes.
//
//   node scripts/update-readme.mjs
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';

const README = new URL('../README.md', import.meta.url);
const START = '<!-- script-table -->';
const END = '<!-- /script-table -->';

const { block } = JSON.parse(readFileSync(new URL('../proposal/generated/amounts.json', import.meta.url), 'utf8'));
const decoded = execFileSync('node', [new URL('decode-script.mjs', import.meta.url).pathname, 'proposal/generated/script.hex'], {
  encoding: 'utf8',
}).trim();
const [summary, ...table] = decoded.split('\n');
const block_ = [
  START,
  '',
  `Built at block ${block} ([proposal/generated/amounts.json](proposal/generated/amounts.json)), ${summary}.`,
  ...table,
  '',
  END,
].join('\n');

const readme = readFileSync(README, 'utf8');
const start = readme.indexOf(START);
const end = readme.indexOf(END);
if (start === -1 || end === -1) {
  console.error(`README.md needs the markers ${START} and ${END}`);
  process.exit(1);
}
const updated = readme.slice(0, start) + block_ + readme.slice(end + END.length);
if (updated === readme) {
  console.log('README.md table is current');
} else {
  writeFileSync(README, updated);
  console.log('README.md table updated');
}

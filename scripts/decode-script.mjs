#!/usr/bin/env node
// Prints the calls of a vote script as a markdown table, one row per call.
//
//   node scripts/decode-script.mjs proposal/generated/script.hex
//
// The script is split into (target, calldata) entries, a call the primary Agent forwards through `execute` is unwrapped,
// and the calldata is decoded against the signatures the migration vote can contain. Anything else is printed raw, so an
// unexpected call stands out. The names next to the addresses are labels this file assigns for readability (NAMES
// below), the addresses are what the script holds, and the output says so. A reading aid. VerifyVote.s.sol compares a
// posted script byte for byte with the source build. The fork tests exercise the source-built script.
// Needs `cast` for the hashes. Read-only, no dependencies.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const NAMES = {
  '0x0b38210ea11411557c13457d4da7dc6ea731b88a': 'API3 token',
  '0x6dd655f10d4b9e242ae186d9050b68f725c76d76': 'API3 pool',
  '0xdb6c812e439ce5c740570578681ea7aadba5170b': 'primary voting app',
  '0x1c8058e72e4902b3431ef057e8d9a58a73f26372': 'secondary voting app',
  '0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae': 'primary Agent',
  '0x556ecbb0311d350491ba0ec7e019c354d7723ce0': 'secondary Agent',
  '0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a': 'ACL',
  '0x593ea926ee9820a933488b6a288433c387d06dba': 'Kernel',
  '0x8e03609ed680b237c7b6f8020472ca0687308b24': 'Vault Safe',
  '0xb7fa2cb302c5dc127e61f27b92bec411cbf0ae4a': 'Treasury Safe',
  '0xbbe0de9757f93e3306adbfebe906ab285edd13da': 'agent multisig',
  '0x000000000000000000000000000000000000dead': 'dead address',
  '0xffffffffffffffffffffffffffffffffffffffff': 'any address',
  '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48': 'USDC',
  '0x93ed3fbe21207ec2e8f2d3c3de6e058cb73bc04d': 'PNK',
  '0x67f4c72a50f8df6487720261e188f2abe83f57d7': 'wPOKT',
};
const DECIMALS = { USDC: 6, PNK: 18, wPOKT: 6, 'API3 token': 18 };
const ROLES = [
  'CREATE_VOTES_ROLE',
  'MODIFY_SUPPORT_ROLE',
  'MODIFY_QUORUM_ROLE',
  'TRANSFER_ROLE',
  'EXECUTE_ROLE',
  'CREATE_PERMISSIONS_ROLE',
  'APP_MANAGER_ROLE',
];
const SIGNATURES = [
  'grantPermission(address,address,bytes32)',
  'revokePermission(address,address,bytes32)',
  'removePermissionManager(address,bytes32)',
  'transfer(address,address,uint256)',
  'execute(address,uint256,bytes)',
  'updateMinterStatus(address,bool)',
  'mint(address,uint256)',
  'transferOwnership(address)',
  'changeSupportRequiredPct(uint64)',
  'changeMinAcceptQuorumPct(uint64)',
];
const AGENT = '0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae';

const cast = (...args) => execFileSync('cast', args, { encoding: 'utf8' }).trim();

const ROLE_NAMES = Object.fromEntries(ROLES.map((role) => [cast('keccak', role), role]));
const SELECTORS = Object.fromEntries(SIGNATURES.map((signature) => [cast('sig', signature), signature]));
const EXECUTE = cast('sig', 'execute(address,uint256,bytes)');

const word = (data, i) => data.slice(64 * i, 64 * (i + 1));

// (target, value, inner calldata) of an execute(address,uint256,bytes) calldata, selector included
const decodeExecute = (data) => {
  const body = data.slice(8);
  const target = `0x${word(body, 0).slice(24)}`;
  const value = BigInt(`0x${word(body, 1)}`);
  const offset = Number(BigInt(`0x${word(body, 2)}`)) * 2;
  const length = Number(BigInt(`0x${body.slice(offset, offset + 64)}`)) * 2;
  return { target, value, inner: body.slice(offset + 64, offset + 64 + length) };
};

const name = (address) => {
  const label = NAMES[address.toLowerCase()];
  return label ? `${label} \`${address}\`` : `\`${address}\``;
};

const units = (value, decimals) => {
  const text = value.toString().padStart(decimals + 1, '0');
  const whole = text.slice(0, text.length - decimals) || '0';
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')}.${text.slice(text.length - decimals).padEnd(6, '0').slice(0, 6)}`;
};

const amount = (value, token) => {
  const decimals = DECIMALS[token];
  return decimals === undefined ? value.toString() : `${value} (${units(value, decimals)} ${token})`;
};

const eth = (wei) => `${wei} wei (${units(wei, 18)} ETH)`;

// Function name and decoded arguments of a call, or the raw calldata when the selector is unknown
const describe = (target, value, data) => {
  if (data === '') return `plain ETH transfer of ${eth(value)}`;
  const selector = `0x${data.slice(0, 8)}`;
  const body = data.slice(8);
  const signature = SELECTORS[selector];
  if (!signature) return `unknown selector \`${selector}\`, calldata \`0x${data}\``;
  const [fname, typeList] = signature.slice(0, -1).split('(');
  if (fname === 'execute') {
    const { target: innerTarget, value: innerValue, inner } = decodeExecute(data);
    const innerCall = inner ? describe(innerTarget, 0n, inner) : 'no calldata';
    return `\`execute\`(${name(innerTarget)}, ${eth(innerValue)}, ${innerCall})`;
  }
  const args = [];
  let token;
  typeList.split(',').forEach((kind, i) => {
    const w = word(body, i);
    if (kind === 'address') {
      const address = `0x${w.slice(24)}`;
      args.push(name(address));
      if (i === 0 && fname === 'transfer') token = NAMES[address];
    } else if (kind === 'bytes32') {
      args.push(ROLE_NAMES[`0x${w}`] ?? `0x${w}`);
    } else if (kind === 'bool') {
      args.push(String(BigInt(`0x${w}`) !== 0n));
    } else {
      const n = BigInt(`0x${w}`);
      if (fname === 'mint') args.push(amount(n, NAMES[target.toLowerCase()]));
      else if (fname === 'transfer') args.push(amount(n, token));
      else args.push(n.toString());
    }
  });
  const text = `\`${fname}\`(${args.join(', ')})`;
  return value ? `${text} with ${value} wei` : text;
};

const main = (path) => {
  const script = path.startsWith('0x') ? path : readFileSync(path, 'utf8').trim();
  const data = script.startsWith('0x') ? script.slice(2) : script;
  if (data.slice(0, 8) !== '00000001') {
    console.error(`not a CallsScript, spec id 0x${data.slice(0, 8)}`);
    process.exit(1);
  }
  const rows = [];
  let offset = 8;
  while (offset < data.length) {
    const target = `0x${data.slice(offset, offset + 40)}`;
    const length = Number(BigInt(`0x${data.slice(offset + 40, offset + 48)}`)) * 2;
    const calldata = data.slice(offset + 48, offset + 48 + length);
    if (calldata.length !== length) {
      console.error(`truncated calldata in call ${rows.length + 1}`);
      process.exit(1);
    }
    offset += 48 + length;
    if (target === AGENT && `0x${calldata.slice(0, 8)}` === EXECUTE) {
      const { target: innerTarget, value, inner } = decodeExecute(calldata);
      rows.push(['via primary Agent', innerTarget, describe(innerTarget, value, inner)]);
    } else {
      rows.push(['voting app', target, describe(target, 0n, calldata)]);
    }
  }
  console.log(`${rows.length} calls, ${data.length / 2} bytes\n`);
  console.log('| # | caller | target | call |');
  console.log('| - | ------ | ------ | ---- |');
  rows.forEach(([caller, target, call], i) => console.log(`| ${i + 1} | ${caller} | ${name(target)} | ${call} |`));
  console.log(
    '\nThe names next to the addresses are labels this decoder assigns for readability, they are not part of the script. The addresses are what the script holds, check them against the proposal.',
  );
};

if (process.argv.length !== 3) {
  console.error('usage: node scripts/decode-script.mjs <script.hex file or 0x bytes>');
  process.exit(1);
}
main(process.argv[2]);

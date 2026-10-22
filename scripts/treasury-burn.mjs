#!/usr/bin/env node
// The fallback after a late execution: when one more reward epoch was minted between posting and execution, the supply
// overshoots 200,000,000 API3 by that reward and the Treasury Safe, which received the mint, burns the excess. This
// prints the two calls as calldata and writes a Safe Transaction Builder batch for them, with the amount read from the
// chain at the moment it runs. Nothing is proposed or sent, the signers create the Safe transaction themselves.
//
//   node scripts/treasury-burn.mjs [--block <number>] [--out proposal/generated/treasury-burn.json]
//
// Needs `cast` and ETH_RPC_URL. Read-only, no dependencies.
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const API3 = '0x0b38210ea11411557c13457D4dA7dC6ea731B88a';
const POOL = '0x6dd655f10d4b9E242aE186D9050B68F725c76d76';
const TREASURY_SAFE = '0xb7fa2Cb302C5dC127e61F27b92beC411cbf0AE4A';
const DEAD = '0x000000000000000000000000000000000000dEaD';
const TARGET_SUPPLY = 200_000_000n * 10n ** 18n;
const CHAIN_ID = 1;
// The Transaction Builder release whose batch file format this follows
const TX_BUILDER_VERSION = '1.18.3';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index === -1 ? fallback : args[index + 1];
};
const block = option('--block');
const out = option('--out', 'proposal/generated/treasury-burn.json');
const rpcUrl = process.env.ETH_RPC_URL;
if (!rpcUrl) {
  console.error('set ETH_RPC_URL to a mainnet RPC');
  process.exit(1);
}

const cast = (...castArgs) => execFileSync('cast', castArgs, { encoding: 'utf8' }).trim();
const call = (to, signature, ...callArgs) =>
  cast('call', to, signature, ...callArgs, '--rpc-url', rpcUrl, ...(block ? ['--block', block] : []));
const uint = (text) => BigInt(text.split(' ')[0]);

const units = (value, decimals = 18) => {
  const text = value.toString().padStart(decimals + 1, '0');
  const whole = text.slice(0, text.length - decimals) || '0';
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')}.${text.slice(text.length - decimals).padEnd(6, '0').slice(0, 6)}`;
};

// A port of the Transaction Builder's serializeJSONObject: keys of every object hashed in sorted order
const serialize = (json) => {
  if (Array.isArray(json)) return `[${json.map((element) => serialize(element)).join(',')}]`;
  if (typeof json !== 'object' || json === null) return JSON.stringify(json === undefined ? null : json);
  const keys = Object.keys(json).sort();
  let serialized = `{${JSON.stringify(keys)}`;
  for (const key of keys) serialized += `${serialize(json[key])},`;
  return `${serialized}}`;
};
// The Transaction Builder warns on import when the checksum does not match the file, which it computes without the
// batch name and without the checksum itself
const checksum = (file) => cast('keccak', serialize({ ...file, meta: { ...file.meta, name: null } }));

const blockNumber = block ?? cast('block-number', '--rpc-url', rpcUrl);
const supply = uint(call(API3, 'totalSupply()(uint256)'));
const treasuryBalance = uint(call(API3, 'balanceOf(address)(uint256)', TREASURY_SAFE));
const owner = call(API3, 'owner()(address)');
const poolMints = call(API3, 'getMinterStatus(address)(bool)', POOL) === 'true';
const treasuryBurns = call(API3, 'getBurnerStatus(address)(bool)', TREASURY_SAFE) === 'true';

console.log(`block ${blockNumber}`);
console.log(`total supply        ${supply} (${units(supply)} API3)`);
console.log(`Treasury Safe API3  ${treasuryBalance} (${units(treasuryBalance)} API3)`);
console.log(`token owner         ${owner}${owner.toLowerCase() === DEAD.toLowerCase() ? ' (dead, the vote executed)' : ' (the vote has not executed)'}`);
console.log(`pool mints          ${poolMints}`);
console.log(`Treasury Safe burns ${treasuryBurns}`);

if (supply <= TARGET_SUPPLY) {
  console.log(`\nNothing to burn: the supply is ${units(TARGET_SUPPLY - supply)} API3 at or below the target. The vote lands on the target on time, or has not executed yet.`);
  process.exit(1);
}
const excess = supply - TARGET_SUPPLY;
console.log(`\nexcess              ${excess} (${units(excess)} API3)`);
if (treasuryBalance < excess) {
  console.log('The Treasury Safe holds less than the excess, nothing to paste.');
  process.exit(1);
}

const calls = [
  // Skipped once the Safe is a burner already, the token refuses a no-op status update
  ...(treasuryBurns
    ? []
    : [
        {
          signature: 'updateBurnerStatus(bool burnerStatus)',
          name: 'updateBurnerStatus',
          inputs: [{ internalType: 'bool', name: 'burnerStatus', type: 'bool' }],
          values: { burnerStatus: 'true' },
          calldata: cast('calldata', 'updateBurnerStatus(bool)', 'true'),
        },
      ]),
  {
    signature: 'burn(uint256 amount)',
    name: 'burn',
    inputs: [{ internalType: 'uint256', name: 'amount', type: 'uint256' }],
    values: { amount: excess.toString() },
    calldata: cast('calldata', 'burn(uint256)', excess.toString()),
  },
];

console.log(`\n${calls.length} calls from the Treasury Safe ${TREASURY_SAFE} to the API3 token ${API3}, value 0:\n`);
for (const [index, { signature, values, calldata }] of calls.entries()) {
  console.log(`${index + 1}. ${signature} with ${JSON.stringify(values)}`);
  console.log(`   ${calldata}`);
}

const file = {
  version: '1.0',
  chainId: CHAIN_ID.toString(),
  createdAt: Date.now(),
  meta: {
    name: `Burn the ${units(excess)} API3 overshoot`,
    description: `Supply ${units(supply)} API3 at block ${blockNumber}, target 200,000,000`,
    txBuilderVersion: TX_BUILDER_VERSION,
    createdFromSafeAddress: TREASURY_SAFE,
    createdFromOwnerAddress: '',
  },
  transactions: calls.map(({ name, inputs, values }) => ({
    to: API3,
    value: '0',
    data: null,
    contractMethod: { inputs, name, payable: false },
    contractInputsValues: values,
  })),
};
file.meta.checksum = checksum(file);
writeFileSync(out, `${JSON.stringify(file, null, 2)}\n`);
console.log(`\nTransaction Builder batch written to ${out}. Import it in the Transaction Builder app of the Treasury Safe, or paste the calldata above as custom transactions. Nothing was sent.`);

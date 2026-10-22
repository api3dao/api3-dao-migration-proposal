#!/usr/bin/env node
// The fallback after a late execution: when one more reward epoch was minted between posting and execution, the supply
// overshoots 200,000,000 API3 by that reward, and the Agent Safe burns that much of its own API3, one `burn(amount)`
// call on the token. The token lets a holder burn once it opted in with `updateBurnerStatus(true)`, a one-time call the
// Agent Safe makes any time before the vote. This prints the one call to make as calldata, with the amount read from
// the chain at the moment it runs, and the preparation or the top-up from the Treasury Safe when either is still
// needed. Nothing is proposed or sent, the signers create the Safe transaction themselves.
//
//   node scripts/burn-overshoot.mjs [--block <number>]
//
// Needs `cast` and ETH_RPC_URL. Read-only, no dependencies.
import { execFileSync } from 'node:child_process';

const API3 = '0x0b38210ea11411557c13457D4dA7dC6ea731B88a';
const POOL = '0x6dd655f10d4b9E242aE186D9050B68F725c76d76';
const AGENT_SAFE = '0xBBE0dE9757F93e3306aDBfeBE906AB285EDD13DA';
const TREASURY_SAFE = '0xb7fa2Cb302C5dC127e61F27b92beC411cbf0AE4A';
const DEAD = '0x000000000000000000000000000000000000dEaD';
const TARGET_SUPPLY = 200_000_000n * 10n ** 18n;

const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
};
const block = option('--block');
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

// One Safe transaction: a plain call from `from` to the API3 token with this calldata and no value
const transaction = (heading, from, signature, ...values) => {
  console.log(`\n${heading}`);
  console.log(`  from   ${from}`);
  console.log(`  to     ${API3} (API3 token), value 0`);
  console.log(`  call   ${signature} with ${values.join(', ')}`);
  console.log(`  data   ${cast('calldata', signature, ...values)}`);
};

const blockNumber = block ?? cast('block-number', '--rpc-url', rpcUrl);
const supply = uint(call(API3, 'totalSupply()(uint256)'));
const agentBalance = uint(call(API3, 'balanceOf(address)(uint256)', AGENT_SAFE));
const treasuryBalance = uint(call(API3, 'balanceOf(address)(uint256)', TREASURY_SAFE));
const owner = call(API3, 'owner()(address)');
const poolMints = call(API3, 'getMinterStatus(address)(bool)', POOL) === 'true';
const agentBurns = call(API3, 'getBurnerStatus(address)(bool)', AGENT_SAFE) === 'true';

console.log(`block ${blockNumber}`);
console.log(`total supply        ${supply} (${units(supply)} API3)`);
console.log(`Agent Safe API3     ${agentBalance} (${units(agentBalance)} API3)`);
console.log(`Treasury Safe API3  ${treasuryBalance} (${units(treasuryBalance)} API3)`);
console.log(`token owner         ${owner}${owner.toLowerCase() === DEAD.toLowerCase() ? ' (dead, the vote executed)' : ' (the vote has not executed)'}`);
console.log(`pool mints          ${poolMints}`);
console.log(`Agent Safe burns    ${agentBurns}`);

if (!agentBurns) {
  transaction(
    'Preparation, once, any time before the vote: the Agent Safe opts in as a burner, which only lets it burn its own API3',
    AGENT_SAFE,
    'updateBurnerStatus(bool)',
    'true'
  );
}

if (supply <= TARGET_SUPPLY) {
  console.log(`\nNothing to burn: the supply is ${units(TARGET_SUPPLY - supply)} API3 at or below the target. The vote lands on the target on time, or has not executed yet.`);
  process.exit(1);
}
const excess = supply - TARGET_SUPPLY;
console.log(`\nexcess              ${excess} (${units(excess)} API3)`);

const shortfall = agentBalance < excess ? excess - agentBalance : 0n;
if (shortfall > 0n) {
  if (treasuryBalance < shortfall) {
    console.log(`The Agent Safe holds ${units(shortfall)} API3 less than the excess and the Treasury Safe cannot cover it.`);
    process.exit(1);
  }
  transaction(
    `First, since the Agent Safe holds ${units(shortfall)} API3 less than the excess: the Treasury Safe, where the mint landed, tops it up`,
    TREASURY_SAFE,
    'transfer(address,uint256)',
    AGENT_SAFE,
    shortfall.toString()
  );
}

transaction('The fallback: the Agent Safe burns the excess', AGENT_SAFE, 'burn(uint256)', excess.toString());
console.log('\nPaste the data as a custom transaction to the API3 token in the Safe app and verify it like any other. Nothing was sent.');
if (shortfall > 0n || !agentBurns) process.exit(1);

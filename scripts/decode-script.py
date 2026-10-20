#!/usr/bin/env python3
"""Prints the calls of a CallsScript as a markdown table, for ticking Appendix A row by row.

    ./scripts/decode-script.py proposal/generated/script.hex

The script is split into (target, calldata) entries, a call the primary Agent forwards through `execute` is unwrapped,
and the calldata is decoded against the signatures the wind-down vote can contain. Anything else is printed raw, so an
unexpected call stands out. Needs `cast` for the hashes. Read-only.
"""
import json
import subprocess
import sys

NAMES = {
    "0x0b38210ea11411557c13457d4da7dc6ea731b88a": "API3 token",
    "0x6dd655f10d4b9e242ae186d9050b68f725c76d76": "Api3Pool",
    "0xdb6c812e439ce5c740570578681ea7aadba5170b": "primary voting app",
    "0x1c8058e72e4902b3431ef057e8d9a58a73f26372": "secondary voting app",
    "0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae": "primary Agent",
    "0x556ecbb0311d350491ba0ec7e019c354d7723ce0": "secondary Agent",
    "0x1e7ecc6d3b5b4cfdfc71cb7c3ea9ac4a55f4195a": "ACL",
    "0x593ea926ee9820a933488b6a288433c387d06dba": "Kernel",
    "0x8e03609ed680b237c7b6f8020472ca0687308b24": "Vault Safe",
    "0xbbe0de9757f93e3306adbfebe906ab285edd13da": "agent multisig",
    "0x000000000000000000000000000000000000dead": "dead address",
    "0xffffffffffffffffffffffffffffffffffffffff": "any address",
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "USDC",
    "0x93ed3fbe21207ec2e8f2d3c3de6e058cb73bc04d": "PNK",
    "0x67f4c72a50f8df6487720261e188f2abe83f57d7": "wPOKT",
}
DECIMALS = {"USDC": 6, "PNK": 18, "wPOKT": 6, "API3 token": 18}
ROLES = [
    "CREATE_VOTES_ROLE",
    "MODIFY_SUPPORT_ROLE",
    "MODIFY_QUORUM_ROLE",
    "TRANSFER_ROLE",
    "EXECUTE_ROLE",
    "CREATE_PERMISSIONS_ROLE",
    "APP_MANAGER_ROLE",
]
SIGNATURES = [
    "grantPermission(address,address,bytes32)",
    "revokePermission(address,address,bytes32)",
    "removePermissionManager(address,bytes32)",
    "transfer(address,address,uint256)",
    "execute(address,uint256,bytes)",
    "updateMinterStatus(address,bool)",
    "mint(address,uint256)",
    "transferOwnership(address)",
    "changeSupportRequiredPct(uint64)",
    "changeMinAcceptQuorumPct(uint64)",
]
AGENT = "0xd9f80bdb37e6bad114d747e60ce6d2aaf26704ae"


def cast(*args):
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


ROLE_NAMES = {cast("keccak", role): role for role in ROLES}
SELECTORS = {cast("sig", signature): signature for signature in SIGNATURES}
EXECUTE = cast("sig", "execute(address,uint256,bytes)")


def word(data, i):
    return data[64 * i : 64 * (i + 1)]


def decode_execute(data):
    """(target, value, inner calldata) of an execute(address,uint256,bytes) calldata, selector included."""
    body = data[8:]
    target = "0x" + word(body, 0)[24:]
    value = int(word(body, 1), 16)
    offset = int(word(body, 2), 16) * 2
    length = int(body[offset : offset + 64], 16) * 2
    return target, value, body[offset + 64 : offset + 64 + length]


def name(address):
    label = NAMES.get(address.lower())
    return f"{label} `{address}`" if label else f"`{address}`"


def amount(value, token):
    decimals = DECIMALS.get(token)
    if decimals is None:
        return str(value)
    return f"{value} ({value / 10**decimals:,.6f} {token})"


def describe(target, value, data):
    """Function name and decoded arguments of a call, or the raw calldata when the selector is unknown."""
    if data == "":
        return f"plain ETH transfer of {value} wei ({value / 1e18:.6f} ETH)"
    selector, body = data[:8], data[8:]
    signature = SELECTORS.get("0x" + selector)
    if signature is None:
        return f"unknown selector `0x{selector}`, calldata `0x{data}`"
    fname, types = signature[:-1].split("(")
    if fname == "execute":
        inner_target, inner_value, inner = decode_execute(data)
        inner_call = describe(inner_target, 0, inner) if inner else "no calldata"
        return f"`execute`({name(inner_target)}, {inner_value} wei ({inner_value / 1e18:.6f} ETH), {inner_call})"
    args = []
    token = None
    for i, kind in enumerate(types.split(",")):
        w = word(body, i)
        if kind == "address":
            address = "0x" + w[24:]
            args.append(name(address))
            if i == 0 and fname == "transfer":
                token = NAMES.get(address)
        elif kind == "bytes32":
            args.append(ROLE_NAMES.get("0x" + w, "0x" + w))
        elif kind == "bool":
            args.append(str(int(w, 16) != 0).lower())
        else:
            n = int(w, 16)
            if fname == "mint":
                args.append(amount(n, NAMES.get(target.lower())))
            elif fname == "transfer":
                args.append(amount(n, token))
            else:
                args.append(str(n))
    text = f"`{fname}`({', '.join(args)})"
    if value:
        text += f" with {value} wei"
    return text


def main(path):
    script = open(path).read().strip() if not path.startswith("0x") else path
    data = script[2:] if script.startswith("0x") else script
    if data[:8] != "00000001":
        sys.exit(f"not a CallsScript, spec id 0x{data[:8]}")
    rows = []
    offset = 8
    while offset < len(data):
        target = "0x" + data[offset : offset + 40]
        length = int(data[offset + 40 : offset + 48], 16) * 2
        calldata = data[offset + 48 : offset + 48 + length]
        if len(calldata) != length:
            sys.exit(f"truncated calldata in call {len(rows) + 1}")
        offset += 48 + length
        if target == AGENT and "0x" + calldata[:8] == EXECUTE:
            inner_target, value, inner = decode_execute(calldata)
            rows.append(("via primary Agent", inner_target, describe(inner_target, value, inner)))
        else:
            rows.append(("voting app", target, describe(target, 0, calldata)))
    print(f"{len(rows)} calls, {len(data) // 2} bytes\n")
    print("| # | caller | target | call |")
    print("| - | ------ | ------ | ---- |")
    for i, (caller, target, call) in enumerate(rows, 1):
        print(f"| {i} | {caller} | {name(target)} | {call} |")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

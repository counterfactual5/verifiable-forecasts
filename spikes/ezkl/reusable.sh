#!/usr/bin/env bash
# Usage: ./reusable.sh [hashed|fixed]
# Experimental EZKL reusable verifier: deploy Halo2VerifierReusable once, registerVka(vka),
# then verifyProof(proof, instances, vka). Prereq: REUSABLE=1 pipeline.py evm + pipeline.py vka.
set -euo pipefail
cd "$(dirname "$0")"
V=${1:-hashed}
D=out/$V
PORT=8546
RPC=http://127.0.0.1:$PORT
FROM=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

cp "$D/VerifierReusable.sol" forge/src/VerifierReusable.sol
(cd forge && forge build --sizes 2>&1 | grep -E "Reusable \|")

anvil --port $PORT --silent --code-size-limit ${CODE_SIZE_LIMIT:-24576} &
ANVIL=$!
trap 'kill $ANVIL; rm -f forge/src/VerifierReusable.sol' EXIT
sleep 1

ADDR=$(cd forge && forge create src/VerifierReusable.sol:Halo2VerifierReusable --rpc-url $RPC --private-key $PK --broadcast --json | jq -r .deployedTo)
echo "reusable verifier: $ADDR"

read -r PROOF INST VKA < <(.venv/bin/python - "$D" <<'EOF'
import json, sys
d = sys.argv[1]
p = json.load(open(f"{d}/proof.json"))
inst = [int.from_bytes(bytes.fromhex(x), "little") for x in p["instances"][0]]
raw = open(f"{d}/vka.bytes", "rb").read()
n = int.from_bytes(raw[:8], "little")
words = [raw[8 + 32 * i: 8 + 32 * (i + 1)].hex() for i in range(n)]
assert 8 + 32 * n == len(raw)
print(p["hex_proof"], "[" + ",".join(map(str, inst)) + "]", "[" + ",".join("0x" + w for w in words) + "]")
EOF
)
cast send $ADDR "registerVka(bytes32[])" "$VKA" --rpc-url $RPC --private-key $PK --json | jq -r '"registerVka gasUsed: " + (.gasUsed|tostring)'
CD=$(cast calldata "verifyProof(bytes,uint256[],bytes32[])" "$PROOF" "$INST" "$VKA")
echo "calldata bytes: $(( (${#CD} - 2) / 2 ))"
REQ="{\"to\":\"$ADDR\",\"data\":\"$CD\"}"
RET=$(cast rpc eth_call "$REQ" latest --rpc-url $RPC | tr -d '"')
echo "eth_call -> (success, vka_digest, rescaled_instances):"
.venv/bin/python -c "import sys;h=sys.argv[1][2:];[print(i,int(h[64*i:64*i+64],16)-(1<<256 if h[64*i]>=\"8\" else 0)) for i in range(len(h)//64)]" "$RET"; echo "ret bytes: $(( (${#RET} - 2) / 2 ))"
TX=$(cast rpc eth_sendTransaction "{\"from\":\"$FROM\",\"to\":\"$ADDR\",\"data\":\"$CD\",\"gas\":\"0x1c9c380\"}" --rpc-url $RPC | tr -d '"')
echo "tx status: $(cast receipt $TX status --rpc-url $RPC)  gasUsed: $(cast receipt $TX gasUsed --rpc-url $RPC)"

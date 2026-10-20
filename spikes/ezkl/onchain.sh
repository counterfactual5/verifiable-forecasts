#!/usr/bin/env bash
# Usage: ./onchain.sh [fixed|hashed]
# Deploys the generated Halo2Verifier on a throwaway anvil, calls verifyProof with the
# real calldata (expect true) and with tampered public instances (expect false/revert).
set -euo pipefail
cd "$(dirname "$0")"
V=${1:-fixed}
D=out/$V
PORT=8546
RPC=http://127.0.0.1:$PORT
FROM=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266                                  # anvil default #0
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

cp "$D/Verifier.sol" forge/src/Verifier.sol
(cd forge && forge build --sizes 2>&1 | grep -E "Halo2Verifier|Solc")

anvil --port $PORT --silent --code-size-limit ${CODE_SIZE_LIMIT:-24576} &
ANVIL=$!
trap 'kill $ANVIL' EXIT
sleep 1

ADDR=$(cd forge && forge create src/Verifier.sol:Halo2Verifier --rpc-url $RPC --private-key $PK --broadcast --json | jq -r .deployedTo)
echo "verifier: $ADDR  runtime code bytes: $(( ($(cast code $ADDR --rpc-url $RPC | wc -c) - 3) / 2 ))"

CD=0x$(xxd -p "$D/calldata.bin" | tr -d '\n')
call() { cast rpc eth_call "{\"to\":\"$ADDR\",\"data\":\"$1\"}" latest --rpc-url $RPC 2>&1 | tail -1; }

echo "eth_call (valid): $(call $CD)"
TX=$(cast rpc eth_sendTransaction "{\"from\":\"$FROM\",\"to\":\"$ADDR\",\"data\":\"$CD\",\"gas\":\"0x1c9c380\"}" --rpc-url $RPC | tr -d '"')
echo "tx status: $(cast receipt $TX status --rpc-url $RPC)  gasUsed (incl. 21000 base + calldata): $(cast receipt $TX gasUsed --rpc-url $RPC)"

tamper() {  # $1 = index into instances[], adds 1 to that public instance
  .venv/bin/python - "$CD" "$1" <<'EOF'
import sys
h = bytes.fromhex(sys.argv[1][2:]); i = int(sys.argv[2])
body = bytearray(h[4:])
off = int.from_bytes(body[32:64], "big")            # offset of instances[]
n = int.from_bytes(body[off:off + 32], "big")
pos = off + 32 + 32 * (i % n)
v = (int.from_bytes(body[pos:pos + 32], "big") + 1).to_bytes(32, "big")
body[pos:pos + 32] = v
print("0x" + (h[:4] + bytes(body)).hex())
EOF
}
echo "eth_call (input[0]+1):  $(call $(tamper 0))"
echo "eth_call (output[4]+1): $(call $(tamper -1))"

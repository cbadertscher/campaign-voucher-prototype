#!/usr/bin/env bash
# CampaignVoucher M2 trusted setup: fresh local Powers-of-Tau + circuit-specific
# phase2, single contribution. NOT production-secure toxic waste — this is a
# gas-measurement prototype (SPEC.md), not a production deployment. Run once
# from circuits/: `npm run setup`. Regenerate only if credential.circom changes;
# routine `forge test` does not depend on this script (it reads the committed
# src/verifiers/Groth16Verifier.sol and test/fixtures/*.json).
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build
CIRCUIT=credential
POWER=14

mkdir -p "$BUILD"

echo "== compiling circuit =="
circom "$CIRCUIT.circom" --r1cs --wasm -l node_modules -o "$BUILD/"

echo "== powers of tau (phase 1, local, single contribution) =="
npx snarkjs powersoftau new bn128 "$POWER" "$BUILD/pot${POWER}_0000.ptau" -v
npx snarkjs powersoftau contribute "$BUILD/pot${POWER}_0000.ptau" "$BUILD/pot${POWER}_0001.ptau" \
  --name="CampaignVoucher local contribution" -v -e="$(head -c64 /dev/urandom | base64)"
npx snarkjs powersoftau prepare phase2 "$BUILD/pot${POWER}_0001.ptau" "$BUILD/pot${POWER}_final.ptau" -v

echo "== groth16 setup (phase 2, circuit-specific) =="
npx snarkjs groth16 setup "$BUILD/$CIRCUIT.r1cs" "$BUILD/pot${POWER}_final.ptau" "$BUILD/${CIRCUIT}_0000.zkey"
npx snarkjs zkey contribute "$BUILD/${CIRCUIT}_0000.zkey" "$BUILD/${CIRCUIT}_final.zkey" \
  --name="CampaignVoucher local contribution" -v -e="$(head -c64 /dev/urandom | base64)"

echo "== exporting verifier + verification key =="
npx snarkjs zkey export solidityverifier "$BUILD/${CIRCUIT}_final.zkey" "../src/verifiers/Groth16Verifier.sol"
npx snarkjs zkey export verificationkey "$BUILD/${CIRCUIT}_final.zkey" "$BUILD/verification_key.json"

# Pin the pragma to this project's solc version; snarkjs emits a floating pragma.
sed -i 's/pragma solidity .*/pragma solidity 0.8.24;/' "../src/verifiers/Groth16Verifier.sol"

echo "== done: src/verifiers/Groth16Verifier.sol regenerated, $BUILD/${CIRCUIT}_final.zkey + credential_js/ ready for fixture generation =="

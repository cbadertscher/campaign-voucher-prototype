#!/usr/bin/env node
// Generates test/fixtures/*.json for CitizenFactory tests: a real Groth16 proof
// (ABI-encoded as (uint256[2] a, uint256[2][2] b, uint256[2] c)) plus its public
// signals, matching CitizenFactory.createAccount's parameter shapes directly.
// Fixed test seeds below make regeneration deterministic and diffable.
"use strict";
const fs = require("fs");
const path = require("path");
const circomlibjs = require("circomlibjs");
const snarkjs = require("snarkjs");

const BUILD = path.join(__dirname, "..", "build");
const WASM = path.join(BUILD, "credential_js", "credential.wasm");
const ZKEY = path.join(BUILD, "credential_final.zkey");
const OUT_DIR = path.join(__dirname, "..", "..", "test", "fixtures");

const AUTHORITY_PRV = Buffer.from(
  "0001020304050607080910111213141516171819202122232425262728293031",
  "hex"
);
const ROGUE_PRV = Buffer.from(
  "aa01020304050607080910111213141516171819202122232425262728293031",
  "hex"
);
const SECRET_S = 123456789n;
const OWNER_ADDRESS = "0x1111111111111111111111111111111111111111";

// Address of test private key 0xA11CE (same key test/CitizenAccount.t.sol signs
// with) -- used for the one fixture that needs a real, controllable owner key
// (test/VoucherPaymaster.t.sol's account-creation-sponsorship case).
const KNOWN_KEY_OWNER_ADDRESS = "0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7";
const SECRET_S_OWNED = 555555555n;

async function buildInput(authorityPrv, electionId, secret, ownerAddress) {
  const poseidon = await circomlibjs.buildPoseidon();
  const eddsa = await circomlibjs.buildEddsa();
  const F = poseidon.F;

  const pub = eddsa.prv2pub(authorityPrv);
  const s = F.e(secret);
  const C = poseidon([F.e(0), s]);
  const sig = eddsa.signPoseidon(authorityPrv, C);
  const nullifier = poseidon([F.e(1), s, F.e(BigInt(electionId))]);

  return {
    authorityPubKeyAx: F.toObject(pub[0]).toString(),
    authorityPubKeyAy: F.toObject(pub[1]).toString(),
    nullifier: F.toObject(nullifier).toString(),
    owner: BigInt(ownerAddress).toString(),
    electionId: electionId.toString(),
    s: F.toObject(s).toString(),
    C: F.toObject(C).toString(),
    R8x: F.toObject(sig.R8[0]).toString(),
    R8y: F.toObject(sig.R8[1]).toString(),
    S: sig.S.toString(),
  };
}

/// Uses snarkjs's own G2-coordinate ordering (exportSolidityCallData) rather than
/// hand-rolling from proof.pi_b directly, to avoid the well-known Fp2 swap footgun.
async function packProofCalldata(proof, publicSignals) {
  const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
  const [a, b, c] = JSON.parse("[" + calldata + "]");
  const words = [a[0], a[1], b[0][0], b[0][1], b[1][0], b[1][1], c[0], c[1]];
  return "0x" + words.map((w) => BigInt(w).toString(16).padStart(64, "0")).join("");
}

async function genFixture(name, authorityPrv, electionId, secret = SECRET_S, ownerAddress = OWNER_ADDRESS) {
  const input = await buildInput(authorityPrv, electionId, secret, ownerAddress);
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, WASM, ZKEY);

  const out = {
    proof: await packProofCalldata(proof, publicSignals),
    pubSignals: publicSignals, // [authorityPubKeyAx, authorityPubKeyAy, nullifier, owner, electionId]
  };
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const outPath = path.join(OUT_DIR, `${name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log(`wrote ${outPath}`);
}

async function main() {
  await genFixture("credential_election1", AUTHORITY_PRV, 1);
  await genFixture("credential_election2", AUTHORITY_PRV, 2);
  await genFixture("credential_rogue_authority", ROGUE_PRV, 1);
  await genFixture("credential_owned", AUTHORITY_PRV, 1, SECRET_S_OWNED, KNOWN_KEY_OWNER_ADDRESS);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

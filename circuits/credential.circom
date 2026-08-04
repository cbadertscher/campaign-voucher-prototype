pragma circom 2.0.0;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/eddsaposeidon.circom";

// SPEC.md §3.2 — the credential-verification circuit. Runs exactly once, at
// account creation (SPEC §1 #2). Proves the prover holds a secret `s` for which
// the authority signed a commitment, and derives an election-scoped nullifier
// from that same secret, without revealing `s`.
template CredentialCircuit() {
    // Public: the authority pubkey is checked on-chain (CitizenFactory) against
    // its own immutable copy, not baked into the circuit — see M2 plan decision 1.
    signal input authorityPubKeyAx;
    signal input authorityPubKeyAy;
    signal input nullifier;
    signal input owner;
    signal input electionId;

    // Private
    signal input s;
    signal input C;
    signal input R8x;
    signal input R8y;
    signal input S;

    // 1. C == Poseidon(0, s)  (commitment; domain tag 0)
    component commitHash = Poseidon(2);
    commitHash.inputs[0] <== 0;
    commitHash.inputs[1] <== s;
    C === commitHash.out;

    // 2. EdDSA-Poseidon: (R8,S) is a valid authorityPubKey signature on C
    component sig = EdDSAPoseidonVerifier();
    sig.enabled <== 1;
    sig.Ax <== authorityPubKeyAx;
    sig.Ay <== authorityPubKeyAy;
    sig.S <== S;
    sig.R8x <== R8x;
    sig.R8y <== R8y;
    sig.M <== C;

    // 3. nullifier == Poseidon(1, s, electionId)  (domain tag 1, scoped per election)
    component nullHash = Poseidon(3);
    nullHash.inputs[0] <== 1;
    nullHash.inputs[1] <== s;
    nullHash.inputs[2] <== electionId;
    nullifier === nullHash.out;

    // 4 & 5. `owner` and `electionId` are not otherwise constrained here — Groth16's
    // verification equation itself binds every public signal to the specific proof,
    // so including them as public inputs is what "stops proof re-use under another
    // owner" / "ties the proof to one election" (they cannot be swapped post-hoc
    // without invalidating the proof).
}

component main {public [authorityPubKeyAx, authorityPubKeyAy, nullifier, owner, electionId]} = CredentialCircuit();

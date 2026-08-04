# Campaign-Voucher — Prototype

A faithful, end-to-end prototype of an anonymous-eID campaign-finance voucher system.
Vouchers are discrete ERC-721 tokens that move `0 (mint) -> citizen -> candidate ->
vendor -> 0 (burn)`; every other transfer edge reverts. Full design in [SPEC.md](SPEC.md).

The headline result is a real, measured USD cost estimate for running this system on
L1 Ethereum or Base — see **"Reproduce the cost report"** below, which is the fastest
path to the main output this prototype exists to produce. After that, **"Local devnet
demo"** shows the same system as real broadcast transactions on a throwaway chain, so
the emitted events are independently inspectable. Everything past that is a
milestone-by-milestone deep dive (token economy, ZK circuit, account abstraction,
end-to-end walkthrough) for anyone who wants to examine a specific piece rather than
the headline results.

## Environment setup (Foundry)

- **[Foundry](https://book.getfoundry.sh/)** is the toolkit used to compile, test,
  and run those contracts. It's one install that gives you four command-line
  tools:
  - `forge` — compiles the contracts, runs the test suite (`test/*.t.sol`), and
    runs one-off scripts (`script/*.s.sol`, like the cost estimators below).
    You'll use this one the most.
  - `anvil` — starts a local, fake Ethereum blockchain on your machine in about a
    second, pre-funded with test accounts. Only needed for the "local devnet
    demo" below; `forge test`/`forge script` spin up their own throwaway chain
    internally and don't need `anvil` running separately.
  - `cast` — a command-line tool for sending one-off calls/transactions to a
    chain (used below to read event logs off the demo's `anvil` chain).
  - `chisel` — a Solidity REPL; not used by anything in this repo, just comes
    bundled.

**1. Install Foundry** (macOS or Linux; on Windows, use
[WSL](https://learn.microsoft.com/en-us/windows/wsl/install) first, then follow
the Linux instructions inside it):
```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup
```
The first command installs `foundryup` (Foundry's own installer/updater) into
your shell; you may need to open a new terminal (or `source` your shell's rc
file, as the installer's output will tell you) before `foundryup` is on your
`PATH`. `foundryup` then downloads and installs `forge`/`anvil`/`cast`/`chisel`
themselves. Verify it worked:
```sh
forge --version
```

**2. Get the code.** If you don't already have this checked out:
```sh
git clone --recurse-submodules https://github.com/cbadertscher/campaign-voucher-prototype.git
cd campaign-voucher-prototype
```
`--recurse-submodules` matters here — this repo's Solidity dependencies
(OpenZeppelin's contracts, `forge-std`, the ERC-4337 `account-abstraction`
library) are pulled in as git submodules under `lib/`, not vendored directly.
If you already cloned without it (or these directories look empty), fetch them
with `git submodule update --init --recursive`, or just run `forge install`
below, which fetches the same thing.

**3. Build and test** — this is the "did my setup work?" checkpoint:
```sh
forge install   # harmless even if submodules are already present; first checkout only, in practice
forge build     # compiles everything under src/, test/, script/
forge test      # runs the full test suite -- expect "61 tests passed, 0 failed" if all is well
```
If `forge build` fails, it's almost always a missing/incomplete `lib/`
submodule — re-run `git submodule update --init --recursive` (or `forge
install`) and try again. Everything else in this README assumes these three
commands already ran successfully at least once.

**Other tools, only needed for specific pieces** (skip these until you actually
need them — they're not required to build, test, or run the cost estimators):
- **python3** (standard library only) — for `bench/fit_b3.py`, a small
  post-processing script over B3's gas-benchmark CSVs.
- **circom, snarkjs, node** — only needed to *regenerate*
  `src/verifiers/Groth16Verifier.sol` or `test/fixtures/*.json`; both are
  already committed, so routine `forge build`/`forge test` need none of these.

## Reproduce the cost report

This is the main event: a real, measured USD cost estimate (SPEC §7/§8) for running
the whole voucher lifecycle on L1 Ethereum (at three price levels) or Base (at real
live conditions). No mocks — the full contract system is deployed fresh and driven
through the actual create→claim→donate→spend→redeem walkthrough, and gas is measured
directly, not guessed.

```sh
cp .env.example .env                                              # first time only; edit ETH_USD / L1 gas-price tiers
forge test --mt test_B3                                           # prerequisite: refreshes gas-reports/b3_*.csv
L1_SCENARIO=low    forge script script/CostEstimate.s.sol         # -> gas-reports/CostEstimate_low.md
L1_SCENARIO=normal forge script script/CostEstimate.s.sol         # -> gas-reports/CostEstimate_normal.md
L1_SCENARIO=high   forge script script/CostEstimate.s.sol         # -> gas-reports/CostEstimate_high.md
forge script script/CostEstimate.s.sol --fork-url https://mainnet.base.org   # -> gas-reports/CostEstimate_base.md
```

One run writes one report, for one price scenario — not a single combined
low/normal/high/Base table. This is deliberate: EntryPoint's own gas accounting
reads `block.basefee` directly (see `getUserOpGasPrice` in
`account-abstraction/contracts/core/EntryPoint.sol`), so the gas used by the
sponsored actions (create/claim/donate) is measurably not price-independent.
Each L1 scenario pins `block.basefee` to its own configured price via
`vm.fee(...)` *before* deploying and measuring, so the reported gas is always
measured under the exact price it's priced at, rather than reusing one
measurement (taken under whatever basefee happened to be ambient) across every
column. The Base scenario deliberately does *not* pin the fee — it measures
under Base's real, live `block.basefee` and the real `GasPriceOracle` precompile,
which requires `--fork-url`.

Each report contains: methodology, parameters and their sources, a per-action
USD table for that one scenario, and SPEC §8's program-scale extrapolation
(split into sponsor-paid and self-paid buckets, not a third "admin" bucket —
candidate/vendor registration is authority-paid, the same party that funds the
paymaster) over an explicitly illustrative example population. The §8 section
degrades to a note if `forge test --mt test_B3` hasn't been run yet, rather
than fabricating slope/intercept figures.

**Want your own population instead of the illustrative example?** Use the
interactive variant — it's a thin overlay on the script above (same
methodology, same per-action table), just with real, prompted numbers instead
of a fixed example:
```sh
forge test --mt test_B3                                     # prerequisite: refreshes gas-reports/b3_*.csv
forge script script/InteractiveCostEstimate.s.sol            # prompts for L1 price level, then population
forge script script/InteractiveCostEstimate.s.sol --fork-url https://mainnet.base.org   # Base: no price prompt, only population
```
`InteractiveCostEstimateScript is CostEstimateScript` and overrides five small
hooks -- `_population()` (prompts for citizen/candidate/vendor counts and
donation-rate percent instead of returning SPEC §8's fixed illustrative example),
`_populationIsIllustrative()` (so the report correctly says "user-provided
population" instead of "not measured, not real data"), `_reportBasename()`
(writes to `gas-reports/InteractiveCostEstimate_<scenario>.md` instead, so it
never collides with `CostEstimate.s.sol`'s own output), `_l1ScenarioLabel()`
(prompts for the price level -- low/normal/high -- instead of reading
`L1_SCENARIO` from the environment; skipped entirely when `--fork-url` is used,
since Base's live basefee is used either way), and `_scenarioSourceLabel()` (so
the report's own Parameters table says "interactive prompt" rather than
"L1_SCENARIO env var"). `run()` itself, the full methodology/parameters/
per-action table, and the sponsor-paid/self-paid §8 breakdown are all
inherited unchanged. Needs an interactive terminal (`vm.promptUint`/`vm.prompt`)
-- doesn't work piped or in CI. Prompt order: price level (if not forked) first,
then population, once deployment/measurement has already run underneath.

## Local devnet demo (transparency showcase)

```sh
anvil                                                                        # terminal 1, leave running
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2

# then inspect the real, persisted events on the running chain (addresses are
# printed by the script itself on each run):
cast logs --rpc-url http://127.0.0.1:8545 --from-block 0 --address <VoucherNFT address>
cast logs --rpc-url http://127.0.0.1:8545 --from-block 0 --address <CitizenFactory address>
```

Unlike the cost report above, this one is **not simulated** — every step is a
real broadcast transaction against a real (local, throwaway) chain, using anvil's
well-known default dev-account keys (public, standard-mnemonic-derived; never real
funds). `cast logs` then shows the real `AccountCreated` → `VoucherClaimed` →
`VoucherDonated` → `VoucherSpent` → `VoucherRedeemed` sequence as it actually
happened on-chain, across five real blocks — the concrete transparency proof behind
this whole prototype's premise. Candidate/vendor steps are plain, unsponsored EOA
transactions (SPEC §3.6); create/claim/donate are sponsored through the real
`EntryPoint`+paymaster, same as the cost report above.

**Gas note**: the demo passes an explicit gas stipend on `handleOps` calls
(`{gas: 3_000_000}`) rather than relying on `eth_estimateGas` — a known ERC-4337
gotcha where naive gas estimation underestimates `handleOps` transactions, since
`EntryPoint`'s internal `call{gas: verificationGasLimit}`-style sub-calls enforce
their own gas requirements in a way a plain outer-call binary search doesn't
reliably discover. Real bundlers compute the required gas directly from the
userOp's own declared limits instead of trusting estimation; this script does the
same.

---

# Milestone-by-milestone deep dive

Everything below reproduces or explains one specific piece of the system in
isolation — useful if you want to inspect a particular milestone rather than the
headline cost result above. This checkout implements **Milestone 1 (Token
economy)** — `AllowList` + `VoucherNFT` (transfer-rule state machine,
`claimVoucher`, outflow batching), invariant tests, and gas benchmarks B1–B3 —
**Milestone 2 (ZK)**: the Circom credential circuit, a local Groth16 trusted
setup, the generated on-chain verifier, and `CitizenFactory` (the single ZK site
— SPEC §3.2/§3.3), enforcing I2 (one account per credential per election) — and
**Milestone 3 (Account abstraction)**: the real ERC-4337 v0.7 `CitizenAccount`
(`eth-infinitism/account-abstraction`, ECDSA owner key per SPEC §1 #6),
`VoucherPaymaster` (SPEC §3.6, sponsors only ops targeting the factory or
`VoucherNFT`), a real deployed `EntryPoint` in the test harness, and factory
staking, enforcing I6/I7 — and **Milestone 4 (End-to-end)**: `EndToEnd.t.sol`
(SPEC §4/B5), the canonical create→claim→donate→spend→redeem walkthrough for
one voucher's full life, sponsored throughout its ERC-4337 steps, real
`EntryPoint` + paymaster + verifier, no mocks, per-step and total gas — and
**Milestone 5 (Costing)**: the `script/CostEstimate.s.sol`/
`script/InteractiveCostEstimate.s.sol` pair covered above.

## Layout

```
src/                AllowList.sol, VoucherNFT.sol, CitizenFactory.sol, CitizenAccount.sol,
                    VoucherPaymaster.sol
src/verifiers/      Groth16Verifier.sol — generated by circuits/scripts/setup.sh, committed
circuits/           credential.circom, package.json, scripts/ (setup.sh, gen_fixture.js)
script/             CostEstimate.s.sol (M5, SPEC §7/§8), InteractiveCostEstimate.s.sol
                    (thin overlay on CostEstimate.s.sol -- real, prompted population),
                    Demo.s.sol (local devnet demo), lib/CostMeasurement.sol (shared
                    deploy/measure/format code both cost scripts build on)
test/               unit tests, invariants/ (I1, I5), gas/ (B1-B4), EndToEnd.t.sol (B5)
test/fixtures/      committed proof + public-signal fixtures, read via vm.readFile
test/utils/         Fixture.sol (M1), CitizenFactoryHarness.sol (M2/M3), UserOpLib.sol
                    (PackedUserOperation builder for ERC-4337 tests)
bench/              fit_b3.py — OLS fit + v_max over B3's gas-vs-v CSVs
gas-reports/        CSVs written by the B3 gas tests + CostEstimate_{low,normal,high,base}.md
                    (M5's reports, one per price scenario), all gitignored, regenerated each run
.env.example        M5's price parameters (copy to .env and edit before running)
```

## Reproducing the M1 benchmarks (§6 of SPEC.md)

```sh
forge test --mt test_B1 -vv    # B1: donation gas invariant to |citizens| (50 vs 5,000)
forge test --mt test_B2 -vv    # B2: baseline O(1) gas for claim/donate/spend(1)/redeem(1)
forge test --mt test_B3 -vv    # B3: writes gas-reports/b3_{batchTransfer,redeem}.csv
python3 bench/fit_b3.py gas-reports/b3_batchTransfer.csv gas-reports/b3_redeem.csv
```

The last command prints the linear fit (slope = marginal gas/voucher, intercept = fixed
overhead) and `v_max` — the largest batch size that fits under a 30M L1 block gas limit —
for both `batchTransfer` (spend) and `redeem`.

```sh
forge test --mt test_B4 -vv    # B4: real Groth16 verify + CREATE2 deploy + register
```

## Milestone 3 tests (I6, I7)

```sh
forge test --match-contract CitizenAccountTest -vv    # I6: forged signatures fail/revert
forge test --match-contract VoucherPaymasterTest -vv   # I7: paymaster sponsors only approved targets
```

Both deploy a real `EntryPoint` and exercise it through `handleOps` — no mocks. Note:
ERC-4337's factory/paymaster staking requirement (ERC-7562) is enforced by bundlers
during off-chain simulation, not by `EntryPoint.handleOps` itself, so `test_stake_*`
(in `test/CitizenFactory.t.sol`) only proves staking mechanically works, not that an
unstaked factory would be rejected — that rejection has no on-chain code path to test.

## Milestone 4 test (B5)

```sh
forge test --match-test test_B5_endToEndWalkthrough -vv
```

The one test that exercises every piece together — ZK proof verification, ERC-4337
account creation/execution, paymaster sponsorship, and the plain-EOA outflow steps —
across one voucher's full life, printing per-step and total gas.

## Regenerating the M2 circuit artifacts (optional)

Not needed for routine `forge build`/`forge test` — both `src/verifiers/Groth16Verifier.sol`
and `test/fixtures/*.json` are committed. Only run this if you change
`circuits/credential.circom`:

```sh
cd circuits
npm install
npm run setup       # trusted setup (fresh local ceremony, NOT production-secure —
                     # see circuits/scripts/setup.sh) + regenerates Groth16Verifier.sol
npm run fixtures    # regenerates test/fixtures/*.json from the new circuit/setup
```

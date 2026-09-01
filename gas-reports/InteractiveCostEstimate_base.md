# CampaignVoucher - Cost Estimate (SPEC Section 7/8) -- scenario: base

As of block 49548253, timestamp 1785885853.

## Methodology

Gas figures below are measured directly, with no mocks: the full contract system (Groth16 verifier, EntryPoint v0.7, CitizenFactory, CitizenAccount, VoucherPaymaster, VoucherNFT) is deployed fresh and driven through SPEC Section 4's canonical walkthrough (create/claim/donate sponsored through the real EntryPoint + paymaster; spend/redeem as plain EOA calls), identical to `test/EndToEnd.t.sol`. This report covers exactly one price scenario -- run this script again with a different `L1_SCENARIO` (or with `--fork-url` for Base) to get the others; see the file list under gas-reports/. For an L1 scenario, `block.basefee` is pinned via `vm.fee(...)` to that scenario's own price BEFORE deployment, so the measured gas reflects that exact price -- not a value borrowed from whatever chain happened to be forked (EntryPoint's own fee accounting reads `block.basefee` directly, so gas usage is not perfectly price-independent). For Base, the real `GasPriceOracle` precompile and live `block.basefee` are used instead (`--fork-url <base-rpc>` required). ETH_USD is a supplied parameter (via `.env`, see `.env.example`), not measured or invented by the script.

## Parameters

| Parameter | Value | Source |
|---|---|---|
| Scenario | base | --fork-url (live) |
| ETH_USD | $1850 | env var (default 1850, researched 2026-08-04) |
| Base L2 gas price | 5000000 wei | live, `block.basefee` at block 49548253 |

## Per-action cost (SPEC Section 4/7)

| Action | Gas | Cost (base) |
|---|---|---|
| Create | 832608 | $0.007705 |
| Claim | 140167 | $0.001298 |
| Donate | 80192 | $0.000743 |
| Spend (1) | 40023 | $0.000370 |
| Redeem (1) | 10845 | $0.000100 |

`(1)` on Spend/Redeem means a single voucher, not a fixed per-call cost: both `batchTransfer`/`redeem` take an array of voucher IDs and can sweep many at once (SPEC's batching requirement at the candidate->vendor and vendor->authority outflows), so this is the no-batching baseline, not what a real accumulated sweep costs -- see B3 (`test/gas/B3_OutflowSlope.t.sol`) for the measured marginal gas/voucher once batched, and Section 8 below for that fit applied to a real population.

(`a_register` measured separately: 24066 gas -- used only in Section 8 below.)

## Program-scale extrapolation (SPEC Section 8)

User-provided population: 5000000 citizens, 500 candidates, 10000 vendors, 100% of citizens donate their voucher, each candidate/vendor sweeps its accumulated vouchers in 1 / 1 batched transaction(s) respectively.

B3 refit: spend slope=12745 gas/voucher, intercept=27051; redeem slope=8745 gas/voucher, intercept=2111.

Sponsor-paid and self-paid are collapsed to two buckets, not three: candidate/vendor registration is authority-paid (SPEC Section 3.1's AllowList admin model), the same party that funds the paymaster deposit (SPEC Section 3.6) -- so it's counted as sponsor-paid, not a separate bucket.

**Extrapolated total gas: 5372572328500**

| Bucket | Gas | Cost (base) |
|---|---|---|
| Sponsor-paid (create+claim+donate+registration) | 5265087693000 | $48702.061160 |
| Self-paid (candidate/vendor batched spend+redeem) | 107484635500 | $994.232878 |
| **Program total** | 5372572328500 | $49696.294038 |

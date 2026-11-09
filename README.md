# Shadow ($SHDW)

**3,333 shadows sleep on Elysium (chain 99901). Hold 1 whole $SHDW → draw one. Burn a coin to light it → earn 2% of every trade.**

Shadow is a single-contract shadow machine: a zero-seed bonding curve, a three-state
shadow lifecycle (POOL → DARK → LIT), and blockhash-sealed draws. The contract launched
holding exactly **0 HYPE** — no presale, no team allocation, no seed liquidity — and its
admin was frozen in the same hour it deployed.

- 🌐 Site & app: https://shadow.yoga
- 𝕏: https://x.com/CryptoLenslw7q
- 🔍 Explorer: https://elysiumscan.io/address/0x4748EF1e38CA8D3e1313ce38Bae4B73675B4cae1

## Deployed contract (the only official one)

| | |
|---|---|
| Contract | `0x4748EF1e38CA8D3e1313ce38Bae4B73675B4cae1` |
| Chain | Elysium · 99901 · gas token HYPE |
| Deploy tx | `0x7ac81247127b95f1ce46f7b618bcd860614925ce2d8c2f83669a6c6efd891e83` |
| Runtime size | 11,932 bytes |
| Fee | 3% per trade — 2% to lit shadows by weight, 1% operations |
| Admin | `frozen() == true` since launch; the fee split can never be edited |

### ⚠️ v1 — abandoned, never interact

`0x244dEF9521E379Fa79Bd227571790ECA347f0b27` was our first deployment. A self-test caught
a bug that could trap fractional balances after a shadow was lit (root cause and fix:
`test/Regression.t.sol`). v1 never took public money. If an address differs by even one
character from the v2 address above, it is not us.

## How it works

- **Curve.** Constant product with virtual reserves (2,000 virtual HYPE × 3,333 virtual
  SHDW). Clearing the whole pool costs exactly 2,000 HYPE of net buys.
- **Draw.** Holding ≥ 1.0 whole SHDW entitles you to draw shadows from the pool of 3,333.
  The draw unlocks ~1 minute after crossing a whole coin and is sealed by a future
  blockhash. A shadow's generation is fixed by its ID (weights ×1.0 / ×1.4 / ×2.0 / ×2.8 /
  ×4.0 for GEN 1–5, counts 1338 / 899 / 603 / 362 / 131).
- **Dissolve.** If a sell or transfer takes you below a whole coin, your newest unlit
  shadow dissolves back into the pool. Lit shadows never dissolve.
- **Light (consecrate).** Burn 1.0 SHDW to light a shadow forever. It earns a weight-share
  of the 2% lit pool from every trade. Attune up to 4 times (+50% weight per level, 1.0
  SHDW burned each). Lit shadows are non-transferable.

## Verify this source matches the chain

```bash
forge install foundry-rs/forge-std
forge build
# Compare the runtime bytecode of out/ShadowCore.sol/ShadowCore.json
# (deployedBytecode) against the code at the contract address:
# byte-identical (11,932 bytes) except the CBOR metadata trailer and the
# seven slots of the constructor-computed immutable K
# (0x990b3a09db68786162b8097cc20000000000), which are zero in a plain build.
```

Compiler: solc 0.8.24, optimizer 200 runs, EVM cancun (see `foundry.toml`).
Tests: `forge test` — 25 tests, including `Probe.t.sol` (adversarial probes written
before launch) and `Regression.t.sol` (the v1 bug, reproduced and fixed).

## Known issues (disclosed, by design or by record)

1. **`reserveForLit` — 0.007 HYPE stranded.** Fees that accrued before the first shadow
   was lit were parked in `reserveForLit`, which has no distribution path. The amount is
   permanently capped at 0.007 HYPE: since the first LIT exists, `totalWeight > 0`
   forever and no new funds can enter that bucket. Frozen contract; documented, accepted.
2. **Draw window.** On this chain the contract's `block.number` advances ≈ 1.19/s (the
   RPC reports a different, faster numbering). A draw unlocks ≈ 42 s after scheduling
   and must be settled within ≈ 160 s, or `settle()` reverts `Expired()`; the draw is
   re-armed by buying up to the next whole coin. Entitlement is never lost.
3. **First LIT is ours.** Shadow #2929 (GEN 2) was lit by the deploying wallet during
   the public self-test and currently receives 100% of the lit pool — until the second
   shadow is lit. The live count is shown on the site's transparency section.
4. **Draw outcome predictability.** A pending draw's inputs are on-chain, so a
   sophisticated observer can compute the outcome before settling. Generation is fixed
   by ID regardless; this affects timing games, not the rarity table.

## Repository layout

- `src/ShadowCore.sol` — the exact source of the deployed v2 contract
  (fee 3%, team share = fee/3, plus the one-line `darkOf` fix vs. the original draft)
- `test/` — unit tests, adversarial probes, and the v1 regression tests
- `script/` — deploy & on-chain verification scripts
- `docs/` — deployment records for v1 and v2, and the response to an independent
  post-launch on-chain audit (Chinese)

## License

MIT

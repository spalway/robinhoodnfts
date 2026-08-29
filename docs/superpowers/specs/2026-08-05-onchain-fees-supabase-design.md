# xNFTs — Protocol fees, Supabase backend, dev-wallet payouts

**Date:** 2026-08-05
**Status:** Approved. Section 3 implemented; sections 4–6 rewritten 2026-08-05 after the Anchor
program was abandoned — see §4 and §8.

---

## 1. What this adds

Before this spec the app was a deterministic simulation with one real-value path (`src/lib/solana.ts`,
a burn-to-mint disabled by default). It adds:

1. A **protocol fee** — 5% on mints and sales, 10% on rental contracts — accruing to a treasury.
2. A **transaction layer** (`src/lib/spl.ts`) that composes the fee into the same atomic transaction
   as the payment it taxes, using nothing but SPL Token instructions.
3. A **Supabase backend** acting as an index and a payout queue. It is **never** the authority on
   balances.
4. A **Payouts tab** where the operator moves accrued fees to the dev wallet, and a claim appears as
   a genuinely pending transaction until the chain confirms it.
5. A **repricing** that makes minting EV-neutral instead of a free ~26%.

The original plan for (2) was an Anchor program, `xnft_market`, that would be the authority on every
transfer of value. That program was written, never compiled, and abandoned — §8 records why, so that
nobody spends another day on the same toolchain. §4 is what shipped instead, and §4.4 is the honest
accounting of what the substitution cost.

## 2. Decisions already made

| Question | Decision |
|---|---|
| On-chain scope | **No program.** Every real path is a composed SPL Token transaction the payer signs. |
| Mint fee incidence | Tax rides **on top**: 10,500 total — 10,000 burned, 500 to treasury |
| Token model | **One token.** `$XPL` is retired; everything is denominated in `$xNFT` |
| Rental fee | **10%**, distinct from the 5% on mints and sales |
| Sales | **Simulated.** Escrow is the one thing only a program could have provided — see §4.3 |
| Treasury custody | A plain SPL token account owned by an operator-held keypair, **not** a PDA |
| Supabase | CLI installed locally; migrations and Edge Functions written here, deployed by the user |

## 3. Economic model

*Unchanged and still binding. Every number below survived the program's removal, because none of them
ever depended on it — the arithmetic lives in `src/lib/fees.ts`, which is now the sole implementation
rather than half of a matched pair.*

### 3.1 Constants

```
BPS_DENOM      = 10_000
TRADE_FEE_BPS  =    500   // 5%  — mints and sales
RENT_FEE_BPS   =  1_000   // 10% — rental contracts
MAX_FEE_BPS    =  2_000   // 20% — ceiling on any configurable fee
MINT_BURN      = 10_000   // whole $xNFT sent to the incinerator per mint
MINT_FEE       =    500   // = MINT_BURN * TRADE_FEE_BPS / BPS_DENOM
MINT_TOTAL     = 10_500   // what the buyer actually pays
```

`MAX_FEE_BPS` is 2000 rather than 1000 so that the 10% rental fee is not sitting exactly at the
ceiling, while still making a predatory fee impossible even from a compromised authority.

> **Amended 2026-08-05.** That last clause was true of a program and is not true of a constant.
> `MAX_FEE_BPS` is now a range check inside `src/lib/fees.ts` — it stops a bad argument, not a bad
> operator, because the operator is the one who ships `fees.ts`. The rate a payer is actually charged
> is whatever the bundle they loaded computes. See §4.4.

### 3.2 Why `XNFT_USD = 0.19`

Tier supply is 60/25/12/3 and principal is `1000 × skills`, so:

```
E[principal]        = .60(1000) + .25(2000) + .12(3000) + .03(4000) = $1,580
mean effective APY  = weighted mean baseApy (0.0580) × mean proficiency (0.80) ≈ 4.64%
fair-value multiple = 1 + apy/0.18                                              ≈ 1.258×
E[fair value]       = 1580 × 1.258                                              ≈ $1,988
```

The old `XPL_USD = 0.42` made a 10,000-token mint cost $4,200 for $1,988 of value — but that number
was never comparable, because the mint was denominated in `$xNFT` and the market in `$XPL` with no
conversion anywhere in the codebase. That is the defect this spec closes.

At `XNFT_USD = 0.19` the buyer pays `10,500 × 0.19 = $1,995` for an expected $1,988. **Mint edge:
−0.35%** — neutral, which is the target. Downstream this puts the UNCOMMON floor near 6,600 $xNFT
(below mint cost) and an X-RATED near 26,900. That is correct: minting is a fairly-priced tier
lottery, and a buyer who only wants yield buys the floor instead.

### 3.3 Rental economics change

With `Y` = expected total yield over the term and `spread` = the listing's fee multiple:

```
renter pays   = spread × Y × 1.10
renter margin = Y × (1 − 1.10 × spread)
break-even    = spread of 0.909   (was 1.0 with no fee)
```

Listing spreads are drawn from 0.7–1.4×, so the profitable band for renters narrows from ~43% of
the range to ~30%. `contractMath` **must** be updated to subtract the fee, or the UI reports a
margin that does not exist.

### 3.4 Rounding direction

The fee is **floored**, and the counterparty receives exactly `gross`. Both operands are
non-negative, so bigint truncation toward zero *is* floor. The payer covers the fee on top, so the
rounding remainder — bounded at one raw unit, 1e-9 of a token at the assumed decimals — is left with
the payer rather than extracted from them.

This is the direction `src/lib/fees.ts` implements and the direction the UI quotes. An earlier draft
of this spec specified rounding *up*, on the argument that the treasury must never be short because
`total_fees` versus the treasury balance versus the Supabase `fee_ledger` was an equality rather than
a tolerance. That argument died with the program: there is no `total_fees` counter any more, the
treasury's authoritative balance is simply what the token account holds (§4.2), and the reconciliation
that demanded exactness no longer exists. What survives is the weaker and now sufficient rule — never
over-charge the payer — so the direction is floor. A build that changes it must change the quote and
the debit in the same commit, which is one file.

## 4. On-chain: composed SPL transactions

There is no program. `src/lib/spl.ts` builds every real transfer out of `transferChecked` and
`createAssociatedTokenAccountIdempotent`, addressed at whichever token program owns the mint
(classic SPL or Token-2022, read off the mint account rather than assumed).

### 4.1 What is chain-backed and what is simulated

| Operation | Status | Why |
|---|---|---|
| **Mint** | **Chain-backed.** Two `transferChecked`s in one transaction: 10,000 $xNFT to the incinerator, 500 to the treasury. | A mint is a payment by one party. One signature covers both legs; both land or neither does. |
| **Rent** | **Chain-backed.** Two `transferChecked`s in one transaction: `fee_per_epoch × term` to the owner, 10% of that to the treasury. | The xployee never moves. A rental is a payment plus a tenancy row — there was never anything for an escrow to hold. |
| **Payout claim** | **Chain-backed.** One `transferChecked` from the treasury token account to the dev wallet's, signed by the treasury keypair. | The token program enforces that only that keypair can move the balance. It does not enforce where it goes — see §4.4. |
| **Sale** | **Simulated.** A Supabase ledger entry, like the rest of the collection. | §4.3. |

Atomicity is not a property the program provided; it is a property of a Solana transaction. Two
instructions in one transaction execute in order or not at all, which is the entire guarantee the fee
ever needed: **there is no ordering in which the burn happens and the fee does not.**

### 4.2 The three transactions

Every builder returns an unsigned `Transaction` or a typed `SplError`, and asks the wallet for
nothing. Sending is a separate call, wired only to a click.

**`buildMintTransaction(owner)`**
Idempotent ATA creates for any destination that is actually missing, then
`owner → incinerator: quote.gross` and `owner → treasury: quote.fee`. Total debit `quote.total`,
checked against the payer's live balance before the transaction is built, so an underfunded visitor
reads a sentence instead of dismissing a wallet prompt they should never have seen.

The creates are *idempotent* rather than plain creates even though existence was just read: between
that read and the send, anyone at all may open the account, and a plain create that finds it already
there fails the whole transaction — taking the burn leg down with it.

**`buildRentTransaction(renter, owner, feePerEpoch, termEpochs)`**
`renter → owner: gross`, `renter → treasury: fee`. `owner` is a parameter because a renter pays a
specific counterparty read off a listing; it is a counterparty, not a destination the module owns.
The treasury leg is the one pinned to configuration. Refuses a self-rental (which would debit the
renter a 10% fee to move tokens between two of their own accounts), a non-positive term, and a
negative fee.

**`buildClaimTransaction(operator, amount)`**
Treasury ATA → dev-wallet ATA, signed by the treasury wallet. `amount` is checked against the live
treasury balance, so a stale UI figure is refused before the wallet is asked rather than after. The
`operator === TREASURY_ADDRESS` check is not a permission system: it is the module declining to build
a transaction the token program would certainly reject.

**The claimable balance is the token account's balance**, deliberately, and not a running total of
fees minus claims. With no program keeping counters, the account is the only thing that knows how
much money is actually there.

### 4.3 Why sale is the one that could not survive

An outright sale is the only operation where **both sides deliver**: the buyer's $xNFT and the
seller's NFT have to change hands together or not at all. Every other operation in this protocol is
one party paying — a mint, a rental, a claim — and one party paying is one signature.

A two-sided atomic swap without a program requires both parties to sign the *same* transaction. That
is a coordination problem a marketplace cannot solve: the seller lists and walks away, and there is
nobody to co-sign when a buyer arrives hours later. The program solved it by taking custody — the
`Listing` PDA held the NFT in escrow, so the buyer's single signature could move both legs, because
the seller's leg had already been authorized at listing time.

That escrow is what the program genuinely bought, and it is what dropping the program genuinely cost.
Sales are therefore Supabase ledger entries, consistent with the rest of this deliberately simulated
collection. `spl.ts` has no `buildSaleTransaction` and will not grow one; nothing in the code or the
UI copy claims a sale moves value.

### 4.4 What dropping the program cost

Three guarantees were traded away for not deploying Rust. They are recorded here specifically so that
nobody later reads "the fee is enforced" into a codebase where it is not.

**1. The fee is no longer structurally unbypassable.**
The program made escrow the only exit from a listing: once listed, an xployee could leave only via
`buy` (which charged) or `cancel_listing` (which returned it to the seller). There was no path that
moved the asset without paying. Now the fee holds within any transaction *this app builds* — that
much is real, and it is real because the fee instruction sits in the same transaction as the payment
— but nothing stops two parties from arranging a trade outside the app entirely and paying nothing.
The guarantee moved from *"the chain will not execute an untaxed trade"* to *"this client will not
compose one"*, which is a guarantee about a bundle rather than about a protocol.

**2. The treasury is an operator-held wallet, so a claim is an authorization rather than an enforced
permission.**
`Treasury` was a PDA: no human held its key, and `claim_fees` would only send to
`config.dev_wallet`, an on-chain address constraint. Now the treasury is an ordinary SPL token
account owned by a keypair the operator holds. Two consequences, both plain:

- Custody of the fee balance *is* custody of a private key. Whoever holds it can send the fees
  anywhere, at any time, without touching this app.
- The dev-wallet destination is a constant in a file the operator ships. Keeping it out of
  `claimTransfer`'s parameter list is still worth doing — no call site, and no bug in one, can
  redirect a payout — but it is worth strictly less than an address constraint, because it binds the
  code rather than the key.

**3. There is no on-chain cap on the fee rate.**
`set_config` refused any rate above `MAX_FEE_BPS`, checked inside the program, so even a compromised
authority could not set a confiscatory tax. That check now lives in `fees.ts` as an argument
validation, which constrains a caller and not an operator. Nor is there a `max_total` slippage
argument any longer, and it is no longer needed for the same reason: the rate is not read from a
mutable on-chain account between signing and landing, it is compiled into the bundle the payer is
looking at. The payer sees exactly the amounts in the transaction their wallet renders before they
sign. What they do not get is any assurance about what the *next* bundle will charge.

**What did not change.** The rules that governed the client were never program-dependent and all
survive: money is bigint raw units; async money paths return typed errors rather than throwing;
destinations come from configuration and never from a parameter; building and sending are separate
calls; nothing sends without a click; the module refuses to build anything at all while the mint
address is unset; and a confirmation timeout is success-with-unknown-status, never failure.

### 4.5 The configuration gate

Three deployment constants in `spl.ts` — `XNFT_MINT_ADDRESS`, `TREASURY_ADDRESS`,
`DEV_WALLET_ADDRESS` — are empty placeholders. `isConfigured()` is a single check across all three,
and while it is false every path returns `not-configured` and no transaction is built.

One gate rather than three, deliberately. Every path that moves value touches at least two of these:
a mint pays the treasury, a claim empties it. A half-armed build could only ever produce a transfer
to a destination nobody chose — a mint with no treasury configured is a burn with no fee, which is
exactly the bypass the fee is supposed to close. Refusing until the whole set is present is cheaper
to reason about than a matrix of partial states.

`TREASURY_ADDRESS` and `DEV_WALLET_ADDRESS` are additionally validated as *on-curve* wallets, so
pasting a PDA into either reads as "not configured" rather than throwing out of an ATA derivation.

### 4.6 Burn mechanism

The mint transfers to the incinerator (`1nc1nerator11111111111111111111111111111111`) rather than
issuing a `burn` instruction. This matches both the existing frontend and the original brief ("sent
to a solana burn address"). A true `burn` would additionally reduce `mint.supply` and is a one-line
swap if that is ever preferred; it is recorded here so the choice is deliberate rather than
accidental.

The incinerator is off the ed25519 curve, so the default ATA derivation refuses it. `spl.ts` exposes
`incineratorTokenAccount()` as a *separate function* with the off-curve guard relaxed, rather than a
boolean parameter on `tokenAccountFor()` — a parameter would let any caller opt any owner out of a
guard whose entire purpose is to stop tokens being sent somewhere nobody can sign from.

## 5. Supabase

### 5.1 Role

Supabase is a **read model and a payout queue**. It is never consulted to decide whether someone can
afford something, and it never holds an authoritative balance. If Supabase and the chain disagree,
the chain wins and the index is rebuilt.

With sales simulated (§4.3), Supabase carries one more responsibility than originally planned: it is
the *only* record of ownership transfer on a sale. That is a change in kind, not degree — for mints
and rentals the index describes something that happened on-chain, and for sales it is the thing that
happened. The UI must not present the two the same way.

### 5.2 Tables

| Table | Key | Notes |
|---|---|---|
| `wallets` | `address` | handle, bio, twitter |
| `xployees` | `id` | nft_mint, owner, tier, skills, traits, principal, apy, hired_at, mint_signature |
| `listings` | `nft_mint` | seller, price, kind, fee_per_epoch, term_epochs, status |
| `trades` | `signature` | nft_mint, buyer, seller, gross, fee, net_to_seller, slot — **simulated; no chain signature backs a sale** |
| `mints` | `signature` | buyer, burned, fee, xployee_id, slot |
| `fee_ledger` | `signature`, `source` | source ∈ {mint, sale, rent}, amount, slot — the accrual side |
| `payouts` | `id` | amount, destination, status, signature, requested_at, confirmed_at |

`listings.listing_pda` is gone; there are no PDAs. The `mints` and `fee_ledger` rows for a mint or a
rental are keyed on a real signature; a `trades` row is not.

### 5.3 The trust boundary

**One Edge Function, `ingest-signature`, is the only write path for chain-derived data.** The client
posts a signature and nothing else. The function fetches that transaction from RPC and writes from
*its* reading — never from client-supplied amounts. Idempotent on `signature` as primary key, so a
double-post is a no-op.

What that function verifies has changed with the program. It can no longer check a program id and
decode an event; there is no program and no event. It must instead verify the **shape of the
transfers themselves**: that the instructions are `transferChecked` against the configured mint, that
the destinations are the configured incinerator and treasury token accounts, and that the amounts
match what `fees.ts` computes for the claimed action. That is a weaker check than parsing a program's
own event — a transaction can satisfy it without the app having built it — but it is sound for the
purpose, because the thing being recorded is "these tokens reached these accounts", which is exactly
what it confirms.

RLS:
- Public `SELECT` on everything except `payouts`.
- `payouts` `SELECT` restricted to the operator address.
- **Zero client-side `INSERT`/`UPDATE`/`DELETE` on any table.** All writes go through service-role
  Edge Functions.

This mirrors the bug already fixed once in `src/lib/social.ts`, where an unfiltered projection let a
third party inject offers. The same class of hole is closed here structurally rather than by filter.

### 5.4 The pending payout, concretely

1. Operator opens Payouts. Claimable balance is read **live from the chain** — the treasury token
   account's balance — not from Supabase.
2. Claim → `buildClaimTransaction` → `sendClaim` → wallet signs.
3. The instant a signature returns, a `payouts` row is written with `status = 'pending'`. This is a
   real pending state: the transaction genuinely is unconfirmed.
4. `confirm-payout` polls `getSignatureStatus` and flips the row to `confirmed` or `failed`. It also
   runs on a schedule, so a row cannot hang forever if the browser is closed mid-claim.
5. A timeout leaves the row `pending`, never `failed` — the same rule `confirmSignature` follows in
   `spl.ts`, because presenting a possibly-landed transfer as a failure invites a duplicate.

## 6. Frontend

| File | Role |
|---|---|
| `src/lib/fees.ts` | Single source of fee math. All `bigint` raw units. `feeOn`, `totalWithFee`, `mintQuote`, `saleQuote`, `rentQuote`. Now the sole implementation, not half a matched pair. |
| `src/lib/spl.ts` | **The transaction layer.** Configuration constants, quotes, pure instruction composers, builders, senders. Replaced `src/lib/program.ts`, which was deleted with its tests. |
| `src/lib/solana.ts` | The burn-to-mint surface the existing UI already speaks (`MINT_COST`, `isBurnConfigured`, `buildBurnTransaction`, `sendBurn`, `BurnError`…), now routed through `spl.ts`. No program vocabulary remains. |
| `src/lib/market.ts` | `XPL_USD` → `XNFT_USD = 0.19`. `fairValueXpl` → `fairValueXnft`. `contractMath` carries the 10% fee. |
| `src/lib/format.ts` | `xpl()` → `xnft()`. |
| `src/lib/supabase.ts` | Typed read-only client, anon key only. No write path. |
| `src/pages/Payouts.tsx` | Operator-gated. Live claimable balance, claim button, payout history with pending state. Copy must describe custody honestly (§4.4). |
| `src/pages/Marketplace.tsx` | Shows fee and total explicitly on every buy and rent, and must be explicit that a buy is a ledger entry. |

**No float ever touches a balance.** Money is `bigint` raw units end to end; conversion to a display
string happens once, at the edge.

## 7. Testing

Everything is vitest, offline, and there is nothing to run a validator against.

- **Transaction layer** (`src/lib/spl.test.ts`): the exact 10,000 + 500 = 10,500 set and that the fee
  rides on top rather than out of the burn; the burn destination being the incinerator, invariant
  across owners and unoverridable (arity assertions plus an actual attempt to smuggle extra
  `PublicKey` arguments into `mintTransfers`, asserting byte-identical output); ATA derivation for
  on-curve wallets, for the off-curve incinerator, and its divergence under Token-2022; bigint
  decimals scaling exact for 0..18, including a case a float provably corrupts; the unconfigured gate
  sweeping every entry point, each called with a deliberately unusable RPC endpoint so that a
  `network` code would prove the gate fired too late; and rent arithmetic equal to `fees.rentQuote`
  plus the flooring-once-on-the-total property.
- **Fee engine** (`src/lib/fees.test.ts`): the exact `10_000 → 10_500` mint case and the flooring
  direction at the boundary (§3.4).
- **Economics**: mint EV stays within ±2% of fair value, so a future tuning change that reopens the
  arbitrage fails loudly.

The program's test plan — `anchor test` against `solana-test-validator`, covering slippage rejection,
authority gating, escrow reachability, pause semantics and rental exclusivity — is void. Every item on
it tested a guarantee that no longer exists (§4.4); none of them can be salvaged as a client test,
because a client cannot test what a client is not the one enforcing.

## 8. Toolchain: why there is no Rust

**Do not attempt the Anchor path again in this environment without first fixing the toolchain.** It
was tried, and it failed for an environmental reason, not a code reason:

1. **The MSVC path requires administrator elevation that is unavailable here.** Building any Rust
   crate with the default `x86_64-pc-windows-msvc` target needs the Visual Studio Build Tools C++
   workload for its linker, and the Build Tools installer demands elevation. That is not a flag that
   can be worked around from a non-elevated shell.
2. **The GNU fallback failed on missing binutils.** Switching to `x86_64-pc-windows-gnu` avoids MSVC
   entirely, but the build then died on a missing `dlltool` — part of GNU binutils, which the
   available toolchain did not supply and which cannot be installed by the same route that was
   already blocked.

The Rust sources under `anchor/` were **never compiled**, so they were never type-checked, never
linted, and never run. `anchor/target/` contains a program keypair and no build artifact, which is
the evidence. See `anchor/ABANDONED.md`.

The directory stays on disk only because this project is not under version control and deleting it
would be unrecoverable. **It is not a source of truth for anything** — not layouts, not constants,
not comments. Where it disagrees with `src/lib/`, `src/lib/` is right by definition, because
`src/lib/` runs.

## 9. Explicitly out of scope

- Deploying any program, or creating the real `$xNFT` mint.
- Reviving the Anchor program, which would require the toolchain in §8.
- Any change to the generative art, tier, or accrual systems.
- Migrating the existing simulated collection into Supabase; the deterministic generator stays as
  the source of truth for identity.

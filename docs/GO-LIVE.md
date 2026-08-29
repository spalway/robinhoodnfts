# xNFTs — Go-Live

> **STALE — read as history, not as the current state.** This audit describes the repository on
> 2026-08-05, two rounds of change ago. Since then the on-chain program was abandoned in favour of
> composed SPL transfers, the addresses moved out of `VITE_` vars into `protocol_config`, and the
> shipped collection went from 512 xployees across 97 invented wallets to a single holding —
> `#0000`, X-RATED, the project wallet — with an empty order book, no other wallets, and no
> activity. Every count below (512, 97, `HIRED_COUNT = 512`) is wrong now. The findings about what
> is real versus simulated, and the risk sections, still hold. See [DEPLOY.md](DEPLOY.md) and the
> README for the current shape.

**Written:** 2026-08-05, from an audit of this repository at that date.
**Scope:** what stands between the app as it exists on disk and a deployment that moves real value.
**Not:** legal advice. §5 flags exposure and stops there.

Every claim below is anchored to a file that was read. Where I could not establish something from the
repository — an external service's current terms, a rent figure that changes with account size — it is
marked **UNVERIFIED** rather than guessed. A confidently wrong step in a go-live document costs real
money, so the uncertainty is left visible.

Verification run at the time of writing, in this working tree:

```
$ npx tsc --noEmit
(no output, exit 0)

$ npx vitest run
 Test Files  5 passed (5)
      Tests  188 passed (188)
```

**Both numbers above moved while this document was being written, because other workflows were editing
the tree concurrently. Treat them as a snapshot, not a guarantee — re-run both before any deploy.**
Specifically:

- One earlier `tsc` invocation reported `src/components/Inbox.tsx(128,10): error TS6133:
  'EnvelopeGlyph' is declared but its value is never read.` Two subsequent runs were silent and exited
  0. Almost certainly a mid-edit read.
- An intermediate `vitest run` reported **188 tests, 5 failed** — all five in
  `src/lib/protocol.test.ts > network`, all `Cannot read properties of undefined (reading
  'principal')`. Cause: `src/lib/collection.ts`, `tiers.ts`, `xployee.ts` and `protocol.test.ts` were
  being rewritten at 18:21–18:23 to add a serial/reveal-order mechanism while `src/lib/network.ts`
  still indexed `collection()` by raw id. The next run, one minute later, was green — that track
  landed. Recorded only so nobody reading a stale terminal thinks the suite is broken.

Nothing in this document edited any source file. The only file written is `docs/GO-LIVE.md`.

Local toolchain confirmed present: `solana-cli 4.1.1 (Agave)`, `spl-token-cli 5.6.1`, `node v24.18.0`,
`wrangler 4.118.0`, `supabase 2.111.0`. `metaboss` and `sugar` are **not** installed. Docker is not
installed either, which is why `supabase/README.md` documents a remote-only workflow.

---

## 0. The verdict in one paragraph

**There is no NFT.** The 512 xployees are generated in the browser from a seeded PRNG, their "mint
addresses" come from a function whose own comment says *"never a real key"*, and a hire is a row in
`localStorage`. Nothing is minted on Solana, nothing is transferable, and the artwork does not exist
as a file anywhere — it is painted onto a `<canvas>` at runtime and discarded when the tab closes.
The token the whole economy is denominated in, `$xNFT`, does not exist either. Two real things do
work today: the xStock mint addresses and their live prices. Everything between those and a launch is
work that has not been started, not work that has been half-finished. Going live is not a
configuration exercise; it is roughly a **6–10 week build** for one competent Solana engineer, and
about half of that is the NFT and art pipeline that nothing in this repository currently anticipates.

---

## 1. What is real today vs simulated

### 1.1 The table

| Thing | Status | Where | Notes |
|---|---|---|---|
| xStock mint addresses | **REAL** | `src/lib/xstocks.ts:19-35` | 16 entries, resolved against Jupiter's token registry 2026-08-03 and baked in as constants. Identity is never resolved at runtime. |
| xStock USD prices | **REAL, live** | `src/lib/prices.ts:19,35-69` | `GET https://lite-api.jup.ag/price/v3?ids=<mints>`. Failure degrades to `referencePrice` per stock with `source: 'cached'`; never throws, never renders `NaN`. |
| Wallet connect + signing | **REAL** | `src/lib/wallet.tsx` | Wallet Standard (`@wallet-standard/app`), no wallet-adapter modal. `signAndSendTransaction` is the only signing path and is null when unavailable. |
| Fee arithmetic | **REAL** | `src/lib/fees.ts` | 5% mints/sales, 10% rentals, floored, bigint raw units. 37 passing tests. |
| SPL transaction layer | **REAL, disarmed** | `src/lib/spl.ts` | Genuine `transferChecked` composition for mint / rent / claim. |
| — its three deployment constants | **EMPTY** | `src/lib/spl.ts:79,90,100` | `XNFT_MINT_ADDRESS`, `TREASURY_ADDRESS`, `DEV_WALLET_ADDRESS` are all `''`. `isConfigured()` (`spl.ts:220`) gates every path; while any is empty nothing is built. |
| $xNFT token itself | **DOES NOT EXIST** | `src/lib/token.ts:21-30` | `XNFT_CA`, `PUMP_FUN_URL`, `DEXSCREENER_URL`, `TWITTER_HANDLE` all `''`. `isTokenLaunched()` is false. |
| **The xployees (the "NFTs")** | **SIMULATED** | `src/lib/collection.ts` (`HIRED_COUNT = 512`, `collection()`), `src/lib/xployee.ts:43-67` | 512 built by `buildXployee(id, hireTimeFor(id))`. `MAX_SUPPLY = 5000` is a display constant only. |
| — their mint addresses | **FAKE** | `src/lib/xployee.ts:44` → `src/lib/rng.ts:78-85` | `fakeAddress()` draws 44 chars from the base58 alphabet with `mulberry32`. Comment: *"Deterministic pseudo-Solana address. Base58 alphabet, 44 chars, never a real key."* |
| — their artwork | **NO FILE EXISTS** | `src/lib/avatar.ts` (`buildAvatar` → 32×32 grid of colour strings), `src/components/PixelAvatar.tsx:30-47` (canvas `fillRect` per pixel), `src/lib/backgrounds.ts:248-253` (CSS `filter` over a shared JPEG) | The art is computed and painted at render time. There is no PNG, no SVG, no export path. |
| Your holdings | **SIMULATED, browser-local** | `src/lib/useHoldings.ts:11,49-58` | `localStorage['xnfts:holdings']`, `{id, hiredAt}[]`. New id is `HIRED_COUNT + current.length` — the same ids on every machine, colliding across users. |
| Books / yield / APY | **SIMULATED** | `src/lib/accrual.ts:37-48,85-87` | Pure function of (hire time, now, skills). No capital is deployed anywhere; there is no position in any xStock. |
| Marketplace listings | **SIMULATED** | `src/lib/market.ts:148-184` | `rngFrom('market', x.mint)`; ~10% sales, ~8% contracts. Prices scatter 0.75–1.45× a computed fair value. |
| Sales settlement | **SIMULATED** | `src/lib/spl.ts:20-24`, `src/pages/Marketplace.tsx:173`, spec §4.3 | No `buildSaleTransaction` exists and one is not planned. Escrow died with the abandoned program. |
| $xNFT/USD rate | **SIMULATED** | `src/lib/market.ts:36` | `XNFT_USD = 0.19`, derived to make a mint EV-neutral (spec §3.2). Not a market price. |
| xNET ownership graph | **SIMULATED** | `src/lib/network.ts:212-241` | 97 wallets from `fakeAddress('xnet:wallet:N')`, partitioned over a seeded permutation. |
| Social / DMs / trade offers | **SIMULATED** | `src/lib/social.ts:1-13` | *"There is no server."* Visitor's half in `localStorage`, counterparties deterministic. |
| Payments queue ("3 hours") | **SIMULATED, browser-local** | `src/lib/earnings.ts:190-294`, `src/pages/Payments.tsx:25,112` | A claim ID written to `localStorage['xnfts:payments:<address>']`. **The request never leaves the browser.** No operator can see it. |
| SOL/USD used in payouts | **HARDCODED** | `src/lib/earnings.ts:30` | `SOL_USD = 180`, marked PLACEHOLDER. |
| Supabase schema | **WRITTEN, NOT DEPLOYED** | `supabase/migrations/*.sql` (929 lines across 3 files) | Tables, domains, `SECURITY DEFINER` writers, RLS. Nothing has been pushed — no project exists. |
| Edge Functions | **WRITTEN, NOT DEPLOYED** | `supabase/functions/{ingest-signature,request-payout,confirm-payout}` | `ingest-signature` verifies transfer *shape* against `preTokenBalances`/`postTokenBalances`, not a program event. |
| Supabase client | **REAL, unconfigured** | `src/lib/supabase.ts:77-86` | `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` unset ⇒ every call returns `not-configured`. |
| Cloudflare deploy | **CONFIGURED, never run** | `wrangler.jsonc`, `package.json:14-15` | Assets-only Worker over `./dist`, `not_found_handling: "single-page-application"`. Needs an interactive `wrangler login`. |
| The Anchor program | **DEAD** | `anchor/` | Never compiled. Spec §8. Do not read it, do not revive it. |

### 1.2 Three things that table does not make obvious

**(a) The configuration placeholders are source constants, not environment variables.**
`src/lib/spl.ts:79,90,100` and `src/lib/token.ts:21-30` are `export const … : string = ''`. Nothing
reads them from `import.meta.env`. A grep across `src/` for `import.meta.env` returns **exactly one
hit — `src/lib/supabase.ts:73`**, the helper that reads the Supabase URL and anon key. Those two are
the only environment variables the browser bundle consumes. So:

- `VITE_XNFT_MINT`, `VITE_XNFT_PROGRAM_ID` and `VITE_SOLANA_RPC_URL` in `.env.example` are **read by
  nothing**. Setting them has no effect.
- `VITE_XNFT_PROGRAM_ID` refers to the abandoned program and should not exist at all.
- Arming the money paths means **editing two source files and rebuilding**, not setting env vars.

**(b) `.env.example` and `supabase/README.md` §4 disagree with the code that actually runs.**
`supabase/functions/_shared/env.ts:66-84` requires `SOLANA_RPC_URL`, `XNFT_MINT_ADDRESS`,
`TREASURY_ADDRESS`, `DEV_WALLET_ADDRESS` (and rejects treasury == dev wallet). `supabase/README.md` §4
tells you to set `SOLANA_RPC_URL` and `XNFT_PROGRAM_ID`. **Following the README verbatim produces a
backend that returns 503 `not-configured` on every call, forever.** Both of those files are owned by
another workflow; this is reported, not fixed.

**(c) There are two unrelated payout systems and the UI does not connect them.**

| | `src/pages/Payouts.tsx` + `src/lib/usePayouts.ts` | `src/pages/Payments.tsx` + `src/lib/earnings.ts` |
|---|---|---|
| Who uses it | The operator only (`useIsOperator`, `usePayouts.ts:329`) | Any connected wallet |
| Asset | `$xNFT` raw units | SOL |
| Source of funds | Protocol fee legs landing in the treasury ATA | pump.fun creator fees (`Payments.tsx:104-107`) |
| Mechanism | On-chain `transferChecked`, signed by the treasury keypair | A human sending SOL by hand |
| State | Chain + Supabase `payouts` | `localStorage`, browser-only |

Nothing routes value from the first pool to the second. The user-facing promise — "payouts are made in
SOL out of the creator fees the $xNFT token earns on pump.fun" — is backed by a wallet that does not
exist yet and a queue nobody can read.

---

## 2. Blocking gaps, ordered by what stops a launch

Effort figures are engineer-days for one experienced Solana/TypeScript developer, excluding review and
legal. They assume the existing code quality bar is maintained.

---

### B1 — There is no NFT. **BLOCKING. Largest single gap.**

**What is missing.** Everything. `buildXployee` (`src/lib/xployee.ts:43-67`) produces a plain JS
object; `fakeAddress` (`src/lib/xployee.ts:44` → `src/lib/rng.ts:78-85`) produces a
44-character base58 *string* that no account on any cluster corresponds to; `useHoldings` writes
`{id, hiredAt}` into `localStorage`. There is no mint account, no token account, no metadata account,
no collection, no royalty config, no transfer, no ownership read. `src/pages/Mint.tsx:186-188` states
it outright to the visitor: *"the xployee it reveals is generated in your browser and stored there —
there is no NFT on-chain to receive."*

The database already concedes it in two places:
`supabase/migrations/20260805120000_protocol_tables.sql` comments `xployees.nft_mint` as
*"Unpopulated. No writer sets it and nothing joins on it"*, and `mints.xployee_id` as *"Null in
practice. A mint transaction carries no xployee id."*

**What it takes to close it.**

1. **Pick a standard.** For a 5,000 supply where *the buyer pays their own mint*, cost is not the
   deciding factor — see the cost note below — so **Metaplex Core (`mpl-core`)** is the right default:
   one account per asset, first-class collections, plugin-based royalties, and far less ceremony than
   Token Metadata's mint + ATA + metadata + master-edition quartet. Compressed NFTs via Bubblegum are
   the alternative and the right answer only if you pre-mint the whole collection up front or expect
   supply to grow past ~10⁴.
2. **Decide who mints.** Two shapes, and they have very different costs:
   - *Buyer-minted* (matches the current UX). The buyer's transaction creates the asset. The buyer pays
     the rent. The protocol pays nothing per unit. This requires an authority signature on the mint
     instruction, which means either a server that co-signs (a backend service holding a hot key — new
     infrastructure, new attack surface) or a mint authority delegated to the buyer, which gives away
     the ability to control what gets minted.
   - *Pre-minted + transferred.* The operator mints all 5,000 in advance and a purchase transfers one.
     Simpler authority story, but the operator fronts 5,000 × rent, and a transfer to a buyer still
     needs the operator to sign — the exact co-signing problem that killed atomic sales (§B6).

   **There is no version of a real NFT mint that keeps the current "no backend, nothing to co-sign"
   architecture.** This is the decision that shapes everything else, and it is not made anywhere in
   the repository.
3. **Attach the deterministic identity.** The tier/skills/traits currently come from
   `rngFrom('xployee', id)`. On-chain they must be *committed*, not re-derived, or two clients running
   different bundles disagree about what a token is. That means the metadata JSON is authoritative and
   `buildXployee` becomes a renderer of stored attributes rather than the source of them — a
   non-trivial refactor of `src/lib/xployee.ts`, `collection.ts`, `network.ts` and every page that
   calls `byId()`.
4. **Replace `useHoldings` with a chain read.** Ownership becomes a DAS/`getAssetsByOwner` query (Helius,
   Triton and QuickNode all expose the Metaplex DAS API) keyed on the collection address, cached
   through TanStack Query. `localStorage` holdings must be deleted, not migrated — they are not real.

**Cost note.** **UNVERIFIED — compute these before committing.** Rough orders of magnitude at the time
of writing: a Token Metadata NFT is ~0.012 SOL of rent (mint + ATA + metadata + master edition); a
Metaplex Core asset is a single account and materially cheaper; a Bubblegum tree's cost is dominated by
its canopy depth and is a one-time allocation. Do not take those numbers from this document — size the
account and run `solana rent <bytes>`, then multiply.

**Effort: 15–25 days.** This is the critical path and nothing downstream of it can be finished first.

---

### B2 — The art does not exist as a file. **BLOCKING, and coupled to B1.**

**What is missing.** A rendered image per xployee, hosted somewhere permanent, and a metadata JSON
pointing at it. Today:

- `src/lib/avatar.ts` `buildAvatar()` returns a 32×32 `(string|null)[][]`.
- `src/components/PixelAvatar.tsx:38-46` paints it one `fillRect` per pixel onto a canvas.
- `src/lib/backgrounds.ts:248-253` composes the tier backdrop as a CSS `background-image` plus
  `filter: hue-rotate(Ndeg) saturate(S) brightness(B) contrast(C)`.
- `src/components/XployeeArt.tsx` adds an animated particle canvas on top for Epic and X-RATED.

**What it takes to close it.**

1. A Node render script that imports `avatar.ts` unchanged (it is pure — that was designed for this;
   its header even says *"reusable for exports"*) and rasterises the grid with `@napi-rs/canvas` or
   `sharp`.
2. **The hard part: reproducing the CSS filter chain.** `hue-rotate`/`saturate`/`brightness`/`contrast`
   are defined by specific colour matrices operating in sRGB. `sharp`'s `modulate`/`linear` are *not*
   the same transform. If you approximate, the exported PNG will not match what the site shows, and
   for an NFT the exported PNG **is** the asset. Either port the CSS filter matrices exactly, or —
   better — pre-render the 7 X-RATED backdrops × the number of hue steps into finished files at build
   time and have both the site and the exporter consume the same images. The second option removes an
   entire class of "the art on the marketplace doesn't match the art on the site" bug.
3. **Pick a still frame deterministically.** Particles animate. The exported image must be a defined
   frame (frame 0 with a seeded particle state), recorded so it is reproducible.
4. **Hosting.** Options, in descending order of durability: Arweave via Irys (permanent, pay once,
   the norm for Solana NFTs), IPFS via a pinning service (durable while you pay), or your own R2/CDN
   behind the domain (cheapest, and the metadata dies with your Cloudflare account — which for an NFT
   is a real problem, not a shrug). **Recommend Arweave/Irys** and budget for it: 5,000 small PNGs plus
   5,000 JSON files is a modest one-time cost, but it is not zero and it must be paid before the mint
   opens.
5. **Metadata schema.** Standard Metaplex JSON: `name` (`xployee #0042`), `symbol`, `description`,
   `image`, `attributes` for tier, skill count, each skill's ticker and proficiency, and the four
   visual traits from `src/lib/xployee.ts:17-20`. `properties.files` and `properties.category: "image"`.

**Effort: 8–12 days**, of which the filter-fidelity work is the risky half.

---

### B3 — `$xNFT` does not exist. **BLOCKING for every money path.**

`src/lib/token.ts` ships four empty strings and `isTokenLaunched()` returns false, so the /token page
correctly says "not launched". `src/lib/spl.ts:79` is empty, so `isConfigured()` is false, so
`buildMintTransaction`, `buildRentTransaction`, `buildClaimTransaction`, `fetchOwnerBalance` and
`fetchTreasuryBalance` all return `not-configured` and build nothing.

**What it takes.** Launch the token (§3 Phase 6), capture the CA, paste it into two files, rebuild.
Mechanically small. The consequences are not: from the moment `XNFT_MINT_ADDRESS` is non-empty, the
Mint button is a **real, irreversible** 10,500 $xNFT debit (10,000 to `1nc1nerator1111…`, 500 to the
treasury). `README.md:91-92` is explicit that this path *"has never been exercised against a live
token"*.

**Effort: 0.5 days of edits. Non-negotiable prerequisite: the devnet rehearsal in Phase 3.**

---

### B4 — The payout queue is a browser-local fiction, and it promises 3 hours. **BLOCKING (trust/legal).**

`src/pages/Payments.tsx:25` sets `SETTLEMENT_HOURS = 3` and the copy at lines 108-113 and 286-288 tells
the visitor to chase a claim ID *"if a payout has not landed within 3 hours."* But
`src/lib/earnings.ts:253-264` writes the request to `localStorage['xnfts:payments:<address>']` and
`notify()`s local listeners. **That is the entire flow.** No fetch, no Supabase call, no email, no
webhook. The operator has no queue to work.

Compounding it: the amount is derived from `accruedTotal()` — simulated yield with no funding source —
converted at a hardcoded `SOL_USD = 180`.

**What it takes to close it.**

1. Repoint the four persistence functions at a real backend. `earnings.ts:190-201` marks itself as
   "THE SEAM" and is deliberately four functions wide (`loadRequests`, `saveRequest`, `clearRequests`,
   `subscribeRequests`) precisely so this is a swap and not a rewrite. A new `payment_requests` table
   plus an Edge Function that writes it. **Note the ownership constraint: `src/lib/supabase.ts` and
   `supabase/**` are owned by another workflow — coordinate, do not fork.**
2. Authenticate the request. Right now anyone can POST any address. A wallet signature over a nonce
   (`signMessage`) is the minimum; `src/lib/wallet.tsx` currently exposes only `signAndSendTransaction`,
   so that method has to be added.
3. Decide, in writing, **where the SOL comes from and what the eligibility rule is** — see §5.
4. Either back the 3-hour promise with a rota and alerting (§4.2) or change the copy. Do not ship a
   number you cannot meet.
5. Replace `SOL_USD = 180` with a live quote. `src/lib/prices.ts` already talks to Jupiter and SOL
   (`So11111111111111111111111111111111111111112`) is available from the same endpoint — a small,
   contained change, but a wrong SOL price directly mis-sizes a real payment.

**Effort: 5–8 days.**

---

### B5 — No RPC endpoint is ever supplied. **BLOCKING at any traffic.**

`src/lib/spl.ts:116` — `DEFAULT_RPC = clusterApiUrl('mainnet-beta')`. Every read and build accepts an
`endpoint` argument (`TxOptions`), **and nothing in the app ever passes one**:
`src/lib/useBurn.ts:93` calls `fetchXnftBalance(address)`; `src/lib/usePayouts.ts:312` calls
`fetchTreasuryBalance()`. So 100% of traffic goes to `api.mainnet-beta.solana.com`, which:

- rate-limits per IP aggressively and returns 429 under trivial load;
- routinely refuses WebSocket upgrades (which is why `confirmSignature` polls — `spl.ts:864`);
- is explicitly not for production use.

Concretely, `usePayouts` polls the treasury every 30s (`TREASURY_REFETCH_MS`), `buildMintTransaction`
makes four sequential RPC calls before the wallet is even asked (`getAccountInfo`, balance read, two
`tokenAccountExists`), and `sendMint` then polls up to 30 times at 2s. A dozen concurrent minters will
exhaust the public endpoint, and a failed read mid-mint surfaces as a `network` error on an
irreversible action.

**What it takes.** A paid endpoint (Helius / Triton / QuickNode), plus threading it through: read it
from `import.meta.env.VITE_SOLANA_RPC_URL` once and pass `{ endpoint }` at every call site in
`useBurn.ts` and `usePayouts.ts`. **`spl.ts`, `useBurn.ts` and `usePayouts.ts` are owned by another
workflow** — this is a coordination item, not a unilateral edit. The same endpoint (or a separate,
higher-limit one) goes into the Edge Function secret `SOLANA_RPC_URL`.

**Effort: 1–2 days once the provider account exists.**

---

### B6 — There is no marketplace settlement. **NOT blocking a launch; blocking the marketplace.**

An atomic swap of an NFT for `$xNFT` needs both sides in one transaction, and the seller has left by
the time a buyer arrives. Escrow is exactly what the abandoned program bought (spec §4.3), and
`src/lib/spl.ts:20-24` states plainly that `buildSaleTransaction` does not exist and will not.

**Options, honestly ranked.**

1. **Ship without a marketplace.** List, but route the Buy button to an external marketplace (Tensor,
   Magic Eden) once the collection is a real Metaplex collection. They already solved escrow, they
   already honour on-chain royalty plugins, and it costs you zero on-chain code. **This is the right
   answer for a first launch.** The 5% trade fee then becomes a royalty enforced (or not) by that
   marketplace, not by you — say so in the docs.
2. Write the escrow program. Anchor, ~600 lines with tests, plus an audit. Spec §8 records that the
   Rust toolchain does not build in this environment (MSVC needs elevation, the GNU fallback lacks
   `dlltool`) — so this needs a different machine or a container before a line is written.
3. Keep sales simulated and label them relentlessly. Workable only while the xployee is also
   simulated. **Once B1 lands and an xployee is a real NFT, a "simulated sale" of a real asset is
   indefensible** — the ledger would say a wallet owns something the chain says it does not. If you do
   B1, you must do 1 or 2.

**Effort: 2 days (option 1) / 25–40 days plus audit (option 2).**

---

### B7 — The Supabase index cannot say which xployee a mint bought.

`ingest-signature` recognises a mint as *exactly* two `$xNFT` legs — `MINT_BURN` to the incinerator and
`feeOn(MINT_BURN, 500)` to the treasury — reconciled against balance deltas. It is a good design. But
two `transferChecked` instructions carry no room for an xployee id, which the schema comment states:
*"Closing this needs a memo instruction the buyer signs alongside the transfers; nothing currently
builds one."*

If B1 lands, this largely dissolves — the mint transaction creates a real asset with a real address,
and that address is the identifier. If B1 does *not* land, add an SPL Memo instruction to
`buildMintTransaction` carrying the id and have `ingest-signature` read it. Either way, `listings` has
no writer at all (`supabase/README.md`, "Known gaps"), so the index cannot serve a marketplace.

**Effort: 2 days with a memo; folded into B1 otherwise.**

---

### B8 — Ownership is destroyed by clearing browser data.

`src/lib/useHoldings.ts` is the only record of a hire. Clearing site data, switching browsers, or
using a second device loses everything — and after B3 the visitor will have paid 10,500 real `$xNFT`
for it. Worse, `nextId = HIRED_COUNT + current.length` (`useHoldings.ts:51`) means every user's first
hire is `#512`, so "your" xployee is the same object as everyone else's. Closed by B1 and not before.

---

### B9 — Backdrop art provenance. **BLOCKING for a commercial NFT release.**

`README.md:67`: *"the x-rated textures were supplied as stock/search-engine downloads (one is an Adobe
Stock preview ID). For art that becomes the NFT itself, licensing is worth confirming before any
commercial release."* The files bear that out — `public/texture-files/xrated/` contains
`360_F_1916540295_IsJKrZ9lR1xK0rTtYydRBtPDdbM01X7b.jpg` (an Adobe Stock preview filename),
`images (1).jpg`, `images (2).jpg`, `images (4).jpg`, `images.jpg` (browser default download names) and
two others.

These are the backdrops for the rarest 3% of the collection. Selling them as NFTs, minting them to
Arweave permanently, and taking a royalty on secondary sales is commercial use of images you probably
do not have a licence for, and permanence makes takedown impossible. **Either buy proper licences with
the right to redistribute as part of an NFT, or commission/generate replacements.** Note that
`src/lib/backgrounds.ts:100,111-147` records a measured `baseLuma` per scene — any replacement needs
its mean luminance measured and recorded or it renders wrong.

**Effort: 3–10 days depending on replace-vs-license.**

---

### B10 — Smaller items that will bite

| Item | Where | Fix |
|---|---|---|
| `.env.example` documents variables nothing reads | `.env.example:29-36` | Delete `VITE_XNFT_PROGRAM_ID`; either wire `VITE_XNFT_MINT`/`VITE_SOLANA_RPC_URL` or remove them |
| `supabase/README.md` §4 names the wrong secrets | vs `supabase/functions/_shared/env.ts:66-84` | Set `XNFT_MINT_ADDRESS`/`TREASURY_ADDRESS`/`DEV_WALLET_ADDRESS`, not `XNFT_PROGRAM_ID` |
| No `robots.txt`, no OG image, no favicon | `index.html`, `public/` | Trivial, but a link with no preview card on launch day is a real cost |
| No error tracking | — | Sentry or equivalent before real money moves |
| `origin`/CORS on Edge Functions | `supabase/functions/_shared/http.ts` | Confirm the allowed origin list matches the production domain |
| `dist/` is committed to the working tree | `dist/` | It is a build artifact; regenerate rather than deploy a stale one |

---

## 3. Step by step to live

Dependency-ordered. Do not reorder — several steps are irreversible or make later steps expensive.
Commands assume this working directory unless stated.

### Phase 0 — Decisions that must be made before any money is spent

Write these down and get them agreed. Every one of them changes the build.

1. **NFT standard**: Metaplex Core vs Bubblegum vs Token Metadata. (§B1)
2. **Who mints**: buyer-minted with a co-signing backend, or pre-minted and transferred. (§B1)
3. **Marketplace**: external (Tensor/ME) or none at launch. (§B6)
4. **Metadata hosting**: Arweave/Irys vs IPFS vs own CDN. (§B2)
5. **Yield story**: is accrued "yield" paid at all, and out of what? (§5 — this is the compliance
   question, not an engineering one.)
6. **X-RATED backdrops**: license or replace. (§B9)
7. **Supply**: `MAX_SUPPLY = 5000` (`src/lib/xployee.ts:7`) but only 512 exist. Which is the real
   collection size? The metadata and the collection account fix this permanently.

### Phase 1 — Wallets and custody

You need **three distinct wallets**. Do not collapse them; `supabase/functions/_shared/env.ts:78-80`
rejects a config where treasury == dev wallet, and for good reason.

| Role | Holds | Custody |
|---|---|---|
| **Creator wallet** | Launches `$xNFT` on pump.fun; receives SOL creator fees. This is the wallet that funds user payouts. | **Hardware wallet.** It is publicly linked to the coin forever and it accrues real income. |
| **Treasury wallet** (`TREASURY_ADDRESS`) | Its ATA receives the 5%/10% `$xNFT` fee legs. Signs claims. | **Hardware wallet.** Spec §4.4: *"custody of the fee balance is custody of a private key."* Whoever holds it can move the fees anywhere. |
| **Dev wallet** (`DEV_WALLET_ADDRESS`) | Destination of treasury claims. | Hardware wallet, or a multisig (Squads) if more than one person should be able to spend. |

If you also do buyer-minted NFTs (§B1), a **fourth** hot key lives on a server to co-sign mints. Keep
it funded with the minimum SOL it needs and nothing else; treat its compromise as "attacker can mint
xployees", not "attacker drains treasury".

```bash
# Inspect what the CLI is currently pointed at (do NOT print key material).
solana config get

# Derive an address from a Ledger without ever exporting a key:
solana address --keypair usb://ledger

# If you must generate a filesystem keypair (dev/devnet only, never mainnet treasury):
solana-keygen new --outfile ./devnet-treasury.json --no-bip39-passphrase
solana address -k ./devnet-treasury.json
```

**Record, in a password manager, for each wallet:** role, public address, device, seed-phrase backup
location, and who has access. A treasury whose key holder is on holiday is a treasury you cannot claim
from.

### Phase 2 — Paid RPC

Sign up with Helius, Triton or QuickNode and create a **mainnet** and a **devnet** endpoint. If you go
the DAS route for ownership reads (§B1), confirm the provider exposes the Metaplex DAS API — not all
plans do.

You need the URL in three places:

1. `VITE_SOLANA_RPC_URL` in `.env` — **and code that reads it** (§B5; not wired today).
2. `SOLANA_RPC_URL` as a Supabase function secret (Phase 8).
3. Your own CLI: `solana config set --url <endpoint>`.

Why this cannot be skipped: see §B5. The public endpoint will 429 the fourth concurrent minter and the
failure lands on an irreversible action.

### Phase 3 — Devnet dress rehearsal (**before mainnet, no exceptions**)

`README.md:91-92` states the burn path has never been run end to end. Rehearse it against a throwaway
token where a mistake costs nothing.

```bash
solana config set --url https://api.devnet.solana.com
solana airdrop 2
solana balance

# A stand-in for $xNFT. 9 decimals matches XNFT_DECIMALS in src/lib/fees.ts:44.
spl-token create-token --decimals 9
#   => Creating token <DEVNET_MINT>

spl-token create-account <DEVNET_MINT>
spl-token mint <DEVNET_MINT> 1000000
spl-token balance <DEVNET_MINT>

# A devnet treasury and dev wallet.
solana-keygen new --outfile ./devnet-treasury.json --no-bip39-passphrase
solana-keygen new --outfile ./devnet-dev.json      --no-bip39-passphrase
solana address -k ./devnet-treasury.json
solana address -k ./devnet-dev.json
```

Then temporarily set the three constants in `src/lib/spl.ts` to the devnet values, point
`VITE_SOLANA_RPC_URL`/the connection at devnet, `npm run dev`, and walk the whole flow:

- [ ] `BurnGate` arms (it renders the real button instead of `simulatedFallback` — `BurnGate.tsx:55,168`)
- [ ] The quoted total is **10,500** and the transaction contains exactly two `transferChecked`s plus any needed idempotent ATA creates
- [ ] The burn leg lands at `1nc1nerator11111111111111111111111111111111`'s ATA
- [ ] The fee leg lands at the treasury ATA — check with `spl-token balance <DEVNET_MINT> --owner <treasury>`
- [ ] An **underfunded** wallet gets a sentence, not a wallet prompt (`spl.ts:698-706`)
- [ ] A **rejected** signature reports "cancelled — nothing was sent" and does not retry
- [ ] Killing the RPC mid-confirmation resolves as success-with-unknown-status, **not** failure (`spl.ts:878-896`)
- [ ] `ingest-signature` indexes the devnet mint and writes `mints` + `fee_ledger` rows
- [ ] The treasury claim signs from the treasury keypair, lands in the dev wallet, and `confirm-payout` settles the row
- [ ] The double-claim lock holds: a second claim is refused while the first is pending (`usePayouts.ts:472`)

**Then revert the constants to `''` and confirm the app returns to simulated.** A devnet address left
in a mainnet build is a mint that silently does nothing.

### Phase 4 — Art and metadata pipeline (§B2)

1. Write `scripts/render-collection.mjs` importing `src/lib/avatar.ts` unchanged.
2. Resolve the CSS-filter fidelity problem (pre-render the backdrop variants is the safer route).
3. Render N PNGs at a fixed size (512×512 or 1024×1024, nearest-neighbour upscale from 32×32 for the
   sprite layer — never bilinear, or the pixel art turns to mush).
4. Generate metadata JSON per asset.
5. Upload images, rewrite the JSON `image` fields with the returned URIs, upload the JSON.
6. **Record every URI in a file in this repo.** If the upload succeeds and you lose the manifest, you
   cannot mint.
7. Spot-check five assets — one per tier plus one X-RATED — by opening the hosted image next to the
   site's rendering of the same id.

### Phase 5 — NFT integration (§B1)

Build against devnet the whole way. Create the collection asset, mint one, read it back with DAS,
render a Portfolio page from the chain read rather than `useHoldings`. Only when a full mint → own →
display → transfer loop works on devnet does mainnet become a conversation.

### Phase 6 — Launch `$xNFT` and capture the CA

**Irreversible. Do it from the creator wallet, on a machine you trust, with the site already built and
staged so the CA can be wired in immediately.**

1. Go to pump.fun, connect the **creator wallet**, create the coin. Name, ticker, image, description,
   and the links (site, X) — the socials are fixed at creation on most launchpads, so have the domain
   registered (Phase 10) *before* this step.
2. **Copy the CA immediately** and paste it somewhere durable. Base58 is case-sensitive and has no
   checksum you can eyeball; a transcription error is a different token.
3. Verify it independently before wiring it anywhere:

```bash
solana config set --url <your mainnet RPC>
spl-token display <CA>            # decimals, supply, mint authority, freeze authority
solana account <CA>               # owner must be the SPL Token (or Token-2022) program
```

   Check: **decimals** (`src/lib/fees.ts:44` assumes 9 for the simulated market — `spl.ts` reads the
   real value off the mint, but if it is not 9 the simulated marketplace prices and the real debit
   describe different units, and `XNFT_DECIMALS`'s comment says both must be updated together);
   **mint authority is revoked**; **freeze authority is revoked** (a live freeze authority means
   someone can freeze the treasury ATA).
4. Note the pump.fun coin URL and, once liquidity exists, the DexScreener pair URL.

**UNVERIFIED:** pump.fun's creator-fee terms — the rate, whether it differs pre- and post-graduation,
and the claim mechanism — have changed repeatedly. **Read the current terms on the day you launch, take
a screenshot, and record them.** §4.1 and §5 both depend on this and neither can be written for you.

### Phase 7 — Wire the configuration

Two source files, then a rebuild. There is no environment variable for these (§1.2a).

`src/lib/spl.ts` — **owned by another workflow; coordinate the edit:**

```ts
export const XNFT_MINT_ADDRESS: string = '<CA from Phase 6>'
export const TREASURY_ADDRESS:  string = '<treasury pubkey>'
export const DEV_WALLET_ADDRESS: string = '<dev wallet pubkey>'
```

`src/lib/token.ts` — this one is yours to fill in:

```ts
export const XNFT_CA:         string = '<CA>'
export const PUMP_FUN_URL:    string = 'https://pump.fun/coin/<CA>'
export const DEXSCREENER_URL: string = 'https://dexscreener.com/solana/<pair>'
export const TWITTER_HANDLE:  string = 'xnftsdotfun'   // no @, no URL
```

Then, in this order:

```bash
npx tsc --noEmit
npx vitest run
npm run build
```

**Sanity check the built bundle before deploying** — this is the last cheap moment to catch a
transposed address:

```bash
grep -o '<first 8 chars of CA>[A-Za-z0-9]*' dist/assets/*.js | sort -u
```

`isConfigured()` is all-or-nothing by design (`spl.ts:220`): a build with a mint and no treasury would
be a burn that pays no fee.

### Phase 8 — Supabase

Follow `supabase/README.md` **with the §4 correction from §1.2b of this document.**

```bash
# 1. Create the project in the dashboard (needs an org), note the project ref.
npx supabase login
npx supabase link --project-ref <ref>

# 2. Migrations. READ the dry run before letting it write.
npx supabase migration list
npx supabase db push --dry-run
npx supabase db push

# 3. Secrets — these names, not the ones in supabase/README.md §4.
npx supabase secrets set SOLANA_RPC_URL="https://<paid endpoint>"
npx supabase secrets set XNFT_MINT_ADDRESS="<CA>"
npx supabase secrets set TREASURY_ADDRESS="<treasury pubkey>"
npx supabase secrets set DEV_WALLET_ADDRESS="<dev wallet pubkey>"
npx supabase secrets list

# 4. Functions.
npx supabase functions deploy ingest-signature
npx supabase functions deploy request-payout
npx supabase functions deploy confirm-payout
npx supabase functions list
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically and the
CLI refuses to set them. `_shared/` is not deployed as a function — the leading underscore is
load-bearing.

Then in the SQL editor:

```sql
-- Makes `payouts` readable by the operator. Fails closed until it exists.
alter database postgres set app.authority_address = '<treasury pubkey>';
notify pgrst, 'reload config';
```

And schedule the sweep (`supabase/README.md` §6, verbatim) — `pg_cron` + `pg_net`, service-role key in
Vault rather than inline in the job body, every 2 minutes. Without it a payout row hangs pending
forever if the operator's browser closes mid-claim, and `claimLocked` (`usePayouts.ts:472`) then locks
the desk with no client-side escape.

Finally, run the anon-key verification block at the bottom of `supabase/README.md`. Reads must work,
**every write must return 401/403 and never 201**, `payouts` must return `[]` for anon, and
`ingest-signature` must reject an unrelated signature with a 422 regardless of what the body claims.

Then set the browser env and rebuild:

```
VITE_SUPABASE_URL=https://<ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon key>
```

Never put the service-role key in a `VITE_` variable. It bypasses RLS and it would be compiled into
the bundle.

### Phase 9 — Deploy the frontend

`wrangler.jsonc` already configures an assets-only Worker over `./dist` with
`not_found_handling: "single-page-application"`. That last line is load-bearing: without it a shared
deep link to `/marketplace` or `/wallet/<address>` returns Cloudflare's 404 instead of the app.

```bash
npx wrangler login          # interactive browser flow, must be run by a human

npm run deploy:preview      # build + `wrangler versions upload` — a version, not production
# smoke-test the preview URL, then:
npm run deploy              # build + `wrangler deploy` → *.workers.dev
```

Post-deploy checks, in a fresh incognito window:

- [ ] Deep link `https://<app>/marketplace` loads the app, not a 404
- [ ] Deep link `https://<app>/wallet/<any address>` loads
- [ ] Dark mode renders (toggle, then hard reload)
- [ ] The /token page shows the CA and the pump.fun link
- [ ] Prices are `LIVE`, not `CACHED`
- [ ] Connect a wallet with **zero** `$xNFT` — the mint gate must show a shortfall sentence, not a prompt
- [ ] `dist/` was rebuilt from the current source (`npm run build` immediately before deploy — the
      committed `dist/` in this tree is stale by construction)

To roll back: `npx wrangler deployments list`, then `npx wrangler rollback [version-id]`.
**UNVERIFIED** for assets-only Workers specifically on wrangler 4.118 — confirm the rollback path works
on the preview deployment *before* you need it.

### Phase 10 — Domain and DNS

Do this **before** Phase 6, because launchpad socials are usually fixed at coin creation.

1. Register the domain and put it on Cloudflare (nameservers at the registrar → Cloudflare).
2. Attach it to the Worker. Either the dashboard (Workers → your worker → Settings → Domains & Routes →
   Add custom domain), or add a `routes` entry with `custom_domain: true` to `wrangler.jsonc` and
   redeploy. **UNVERIFIED:** the exact `routes` schema for assets-only Workers on wrangler 4.118 —
   check `node_modules/wrangler/config-schema.json`, which `wrangler.jsonc` already references, before
   editing.
3. Cloudflare provisions the certificate automatically for a custom domain. Confirm HTTPS and that the
   apex and `www` both resolve.
4. Update `index.html`'s `<title>`/`description`, add an OG image, add `robots.txt`.
5. Only then create the pump.fun coin with the real URL in its socials.

### Phase 11 — Arm mainnet and take the first mint yourself

1. Deploy with the constants set.
2. **Buy `$xNFT` on the open market with a personal wallet, and mint once.** Not with the treasury —
   the treasury is a party to the transaction and would tell you nothing about the buyer's path.
3. Verify on Solscan: 10,000 to the incinerator ATA, 500 to the treasury ATA, one signature.
4. Verify the `mints` and `fee_ledger` rows appeared in Supabase.
5. Claim from the Payouts desk and verify the row settles to `confirmed` with a verified amount.
6. Only then announce.

### Phase 12 — Go / no-go

Do not launch with any of these unticked.

- [ ] `npx tsc --noEmit` clean, `npx vitest run` green, on the exact commit being deployed
- [ ] Full devnet rehearsal passed (Phase 3), constants reverted afterwards
- [ ] Mint authority and freeze authority on `$xNFT` are revoked
- [ ] Treasury and dev wallet on hardware, backups tested by restoring to a spare device
- [ ] Paid RPC live and actually threaded through the client (not just present in `.env`)
- [ ] Supabase RLS verification block run and passed
- [ ] `confirm-payout` cron scheduled and observed running once
- [ ] Someone is on call for the 3-hour payout promise, or the copy has been changed
- [ ] Counsel has seen §5
- [ ] X-RATED backdrop licensing resolved (§B9)
- [ ] Docs/README describe what is real, matching reality on launch day

---

## 4. Operations

### 4.1 How creator fees actually reach the treasury

They do not — not automatically, and not into the `$xNFT` treasury. Two separate flows:

**Flow A — protocol fees (`$xNFT`).** A mint's fee leg and a rental's fee leg are transfers inside the
same transaction the payer signs (`spl.ts:480-509`). They land in the treasury wallet's associated
`$xNFT` account and stay there. The operator moves them with `buildClaimTransaction` → `sendClaim`,
signed by the treasury keypair, into the dev wallet. That is a one-instruction `transferChecked`;
the destination is a compiled-in constant, **not** an on-chain constraint (spec §4.4).

**Flow B — pump.fun creator fees (SOL).** These accrue to the **creator wallet** from trading activity
and are claimed through pump.fun's own interface or program. Nothing in this repository touches them.
This is the pool `src/pages/Payments.tsx:104-107` promises user payouts from.

**They are not connected.** If user payouts are to come from creator fees, that is a manual step — claim
on pump.fun, hold SOL in the creator wallet, send it out by hand. Write down who does it and how often.
Also write down, before launch, whether the two pools are ever commingled; you will be asked.

**UNVERIFIED:** pump.fun's current creator-fee rate and claim mechanism (§Phase 6).

### 4.2 Settling a payout request within 3 hours

Today this is impossible: the request never leaves the browser (§B4). Assuming B4 is closed, the
runbook is:

1. **Intake.** `payment_requests` row appears with claim ID, wallet, USD, SOL, timestamp.
2. **Alert.** Row insert → Slack/Discord/email within 60 seconds. A queue with no alert is a queue that
   gets worked when someone happens to look.
3. **Verify.** Confirm the requesting wallet actually holds the xployees the amount is derived from —
   a chain read after B1, not a `localStorage` claim. Confirm the amount matches `earningsFor()` at the
   time of the request within tolerance. Confirm no duplicate claim ID has been paid.
4. **Fund.** Check the creator wallet's SOL balance covers it. If not, claim creator fees first — that
   step can itself take longer than the promised window, so **hold a working float**.
5. **Send.** From the creator wallet, with a hardware signature. Record the signature.
6. **Close.** Mark the row `paid`, store the signature, notify the user.
7. **Escalate.** If any step is blocked, the claim ID is what the user quotes; have a human answering
   the X account named in `src/lib/token.ts`.

**Three hours is a hard promise across nights and weekends.** Either staff it, or change
`SETTLEMENT_HOURS` in `src/pages/Payments.tsx:25` and the surrounding copy to something you can meet
(24 hours, one business day). A missed promise on money is more damaging than a slower promise kept.

### 4.3 Records to keep

Assume you will need to reconstruct any of this two years from now, for an auditor, a tax authority, or
a user who says they were not paid.

| Record | Where | Retention |
|---|---|---|
| Every treasury claim: signature, amount, timestamp, destination | Supabase `payouts` + your own export | Permanent |
| Every user payout: claim ID, wallet, USD, SOL, rate used, tx signature, operator | `payment_requests` + a spreadsheet you control | Permanent |
| pump.fun creator-fee claims: date, amount, tx | Manual log | Permanent |
| The SOL/USD rate used for each payout, with its source and timestamp | On the payout row | Permanent |
| Wallet inventory: role, address, custodian, backup location | Password manager | Live document |
| Every deployed frontend version + the CA/treasury/dev addresses compiled into it | Wrangler version history + a changelog | Permanent |
| Migration and secret-change history | `supabase migration list`, a change log | Permanent |
| Screenshot of pump.fun's fee terms on launch day | Anywhere durable | Permanent |
| Art licences / commission agreements | Contracts folder | Permanent |

Supabase is **not** a system of record for money (`src/lib/supabase.ts:5-7`: *"never an authority on a
balance"*). Export `payouts` and `fee_ledger` on a schedule to storage you control.

### 4.4 Monitoring and alerting

**Page a human for:**

- Treasury `$xNFT` balance drops without a matching `payouts` row → possible key compromise. This is
  the single highest-severity alert you have.
- A `payouts` row pending > 30 minutes → the double-claim lock is engaged and the desk is frozen
  (`usePayouts.ts:472`, and note the deliberate design: an *indexed* pending row cannot be released
  from the browser, only server-side).
- `confirm-payout` cron has not run in 10 minutes (`select * from cron.job_run_details order by
  start_time desc limit 10;`).
- Any Edge Function 5xx rate above baseline.
- RPC error rate above ~1% — under B5's design a failed read lands on an irreversible action.

**Watch on a dashboard:**

- Mint rate, treasury balance, `fee_ledger` totals (`sumFees` — sum with BigInt, never a server-side
  `SUM`, which PostgREST would serialise as a lossy JSON number: `supabase.ts:426-435`).
- Price feed `source` — the ratio of `live` to `cached` readings.
- Cloudflare Worker analytics (`observability.enabled` is already true in `wrangler.jsonc`).
- Payment request queue depth and oldest-unpaid age.

**Add before launch:** client error tracking (Sentry), and an uptime check on `/` and on
`https://<ref>.supabase.co/rest/v1/fee_ledger?select=*&limit=1`.

### 4.5 When the price feed degrades

`src/lib/prices.ts` already handles this correctly and needs no code change — know the behaviour so you
do not panic:

- Non-2xx, network failure, unparseable body, or **zero resolved symbols** → `cachedFallback()`:
  every xStock keeps its `referencePrice` from `src/lib/xstocks.ts` and the reading is marked
  `source: 'cached'`. The UI shows a `CACHED` chip. It never blanks, never spins forever, never
  renders `NaN`.
- Partial responses keep reference prices for the missing symbols only.

**What that means operationally:** displayed portfolio values drift from reality but nothing breaks, and
**no money decision depends on an xStock price** — the mint cost is a fixed 10,500 `$xNFT` and the fee
is a fixed bps of it. So a degraded feed is a display incident, not a financial one. Say so publicly
rather than going quiet.

**Escalation:** if Jupiter is down for more than a few hours, the `referencePrice` constants (captured
2026-08-03) become visibly stale. Either refresh them from another source and redeploy, or add a
secondary feed. **Do not** silently substitute a different price source without changing the `CACHED`
label — the honesty of that chip is the whole point.

**If the SOL price feed (B4) fails**, payouts must **stop**, not fall back to a stale rate. A hardcoded
`SOL_USD` sizing a real SOL transfer is exactly the failure `src/lib/earnings.ts:11-15` warns about.

### 4.6 The one incident class that cannot be undone

A burn is irreversible and nobody, including the operator, can recover it. Two rules already encoded in
the client that operations must not undermine:

- A confirmation **timeout** is success-with-unknown-status, never failure (`spl.ts:878-896`). Never
  tell a user to "just try again" after a timeout — check the signature on an explorer first.
- The double-claim lock survives reload and wallet switch by design (`usePayouts.ts:449-472`). If the
  desk is locked, the fix is server-side; do not add a client escape hatch for indexed rows.

---

## 5. Risk and compliance

**I am not a lawyer and this is not legal advice.** What follows is a description of exposure so that
counsel can be briefed properly. Get a securities lawyer with digital-asset experience, in every
jurisdiction you will accept users from, **before** launch — not after.

**1. Paying users from creator fees looks like a distribution to investors.**
`src/pages/Payments.tsx` promises SOL to holders, funded by trading fees on a token, in an amount that
scales with how much of that token they burned. That is a profit-sharing arrangement whose returns
derive from the efforts of the promoter. Under the *Howey* framing used in the US — and analogues
elsewhere — that combination is what a securities regulator looks for. It does not matter that the
underlying "yield" is simulated; the payment is real.

**2. Presenting yield on tokenized equities compounds it.**
The product's core claim is that xployee skills work desks tied to real tokenized equities and produce
yield. The tickers and prices are real (`src/lib/xstocks.ts`, `src/lib/prices.ts`), which makes the
association concrete rather than thematic. But **no capital is deployed anywhere** — `accruedTotal()`
is arithmetic over a hire timestamp. Two distinct problems: (a) offering a return referenced to
securities may itself be a regulated activity; (b) presenting a computed number as investment
performance when nothing is invested is a misrepresentation risk independent of securities law.
Backed Finance's xStocks have their own restrictions on who may hold and how they may be referenced —
**check them.**

**3. Sending SOL to users on request has money-transmission characteristics.**
Receiving value (token burns) and disbursing value (SOL payouts) to third parties, at their request,
by hand, is the shape of a money services business in several jurisdictions. Whether it *is* one turns
on facts your lawyer needs. Related: no KYC, no AML screening, no sanctions screening, and no
geoblocking exists anywhere in this codebase.

**4. Treasury custody is a single private key.**
Spec §4.4: *"custody of the fee balance is custody of a private key."* There is no PDA, no multisig, no
time-lock, no on-chain cap on the fee rate. If you hold user-attributable funds in it, you are a
custodian in substance. Consider Squads multisig at minimum.

**5. The fee is not enforced by anything but this bundle.**
Also §4.4: the guarantee moved from *"the chain will not execute an untaxed trade"* to *"this client
will not compose one."* Any public claim that fees are protocol-enforced would be false.

**6. Sale records will describe things that did not happen.**
`supabase/migrations/20260805120000_protocol_tables.sql` is admirably blunt: *"NOTHING IN HERE
HAPPENED ON A BLOCKCHAIN."* That is fine while the collection is openly simulated. **After B1 it is
not** — a `trades` row for a real NFT that did not move is a false record about a real asset.

**7. Art provenance (§B9).** Selling, permanently storing, and taking a royalty on images sourced from
stock previews and search-engine downloads is commercial use of third-party work. Arweave makes it
un-deletable. Resolve before minting, not after.

**8. Marketing language.** "Yield", "APY", "principal", "capital deployed", "book value", "earnings"
are all financial terms of art and they are used throughout the UI. They are honest descriptions of a
simulation and a poor fit for a product that pays real money. Have counsel review the copy on
`src/pages/Docs.tsx`, `Overview.tsx`, `Portfolio.tsx` and `Payments.tsx` specifically.

**The single most useful thing you can do before spending money on engineering: take §1's table, §2's
gaps and this section to a lawyer, and ask which of the six paths in §6 is defensible.** The answer may
delete half the roadmap, and that is much cheaper to discover now.

---

## 6. What I would cut — the minimum viable launch

The full list above is ~50–75 engineer-days plus legal. Here is what I would actually ship, and what I
would defer.

### Ship (must have)

| # | Item | Why it cannot wait | Days |
|---|---|---|---|
| 1 | **Real NFT** (Metaplex Core, buyer-minted, deterministic traits committed to metadata) | Without it there is no product. A paid mint that returns a `localStorage` row is indefensible the moment real money moves. | 15–25 |
| 2 | **Art + metadata on Arweave** | The NFT is the image. There is no image. | 8–12 |
| 3 | **Art licensing resolved** | Legal, and permanence makes it unfixable later. | 3–10 |
| 4 | **`$xNFT` launched, CA wired, devnet-rehearsed** | The whole economy is denominated in it. | 2 |
| 5 | **Paid RPC, threaded through the client** | The public endpoint fails at the fourth concurrent minter, on an irreversible action. | 1–2 |
| 6 | **Hardware custody for three wallets, documented** | One key loss ends the project. | 1 |
| 7 | **Supabase deployed with the corrected secret names, cron scheduled, RLS verified** | The index and the payout desk are dead without it — and the README will mislead you. | 2 |
| 8 | **Ownership read from chain; `useHoldings` deleted** | Otherwise a paid asset is destroyed by clearing browser data. | 3 |
| 9 | **Frontend deployed to a real domain, deep links verified** | — | 1 |
| 10 | **Legal review of §5** | Determines whether 11 and 12 are legal at all. | — |
| 11 | **Payments either backed by a real queue, or removed** | Do not ship a 3-hour promise into `localStorage`. **Removing the page is a legitimate ship decision** and it is the one I would take for v1. | 0 or 5–8 |
| 12 | **Honest docs matching launch-day reality** | The current README's "what's real vs simulated" section is the best thing in this repo. Keep it true. | 1 |

**Total: roughly 37–67 days, plus legal.**

### Defer (phase 2)

| Item | Why it can wait | Interim |
|---|---|---|
| **On-chain marketplace / escrow** | Tensor and Magic Eden already solved it, for free, the day your collection is a real Metaplex collection. | Link out. Delete or clearly gate the internal marketplace. |
| **Rental contracts** | `buildRentTransaction` exists but has **no UI at all** (`README.md:114`). It is a whole feature, not a wiring job. | Hide the Contracts tab. |
| **`listings` table writer** | Nothing populates it and nothing can (`supabase/README.md`, Known gaps). | Moot if the marketplace is external. |
| **xNET / social / DMs / trade offers** | 1,045 lines of `network.ts` + `social.ts` that are pure simulation over fake wallets. Beautiful, and after B1 they describe a world that does not exist. | Keep as an explicitly-labelled demo, or hide. |
| **`mints.xployee_id`** | Dissolves once a mint creates a real asset with a real address (§B7). | — |
| **Live SOL price feed** | Only needed if payouts ship. | Blocked with payouts. |
| **Yield accrual as a real mechanism** | There is no capital and no strategy. Making the yield real is a fund, not a feature. | Label the number as a simulated score, or remove it. |

### The cut I would argue hardest for

**Ship the collection without the yield and payout story.** A generative pixel NFT collection with a
real token, real prices on real tokenized equities as *flavour*, an honest simulated "desk" score, and
no promise of payment is a product you can launch in ~5 weeks with a fraction of the legal exposure.
Adding "and we will send you SOL proportional to a number we compute" converts a collectible into
something a regulator has an opinion about, and it is the single largest source of risk in §5 — for a
feature (`src/pages/Payments.tsx` + `src/lib/earnings.ts`, ~610 lines) that no one has asked for yet.

Everything else in this document is engineering. That one is a business decision, and it should be made
before the engineering starts.

---

## 7. Open questions I could not answer from the repository

Flagged so nobody mistakes silence for a conclusion.

1. **Is the collection 512 or 5,000?** `HIRED_COUNT = 512` (`collection.ts:8`) vs `MAX_SUPPLY = 5000`
   (`xployee.ts:7`). The metadata and collection account fix this permanently.
2. **What actually funds the yield?** Nothing in the repository deploys capital. If the answer is
   "creator fees", the yield is a marketing number and §5.2 applies.
3. **pump.fun's current creator-fee terms.** Rate, pre-/post-graduation split, claim mechanism.
4. **Exact rent for the chosen NFT standard.** Size the account, run `solana rent`.
5. **The `routes`/`custom_domain` schema for assets-only Workers on wrangler 4.118.** Check
   `node_modules/wrangler/config-schema.json`, which `wrangler.jsonc` already `$schema`-references.
6. **Whether Backed Finance's terms permit referencing xStocks this way.** Not answerable from code.
7. **Who is the operator, and where do they live?** Determines which regulator's rules apply, which
   determines most of §5.

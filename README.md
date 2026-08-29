# xNFTs

> **You don't buy a token. You hire an employee.**

An **xployee** is a generative pixel worker on Solana. Every xployee has **skills**, and each skill works a desk tied to a real tokenized equity (**xStocks**: AAPLx, NVDAx, JPMx, SPYx, GLDx, TBLLx). Skills are the yield engine — more skills, more desks, more streams paying into the xployee's book.

Hold one, **contract** it out for a fixed fee, or **sell** it with its book attached.

## Run it

```bash
npm install
```

```bash
npm run dev
```

Opens on <http://localhost:5181>.

```bash
npm test
```

## Deploy (Cloudflare)

Configured and dry-run verified — it needs your Cloudflare login, which is an interactive browser flow:

```bash
npx wrangler login
```

```bash
npm run deploy
```

That builds and publishes `dist/` as an assets-only Worker, returning a `*.workers.dev` URL you can share. `npm run deploy:preview` uploads a version without promoting it to production.

[wrangler.jsonc](wrangler.jsonc) sets `not_found_handling: "single-page-application"`. That line is load-bearing: this is a client-side router, so without it a shared deep link to `/marketplace` or `/wallet/<address>` returns Cloudflare's 404 instead of the app.

## Theme

There is **one** theme: white paper, black ink. No dark mode, no toggle, no `localStorage` preference — the chrome is a single palette defined once in [src/index.css](src/index.css).

Everything is built on the `paper` / `ink` / `ink-mute` / `ink-faint` / `rule` / `wash` tokens, plus `up` / `down` / `money` for figures. Style new components with those rather than literals: a hardcoded `#fff` looks identical today and is the thing that has to be hunted down the day the palette moves.

Rarity hues are the exception, and deliberately so — they are identity, not chrome, and they live in [src/lib/tiers.ts](src/lib/tiers.ts) beside the tier that owns them.

## Rarity is positional

Rarity is not rolled. The collection is laid out **rarest-first across the 5,000 serials**, so a serial number *is* the rarity claim: `tierForId()` in [src/lib/tiers.ts](src/lib/tiers.ts) maps a serial to its band, and the band decides skill count, colour and backdrop treatment.

| Tier | Serials | Skills | Colour | Treatment | Supply |
|---|---|---|---|---|---|
| Uncommon | `#2000`–`#4999` | 1 | `#44AF63` green | Flat neutral backdrop | 60% |
| Rare | `#0750`–`#1999` | 2 | `#1D84DE` blue | Vivid solid backdrop | 25% |
| Epic | `#0150`–`#0749` | 3 | `#D211B0` magenta | Violet drift on the type, procedural ray backdrop | 12% |
| X-RATED | `#0000`–`#0149` | 4 | `#FF1B1B` laser red | Laser shine sweep + embers, scenic backdrop | 3% |

The boundaries are **derived** from each tier's `supply` share, not written out as literals, so editing a share moves the bands with it and the table above is the only place the two can drift. Rounding is absorbed by the last band — a share table that rounds down must not leave a gap, because a gap is a serial no xployee can occupy.

### Why serials are shuffled

Positional rarity has an obvious failure mode: hand serials out in ascending order and the first 150 mints take **every** X-RATED in existence, while everything after `#2000` is uncommon forever. The mint stops being a lottery and becomes a queue position.

So serials are dealt from a **seeded reveal permutation** — `mintOrder()` in [src/lib/collection.ts](src/lib/collection.ts) shuffles all 5,000 serials once and `serialForMint(n)` hands out the *n*th entry. Every minter draws from the same bag regardless of when they arrive, and low numbers stay genuinely rare rather than merely early. The shuffle is seeded and cached, so the permutation regenerates identically on every machine with no database — the same property the rest of the collection relies on.

One consequence for anyone touching the code: **a serial is not an array index.** Serials are dealt out of the shuffle, so they are non-contiguous and `collection()[id]` returns the wrong xployee — or, now that the collection ships with one holding, nothing at all. Look up by serial with `byId()`, which resolves any serial in the supply whether or not anyone owns it.

Colour appears **only** on rarity elements. The rest of the interface is white paper and black ink, which is what makes a tier readable at a glance across a dense grid.

Two rules keep the art system coherent:

- **The character never carries tier colour.** Skin, hair and fabric palettes are neutral, so rarity is signalled once — by the backdrop — instead of twice.
- **The avatar is transparent outside its silhouette.** That is the load-bearing invariant: fill the background and every scenic backdrop disappears. It is unit-tested.

X-RATED backdrops are the scenic images in `public/texture-files/xrated/`, square-cropped and recoloured per-xployee with CSS filters so each image yields several distinct variants. Uncommon and Rare are deliberately flat and weather-free; Epic and X-RATED get particle overlays (snow, rain, thunder, embers, stars).

> **Backdrop asset provenance:** the x-rated textures were supplied as stock/search-engine downloads (one is an Adobe Stock preview ID). For art that becomes the NFT itself, licensing is worth confirming before any commercial release.

## Pages

`Overview` · `Marketplace` · `Mint` · `Portfolio` · `xNET` · `Docs`, plus `Transactions` and `Profile` in the wallet menu

## Burn to mint — READ BEFORE ENABLING

Minting debits **10,000 $xNFT** in one transaction and burns every one of them at Solana's
incinerator (`1nc1nerator11111111111111111111111111111111`). **One** `transferChecked` instruction,
one signature, one destination. There is **no protocol fee on a mint** — no treasury leg, no second
transfer, and no fee constant sitting at zero waiting to be filled in. The burn is **irreversible**;
nobody, including the operator, can recover it.

There is no on-chain program — none was ever deployed. Every real transfer this app makes is composed
from plain SPL Token instructions in [src/lib/spl.ts](src/lib/spl.ts), which carries no arithmetic of
its own: every amount comes from [src/lib/fees.ts](src/lib/fees.ts).

Because the mint takes no fee, there is nothing about it left for a program to have enforced. The one
thing a client could still get wrong is the *amount*, and that is a convention of this codebase —
`MINT_BURN` in `fees.ts`, pinned by tests, binding on this client and on nothing else. A transaction
composed elsewhere can send any amount it likes to the incinerator and the chain will take it.

The two remaining rates, `SIM_SALE_FEE_BPS` and `SIM_RENT_FEE_BPS`, price the **simulated**
marketplace. Sales are Supabase ledger entries; the rent transfer builder exists but is wired to
nothing. Neither rate is charged on a mint, which is why both carry the prefix.

It is **disabled by default**. Three constants at the top of `spl.ts` — `XNFT_MINT_ADDRESS`,
`TREASURY_ADDRESS`, `DEV_WALLET_ADDRESS` — are empty strings. Minting is gated on the first alone
(`isMintConfigured`), because it is the only address a mint touches; the rent and payout builders are
gated on all three (`isConfigured`). While the relevant ones are empty every path refuses and builds
nothing, and minting falls back to simulated. To go live:

1. Set `XNFT_MINT_ADDRESS`. That is the whole requirement for minting — it pays no configured wallet,
   so demanding a treasury address before it would gate a transaction on something it never uses.
   Set the other two only if you intend to exercise the payout desk.
2. Replace `DEFAULT_RPC` — the public endpoint is rate-limited and will fail under load.
3. Test on devnet with a throwaway mint first. **This path has never been exercised against a live
   token**; it is written to the SPL spec but has not been run end to end.

Safety properties worth preserving if you touch it: destinations are read from configuration and
never taken as parameters (otherwise a burn helper becomes an arbitrary-transfer primitive);
building and sending are separate calls; nothing sends without a click; decimals *and* the token
program are read off the mint rather than assumed; money is `bigint` raw units throughout; nothing
throws, every failure is a typed error the UI renders; and a confirmation timeout is treated as
success-with-unknown-status, never as failure — presenting a possibly-landed burn as failed is how
you get a duplicate of an irreversible transfer.

There is an `anchor/` directory. It is **dead code** — an abandoned Solana program that was never
compiled. See [anchor/ABANDONED.md](anchor/ABANDONED.md); do not treat anything in it as true.

Solana's libraries need Node's `Buffer`, which Vite does not provide. [src/polyfills.ts](src/polyfills.ts)
supplies it and **must stay the first import in `main.tsx`** — `spl-token` touches `Buffer` while it
evaluates, so assigning it later throws at import time. They are also lazy-loaded on the Mint page
only, keeping ~253kB out of the main bundle.

## What's real vs simulated

**Real, live:** every xStock mint address (verified against Jupiter's token registry) and every price shown, polled live from Jupiter. Kill the network and the app degrades to captured reference prices with a `CACHED` chip — it never blanks or renders `NaN`.

**Real, but disarmed:** the money paths. `spl.ts` builds genuine SPL Token transactions for three operations — the **mint** (10,000 burned + 500 fee), a **rental payment** (owner's take + the 10% fee), and a **treasury claim** (operator → dev wallet). All three refuse to build anything while the three configuration constants are empty, which is how they ship. Only the mint is wired to a button today; rent and claim exist at the transaction layer and have no UI yet.

So the wallet is **not** read-only: connect one with minting configured and the app will ask you to sign a real transfer. Nothing sends without a click, and every amount is stated before the button.

**Simulated:** everything else, including **sales**. A sale is the one operation that needs both sides to deliver at once, and an atomic swap without an escrow program requires both parties to co-sign the same transaction — which a marketplace cannot arrange, since the seller has walked away by the time a buyer arrives. Escrow is what the abandoned program actually bought, so buying an xployee is a ledger entry and says so. Every xployee’s identity, art, book and yield is generated deterministically in-browser from its serial, so the collection regenerates identically on any machine with no database. Your own hires persist to `localStorage`.

**What ships is empty.** The index carries one holding — `#0000`, X-RATED, the project wallet — and nothing else: no listings, no other wallets, no activity, no earnings history. Earlier builds seeded 512 xployees across 97 invented wallets with an ≈18% order book rolled on top, which is the right shape for a demo and a fabricated history for a launch. The landing page shows a `showcase()` of unminted workers so the art is still visible; they are owned by nobody and counted in nothing.

**What is not enforced.** With no program, the treasury is an ordinary wallet whose keypair the operator holds — not a PDA. A payout claim is an authorization the operator performs, not a permission the chain grants; whoever holds that key can move the fees anywhere. The fee holds inside any transaction this app builds, but nothing stops a trade arranged outside it, and there is no on-chain ceiling on the rate. [The spec](docs/superpowers/specs/2026-08-05-onchain-fees-supabase-design.md) §4.4 accounts for exactly what that trade cost.

## Stack

Vite · React 19 · TypeScript · Tailwind v4 · react-router 7 · TanStack Query · Wallet Standard

## Fonts

| Role | Face |
|---|---|
| The xNFTs wordmark, and nothing else | **m42** (`public/fonts/m42.ttf`) |
| Labels, nav, panel titles, badges | **Roboto Bold** (`@fontsource-variable/roboto`, Apache 2.0) |
| Body copy | **Geist Sans** (`@fontsource-variable/geist`, SIL OFL) |
| Numerals, tables, addresses, tickers | **Geist Mono** (`@fontsource-variable/geist-mono`, SIL OFL) |

m42 is a 2001 caps-only bitmap face — characterful at display size, illegible as UI, so it is confined to the wordmark. The wordmark fakes lowercase: a 24px `X`, a 42px `NFT`, a 24px `S`.

The label voice is the `.ui` class — Roboto at weight 700, uppercase, tracked — at the fixed sizes `ui-10 / 11 / 12 / 14 / 18 / 22`. Those names are historical: each renders one step larger than its name (`ui-10` is 11px), because bold type needs the extra room. Tracking is `0.07em` rather than Geist's `0.09em`; Roboto Bold is denser, and at the wider setting a bold uppercase run reads as spaced-out instead of as a label. Anything that should align in a column or read as data uses `.mono`.

## xBoss banners

| Rank | Treatment |
|---|---|
| **xCEO** | Antique-gold gradient plate, white label, white metallic sweep on a 3.6s loop |
| **VP** | Royal blue `#2545C4`, white label |
| **DIRECTOR** | Black, white label |
| **BOSS** | Quiet grey outline — deliberately unchanged, so the ladder reads bottom-to-top |

The gold is anchored deep (`#7a5c0e` → `#d8b34a`) rather than on a bright mid-gold: white on mid-gold is barely legible, so the brightness lives in the sweep and the label carries a shadow. The sweep is an absolutely-positioned layer animating `transform`, not `background-position`, so it stays on the compositor — a directory of badges would otherwise repaint continuously.

The lowercase `x` in `xNFTs`, `xployee` and every ticker (`$AAPLx`) is the brand — `.keep-case` exists to protect it from the uppercase rule. Don't remove it.

Panel titles need `truncate` + `min-w-0`, or long titles wrap as flex items and the black bar balloons to four rows.

## Backdrop exposure

The seven X-RATED source images span a 13× luminance range (13 for the near-black vaporwave grid, 172 for the daylit ridgeline). Rolling one brightness range across all of them crushes the night scenes to black tiles. Each scene therefore carries a measured `baseLuma`, and brightness is derived to normalise it toward `TARGET_LUMA` — not rolled blind. If you add a source image, measure its mean luminance and record it, or it will render wrong.

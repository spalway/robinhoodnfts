# xNFTs — Design Spec

**Date:** 2026-08-03
**Status:** Approved — building
**Location:** `C:\Users\skizp\crypto\new_projects\xnfts`

---

## 1. Concept

> **You don't buy a token. You hire an employee.**

**xNFTs** is the protocol. An **xployee** is one unit — a generative pixel worker on Solana. Every xployee has **skills**, and each skill works a desk tied to a tokenized equity (**xStocks**: AAPLx, NVDAx, JPMx, SPYx, GLDx, TBLLx). Skills are the yield engine: more skills, more desks worked, more streams paying into the xployee's vault.

You can hold an xployee, **contract** it out to someone else for a fee, or **sell** it outright.

### Vocabulary

| Term | Meaning |
|---|---|
| **xployee** | One NFT — the worker |
| **Skill** | One yield-producing specialization, tied to an xStock desk |
| **Book** | The xployee's vault of accrued xStocks |
| **Contract** | A rental: renter takes the yield for a term, owner keeps the asset + fee |
| **Epoch** | 24h accrual / settlement cycle |
| **$XPL** | Payroll token — the unit contracts and listings are priced in |

### Positioning

A fully-realized protocol front end. Financial state is simulated deterministically (§7). Prices are live where available. No funds move and no program is deployed; DOCS carries that disclosure explicitly (§6.8).

---

## 2. Rarity → skills

Rarity **is** skill count. This is the spine of the whole product — it drives the art, the yield, and every price in the marketplace.

| Tier | Skills | Color | Treatment | Supply |
|---|---|---|---|---|
| **Entry-Level** | 1 | Muted green `#5f8c5a` | Flat, deliberately bland | 60% |
| **Mid-Level** | 2 | Blue `#3a6ea5` | Slightly richer, subtle sheen | 25% |
| **Expert** | 3 | Magenta `#c33fa8` | Animated glow | 12% |
| **X-RATED** | 4 | Red `#d92b2b` | Pixel flame on the rarity badge | 3% |

The tier ramp is intentional: Entry-Level looks boring *on purpose*, so the jump to Expert glow and X-RATED flame lands hard. Rarity is legible across a whole grid at a glance, from color alone.

### 2.1 Skill registry

Sixteen skills for trait diversity. Each maps to a desk, an xStock, and a base yield rate.

| Skill | Desk | Ticker | Base APY |
|---|---|---|---|
| Silicon Analyst | Semis | NVDAx | 9.2% |
| Platform Ops | Megacap Tech | AAPLx | 7.4% |
| Cloud Architect | Enterprise SW | MSFTx | 7.1% |
| Ledger Clerk | Financials | JPMx | 6.3% |
| Card Rails | Payments | Vx | 5.8% |
| Crude Desk | Energy | XOMx | 8.1% |
| Grid Tech | Utilities/Industrial | HONx | 5.2% |
| Trial Nurse | Pharma | LLYx | 6.7% |
| Claims Adjuster | Health Ins. | UNHx | 5.9% |
| Shelf Stocker | Staples | KOx | 4.4% |
| Brand Manager | Consumer | PGx | 4.6% |
| Index Ballast | Broad Market | SPYx | 4.0% |
| Bills Desk | T-Bills | TBLLx | 4.8% |
| Vault Keeper | Gold | GLDx | 3.2% |
| Chain Teller | Crypto Equity | COINx | 12.6% |
| Treasury Degen | Crypto Proxy | MSTRx | 14.1% |

High-APY skills (Chain Teller, Treasury Degen) are weighted rarer in the draw, so a 4-skill X-RATED holding both is genuinely scarce — and the marketplace prices it accordingly.

### 2.2 Skill assignment

Pure function, `seed → skills`:

1. Draw tier from the supply distribution above.
2. Draw `tier.skillCount` **distinct** skills, weighted so high-APY skills appear less often.
3. Each skill gets a proficiency roll (60–100%) scaling its effective APY.

xployee APY = Σ (skill base APY × proficiency) ÷ skill count, so a 4-skill worker earns from four desks but each contributes a fraction — more skills means more yield *and* more diversification, never a flat 4× multiplier.

### 2.3 Visual traits

Independent of tier, for silhouette diversity: **uniform** (8), **head/hair** (10), **face** (8), **accessory** (10, includes "none"). All rendered in the tier palette, so tier stays instantly readable while individuals stay distinct.

---

## 3. Marketplace

The reason the collection has a floor. Two modes on one page.

### 3.1 Buy / Sell
Ownership transfers. Listings show avatar, tier, skills, APY, book value, ask price in $XPL. Sortable by price, APY, tier, skill count. Owners list from HOLDINGS.

### 3.2 Contract (rent)
The differentiated mechanic. An owner lists an xployee at **X $XPL per epoch for N epochs**. The renter pays up front and receives **all yield the xployee produces during the term**. The owner keeps the asset and the fee.

The trade is legible in both directions: renter profits if realized yield beats the fee; owner takes guaranteed income instead of variable yield. Each listing shows fee, term, projected yield, and implied renter margin so the bet is explicit.

Contracts auto-expire at term end and the xployee returns to its owner. Active contracts appear in HOLDINGS for both sides.

---

## 4. Mechanic

1. **HIRE (mint)** — pay the mint price; the xployee's skills open their desks.
2. **ACCRUE** — each skill pays into the Book every epoch. Per-NFT, not per-claim — skipping a claim never forfeits yield.
3. **CLAIM / COMPOUND** — take yield to wallet, or roll it back into the desks.
4. **CONTRACT / SELL** — rent the worker out, or sell it with its Book attached.

Supply: **5,000 max.** Simulated current state: **512 hired.**

**Trailing APY** — accrued yield over the trailing 30 epochs ÷ average Book NAV, annualized ×12.17. Under 30 epochs it annualizes over actual lifetime and carries an `EST` chip.

---

## 5. Visual design

**White ground, black chrome, color reserved exclusively for rarity.**

That restriction is the core rule. Because no UI element competes for color, a green/blue/magenta/red badge reads instantly at any density. Retro, clean, professional — never toy-like.

### 5.1 Tokens

| Token | Value | Use |
|---|---|---|
| `--paper` | `#ffffff` | Page ground |
| `--ink` | `#000000` | Text, borders, filled section headers |
| `--ink-mute` | `#6b6b6b` | Secondary text |
| `--ink-faint` | `#9a9a9a` | Captions |
| `--rule` | `#d9d9d9` | Table hairlines |
| `--wash` | `#f6f6f6` | Zebra rows |
| `--t1` … `--t4` | tier colors §2 | Rarity only |

### 5.2 Type

Two faces only.

| Role | Face |
|---|---|
| Headers, section labels, badges, nav, **stat numerals** | **m42** (`m42.TTF`, local) |
| Body copy, tables, docs | **Geist Pixel Square** (`geist`, OFL) |

m42 is a 2001 bitmap face — crisp only at its native size and integer multiples. Label sizes are locked to a fixed scale (11 / 14 / 22 / 40px) with `-webkit-font-smoothing: none`, never fluid-scaled.

*License note: m42 is freeware whose readme forbids commercial bundling; the user holds a separate commercial license. Kept behind a single font token for one-edit swapping.*

### 5.3 Header

Modeled on the FASTEST reference:

- **xNFTs** wordmark far left, m42, large (40px) — dominant.
- A **vertical rule** separating wordmark from navigation.
- Slim, tight nav tabs (m42, 11px, uppercase, generous tracking): OVERVIEW · EXPLORE · MARKETPLACE · HISTORY · MINT · HOLDINGS · TREASURY · DOCS.
- **CONNECT WALLET** as a solid black block button, far right, square corners.

Header is white with black labels. Section headers invert — solid black bar, white m42 label — which is what gives the page its retro-industrial rhythm.

### 5.4 Avatars

24×24 pixel workers, canvas-rendered with `image-rendering: pixelated`, crisp from 40px grid cells to 400px reveal. Composed from trait layers, palettized by tier.

- **Expert** — animated glow behind the portrait.
- **X-RATED** — animated pixel flame on the rarity badge, drawn on canvas frame-by-frame, not a GIF.

Both effects respect `prefers-reduced-motion` and fall back to a static treatment.

---

## 6. Pages

1. **OVERVIEW** — stat strip (hired of 5,000, protocol NAV, lifetime yield, next epoch, floor price, avg APY), tier distribution bar, recent hires, top-earning desks, how-it-works.
2. **EXPLORE** — full collection grid; filters by tier, skill, APY band, contract status.
3. **MARKETPLACE** — §3. Buy/sell and contract listings.
4. **HISTORY** — epoch ledger: accruals, sales, contracts opened/expired, execution prices. Dense log table.
5. **MINT** — hire flow. Avatar rolls, reveal shows tier, skills, and opening desks. Wallet required.
6. **HOLDINGS** — your xployees, Books, accrued yield, claim/compound, list for sale or contract, plus contracts you've taken.
7. **TREASURY** — protocol aggregate by ticker with live prices, revenue, fee schedule, reserve ratio.
8. **DOCS** — mechanism spec, skill and tier tables with rarity, contract math, fee schedule, risk disclosures, **simulation disclosure**.

---

## 7. Architecture

Vite + React 19 + TypeScript + Tailwind v4 + react-router-dom v7 — matching the `hoodpeg` convention.

### 7.1 Determinism

Seeded RNG (mulberry32 over a hash of the mint address) drives tier, skills, proficiency, visual traits, and hire timestamps. The 512-of-5,000 collection regenerates identically everywhere with no database. Accrual is a **pure function** of `(hireTime, now, skills, prices)`, so yield ticks live with nothing stored. The user's own hires, listings, and contracts persist to `localStorage`.

### 7.2 Modules

| Module | Responsibility |
|---|---|
| `lib/rng.ts` | mulberry32 + string hashing |
| `lib/xstocks.ts` | Ticker registry — symbol, mint address, sector |
| `lib/skills.ts` | Skill registry; weighted draw |
| `lib/tiers.ts` | Tier table, palettes, supply distribution |
| `lib/xployee.ts` | `seed → xployee` (tier, skills, traits) |
| `lib/avatar.ts` | `traits → 24×24 pixel grid` |
| `lib/flame.ts` | Doom-fire simulation for the X-RATED badge |
| `lib/accrual.ts` | Book NAV, accrued yield, APY |
| `lib/market.ts` | Listings, contracts, floor price, projected margin |
| `lib/collection.ts` | Deterministic collection + epoch ledger |
| `lib/prices.ts` | Jupiter fetch + fallback |
| `lib/wallet.tsx` | Wallet Standard provider/hook |
| `lib/format.ts` | Number, currency, address formatting |
| `lib/useNow.ts` | Ticking clock that drives live accrual |
| `lib/usePrices.ts` | Polled price query |
| `lib/useHoldings.ts` | The visitor's own hires, localStorage-backed |

The fire simulation lives in `lib`, not in the component, for a specific reason:
`requestAnimationFrame` is paused whenever a page isn't being composited, which
makes canvas animation impossible to verify in-browser. As a pure state machine
it is unit-testable, and the component paints one settled frame on mount so the
badge is correct even when animation never runs.
| `components/ui.tsx` | Panel, StatTile, DataTable, Badge, Button |
| `components/PixelAvatar.tsx` | Canvas renderer + tier effects |
| `components/Layout.tsx` | Header, nav, status bar |
| `pages/*.tsx` | Eight pages |

### 7.3 Wallet

Wallet Standard (`getWallets()`) rather than the full adapter stack — detects Phantom / Solflare / Backpack, connect + address display, no imported modal CSS so the button stays in-aesthetic. Falls back to `window.phantom.solana`. **Read-only: never requests a signature, never builds a transaction.**

### 7.4 Prices

Jupiter price API against real xStocks mints, polled every 30s via TanStack Query. Mint addresses are verified during implementation and baked into `lib/xstocks.ts` as constants — never resolved at runtime.

**Failure handling is a requirement.** On unreachable/rate-limited API or unresolved symbol, fall back to baked-in reference prices and show a `CACHED` chip. The UI must never blank, spin forever, or render `NaN`.

### 7.5 Error handling

Route-level `ErrorBoundary`; price failure → `CACHED`; no wallet → install guidance panel, not a dead button; rejected connect → recoverable inline message; unknown xployee id → in-aesthetic 404.

### 7.6 Testing

Vitest over pure modules: RNG determinism; tier distribution within tolerance over 5,000 seeds; skill count matches tier; skills always distinct; accrual monotonic and zero at t=0; contract margin math; format helpers. UI verified in-browser.

---

## 8. Out of scope

Deployed program, real transactions, signing, backend, secondary-market integration, real custody of xStocks.

---

## 9. Success criteria

1. Eight pages build and render with zero console errors.
2. Collection generates identically across reloads and machines.
3. Yield accrues visibly in real time with no stored state.
4. Live prices load; network loss degrades to `CACHED` without breaking a page.
5. Wallet connects with Phantom, shows truncated address.
6. Tier is identifiable at a glance from color alone across a full grid.
7. Expert glow and X-RATED pixel flame animate, and respect `prefers-reduced-motion`.
8. Marketplace supports both buy/sell and contract listings with legible margin math.
9. Color appears **only** on rarity elements — nowhere else in the chrome.
10. Math modules pass vitest.

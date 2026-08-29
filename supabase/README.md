# xNFTs — Supabase backend

The database, the index and the payout queues for a protocol with **no on-chain
program**.

Supabase is **never** the authority on a token balance. Where the chain has an
opinion — a burn, a treasury transfer — this database is a read model rebuilt
from signatures, and if the two disagree the chain is right. Where the chain has
no opinion — who owns which xployee, what is listed, who is friends with whom,
what a wallet has claimed — this database *is* the authority, because nothing
else is.

---

## What is real and what is simulated

There is no Anchor program. There never will be one; the `anchor/` directory is
abandoned and nothing here reads it, builds it or matches its layouts.

| | Real? | How |
|---|---|---|
| **Mint** | Real | **One** `transferChecked`: 10,000 $xNFT to `1nc1nerator11111111111111111111111111111111`. No fee, no treasury leg, no second amount. Every token a buyer spends is burned. |
| **NFTs** | **Not on Solana** | An xployee is a row keyed by serial 1..5000. Ownership lives in Postgres, not in a token account. Minting assigns a serial; it does not create a token. |
| **Rent** | Real *or* simulated | A chain-verified rental (renter pays the owner + 10% to the treasury) still ingests into `fee_ledger`. The rentals the app actually creates are rows in `public.rentals`. Check `origin`. |
| **Sale** | **Simulated** | Escrow was the one thing the program genuinely bought. Without it an atomic swap needs both parties to co-sign one transaction, which a marketplace cannot arrange. A sale is a row in `public.trades`. |
| **Yield / books / epochs** | **Simulated** | `public.epochs` and `public.epoch_yields` are a ledger of a simulation. Nothing accrues anywhere but here. |
| **Treasury payout** | Real | The treasury is an ordinary wallet whose keypair the operator holds — **not a PDA**. A claim is the operator signing a `transferChecked` to the dev wallet. |
| **Holder payout** | Real, **by hand** | SOL from pump.fun creator fees, sent by an operator from a wallet this backend holds no key for. `public.payout_requests` is the ticket queue; `status = 'paid'` is an operator recording a transfer with its signature. |

Every table that could hold either kind carries an **`origin`** column
(`'chain'` or `'simulated'`). Read it before presenting any row as on-chain.

### The mint has no fee

It used to be 10,000 burned **plus 500 to the treasury**. It is now 10,000
burned and nothing else. The change is enforced, not merely applied:

- `mints.fee` is nailed to `'0'` by `mints_never_carry_a_fee`;
- `fee_ledger` refuses `source = 'mint'` outright, because a mint produces no
  treasury revenue and a zero row there would still tell a reader it did;
- `record_mint`'s seven-argument signature is **dropped**, so a caller still
  passing a fee gets "function does not exist" rather than writing a number
  nowhere;
- `mintLegs()` in `_shared/protocol.ts` is replaced by `mintAmount()` returning
  a bare `bigint` — a return type that cannot express a second amount cannot
  quietly grow one.

---

## Docker is not installed on this machine

`npx supabase start` runs the whole stack in Docker. Without Docker there is no
local Postgres, no local PostgREST and no local Edge Runtime, so these do **not**
work here:

```
npx supabase start           # needs Docker
npx supabase stop            # needs Docker
npx supabase db reset        # needs Docker (local only)
npx supabase functions serve # needs Docker
```

Everything below is the **remote-project workflow**. The one real cost is that
there is no throwaway database to test a migration against, so read
`db push --dry-run` output before letting it run.

There is also no Rust toolchain here and nothing needs one. Never run `cargo` or
`anchor`.

---

## 1. Create and link the project

```bash
npx supabase login
npx supabase link --project-ref <your-project-ref>
```

Create the project itself in the dashboard (<https://supabase.com/dashboard> →
**New project**); creation needs an organization. Note the **project ref** — the
subdomain in `https://<ref>.supabase.co`.

`link` writes `supabase/.temp/`, which should not be committed.

---

## 2. Push the migrations

```bash
npx supabase migration list          # applied remotely vs. local
npx supabase db push --dry-run       # print the SQL that would run — read this
npx supabase db push
```

Applied in order:

| Migration | What it does |
|---|---|
| `20260805120000_protocol_tables.sql` | Original tables, money/address domains, the `origin` discriminator |
| `20260805120100_writer_functions.sql` | `SECURITY DEFINER` writers, granted to `service_role` only |
| `20260805120200_rls_policies.sql` | RLS for those tables: anon reads, anon writes nothing |
| `20260805120300_rent_closes_one_listing.sql` | `record_rent` closes one listing, not all of an owner's |
| `20260806090000_mint_fee_retired.sql` | The mint fee is removed at the schema level |
| `20260806090100_collection.sql` | Tiers, skills, traits, positional rarity, `reveal_order` |
| `20260806090200_seed_reveal_order.sql` | The 5,000-serial mint permutation |
| `20260806090300_seed_xployees.sql` | All 5,000 xployees |
| `20260806090400_seed_xployee_skills.sql` | 7,900 skill rows + the apy reconciliation |
| `20260806090500_seed_xnet_genesis.sql` | 97 xNET wallets and the 512 genesis workers |
| `20260806090600_mint_control.sql` | **The mint rate limit**, reservations, the serial dealer |
| `20260806090700_identity.sql` | Profiles, verified X handles, wallet linking |
| `20260806090800_market_and_epochs.sql` | Listings, sales, rentals, simulated fees, the epoch ledger |
| `20260806090900_social.sql` | Friends, threads, messages, trade offers |
| `20260806091000_payout_requests.sql` | The SOL claim queue + realtime |
| `20260806091100_rls_policies.sql` | RLS for everything above |

The seed migrations are large (`20260806090300` is ~500 KB) because the
collection is 5,000 units. They are generated from `src/lib` itself rather than
hand-written — see [Regenerating the seed](#regenerating-the-seed).

Each seed file **asserts what it loaded**: the permutation is complete and
one-to-one, the four tier bands are 150/600/1250/3000, every worker holds exactly
its tier's number of skills, and each worker's stored `apy` equals the blend
recomputed from its own skill rows. A truncated paste or a drifted generator
fails the push instead of loading a collection whose rarity is quietly wrong.

> **If you pushed an earlier version of the first four files to a project
> already, stop.** `20260806090600` adds constraints that an existing `mints` row
> written under the old two-leg mint will violate. Nothing has been deployed to a
> real cluster and `$xNFT` does not exist, so the index holds no data worth
> keeping. Reset the public schema in the SQL editor and push again:
>
> ```sql
> drop schema public cascade;
> create schema public;
> grant usage on schema public to anon, authenticated, service_role;
> delete from supabase_migrations.schema_migrations where version like '2026%';
> ```
>
> If you have a project with real `payouts` or `payout_requests` rows, do **not**
> do this — those two tables are the only ones not reconstructible from chain
> reads.

---

## 3. Set the function secrets

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically — **do not** set them; the CLI rejects secret names beginning with
`SUPABASE_`.

```bash
npx supabase secrets set SOLANA_RPC_URL="https://<your-rpc-endpoint>"
npx supabase secrets set XNFT_MINT_ADDRESS="<the $xNFT SPL mint>"
npx supabase secrets set TREASURY_ADDRESS="<the treasury wallet>"
npx supabase secrets set DEV_WALLET_ADDRESS="<where claimed fees are sent>"

npx supabase secrets list
```

**The gate is split.** `ingest-signature`, `request-payout` and `confirm-payout`
load the full config and refuse with a 503 while any of the four is unset. The
six session-backed functions — `mint-reserve`, `link-wallet`, `profile`,
`market`, `social`, `payout-request` — touch no Solana address and load only the
platform credentials, so the social layer is not gated behind a treasury address
nobody has set yet.

- A wrong `XNFT_MINT_ADDRESS` makes `ingest-signature` index somebody else's
  token as if it were ours.
- A wrong `TREASURY_ADDRESS` means no claim is ever recognised, and every rental
  fails as "not a rental".
- A wrong `DEV_WALLET_ADDRESS` means `confirm-payout` never recognises a claim
  and every payout sits pending until its blockhash expires.

`TREASURY_ADDRESS` and `DEV_WALLET_ADDRESS` must be different wallets; the config
loader refuses them otherwise, because a claim from an account to itself would
verify as a settled payout that moved nothing.

Use a dedicated RPC endpoint (Helius, Triton, QuickNode) serving `getTransaction`
with `encoding: "jsonParsed"` — the whole ingest path is built on the node's
parsed instructions and its `preTokenBalances` / `postTokenBalances` metadata.

---

## 4. Configure Supabase Auth with the X (Twitter) provider

**X is the only sign-in provider.** A session exists for exactly two purposes: to
carry a verified X identity that `link-wallet` copies a handle out of, and to be
the subject a wallet signature is bound to. Email/password proves neither, so
enabling it would create sessions that can write to the social layer while
proving nothing about who is writing.

### 4a. Create the X app

1. <https://developer.x.com/en/portal/dashboard> → **Projects & Apps** → your
   project → **+ Add App** (or use an existing one).
2. **User authentication settings** → **Set up**.
   - **App permissions**: *Read* is enough. This backend never posts.
   - **Type of App**: *Web App, Automated App or Bot* (a confidential client).
   - **Callback URI / Redirect URL** — exactly this, no trailing slash:

     ```
     https://<project-ref>.supabase.co/auth/v1/callback
     ```

   - **Website URL**: your deployed site.
3. Save, then copy the **OAuth 2.0 Client ID** and **Client Secret**. The secret
   is shown once.

> Supabase's `twitter` provider uses **OAuth 2.0**. If the X portal shows you
> "API Key / API Secret" (OAuth 1.0a) rather than "Client ID / Client Secret",
> you are looking at the wrong pane — go back to **User authentication settings**.

### 4b. Configure Supabase

Dashboard → **Authentication** → **Providers** → **Twitter**:

1. Toggle **Enabled**.
2. Paste the **Client ID** and **Client Secret**.
3. Save.

Then **Authentication** → **URL Configuration**:

- **Site URL**: your deployed origin, e.g. `https://xnfts.example`.
- **Redirect URLs**: add every origin the app runs on, including
  `http://localhost:5181` for `npm run dev`. A missing entry fails the callback
  *after* the user has already authorised on X, which reads as the app being
  broken rather than as a configuration gap.

Finally **Authentication** → **Sign In / Providers** → confirm **Allow new users
to sign up** is on. With OAuth as the only provider, "signup" is simply the first
time an X account signs in; leaving it off makes every new visitor's first
sign-in fail.

### 4c. What the client does

```ts
await supabase.auth.signInWithOAuth({ provider: 'twitter' })
```

That is the whole of it. The client never handles the secret, never sends a
handle, and never receives one to send back.

### 4d. Linking a wallet — both sides are proved

A link is a claim about two things at once, so one proof is not enough. Proving
only the X side lets anyone attach a stranger's wallet to their account and
inherit its collection on every leaderboard. Proving only the wallet side lets
anyone attach a stranger's handle to their wallet and impersonate them.

```
POST /functions/v1/link-wallet   { "action": "challenge", "wallet": "<base58>" }
  -> { nonce, statement, expiresInSeconds }

# the browser asks the wallet to sign `statement` (signMessage, not a transaction)

POST /functions/v1/link-wallet   { "action": "verify", "wallet": "<base58>",
                                   "nonce": "...", "signature": "<base58>" }
  -> { ok: true, wallet, twitterHandle }
```

- The **nonce is issued by this server**. A client-chosen nonce is a signature an
  attacker could have collected somewhere else — a phishing page, another dapp
  asking the user to "verify ownership" — and replayed here.
- The **statement is stored and compared**, not rebuilt at verification time. A
  verifier that reconstructs the message from a template can be handed a
  signature made over a different template.
- The challenge is **single use**, consumed in the same transaction that writes
  the link.
- The signature is checked with `crypto.subtle.verify` under Ed25519. Every
  failure path — unsupported algorithm, wrong key length, malformed signature, a
  throw from `verify` — returns false or a typed error. Nothing treats "could not
  check" as "checked and fine".

### 4e. There is no path that accepts a typed X handle

This is enforced three ways, and each is independent of the others:

1. **`public.set_profile` has no twitter parameter.** Not an ignored one — the
   argument list has no place to put a handle. The `profile` function *refuses*
   a body containing one rather than dropping it silently, because a client
   sending a handle is a client that believes it can set one.
2. **`link_twitter_identity` reads `auth.identities` itself.** The handle is a
   value GoTrue wrote after completing the OAuth exchange with X.
3. **`profiles_twitter_is_verified`** — a check constraint making a handle
   without a provider id, a verification timestamp *and* an auth user
   unrepresentable. Even a service-role INSERT cannot write a bare handle.

`wallets.twitter` is a mirror of the verified handle, guarded by the
`wallets_twitter_must_be_verified` trigger, which refuses any value not already
verified on the matching profile.

---

## 5. Deploy the functions

```bash
npx supabase functions deploy          # all of them
npx supabase functions list
```

`_shared/` is not a function — the leading underscore keeps the CLI from
deploying it as one, and its modules are bundled into each function that imports
them.

| Function | Role |
|---|---|
| `ingest-signature` | **The chain trust boundary.** Takes a signature and nothing else, fetches the transaction from RPC itself, and writes from *its* reading. |
| `mint-reserve` | **Takes the mint rate limit and holds a serial, before anything is burned.** |
| `request-payout` | Writes the pending row for a treasury claim the operator already signed. |
| `confirm-payout` | Polls signature status and settles pending treasury claims. **A timeout leaves the row pending, never failed.** |
| `link-wallet` | Wallet ↔ X linking. Issues the nonce, verifies the ed25519 signature, writes the link. |
| `profile` | Handle, bio, avatar. Cannot set an X handle. |
| `market` | List, cancel, buy, rent. All simulated; all checked under a row lock in SQL. |
| `social` | Friend requests, messages, trade offers. |
| `payout-request` | The SOL claim queue: a holder opens a ticket, an operator resolves it. |

### How `ingest-signature` recognises a mint

1. Fetch with `encoding: "jsonParsed"`. Refuse if it is missing, has `meta.err`,
   or contains a token-program instruction the node did not parse — an
   instruction it cannot read is a hole, and "cannot see" is never reported as
   "did not happen".
2. Collect **every** transfer of the configured mint. Not "a transfer to the
   incinerator" — all of them.
3. There must be **exactly one**, to the incinerator, of `10_000 × 10^decimals`,
   from a payer who is not the treasury. Compared for equality.
4. The `preTokenBalances` / `postTokenBalances` deltas must corroborate both
   sides: payer down by the burn, incinerator up by it, summed across every
   account each owner holds of that mint.

Anything else is a `422` and **nothing is written**.

> **A mint and a treasury claim are now both a single transfer**, so the leg
> count no longer distinguishes them and the ownership of both ends has to. The
> claim branch (`treasury -> dev wallet`) is checked **first**, and the mint
> branch additionally refuses a treasury payer. The old two-leg mint is refused
> by name, so a stale client fails loudly instead of being reinterpreted as a
> rental of the incinerator.

Ingestion is idempotent **per event**: the keys are `(signature, event_index)` on
`mints` and `(signature, source, event_index)` on `fee_ledger`, where
`event_index` is the position of the event's first transfer in the flattened
instruction list — a property of the transaction, so a replay derives the same
index and collides with the same row.

### How `confirm-payout` decides a treasury payout failed

A pending row moves to `failed` in exactly three situations:

1. **Blockhash expired.** `getSignatureStatus` (with `searchTransactionHistory`)
   finds nothing *and* the current block height is past the row's
   `expires_at_block_height`. This is the only definite negative drawn from not
   seeing something.
2. **Landed and reverted.** The chain reports the signature with a non-null `err`.
3. **Landed and was not a claim.** Confirmed, **fully readable**, and containing
   no $xNFT transfer from the treasury to the dev wallet. "Fully readable" is
   checked: an unreported owner makes a claim that landed perfectly well look
   identical to one that never existed, so any unattributed movement stays
   pending.

Everything else stays pending. A claim that may have landed must never be shown
as failed, because the operator's response to a failed claim is to claim again —
and the second claim is a second withdrawal.

---

## 6. The mint rate limit

> The concern is concrete: at a low market cap 10,000 $xNFT is cheap, so someone
> accumulates supply and mints in bulk to drain the rare low serials. X-RATED is
> 150 units out of 5,000.

### Enforced in the database, and taken *before* the burn

A client-side limit is not a limit: the mint transaction is a plain SPL transfer
any wallet can build without this app's help, and the Edge Function is reachable
with a public anon key. The only party that sees every request is Postgres.

**And a limit checked at ingest time is checked after the tokens are gone.** It
cannot prevent anything — it can only decide whether to hand over an xployee for
money that has already been destroyed. So the budget is consumed when a serial is
**reserved**:

```
POST /functions/v1/mint-reserve  { "action": "check"   }  -> can I, and when?
POST /functions/v1/mint-reserve  { "action": "reserve" }  -> holds a serial
# ... build the burn with buildMintTransaction(), send it ...
POST /functions/v1/ingest-signature { "signature": "..." } -> redeems the hold
```

Both doors are closed with the same policy. A burn arriving with **no** live
reservation is dealt a serial only if the policy would have granted one at that
instant. Otherwise the mint is still recorded — the tokens are gone and the chain
says so, and a backend that silently forgot a real burn would be stealing — but
as `assignment_status = 'held'`, with no serial, for an operator to resolve.
**"Burn first, ask later" therefore buys nothing except burnt tokens and a
support ticket.**

A client must render `held` as *"your tokens are burned and this is with an
operator"*, never as a failure. Telling somebody their mint failed is how they
burn a second 10,000 trying again.

### What is atomic, and why there are five layers

| | Mechanism | What it survives |
|---|---|---|
| 1 | `pg_advisory_xact_lock(mint_gate_key())` | Two callers both reading a window count of 99. Held to commit, so every count is exact. |
| 2 | `mint_reservations_one_live_per_wallet` — partial UNIQUE | The lock being removed. One wallet cannot hold two live reservations, ever. |
| 3 | `mint_reservations_one_holder_per_position` / `_per_serial` | A released position legitimately returning to the pool, without allowing two *effective* holders. |
| 4 | `for update skip locked` on the reveal pool | Two dealers racing for one position. Redundant under the gate lock, kept for the day somebody decides the gate is too coarse. |
| 5 | `reveal_order.serial UNIQUE` | Every function above being wrong. A duplicate serial is unrepresentable at the storage layer. |

Not one check-then-insert anywhere.

### Configurable without a code change

Every threshold is a column on `public.mint_policy`, a one-row table:

```sql
select * from public.mint_policy;

-- tighten during a raid
update public.mint_policy set global_window_limit = 20, wallet_cooldown_seconds = 600;

-- stop entirely
update public.mint_policy set paused = true, pause_reason = 'Investigating unusual mint volume.';
```

| Column | Default | What it bounds |
|---|---|---|
| `paused` | `false` | Everything. Refuses new reservations; does **not** refuse an already-reserved burn, because pausing must never become a way to take somebody's tokens. |
| `wallet_cooldown_seconds` | `90` | The gap between one wallet's reservations. Turns a tight loop into a queue. |
| `wallet_window_seconds` / `wallet_window_limit` | `86400` / `10` | Reservations per wallet per day. |
| `global_window_seconds` / `global_window_limit` | `3600` / `120` | **The one that protects the low serials.** A true sliding window across all wallets. |
| `reservation_ttl_seconds` | `900` | How long a held serial stays out of the pool. |

Abandoning a reservation does **not** refund its budget — otherwise
reserve/cancel/reserve would be a free way to reroll until a rare serial came up,
and the reveal order is a lottery.

### What it does not do

It does not stop a Sybil. Wallets are free, so a per-wallet cap is a cost
multiplier, not a wall — anyone claiming otherwise about a system with no
identity layer is selling something. What the **global** cap does is bound the
rate at which the collection can drain regardless of how many wallets are
involved, converting *"the rare serials were gone before anyone noticed"* into
*"the rare serials are draining and the operator has hours to respond"*.

---

## 7. Realtime for the admin desk

`payout_requests`, `payouts` and `mints` are in the `supabase_realtime`
publication with `replica identity full`, so an UPDATE payload carries the
previous row as well as the new one — a desk watching for "pending became paid"
would otherwise need a round trip per event to find out what a row changed *from*.

```ts
supabase
  .channel('payout-desk')
  .on('postgres_changes',
      { event: '*', schema: 'public', table: 'payout_requests' },
      (payload) => { /* payload.new, payload.old */ })
  .subscribe()
```

**Realtime respects RLS per subscriber.** An unauthenticated socket receives only
the `status = 'paid'` rows the public policy publishes. To see the whole queue the
desk must be signed in as an **operator**, which means a row in
`public.operators` for the wallet that session has linked:

```sql
-- ships EMPTY on purpose: every operator path refuses until somebody with
-- database access adds a row.
insert into public.operators (wallet, label) values ('<operator wallet>', 'skiz');
```

---

## 8. Scheduled jobs

Three, and only the first is load-bearing. The other two are hygiene: nothing
depends on them having run.

```sql
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net  with schema extensions;

-- Store the service-role key in Vault rather than inline: pg_cron job
-- definitions are readable by anyone who can read cron.job.
select vault.create_secret('<service-role-key>', 'confirm_payout_key');

-- 1. Settle treasury claims. Without this a payout hangs pending until its
--    blockhash expires if the browser is closed mid-claim.
select cron.schedule(
  'confirm-payout-sweep', '*/2 * * * *',
  $$
  select net.http_post(
    url     := 'https://<project-ref>.supabase.co/functions/v1/confirm-payout',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets where name = 'confirm_payout_key')),
    body    := '{}'::jsonb);
  $$);

-- 2. Return abandoned mint reservations to the pool. `reserve_mint` already does
--    this at the top of every reservation, so a cron that stops running cannot
--    leak the collection — this only keeps the pool honest during a quiet period.
select cron.schedule('release-mint-reservations', '*/5 * * * *',
  $$ select public.release_expired_reservations(); $$);

-- 3. Close finished epochs and expire stale trade offers.
select cron.schedule('settle-epochs', '17 * * * *',
  $$ select public.settle_due_epochs(7); $$);
select cron.schedule('expire-offers', '23 * * * *',
  $$ select public.expire_trade_offers(); $$);
```

Check and unschedule with:

```sql
select * from cron.job;
select * from cron.job_run_details order by start_time desc limit 10;
select cron.unschedule('confirm-payout-sweep');
```

`settle_epoch` refuses to settle an epoch that has not finished and refuses to
rewrite one it has already closed, so running it twice is a no-op.

---

## 9. Generate types

```bash
npx supabase gen types typescript --linked --schema public > src/lib/database.types.ts
```

`src/lib/supabase.ts` does **not** import these. It declares its own row types
because it converts every money column from `text` to `bigint` at the boundary,
and a generated `string` would let a raw amount reach a component unparsed. Treat
the generated file as a check that the hand-written types still match the schema,
not as the source of them.

---

## Regenerating the seed

The four seed migrations are generated from `src/lib` by importing it, so the
rows in Postgres and the objects in the browser come from one piece of code. They
are **not** hand-edited. If `src/lib/xployee.ts`, `tiers.ts`, `skills.ts` or
`collection.ts` changes in a way that alters identity, the seed has to be
regenerated into a **new** migration — never by editing an applied one — and the
old rows corrected by a forward migration.

The generator is not committed because it runs once; it imports
`buildXployee(id, 0)` for every serial, `mintOrder()` for the permutation and
`networkWallets()` for the xNET partition, asserts the permutation is one-to-one
and every tier agrees with `tierForId`, and emits the value lists the migrations
wrap. The assertions inside the migrations themselves are the durable half — they
re-check everything against the schema at push time.

---

## Verifying the security properties

Run these against the REST endpoint with the **anon** key.

```bash
export URL="https://<ref>.supabase.co"
export ANON="<anon key>"

# Public reads work.
curl -s "$URL/rest/v1/xployees?select=id,tier,apy&limit=1"  -H "apikey: $ANON"
curl -s "$URL/rest/v1/mint_policy?select=*"                 -H "apikey: $ANON"
curl -s "$URL/rest/v1/reveal_order?select=*&limit=1"        -H "apikey: $ANON"

# Private tables do not — expect 401/403/permission denied, never a row.
curl -s "$URL/rest/v1/wallet_link_challenges?select=*"      -H "apikey: $ANON"
curl -s "$URL/rest/v1/mint_rate_limits?select=*"            -H "apikey: $ANON"
curl -s "$URL/rest/v1/messages?select=*"                    -H "apikey: $ANON"
curl -s "$URL/rest/v1/wallet_identities?select=*"           -H "apikey: $ANON"

# A column that is not granted stays hidden even from `select=*`.
curl -s "$URL/rest/v1/profiles?select=auth_user_id&limit=1" -H "apikey: $ANON"

# Only paid claims are public.
curl -s "$URL/rest/v1/payout_requests?select=claim_id,status" -H "apikey: $ANON"

# Writes do not work — expect 401/403, never 201.
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/xployees" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{"id":1,"owner":"x"}'

curl -s -o /dev/null -w '%{http_code}\n' -X PATCH "$URL/rest/v1/mint_policy?id=eq.true" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{"wallet_cooldown_seconds":0}'

curl -s -o /dev/null -w '%{http_code}\n' -X PATCH "$URL/rest/v1/reveal_order?draw_position=eq.512" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{"claimed_by":"x"}'

# The writer functions are unreachable from the anon key.
for fn in reserve_mint record_mint set_profile buy_listing complete_wallet_link resolve_payout_request; do
  curl -s -o /dev/null -w "$fn %{http_code}\n" -X POST "$URL/rest/v1/rpc/$fn" \
    -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
    -H "Content-Type: application/json" -d '{}'     # => 404 or 403
done

# ingest-signature refuses anything but its two shapes, whatever the body claims.
curl -s -X POST "$URL/functions/v1/ingest-signature" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" \
  -d '{"signature":"<some unrelated mainnet signature>","burned":"999999999","xployeeId":0}'
  # => 422 rejected. The extra fields are not read by any code path.

# mint-reserve refuses a session that is not one.
curl -s -X POST "$URL/functions/v1/mint-reserve" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{"action":"reserve"}'
  # => 400. The anon key is a valid JWT and is not a user.
```

Two schema-level properties worth checking directly:

```sql
-- Rarity is positional, and a row that disagrees cannot be written.
update public.xployees set tier = 'xrated' where id = 4300;   -- => constraint violation

-- Every table has RLS and a restrictive denial on all three write verbs.
-- (This is the same assertion 20260806091100 runs at push time.)
select c.relname, c.relrowsecurity
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
-- => zero rows
```

---

## Rebuilding the index

The chain-derived part is disposable. Ingestion is idempotent, so replaying a
signature list twice is a no-op:

```sql
truncate public.fee_ledger;
```

Everything else is **not** disposable, and the list of what is not has grown:

- **`mints`** now carries the serial assignment. Truncating it and replaying
  would re-deal serials from whatever the pool looks like today, so a buyer could
  end up owning a different xployee than the one they were shown.
- **`xployees`, `reveal_order`, `mint_reservations`** — ownership and the mint
  permutation. There is no chain reading to rebuild these from.
- **`trades`, `rentals`, `sim_fee_ledger`, `listings`** — simulated. No
  transaction to replay; truncating destroys the only copy.
- **`payouts`, `payout_requests`** — request-time records of claims, including
  ones whose signature never landed.
- **`profiles`, `wallet_identities`, `friendships`, `threads`, `messages`,
  `trade_offers`** — user data. Obviously.

---

## Known gaps

- **The reveal order is public, and sniping follows from that.** `mintOrder()` is
  a fixed-seed shuffle compiled into the browser bundle, so anyone can derive the
  whole permutation offline — publishing `reveal_order` does not create that
  exposure and restricting it would not remove it. Because serials are dealt from
  the head of the pool in order, a determined buyer can compute which draw
  position yields an X-RATED and reserve precisely when the pool reaches it. What
  bounds it is `mint_policy`: a sniper cannot *choose* a position, only wait for
  one, and while they wait the cooldown and the global window mean they queue
  against everybody else on equal terms. Closing it properly needs a
  commit–reveal with a seed the client does not hold, which is a different design.
- **A per-wallet limit is not Sybil resistance.** Wallets are free. See §6.
- **`request_payout` bounds the client's number, it does not verify it.** Accrual
  is computed in the browser; the database recomputes the wallet's *maximum
  possible* accrual and refuses anything above it, deliberately generously (it
  ignores rentals redirecting yield, so it errs permissive). An operator reviews
  every ticket, and that review is the actual control.
- **`payout_requests` is settled by hand and this backend verifies nothing about
  it.** The paying key never comes near this system. `status = 'paid'` is an
  operator recording a signature; it is published for anyone to check rather than
  presented as a confirmation the server performed.
- **Accepting a trade offer moves nothing.** There is no escrow anywhere in this
  protocol, so an offer that reassigned xployees would be a settlement layer
  hidden inside a messaging table — with none of `buy_listing`'s ownership
  locking. The responses say `settled: false` explicitly.
- **A chain-verified rental still cannot recover its term.** Two transfers say
  how much was paid, not for how many epochs. `record_rent` records the fee and
  identifies the listing by price alone — oldest first, at most one, none if
  nothing matches. `public.rentals` exists only for *simulated* rentals, where the
  term is stated by a listing this database wrote itself.
- **`mints.fee` still exists as a column.** It is nailed to `'0'` by a check
  constraint. It survives only because `parseMint` in `src/lib/supabase.ts`
  refuses a mint row whose `fee` is absent, and a dropped column changes the shape
  PostgREST returns. Drop both together when that parser stops requiring it.
- **The treasury payout queue is bounded, not authorised.** `request-payout`
  cannot authenticate anyone — the transaction being recorded has not landed yet.
  What is bounded is the consequence: at most 8 unsettled rows, a signature past
  that ceiling admitted only if the chain has already seen it, and
  `confirm-payout` sweeping least-recently-checked first.
- **Custody of the treasury is custody of a private key.** Nothing on-chain
  constrains where the treasury keypair can send fees. `payouts.destination`
  records a convention this deployment enforces until `confirm-payout` overwrites
  it with a reading. Any UI copy implying the chain enforces the destination is
  wrong.
- **Nothing on the real SPL path has been exercised against a live mint.** `$xNFT`
  does not exist and every deployment constant is empty.

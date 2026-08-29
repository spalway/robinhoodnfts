-- =========================================================================
-- xNFTs database setup — PART 01 of 08
-- =========================================================================
--
-- Run these IN ORDER, one at a time, in the Supabase SQL Editor.
-- Wait for each to finish before starting the next.
--
-- Split only at statement boundaries, so no statement is cut in half. Safe to
-- re-run: every statement uses "if not exists", "or replace", or
-- "on conflict do nothing".
--
-- After all 08 parts, run RUN-THIS-SECOND.sql (protocol_config).
-- =========================================================================

-- =========================================================================
-- xNFTs — complete database setup, part 1 of 2
-- =========================================================================
--
-- Run this ENTIRE file in the Supabase SQL Editor, then run
-- protocol_config.sql afterwards.
--
-- This is 16 migrations concatenated in dependency order. The order matters:
-- later sections reference tables earlier ones create, so do not reorder or
-- run parts of it out of sequence.
--
-- Safe to re-run. Every statement uses "if not exists", "or replace", or
-- "on conflict do nothing", so running it twice does not duplicate data or
-- error out.
--
-- If it fails, the banner above the failure tells you which original migration
-- the problem is in — send me that name and the error text.
--
-- Sections, in order:
--    1. 20260805120000_protocol_tables.sql
--    2. 20260805120100_writer_functions.sql
--    3. 20260805120200_rls_policies.sql
--    4. 20260805120300_rent_closes_one_listing.sql
--    5. 20260806090000_mint_fee_retired.sql
--    6. 20260806090100_collection.sql
--    7. 20260806090200_seed_reveal_order.sql
--    8. 20260806090300_seed_xployees.sql
--    9. 20260806090400_seed_xployee_skills.sql
--   10. 20260806090500_seed_xnet_genesis.sql
--   11. 20260806090600_mint_control.sql
--   12. 20260806090700_identity.sql
--   13. 20260806090800_market_and_epochs.sql
--   14. 20260806090900_social.sql
--   15. 20260806091000_payout_requests.sql
--   16. 20260806091100_rls_policies.sql
--
-- =========================================================================



-- =========================================================================
-- SECTION 1 of 16 — 20260805120000_protocol_tables.sql
-- =========================================================================

-- xNFTs index — tables.
--
-- Supabase is a read model and a payout queue. It is never the authority on a
-- balance: if this database and the chain disagree, the chain wins and the index
-- is rebuilt from signatures.
--
-- ---------------------------------------------------------------------------
-- THERE IS NO PROGRAM. READ THIS BEFORE READING THE SCHEMA.
-- ---------------------------------------------------------------------------
-- An earlier version of this file was shaped around an Anchor program that was
-- abandoned before it was ever deployed. That program is gone, and with it every
-- PDA, every event and every escrow account. What replaced it is plain SPL token
-- transfers, which changes what this database can honestly claim to know:
--
--   MINTS are REAL. A mint is one transaction containing two transferChecked
--   instructions — 10,000 $xNFT to the incinerator and 500 to the treasury.
--   `ingest-signature` recognises exactly that pair and writes from its own
--   reading of the chain.
--
--   RENTALS are REAL, for the same reason and by the same route.
--
--   SALES are SIMULATED. An atomic swap of an asset for $xNFT with no escrow
--   program requires both parties to co-sign one transaction, which a
--   marketplace cannot arrange. So a sale is a row in this database and nothing
--   else, exactly like the rest of this deliberately simulated collection.
--
--   PAYOUTS are REAL, and their custody model is weaker than it was. The
--   treasury is an ordinary wallet whose keypair the operator holds, not a PDA.
--   A claim is an authorisation the operator performs, not a permission the chain
--   enforces.
--
-- Because those four are no longer the same kind of thing, every table below that
-- can hold either kind carries an `origin` column saying which it is. That is
-- deliberately a column and not a convention: a reader looking at a row must be
-- able to tell whether it is backed by a transaction they can open on Solscan, or
-- whether it is a number this application made up, without knowing which code
-- path wrote it.

-- ---------------------------------------------------------------------------
-- Domains
-- ---------------------------------------------------------------------------

-- Token amounts are stored as base-10 digit strings, not numeric or bigint.
--
-- This is not stylistic. PostgREST serialises both `bigint` and `numeric` as
-- unquoted JSON numbers, and JSON.parse turns those into IEEE-754 doubles — so
-- any raw-unit amount above 2^53 silently loses its low digits somewhere between
-- Postgres and the browser. u64 goes to ~1.8e19. Text survives the wire exactly
-- and BigInt(s) reconstructs it losslessly on the other side, which is what makes
-- the project-wide "no float ever touches a balance" rule structurally true
-- rather than merely intended.
--
-- The cost is that SQL aggregation needs an explicit ::numeric cast. That is the
-- right trade for a table that is an index, not a ledger of record.
create domain public.u64_text as text
  check (value ~ '^(0|[1-9][0-9]{0,19})$');

-- Base58, no 0/O/I/l. Rejecting malformed keys at the column means a junk row
-- cannot exist even if a writer is wrong, which matters because the Edge
-- Functions are the only writers and a bug there would otherwise be invisible.
create domain public.base58_address as text
  check (value ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$');

create domain public.tx_signature as text
  check (value ~ '^[1-9A-HJ-NP-Za-km-z]{64,88}$');

-- Every chain-derived row says so, and every simulated row says so. Constrained
-- at the domain rather than per table so a future table cannot invent a third
-- word for the same distinction.
create domain public.row_origin as text
  check (value in ('chain', 'simulated'));

comment on domain public.row_origin is
  'chain = written by ingest-signature from a transaction it fetched and verified itself. '
  'simulated = written by the application; no transaction exists and none can.';

-- ---------------------------------------------------------------------------
-- wallets
-- ---------------------------------------------------------------------------

create table public.wallets (
  address    public.base58_address primary key,
  handle     text,
  bio        text,
  twitter    text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.wallets is
  'Optional public profile per address. Purely cosmetic — nothing here gates access to anything.';

-- ---------------------------------------------------------------------------
-- xployees
-- ---------------------------------------------------------------------------

-- Identity stays with the deterministic in-browser generator (spec §8): tier,
-- skills, traits, principal and apy are all reproducible from the id alone.
--
-- `id` is the identity of record throughout this schema, and that is the fix for
-- a real defect rather than a preference. Ownership used to be reassigned by
-- joining on `nft_mint` — a column no writer has ever populated — so the UPDATE
-- matched zero rows on every sale, silently, forever. Nothing joins on nft_mint
-- any more. See `record_simulated_sale` in the writers migration.
create table public.xployees (
  id             bigint primary key check (id >= 0),
  -- Kept, nullable, and deliberately not a key: there is no real NFT mint for a
  -- simulated collection, and there is no program to create one. It exists so a
  -- future tokenised collection has somewhere to record the address. If you find
  -- yourself writing a join against it, check first that something writes it.
  nft_mint       public.base58_address unique,
  owner          public.base58_address,
  tier           text,
  skills         smallint check (skills is null or skills between 1 and 4),
  traits         jsonb,
  -- USD notional from the simulation, not a token balance, so exact decimal is
  -- appropriate here where u64_text is appropriate above.
  principal      numeric(20, 2),
  apy            numeric(8, 6),
  hired_at       timestamptz,
  -- The signature of a verified on-chain mint, when one is known. Chain ingestion
  -- cannot fill this in: a mint transaction is two token transfers and carries no
  -- xployee id anywhere, so nothing on-chain says *which* xployee it bought. See
  -- the note on public.mints.xployee_id.
  mint_signature public.tx_signature,
  updated_at     timestamptz not null default now()
);

create index xployees_owner_idx on public.xployees (owner);

comment on column public.xployees.nft_mint is
  'Unpopulated. No writer sets it and nothing joins on it — see the table comment for why that is now enforced rather than assumed.';

-- ---------------------------------------------------------------------------
-- listings
-- ---------------------------------------------------------------------------

-- Listings are an application concept end to end. There is no escrow, so listing
-- an xployee moves nothing and proves nothing; a listing is an advertisement.
create table public.listings (
  nft_mint      public.base58_address primary key,
  -- The join key that actually works. Not null because a listing that cannot be
  -- tied back to an xployee cannot be closed by a sale or a rental.
  xployee_id    bigint not null unique check (xployee_id >= 0),
  seller        public.base58_address not null,
  kind          text not null check (kind in ('sale', 'rent')),
  price         public.u64_text,
  fee_per_epoch public.u64_text,
  term_epochs   integer check (term_epochs is null or term_epochs > 0),
  status        text not null default 'active'
                  check (status in ('active', 'sold', 'rented', 'cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- A sale listing without a price and a rent listing without a rate are both
  -- unbuyable rows that would render as "—" forever. Reject them at the column.
  constraint listings_priced_by_kind check (
    (kind = 'sale' and price is not null)
    or (kind = 'rent' and fee_per_epoch is not null and term_epochs is not null)
  )
);

create index listings_seller_idx on public.listings (seller);
create index listings_status_idx on public.listings (status, updated_at desc);

comment on table public.listings is
  'Advertisements, not escrow. Nothing is held, so a listing constrains nobody — the seller can ignore it and there is no on-chain state to disagree with.';

-- ---------------------------------------------------------------------------
-- mints — chain-derived
-- ---------------------------------------------------------------------------

-- One row per verified on-chain mint.
--
-- The key is (signature, event_index), not signature alone. event_index is the
-- position of the mint's first transfer within the transaction's flattened
-- instruction list — a property of the transaction itself, so re-reading the same
-- signature derives the same value and collides with the same row. That is what
-- makes ingestion idempotent per *event* rather than merely per transaction: two
-- mints batched into one signature would be two rows and would stay two rows
-- across any number of replays, instead of the second silently vanishing into a
-- primary-key conflict with the first.
create table public.mints (
  signature   public.tx_signature not null,
  event_index integer not null check (event_index >= 0),
  buyer       public.base58_address not null,
  burned      public.u64_text not null,
  fee         public.u64_text not null,
  -- Nullable, and this is the honest limitation of a mint with no program. The
  -- transaction proves that this wallet burned 10,000 $xNFT and paid 500 to the
  -- treasury. It does not say which xployee that bought, because two token
  -- transfers carry no room to say so. Closing this needs a memo instruction the
  -- buyer signs alongside the transfers; nothing currently builds one.
  xployee_id  bigint check (xployee_id is null or xployee_id >= 0),
  slot        bigint not null,
  block_time  timestamptz,
  origin      public.row_origin not null default 'chain' check (origin = 'chain'),
  indexed_at  timestamptz not null default now(),
  primary key (signature, event_index)
);

create index mints_buyer_idx on public.mints (buyer, slot desc);
create index mints_slot_idx on public.mints (slot desc);

comment on table public.mints is
  'Chain-backed only. Every row corresponds to a transaction ingest-signature fetched, recognised as exactly 10,000 burned + 500 to the treasury, and reconciled against the token balance deltas.';
comment on column public.mints.xployee_id is
  'Null in practice. A mint transaction carries no xployee id; see the column comment in the table definition.';

-- ---------------------------------------------------------------------------
-- trades — SIMULATED
-- ---------------------------------------------------------------------------

-- Sales are simulated, and this table is the place that is most likely to be
-- misread, so it is worth being blunt: NOTHING IN HERE HAPPENED ON A BLOCKCHAIN.
--
-- The primary key is a generated uuid rather than a transaction signature,
-- because a simulated sale has no signature and pretending otherwise would put a
-- column in the schema that could never be filled. `origin` permits 'chain' so
-- that a future escrow-backed sale has somewhere to go, but the only writer that
-- exists hard-codes 'simulated' and cannot express the other value.
--
-- The fee column is a notional figure — what a 5% fee would have been. It is
-- deliberately NOT written into fee_ledger, because fee_ledger is reconciled
-- against a real treasury token account and a simulated accrual there would
-- overstate a balance somebody can actually go and look at.
create table public.trades (
  id            uuid primary key default gen_random_uuid(),
  -- The application's own idempotency key. A simulated sale has no natural chain
  -- key, so replay protection has to come from the caller; this is where it goes.
  sale_ref      text unique,
  xployee_id    bigint not null check (xployee_id >= 0),
  nft_mint      public.base58_address not null,
  buyer         public.base58_address not null,
  seller        public.base58_address not null,
  gross         public.u64_text not null,
  fee           public.u64_text not null,
  net_to_seller public.u64_text not null,
  origin        public.row_origin not null default 'simulated',
  -- Null for every row that exists today. A chain-backed sale would carry both.
  signature     public.tx_signature unique,
  slot          bigint,
  block_time    timestamptz,
  recorded_at   timestamptz not null default now(),
  -- The two words mean different things and the row has to be consistent with
  -- whichever one it claims. A 'chain' row without a signature is an unverifiable
  -- assertion wearing the word "chain"; a 'simulated' row with one is a row
  -- claiming a transaction it did not come from.
  constraint trades_origin_matches_evidence check (
    (origin = 'simulated' and signature is null and slot is null)
    or (origin = 'chain' and signature is not null and slot is not null)
  )
);

create index trades_xployee_idx on public.trades (xployee_id, recorded_at desc);
create index trades_buyer_idx on public.trades (buyer, recorded_at desc);
create index trades_seller_idx on public.trades (seller, recorded_at desc);
create index trades_recorded_idx on public.trades (recorded_at desc);

comment on table public.trades is
  'SIMULATED. Sales are Supabase ledger entries — there is no escrow program, so an atomic swap would need both parties to co-sign one transaction and nothing arranges that. Check the origin column before presenting any row here as on-chain.';
comment on column public.trades.fee is
  'Notional. What a 5% fee would have been on a real sale. Never enters fee_ledger and never reaches the treasury.';

-- ---------------------------------------------------------------------------
-- fee_ledger — chain-derived
-- ---------------------------------------------------------------------------

-- The accrual side of the treasury: one row per fee that actually landed in the
-- treasury's token account.
--
-- `source` covers only the two paths that move real value. 'sale' is absent, and
-- its absence is the point — see the trades table above.
--
-- Keyed on (signature, source, event_index) so a transaction that carried two
-- fee-bearing events records both. The old (signature, source) key collapsed them
-- and was documented as a ceiling; event_index removes the ceiling rather than
-- restating it.
create table public.fee_ledger (
  signature   public.tx_signature not null,
  source      text not null check (source in ('mint', 'rent')),
  event_index integer not null check (event_index >= 0),
  -- Who paid it: the buyer on a mint, the renter on a rental. Chain-proven, and
  -- worth keeping because a fee with no payer cannot be reconciled against
  -- anything after the fact.
  payer       public.base58_address not null,
  amount      public.u64_text not null,
  slot        bigint not null,
  block_time  timestamptz,
  origin      public.row_origin not null default 'chain' check (origin = 'chain'),
  indexed_at  timestamptz not null default now(),
  primary key (signature, source, event_index)
);

create index fee_ledger_slot_idx on public.fee_ledger (slot desc);
create index fee_ledger_source_idx on public.fee_ledger (source, slot desc);
create index fee_ledger_payer_idx on public.fee_ledger (payer, slot desc);

comment on table public.fee_ledger is
  'Chain-backed only. Sum this against the treasury token account balance plus confirmed payouts; a simulated row in here would break that reconciliation, which is why the source check has no sale.';

-- ---------------------------------------------------------------------------
-- payouts
-- ---------------------------------------------------------------------------

-- The payout queue. A row appears the instant a claim signature exists and
-- genuinely is unconfirmed at that moment — this is a real pending state, not a
-- spinner.
--
-- THE AMOUNT RULE, ENFORCED IN THE SCHEMA RATHER THAN IN A COMMENT:
--
--   `claimed_amount_unverified` is whatever the client said it was claiming. It
--   is never treated as truth by anything, and its name is the documentation.
--
--   `amount` is the authoritative figure and is NULL until confirm-payout reads
--   the transfer off the chain. The check constraint below makes `confirmed`
--   unreachable while it is null, so "a payout is only confirmed from a verified
--   on-chain transfer" is a property of the table, not of the code that writes
--   it. A failed payout keeps amount null too — nothing moved, so there is no
--   verified amount to record.
--
--   `amount_verified` is generated from `amount`. It cannot drift from the column
--   it describes because it is not stored independently of it.
create table public.payouts (
  id                        uuid primary key default gen_random_uuid(),
  amount                    public.u64_text,
  claimed_amount_unverified public.u64_text,
  amount_verified           boolean generated always as (amount is not null) stored,
  -- At request time this is DEV_WALLET_ADDRESS from the function's environment —
  -- never a request parameter. On confirmation it is overwritten with the address
  -- the chain says actually received the transfer. Worth being precise about the
  -- guarantee: no program constrains where the treasury keypair can send fees, so
  -- this column records a convention until the moment it records a reading.
  destination               public.base58_address not null,
  status                    text not null default 'pending'
                              check (status in ('pending', 'confirmed', 'failed')),
  -- Not null and unique: a payout row exists because a signature came back, and
  -- uniqueness is what stops a double-posted claim becoming two rows.
  signature                 public.tx_signature not null unique,
  -- The height past which this transaction's blockhash is dead. This is the ONLY
  -- basis on which confirm-payout may call an unseen signature a definite
  -- failure; without it, "the chain has never heard of this" is indistinguishable
  -- from "the chain has not heard of this yet", and the second one must never be
  -- rendered as a failure the operator might respond to by claiming again.
  expires_at_block_height   bigint not null check (expires_at_block_height > 0),
  failure_reason            text,
  requested_at              timestamptz not null default now(),
  last_checked_at           timestamptz,
  confirmed_at              timestamptz,
  -- A settled row must say when it settled; a pending row must not claim to have.
  constraint payouts_settled_has_timestamp check (
    (status = 'pending' and confirmed_at is null)
    or (status <> 'pending' and confirmed_at is not null)
  ),
  -- Only a failure carries a reason, so a stray reason on a confirmed row can
  -- never be rendered as an error next to a successful claim.
  constraint payouts_reason_only_on_failure check (
    failure_reason is null or status = 'failed'
  ),
  -- The one that matters: an amount exists if and only if the payout confirmed.
  constraint payouts_amount_iff_confirmed check (
    (status = 'confirmed' and amount is not null)
    or (status <> 'confirmed' and amount is null)
  )
);

create index payouts_status_idx on public.payouts (status, requested_at asc);
create index payouts_requested_idx on public.payouts (requested_at desc);

comment on table public.payouts is
  'Treasury claims. Publicly readable: every confirmed row describes a token transfer already visible on any explorer.';
comment on column public.payouts.amount is
  'Authoritative, read off the chain by confirm-payout. Null until then, and null forever on a payout that failed.';
comment on column public.payouts.claimed_amount_unverified is
  'What the client asserted at request time. Never truth; kept only so a discrepancy with the verified amount is visible.';
comment on column public.payouts.expires_at_block_height is
  'Read from getLatestBlockhash server-side, never supplied by the caller — a low value from a caller would manufacture a false "definitely did not land".';


-- =========================================================================
-- SECTION 2 of 16 — 20260805120100_writer_functions.sql
-- =========================================================================

-- xNFTs index — the write path.
--
-- Every one of these runs as SECURITY DEFINER with EXECUTE revoked from anon and
-- authenticated, so the only caller that can reach them is a service-role Edge
-- Function. That is deliberate: it means the trust boundary is one hop wide.
-- `ingest-signature` reads a transaction off the chain, reconciles its token
-- balance deltas against its instructions, and calls exactly one of these — and
-- because the whole multi-table effect of a single chain event happens inside one
-- function, it is one transaction. A half-ingested signature (fee recorded, mint
-- missing) cannot exist.
--
-- Each returns 'inserted' or 'duplicate' so the caller can tell a first sighting
-- from a replay without a second round trip.
--
-- search_path is pinned to '' on every function: a SECURITY DEFINER function that
-- resolves object names through the caller's search_path is a privilege-escalation
-- primitive, so every user object below is schema-qualified.
--
-- WHICH WRITERS ARE CHAIN-BACKED AND WHICH ARE NOT:
--
--   record_mint            chain — called only by ingest-signature
--   record_rent            chain — called only by ingest-signature
--   record_payout_pending  chain-adjacent — a signature exists, nothing verified
--   settle_payout          chain — writes only what confirm-payout read
--   record_simulated_sale  SIMULATED — writes trades and moves ownership
--
-- The simulated one is separated by name rather than by a parameter, so no caller
-- can flip a boolean and write a simulated row into a chain-backed table.

-- ---------------------------------------------------------------------------
-- Read helper — lets ingest skip an RPC round trip on a replayed post
-- ---------------------------------------------------------------------------

-- trades is not consulted: it holds no chain-derived rows, so a signature can
-- never be "already indexed" because of one.
create or replace function public.is_signature_indexed(p_signature text)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (select 1 from public.mints where signature = p_signature)
      or exists (select 1 from public.fee_ledger where signature = p_signature);
$$;

-- ---------------------------------------------------------------------------
-- record_mint
-- ---------------------------------------------------------------------------

-- p_burned and p_fee are text, not bigint, because they are u64 raw units.
-- Sending them as JSON numbers would route them through a double on the way here,
-- and this is not the file to start making exceptions to that rule in.
--
-- Note what this function does NOT do: it does not touch public.xployees. The old
-- version did, because the program's MintEvent named the xployee it had just
-- assigned. Two token transfers name nothing, so there is no honest way to say
-- which xployee this mint bought, and inventing one would put a wrong owner into
-- the index under the authority of a verified transaction.
create or replace function public.record_mint(
  p_signature   text,
  p_event_index integer,
  p_slot        bigint,
  p_block_time  timestamptz,
  p_buyer       text,
  p_burned      text,
  p_fee         text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
begin
  insert into public.mints (signature, event_index, buyer, burned, fee, slot, block_time)
  values (p_signature, p_event_index, p_buyer, p_burned, p_fee, p_slot, p_block_time)
  on conflict (signature, event_index) do nothing;
  v_inserted := found;

  insert into public.fee_ledger (signature, source, event_index, payer, amount, slot, block_time)
  values (p_signature, 'mint', p_event_index, p_buyer, p_fee, p_slot, p_block_time)
  on conflict (signature, source, event_index) do nothing;

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- record_rent
-- ---------------------------------------------------------------------------

-- Rentals never move the xployee, so there is nothing to reassign — the only
-- durable consequence a rental has in this schema is the fee.
--
-- The renter, the owner and the total paid are all verified from the chain, and
-- the fee row keeps the payer. The term is not recoverable: two token transfers
-- say how much was paid but not for how many epochs, so tenancy stays an
-- application concept and no rentals table is invented to hold a number the chain
-- did not state. That is flagged in supabase/README.md rather than silently
-- patched with a default.
create or replace function public.record_rent(
  p_signature   text,
  p_event_index integer,
  p_slot        bigint,
  p_block_time  timestamptz,
  p_renter      text,
  p_owner       text,
  p_gross       text,
  p_fee         text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
begin
  insert into public.fee_ledger (signature, source, event_index, payer, amount, slot, block_time)
  values (p_signature, 'rent', p_event_index, p_renter, p_fee, p_slot, p_block_time)
  on conflict (signature, source, event_index) do nothing;
  v_inserted := found;

  -- A rental closes a rent listing only if the owner listing it is the owner who
  -- was actually paid. Without that check any renter could close any listing by
  -- paying anyone; with it, the transaction has to corroborate the row it edits.
  update public.listings l
     set status = 'rented',
         updated_at = now()
   where l.seller = p_owner
     and l.kind = 'rent'
     and l.status = 'active'
     and exists (
       select 1 from public.xployees x
        where x.id = l.xployee_id
          and x.owner = p_owner
     );

  -- p_gross is verified by the caller and deliberately not stored. It is still in
  -- the signature so the drop is visible at the call site rather than being an
  -- absence someone has to notice: storing it would mean a rentals table, and a
  -- rentals table needs a term column that nothing on-chain can fill.

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- record_simulated_sale — THE SIMULATED WRITE PATH
-- ---------------------------------------------------------------------------

-- Writes a sale that did not happen on any chain, and moves ownership because of
-- it. Everything about that sentence is uncomfortable and all of it is honest:
-- sales are simulated, so the only thing that can record one is the application.
--
-- `origin` is hard-coded to 'simulated' and is not a parameter. There is no
-- argument to this function that can produce a row claiming to be chain-backed.
--
-- THIS IS THE FIX FOR THE OWNERSHIP DEFECT. The previous writer reassigned
-- ownership with:
--
--     update public.xployees set owner = p_buyer where nft_mint = p_nft_mint
--
-- while no writer anywhere ever populated `xployees.nft_mint`. The predicate
-- matched zero rows on every sale, so ownership never moved, and it failed
-- silently because an UPDATE that matches nothing is not an error. Two things
-- changed:
--
--   1. The join key is `xployee_id`, which is the key this very function writes
--      into public.trades — so the column the update reads and the column the
--      caller supplies are the same column.
--   2. The xployees row is upserted rather than updated. A sale of an xployee
--      this index has not seen before now creates it owned by the buyer, instead
--      of quietly doing nothing. A no-op is impossible rather than merely
--      unlikely.
--
-- No fee_ledger row is written. A simulated sale accrues no real fee, and the fee
-- ledger is reconciled against a treasury token account anyone can read.
create or replace function public.record_simulated_sale(
  p_sale_ref      text,
  p_xployee_id    bigint,
  p_nft_mint      text,
  p_buyer         text,
  p_seller        text,
  p_gross         text,
  p_fee           text,
  p_net_to_seller text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
begin
  if p_buyer = p_seller then
    raise exception 'record_simulated_sale: buyer and seller are the same wallet';
  end if;

  insert into public.trades (sale_ref, xployee_id, nft_mint, buyer, seller, gross, fee, net_to_seller, origin)
  values (p_sale_ref, p_xployee_id, p_nft_mint, p_buyer, p_seller, p_gross, p_fee, p_net_to_seller, 'simulated')
  on conflict (sale_ref) do nothing;
  v_inserted := found;

  -- Only on a first sighting. Replaying a sale must not move ownership again,
  -- because by then a later sale may have moved it on.
  if v_inserted then
    insert into public.xployees (id, owner, updated_at)
    values (p_xployee_id, p_buyer, now())
    on conflict (id) do update
       set owner      = excluded.owner,
           updated_at = now();

    update public.listings l
       set status = 'sold',
           updated_at = now()
     where l.xployee_id = p_xployee_id
       and l.status = 'active';
  end if;

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- payouts
-- ---------------------------------------------------------------------------

-- Called by request-payout the moment the wallet hands back a signature. The row
-- is written with no verified amount on purpose: the transaction is genuinely in
-- flight, nothing has read it, and `amount` stays null until something does.
-- p_claimed_amount_unverified is the client's assertion and goes into the column
-- whose name says exactly that.
create or replace function public.record_payout_pending(
  p_signature                 text,
  p_claimed_amount_unverified text,
  p_destination               text,
  p_expires_at_block_height   bigint
) returns public.payouts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.payouts;
begin
  insert into public.payouts (
    amount, claimed_amount_unverified, destination, status, signature, expires_at_block_height
  )
  values (
    null, p_claimed_amount_unverified, p_destination, 'pending', p_signature, p_expires_at_block_height
  )
  on conflict (signature) do nothing;

  -- A double-post returns the row that already exists rather than erroring, so a
  -- retried browser request is indistinguishable from the first one. Note that it
  -- returns the ORIGINAL row: a second post cannot revise the expiry height or
  -- the claimed amount of a claim already on record.
  select * into v_row from public.payouts where signature = p_signature;
  return v_row;
end;
$$;

-- The confirm path. Deliberately cannot express "pending" — a caller that wanted
-- to leave a row alone calls touch_payout instead. Splitting them this way means
-- the rule "a timeout must never mark a payout failed" is enforced by which
-- function got called, not by a branch inside one that could be written wrong.
--
-- p_amount and p_destination are what confirm-payout read out of the transaction's
-- own token balance deltas. Writing them is the moment the row stops being a
-- claim about money and starts being a reading of money — which is why a
-- confirmation without an amount is refused here as well as by the table's check
-- constraint. Two locks, because this is the one transition that turns an
-- unverified number into a settled one.
create or replace function public.settle_payout(
  p_signature      text,
  p_status         text,
  p_amount         text default null,
  p_destination    text default null,
  p_failure_reason text default null
) returns public.payouts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.payouts;
begin
  if p_status not in ('confirmed', 'failed') then
    raise exception 'settle_payout accepts only confirmed or failed, got %', p_status;
  end if;
  if p_status = 'confirmed' and p_amount is null then
    raise exception 'settle_payout: a confirmation needs the amount read off the chain';
  end if;
  if p_status = 'failed' and p_amount is not null then
    raise exception 'settle_payout: a failed payout moved nothing and has no amount';
  end if;

  -- `where status = 'pending'` makes settlement one-way. Re-running the scheduled
  -- sweep over an already-settled row is a no-op, and a later contradictory read
  -- (a status query that briefly forgets a signature) cannot flip a confirmed
  -- payout back to failed.
  update public.payouts p
     set status         = p_status,
         amount         = p_amount,
         destination    = coalesce(p_destination, p.destination),
         failure_reason = case when p_status = 'failed' then p_failure_reason else null end,
         confirmed_at   = now(),
         last_checked_at = now()
   where p.signature = p_signature
     and p.status = 'pending'
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.payouts where signature = p_signature;
  end if;

  return v_row;
end;
$$;

-- The unknown-status path. It can move `last_checked_at` and nothing else, so a
-- payout whose fate the chain has not yet decided stays exactly as pending as it
-- really is. Presenting a possibly-landed claim as failed is how you get someone
-- to claim twice, and the second claim is a second withdrawal.
create or replace function public.touch_payout(p_signature text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.payouts
     set last_checked_at = now()
   where signature = p_signature
     and status = 'pending';
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

-- PostgREST resolves /rpc/<fn> through the caller's role, so revoking EXECUTE
-- here is what stops the anon key from calling a writer directly. Without this,
-- SECURITY DEFINER would hand anon exactly the privileges it is meant to deny.
revoke all on function public.is_signature_indexed(text) from public, anon, authenticated;
revoke all on function public.record_mint(text, integer, bigint, timestamptz, text, text, text) from public, anon, authenticated;
revoke all on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) from public, anon, authenticated;
revoke all on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.record_payout_pending(text, text, text, bigint) from public, anon, authenticated;
revoke all on function public.settle_payout(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.touch_payout(text) from public, anon, authenticated;

grant execute on function public.is_signature_indexed(text) to service_role;
grant execute on function public.record_mint(text, integer, bigint, timestamptz, text, text, text) to service_role;
grant execute on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) to service_role;
grant execute on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) to service_role;
grant execute on function public.record_payout_pending(text, text, text, bigint) to service_role;
grant execute on function public.settle_payout(text, text, text, text, text) to service_role;
grant execute on function public.touch_payout(text) to service_role;


-- =========================================================================
-- SECTION 3 of 16 — 20260805120200_rls_policies.sql
-- =========================================================================

-- xNFTs index — row level security.
--
-- The shape of the whole policy set, in one sentence: the anon key can read
-- everything and can write absolutely nothing, anywhere, ever.
--
-- The write half is closed structurally, in three independent layers, because a
-- filter is only as good as the next person who edits the query:
--
--   1. GRANT — anon and authenticated hold SELECT and nothing else. A client
--      INSERT is rejected before RLS is even consulted.
--   2. RESTRICTIVE policies — an explicit `with check (false)` / `using (false)`
--      on every write verb of every table. Postgres already denies anything with
--      no permissive policy, but a restrictive policy also survives someone later
--      adding a well-meaning permissive one, and it states the intent in the
--      schema instead of in a comment.
--   3. Writers are SECURITY DEFINER functions granted only to service_role
--      (see 20260805120100), so the only write path is an Edge Function.
--
-- ---------------------------------------------------------------------------
-- WHY PAYOUT HISTORY IS PUBLIC
-- ---------------------------------------------------------------------------
-- An earlier version of this file restricted `payouts` to a single authority
-- address, on the reasoning that a treasury operations log says how much the dev
-- wallet has taken and when. That reasoning does not survive contact with what a
-- payout now is.
--
-- A payout is a plain SPL token transfer from the treasury's associated token
-- account to the dev wallet's. It is in a block. Anyone with an RPC endpoint —
-- or Solscan, or a browser — can list every transfer that account has ever made,
-- with amounts and timestamps, without asking this database for permission.
-- There is nothing here that is not already published by the ledger.
--
-- So the old policy protected nothing. What it actually did was cost something:
-- it required a session carrying a `wallet_address` JWT claim, which this app has
-- no way to mint, so the Payouts page rendered an empty history no matter who was
-- looking, including the operator. A lock that keeps out only the person holding
-- the key, on a door that has no wall beside it, is theatre — and theatre in a
-- security policy is worse than no policy, because it invites someone to reason
-- "payouts are protected" about a table that is readable from a block explorer.
--
-- The honest arrangement is this one: the history is public because the transfers
-- are public, and the thing that actually needs defending — the ability to WRITE
-- a payout row, and in particular to flip one to 'confirmed' — is closed to the
-- anon key exactly as tightly as every other table here. Note also that
-- `payouts.amount` is null until a chain reading fills it and `amount_verified`
-- is generated from that, so a public reader cannot even be shown an unverified
-- number dressed as a settled one.
--
-- The `app.authority_address` database setting the old policy depended on is gone
-- with it. Nothing reads it; do not set it.
--
-- RLS is deliberately NOT forced. FORCE ROW LEVEL SECURITY would also subject the
-- table owner to these policies, and the owner is exactly who the SECURITY DEFINER
-- writer functions run as — forcing it would lock out the only legitimate writer.

alter table public.wallets    enable row level security;
alter table public.xployees   enable row level security;
alter table public.listings   enable row level security;
alter table public.trades     enable row level security;
alter table public.mints      enable row level security;
alter table public.fee_ledger enable row level security;
alter table public.payouts    enable row level security;

-- ---------------------------------------------------------------------------
-- Layer 1 — table privileges
-- ---------------------------------------------------------------------------

revoke all on public.wallets    from anon, authenticated;
revoke all on public.xployees   from anon, authenticated;
revoke all on public.listings   from anon, authenticated;
revoke all on public.trades     from anon, authenticated;
revoke all on public.mints      from anon, authenticated;
revoke all on public.fee_ledger from anon, authenticated;
revoke all on public.payouts    from anon, authenticated;

grant select on public.wallets    to anon, authenticated;
grant select on public.xployees   to anon, authenticated;
grant select on public.listings   to anon, authenticated;
grant select on public.trades     to anon, authenticated;
grant select on public.mints      to anon, authenticated;
grant select on public.fee_ledger to anon, authenticated;
grant select on public.payouts    to anon, authenticated;

-- Sequences are a write primitive: nextval() mutates. Nothing client-side has any
-- business calling one.
revoke all on all sequences in schema public from anon, authenticated;

-- A table added by a later migration must not arrive writable by accident. This
-- makes the safe state the default one.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Layer 2 — read policies
-- ---------------------------------------------------------------------------

-- Every row in these seven tables is either already on-chain and readable by
-- anyone with an RPC endpoint, or is simulated data this application made up, or
-- is a self-published profile. There is nothing here to leak, and making it
-- readable is what lets the frontend run on the anon key alone.
--
-- A reader who wants to know which is which reads the `origin` column, not the
-- policy — see 20260805120000.

create policy "wallets are public" on public.wallets
  for select to anon, authenticated using (true);

create policy "xployees are public" on public.xployees
  for select to anon, authenticated using (true);

create policy "listings are public" on public.listings
  for select to anon, authenticated using (true);

create policy "trades are public" on public.trades
  for select to anon, authenticated using (true);

create policy "mints are public" on public.mints
  for select to anon, authenticated using (true);

create policy "fee ledger is public" on public.fee_ledger
  for select to anon, authenticated using (true);

-- Public for the reason argued at the top of this file: these are transfers
-- already visible on any block explorer, and gating them here while they are
-- published on chain would be theatre.
create policy "payouts are public" on public.payouts
  for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------------
-- Layer 3 — explicit write denial
-- ---------------------------------------------------------------------------

-- Restrictive policies AND together with everything else, so `false` is final:
-- no permissive policy added later can grant a client write, and the denial is
-- visible in \d output instead of being an absence someone has to notice.

create policy "wallets accept no client insert" on public.wallets
  as restrictive for insert to anon, authenticated with check (false);
create policy "wallets accept no client update" on public.wallets
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "wallets accept no client delete" on public.wallets
  as restrictive for delete to anon, authenticated using (false);

create policy "xployees accept no client insert" on public.xployees
  as restrictive for insert to anon, authenticated with check (false);
create policy "xployees accept no client update" on public.xployees
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "xployees accept no client delete" on public.xployees
  as restrictive for delete to anon, authenticated using (false);

create policy "listings accept no client insert" on public.listings
  as restrictive for insert to anon, authenticated with check (false);
create policy "listings accept no client update" on public.listings
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "listings accept no client delete" on public.listings
  as restrictive for delete to anon, authenticated using (false);

-- Trades hold simulated rows, and that makes a client write MORE tempting rather
-- than less: a row here moves ownership of an xployee through
-- record_simulated_sale, and there is no chain reading anywhere that would later
-- contradict it. Closed exactly as tightly as the chain-backed tables.
create policy "trades accept no client insert" on public.trades
  as restrictive for insert to anon, authenticated with check (false);
create policy "trades accept no client update" on public.trades
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "trades accept no client delete" on public.trades
  as restrictive for delete to anon, authenticated using (false);

create policy "mints accept no client insert" on public.mints
  as restrictive for insert to anon, authenticated with check (false);
create policy "mints accept no client update" on public.mints
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "mints accept no client delete" on public.mints
  as restrictive for delete to anon, authenticated using (false);

create policy "fee ledger accepts no client insert" on public.fee_ledger
  as restrictive for insert to anon, authenticated with check (false);
create policy "fee ledger accepts no client update" on public.fee_ledger
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "fee ledger accepts no client delete" on public.fee_ledger
  as restrictive for delete to anon, authenticated using (false);

-- Payouts is the table where a client write would be worth the most, and making
-- reads public does not change that by one inch: flipping a pending row to
-- confirmed would present a claim as settled before the chain agreed with it, and
-- inserting one would put a signature into the sweep that confirm-payout would
-- then go and settle against a transaction nobody sent.
create policy "payouts accept no client insert" on public.payouts
  as restrictive for insert to anon, authenticated with check (false);
create policy "payouts accept no client update" on public.payouts
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "payouts accept no client delete" on public.payouts
  as restrictive for delete to anon, authenticated using (false);


-- =========================================================================
-- SECTION 4 of 16 — 20260805120300_rent_closes_one_listing.sql
-- =========================================================================

-- xNFTs index — a rental closes the listing that was rented, and only that one.
--
-- Additive, as every correction to this schema has to be: 20260805120100 has been
-- written and may have been applied, so it is not edited. `create or replace
-- function` on the same signature is the whole mechanism — it keeps the existing
-- privileges, and the grants at the bottom are restated rather than relied on so
-- this file can be read on its own.
--
-- ---------------------------------------------------------------------------
-- THE DEFECT
-- ---------------------------------------------------------------------------
-- The previous body closed listings like this:
--
--     update public.listings l
--        set status = 'rented'
--      where l.seller = p_owner
--        and l.kind = 'rent'
--        and l.status = 'active'
--        and exists (... x.owner = p_owner ...)
--
-- Every predicate there is about the OWNER. Not one of them is about which
-- listing was actually rented — and nothing anywhere tied the amount that was
-- paid to any listing's price. So an owner advertising three xployees for rent
-- had all three marked 'rented' by a single rental of one of them, and the other
-- two vanished from the marketplace while remaining perfectly available. The
-- damage was silent, because an UPDATE that matches too many rows is no more of
-- an error than one that matches too few.
--
-- ---------------------------------------------------------------------------
-- WHAT REPLACES IT, AND WHAT IT CANNOT DO
-- ---------------------------------------------------------------------------
-- The transaction has to corroborate the row it edits, and the only thing it says
-- beyond who was paid is HOW MUCH. `src/lib/fees.ts` defines a rental contract as
-- `fee_per_epoch × term_epochs` to the owner with the protocol fee riding on top,
-- and `_shared/events.ts` recognises a rental by exactly that relationship — so
-- `p_gross`, which is the owner's leg read off the chain, is the contract total of
-- whichever listing was rented. Matching on it turns "some listing of this
-- owner's" into "the listing whose price the payment actually is".
--
-- Then `limit 1`: at most one listing closes, ever. Two listings of the same
-- owner priced identically are genuinely indistinguishable from the chain — two
-- token transfers carry no listing id — so the oldest is closed and the tie-break
-- is stated (`updated_at asc, nft_mint asc`) rather than left to the planner.
-- Closing one of two identical listings is a defensible guess; closing both is
-- not, and closing all three of an owner's unrelated listings never was.
--
-- No match closes nothing. An owner paid an amount that corresponds to no listing
-- of theirs still gets the fee row — the money moved and the chain proves it — and
-- the marketplace is left alone, because inventing which advertisement that
-- payment settled would be exactly the kind of guess the fee ledger is not
-- allowed to be built on.
--
-- The close is also now inside the first-sighting branch, matching
-- record_simulated_sale. Re-posting a months-old rent signature must not reach
-- into today's marketplace and close a listing that happens to carry the same
-- total; the fee row's `on conflict do nothing` already made the money idempotent,
-- and this makes the side effect idempotent too.

create or replace function public.record_rent(
  p_signature   text,
  p_event_index integer,
  p_slot        bigint,
  p_block_time  timestamptz,
  p_renter      text,
  p_owner       text,
  p_gross       text,
  p_fee         text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
begin
  insert into public.fee_ledger (signature, source, event_index, payer, amount, slot, block_time)
  values (p_signature, 'rent', p_event_index, p_renter, p_fee, p_slot, p_block_time)
  on conflict (signature, source, event_index) do nothing;
  v_inserted := found;

  if v_inserted then
    -- The outer `status = 'active'` is not redundant with the subquery's: between
    -- choosing the row and updating it, a concurrent rental may already have
    -- closed it, and re-closing a listing would move its updated_at for an event
    -- that changed nothing.
    update public.listings l
       set status = 'rented',
           updated_at = now()
     where l.status = 'active'
       and l.nft_mint = (
         select m.nft_mint
           from public.listings m
          where m.seller = p_owner
            and m.kind = 'rent'
            and m.status = 'active'
            and m.fee_per_epoch is not null
            and m.term_epochs is not null
            -- The listings_priced_by_kind constraint already guarantees both are
            -- present on a rent listing; the null checks are here so the
            -- arithmetic below cannot quietly become null and match nothing for a
            -- reason nobody would look for.
            --
            -- ::numeric because amounts are stored as digit strings (see the
            -- u64_text domain) — the cast is the price of a column that survives
            -- PostgREST without going through a double, and the comparison is
            -- exact integer arithmetic either way.
            and m.fee_per_epoch::numeric * m.term_epochs::numeric = p_gross::numeric
            -- The seller of a listing is not proof of anything on its own; the
            -- xployee has to be theirs too. Without this a stale listing left
            -- behind by a previous owner could be closed by the new owner's rental.
            and exists (
              select 1
                from public.xployees x
               where x.id = m.xployee_id
                 and x.owner = p_owner
            )
          order by m.updated_at asc, m.nft_mint asc
          limit 1
       );
  end if;

  -- p_gross is now load-bearing rather than merely documented: it is what
  -- identifies the listing. It is still not stored, for the reason the original
  -- writer gave — storing it means a rentals table, and a rentals table needs a
  -- term column that nothing on-chain can fill.

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- Matches the subquery's predicate: owner, then kind and status. The existing
-- listings_seller_idx covers `seller` alone, which is enough for one owner's
-- listings but makes the planner filter the rest.
create index if not exists listings_rent_match_idx
  on public.listings (seller, kind, status);

-- ---------------------------------------------------------------------------
-- The pending-payout sweep
-- ---------------------------------------------------------------------------
--
-- `confirm-payout` used to sweep pending rows oldest-first. The payouts queue is
-- writable through an endpoint that has no authorisation and cannot have one — the
-- anon key is public and the transaction being recorded has not landed yet — so a
-- strict FIFO meant anyone could park rows at the head of it and a real payout
-- behind them would never be reached within the sweep's bound. It now sweeps
-- least-recently-checked first, which makes the queue round-robin: examining a row
-- moves it to the back, and every pending row is reached within a bounded number
-- of sweeps regardless of how many siblings it has.
--
-- `nulls first` matches the order the function asks PostgREST for, so a row
-- nothing has looked at yet is served before one that has been.
create index if not exists payouts_pending_sweep_idx
  on public.payouts (status, last_checked_at asc nulls first, requested_at asc);

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------
--
-- `create or replace function` preserves the privileges on the existing function,
-- so these are a restatement rather than a repair. They are here because a reader
-- checking that anon cannot call a writer should be able to answer that from the
-- file that last defined it.
revoke all on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) from public, anon, authenticated;
grant execute on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) to service_role;


-- =========================================================================
-- SECTION 5 of 16 — 20260806090000_mint_fee_retired.sql
-- =========================================================================

-- xNFTs index — the mint fee is gone, and the schema stops being able to hold one.
--
-- Additive, like every correction to this schema: 20260805120000 has been written
-- and may have been applied, so it is not edited. What changes here is what the
-- columns are ALLOWED to contain, which is the only kind of change that actually
-- retires an economic parameter. Setting the fee to zero somewhere in application
-- code retires nothing — a zero is a value, and a value can be changed back by
-- anyone who finds the constant.
--
-- ---------------------------------------------------------------------------
-- WHAT A MINT IS NOW
-- ---------------------------------------------------------------------------
-- ONE transferChecked. 10,000 $xNFT from the buyer to
-- `1nc1nerator11111111111111111111111111111111`. No treasury leg, no protocol
-- fee, no second amount to reconcile. Every token the buyer spends is burned.
--
-- This is a strictly stronger claim than the old two-leg mint, and it is worth
-- being precise about why: with a fee leg, "was this a mint?" was a question
-- about a *pair* of transfers that had to agree with each other, and a
-- transaction that burned correctly while underpaying the fee was a partial mint
-- with an irreversible burn already inside it. With one leg there is no pair, no
-- second amount, and no partial state. The burn either happened at the published
-- size or the transaction is not a mint.
--
-- ---------------------------------------------------------------------------
-- WHY `mints.fee` SURVIVES AS A COLUMN
-- ---------------------------------------------------------------------------
-- Dropping it outright would be cleaner in the schema and worse everywhere else:
-- `src/lib/supabase.ts` parses a mint row with `rawUnits(row.fee)` and REFUSES
-- the row when that comes back null. PostgREST omits a dropped column entirely,
-- so `select=*` would hand the browser rows with no `fee` key, every one of them
-- would parse to null, and the Transactions page would render permanently empty
-- against a database that is perfectly correct. That is the same failure the
-- comment block in supabase.ts was written about — a reader stricter than the
-- schema — and it is not worth re-creating from the other side.
--
-- So the column stays and is nailed to zero by a check constraint. Note what that
-- buys, because it is more than a default would: a default is what happens when
-- nobody says otherwise, and a check is what happens no matter who says
-- otherwise. `record_mint` cannot write a fee, a service-role INSERT cannot write
-- a fee, and a future migration that wants one has to delete this constraint by
-- name — which is a thing a reviewer can see, unlike a constant quietly changing
-- from 0 to 500.
--
-- The removal path is stated rather than implied: when `parseMint` in
-- src/lib/supabase.ts stops requiring `fee`, drop the column and this constraint
-- together.

-- ---------------------------------------------------------------------------
-- mints.fee — vestigial, and permanently zero
-- ---------------------------------------------------------------------------

-- The column is NOT NULL with no default, so a writer that stops supplying it
-- would fail its insert. The default is what lets `record_mint` drop the
-- parameter; the check is what stops the default being talked out of.
alter table public.mints
  alter column fee set default '0';

alter table public.mints
  add constraint mints_never_carry_a_fee check (fee = '0');

comment on column public.mints.fee is
  'VESTIGIAL, permanently ''0'', enforced by mints_never_carry_a_fee. A mint is one transfer to the incinerator and pays nobody. '
  'The column is retained only because src/lib/supabase.ts refuses a mint row whose `fee` is absent; drop both together when that parser stops requiring it.';

comment on table public.mints is
  'Chain-backed only. Every row corresponds to a transaction ingest-signature fetched and recognised as exactly one transfer of 10,000 $xNFT to the incinerator, reconciled against the token balance deltas. There is no fee leg and there is no treasury leg.';

-- ---------------------------------------------------------------------------
-- fee_ledger — a mint can no longer accrue anything
-- ---------------------------------------------------------------------------

-- The fee ledger is reconciled against the treasury's real token account. A mint
-- now moves nothing into it, so a `source = 'mint'` row would be an accrual with
-- no deposit behind it — the exact corruption the table's original comment says
-- the missing 'sale' value exists to prevent, arriving through the other door.
--
-- A zero-valued mint row would be no better than a wrong one. It would still
-- appear in `fetchFeeLedger`, still be counted by `sumFees(rows, 'mint')`, and
-- still tell a reader that mints are a revenue source. They are not one.
--
-- The domain check on `source` is left alone — widening it back is not something
-- this migration should make easy — and the exclusion is expressed as its own
-- named constraint so it reads as a decision rather than as an omission.
alter table public.fee_ledger
  add constraint fee_ledger_mints_accrue_nothing check (source <> 'mint');

comment on constraint fee_ledger_mints_accrue_nothing on public.fee_ledger is
  'A mint burns every token it costs and pays no fee, so it produces no treasury revenue. A row here would overstate a balance anyone can go and read on chain.';

comment on table public.fee_ledger is
  'Chain-backed rental fees only. Sum this against the treasury token account balance plus confirmed payouts. Mints accrue nothing (fee_ledger_mints_accrue_nothing) and simulated sales accrue nothing (the source check has no ''sale''), so the two exclusions between them are what keep this table reconcilable.';

-- ---------------------------------------------------------------------------
-- record_mint — the old signature goes
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced in place. The seventh parameter WAS the fee, so a
-- `create or replace` keeping the same argument list would leave a function that
-- still accepts one — and an accepted parameter is an invitation. Removing the
-- signature means a caller that still passes a fee gets "function does not exist"
-- from Postgres instead of silently writing a number nowhere.
--
-- Its replacement is defined in 20260806090500_mint_control.sql, because the new
-- writer does more than record a transfer: it assigns the serial. Defining it
-- here and immediately rewriting it there would be two versions of one function
-- in one push, and the second one is the only one that has ever run.
drop function if exists public.record_mint(text, integer, bigint, timestamptz, text, text, text);


-- =========================================================================
-- SECTION 6 of 16 — 20260806090100_collection.sql
-- =========================================================================

-- xNFTs index — the collection itself.
--
-- 20260805120000 gave `public.xployees` an id, an owner and a handful of
-- nullable descriptive columns, on the reasoning that identity lived in the
-- browser: `src/lib/xployee.ts` rebuilds a whole worker from its serial, so the
-- database only had to remember who held it.
--
-- That reasoning stops working the moment minting is real. A serial is now
-- ASSIGNED — dealt from a permutation, once, to one buyer — and an assignment
-- that only one party can compute is not an assignment, it is an opinion. The
-- database has to be able to answer "what is #1885, and does that row agree with
-- the rarity its number claims?" without running a TypeScript bundle.
--
-- ---------------------------------------------------------------------------
-- RARITY IS POSITIONAL, AND THAT IS ENFORCED HERE RATHER THAN TRUSTED
-- ---------------------------------------------------------------------------
-- `src/lib/tiers.ts::tierForId` lays the collection out rarest-first, so a serial
-- IS a rarity claim: #0000–#0149 X-RATED, #0150–#0749 EPIC, #0750–#1999 RARE,
-- #2000–#4999 UNCOMMON. Two mechanisms make each row agree with it, and they fail
-- in opposite directions on purpose:
--
--   `public.tier_for_id(id)`   — the same function, in SQL. A check constraint
--                                built on it means a row whose tier contradicts
--                                its serial cannot be written by ANY writer,
--                                including a service-role INSERT and including a
--                                hand-typed statement in the SQL editor.
--   the stamping trigger       — fills tier, skills and principal in from the id
--                                when a writer does not supply them, so the check
--                                is satisfied by construction rather than by
--                                every caller remembering to.
--
-- A trigger alone would be defeated by `alter table ... disable trigger`. A check
-- alone would turn every partial upsert — `record_simulated_sale` writes (id,
-- owner) and nothing else — into a constraint violation. Together, the safe state
-- is also the default one.
--
-- ---------------------------------------------------------------------------
-- LITERALS PLUS AN ASSERTION, NOT A LOOKUP
-- ---------------------------------------------------------------------------
-- Three functions below carry hard-coded numbers that also appear in a table:
-- the tier bands, the skill count per tier, the size of each trait vocabulary.
-- That duplication is deliberate and it is checked. A check constraint may only
-- call an IMMUTABLE function, and a function that reads a table is not immutable
-- however it is declared — marking one immutable and then building a constraint
-- on it is a well-known way to get a constraint that silently disagrees with the
-- data it was supposed to guard. So the constrainable values are literals, and
-- the DO block at the end of this file recomputes every one of them from the
-- registry tables and raises if any has drifted. Editing a supply share without
-- editing the function fails the next `db push` instead of reclassifying a
-- thousand serials in silence.

-- ---------------------------------------------------------------------------
-- Supply
-- ---------------------------------------------------------------------------

-- 5,000, matching MAX_SUPPLY in src/lib/xployee.ts. A function rather than a
-- literal scattered through six constraints: the number appears once, and a
-- reader asking "how big is the collection" has one place to look.
create or replace function public.max_supply()
returns integer
language sql
immutable
parallel safe
set search_path = ''
as $$ select 5000 $$;

comment on function public.max_supply() is
  'Total serials that can ever exist. Matches MAX_SUPPLY in src/lib/xployee.ts. Changing it invalidates the reveal permutation and every tier boundary below.';

-- ---------------------------------------------------------------------------
-- Tier registry
-- ---------------------------------------------------------------------------

create table public.tiers (
  id     text primary key check (id in ('entry', 'mid', 'expert', 'xrated')),
  label  text not null,
  -- Number of skills an xployee of this tier carries. Unique, because the skill
  -- count IS the rarity rank — two tiers carrying three skills each would make
  -- "rarer" meaningless.
  skills smallint not null unique check (skills between 1 and 4),
  -- Share of supply, 0–1. The four must sum to exactly 1; asserted below.
  supply numeric(6, 4) not null check (supply > 0 and supply <= 1),
  color  text not null,
  shade  text not null,
  light  text not null,
  effect text not null check (effect in ('none', 'glow', 'laser'))
);

comment on table public.tiers is
  'Mirrors TIERS in src/lib/tiers.ts. Descriptive: the serial bands are literals in tier_for_id(), and the DO block at the end of this migration asserts they still match these supply shares.';

insert into public.tiers (id, label, skills, supply, color, shade, light, effect) values
('entry','UNCOMMON',1,0.6,'#44AF63','#2f7d46','#7fcb96','none'),
('mid','RARE',2,0.25,'#1D84DE','#145e9e','#63aeeb','none'),
('expert','EPIC',3,0.12,'#D211B0','#8d0b76','#f45ad6','glow'),
('xrated','X-RATED',4,0.03,'#FF1B1B','#830404','#ff7a6b','laser');

-- ---------------------------------------------------------------------------
-- tier_for_id — the positional rarity function
-- ---------------------------------------------------------------------------

-- The bands, and where the numbers come from. `tierForId` walks rarest-first,
-- taking `round(supply x maxSupply)` serials per tier and letting the LAST tier
-- absorb the rounding remainder:
--
--   X-RATED  round(0.03 x 5000) =  150  ->  #0000–#0149
--   EPIC     round(0.12 x 5000) =  600  ->  #0150–#0749
--   RARE     round(0.25 x 5000) = 1250  ->  #0750–#1999
--   UNCOMMON everything left    = 3000  ->  #2000–#4999
--
-- Out of range RAISES rather than returning a tier. A serial outside the supply
-- is not an unusual xployee, it is an impossible one, and the constraint that
-- calls this should fail loudly instead of quietly classifying #7000 as uncommon.
create or replace function public.tier_for_id(p_id bigint)
returns text
language plpgsql
immutable
parallel safe
strict
set search_path = ''
as $$
begin
  if p_id < 0 or p_id >= public.max_supply() then
    raise exception 'tier_for_id: % is outside the collection (0..%)', p_id, public.max_supply() - 1;
  end if;
  if p_id <  150 then return 'xrated'; end if;
  if p_id <  750 then return 'expert'; end if;
  if p_id < 2000 then return 'mid';    end if;
  return 'entry';
end;
$$;

comment on function public.tier_for_id(bigint) is
  'Positional rarity: the tier a serial belongs to. Mirrors tierForId() in src/lib/tiers.ts. IMMUTABLE so check constraints can be built on it.';

-- Skill count per tier, as a constrainable literal. Mirrors the `skills` column
-- of public.tiers, which the assertion below compares it against.
create or replace function public.skills_for_tier(p_tier text)
returns smallint
language sql
immutable
parallel safe
strict
set search_path = ''
as $$
  select case p_tier
    when 'entry'  then 1
    when 'mid'    then 2
    when 'expert' then 3
    when 'xrated' then 4
  end::smallint
$$;

-- Display form: #0042. One implementation, so a serial never appears two ways on
-- one page.
create or replace function public.serial_label(p_id bigint)
returns text
language sql
immutable
parallel safe
strict
set search_path = ''
as $$ select '#' || lpad(p_id::text, 4, '0') $$;

-- ---------------------------------------------------------------------------
-- Skill registry
-- ---------------------------------------------------------------------------

-- Authoritative, unlike the tier boundaries: nothing builds a check constraint on
-- a skill's rate, so it can live in a table and be read by ordinary queries —
-- which is what lets the apy assertion in 20260806090400 recompute a worker's
-- blended rate from its own skill rows instead of taking the stored number on
-- trust.
create table public.skills (
  id       text primary key,
  label    text not null,
  desk     text not null,
  -- The xStock this desk accrues into. Fiction, and consistent fiction.
  ticker   text not null unique,
  -- Base annual yield, 0–1.
  base_apy numeric(8, 6) not null check (base_apy > 0 and base_apy < 1),
  -- Draw weight. High-APY skills are weighted scarce, so a rare pairing stays rare.
  weight   smallint not null check (weight > 0)
);

comment on table public.skills is
  'Mirrors SKILLS in src/lib/skills.ts. The yield engine: an xployee''s apy is the mean of its held skills'' base_apy x proficiency.';

insert into public.skills (id, label, desk, ticker, base_apy, weight) values
('silicon','Silicon Analyst','Semis','NVDAx',0.092000,5),
('platform','Platform Ops','Megacap Tech','AAPLx',0.074000,8),
('cloud','Cloud Architect','Enterprise SW','MSFTx',0.071000,8),
('ledger','Ledger Clerk','Financials','JPMx',0.063000,10),
('rails','Card Rails','Payments','Vx',0.058000,10),
('crude','Crude Desk','Energy','XOMx',0.081000,6),
('grid','Grid Tech','Industrials','HONx',0.052000,11),
('trial','Trial Nurse','Pharma','LLYx',0.067000,9),
('claims','Claims Adjuster','Health Ins.','UNHx',0.059000,10),
('shelf','Shelf Stocker','Staples','KOx',0.044000,13),
('brand','Brand Manager','Consumer','PGx',0.046000,12),
('ballast','Index Ballast','Broad Market','SPYx',0.040000,14),
('bills','Bills Desk','T-Bills','TBLLx',0.048000,12),
('vault','Vault Keeper','Gold','GLDx',0.032000,11),
('teller','Chain Teller','Crypto Equity','COINx',0.126000,3),
('degen','Treasury Degen','Crypto Proxy','MSTRx',0.141000,2);

-- ---------------------------------------------------------------------------
-- Trait vocabulary
-- ---------------------------------------------------------------------------

-- Four independent slots, drawn by index from fixed arrays in
-- src/lib/xployee.ts. Stored by (slot, index) because the index is what the
-- generator actually rolled, and because a lookup table is what a metadata
-- endpoint needs in order to name a trait without hard-coding a word list.
--
-- Note that ACCESSORIES carries 'None' at BOTH index 0 and index 1. That is not a
-- mistake to normalise away: it is how the generator weights a bare xployee at 2
-- in 10, and collapsing the duplicate would change the odds.
create table public.trait_values (
  slot  text     not null check (slot in ('uniform', 'head', 'face', 'accessory')),
  idx   smallint not null check (idx >= 0),
  label text     not null,
  primary key (slot, idx)
);

comment on table public.trait_values is
  'The four trait vocabularies from src/lib/xployee.ts, by draw index. ACCESSORIES repeats ''None'' at 0 and 1 deliberately — that duplication IS the 2-in-10 chance of no accessory.';

insert into public.trait_values (slot, idx, label) values
('uniform',0,'Coverall'),('uniform',1,'Suit'),('uniform',2,'Vest'),('uniform',3,'Polo'),
('uniform',4,'Apron'),('uniform',5,'Lab Coat'),('uniform',6,'Hoodie'),('uniform',7,'Overcoat'),
('head',0,'Crop'),('head',1,'Sweep'),('head',2,'Bald'),('head',3,'Bun'),('head',4,'Mohawk'),
('head',5,'Cap'),('head',6,'Helmet'),('head',7,'Curls'),('head',8,'Bowl'),('head',9,'Tie-back'),
('face',0,'Neutral'),('face',1,'Focused'),('face',2,'Weary'),('face',3,'Smirk'),
('face',4,'Grin'),('face',5,'Scowl'),('face',6,'Blank'),('face',7,'Squint'),
('accessory',0,'None'),('accessory',1,'None'),('accessory',2,'Glasses'),('accessory',3,'Headset'),
('accessory',4,'Visor'),('accessory',5,'Earpiece'),('accessory',6,'Badge'),('accessory',7,'Lanyard'),
('accessory',8,'Cigar'),('accessory',9,'Shades');

-- ---------------------------------------------------------------------------
-- xployees — the columns the browser used to be the only holder of
-- ---------------------------------------------------------------------------

alter table public.xployees
  -- The seed for every generated surface: the pixel bust in src/lib/avatar.ts,
  -- the scenic background in src/lib/backgrounds.ts, the particle layer. It is
  -- `fakeAddress('xployee:' + id)` — a deterministic pseudo-address, NEVER a real
  -- key and never a token mint. Stored rather than recomputed because it is the
  -- image's identity: a renderer, a CDN path or a metadata service needs one
  -- stable string to key art by, and "run this TypeScript" is not one.
  add column if not exists art_seed text,
  add column if not exists uniform_idx   smallint,
  add column if not exists head_idx      smallint,
  add column if not exists face_idx      smallint,
  add column if not exists accessory_idx smallint,
  -- A cache of backgroundFor(x) in src/lib/backgrounds.ts, which is a pure
  -- function of art_seed and tier. Denormalised on purpose: these are the two
  -- fields a collector filters a marketplace by, and re-deriving them would mean
  -- a SQL port of the background generator that could disagree with the renderer.
  -- Regenerating the seed regenerates both, so they cannot drift apart silently.
  add column if not exists background text,
  add column if not exists overlay    text;

-- Where a rendered copy of the art would live. GENERATED rather than stored, so
-- the path and the serial cannot disagree — the failure mode of an `image_url`
-- column that somebody backfilled once and never again.
alter table public.xployees
  add column if not exists image_path text
    generated always as ('xployees/' || lpad(id::text, 4, '0') || '.png') stored;

-- The padded display form. `id` is the number; this is the string every surface
-- prints. Generated for the same reason.
alter table public.xployees
  add column if not exists serial_display text
    generated always as ('#' || lpad(id::text, 4, '0')) stored;

comment on column public.xployees.art_seed is
  'Deterministic art seed — fakeAddress(''xployee:'' + id). Seeds the bust, the background and the particles. Not a key, not a mint address; nothing may derive an on-chain account from it.';
comment on column public.xployees.image_path is
  'Where a rendered PNG would live. Generated from the serial so it cannot disagree with it. Art is generated in the browser today and nothing writes a file at this path yet.';
comment on column public.xployees.overlay is
  'Particle layer from src/lib/backgrounds.ts: none | snow | rain | thunder | sparks | embers | stars.';

-- ---------------------------------------------------------------------------
-- The rarity invariants
-- ---------------------------------------------------------------------------

alter table public.xployees
  add constraint xployees_within_supply
    check (id >= 0 and id < public.max_supply());

-- THE ONE THAT MATTERS. A row whose tier contradicts its serial cannot exist.
--
-- Permissive on null so that a partial upsert is not a constraint violation. The
-- stamping trigger closes that from the other side by filling the tier in before
-- this check ever runs, so null is unreachable in practice; the tolerance exists
-- so a disabled trigger degrades to "incomplete row" rather than to "sales fail".
alter table public.xployees
  add constraint xployees_tier_is_positional
    check (tier is null or tier = public.tier_for_id(id));

comment on constraint xployees_tier_is_positional on public.xployees is
  'Rarity is positional. A row claiming a tier its serial does not carry is refused, whoever writes it — the service role included.';

-- Skill count and principal are both pure functions of the tier, so a row that
-- disagrees with itself is refused too. principal = 1000 x skills, matching
-- principalFor() in src/lib/xployee.ts.
alter table public.xployees
  add constraint xployees_skills_match_tier
    check (skills is null or tier is null or skills = public.skills_for_tier(tier));

alter table public.xployees
  add constraint xployees_principal_matches_skills
    check (principal is null or skills is null or principal = 1000::numeric * skills);

alter table public.xployees
  add constraint xployees_apy_is_a_rate
    check (apy is null or (apy > 0 and apy < 1));

alter table public.xployees
  add constraint xployees_tier_is_known
    check (tier is null or tier in ('entry', 'mid', 'expert', 'xrated'));

-- Trait indices, bounded to the size of each vocabulary. Literals for the reason
-- given at the top of this file — a check may not contain a subquery, so it
-- cannot ask trait_values how long a list is — and the assertion at the bottom
-- proves these four bounds still match the table.
alter table public.xployees
  add constraint xployees_traits_in_vocabulary check (
    (uniform_idx   is null or uniform_idx   between 0 and 7)
    and (head_idx      is null or head_idx      between 0 and 9)
    and (face_idx      is null or face_idx      between 0 and 7)
    and (accessory_idx is null or accessory_idx between 0 and 9)
  );

alter table public.xployees
  add constraint xployees_overlay_is_known check (
    overlay is null or overlay in ('none', 'snow', 'rain', 'thunder', 'sparks', 'embers', 'stars')
  );

-- ---------------------------------------------------------------------------
-- The stamping trigger
-- ---------------------------------------------------------------------------

-- Fills in what the serial already determines, and REFUSES a writer that supplies
-- something else.
--
-- The refusal half is why this is not merely a convenience. A caller passing
-- tier 'xrated' for #4300 is either confused or malicious, and either way the
-- honest answer is an exception naming the disagreement — not a silent overwrite,
-- which would leave the caller believing something the database does not.
create or replace function public.stamp_xployee_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tier   text;
  v_skills smallint;
begin
  v_tier   := public.tier_for_id(new.id);
  v_skills := public.skills_for_tier(v_tier);

  if new.tier is null then
    new.tier := v_tier;
  elsif new.tier <> v_tier then
    raise exception 'xployee %: that serial is % by position, not %',
      public.serial_label(new.id), v_tier, new.tier;
  end if;

  if new.skills is null then
    new.skills := v_skills;
  elsif new.skills <> v_skills then
    raise exception 'xployee %: a % carries % skills, not %',
      public.serial_label(new.id), v_tier, v_skills, new.skills;
  end if;

  if new.principal is null then
    new.principal := 1000::numeric * v_skills;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger xployees_stamp_identity
  before insert or update on public.xployees
  for each row execute function public.stamp_xployee_identity();

comment on function public.stamp_xployee_identity() is
  'Fills tier, skills and principal from the serial and refuses a writer that supplies a different one. Paired with xployees_tier_is_positional: the trigger makes the safe state the default, the check makes it the only one.';

-- ---------------------------------------------------------------------------
-- xployee_skills — which desks a worker actually works
-- ---------------------------------------------------------------------------

-- One row per held skill, with the proficiency roll that scales it.
--
-- `proficiency_pct` is a SMALLINT of whole percent, not a float. rollSkills draws
-- `randInt(rng, 60, 100) / 100`, so the integer is the value the generator
-- actually produced and the division is a presentation step. Storing the quotient
-- as a float would push a representation error into the one input the yield
-- calculation multiplies by, for no gain at all.
create table public.xployee_skills (
  xployee_id      bigint   not null references public.xployees (id) on delete cascade,
  -- Draw order, 0-based: the order the skills were rolled, which is the order the
  -- xployee sheet lists them.
  slot            smallint not null check (slot between 0 and 3),
  skill_id        text     not null references public.skills (id) on delete restrict,
  proficiency_pct smallint not null check (proficiency_pct between 60 and 100),
  primary key (xployee_id, slot),
  -- A worker cannot hold the same skill twice: pickDistinct draws without
  -- replacement, and a duplicate would double-count one desk in the blend.
  unique (xployee_id, skill_id)
);

create index xployee_skills_skill_idx on public.xployee_skills (skill_id);

comment on table public.xployee_skills is
  'The desks one worker works, in draw order. proficiency_pct is whole percent — the integer randInt actually rolled — so the yield input carries no float rounding.';

-- The join the app would otherwise write in four places. `security_invoker` so
-- the caller's RLS applies rather than the view owner's: a view is not a way to
-- read past a policy.
create view public.xployee_desks with (security_invoker = true) as
  select
    xs.xployee_id,
    xs.slot,
    s.id     as skill_id,
    s.label,
    s.desk,
    s.ticker,
    s.base_apy,
    xs.proficiency_pct,
    (xs.proficiency_pct::numeric / 100)              as proficiency,
    round(s.base_apy * xs.proficiency_pct / 100, 6)  as effective_apy
  from public.xployee_skills xs
  join public.skills s on s.id = xs.skill_id;

comment on view public.xployee_desks is
  'xployee_skills joined to the skill registry with the effective rate computed. Read this rather than recomputing base_apy x proficiency at a call site.';

-- ---------------------------------------------------------------------------
-- reveal_order — the mint permutation, materialised
-- ---------------------------------------------------------------------------

-- Why a table and not an algorithm: `mintOrder()` in src/lib/collection.ts is a
-- Fisher–Yates shuffle over mulberry32, seeded from an FNV-1a hash of the string
-- 'mintorder'. Reproducing that in plpgsql means reproducing Math.imul's 32-bit
-- wraparound and the exact float arithmetic of `Math.floor(rng() * (i + 1))`, and
-- a single bit of disagreement anywhere in 5,000 iterations reorders the entire
-- tail of the collection. The permutation is 5,000 integers; it is cheaper and
-- very much safer to write them down than to maintain a second generator that has
-- to agree with the first forever.
--
-- WHAT IT IS FOR. Rarity is positional, so handing serials out in ascending order
-- would give the first 150 mints every X-RATED in existence and make every mint
-- past #2000 uncommon forever — the mint would stop being a lottery and become a
-- queue position. Dealing from a shuffle restores the lottery while keeping the
-- low numbers genuinely rare.
--
-- WHAT MAKES A SERIAL UNREPEATABLE. `serial` is UNIQUE and `draw_position` is the
-- primary key, so the permutation cannot contain a duplicate however it was
-- loaded — that is a constraint, not a convention, and it holds even if every
-- function in this schema is wrong. `claimed_by` moving from null to a wallet is
-- the whole of assignment, and the dealer in 20260806090500 takes its row with
-- `for update skip locked`, so two concurrent mints take two different positions
-- instead of racing for one.
create table public.reveal_order (
  -- 0-based draw position: the Nth mint takes position N.
  draw_position integer primary key check (draw_position >= 0 and draw_position < public.max_supply()),
  serial        integer not null unique check (serial >= 0 and serial < public.max_supply()),
  -- Who holds it, or null while it is still in the pool.
  --
  -- Deliberately NOT a foreign key to public.wallets: a wallet row is an optional
  -- profile that may never be created, and a mint must never fail because the
  -- buyer did not fill one in first.
  claimed_by    public.base58_address,
  claimed_at    timestamptz,
  -- How the position left the pool.
  --
  --   'genesis'  — one of the 512 pre-hired workers the simulated collection
  --                ships with (HIRED_COUNT in src/lib/collection.ts). Reserved at
  --                seed time so a real mint can never be dealt a serial the app
  --                is already rendering as somebody else's.
  --   'reserved' — held by a live mint reservation; not burned for yet.
  --   'minted'   — burned for, verified on chain, assigned.
  claim_kind    text check (claim_kind in ('genesis', 'reserved', 'minted')),
  constraint reveal_order_claim_is_complete check (
    (claimed_by is null and claimed_at is null and claim_kind is null)
    or (claimed_at is not null and claim_kind is not null)
  )
);

-- The dealer's predicate, and the only index it needs: the lowest unclaimed
-- position. Partial, so the scan is over the remaining pool rather than the whole
-- permutation — and it shrinks as the collection sells out.
create index reveal_order_pool_idx on public.reveal_order (draw_position) where claimed_at is null;
create index reveal_order_claimed_by_idx on public.reveal_order (claimed_by) where claimed_by is not null;

comment on table public.reveal_order is
  'The seeded mint permutation from src/lib/collection.ts, written down rather than recomputed. Position N is the serial the Nth mint receives; positions 0..511 are reserved for the genesis crew the app already renders.';

-- ---------------------------------------------------------------------------
-- Agreement check — the literals against the registries
-- ---------------------------------------------------------------------------

-- Recomputes the four serial bands from public.tiers exactly the way
-- src/lib/tiers.ts does (rarest-first, round(supply x maxSupply) each, the last
-- band absorbing the remainder) and raises if tier_for_id disagrees with any of
-- them. Then does the same for the skill counts and the trait vocabulary sizes.
--
-- This is what keeps the duplication honest.
do $$
declare
  v_max    integer := public.max_supply();
  v_start  integer := 0;
  v_end    integer;
  v_tier   text;
  v_order  text[] := array['xrated', 'expert', 'mid', 'entry'];
  v_supply numeric;
  v_total  numeric;
  v_rec    record;
  i        integer;
begin
  select sum(supply) into v_total from public.tiers;
  if v_total <> 1 then
    raise exception 'tier supply shares sum to %, not 1', v_total;
  end if;

  for i in 1 .. array_length(v_order, 1) loop
    v_tier := v_order[i];
    select supply into v_supply from public.tiers where id = v_tier;
    if v_supply is null then
      raise exception 'tier % is missing from public.tiers', v_tier;
    end if;
    -- The final band takes whatever the rounding left over, which is why a share
    -- table that rounds down cannot leave a gap of unassigned serials.
    v_end := case
               when i = array_length(v_order, 1) then v_max
               else v_start + round(v_supply * v_max)::integer
             end;

    if public.tier_for_id(v_start) <> v_tier then
      raise exception 'tier_for_id(%) is %, expected % — the literals in tier_for_id() no longer match public.tiers',
        v_start, public.tier_for_id(v_start), v_tier;
    end if;
    if public.tier_for_id(v_end - 1) <> v_tier then
      raise exception 'tier_for_id(%) is %, expected % — a band end has drifted',
        v_end - 1, public.tier_for_id(v_end - 1), v_tier;
    end if;
    if v_end < v_max and public.tier_for_id(v_end) = v_tier then
      raise exception 'tier % does not end at %, so its band is wider than public.tiers says', v_tier, v_end;
    end if;

    v_start := v_end;
  end loop;

  if v_start <> v_max then
    raise exception 'the tier bands cover % serials, not %', v_start, v_max;
  end if;

  for v_rec in select id, skills from public.tiers loop
    if public.skills_for_tier(v_rec.id) <> v_rec.skills then
      raise exception 'skills_for_tier(%) is %, but public.tiers says %',
        v_rec.id, public.skills_for_tier(v_rec.id), v_rec.skills;
    end if;
  end loop;

  -- The trait bounds in xployees_traits_in_vocabulary, against the vocabulary
  -- itself. The check cannot ask the table, so this asks on its behalf.
  for v_rec in
    select slot, max(idx) as top, count(*) as n from public.trait_values group by slot
  loop
    if v_rec.top <> v_rec.n - 1 then
      raise exception 'trait vocabulary % has gaps: % entries but a top index of %',
        v_rec.slot, v_rec.n, v_rec.top;
    end if;
    if (v_rec.slot = 'uniform'   and v_rec.top <> 7)
    or (v_rec.slot = 'head'      and v_rec.top <> 9)
    or (v_rec.slot = 'face'      and v_rec.top <> 7)
    or (v_rec.slot = 'accessory' and v_rec.top <> 9) then
      raise exception 'trait vocabulary % now tops out at %, which xployees_traits_in_vocabulary does not allow for',
        v_rec.slot, v_rec.top;
    end if;
  end loop;
end;
$$;


-- =========================================================================
-- SECTION 7 of 16 — 20260806090200_seed_reveal_order.sql
-- =========================================================================

-- xNFTs index — seed: the reveal permutation.
--
-- 5,000 integers, emitted from `mintOrder()` in src/lib/collection.ts by
-- importing that module rather than re-implementing it. The generator asserts
-- the array is a permutation (5,000 distinct values covering 0..4999) before it
-- writes anything, and the UNIQUE constraints on both columns say the same thing
-- again on the way in — so a corrupted paste fails the push instead of producing
-- a collection with a duplicate serial and a missing one.
--
-- Position N is the serial the Nth mint receives. Read the header of
-- public.reveal_order in 20260806090100 for why this is a table and not an
-- algorithm; the short version is that reproducing mulberry32 and Math.imul in
-- plpgsql risks a one-bit disagreement that reorders the entire tail of the
-- collection, and 5,000 integers are cheap.
--
-- `with ordinality` gives the position, so the array's own order IS the
-- permutation and there is no second column of indices to get out of step with
-- it.

insert into public.reveal_order (draw_position, serial)
select (ord - 1)::integer, s
  from unnest(array[
  2867,995,3679,3355,1885,62,2967,2234,3928,2227,2638,2007,3020,4745,4511,284,2823,3480,731,4109,1852,3354,3591,3138,295,
  2087,3863,1291,2833,4661,4747,1289,2012,4749,1261,1706,42,3067,3454,1200,4358,786,2090,4574,3786,3259,4780,1532,1499,1080,
  3838,96,394,1949,2939,4354,465,768,3635,1708,4862,4682,1722,2696,4101,3388,865,3633,514,2253,3770,2887,2744,1726,2043,
  2480,3872,4479,1487,1920,4179,1463,917,4545,1030,2400,1893,4083,3865,3736,1023,4691,2778,2850,3948,3761,3683,643,2868,1140,
  666,2275,1321,4047,2088,3380,368,1743,3757,3448,2106,2456,2640,653,1007,4158,2862,4931,3690,4010,3439,3364,858,3726,2252,
  94,1239,4013,3249,2075,2658,3397,4763,1152,3654,1778,3419,1527,3076,1897,4985,2548,4795,513,1096,4710,4078,3913,3567,2764,
  1149,891,2157,4385,3762,4828,3064,3389,2962,4919,773,3970,1390,136,2146,589,20,1366,1456,4935,1924,977,2829,3992,4304,
  4585,2237,3109,2149,4265,404,370,3184,353,1740,4281,866,1601,2131,610,2942,3695,4088,4218,2241,1960,854,2595,2291,4641,
  4380,4653,3142,3116,3233,3904,4517,1912,3847,4126,4328,881,595,1571,143,3332,497,799,1936,3339,1725,285,2542,2240,974,
  3278,2360,217,679,611,2614,1394,4760,1184,524,939,713,3175,1718,904,2656,636,1761,3818,1577,1959,632,628,3261,4372,
  2793,2878,1519,3572,1579,4554,3275,2532,1408,1106,744,4184,549,2960,1338,4754,212,1207,2079,765,4778,4468,892,3830,1449,
  2853,3924,3445,204,2639,565,3075,385,1820,1921,2821,823,2645,4247,165,3921,4879,2129,4866,775,4835,3553,33,2794,139,
  2197,1557,333,2104,4986,4934,1342,391,1201,4961,2842,1308,2403,2098,4945,3519,3433,303,686,2906,4837,1737,2647,4053,847,
  444,4399,339,2303,1894,4300,2500,2807,3151,3748,3973,4721,13,1790,2523,696,4455,2766,2564,409,3963,4325,1334,3800,3930,
  4312,2699,1087,2140,98,2433,1551,2785,2674,2167,929,1935,1169,3585,484,4811,3009,1374,242,2196,3958,3208,1682,591,616,
  1968,4301,4995,2034,1301,11,2179,3923,4686,3927,3399,3590,3335,1204,758,4408,3616,2298,3583,3326,4887,3979,2551,2831,2282,
  4522,4694,2671,4582,2943,2951,2774,4669,3295,308,2335,2980,2284,1578,958,356,2812,4191,171,327,2933,2835,721,4249,4241,
  1979,1073,138,4025,4255,3526,2382,3925,3435,4982,355,2032,3856,244,1359,2802,3946,4908,987,4192,4483,2827,687,1069,4212,
  625,4673,2863,4968,1536,1947,4524,155,1696,4165,3057,3005,2662,3827,1206,2578,3318,4575,4645,1782,3943,2627,4261,4821,3779,
  3371,14,3365,274,2391,2682,766,728,4206,4978,3242,2840,920,39,330,2908,2102,2441,2173,792,4061,3832,2045,3932,4043,
  1513,4626,1538,100,386,4932,2505,1019,2820,334,2570,2434,4228,2278,2607,3555,1066,4417,1866,4272,1495,4503,4598,1906,3520,
  2132,2594,3791,3637,2113,2748,401,539,2224,1771,2700,988,1310,1860,3714,3413,2830,3798,1195,1407,576,1313,2109,2413,1803,
  4467,1709,2534,1090,893,66,2777,4298,533,1941,3908,1434,2923,1061,4055,1752,3486,4668,411,2054,4727,2928,1110,1633,2396,
  2508,2443,3039,3629,53,638,4026,2048,1150,1045,4403,3190,4642,1147,1424,3557,1420,535,889,2148,4113,4383,3322,117,4371,
  3053,4147,1689,1840,1498,4260,2022,4623,2094,4637,1246,1617,3463,935,3046,4069,630,4054,3707,3843,1775,570,1887,4058,3972,
  1667,1545,3013,4746,4167,88,3483,1844,3632,4321,1172,256,657,1282,2852,4915,152,3506,1309,4892,352,2421,619,3816,3864,
  3700,2229,129,3501,1012,3532,4906,4074,344,1124,447,2527,3290,351,3775,946,3742,637,4510,9,594,3951,206,3837,2465,
  4812,1040,3347,1114,528,3368,1400,715,169,2552,3782,218,237,3644,4313,2497,1025,2608,1962,3625,4959,2475,2949,343,2212,
  4347,2618,4127,1376,2697,1791,3111,4848,2921,3540,2521,2504,1000,320,1878,573,1216,843,4210,2295,2803,3539,4115,2701,4112,
  2116,1095,1511,4124,1135,2899,1161,3001,3012,472,2801,4594,4903,2384,2519,406,4131,1143,1967,3065,210,4632,3850,78,859,
  1481,4954,2885,2130,2577,3223,4289,2490,3166,2328,2588,756,3327,3202,1637,2107,4451,142,1666,4788,1344,1816,4994,263,2242,
  1494,2772,255,1060,1653,4909,2389,736,4640,1658,2572,1889,4296,1681,2359,1444,405,1657,2788,2136,1363,4659,4366,1229,4758,
  848,3123,3447,2895,4647,4235,1102,742,4984,2567,2886,4029,4405,3933,3934,376,4767,2263,4031,1084,1515,1928,4197,580,2592,
  3573,3961,1355,1817,4392,476,4860,3102,3860,1704,64,387,3734,4369,4532,1892,1855,3140,4009,3867,3831,302,2182,3385,2363,
  4699,3659,3192,1880,4534,1505,429,1367,2694,4307,4316,3663,1856,1462,3425,2259,1212,4825,4220,4576,1256,205,813,1685,1692,
  2289,4356,151,2670,4168,1133,468,3697,4988,4420,3408,4556,3493,2181,3758,4930,2448,1178,3430,3510,2950,2940,2026,1914,1341,
  634,1678,4597,1274,4708,2120,1831,898,3126,1891,4989,1627,3721,77,3427,4442,3101,1179,1118,1839,331,3799,2068,1543,938,
  790,131,2537,1956,903,2269,550,649,38,4462,2540,2882,128,3092,4458,2175,1329,4523,2630,1611,4619,2038,3614,586,1931,
  1727,4861,916,1249,884,2715,1101,86,2414,937,2728,3003,4856,1406,2287,3145,3279,3915,3066,583,771,2892,1729,4555,378,
  4062,2574,4902,1850,4119,3069,3780,4333,3377,178,855,3216,2796,3317,1865,1975,1323,3974,252,4041,1189,4608,4355,1690,3615,
  1351,4279,346,4840,1188,1701,2859,554,3207,4278,2468,300,51,1156,1170,23,2677,3094,1480,4552,2124,2013,2072,4453,1930,
  3378,690,4898,197,1108,4291,2556,2217,3285,2993,1716,830,1217,1766,2604,416,4024,3598,1606,706,915,328,2857,329,1540,
  2704,2511,2056,3250,3549,1472,2447,3844,4251,4737,704,270,1268,2973,46,2492,4666,4764,802,2029,512,2501,552,4525,2780,
  3139,2582,3874,1764,3119,4874,1447,223,1227,1174,4306,2945,1235,3891,3296,4099,3429,3907,4239,2376,2913,1970,3387,2568,2188,
  240,1474,2554,4490,389,4715,4365,964,4777,3137,2916,1038,763,3455,3403,644,3514,209,1741,3118,3580,4918,1742,2516,2332,
  4006,3587,857,4459,2969,1315,3922,4536,4911,2684,2897,4578,2493,293,500,4064,1437,4394,3402,750,260,4697,3715,2920,947,
  4416,45,1876,887,1322,962,381,2732,587,1067,1845,74,4196,540,3319,1673,560,2845,3343,2439,2880,2731,2784,313,897,
  2620,4868,2550,159,1429,3031,1910,3910,720,4030,592,3247,2039,703,1428,4546,1489,234,3643,3407,4493,4180,1542,4662,3221,
  642,801,1398,1899,992,2369,759,1616,633,2076,1822,748,2015,4052,1439,942,3023,4443,3665,3497,4646,4363,2342,2996,390,
  553,498,4033,1861,4225,1242,2657,469,3357,4966,4624,1559,4469,4695,208,3929,623,4967,4413,2265,4570,4938,3998,3575,784,
  4700,1136,1020,2254,373,1809,4964,3562,2267,1085,3159,3826,3548,4854,3310,1126,4491,1501,4160,4295,109,2093,2915,1097,1937,
  4070,2069,103,1563,3080,4564,3569,2848,2386,1086,3269,107,3905,4081,1175,2779,4449,4609,140,68,1304,3746,3303,2612,466,
  1954,1913,3032,4035,118,3016,4488,3822,833,1324,1388,2579,3618,4346,1255,1517,990,641,2817,3912,4649,3375,4877,4622,1343,
  4744,4497,4563,4341,2260,4456,911,1631,2978,4875,3971,1467,2990,3244,3150,4034,3558,4177,2040,3024,3710,1360,1652,791,1039,
  3821,4759,2713,4779,35,1821,2649,1460,1872,2661,2544,84,4947,2202,3513,678,4794,3346,1100,1530,2602,4504,2271,919,2423,
  2581,3273,2563,2300,3976,2172,1573,3957,2078,2137,2771,4174,597,3619,3423,3210,931,2484,2881,797,4273,2112,1450,1115,2683,
  1556,2983,798,607,1795,910,2272,362,3866,2710,116,70,3047,91,1702,2469,4922,639,2219,1093,2743,2648,3054,4032,710,
  3234,1058,3485,2781,3254,1804,2455,4476,1623,4607,3087,4880,1358,4484,4269,3545,1939,3205,276,3265,1896,781,3738,1679,4948,
  4630,3926,1332,3551,1926,546,3965,462,1319,2225,3839,2573,2283,3705,3082,1346,101,4664,2518,2751,3011,712,2695,1292,4752,
  2610,1233,433,2646,3792,2238,3052,105,4681,1504,296,2061,1068,3949,3699,3737,1071,3823,451,588,3550,1991,3470,3220,4236,
  4478,2666,261,3337,4884,3804,677,730,3747,4438,3302,1772,4373,602,825,1471,1808,3584,1213,4440,3103,918,4176,1438,4338,
  3362,3058,2122,3624,4193,2769,461,828,4305,1916,3681,3940,3647,2580,446,1598,195,1361,1794,4502,2512,702,1654,3114,3360,
  4120,3163,2385,1592,3982,1074,1245,1253,3462,1423,3386,837,3732,1226,1320,909,1976,1760,371,2228,104,4155,4173,4084,3263,
  1303,1445,4216,2168,928,29,923,3170,4473,3878,2767,2408,2164,2806,3675,4913,3997,2798,3091,1600,4509,3300,2636,4549,2060,
  3115,2723,2349,3676,1730,745,3168,200,871,3084,1796,4940,4521,976,1888,1982,2317,2042,3206,1607,464,507,1340,761,4224,
  2752,358,4974,216,3178,474,1223,436,1680,3050,3776,966,1028,1518,2528,4330,2316,2008,2603,4926,1881,115,4693,1218,4214,
  2768,412,19,4164,182,4161,6,3323,1720,4839,2904,3457,1383,1724,435,2030,3460,2709,253,3345,2547,3631,1159,4529,1042,
  3518,2941,808,1267,3487,3298,57,4234,1943,2931,4714,4233,1589,4896,361,3522,4436,4706,3955,4774,324,418,4990,2402,2477,
  1254,1269,367,1251,662,3245,311,3063,422,1197,3871,621,3993,1770,1570,1788,4144,2223,2875,521,2995,2036,3989,1247,805,
  4310,2049,3565,221,3097,309,2355,654,2405,317,1265,4208,3081,984,3914,600,590,3154,3808,941,2127,230,2018,110,1425,
  4487,2086,473,1547,426,4089,2688,1826,4259,1915,83,4876,4629,4533,965,819,2412,2025,1544,4139,4118,4183,181,67,4981,
  4602,119,1508,2891,4199,4826,3038,428,851,2825,4672,4939,1711,184,1099,2399,1669,1777,615,157,2250,1228,1122,3636,4537,
  1879,2621,3986,4929,2816,1054,2633,1399,4324,2471,3868,3475,3059,225,2183,2458,3028,59,1475,434,2782,4253,983,1024,1370,
  569,445,3767,227,1403,3253,495,3756,4039,4655,336,948,3117,4135,1784,4742,1151,236,711,2635,3589,4257,839,2871,1659,
  4804,2770,2352,1948,457,3509,2397,3552,2698,2251,3789,783,232,3390,4553,4063,2153,4143,1739,2925,1903,4786,2873,3274,146,
  2294,4698,174,1405,4162,2293,2775,280,729,12,2216,4822,4711,3157,732,2001,279,806,393,392,2838,430,1279,1415,2398,
  2541,2138,1111,2231,779,1858,3441,382,955,4753,1811,3096,1762,4282,3293,631,1148,4379,3749,2617,541,4973,3366,1744,1029,
  407,2745,3095,112,1296,1302,3578,3919,4871,4958,769,1923,3243,963,1785,2037,1157,2459,2981,3711,4482,3305,192,442,3783,
  617,804,2663,1224,902,921,2759,1927,4410,2027,723,4097,4270,1119,3944,2776,3019,2145,2192,2786,2665,122,2596,531,4186,
  3793,1905,4813,3657,1528,388,50,2587,4751,2893,534,1103,3098,3104,4188,1818,4688,2162,4423,2495,4258,2442,2134,4890,4859,
  3903,2599,3622,3367,1945,1629,1883,901,3314,518,885,2255,1940,1656,4492,4017,665,2052,30,1435,1886,4651,1220,2974,4059,
  487,4005,4571,3382,275,4472,4565,2988,1953,3745,4987,2641,4470,2285,3876,1094,1983,2524,398,207,4049,4766,4590,2530,2953,
  4407,2800,1636,4515,2947,1003,3739,3778,4674,2605,1531,659,2308,2387,1922,4137,4508,989,2909,1824,1548,496,2264,289,1510,
  1325,1838,4357,3741,3465,1072,895,4042,158,4550,2851,2333,1586,1830,3213,2476,3536,3502,3133,4071,4773,281,1908,2883,1205,
  1076,2426,1792,3781,374,738,1288,1055,4463,658,4136,3229,449,2739,3093,4211,2717,1999,2171,1036,2084,4245,4466,620,2716,
  4559,4541,1364,1171,1237,211,3309,432,3743,2353,1591,2151,306,2314,3642,2067,3179,1841,1250,1104,1401,310,47,2020,861,
  626,957,4275,3656,3384,3588,2195,2357,3172,4040,2393,3593,536,1507,4044,1416,2180,3048,1566,2924,4448,4397,163,3456,927,
  3149,3678,1121,3311,3152,751,511,179,1827,4709,2365,4927,3272,3196,2009,4501,3751,1286,2824,3846,3477,2625,2935,3187,1065,
  1984,733,257,4421,3410,4586,2858,4067,3621,301,2877,235,1981,4048,185,4435,4292,4248,1287,2600,1139,337,463,1312,2982,
  3568,4905,359,61,3609,3029,2028,3512,3523,2984,3268,1950,76,1604,3626,675,1524,2395,1605,1958,1165,2422,4707,4581,4077,
  2693,267,3887,3546,1486,4671,3620,4471,4538,3180,1018,3194,3759,3962,4889,1225,1380,1596,490,198,4370,2288,3601,156,2096,
  4382,194,4771,2650,259,1041,3947,3854,4110,3613,3336,3203,1348,4104,3467,530,2676,2814,1112,4480,4827,2790,572,3165,2115,
  3810,1314,2121,3049,3693,2813,1098,278,2611,818,1500,1836,3495,1163,1580,2956,1263,3577,838,3673,486,840,2273,4886,4023,
  4200,660,2756,3995,4091,517,2808,2496,4457,2900,934,2290,3396,603,1047,3938,2966,971,2797,1774,1240,3010,3484,3464,199,
  4820,3017,1874,3197,3765,467,2905,3694,4720,1944,3131,1549,3833,3262,4340,2337,1046,1198,692,688,3491,3596,3879,700,44,
  4337,3937,3666,186,2932,2214,542,3999,137,4309,4675,4190,2158,2218,2721,2178,2436,3977,1384,878,3936,1823,1582,2425,2865,
  834,3950,1466,4350,4319,3400,3481,265,782,2815,3820,2345,2712,3421,719,402,3340,2460,1413,1210,2977,1294,1464,1166,1622,
  538,809,1418,2911,4227,3411,2543,2374,4857,1512,3723,3292,299,1300,1588,2560,3182,2147,3909,4591,2725,3344,1142,2044,3321,
  4066,4432,1259,2765,4815,1451,1634,366,3112,1365,2517,1273,4374,4452,4213,3773,2464,3817,326,354,4713,1336,2281,2023,3444,
  2957,2644,4949,4736,187,483,880,424,1243,862,2741,3164,3945,1769,3787,3579,3181,318,2100,43,1805,4528,4618,3489,749,
  2890,1555,4003,2313,680,757,3600,3006,4085,2876,739,170,400,1902,172,134,245,912,3035,3160,213,4171,4500,2742,1560,
  4016,1353,2033,4263,2410,1521,3825,1412,4486,1847,831,1942,4712,544,425,1539,1417,646,364,3155,4400,3815,345,4169,4539,
  4412,4852,2937,3592,2205,2724,1120,2660,4201,3458,3453,3251,219,2160,427,2864,4431,3090,1583,1688,4079,842,4001,1613,3667,
  2339,2262,2679,725,3393,4566,1260,943,1008,4507,1107,4096,3237,108,3222,102,1773,1426,384,3033,2446,4073,2989,4684,431,
  2377,973,1404,3301,164,1248,3022,454,1763,3658,264,4050,150,4125,3239,1037,2846,1686,2626,3521,1835,1432,2761,4398,1130,
  624,752,2194,479,2473,491,3703,1810,577,3079,2559,558,2144,2186,65,3893,4334,1283,698,1146,2161,1478,2609,656,4481,
  1986,4516,1327,608,437,4207,3828,959,1154,3730,3645,1793,1393,1977,1665,1833,3287,3288,1966,2450,3836,1875,229,369,4846,
  2914,4912,1350,4557,2114,2571,2420,4027,4485,1043,3858,3391,1105,2539,3405,814,365,4004,2367,4792,2347,562,741,3034,2919,
  4998,4268,2118,4606,423,2740,4803,1684,2757,1647,1668,1326,4805,4631,3490,1602,1193,2073,4944,2411,4384,4750,4785,2383,3729,
  2474,1650,1199,1190,4498,3161,3696,4680,1963,3840,1433,24,4280,4639,3597,1961,3917,82,2561,1934,2729,1558,4368,1587,3517,
  1297,760,4569,581,1735,4391,2126,2215,0,1492,1316,1712,48,3709,2791,4798,561,395,1262,952,2826,575,123,3051,4865,
  3446,1331,325,2828,375,4322,1052,2004,1021,4237,1091,503,776,4583,2930,3381,3204,3886,4108,2531,1955,4775,3266,4219,4428,
  3978,2702,1909,1079,2750,4215,4732,1525,3563,3363,4845,609,1252,1176,3595,4739,4226,2714,4114,4800,149,2279,291,2193,2912,
  2586,3901,2958,4446,4303,3969,2330,2870,1717,1700,1306,49,3845,3991,3628,4810,1396,1382,2047,1799,2207,1568,3352,2437,4505,
  4194,3750,868,3414,1177,2232,4008,4910,4351,2999,4772,2869,1632,2358,3018,3801,3499,3524,2276,1738,4014,3328,1695,4007,2021,
  3994,1339,3533,1957,3807,2453,3135,4658,2211,3148,4020,2643,4427,2804,410,1884,241,3147,4283,1335,3044,949,4297,3990,4477,
  3953,4611,3570,2361,3469,2266,2672,780,3169,2854,2055,2301,2506,4621,4335,1006,4696,3672,2502,4878,815,4904,3349,785,701,
  69,1155,4604,4807,4991,3409,2624,4011,2522,1295,3312,682,1514,1779,415,3113,3985,4437,414,421,1802,3956,3861,3713,3144,
  4832,4593,4244,4286,226,2119,2133,1221,3733,4036,4977,2535,1988,2726,1731,1275,1825,154,1733,2246,3329,2304,1890,3602,582,
  3725,856,399,3813,523,2338,1798,3594,1552,377,2844,2123,135,1356,3894,2066,4360,1677,3638,3648,4267,1996,3494,584,1491,
  1746,3008,1776,2306,2629,1391,4558,3980,4921,1027,747,1026,4937,58,664,1971,1670,75,2381,4326,2141,2006,4060,4562,4776,
  3062,268,1409,3870,2926,1572,21,3071,321,3731,3795,3299,2669,89,4738,4352,3468,4844,2934,1787,4381,960,3686,1477,3627,
  3706,3547,3968,1710,4599,1290,7,3056,1352,1005,1882,3002,448,63,2050,1369,1965,4547,4277,1974,4610,2792,2059,3224,4761,
  699,3442,827,4076,972,1533,2366,4271,4870,4979,2481,307,2085,1064,4755,3862,4941,816,111,1584,4628,3916,1503,4022,160,
  1759,168,1672,1264,1691,1453,2092,3835,3100,4829,4246,1127,1299,3106,1145,99,2329,3060,1595,3449,2051,991,4580,408,4789,
  1454,505,3406,2565,2653,4018,1258,905,1034,2392,850,470,1164,722,4327,292,1626,1832,2760,4359,4445,2449,3906,1980,2922,
  305,1349,1645,1758,173,2907,4799,4678,233,864,3684,247,2818,2685,3392,1187,672,1022,2249,4308,3692,4390,1208,2689,4841,
  835,3841,1728,5,4229,795,4513,4377,821,3255,693,1675,4129,3308,4317,567,2491,4068,1232,1757,2139,2226,2557,4584,2105,
  2155,1978,1546,2503,1593,477,2498,3852,25,4153,926,1446,1377,4121,3880,4917,817,2191,1476,4376,3996,4093,3772,3353,4149,
  2975,717,2487,2902,4730,3724,2998,566,2190,1078,2681,243,1465,4198,4348,980,1333,3885,4345,458,357,2708,166,1051,3498,
  724,1676,2569,4724,2970,4441,925,509,2430,956,2170,2354,4676,4299,4891,1311,1083,3043,3141,3307,4900,1001,2758,1553,2994,
  2077,1898,2292,41,1748,4323,3503,2746,4087,4740,3849,3241,3228,2755,2315,1853,3952,2668,555,2451,3689,863,985,2081,2478,
  1871,4,1455,4770,3975,4425,593,2318,3306,4660,1257,2954,420,4843,4294,1032,2280,2111,1347,1635,2927,3877,3230,2711,36,
  2616,3078,1655,3869,147,190,251,231,3124,3911,3677,4256,493,1564,2057,1597,3452,3376,3538,2483,2856,683,1389,4123,452,
  2467,2718,2368,1951,4254,1646,4151,1998,930,2642,1625,869,3361,4768,4850,1609,2174,3857,3286,4028,3931,2322,3599,2108,545,
  4600,4015,2407,2089,3226,314,4332,1436,4757,3508,3398,812,3819,846,788,3338,4489,1372,882,2839,691,4166,1644,2836,4320,
  811,822,1800,1044,2965,4819,3025,2489,3248,3797,998,2730,4414,349,4963,3511,3897,2553,1619,705,1230,1033,3055,4842,3688,
  668,970,4461,1459,3036,4170,3225,2488,2606,3201,1082,3531,249,4178,740,2239,4824,3238,3418,1470,1715,2003,3698,273,4956,
  3630,2619,4329,347,2311,2667,2615,3720,246,3231,4701,2417,3270,537,1603,4223,1972,2809,1128,2334,3320,3802,2341,1215,3183,
  1088,3716,4928,4833,2258,4625,71,3651,506,3842,689,3331,2163,175,106,1131,2749,203,4046,2466,2203,2533,2277,1035,4389,
  4159,4415,2583,807,4615,3653,1599,2703,3026,3634,113,2901,4784,4756,4266,1565,455,1410,2356,4648,1016,1017,191,332,4430,
  269,443,3369,363,2961,4100,3440,4264,4560,1357,655,3330,4098,2805,601,652,2346,3796,3873,4037,3535,4117,290,3235,950,
  1141,120,3443,1783,3541,1917,2427,4429,2206,1703,4499,4217,1488,3136,37,2601,548,482,3655,4933,3529,1442,2546,3289,3717,
  1859,34,718,183,4692,4134,510,1048,2762,2526,3185,695,800,1612,2156,3132,80,52,1864,883,2401,3649,2687,4962,2208,
  3158,3162,4082,2404,832,1381,1493,323,2654,4717,604,585,4797,4716,770,3959,1502,3004,132,3605,4387,1125,1276,4885,97,
  2002,3374,4051,478,304,4663,1278,2201,2011,3120,3900,3394,3537,2822,2509,1663,743,3461,3007,2622,450,1834,3771,3685,4353,
  3722,3334,2589,4650,2244,2388,707,3611,286,1828,4955,1452,277,2963,4075,2510,3478,2706,1202,3515,2071,872,606,4231,2220,
  2558,1392,4276,28,2176,1244,2860,4999,3466,1620,1812,3085,2515,870,2753,522,673,1057,1117,2462,4957,622,4302,60,1694,
  1337,651,2879,1641,1160,2652,262,4702,4831,764,3188,453,1485,1648,3128,2390,4587,1624,4634,936,4568,3662,4163,913,4209,
  3246,1732,986,2976,774,4601,3014,3037,4475,4318,3105,648,3350,836,254,3370,2470,2010,1473,1846,1183,2773,2364,3372,4652,
  3492,2613,1059,2985,4677,4146,1753,4288,95,3073,3500,2321,1933,1053,1509,4728,2747,248,4496,3889,3276,3359,1581,4548,239,
  1554,2189,4439,1328,2380,3988,1457,1014,3766,4242,2406,3177,2894,1749,563,596,3432,1660,3527,297,2340,3682,4567,419,2884,
  3612,2787,2705,1705,1049,250,3641,1516,1191,2166,2917,994,193,874,954,676,1004,3496,1621,4855,2598,2327,2305,4636,2005,
  2566,4722,2016,4816,1222,2097,3040,1789,1375,2754,2929,298,2738,3417,2457,4152,1192,4406,3215,726,2419,2235,697,1964,1271,
  4689,3728,54,3341,3755,4796,3803,1576,4851,3072,3174,3416,4464,574,4424,1387,1745,1719,2248,8,1168,2143,3805,4725,3129,
  3171,3404,1153,153,471,4474,4849,4401,1862,532,2486,3704,1469,2472,4705,2185,3650,4386,177,4361,4572,456,888,2415,2394,
  4616,3794,124,475,1614,121,1786,4086,4996,2479,4019,2,4592,2371,4375,1285,3566,3324,519,4965,4142,3691,1590,3027,141,
  2302,3219,3727,1751,2000,338,3824,3576,1,4535,3121,2326,2236,824,3424,3083,3564,3373,3507,1837,3186,1806,3218,4830,849,
  4762,4393,4942,2628,1281,1843,4808,3212,526,4238,1137,2142,3153,4202,2763,4972,4992,1768,867,3560,4914,3674,4617,3045,4970,
  978,968,162,746,2590,3479,1378,727,1618,1713,3883,2210,1490,4741,4494,2431,1797,1031,1869,3280,3881,2031,4719,4858,3472,
  1674,266,4444,220,4950,4205,3608,1241,975,2631,3488,4284,360,4221,4141,161,1755,2987,397,999,4793,4818,4290,3428,787,
  4596,4787,2351,1167,1015,4343,1421,3516,3021,3333,4897,4960,4869,508,2494,2525,4627,1483,4704,1734,4731,1608,981,3325,2837,
  1523,2735,1989,18,1194,3199,4426,4450,1813,4743,1918,4526,4936,4232,1569,2299,1929,967,4454,2896,4182,4573,2632,671,1640,
  4133,3918,1985,4883,670,4388,4222,669,3848,2046,4783,3561,4765,176,2538,4729,3981,932,3426,2200,3431,2918,2585,2707,2058,
  1994,79,640,3294,271,4633,85,4588,578,3284,2323,2720,3753,708,4465,2968,4512,3086,886,1630,460,1997,1158,3525,1639,
  2221,3252,3015,4916,2514,4154,287,2320,26,4195,92,1116,3277,2184,4274,1526,3191,1754,1973,4531,599,4823,4847,844,4806,
  4519,4090,1123,1615,875,1395,551,3217,906,1585,126,1868,767,4687,1011,4132,4920,4834,3543,754,2177,3646,2936,2312,826,
  1907,2811,4520,4863,1440,4975,1736,1173,322,2070,481,2520,4128,348,709,2719,1693,613,4888,492,3581,2872,735,3316,2296,
  3395,969,1284,2986,3752,2461,1075,4951,1209,4409,4953,440,661,4791,4817,879,4901,17,258,907,438,4733,890,4344,1009,
  3661,1990,3504,4116,2344,1987,3718,2575,877,4311,2445,4893,2247,2199,3176,189,4544,4530,3379,900,1402,2243,2325,1379,1938,
  1113,3358,1419,945,2379,2019,31,3471,3764,3348,3806,2692,4561,294,3260,499,4654,224,3960,4971,1109,3884,2198,2209,1756,
  543,238,1801,1661,778,4952,3030,520,3888,1236,1362,2997,1534,3571,4801,3193,564,3146,2482,4867,1461,228,4252,2536,4748,
  755,3898,4364,282,4250,3664,40,2152,1013,188,2309,1628,4094,4667,4204,1901,3719,485,1995,3582,439,2637,2866,1575,1448,
  1077,527,3769,1925,2438,3450,924,4685,2310,1870,2849,2343,627,685,3236,3505,3209,2452,1185,90,4551,4240,3134,2861,283,
  1386,4579,196,3829,4769,3668,3671,3412,3070,3110,4402,1904,4331,4419,1318,488,3351,2014,2463,4836,4614,2370,3811,3342,2035,
  2348,2946,3200,1698,579,876,3198,73,2734,2362,1814,810,4102,3954,714,1993,953,1854,3617,2964,3623,1750,3896,4899,3640,
  1430,914,3281,1307,2733,3652,72,504,4644,3712,3966,1932,922,1214,2659,2135,1180,1482,3476,4881,2082,2319,961,3556,1723,
  114,772,993,4339,2576,2795,2065,3000,4690,2074,2686,3257,2261,2099,1638,2324,663,571,2485,4943,2591,2165,4447,3107,3760,
  3383,3214,1070,1520,997,3604,3774,2513,4734,4243,2910,3777,3941,4336,3544,4969,2888,2274,4150,4809,1721,3528,340,133,4045,
  3459,2424,3061,3530,1330,2597,4506,4057,27,3784,4156,1895,3189,396,1683,2664,1842,4781,2898,516,982,319,1305,3882,3077,
  2444,3809,3125,1270,1919,3902,2159,1707,1664,1385,1132,1687,4993,1780,4838,2110,2125,4103,3790,4542,2680,3895,1219,753,979,
  2418,1010,4814,4157,87,2651,3227,1427,3041,2372,2623,1479,3812,896,2727,2634,4718,2972,4287,2545,403,777,794,2117,3920,
  4872,4315,3074,4002,1767,4495,4873,4342,841,3042,130,413,1293,22,3315,1671,2944,4185,762,3282,3984,2499,3068,2903,380,
  3660,4643,1397,547,3356,4656,1535,635,1134,3670,3834,1561,2101,4285,3436,2222,222,3291,793,3258,4543,2655,272,4140,2555,
  489,4460,3422,4367,1089,2053,2350,4145,4924,1443,312,2432,1231,1138,2722,1849,2428,529,4411,1203,56,3680,2331,1567,1468,
  2286,2855,1946,3232,4925,1431,2017,4683,3740,502,1162,1714,2690,933,2691,789,1484,3899,4518,4072,2584,4595,3434,3702,3785,
  3983,1081,3195,4853,316,4314,3297,3437,4679,4262,4148,944,2529,379,1662,125,614,674,1529,940,1497,3173,4187,796,3271,
  2948,4065,4404,4703,1371,3542,3939,315,3701,1900,3859,1186,1819,3708,4589,2213,3687,2783,2150,3851,2737,1277,1266,4122,342,
  3892,853,3639,4107,2440,1649,1496,716,2955,4790,3875,127,372,288,4092,1181,1063,3574,2297,4230,350,4605,2154,1562,694,
  1765,3267,4378,3283,144,1699,3586,4095,803,515,494,1697,4056,1422,2889,4802,2979,4980,4976,3451,605,4189,3603,4514,3438,
  3474,3143,2245,4577,81,684,3987,737,3,2549,501,908,3669,2435,1642,3240,559,2062,4665,556,2230,1345,4434,1911,894,
  3853,3099,215,2268,2063,3942,4000,2336,3088,3534,55,1873,383,93,1458,3156,2375,4657,2799,4021,2257,2810,1211,2832,3167,
  145,4997,4612,180,2673,667,1969,4907,845,647,3256,4895,3768,2429,3473,1867,202,820,3108,4203,214,829,3735,899,2952,
  4418,341,167,3890,2233,1414,1857,734,3127,1643,2128,4422,1182,3211,3607,4181,4983,618,4923,1594,2507,4349,459,2256,2959,
  335,2307,4396,2841,2378,1829,3788,3401,1280,4293,2409,4105,2103,1441,3763,1992,2834,2091,1747,4012,2991,3130,1092,3559,557,
  1574,3420,1144,1610,1863,16,1050,1781,2971,148,3967,4864,4782,1506,4635,1298,1196,2678,1851,2080,1522,480,4726,3606,2847,
  4638,612,2024,4433,2736,1807,4106,2562,1354,4138,860,1272,2416,3482,2819,951,4395,4175,568,1537,4130,3855,2083,4603,4540,
  1877,3089,681,645,4362,4613,3935,4894,650,3264,3122,2095,4620,852,996,3415,2373,1411,4172,441,2187,2874,4723,3610,1541,
  1238,2204,1056,2992,1317,15,2593,2270,3554,1373,3814,4080,2789,2938,3304,10,1234,4735,3964,1062,4882,4946,1848,1952,2675,
  3313,1651,417,2169,2454,3754,201,1550,1002,4670,32,4527,2041,2064,629,1815,525,4038,598,873,3744,1368,4111,1129,2843  ]::integer[]) with ordinality as t(s, ord);

-- The permutation is complete, contiguous and one-to-one, or this push fails.
--
-- The UNIQUE constraints already forbid duplicates. What they cannot say is that
-- nothing is MISSING, and a short permutation would leave serials no mint can
-- ever be dealt — an xployee that exists in the tier bands and can never be
-- owned. `except` is run in both directions because a set that drops one value
-- and repeats another has the right row count and is still wrong.
do $$
declare
  v_rows integer;
  v_max  integer := public.max_supply();
begin
  select count(*) into v_rows from public.reveal_order;
  if v_rows <> v_max then
    raise exception 'reveal_order holds % positions, expected %', v_rows, v_max;
  end if;

  if exists (
    select generate_series(0, v_max - 1) as s
    except
    select serial from public.reveal_order
  ) then
    raise exception 'reveal_order is missing at least one serial';
  end if;

  if exists (
    select serial from public.reveal_order
    except
    select generate_series(0, v_max - 1)
  ) then
    raise exception 'reveal_order holds a serial outside the collection';
  end if;

  if exists (
    select generate_series(0, v_max - 1) as p
    except
    select draw_position from public.reveal_order
  ) then
    raise exception 'reveal_order is missing at least one draw position';
  end if;
end;
$$;
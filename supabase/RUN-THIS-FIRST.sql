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


-- =========================================================================
-- SECTION 8 of 16 — 20260806090300_seed_xployees.sql
-- =========================================================================

-- xNFTs index — seed: all 5,000 xployees.
--
-- Emitted from `buildXployee(id, 0)` in src/lib/xployee.ts by importing that
-- module. Nothing here re-implements the generator: the rows in Postgres and the
-- objects in the browser come out of one piece of code, which is the only
-- arrangement under which "the database agrees with the app" is a fact rather
-- than an intention.
--
-- `hiredAt` is passed as 0 because it is not part of identity — tier, skills,
-- traits, principal and apy are all pure functions of the serial. Hire times are
-- set only for the 512 genesis workers, in 20260806090500, where they belong
-- with the ownership they came from.
--
-- ---------------------------------------------------------------------------
-- WHY ALL 5,000 EXIST BEFORE ANY OF THEM IS OWNED
-- ---------------------------------------------------------------------------
-- A mint does not CREATE an xployee. It assigns one. The whole collection is
-- laid out before the first burn, and minting moves `owner` from null to a
-- wallet — which is what makes a serial's rarity a fact about the collection
-- rather than a property of the transaction that happened to draw it.
--
-- The practical consequence is worth stating: `xployees.owner is null` means
-- unminted, not unknown. Anything counting supply reads that predicate, and
-- nothing needs a separate "minted" flag that could disagree with it.
--
-- ---------------------------------------------------------------------------
-- WHAT IS CHECKED ON THE WAY IN
-- ---------------------------------------------------------------------------
-- Every row passes through `xployees_stamp_identity`, so the seed's own tier and
-- skill count are compared against `tier_for_id` and `skills_for_tier` row by
-- row. A generator that drifted from the SQL — or a hand-edited row — raises on
-- insert naming the serial, rather than loading a collection whose rarity is
-- quietly wrong. The trait indices are bounded by
-- `xployees_traits_in_vocabulary` and the apy is re-derived from the skill rows
-- in 20260806090400.
--
-- Column order below: id, tier, art_seed, uniform, head, face, accessory, apy,
-- background, overlay. `skills` and `principal` are deliberately absent — the
-- trigger fills both from the tier, so the seed cannot state a value that
-- disagrees with the one the schema would compute.

insert into public.xployees (
  id, tier, art_seed, uniform_idx, head_idx, face_idx, accessory_idx, apy, background, overlay
) values
(0,'xrated','7TpwUwuJ9dsa735RcS9gaMchS3D7dbiVqonYH6YAykep',3,8,1,2,0.040388,'Frozen Dune Sunset','none'),
(1,'xrated','9rUNBic13c6A4MJ4YJHMz2p3o9PatZzg3D9n9iugbmVp',6,1,1,5,0.050915,'Dune Sunset','sparks'),
(2,'xrated','3tiDUgyBNheNYhbYrm7hzemSpjY6AxwujWkj9LtmjQDV',2,6,5,4,0.048098,'Orchid Still Water','stars'),
(3,'xrated','NKY5i13DC1zeozuEmN7dCkt6qc3kTwZJ5LSGCCSfjCbh',4,6,5,4,0.065028,'Frozen Infinity Grid','sparks'),
(4,'xrated','dA4zKvnkECpyVexMzX8UMQLYPgitKv2KbnTtL23tAzxa',5,9,2,3,0.039845,'Ember Moonrise Skyline','stars'),
(5,'xrated','a4de9ndud2im4DFVSZd36vfnN3HK4VM6PXhz98fBu8yL',3,7,4,2,0.048765,'Verdant Downtown Grid','thunder'),
(6,'xrated','VtGrRyjhcYpshsVH9hZY6VtgjTh2WBTRwemwRds1BNDm',1,1,6,2,0.048115,'Frozen Dune Sunset','none'),
(7,'xrated','DKqp8QGaGUf48CF2zFUjRpZzDLBzb7bfEtAoM6dvRqJ4',1,0,6,3,0.040468,'Cobalt Moonrise Skyline','rain'),
(8,'xrated','hixZALfqDZW2iomhWPrKmbtxs1UmXXYR4J5hjdxwomVR',0,3,6,8,0.059840,'Orchid Comet Field','stars'),
(9,'xrated','bThLoSpcEaunXrCZAWKw9X4uXzxgU764tvsACQSiRufV',5,5,3,8,0.027810,'Violet Downtown Grid','none'),
(10,'xrated','6WgnHESi3cGPFQYr11ny4xt1wMV7YJ5K2jqnVZhs6LRM',5,7,1,4,0.037308,'Toxic Still Water','none'),
(11,'xrated','HRDBLsRaMXZZ2NeNqy3nLFCUrubD3eWF2ok1wboSbWAz',7,0,2,3,0.061110,'Comet Field','stars'),
(12,'xrated','Dw7NFkKYrzZsda1B4FqkCCzvNapFomjP7nBNPwdKjaxR',7,5,2,3,0.039743,'Verdant Ridgeline','snow'),
(13,'xrated','65VYByDTHgEFME6UAtJrMPYHPzcxTKYQZbKJMptzza7g',1,9,0,8,0.040178,'Verdant Downtown Grid','none'),
(14,'xrated','PB3arsih2oArU9zC2fVdehSW8Fu7UT7LjY35Z7XPtJqt',5,6,4,0,0.056245,'Downtown Grid','thunder'),
(15,'xrated','VaQsBeuTenboxCSUodU57q5BxA2ihj71gWphZzn4Zjne',4,5,0,7,0.044255,'Orchid Ridgeline','snow'),
(16,'xrated','BfMZkijXrBt85jw3KE6oX4Yep4GQ2GWrJHEURuLjRDKT',3,3,6,8,0.036800,'Cobalt Still Water','snow'),
(17,'xrated','rPsZRpduWJv2GjwipV6ku6tkff67ijERzNrcmHJbCBte',5,4,6,2,0.042640,'Verdant Comet Field','sparks'),
(18,'xrated','GxHbeC2dEfmoXUZBYEfYRJHYFfY6trWFa1J5fqNbfKcX',2,2,0,6,0.045212,'Cobalt Still Water','stars'),
(19,'xrated','E4qxsrdRypsu9kLVHkfatq3qfggGfy22874tUm7cYhvn',7,4,3,7,0.048605,'Ember Moonrise Skyline','stars'),
(20,'xrated','LhnRNW8sUSfAUdCoE6eigkfpjModxZvEHi95CQdJsZ8Z',7,6,1,5,0.045707,'Frozen Dune Sunset','none'),
(21,'xrated','G4FHVBiDY9xEjFeWvfq4RNxMTCoXnxdZZAhzzjTrBEQf',5,6,0,6,0.056058,'Frozen Comet Field','stars'),
(22,'xrated','yG8t9ub8ky5D8YhK4wfGHcm1tCCiF5pMNfoRc1Y5FDwK',5,7,3,0,0.054100,'Verdant Comet Field','stars'),
(23,'xrated','jUuogdWD2Zxv6WMFrAT1JZr5fH6Frr9XbbFNWGyn5Ybt',5,4,0,5,0.037340,'Verdant Dune Sunset','sparks'),
(24,'xrated','M2gVCGsSCU9RXhpaW1Rm2d59DfjtEstzA5EELHrNtMx9',7,3,0,4,0.050477,'Ember Infinity Grid','sparks'),
(25,'xrated','GDoA47EkJwr5BGdNybircUPyc4kfMacTkR3YAbPHKc6a',1,7,0,0,0.038997,'Violet Still Water','none'),
(26,'xrated','3wMgteq1dam47M6cyyTsEXLpof4mSK3QyqQyfQe5wpi8',1,4,5,5,0.044850,'Frozen Downtown Grid','thunder'),
(27,'xrated','wJ1tJk1eqSdguNP49ohxTF5gsKgfrkV1BrqSUHzFkEtk',3,7,4,0,0.034880,'Verdant Infinity Grid','thunder'),
(28,'xrated','P1dnLprcAUdKpSbMyv5k632GPFiDmk7phqQmnuN1whYH',0,7,6,5,0.045410,'Violet Comet Field','sparks'),
(29,'xrated','vRCa2PVXWNg3oUfxFEw7B5b73L3zs3sLVHRveh2LETxt',6,5,2,3,0.066248,'Toxic Moonrise Skyline','rain'),
(30,'xrated','8Yv3rKi2xvhoGEr1rFTbhn1ie3oEx8e1iKVb9bGR8Jok',2,9,6,4,0.053047,'Orchid Dune Sunset','sparks'),
(31,'xrated','CQVN68AHZdjaSzPNuG1XgBcEVdXekW7GzujAETsacNBG',7,1,3,4,0.046930,'Cobalt Comet Field','sparks'),
(32,'xrated','ADaGr7mgNxx5vH4ETiuZDhjRBNPxEgJj6LEM9186Wexz',6,6,6,5,0.052500,'Cobalt Infinity Grid','stars'),
(33,'xrated','aZQsaPtM3aR9Gwqecnfz2C8cQgsC7ceoF1t1yGyUsvbc',1,5,4,3,0.054180,'Cobalt Moonrise Skyline','stars'),
(34,'xrated','pDAaAkKYcos9JmbezxquhBoteShvAfpfC7wUGTEFv6A3',0,6,3,5,0.047392,'Toxic Still Water','none'),
(35,'xrated','cccxu6TLYqX8iHMeCSTrJ98gR8bmob3QQjzLDsHhssvc',6,9,5,8,0.066345,'Cobalt Infinity Grid','sparks'),
(36,'xrated','hYVHVWsaafvnr78irYpqBrU2eDLqY2R7P1ESBNMZKKVg',4,4,4,9,0.049320,'Violet Moonrise Skyline','rain'),
(37,'xrated','5aobNooHFXEnb1bDVLVUz3GGqUhhWrFFnErRJgWFGg2i',0,9,4,3,0.045060,'Violet Comet Field','stars'),
(38,'xrated','84jftyXdLNgcev6YKCXhAoU4BiVVmFRFaukn2MvFbM1g',3,1,0,0,0.040395,'Orchid Comet Field','stars'),
(39,'xrated','AKNWh6vH5Rt4KYeKqWUQRN8LRFFxGi9Z2RckN1kNkYNd',1,3,4,4,0.047942,'Moonrise Skyline','rain'),
(40,'xrated','scHsGw4RQwLLt9coYedsc78k9ckkVpvtvRDbTZfeo3d1',5,3,2,4,0.035980,'Ember Still Water','snow'),
(41,'xrated','fsvzEWob2pWGHBMfFCjoJRW1UZRs2FgPXkZ5LYfGLWt8',4,4,6,7,0.047740,'Violet Downtown Grid','thunder'),
(42,'xrated','FS1UGvn7Xbj9HyXkzWACgW6NYMdn1sdJqKr1eMbGTH6J',3,1,6,0,0.033225,'Moonrise Skyline','snow'),
(43,'xrated','saTsV3F2CA9iYq88EGWkaXeiNKRxANViAUEkXQKEicfz',2,1,4,9,0.045885,'Toxic Dune Sunset','sparks'),
(44,'xrated','dmE4C4dCpf8WeBDax5Hr73jBrrNZEteza66YbMptU1DZ',7,1,6,8,0.038845,'Orchid Moonrise Skyline','stars'),
(45,'xrated','DUsVzfXkKN9DVXn9zeBgnjNbGLMupYp73qzHvhQ2KmPe',4,8,2,0,0.076785,'Frozen Ridgeline','rain'),
(46,'xrated','S6zGKam5Ao8fRuHExvL6UNVhSjmSwxYrZd4UrjYEgmxC',2,4,2,0,0.044403,'Ridgeline','rain'),
(47,'xrated','BZ2JRBsCa8F8HUVs1TsjKJDMP9MtdKAYVuNHMALDhVNH',4,1,2,3,0.034885,'Frozen Ridgeline','none'),
(48,'xrated','MTtKBL5HcKao7TDuVesFwRAsFEyxgDNf2FMqn84pku26',0,0,4,0,0.046430,'Cobalt Downtown Grid','none'),
(49,'xrated','2tNWZPZuLGjXSig5WSELJuEaY9RroS34wQXHhAeR9G7L',7,5,1,3,0.051505,'Cobalt Still Water','stars'),
(50,'xrated','FfXPrZXeJCtGPcA4y3MEtzaZK82LdBAhhjK73XA43iJk',5,0,5,3,0.043798,'Verdant Infinity Grid','stars'),
(51,'xrated','aE2cjeHjp9Ax1g1cn2nkVYv9xqV6xhP3reUStYneudUa',0,7,0,2,0.056660,'Violet Ridgeline','rain'),
(52,'xrated','DkwA1cupQAtSAx1fupuQrT1YxVUfmQ9YjBYY61xU9xDR',1,6,1,2,0.044670,'Orchid Comet Field','stars'),
(53,'xrated','GE9DNhfiuna3dhsD3nXNtdTJhW4tPm2t4juTUU8rgvmo',1,6,0,0,0.047390,'Verdant Infinity Grid','thunder'),
(54,'xrated','qYCcHDjexRsh3RcJcQCs3dKtbsBYEN6D1FE5tjfUa5kF',7,5,0,6,0.045025,'Ember Infinity Grid','thunder'),
(55,'xrated','fG7McBPyj6vujy4qEzcfFpQSNeDoYRKH5LvPCVV9QyPG',2,6,4,8,0.034580,'Violet Ridgeline','rain'),
(56,'xrated','7PXqHwA4RsFKWpLn17e1pXrdTuPAkFdiaW8Vb9L8n9Ab',0,5,5,3,0.038270,'Downtown Grid','thunder'),
(57,'xrated','raKgheSGfPG7ydgLBsocuvt9ucCztifcVueGndVBhTCX',6,2,2,5,0.060197,'Orchid Comet Field','stars'),
(58,'xrated','qdFrY5kNE2rZCVn9gtzqKiczqsEbj4me4HJDSqCwihJ7',5,0,4,0,0.055607,'Ember Moonrise Skyline','snow'),
(59,'xrated','4uK7rmDHSVCHBoCvyfWRoVRPoFhfysFkZ7yEbheAtodD',4,3,2,8,0.035355,'Cobalt Moonrise Skyline','stars'),
(60,'xrated','5gRcMURb4MDkt8bbeThCfogfsZ5T2ZTDrevbH9uGfVQ2',3,7,2,8,0.045108,'Verdant Dune Sunset','sparks'),
(61,'xrated','WM31ScAgzVs2aDPVqz3kqZENnkSWLWRLSwF6Zt4D35We',5,3,4,5,0.047415,'Verdant Moonrise Skyline','rain'),
(62,'xrated','KWYfA8FAaLDT9wYrsivGttqoUrZTtJHgNYsbT22mRdBs',7,1,0,2,0.055495,'Verdant Dune Sunset','sparks'),
(63,'xrated','LMufkxiqyTsziEkMguA6d7pznPuyVsZEFF87SvkShpqJ',6,6,6,0,0.046990,'Toxic Ridgeline','snow'),
(64,'xrated','9qYd3zwjgX7qHDMS9cc3RWQnhEy1WWpciJ9JATz7fdoG',6,5,7,7,0.037690,'Orchid Still Water','snow'),
(65,'xrated','gzWRqSyTU9ivTPz2jSCq67GxbRfEUf3mkVVX3gQiYJmA',2,3,5,9,0.045910,'Orchid Ridgeline','snow'),
(66,'xrated','w1LoM2fPERFxBRzcQGmdx6rYqsU4UWb8bTzS4CSq1NxX',4,1,7,8,0.038390,'Moonrise Skyline','rain'),
(67,'xrated','YEuiAQSb1mtj6i74WiL4CxFRrBmU53VxBev5r1iz2nx8',6,5,4,9,0.039005,'Moonrise Skyline','stars'),
(68,'xrated','AMtECvAbUP4UkUS9TfG5mZ9krBdzgLJ5GFyrosL9B3jK',7,5,5,4,0.060382,'Orchid Ridgeline','rain'),
(69,'xrated','4bUh3biEkjrf8shk2Er8JaGujwRAh8mD3aCmefuWYkvQ',3,1,0,2,0.040590,'Ember Comet Field','sparks'),
(70,'xrated','gLTLRK6Fpt5LwufnQc4EZygdZyYSmnei3B5C4k9YccTB',4,5,3,3,0.055895,'Cobalt Dune Sunset','sparks'),
(71,'xrated','5EV3516d3HFcTZJsAEdwkKUYY2h9YK2nU9M9n6JQaqMD',1,3,4,5,0.044620,'Verdant Dune Sunset','none'),
(72,'xrated','PaF7HhxW6Gxbm8fkYdBDbZ9Sg5DdhUxCZt1guCKyTwop',2,6,5,7,0.056543,'Verdant Still Water','none'),
(73,'xrated','F7Wx2sh3FZCuYmSLtH31E2QRT65nCbuuhVEmQvZkijei',1,6,2,0,0.051105,'Frozen Moonrise Skyline','stars'),
(74,'xrated','GMRecqMm9XRdb2jyXSttWvHhBUfNiUxAJFJsiVJtQL49',2,2,6,8,0.032628,'Verdant Comet Field','stars'),
(75,'xrated','iw82C9gGRcr5ryK1YdGSkcT7bd8psdVPzSwSZ1t2AUo7',6,0,6,6,0.060345,'Toxic Comet Field','stars'),
(76,'xrated','5wUFPexKJXujN6J9zH5gzBrPzhRAst8N1JtLbGphW4uV',5,5,5,8,0.042480,'Verdant Still Water','stars'),
(77,'xrated','9ZwMUDSYnwPpyQnBNGLog8ni4JRoy8Xiq5xQL3yc2HGa',7,0,2,3,0.044525,'Toxic Comet Field','stars'),
(78,'xrated','7p9QGCHFgD7PCq1FMXc5wX453V8j2ysHVDZajNyRaS3a',1,8,4,0,0.036933,'Frozen Still Water','stars'),
(79,'xrated','5pkY8DWJccER2XcUYQpx5m83QaeLnG53q8A6d4mHow4o',7,1,2,2,0.040333,'Frozen Ridgeline','snow'),
(80,'xrated','AEWMG9dPQtT9EihMwQXBLoC7SL14QNUCSS8Z1DsQeaKA',1,9,6,6,0.063667,'Orchid Infinity Grid','sparks'),
(81,'xrated','PfTfZGUiqmRMKcD3PAkPfTo3sVuVQwnSn6zJDLdk6WVT',4,0,1,3,0.039690,'Violet Moonrise Skyline','stars'),
(82,'xrated','jzWx1ZD4dKdDe3jwDgxUDG1yqjbSRvTGWEXADoAu99VE',3,7,6,9,0.055802,'Toxic Comet Field','stars'),
(83,'xrated','d4HK7Rj6DLxGFgWxAs7JCihUTyDTxBBjtH28A9sdGbMv',6,6,7,6,0.045345,'Ember Still Water','stars'),
(84,'xrated','eRi5grBSzuqgyqraejT6WEhSEfL8xHatYz16hc7YrF9H',4,0,5,7,0.057202,'Ember Moonrise Skyline','stars'),
(85,'xrated','kpaNcNKo2HY3zuA2nzsQyZz6HuWUhgDjre8ZEW73HC5M',6,2,1,8,0.040420,'Violet Infinity Grid','stars'),
(86,'xrated','Dzyhn9HrfbyPQ4HmByasVWKiJqre1kFbw3VyQN2HLpZo',3,3,5,0,0.043760,'Cobalt Dune Sunset','none'),
(87,'xrated','ArpxjxYZcXo4Nzuaqd4y8U1waWrmHhBb4fLNGUP5RUtq',7,3,7,0,0.045100,'Frozen Ridgeline','rain'),
(88,'xrated','kP9qFZyhiyzPpQXuyuH7Qn69FzuEZbc76MALP6PFA4TD',0,2,2,5,0.037420,'Frozen Infinity Grid','sparks'),
(89,'xrated','Zu4FZCmJg7iArxKnHWV7LKbCrhbjXBBsgnitt91zLfvG',6,8,3,5,0.045867,'Cobalt Downtown Grid','thunder'),
(90,'xrated','e59fLqf5ecPYvF4G8tyxLASF5BvvaNcbNm1R7F65nyxS',0,4,7,7,0.032830,'Verdant Still Water','snow'),
(91,'xrated','KWqjmPFVgVcedd6CMtcotH1NS8w5cdoSnDEirExcKQ1q',0,5,6,0,0.070345,'Cobalt Moonrise Skyline','rain'),
(92,'xrated','G9XMyzV5xUEiMun3AUoemDqiqFqRV8ozT2UHgoxHiTu8',6,2,7,5,0.056905,'Toxic Downtown Grid','none'),
(93,'xrated','9iAdJMyRDfvAv2gcoJPCXWQqC4jGYfHtDSizTPDVXzyF',7,3,0,0,0.049275,'Violet Moonrise Skyline','stars'),
(94,'xrated','xZG4STKeHikd3UGEKN5uNbkLGHubf28a9NcAPojWxkvG',5,5,1,3,0.065047,'Cobalt Infinity Grid','thunder'),
(95,'xrated','4d9xxGyFnCXsHxmWk7DcrB7ddNH2fjJBxpigqEakEnwV',6,1,1,0,0.047580,'Frozen Comet Field','stars'),
(96,'xrated','iy1WK7RqCnVmRQgcZD2RnfCTMdSbb3b8DPZbd1FG22rZ',0,0,7,5,0.061622,'Orchid Dune Sunset','sparks'),
(97,'xrated','Qmor11Skb4dhzmwV4BpJm4C1eF3vZU1ocUZzf21EzBu7',7,0,1,6,0.039025,'Violet Comet Field','stars'),
(98,'xrated','whKCnRqVNqCFg5Mvy2s82RQACU2Cwd5YZznPHS5FrcNF',3,0,6,9,0.046385,'Verdant Ridgeline','snow'),
(99,'xrated','pqBTVgNUCfeWuHvN2wF2X9v8D3ESQqCcdCCFodNzQcyh',1,7,0,4,0.045773,'Frozen Still Water','snow'),
(100,'xrated','4oM1ZiewyyLPcWz7JCaajtEjoB4FaYDUAqREJdhRgNGD',3,5,3,0,0.049410,'Ember Dune Sunset','embers'),
(101,'xrated','T3ojCkP33jpfxYVyQwfLECcBKNCusVJbouMAwbRNTFef',1,5,7,8,0.065418,'Violet Infinity Grid','sparks'),
(102,'xrated','uDmC5sQgjjUTL4LyrDJq73SNUwpG6waWcJSxNYNz5rRv',5,5,2,5,0.041815,'Cobalt Still Water','none'),
(103,'xrated','KSKA4sNNYkUnZU7FoEe9wpDHhr7BgvcT4W7sq3KkUeWb',2,7,2,4,0.048173,'Frozen Dune Sunset','none'),
(104,'xrated','Sj9WCQZES3aFu8rkRhT7ExgdJ56ua1PCd9raTMYhFbGN',7,1,0,5,0.064845,'Cobalt Comet Field','stars'),
(105,'xrated','1qy3sYop3vzoHGCo7agmkjndpSdcRV5xWn6H6493PPuM',6,8,4,3,0.045222,'Ember Downtown Grid','rain'),
(106,'xrated','4yMPebgY8nP634Dg1Ahcx3Dd7V79MykWiwp9sAdnWwVR',3,4,2,0,0.047397,'Dune Sunset','sparks'),
(107,'xrated','ThvmNLDLXZVkjXDAp74BUAt5RTLKhvbnoYM5QX2HUD1F',7,4,5,0,0.065825,'Ember Ridgeline','rain'),
(108,'xrated','t8nQENmK1waLTyH2Q6FzxkHxtKBsGFiWfKa4c8U35QMh',7,6,1,3,0.060463,'Toxic Downtown Grid','rain'),
(109,'xrated','6FoTUjT81zTGcTxyozzWkMHU7GRbSjxTUK8pm6L4xLSb',3,8,6,0,0.045795,'Ember Moonrise Skyline','stars'),
(110,'xrated','3TWCygyLZkVL4TNKMXdrqGJGiADcxNpN4X2fWgSf2wwX',6,4,1,7,0.055095,'Violet Infinity Grid','thunder'),
(111,'xrated','RGaVkSPUH6kCyEcyTtPRgvgkndbVniEBZov1SsokUvAq',2,3,6,0,0.048998,'Ember Downtown Grid','thunder'),
(112,'xrated','rbtbYGk99qgt3C88QPYNNnscZGn56i1UgTiNZVbuK5rU',1,6,3,5,0.043518,'Orchid Still Water','stars'),
(113,'xrated','WxCxphSp7dQdLetTgqeNMzypxjRdKYA4EHovDKPCYwhj',0,6,2,0,0.035230,'Ember Infinity Grid','sparks'),
(114,'xrated','T8dVXrua1UGxvne5osD91ggocjabD2EWLu4mRnzVQC9B',1,8,1,0,0.044692,'Ember Moonrise Skyline','stars'),
(115,'xrated','bFzv2H11e4u9EdDxpY4baHhm4eYkpznZyVutaQwppjzQ',3,1,6,5,0.086167,'Cobalt Ridgeline','none'),
(116,'xrated','25UmYb4i1xznyEybUctC6f59xBNjXZEoJgH5kdjTLtfs',2,4,6,8,0.045703,'Frozen Infinity Grid','thunder'),
(117,'xrated','rwbumdQ6r1As1nKBnqMdb1G3H7UXwtxS6RzMsa2QCcev',3,8,6,0,0.049082,'Verdant Infinity Grid','thunder'),
(118,'xrated','qqFMH3NSYqTMvFmRrdMBA1H2KwHcCFaGQGG9zhPmJdCg',0,2,0,7,0.063403,'Orchid Ridgeline','none'),
(119,'xrated','4uCNGLpM3bzg5RZKLFDMwoi7LkhYRUuxDaujP3LSyPoM',1,9,7,0,0.041020,'Ember Ridgeline','snow'),
(120,'xrated','HhvAG6eJyjDn5PNg5mX8w8zfJFxkr8eyZiqCLfpvP17a',3,1,4,0,0.047770,'Ridgeline','snow'),
(121,'xrated','PnMazTxjLYhoUTLorDFgqDU6Dx4EFo7eDM4jEbEHLWqZ',7,3,5,9,0.036445,'Orchid Moonrise Skyline','stars'),
(122,'xrated','qMqQByU4cELt4wwdSuZtrJk2NjT2C2PWn58M4ZqrttjD',2,1,2,8,0.069742,'Comet Field','stars'),
(123,'xrated','SGNbkNDDxsoHcXf9m4kvLAyhy3mpW6DETwZUqKHcVKmU',7,3,5,9,0.041157,'Orchid Still Water','none'),
(124,'xrated','n68RVExxh5uaRmgvuBF5rZC9wqQYssrtqFenmnxyWoBG',1,7,1,2,0.039010,'Verdant Moonrise Skyline','snow'),
(125,'xrated','DheG8e8LpJQErWNH2XwPDiq6uof948reG1Gz1ku3G6NQ',7,4,2,7,0.059130,'Frozen Dune Sunset','embers'),
(126,'xrated','419JthrnJqFDrssKZhgpooskekqXevnxstvBMCWtcXab',1,3,7,0,0.038960,'Frozen Dune Sunset','sparks'),
(127,'xrated','wXjcEykdRkD8oUxH84QNPMybwaY4kZWG8B3FoEeGPY4k',1,0,2,6,0.037850,'Cobalt Ridgeline','snow'),
(128,'xrated','P2HgK6fCb3v94i6FvxLy4uBSx68L8N99SiNxkByyA2PV',5,5,1,6,0.039733,'Toxic Moonrise Skyline','stars'),
(129,'xrated','WmGrNHeVvhxRk3GX1uJGkPfXLuSu4tny62A4TP6TtALP',7,6,2,7,0.044808,'Frozen Ridgeline','none'),
(130,'xrated','Njh28MHaSvfGVcJ6LcsqirVpEavod9yBDUqLAa4yrAPG',1,9,2,8,0.040180,'Ember Comet Field','stars'),
(131,'xrated','nBS6orhBDQGM6EFVoA5y9HP5wB394sE7Wm69rMcww29z',4,4,1,6,0.037365,'Toxic Infinity Grid','thunder'),
(132,'xrated','BhxaKV9wDUWdiBx5zV6JaK8iiJiCriL6Br8mi2jFxNJY',5,1,0,6,0.067215,'Frozen Infinity Grid','thunder'),
(133,'xrated','gkhVKsuR395sd48VsWVXmUuTmnx4HZ1aZ2ZvHS9vRHZg',2,0,7,8,0.037327,'Ember Comet Field','sparks'),
(134,'xrated','ZUSn5W1zodHYiVzm3PFGZ6nNyP31u343j81BUZ6zDkMf',3,8,0,5,0.053263,'Violet Ridgeline','rain'),
(135,'xrated','B95kYWkbXd2xpoXJkxhoMcEVUhqXEfD9WoKzi9kSfrhV',4,4,7,9,0.043815,'Violet Dune Sunset','sparks'),
(136,'xrated','gcYGq4j4UZeMoW41bn7DRkjPC3sS4gmke1bop4c8URhb',6,1,7,9,0.034865,'Toxic Comet Field','stars'),
(137,'xrated','rSQvoqX6TjnTAjPo66drJ5ipCQBf7g7Z9Z7GPRX9oyhv',1,9,5,7,0.043210,'Frozen Dune Sunset','embers'),
(138,'xrated','yTour5YuueubveX2qXtEeNDTtaCmegHKXRuNH619gpB2',0,1,2,9,0.042673,'Verdant Comet Field','sparks'),
(139,'xrated','ZshmKnwChorFMfovLq4q8KBBanmo4fCvjSgnXFJQCmPo',4,8,2,9,0.044073,'Frozen Dune Sunset','embers'),
(140,'xrated','uEMVBUWiQSnyTiVGAsN2P8ph6QFnzhyHMoTYitZmkcyP',3,8,1,5,0.039485,'Toxic Dune Sunset','sparks'),
(141,'xrated','eHkJibAmZZJwPmDTJWZrAJFg98SoVHoWdvxicr2ouPax',5,9,6,3,0.070690,'Cobalt Infinity Grid','stars'),
(142,'xrated','w3P9GutN2gjAAYMLiukZPVJbUiq3Q935GPSLcQPFSG8K',1,6,6,7,0.050333,'Cobalt Ridgeline','snow'),
(143,'xrated','Hz6aNsv4sZCvXGrdU8FCraSCUgufcHVLMSzkinRTdapM',0,4,7,2,0.062437,'Cobalt Moonrise Skyline','stars'),
(144,'xrated','ar8VEejLyHQBr1ZnZvYW1Sc46bwsctTrYa5xArZkq8cz',3,2,7,8,0.049500,'Frozen Comet Field','stars'),
(145,'xrated','oGjMf7W5yNTJcvcCTeRE76WjeveUG4Ct925c7CV8QugW',2,3,5,4,0.047550,'Frozen Comet Field','stars'),
(146,'xrated','6GU5ABtmbFSVusjgdNaoGBedZii254skZ5SDRc44idCF',7,0,7,5,0.039848,'Toxic Dune Sunset','embers'),
(147,'xrated','bpi4VVff9eb2c7pZvjUXwaD3v7ojT91vLYg6paCHiiN4',5,3,7,6,0.040392,'Verdant Still Water','snow'),
(148,'xrated','oR6zvXsic4V6KD3rADbAW4KQdmVYFR1MASehCdPuAdQJ',3,1,5,9,0.051047,'Dune Sunset','sparks'),
(149,'xrated','w3izoBcB2wPaVGKAMebZADXMUNQA9Jz2PvW8uduG1Dv4',5,3,7,2,0.043615,'Frozen Moonrise Skyline','snow'),
(150,'expert','yQMZYwB9kLBPEVLaZkoParStkY5FzunjGu2SjNcUX2to',1,2,4,6,0.047397,'Cyan Prism','none'),
(151,'expert','FQcB7nH5ptw47VgYbRBsHqT8v6FfnMdb8JnRDsKDWUAA',1,5,2,0,0.051857,'Magenta Prism','none'),
(152,'expert','q9ktN37iwCyBNWhcw4cy7eGqTw9xQDGUBDzW3rLcALzd',4,2,4,9,0.054353,'Magenta Slipstream','stars'),
(153,'expert','22a2HMzM6GNT9XPYbzwce1kWGTFaf5qaqS7Un6oyUvEu',6,5,6,3,0.054763,'Cyan Prism','embers'),
(154,'expert','11vQDSBkWreVpMDoWceXYXinu6NodkiX1KtBRSo8HXsY',2,7,5,3,0.036367,'Violet Burst','sparks'),
(155,'expert','jW25BEcXVQpZWF3M4VMA4UMC3Uc3epm2yPDxEoiMqavG',7,5,7,7,0.035587,'Violet Slipstream','embers'),
(156,'expert','MMpCvfnucP3iuMGChEEZUJzaAKDSP1zFAhPTk6LsojJ5',1,5,1,6,0.039093,'Violet Prism','sparks'),
(157,'expert','9iozgCZYk8PyxDvbk31Shyt63uAyE6VokaddhKoW3D7X',6,2,7,0,0.040277,'Magenta Cascade','stars'),
(158,'expert','h9jRrYn83HoEDn2uGv1UxZKNLq64hsQEn11Zm4QUcGmM',1,7,0,5,0.040527,'Cyan Slipstream','sparks'),
(159,'expert','PjWFmgt27b6UiUtSNXYpyDwmq4kMvc2f88ioUarbrLzp',0,3,1,8,0.041240,'Aqua Rays','stars'),
(160,'expert','njeTMZbpacUgxXmkyowr8Tcbjpf479YfWzszcVnEs1Uh',1,3,2,7,0.038167,'Aqua Rays','sparks'),
(161,'expert','So5DheAi7zRuaorsWQ1jWqwSXFQKdN9XMrCz3SeJQrWH',7,3,2,5,0.033380,'Violet Burst','none'),
(162,'expert','bJE5U7mgZHvFPFz9Aeh4xPzqqsBz3CE6m8jWs1cthCkW',5,5,5,8,0.067400,'Aqua Rays','none'),
(163,'expert','667EMYBfPtUoJMswy6djvwrGTHC5jewUvTvGXXi94YLi',4,3,4,9,0.042767,'Aqua Rays','none'),
(164,'expert','zFj4SFxQgB6wrjHshefRSUhAvTZch5XwwaRuCXK3hmpg',6,6,3,6,0.046110,'Ultraviolet Burst','none'),
(165,'expert','JZKkWYbmC8k8XvpnbyEX13pHC3J2LjRTDjy2r5CT7d5Q',6,9,7,7,0.056433,'Fuchsia Rays','stars'),
(166,'expert','QGwkCZpjmactFX6hLJsWpxpjTwABMTR2SMLYM7uZc4ss',0,6,1,7,0.044317,'Ultraviolet Burst','stars'),
(167,'expert','epDZs6QRvXfYLNLKWeH5NcaDooQW7wTCn4rHvWdqECq6',1,4,0,8,0.054530,'Aqua Fracture','stars'),
(168,'expert','pTVvahRu1DeivAVX5HU223ahrARVSjiaRknjjgwPdcsH',7,4,5,9,0.040113,'Cyan Slipstream','stars'),
(169,'expert','JxE34B4CPj4kQifzg4t4vyvqXMj5yUnBsGgewbNdNCdC',1,2,4,2,0.037863,'Magenta Rays','embers'),
(170,'expert','45mya3K51K7cFoqpBmxuzwfSYcgKoA39BfqPCo2xm3Vu',2,3,5,6,0.037240,'Fuchsia Prism','sparks'),
(171,'expert','XicwQYKzx1Lt4PD7m9EPz8c6uZMAjrcjBkKAMTqJukr4',7,2,5,2,0.040117,'Aqua Burst','embers'),
(172,'expert','pQwqiBTpr3sgtdqfMHXAbGqezfnjBBjCXhk8vpCPWU88',7,5,3,5,0.038467,'Magenta Fracture','sparks'),
(173,'expert','Z7MbShXvHn2oxuTppxSF9neqZqrW83ZDizfoc8PRZuPe',2,8,6,8,0.047387,'Violet Slipstream','stars'),
(174,'expert','eFgGD6K6qrczosS4GWBiYUCYST6Huf2JfcduGQjs4My4',1,7,3,9,0.059830,'Ultraviolet Prism','embers'),
(175,'expert','V8e7YUQPJ3Tpe72j6rnTu14StnnWuceuaDD7ccPRY785',2,5,3,0,0.038893,'Violet Cascade','embers'),
(176,'expert','Vs1LTJScABU4VQL5LMPDNmmQZU7dKAuXzv9ktFZt1r1Y',5,6,2,9,0.051947,'Ultraviolet Fracture','sparks'),
(177,'expert','DaZi2Yp7SPMexZBqDidS4Msc8y4faCjAkmV8W5k6uqDU',1,5,5,3,0.041827,'Aqua Burst','sparks'),
(178,'expert','sPhRNVpm8ULtuQngHo94AUhuYjUTs1F6BXuaCREReWcr',4,6,4,0,0.035327,'Violet Fracture','none'),
(179,'expert','7SabASacrVj6guqVFwpqBvBVr1K26CjBtruaWU7rP2ab',3,3,2,5,0.048050,'Violet Fracture','embers'),
(180,'expert','8zurigXMm33nVVacX3QCfcMDubGqFeVxRmzEUm66zxvg',4,2,4,5,0.058733,'Cyan Slipstream','stars'),
(181,'expert','iH7eVGvS7cMgg23eiSLZfFsMTwkb4BvnXuiwqB55Cefh',1,0,4,9,0.040710,'Magenta Fracture','stars'),
(182,'expert','ukdb9NGcu9D3QYouHjcsXTkQMaqDJ8kMPCtywigv5vGJ',4,6,4,7,0.038970,'Ultraviolet Cascade','stars'),
(183,'expert','j5VPCmM5nQLLuM8neYxhx5qzHYrbS4KgHfCXCLRp5Fte',7,4,6,0,0.058963,'Violet Fracture','none'),
(184,'expert','pXXgTgatCDeG6GZXsCpKrYXy4M7hcsqxJdMRQZBFgez8',3,4,3,7,0.076177,'Violet Fracture','sparks'),
(185,'expert','vnhPfA8bASWqg5q3uddT71RzQSFe854XSzC1dLZ1HfV4',6,4,1,8,0.037523,'Aqua Cascade','stars'),
(186,'expert','QWx48nJEbeTGnDJoCB1W3grdo2HqEXkDczbux1Pf2v3a',0,5,0,5,0.044033,'Ultraviolet Rays','sparks'),
(187,'expert','WNEogcBzCZaxDeZP2wjC2DpfUD4W3biYWJeWmk8s22VQ',1,6,0,6,0.044067,'Ultraviolet Burst','sparks'),
(188,'expert','3Huf6Atb8idNJd7xSDcmrJo8vDBZMnSzcuLVsAiQNGLg',2,6,4,0,0.033393,'Fuchsia Rays','sparks'),
(189,'expert','gCFXJVQLWSUmaKEggFRyp59JhxWbbKB676KQiJz33qUV',2,7,0,7,0.029780,'Aqua Fracture','stars'),
(190,'expert','P4Ewynp2LWCZhHeyyvhnjPY46PKbQDsTgMNCCW6igZcE',5,6,4,6,0.065323,'Cyan Prism','sparks'),
(191,'expert','N9zziat38DSnu8AtZZXpHvW72yNekoxBTcsPoNR9LcEG',2,1,3,2,0.077023,'Magenta Cascade','embers'),
(192,'expert','sSXpo66rQzLxUEH6UcFC6JSPkEAVC3i3BvRuemKhaYBj',6,6,4,6,0.033573,'Cyan Slipstream','embers'),
(193,'expert','DKF9z492FwJUNzp45mJUP83T7smPViTw5jJwerUwbzrh',4,4,2,3,0.045430,'Magenta Rays','embers'),
(194,'expert','y8SQTZggdtD3CiiFsyKvXKvJbf6BYpkznUgg1MNFK2ad',1,8,4,2,0.051847,'Aqua Slipstream','stars'),
(195,'expert','2eNKEzVLhyrUrkUWbqB9CRjAPJusBvQHfLVo5R8LGBDT',2,4,7,6,0.033493,'Violet Burst','stars'),
(196,'expert','ff1Cv5LTpfDKrze6nMYqyYLgXE2QLjgkKEzG5zgiRRoj',6,3,4,9,0.035817,'Violet Rays','sparks'),
(197,'expert','NAKBdZAWkCt6pFX5bB4CYai6PUh6TfSuDZy1mVEo7nCE',4,1,7,5,0.038043,'Fuchsia Prism','sparks'),
(198,'expert','gewjTVrqfTn88PnNxFy5yAGNfY5K3W14jzENgVyUUUeb',5,9,5,3,0.041413,'Fuchsia Fracture','embers'),
(199,'expert','guoUNE6CxMbYB9EBMn7LA8aLG9Vqs5kxsM5ywaYJsXdu',4,0,3,0,0.037887,'Violet Burst','sparks'),
(200,'expert','7tURQhsJknqtvazFb72DyTRSvG2TmgvqLmS3Yp6VbaNW',6,1,3,6,0.064780,'Fuchsia Fracture','none'),
(201,'expert','LqQaBfSkfUtc59kFyRutQXrBKdeodQ4cDKZY2VdUtB88',0,5,5,8,0.042447,'Violet Fracture','sparks'),
(202,'expert','c4Qot2T6ASysvRxxs4K1Sjh26sPwj1s7RABQEnTCSfb4',4,7,5,0,0.056877,'Cyan Burst','stars'),
(203,'expert','6NteHxY1gwQ35QuuVQHX1iG2rt7hQVg5JNGCaxj1JkQ7',1,2,5,4,0.054120,'Violet Rays','stars'),
(204,'expert','UJV2kpNeY17YsrR7TH4Q7DH2m1ggaQzmKiuFnBeaLGWJ',5,9,1,4,0.047273,'Aqua Slipstream','sparks'),
(205,'expert','FBbHzKfSHJdf4FiWBW1FsZQhDnduenEPVsTV4UA8Choi',0,3,3,6,0.052380,'Ultraviolet Fracture','stars'),
(206,'expert','nkLNqdG6QuytbwRvZjkuby38JM5TmjTHcXkppivfYJF8',2,1,7,9,0.037627,'Violet Rays','none'),
(207,'expert','E7WLzz79UvRGiq6MFFa7DZu5Y8PQT8aM4NqbvfkEKNbA',1,3,0,8,0.049567,'Cyan Rays','none'),
(208,'expert','F68FFtGkmQNXQnj8DG3835GHvfbdxakwmPNhEw15nXSP',5,5,5,7,0.042247,'Fuchsia Cascade','stars'),
(209,'expert','qVLbB5fhUTSkoce7obaExzohrmT5YpcuC8ezZdTvUbAf',1,7,1,3,0.067013,'Magenta Rays','none'),
(210,'expert','yAr9RhM3fK1oNWQ2yBLWPyUie9qvyTSMbGNJLiDPuyJL',7,1,0,6,0.043527,'Aqua Rays','sparks'),
(211,'expert','mPXeK3zWdcKboHeJXiweP2Zq1vpf2qkThPENCXC7Wg1Z',6,5,3,4,0.046153,'Aqua Fracture','embers'),
(212,'expert','VEfD8rfb4gYUC79siWXuzAXwgHGfs8Gz1AayrfJVWUDz',6,3,3,9,0.048367,'Ultraviolet Cascade','embers'),
(213,'expert','1umMNq9oNDRVMsQrvZco3N6AiRV85DAiP42g1Q1CCnNa',4,3,1,8,0.044540,'Fuchsia Slipstream','embers'),
(214,'expert','cU3fSAWQJUKCPShjfVHUkbCerUE9pFomsLJgqS9JzBGw',4,7,4,4,0.043867,'Violet Burst','sparks'),
(215,'expert','iyLwEyhKuspRpGsC2jyphhkf4VPj8KtVWT4NaWK3xZcT',4,5,3,3,0.040210,'Aqua Fracture','stars'),
(216,'expert','jiTnF7zXXf8PekkuiZ99zP18Qx6sTrNd2v5sjhXTYTLN',7,5,5,9,0.040307,'Fuchsia Fracture','none'),
(217,'expert','zzzj6ZiXWgvdBAUutLgsm2b9EzwrHtZNYNkaY6CCNYBJ',0,9,3,4,0.052303,'Fuchsia Burst','none'),
(218,'expert','8EBj8xRB63MyBFWvhMhKxuhEHkA5WhnRULKDbshU6iXA',4,8,3,9,0.044250,'Ultraviolet Cascade','none'),
(219,'expert','dWou8aAEsqWYVcVi9F3m3v8RkY6sXSfFTD3MssVekWTQ',6,9,0,0,0.053597,'Violet Cascade','sparks'),
(220,'expert','MkLWKruGz1245Ro1wSxSEoCrmo8uYR2PgtZEtm7Vc7Az',0,5,2,3,0.047670,'Cyan Cascade','sparks'),
(221,'expert','rWHEwUV9vWj4Cv5EFQ1VooJP3GRwXuCPV4Pw98aKoWqd',0,5,7,3,0.066153,'Ultraviolet Cascade','stars'),
(222,'expert','j1XhdDCLRQ3iK1ze54goXJRxWTxDoEtzPrA4SJErE8Um',1,1,4,3,0.050607,'Ultraviolet Slipstream','sparks'),
(223,'expert','oPgxVfsHW2heun8ZZKmaX31ufBBfa8Teuoh1EGMMHnLR',7,0,3,8,0.056140,'Cyan Slipstream','embers'),
(224,'expert','5uUpyMDq94qCzBy6muwTZMiupAL5iEkDX7DP8TcEmSRJ',0,7,3,0,0.049247,'Aqua Rays','stars'),
(225,'expert','oU2XjTNLgPAr89VDpopEis69G6Gnmfsja2JBE95SE3zY',5,4,5,0,0.044743,'Aqua Cascade','stars'),
(226,'expert','MFsMcCZp75dcpWvNgE7tmNiTgGVzfHeurHs9gBuaVcce',3,5,0,0,0.045067,'Ultraviolet Cascade','sparks'),
(227,'expert','J9x5FjKkbEezdeTLMAkk8tPvxqYnckE7j8sKM8BF7YgC',7,5,6,2,0.057813,'Ultraviolet Cascade','sparks'),
(228,'expert','hoLffV3yxuYGm3D3sadkYjmrgoCUfKZfxPckiXpGrDJ9',7,3,0,6,0.050960,'Magenta Rays','stars'),
(229,'expert','yPGbaBqfnnfgQeN6XgMDvz9JhH9UCfaUEHpCJfLfVVPn',5,0,6,8,0.045287,'Aqua Rays','stars'),
(230,'expert','fzpUaDQupXZLfQqaShv3GkS88Z4RvmYjNuV7CqiT4h6K',1,4,6,9,0.044420,'Ultraviolet Prism','stars'),
(231,'expert','xBFjGa8f9rD7yhChstEhZn88N4ZipYHWYaMUhXLC1p2H',7,2,0,5,0.043787,'Cyan Slipstream','sparks'),
(232,'expert','wtBUxsyPGjPTspF6cZcBug66s4eLDJe7ScLnZ8sv2Qtz',0,4,5,8,0.052307,'Fuchsia Cascade','stars'),
(233,'expert','Zivnr1ng9A4chn6PsGgKwa9ZugVidoZvZVC3MKSqdGKJ',3,5,3,9,0.034453,'Aqua Burst','stars'),
(234,'expert','M5wmaBPQG7VE6aLPk1WfZt9VqPgYV5SLUWxU9beKzc9n',1,6,1,7,0.046993,'Aqua Slipstream','sparks'),
(235,'expert','u4xiTN9TuW2vvjSyykA3zCwGtYcuAu65eakJdEXMwF7x',5,4,4,0,0.042293,'Cyan Cascade','none'),
(236,'expert','MqWsR1fuRY37EdwZQZbrj5ZgGeC6WMe8Xfm5zQ3a4c95',4,9,5,5,0.036280,'Ultraviolet Rays','embers'),
(237,'expert','DbZ31Ncovst1QsTvNYranwqUEgBGctwhGajqDsxhwsRZ',4,7,7,7,0.053743,'Fuchsia Slipstream','stars'),
(238,'expert','CLyKGhJ4QoELvYLHG5iM2DUr6cVXNip3qgx52Vv9dTmF',4,7,3,5,0.034140,'Fuchsia Prism','embers'),
(239,'expert','HK6RkKR1qG1yHGMa7htXD31AEJxhNXMWBm8HqGgeFv9E',1,5,5,2,0.040317,'Ultraviolet Fracture','stars'),
(240,'expert','K2kyuwxn4yum2rhhgdG4KY48MTdecwgixbMqMMeZTmd3',0,0,7,3,0.053493,'Aqua Burst','stars'),
(241,'expert','3zUvMLQ4S6coMniELvtVQrFU9sfTRWPwF845NzZ51ZQV',5,4,6,0,0.038673,'Violet Rays','sparks'),
(242,'expert','11YL2wQ4AnDhkCdAwTMqr3eJ8aiayNez321CB7Ceu7qZ',0,3,6,0,0.046187,'Magenta Prism','embers'),
(243,'expert','GBLr9qrKVcSU1yEzZXkgwy8osDwiBQYRKy3wyVM3qYFe',7,0,7,4,0.045020,'Magenta Rays','stars'),
(244,'expert','DZStZqiog6Ekt1QCk9TyrLUxiFuDD9CkxUNn1ciy1Snk',6,0,7,5,0.050407,'Aqua Prism','sparks'),
(245,'expert','cEop5Dp42YWnj5PXqZ4iZCmgzAAXbnHDmSL8C7X3oTPQ',1,8,1,4,0.032173,'Aqua Fracture','sparks'),
(246,'expert','8v5sCf2a3c2kKKY24XFQxFDDXmBiZumeLovoCi2LPZby',0,9,5,0,0.053033,'Cyan Fracture','sparks'),
(247,'expert','zs4XERxLPnV6q9ViCj1qaPwbbxssgjmmjs8ssoXG5jxt',1,4,2,7,0.047517,'Aqua Burst','stars'),
(248,'expert','qqqSFVKbDH9de8H9jeyvqLhFk5uqrZ47Xuy3iFbPmroA',6,6,3,9,0.032973,'Cyan Fracture','sparks'),
(249,'expert','ztfCiLLVYFwNKZrUan4RMJe6Pp1cTxGfuiyJQebpZR85',3,0,0,8,0.047593,'Fuchsia Slipstream','sparks'),
(250,'expert','RtxjyApuLv3v4j7YNMUwtDpfxn3Fo3gJxxhAZpRRjVUd',4,0,4,8,0.048817,'Ultraviolet Rays','sparks'),
(251,'expert','pJDREAFq6Hy1dVVmyJZEjPUKJ4cenDZL6E2BqMpqbBFi',7,3,7,0,0.038020,'Cyan Cascade','stars'),
(252,'expert','5S1zAmiFeKRns4HLUUToqM9d4r7FTchqHHfB8z29wSXN',4,7,2,9,0.034347,'Cyan Burst','sparks'),
(253,'expert','q7YTcbWPXdYGdQY3A7ic5jctZ1dFaA2o3CH5qKx332UD',4,3,0,6,0.032803,'Cyan Rays','embers'),
(254,'expert','gSGDmhHNj2V1ai1TGVjrWwpEn2VT8RyaMhe8VRrxJmwJ',0,9,1,2,0.049493,'Ultraviolet Rays','none'),
(255,'expert','q47KWV9NBkJ4VdzLPZLoWH4vsVAxxMqb7pXWDzGxGPkg',4,1,7,6,0.044163,'Ultraviolet Rays','stars'),
(256,'expert','2J6dhrg6AqvMJKYKFjtFBNWpKXogMsSVdfdDUcsimNod',2,9,3,6,0.049723,'Magenta Cascade','stars'),
(257,'expert','g7VBiBskK9Q7r3T19CLnAUd8ABxREwXqrTZpLxBNrPGJ',0,7,1,9,0.059217,'Ultraviolet Rays','sparks'),
(258,'expert','wsg9rNgSDNYJjfWr8VWiqyEzKfZiny1eH9sNxdV8i5Hh',1,9,1,4,0.047623,'Cyan Burst','none'),
(259,'expert','wubsLWeMuN7HXHzqJw9WfWDj3mQdPfRpCffYj147y8ps',3,5,6,8,0.054900,'Fuchsia Cascade','embers'),
(260,'expert','7NTiqGyuXokRtn7V2py8iCZj4pkcj492nwb9MPVZ2Kf5',1,9,5,9,0.039583,'Cyan Fracture','none'),
(261,'expert','UDm7qUZmVc27aioTKSf7RkU4Yh7fEr3xg638y8TXA2TT',4,1,5,8,0.047327,'Ultraviolet Slipstream','none'),
(262,'expert','ZXoJArpGbSCFPqYDrx9UzBZeQLmCpjwu3Sfpq9oiLWTx',1,9,6,4,0.038377,'Ultraviolet Prism','stars'),
(263,'expert','qGt383Jpz7RAP5CyjBqrgWGFja7K9aGWUxcunRXGDZQZ',7,6,7,4,0.037833,'Aqua Fracture','none'),
(264,'expert','3vXbEGJA93JcSn1L276BjsHdfCJUU5spQmEX1jp1xvBb',6,4,6,0,0.037627,'Violet Prism','sparks'),
(265,'expert','iifbJWumTvfHH1YwndzW6PchoWGHsn8MDKsUHxjKuwXm',0,5,3,7,0.044383,'Aqua Burst','sparks'),
(266,'expert','UbxybtE78uSQbCaM7ew4FVFjVZGNV5Xe5vj5DFA8g8MA',0,7,5,0,0.031527,'Aqua Rays','sparks'),
(267,'expert','WVNoPw65g9NPKqSMXNmeQ8T8YZ9A9XmWMKzRupU9f9qS',2,9,7,6,0.062697,'Fuchsia Fracture','none'),
(268,'expert','rMdD8DL1bt1P8SawYMMxFa68mfVQ2HgHngUr5mq491Sk',3,5,7,0,0.045630,'Cyan Slipstream','stars'),
(269,'expert','a8VTeXecdBNu7GfBepWYF1CD6yD7U63mSgKRHyD5kerH',4,9,2,0,0.035393,'Magenta Rays','stars'),
(270,'expert','Efo16iLJZ53QdbgpP8cus22BQb8ReoXMqo4PNVUvsgbt',5,4,4,0,0.053810,'Cyan Prism','none'),
(271,'expert','WQLxzcCFzrpRxw6mmSkNVjzc5scP3WQxyfzdLaEXa9cu',6,0,6,7,0.057663,'Fuchsia Fracture','stars'),
(272,'expert','4yybS2S2kar1r4cHtYi2oweMxLNtFdvuBpCP2YBQZYr2',6,0,5,2,0.041113,'Fuchsia Cascade','stars'),
(273,'expert','PesfEkUBDr1huth5j1697ggY2TKvpUXhCfTqqPdE3DW6',0,4,4,2,0.065133,'Fuchsia Cascade','none'),
(274,'expert','deo4CmZNj3h5x8D8uigfkNE56o1wubw5QdvWuFB42UE9',7,2,4,7,0.037440,'Aqua Burst','stars'),
(275,'expert','KsjJM7cowdTvHDNyfc25xzyXgXivpe1aysDrGtf9GqoA',0,3,4,2,0.072550,'Violet Cascade','stars'),
(276,'expert','kLCGUxzLYv74VeM1BKvcL1YQgizkk2TQ18YiHtcQxp13',4,7,5,4,0.039873,'Cyan Prism','none'),
(277,'expert','C5VWZ6xFd6DodRDLcQhsPeFB7uWVrhqTjv79MAMenzqq',6,4,0,2,0.033207,'Fuchsia Burst','stars'),
(278,'expert','Lj2XEKDxvMEzmfnGSHGuTzSdtxEHBF7xNs5T5d9gAtfG',5,2,5,6,0.042153,'Magenta Prism','none'),
(279,'expert','NQpP6wWXEsxgbWujFbB5hinqxNHrPd2nUvnH4M4UE8ex',4,5,6,9,0.074027,'Fuchsia Rays','sparks'),
(280,'expert','N2sT1zL4gGzqLawjw1cLLBTQ2D4hF47mynP3NbbMe6AK',4,6,4,6,0.053117,'Cyan Cascade','stars'),
(281,'expert','pVFKsjfz8bubd3kPAuEKqr2bGTDCj6gJFAoLWhC6pDgF',2,0,7,2,0.054847,'Aqua Slipstream','embers'),
(282,'expert','LfBJysss9PvuSN14Ua5KT8XbvjYe3yaYo389Gwp7QWQU',6,6,2,9,0.046037,'Violet Rays','sparks'),
(283,'expert','97aADyPe9YoG9HomqLfD9Xcoq7ZMeh2UHS1CtURw2YTq',4,0,6,4,0.054573,'Magenta Fracture','embers'),
(284,'expert','bSeobMssJy8ihdnCjfUVtyvHEwe4gKHbMKF59zBkMWTy',3,5,0,7,0.050790,'Fuchsia Fracture','stars'),
(285,'expert','jeHBWTNBp7BF63gUrmhCyzZqez9CZ3xvWfr7sQjGWa8q',4,2,3,3,0.035597,'Magenta Burst','none'),
(286,'expert','WQexqYfEVhx74bgDupTT9WJudhzc7UAAzDa192ELtQAP',3,4,2,5,0.042887,'Cyan Cascade','embers'),
(287,'expert','kyuex16PbmXKGJGQw7H4ZuzmxzN9apu6XwfurkLibKYt',4,0,2,4,0.058467,'Cyan Fracture','stars'),
(288,'expert','kX1rUmYptZHprcgaf24Gr2rAm7Pkp2M4NRwDadyX7gB3',7,1,2,8,0.048607,'Violet Cascade','sparks'),
(289,'expert','cqCT6z7JdRE46piruQ2UYQ2WTyjBJpyQoEUCB7oyFctg',2,3,2,4,0.034453,'Violet Fracture','embers'),
(290,'expert','2US8B8yuNU4gwQE3Gyby5TvQ5JvaQZNeTrLbLM8rjyYh',7,9,3,2,0.049453,'Violet Fracture','none'),
(291,'expert','oE7pUK8aP1oFvcv1fBtUdrNi7rnMnZaUtcxT5NfbRACJ',5,0,3,6,0.039543,'Ultraviolet Cascade','stars'),
(292,'expert','rFUSvqfoFwTG9Pq2onj1AKn3Wu9GJUtAzq84fPuDVP4j',3,8,3,2,0.050720,'Magenta Cascade','stars'),
(293,'expert','YbzLWYzJzA2tKzPThrZiKANsjvsVjxVoNUzwycLE7YLB',0,4,2,6,0.053773,'Magenta Prism','stars'),
(294,'expert','UCgfCAaeGCcf1DRthnqYMNnH3cbBmjUmQR3Jona97Aas',6,4,2,9,0.044587,'Magenta Slipstream','stars'),
(295,'expert','ztwX2xQh7rgEHGtu8kj5VfsMverjd4TxsWu6iXXwvTQT',3,9,3,2,0.040293,'Ultraviolet Prism','embers'),
(296,'expert','SvdgyHGnnSDMRVFX2878BD9P2JEMD6evHrdDTiekTMF3',0,3,4,4,0.041640,'Ultraviolet Slipstream','stars'),
(297,'expert','orWeN2HZnJJ6ckP3NMCS7L6TyJuaS7AeEgeADhwjAoEX',3,4,7,3,0.057243,'Cyan Burst','none'),
(298,'expert','1DrK9JVLCR3ooQXVHDTEnNw6VPtgfquX4HmBUX5v2pZa',4,5,0,4,0.036583,'Ultraviolet Burst','sparks'),
(299,'expert','LthCK7SoByHYZQ2iT79en24oGr2yjxbZTxi55HfCJuVw',5,1,1,8,0.045427,'Fuchsia Prism','embers'),
(300,'expert','H9XvGUkf5LC5WR3qfTdUswNhq9yDKp6moKa7H7oJFT7f',0,1,7,8,0.037637,'Ultraviolet Fracture','none'),
(301,'expert','BGnS6pbvScwq9FMG3SnbzAM2hE2Z9ELaEMbVHngBCqxC',2,9,2,3,0.038917,'Ultraviolet Burst','sparks'),
(302,'expert','o3To34y2dhejy1knehfec2Td4pCJsq1PEX2yrmbBTasY',5,0,4,0,0.044137,'Magenta Burst','sparks'),
(303,'expert','hSrG1hRsfGSmgjEcNBsFi6KXyZoxJrH6hrKfFLHDW4gm',6,4,0,5,0.066490,'Cyan Rays','stars'),
(304,'expert','vSiMYxwooepRTqS6ZmD8Z2HX5HZv8PgWt4athEBtmg3X',4,9,0,3,0.046517,'Cyan Burst','stars'),
(305,'expert','iHvugCtQdP8efLqVfn17Vav5oGWJjdZ8jgXSV5mqZv2N',2,4,4,5,0.041093,'Fuchsia Burst','none'),
(306,'expert','5MLASSjeCpQ2zpJFpx4eM1ZFnoLHshan9c7kCsBpD4Yv',2,7,2,7,0.039787,'Cyan Slipstream','sparks'),
(307,'expert','gqXMsugL6mZV7doVBKeV2BV8tMtec1ic4cJvzS2cxG2a',2,1,2,4,0.048957,'Fuchsia Slipstream','stars'),
(308,'expert','zhkvne5zVGVddYqqp2D4AbX1SGq5EjgM9y8f4E3Gb3Kc',4,7,3,0,0.038127,'Cyan Prism','sparks'),
(309,'expert','aWrsBNah8XzSbjfX3qcCP4RDZDebvwWWBxRjdbKLRYQg',0,9,5,5,0.042867,'Violet Rays','sparks'),
(310,'expert','heUPVFUJo18th4vi1FuP1FpNBZrsFi17s3gjvZxnT6U8',4,2,2,0,0.042903,'Cyan Cascade','sparks'),
(311,'expert','Hr7WGqsxzae4YJ3dkkLWyVNRw46kUQ22ufScuLnaaDrS',2,8,2,2,0.042093,'Ultraviolet Cascade','embers'),
(312,'expert','7AvzvadFrSkGM5aG1xrbi4aDNGStyde1Zjk6FVWbHTA8',3,3,3,5,0.043750,'Magenta Rays','sparks'),
(313,'expert','fqzKNnvx8kgkiYAQQCGcbydYgRswm94oj4Fc4tdktaiH',3,0,2,5,0.047763,'Cyan Burst','sparks'),
(314,'expert','8PDbb3WQVmCBrwB4i7rAG52bbXchvnpxaSxQn4CEEK5b',5,3,5,5,0.037677,'Ultraviolet Slipstream','sparks'),
(315,'expert','WibNwUew8b34KCaVch6Hhf8irdi7ioMrUc4urJpy4xyd',0,8,6,3,0.058743,'Violet Slipstream','sparks'),
(316,'expert','Dv9P5oMrXXneUzvqpUyQahQ6tDCPHVv34iyPGJo1wmEu',5,4,0,4,0.039670,'Magenta Cascade','sparks'),
(317,'expert','e9UUpFsTqDukqVbf6DquWwUZcBM922zP7QZ277hg2cec',2,4,6,0,0.048530,'Violet Cascade','stars'),
(318,'expert','tGKvh7xeuAyZjHm5zhcLiDa494krcPeaQ5iXVzuAzrEa',0,8,7,9,0.045030,'Fuchsia Slipstream','sparks'),
(319,'expert','zHYSgrxf3y4xaDFAJyrAszrr1XimUnpfvzJXYsbL5kjT',2,5,6,3,0.049167,'Ultraviolet Fracture','sparks'),
(320,'expert','rXavBm836h6rwoupoECuiVUX5xXwcXxLPiwNm5bjc6fm',5,0,3,6,0.061297,'Aqua Burst','stars'),
(321,'expert','6p4eniRru7Qv9RSsiq71sTs8tqGrgqsyyVKDqizvkNCp',6,2,4,2,0.048480,'Fuchsia Fracture','stars'),
(322,'expert','9kVkMXZGPNsE7wJsDSoYAWZCaXVJ4juuMTT1fNJtjo67',1,5,1,3,0.046487,'Violet Prism','none'),
(323,'expert','QN8xszK7XkZUDXfAbQkTZRQQNCwz8PoHikUbgbLjhYr8',6,7,6,5,0.038030,'Cyan Burst','none'),
(324,'expert','62yMVhNjtEAFaXxZ9DxhBfcxgrbxU12q6hPgx21LXYZf',3,3,7,9,0.039693,'Ultraviolet Cascade','stars'),
(325,'expert','8t7v1rrosWDwaNS77AmYeiYe9mV6SYALpL8g2UPpBDse',4,6,7,0,0.053200,'Violet Burst','embers'),
(326,'expert','xzZGPhzbovUrUAReLbBan5Z31M9G7P8i57v4nViZBXcq',6,5,0,0,0.063770,'Cyan Cascade','embers'),
(327,'expert','UpZhxjrR2qziXdogfX3eXfTpZkfB3sqhEjb2WJa6N1eA',7,6,2,3,0.046720,'Aqua Burst','stars'),
(328,'expert','a81Nn2Ut3Nyd3Hhath9NYhVfnQwhXATBsJyrsSXfJMLk',6,2,1,0,0.038540,'Ultraviolet Fracture','none'),
(329,'expert','cL3cDKYqAH1LyDMLJosg3jq8HboaFTRgrfsfwac9P4ni',5,1,4,0,0.039610,'Magenta Slipstream','sparks'),
(330,'expert','8fKbKGf5YkKejBuRskQYsPv7stj7G4ZmY9nmjnf6EPuG',3,9,7,4,0.031733,'Ultraviolet Fracture','stars'),
(331,'expert','KX3UxEiySvwMWAVxf6ga7fuDvKPfTZJXvAkmx41ZHmML',7,6,2,0,0.036667,'Ultraviolet Prism','stars'),
(332,'expert','phDTuqQCQXKoziy4JeEwNkaRxQibrMfRau9qCrhK4DTb',3,5,6,7,0.045250,'Ultraviolet Prism','sparks'),
(333,'expert','zbkv763kgnxBkYLjdQGaDFjZPTHgSVzYbSBi51P8ud3B',4,9,4,2,0.035160,'Aqua Rays','sparks'),
(334,'expert','3w8sUjz7Utc6P95yyA2guxmJfp77ozFBycv1HHetzGXY',0,2,1,6,0.045083,'Violet Cascade','stars'),
(335,'expert','2TgayF4U6H4CeWCrKNac7q41KZsatuQ3wCXuTpbP7usd',0,9,4,5,0.050613,'Violet Prism','stars'),
(336,'expert','kuw9Y35UixcBn4xo7DxXErJNFuaGivCFbmLwAPBw521a',7,7,1,0,0.051817,'Cyan Rays','stars'),
(337,'expert','BK4tUVLUZQ7BXacD23Rdm9XnntqyX7PvUpGCVbZPiQTH',5,8,0,8,0.055160,'Fuchsia Fracture','sparks'),
(338,'expert','w5TggM5zZyffwoJQnLpgcmaHHiqWBXUCvGRsb9ABkGSv',7,7,2,7,0.038893,'Ultraviolet Cascade','stars'),
(339,'expert','fEpV1qmQpYotiq1AS3gninVJdLBf8KPTU3TxhTYY9GbU',7,2,1,4,0.058347,'Cyan Fracture','stars'),
(340,'expert','Jjr1snKrPbno5KCGXUpvEuEkDsc1m1KS3JU1rvtSCG8L',5,9,5,2,0.044990,'Magenta Fracture','none'),
(341,'expert','kzfb2rArQt25GVgCThes7PnY79KtTTVi8S4NYubocVye',1,7,0,0,0.085107,'Violet Fracture','stars'),
(342,'expert','TLHdSJ3Uiu9fknDejy46Fbu24kV1iMLGEnB7DBEktY2Q',3,2,6,8,0.029307,'Aqua Prism','none'),
(343,'expert','wRVSoF4hrULTLGymV4Eb3iwCp5nSvVTWGaWRzJWqaEoj',3,1,6,0,0.059883,'Ultraviolet Prism','sparks'),
(344,'expert','vdCEE7mVj5zxPS9KaHCyWrWan4VdoKK4b33A3WdsYvNY',5,3,0,2,0.037160,'Aqua Prism','sparks'),
(345,'expert','GLGVjDUfghckgqe58LXZLLKZZNxnQHXa8izEqbr3chNR',0,1,7,3,0.035920,'Ultraviolet Burst','none'),
(346,'expert','sJDkdqjaNgucUpwJRrpQLoHYuYJ6HrU2fMnppL1BNXip',6,6,3,3,0.069817,'Ultraviolet Burst','stars'),
(347,'expert','BwvuGgZzUkETGvoos355RvV23ibKdUeexE32r5LYCvN6',7,7,1,5,0.038520,'Cyan Fracture','sparks'),
(348,'expert','2aw51t1qTutpYPmSbNNwuhe65p83nGiqg2iiByQAe5pG',2,7,2,0,0.048277,'Magenta Rays','embers'),
(349,'expert','9VYUPkeBz4qpo9TErqWs3CPxaubWumpajv4v21Tdm8H7',4,9,1,3,0.073150,'Violet Rays','sparks'),
(350,'expert','NRqWyrSxRYRFSrrGxBg334DwwbqMpsC1LpraVbzbhXc6',1,6,5,8,0.038907,'Magenta Burst','none'),
(351,'expert','Xi5aehbwZvwgT29rN29Ba3hMFGZzAYsX53agjgiycAkQ',5,8,6,3,0.039613,'Cyan Prism','sparks'),
(352,'expert','T3aRxdw7nTF3VdZDh45dMHBMvPPg5Zg3zcvWfsCkEeh4',5,9,0,4,0.046727,'Violet Slipstream','stars'),
(353,'expert','ZABbBSdMbdRGD1QmGF1bvnzwUixUALz6vYvQ71F5beDD',2,7,3,5,0.052943,'Cyan Prism','sparks'),
(354,'expert','ypiwgP1ojtz1ALJsNxf88CLD1dp3p2AfaLGDP6xcirik',2,5,0,2,0.056780,'Fuchsia Slipstream','stars'),
(355,'expert','Bmei76uZeRZz3tvwTFn5Rj3LuP6rJjXExUdFmgVuFK12',2,6,4,7,0.048450,'Aqua Cascade','none'),
(356,'expert','poY14YxfkiUYKVAhzih77xgEeyfHncNW8LSax1L8WHES',3,0,4,3,0.060553,'Cyan Rays','stars'),
(357,'expert','c9avWdDSTan19WqvS5bLmjDQaC55Y3tjLw4KdJMGeNjs',0,7,0,3,0.045843,'Fuchsia Fracture','sparks'),
(358,'expert','6ocy6qohgYupfPWMpXAi9RtPYHdL4DZRHADQMhAUkZ7b',0,6,2,0,0.039073,'Ultraviolet Slipstream','sparks'),
(359,'expert','GAnbABvBeELku5DrJVwovGnAPhiPRkYzuFb35UDgLX3b',3,3,5,0,0.047217,'Aqua Fracture','none'),
(360,'expert','vMbMdCd15qYAmBZAqmPVaUuo7i6q1Sb324wyaxcRKU24',7,8,1,6,0.053423,'Aqua Cascade','stars'),
(361,'expert','buwGK63cSVMpn5VELFpUbDUGnAEwh1v8kGQNU5rqUQXM',2,7,2,4,0.036913,'Cyan Slipstream','sparks'),
(362,'expert','KufDsCJJWGw3KJcnqrqnUZQCuGqpZkJmGeja8qaJ3HTS',5,9,6,0,0.046573,'Violet Prism','stars'),
(363,'expert','nhGM3GJd2MdGqexHSu2q356ywx8EUqMaKq7vqzmRrbR6',4,7,7,3,0.050573,'Violet Cascade','stars'),
(364,'expert','vMtMdwQwPnJZDYnVSsCpBU22e1sRiwVkCKP5YqB8ysYL',2,3,1,5,0.038987,'Magenta Rays','sparks'),
(365,'expert','bcMMk7eU3U9Jg8pgAqiGnFk61TRGtVzSwrLDcjR1zE4o',7,2,5,9,0.056753,'Violet Burst','stars'),
(366,'expert','qb5JuuGudeooGWhhYU6MDaHwAgFN3KL3VDLk98tpk3xT',1,4,1,4,0.041910,'Cyan Fracture','sparks'),
(367,'expert','sX2c9VWeKAPeCL1ivnCg9HtuppoUwYL4nsnKeLRxGTx4',3,2,3,0,0.050960,'Fuchsia Cascade','embers'),
(368,'expert','5bdWXn3NRg5wQehsvwaGfdURqhKWWhqAttmALvb1MBsS',4,0,6,2,0.039433,'Violet Burst','stars'),
(369,'expert','W91WyWgYmjJic83xLrCt2cS89iGTo6HZRQcASe1Hx7dw',6,5,2,8,0.036063,'Magenta Cascade','none'),
(370,'expert','SLGFHuY3xwsVFrfgtZSjamyySz8v8bFvbKaohncRHza8',4,3,0,0,0.032997,'Ultraviolet Fracture','stars'),
(371,'expert','ZkkfeXi7LMZNbdRxX8VnkqTzQRH4JWGstjaf6Cv9kkzR',2,3,0,4,0.046687,'Violet Cascade','stars'),
(372,'expert','F9nfz6JN7yzV4Y1ji3j6NxvgczB4kwB6rkvHyrzyMDLt',2,8,7,6,0.044713,'Cyan Burst','sparks'),
(373,'expert','yDWai5Z7jZDvWYszzqvCcseKbMc96ktmncZtWjiEiZdB',2,0,2,3,0.036507,'Cyan Slipstream','sparks'),
(374,'expert','ne71qZwMKo1x8kcjbbiRcZaH4TtzQVkMymykhXLrmNJm',3,5,3,5,0.060463,'Magenta Slipstream','sparks'),
(375,'expert','HCNJxtuauiu9dfaAnyoGGKEi7FQk6kgDeUnajaNBE1XD',2,4,1,2,0.057923,'Ultraviolet Prism','stars'),
(376,'expert','zYUDodahw5Dkvt3vq8DJU5AfuaBiLv7KqPwEEvjcEjTF',4,7,7,7,0.034693,'Violet Burst','sparks'),
(377,'expert','xSkMZG45mfj2vKowcv39VZqFqMVgs9ViFHASj1R47ZrK',4,1,0,5,0.041040,'Cyan Prism','none'),
(378,'expert','ezkstTnDXzCXXgQXu3zRBNmn31kZyWznA3guAUS35jTa',5,4,2,0,0.033960,'Cyan Slipstream','sparks'),
(379,'expert','v2CDSSS2DhkkVhgErpz9cAt6jjJmv682wzvJUHw5F5Wb',0,5,1,8,0.046837,'Magenta Prism','none'),
(380,'expert','thWRNEwG37z7HUbCkfV1wZVsMmk35Zy7i9u3VfTuWLUk',7,8,5,0,0.045547,'Fuchsia Fracture','sparks'),
(381,'expert','kFYfViERUD1zo3ZFUEHURofmS4vo5ETec4C6PUPdVhMz',2,5,5,9,0.064550,'Cyan Burst','none'),
(382,'expert','Kn3YWooFeXxQFcwrnMfZ1Hpfy9nUhmsB3WXrovuyiy2C',6,6,7,0,0.042600,'Fuchsia Prism','stars'),
(383,'expert','uj2dYwbxT4TELtKt8kFNcWEYFYCUtpvoz1CgvGVVJQvN',1,8,2,9,0.043003,'Ultraviolet Slipstream','stars'),
(384,'expert','GCgAphskYiZCRpTvZv9uk4jvPiSaJnqvyYyeS4WzLFYY',7,2,7,5,0.039763,'Ultraviolet Cascade','sparks'),
(385,'expert','hWkGdZmf17QPK4BjcVVvsMMkmZLMTfBccDASmJ2vQB9f',6,7,0,4,0.036503,'Cyan Rays','sparks'),
(386,'expert','ucD6tQbWNNFvuieUHooJ34A2E7HCpLzBUJ9qLAFcQ3bU',7,1,5,9,0.045693,'Ultraviolet Cascade','stars'),
(387,'expert','c9tHmQ8esZ28EsEMcAmCa9BuEp4nnD6LKQ5EFWbeL9oM',6,4,6,0,0.046800,'Cyan Prism','sparks'),
(388,'expert','4KwGKBpxQL65ABwwWNkgz4YXy7jGBif8FndWQAwcUHek',2,0,5,4,0.038587,'Cyan Burst','embers'),
(389,'expert','LXPSfXFWdXLZABrmDg1TJ4f2xLrgf1s8rZ1QAv4dTnke',7,9,1,3,0.056400,'Magenta Burst','sparks'),
(390,'expert','tBzv1YQph4SqgX97s8iKR1RdygmzFePoBTJxBTnnFYvT',7,3,0,5,0.039860,'Fuchsia Cascade','sparks'),
(391,'expert','3zC82zHAcV5DwwkEfgXVBXWb3DbK4rAkgfLoquYKyejd',7,6,7,7,0.044107,'Fuchsia Prism','sparks'),
(392,'expert','2qz29AQozQHWP7nMFcs1ZV9RDKDKXSfCx47wBadvQg1v',7,2,4,6,0.043497,'Ultraviolet Rays','embers'),
(393,'expert','ByobsL8NzSZ5zrQM6gWqDBre3sShCfP53gipSrCjVLUc',6,3,4,7,0.048607,'Aqua Slipstream','sparks'),
(394,'expert','Q2cyVYot95mEwadAWsSaRjfAbNEoybezje7Xr1S6Sa32',0,9,3,0,0.033760,'Cyan Rays','sparks'),
(395,'expert','jGmjTk7zD8aHz2XYMzqoAKEJvXfyqwucwsNCotLFp4Ph',7,9,3,7,0.032853,'Cyan Fracture','sparks'),
(396,'expert','L5vwbU9hSxfMeVkvSVnqq2m913rN1Q3vgMyoGpuUyjVM',1,8,1,2,0.056307,'Magenta Prism','stars'),
(397,'expert','gYGhThtKkCkgWDcZNZC454cDuxk4poa6voEJbvFbsegW',0,7,3,0,0.048207,'Cyan Slipstream','sparks'),
(398,'expert','93sgWg4VXibpZ5se91ow8JUgMoVBU5xS4qvhaCaCif4L',1,5,1,7,0.039987,'Magenta Rays','embers'),
(399,'expert','TgUCu6KQdSnZHngRPgNHoqJZx4VmzSDfGq919jxq6WG6',1,3,1,6,0.052687,'Magenta Rays','none'),
(400,'expert','7axQT4BNwAXQwLbB9itGrpBCHAMKxYS2ypNeH2D4YtvL',7,8,6,2,0.050160,'Magenta Cascade','sparks'),
(401,'expert','45NpFQneNTf3isw73BF8b2PbotvqmVBfYG3McfF2K3Gq',3,5,0,0,0.051960,'Magenta Slipstream','stars'),
(402,'expert','xZ8veQWrDYfjXEt8DXJ4g3q2DLYyMXPbUkmFY59fiWPY',2,3,1,9,0.041577,'Magenta Burst','none'),
(403,'expert','xon5bNJnMgRKwemtEmdJeGfyRQ3nCX3bu8XV142k8kHH',5,1,3,6,0.047773,'Fuchsia Fracture','sparks'),
(404,'expert','GHnfhoXhPtFnc7GE6ejU77CMfnLhRi5iqbpTxSnofkwr',6,6,5,6,0.036493,'Violet Rays','stars'),
(405,'expert','bhXrgXd79T6UAytnh8P5xbs3xCf6mRuA6rHYFFx1CQGo',5,3,7,5,0.036513,'Violet Cascade','none'),
(406,'expert','Wd4Wyw23f4Q14LHpFgyMS95FckBJac21GbFEkxrhVpVK',3,3,0,6,0.037373,'Cyan Cascade','embers'),
(407,'expert','4onio2c1oc244rutLGGSMPPiNpUYhUvPJ2N5jZbxdShP',6,4,7,8,0.045987,'Magenta Slipstream','none'),
(408,'expert','SStZMJcsmuodCBygPEnwNGqTicBLBC79RbpRDcXtwowo',0,5,7,3,0.054370,'Cyan Cascade','sparks'),
(409,'expert','9r1XpudA1CpEvE6gtNsBFD83uFJbwA577FYBGXsLPe3v',3,1,0,4,0.035053,'Ultraviolet Cascade','sparks'),
(410,'expert','8LNJUbKMin5D4aWHbx6idnFAvDSyfU5VBPBvAY4yL3Ti',2,8,2,3,0.036613,'Violet Burst','none'),
(411,'expert','G3pPCcmYpQjc1rSmQhWcuWLGzqxyxviRSvvadZZuJtKL',7,2,4,3,0.036220,'Ultraviolet Cascade','embers'),
(412,'expert','Vme8huzFMAUxXxeGEiNXy8Eqr2Rp3H4hL5i4ZiMEWemg',7,0,5,2,0.032180,'Fuchsia Prism','embers'),
(413,'expert','8W99aqN4xEng5NTxXL6JWprXwXrrJGv1yD5U7tzbLrge',1,4,3,0,0.054713,'Cyan Slipstream','stars'),
(414,'expert','mPVfZQ5RaVmuTRvxJLEy5Mjz4H7UeXxXoS3M5cNQqChX',3,1,6,9,0.046093,'Cyan Slipstream','stars'),
(415,'expert','V8WxRpR4LcgfotNsnUdZpzXK3n41Nz2mfLxnvnyEuSw3',6,8,1,0,0.038793,'Ultraviolet Fracture','sparks'),
(416,'expert','GhhtfRYTqmkPx8HEeCcBHBqTwi445rY3og2e58NbwPGa',4,2,5,4,0.046397,'Magenta Rays','sparks'),
(417,'expert','N3GUEpE6yNk4KiTgLosHWcBXeSKkkx52r5PCrKKcdNFJ',0,1,1,7,0.049173,'Ultraviolet Prism','sparks'),
(418,'expert','tbhfftoqgbv6RHFwkfAD9r5ZJ35ZdNU71UeRKcivxXWr',0,6,1,0,0.052310,'Ultraviolet Fracture','sparks'),
(419,'expert','7JfQix8zUiXpvW3LhwZHZ49YSsKNRLAXsitVKoLa5RMS',7,3,3,3,0.052040,'Aqua Prism','sparks'),
(420,'expert','SqLgK4PSZJPePCHwTRTvhGmBQnUy6XpNR4hVVr3T9vnw',1,6,0,5,0.043767,'Ultraviolet Burst','embers'),
(421,'expert','kuKGRSRE2NuHs94oEhPBDTvmQfNfsf3v5NB9QHENTBJD',1,4,4,0,0.044747,'Magenta Prism','stars'),
(422,'expert','9yWwECmMCFMkUu2XDUV634Q1TEj8PFDbmFZrSSDbrDfU',4,0,0,6,0.048043,'Ultraviolet Slipstream','stars'),
(423,'expert','MMwYFRa6PsnhEQuU2h9Q7ydRWYEMKuGWngtce296Xe53',6,9,4,9,0.059967,'Cyan Rays','stars'),
(424,'expert','LV3oFf9Ydt1U55ys1Q2su4uTtZzoGPYyQMY2zdY4TZxc',4,5,4,0,0.066540,'Violet Burst','embers'),
(425,'expert','oAVP69mtmDRqh15qbLpxYEEejSxXkDVZ4n6Kge7Q65AS',5,9,3,8,0.042760,'Ultraviolet Cascade','sparks'),
(426,'expert','6c2NJNLkXhs4TD73SszLhdi9WMtvgwBEHfuDeuRpDsph',6,5,2,2,0.044937,'Ultraviolet Cascade','sparks'),
(427,'expert','aQ78AGoiVTKsbyusacDoDxcsgKeFnc17FSATuYJfPRtT',6,8,2,4,0.045657,'Fuchsia Fracture','stars'),
(428,'expert','3CVSvSsAUy5JuPC6jHLkQfmEeYXHuUQdYAnu52VaePMx',0,1,7,5,0.031173,'Violet Slipstream','stars'),
(429,'expert','FVEgyTerCV8m2jVR4A2bZDuZxPefMzjGMgvporUxgk2a',2,1,6,0,0.035667,'Fuchsia Rays','embers'),
(430,'expert','zaffoRRvJc6rCKa8Tf8eu7ea1bRrtc882or7TcuzCDvE',1,4,0,9,0.042350,'Violet Burst','stars'),
(431,'expert','zwY1sxtspSV38RQDKidGNorJBycW2WKfKvezeFYuRo2n',4,5,1,0,0.069783,'Violet Fracture','sparks'),
(432,'expert','keji41c5hVLoP82KZXu2qHiFAg1yFwP4LD1o9x6u76SK',5,6,5,4,0.049977,'Aqua Burst','embers'),
(433,'expert','Jz1DWbuQRe1A59U5kTbFtwouSb9vYfnJUhqmrpmHr5cW',2,6,5,2,0.044547,'Violet Prism','none'),
(434,'expert','UxkVDB625BjJwbzMY6k2zBWpMYBJxHhw7zhvNP8Wdsya',2,6,7,2,0.045727,'Fuchsia Burst','sparks'),
(435,'expert','vmXm35LhtUJj5MgvUDCud7r5fXMgXpinanaSByK2BDL8',4,8,0,9,0.072100,'Ultraviolet Prism','sparks'),
(436,'expert','5MbQTVF7sSDZgTsNQspc55EdQqzzCGkX7fmHkntBqTyP',1,0,6,6,0.070917,'Cyan Prism','stars'),
(437,'expert','VWsqkhy5p6rAojpG5miRmuXuMvTZfV8ynUjLoFLgYiVw',4,1,4,3,0.050467,'Fuchsia Burst','sparks'),
(438,'expert','sRqCEiWA6iqhXQAGYDEkUBCuHxH39JsLCgvGJZYwKbsk',5,0,0,0,0.036800,'Violet Rays','stars'),
(439,'expert','skvNU8LkpHJ8tjSXbHRo8ASxUzFzKgoUYsLn8SU34Xuo',5,1,7,0,0.034750,'Ultraviolet Prism','embers'),
(440,'expert','jNaQBoDibL7S3YTmstVmcddta96yQcKpaaNQw8bZhuEJ',5,2,3,0,0.034687,'Magenta Slipstream','none'),
(441,'expert','oX22ShMQ5nN2CAkwWTdHUazqQ4TvDFyZAyseoAEtcQb9',2,7,3,3,0.053223,'Fuchsia Fracture','embers'),
(442,'expert','J7ERSpNqSGXRUg46dfkmPw64cWHqJDzxR4LnRbBZctuD',3,9,5,6,0.045467,'Ultraviolet Slipstream','embers'),
(443,'expert','Bu1TxUhVnfyboHmpJv5DzzgX4sZX6qEG96ewrHoi3sKg',0,8,7,4,0.045143,'Fuchsia Prism','stars'),
(444,'expert','GGsN5PvWL6Hs569HQKum5uN9Hcnrvi1MZFE9idAgwDqD',2,5,4,9,0.051367,'Magenta Burst','sparks'),
(445,'expert','9ZsduzZHqZ43X8PbsDLQPCVEnZSmSZHYmrEFp4dYR28W',7,2,1,7,0.044687,'Magenta Slipstream','stars'),
(446,'expert','n1X61hPQCJustLxubcp9CzLKxjPazrpyXwfHcoaZjUpC',5,3,1,6,0.036133,'Cyan Cascade','stars'),
(447,'expert','nE7QKEqsAWB4BYRKF1g1MvJtmkVj6KhqTcZckSuaDeYJ',0,1,1,8,0.041413,'Cyan Cascade','sparks'),
(448,'expert','vq9CYuUEovmpgQBsDSAPaiDpCqwAr3Rg5Dt6u5xntpP8',1,1,7,0,0.058793,'Aqua Rays','embers'),
(449,'expert','meKV4bVk6PBhEoMJ9RDrk96dWDKWfqr8cRzbo7YMVcjd',0,8,6,5,0.037437,'Violet Cascade','sparks'),
(450,'expert','zEDoweDTD5qm2T1gRepEPt69ieNg8UsNxpu3wPf3Z9UK',6,0,7,5,0.041067,'Aqua Cascade','sparks'),
(451,'expert','DgJsyD2ocD5rneja7jQMQaNHqsKY6A6JxV24jg3g4CER',3,5,0,9,0.039333,'Magenta Cascade','none'),
(452,'expert','oT84RM6NiCPd3sArtS7Wfz2CpEY8p1BkmJqkEvMiUEmu',5,7,6,9,0.048647,'Cyan Slipstream','stars'),
(453,'expert','EWQyDWLjgTqfbk1nADU5B8ibZKU46ZaR3X7LxkVECgy4',7,7,5,0,0.035213,'Magenta Slipstream','sparks'),
(454,'expert','1o4dRZsB4AWnUhWpeXLPhDvgiGgrggnQv2fK5F8qyp5z',2,7,0,7,0.040543,'Cyan Slipstream','embers'),
(455,'expert','9FXy7KJYERsr7BTg5X2bzhoGSgGa5Vy8Swuodiswt56M',1,9,3,3,0.036473,'Aqua Burst','stars'),
(456,'expert','gJBdbGmCtaAUAEgExumPPkKepezdS8ttoNYB831hNwAo',3,9,4,0,0.037847,'Aqua Fracture','sparks'),
(457,'expert','Apb6CoWZvL93WqT2bq8MJ3XkEsAfpE9XfZazfe8YZ7Ws',3,3,2,5,0.039757,'Cyan Cascade','none'),
(458,'expert','7AuZozVJXJSFYsMT1gc7VaMeYy1Aajx1Cus5qECWh8bH',0,8,1,5,0.037830,'Magenta Burst','stars'),
(459,'expert','BhV7S4VhJxtJYrtvTCT61X2VXFLXiHMTCxD37sJVHBCz',7,4,1,5,0.058013,'Violet Fracture','none'),
(460,'expert','Dbs1du6exK7foymwrW8rVipQVbpeigCbreBc8jjRqVWK',2,9,3,2,0.034863,'Ultraviolet Rays','none'),
(461,'expert','FH51MXqqAowFPAFNsuo2qhGbGkndtRgR3graBpnRtj4n',0,3,5,6,0.041623,'Aqua Slipstream','stars'),
(462,'expert','gpH7ZamAjMYnB5BodeyrEVAXxaeibVW7sHWtJLy2xpQ6',7,0,6,7,0.047450,'Ultraviolet Rays','stars'),
(463,'expert','PkBjM5ZHDcYAJPZVP5avZ7quacyZpQMSZvMvp9F6n8hk',1,0,7,0,0.041327,'Cyan Rays','sparks'),
(464,'expert','JG9tPxLCuE1vhy8gouLXsPP1Mrbn1dBRijxm3pqFn3Xs',4,2,2,9,0.035277,'Violet Slipstream','embers'),
(465,'expert','u9R1guY4V2qN3EMzFpPMmv2fZRBrCtUVqAfGfzVtvUJY',4,5,3,0,0.034600,'Magenta Slipstream','sparks'),
(466,'expert','WNaQEjRaibTRnVLMaBtjPkUPPLmSQuPSw3HPRBzwdoV8',0,4,0,8,0.048237,'Ultraviolet Slipstream','none'),
(467,'expert','LPhRa3PP55E1WWAzfx2ZMMrDjg2cuVSNfkMnNARuuJVy',1,4,7,8,0.070090,'Aqua Rays','stars'),
(468,'expert','PqLz7pXNnDVTCU52UXEUtMtoqU7QZ3GvXSALZCUU3q1T',4,2,0,7,0.052443,'Violet Cascade','stars'),
(469,'expert','BG6CYeg3KJnfL44x2VEA5Z2Njy2KyUKvRUPJfwqmPNz9',6,5,3,9,0.046953,'Ultraviolet Prism','stars'),
(470,'expert','BFo1hb5Pa2TzYGLvDDogSZ3adJd99Ge3ndCUnKbwx19H',2,0,0,9,0.050833,'Fuchsia Prism','none'),
(471,'expert','AafT4qJNwbfBJ57256Ct8828SgJCVtZJvwmcUgzpha6Y',0,5,2,3,0.067887,'Aqua Burst','sparks'),
(472,'expert','RTCjKrY4SnksyMazraskawG12kyX4GgNXaNEE1Ki1ae8',6,0,6,5,0.044443,'Violet Slipstream','embers'),
(473,'expert','TvXkKo6JNT24cyxCiSY2zFbjHUQLcjcqgGmoYUGwevCW',6,0,7,4,0.041293,'Magenta Burst','sparks'),
(474,'expert','eCQa1ZfCjXq8ZEW8LMR3J9j3u4iMY8dWDLPwKgWDMRLc',3,6,2,8,0.054977,'Ultraviolet Rays','sparks'),
(475,'expert','V6KJe92G3FvSnxwpHpr7WJZRWaFL84dS5zURRm4SG46p',3,5,7,7,0.054680,'Aqua Cascade','stars'),
(476,'expert','tdgsLqjUUC5pRE6vPdRFJ5xuQTEGAgnpy5HE5UeaiBGU',0,3,7,4,0.041700,'Ultraviolet Prism','stars'),
(477,'expert','3EcGCQDr2QwRjCxNJr74ZJeZehg7Rtu3ou5WtjP5TwfC',7,3,3,7,0.040060,'Magenta Slipstream','embers'),
(478,'expert','GZcwexJjP5aSCWxyUojW6o4NX5eM4gDEhS1kRBdqW3p7',3,8,5,7,0.044273,'Violet Cascade','sparks'),
(479,'expert','G9mn79xcwQqnhfbzhGZMN8iuBrXE6jTZgPx4YBDyZ4Nx',2,7,1,0,0.046587,'Cyan Burst','stars'),
(480,'expert','gMtcCkSqZo4Dnu5vmrLfwqbbEQ6ExEP3AkVbQFczZhac',0,2,7,8,0.040340,'Violet Cascade','stars'),
(481,'expert','LphkNpk139goDFKmdyroFzLLYdCuqxQnHSnmLs5vgAg6',0,1,4,4,0.053770,'Aqua Prism','sparks'),
(482,'expert','T6V1EBb6RchKjatrtw976Ctv4tuw136M9waCJUWQPmkW',5,8,2,5,0.038427,'Fuchsia Burst','sparks'),
(483,'expert','oSyE1EPmpK5jc4hT4BYE1P29XVrd5g1qu2ex8CneX9H7',7,9,1,0,0.050923,'Aqua Fracture','stars'),
(484,'expert','SQ8FHVE4nFLwVnRX72hofZVUo7KUNbvu3qTGq8CbPpQV',4,8,1,3,0.032097,'Fuchsia Slipstream','embers'),
(485,'expert','EWMyohqSDiMwgCMsf2eeZNWpp8WLkDJbbfHF8KZWi7rb',7,7,1,8,0.050267,'Fuchsia Cascade','embers'),
(486,'expert','JNZLv4AqtHy3sqUFvjfdihc2KiQkiqpSurqkeS1hmNuz',3,2,2,6,0.034957,'Magenta Slipstream','none'),
(487,'expert','k4huDMbREfLwb8xSuBrVnsFw2jUpx98fMAW6EDEwWQEU',5,0,2,8,0.038467,'Magenta Prism','sparks'),
(488,'expert','2eXMJfcVzAZUZ6HQtedPNgwa2z3kb8dE1eR4QtDDsmUK',1,5,5,7,0.040430,'Ultraviolet Prism','embers'),
(489,'expert','SR2LDh2wDEcpwqUDfQswXSDUhx1ZqzYzGYCwQQKWEoUL',7,6,4,7,0.035600,'Cyan Rays','sparks'),
(490,'expert','N2dzrVdgYJHA6xr1UrokP3WnbiAQGqq4eGeiSR58B5XX',4,9,7,9,0.040103,'Ultraviolet Fracture','none'),
(491,'expert','6mbCyjNcSj5QKru4K3BNRseAGdt7k9n964cz9g5j92UX',6,1,3,6,0.047980,'Aqua Rays','none'),
(492,'expert','5d2AMwUoVHDnsJSd3B6rNr5J3dduit2oDdXMuW7zqEju',4,2,2,8,0.044780,'Cyan Burst','sparks'),
(493,'expert','zf6ETn2LnfA5KeUvL5WuwgDH5d9Jw92uNZN5UBnCFVSV',5,2,4,9,0.043310,'Magenta Slipstream','sparks'),
(494,'expert','ufnkxRF2wyW3aTuVHjzqyEW5UCXCoqmi6E3WVs3wtFEi',7,1,3,0,0.037587,'Cyan Slipstream','sparks'),
(495,'expert','31fqzD7xAz3bynadMVMv3M9YWjaBmBTi3XaiNUFNqUxp',6,0,1,7,0.050303,'Fuchsia Fracture','embers'),
(496,'expert','nZXM14n48aaqt9dyzR29tFMiE7FSU3HmQ86BzLnaUjkh',0,0,7,8,0.055920,'Aqua Slipstream','stars'),
(497,'expert','yauxtfJxxqZ5rCmR49ogNbCuZdxu39WRhyAMyxSvGgAp',3,0,7,3,0.041427,'Aqua Cascade','stars'),
(498,'expert','UV2zV8b76dnbiQFx1Mgg1D85xqfbHEekrWXXEVs3Ev1T',6,1,6,2,0.044420,'Violet Slipstream','sparks'),
(499,'expert','3RJfynpu2bEYFpwz7ZaaM8WfgRQuH96Hz6W336Vg3nia',4,4,0,0,0.052387,'Aqua Prism','sparks'),
(500,'expert','fxW748wi5bgFzTcy6d9ug7WyxasM6Rqenm8DHdeikB3G',2,5,2,4,0.045917,'Fuchsia Rays','sparks'),
(501,'expert','ED6rmtNBoX3Zsw1kdYKeZXzDEKmF948QpcM5HpzPQkUY',3,8,5,3,0.039243,'Magenta Slipstream','embers'),
(502,'expert','YaRyUZngxgEiWRa2W3RkMQNrXzN5RTx9C9U22DhXuNhL',7,2,2,3,0.034590,'Ultraviolet Prism','none'),
(503,'expert','uEmtjjXdcGBpcL8SKNnmPkqE7rgX5WfTxdrEMLWfPmbt',4,8,1,8,0.052463,'Ultraviolet Burst','stars'),
(504,'expert','w3vSxXRDVtRJ12rXgboU297nF7BUJF1L1beGd47cCNE1',5,2,3,0,0.062013,'Ultraviolet Rays','stars'),
(505,'expert','nth85HHzLouSivvDiUFqk1tPBLfayM8WSSUJpno2GAW1',3,5,1,3,0.041840,'Magenta Prism','stars'),
(506,'expert','4PtVoFF4K9kfv77kLgtU6gSnChkqBoiR2jxGsw9BCiFu',6,0,2,0,0.039247,'Violet Cascade','sparks'),
(507,'expert','HZM7yJuKDL9fDhakQeqXNuRcYYcSXuUGjmHSXxP14SJZ',0,9,1,0,0.045847,'Magenta Slipstream','stars'),
(508,'expert','ZoiQZAJniiwMg2Ms5fdwB5oMWRGfiahktbzrU3Rz95ZD',3,3,7,4,0.033797,'Aqua Prism','stars'),
(509,'expert','dG362nhVciH9u7TPKdyCzSoMDhHWKF1aX7nw6pWBLmxg',7,9,7,8,0.050207,'Ultraviolet Slipstream','stars'),
(510,'expert','Qw9WG4VjwAXGJMECjRz61UohHCV3AjiKzaBkpbV8PgMb',0,7,7,9,0.037817,'Aqua Rays','embers'),
(511,'expert','35Aa7M8mkEESHL8Zbtpfu9ECHCoV9W9eiRBxd9JLNsa4',4,2,1,8,0.048527,'Cyan Cascade','stars'),
(512,'expert','fo55rjGap5BK9nFiab75KnYNvSdG4Q3CkfwGYyhx8SkD',0,2,2,3,0.049793,'Fuchsia Cascade','stars'),
(513,'expert','aU4ffwT6xgANm9iHYY39oMcSNfP5MmN1kAv9kUcbUmpQ',5,9,1,6,0.043683,'Magenta Burst','stars'),
(514,'expert','1XMZgzKDfAmiwWZQqitxMiGdnehWwtAsUSXzQu8UEN3t',4,5,6,3,0.049097,'Ultraviolet Fracture','stars'),
(515,'expert','74tTiMEbysq3PDUDXBSDqP1yxZiBPKpmNU5JS615JtUR',6,9,4,3,0.047707,'Ultraviolet Prism','stars'),
(516,'expert','a92t29a392UFARfzVPkuS1tj3xWWVFQpBRbFj8awExGU',4,3,5,9,0.044467,'Magenta Rays','sparks'),
(517,'expert','L8P1CkQrU6LtnGFFEPEHH3AR2sarbgkoy47u1GNQkxCM',4,6,2,8,0.049293,'Aqua Slipstream','sparks'),
(518,'expert','apTLAx383BQyBNsjHBWwJ1umk1gsUSk3g96n1yiwpBoZ',4,2,7,4,0.036173,'Aqua Rays','sparks'),
(519,'expert','TXumNTH6Vx4PnouFsV9Z8CSLBb4Ezd4ragcTKatt67xL',1,1,2,0,0.067133,'Magenta Slipstream','sparks'),
(520,'expert','RpEYVHEvnaFeVTxyv3yuCUTifoKq5Y1WioUVNgTuaTiU',6,2,0,9,0.047150,'Aqua Fracture','embers'),
(521,'expert','CTBnqifXWGVdoe5mtHiZUj11WfBDtcsfNCBcCvVw3mhq',2,9,6,8,0.044943,'Violet Rays','none'),
(522,'expert','3b7nQxbTRxTiSE7tAZojVvtBep6R2exMtcDCeZM6aueX',3,7,1,3,0.063380,'Ultraviolet Fracture','none'),
(523,'expert','SW6wVPtsHwRN2YcLaNVWdnMPrEqD3hSUBLVChpLaBaj3',6,8,0,3,0.041480,'Cyan Cascade','embers'),
(524,'expert','7zW82dCgmQjoYxj5TZRDh9G4Wt9AUaXtZ9LpfzH3uRFq',2,3,7,2,0.034093,'Magenta Burst','none'),
(525,'expert','ezWz8vpz4fuMLX3tPHSDxVGSZzBTuVHQo9M1NkJo1HbQ',5,2,7,6,0.042027,'Aqua Rays','none'),
(526,'expert','zbM6Qi2c657z8PqrLWokv3cotLe1aZznDDj2a77UQM8p',4,3,3,9,0.046393,'Aqua Burst','none'),
(527,'expert','ENsxVyiGu7RgbNQojXfCJ8qZYgGd71ibMTSHcShzibxi',7,4,2,4,0.055757,'Fuchsia Burst','stars'),
(528,'expert','8JytboUbAXKKSMGNTRdqUVg5vCpnhHhDBHeWcGf8669p',3,9,6,0,0.046063,'Violet Rays','sparks'),
(529,'expert','hqENjj69h1zRxV14rh2TdFJWHwumsoptBkaX6M68SRC5',7,3,3,2,0.036733,'Violet Burst','stars'),
(530,'expert','ngU25njdsY9i8kmbr3YnocacDV3uu32E8nW7Pxr8GsqZ',2,8,1,8,0.039967,'Aqua Prism','none'),
(531,'expert','qNrBrPch6x2rTa5pEBcwRdJbzwbetrVJhULFq7SXw7S5',2,8,2,9,0.040257,'Cyan Prism','stars'),
(532,'expert','aETQYMBEdQsfy3fFgswthvXTkhZjc4xcECV6iPbcmXtE',0,2,7,4,0.067013,'Violet Cascade','none'),
(533,'expert','P7rmFWoNQakiNgNt6JCT6GMsHyfzVh8ce6EcaQ2148sK',7,9,3,4,0.041467,'Cyan Rays','embers'),
(534,'expert','PrnG6512r57Noztq2ei5JzmrYVpCKR5BUtjuPr5PLC4m',5,2,0,5,0.057320,'Aqua Prism','stars'),
(535,'expert','vnuk3YU4wu9o8zfuiyToFK7CyLwFq5MkkkYvo9STTVSF',1,3,0,2,0.040953,'Ultraviolet Rays','sparks'),
(536,'expert','fNsr4QJCL5BsnLvnt7aFiGqxKS8N3QwvFpEyuwWiqxEF',5,7,6,3,0.056910,'Ultraviolet Rays','sparks'),
(537,'expert','qodVYBTB6NaTmAGBX3qyXniJGn4uMtTa6aRQLF5PATX3',6,7,3,0,0.045840,'Aqua Cascade','embers'),
(538,'expert','d6DBCkvFJF64rjkELdWg6xcFKzZbf7efhanYNwexBrhR',6,1,4,9,0.053173,'Fuchsia Prism','stars'),
(539,'expert','pDSPv1PHeEGvGXf6YdzVoThWL7zzfMcLbgxgrPUhz5ho',5,4,7,3,0.044703,'Cyan Slipstream','none'),
(540,'expert','YiSiktWEfbABBuVQo9ma9thcaiTEhFCJwzFxR3iLXpxi',2,6,2,4,0.046030,'Aqua Rays','stars'),
(541,'expert','AADL411wTTpxEA5vMMqeTBih6RLdLLmKqUeDxeHW2dPV',4,4,2,7,0.042317,'Cyan Rays','stars'),
(542,'expert','x6DmdFe65DQs63J9TGXkju1L8QFW7HTrXP5gZgJLVSZr',5,7,1,4,0.034887,'Magenta Burst','stars'),
(543,'expert','GGsxjSbYQy12ZtF381KSmd5UuuCNQiboRDNQqUDsYaD7',5,1,5,3,0.032200,'Fuchsia Prism','embers'),
(544,'expert','WfBu3WerkkLK78DPPMyaFz3usu3ChiuGiA1JP1fnGSFT',6,9,1,8,0.069667,'Fuchsia Rays','sparks'),
(545,'expert','cvVvo5WPzGKTxLcTXFHfoknuUm2X8K89Zo4JfUn5eCBD',4,5,5,3,0.041287,'Magenta Prism','sparks'),
(546,'expert','mD1Rzgm1jJt39vrmvhyRz8fpxFQ5UFTa3Dms7wZ9UaFv',7,0,5,8,0.055587,'Violet Burst','embers'),
(547,'expert','sbnjQm4f52FUi8PitZz9hFimnH8YtD1FDPaz4DKJWW9G',2,0,4,0,0.052103,'Magenta Rays','stars'),
(548,'expert','FRLS1h4aUdHKnftbP9g2k8ucKa8pqbQcGcHTzxkDD17o',3,6,6,6,0.050857,'Violet Rays','sparks'),
(549,'expert','BnJbY3k8o8YjPCYTtDkTCu1HZ84ibgeYvzn49KHLphNh',3,6,1,2,0.061983,'Fuchsia Slipstream','stars'),
(550,'expert','F6i2CasLxxvMDyhC6rWEDKqCfqNchULnAhK2E3xwPmJm',4,0,2,2,0.045140,'Fuchsia Prism','sparks'),
(551,'expert','JDVTnBmpACt2Z8vi3oeH5vpeRmhqnopRe8wSVwtTGek8',2,0,2,5,0.073320,'Cyan Rays','embers'),
(552,'expert','uFb3o8msFAq1SPCUZXj4XQHyJtvcAK8xJEwKH4hiyznn',4,2,3,9,0.038133,'Violet Slipstream','embers'),
(553,'expert','3ihZekjCiTxsm3weyXawbPn7ZB9Vs3XVuBhS3L4X6rRT',6,6,2,7,0.052243,'Magenta Burst','sparks'),
(554,'expert','HM63ypHdPJgoLzYNVw7nV3aZ6yQHkp1qL968NazYuMxT',6,7,3,5,0.037960,'Ultraviolet Prism','sparks'),
(555,'expert','MwT73fc9LMJuntu58xVru3zcakyDLyLmwpc7Txxf51M3',1,7,5,3,0.039890,'Ultraviolet Burst','sparks'),
(556,'expert','offWz3gYYaW45KgG3yA8biQ1hDV3wYESMdAkmzmpsEgn',2,2,0,8,0.057560,'Magenta Rays','sparks'),
(557,'expert','6NCje4T4ebt4bQ4n86AsW3amEWXa3Jyk5fpmKdaXtFq6',4,4,1,8,0.042093,'Aqua Slipstream','sparks'),
(558,'expert','MSKMgUPAf4hEjXnimHkQQJ2ZNR7XoNAy17YAFwXYkk9k',0,3,4,3,0.042107,'Fuchsia Cascade','sparks'),
(559,'expert','ZRBymy7tYs6nuXbXNWoVHD7KN61Hoy9xBxR5BFsU11tN',3,3,5,0,0.043080,'Violet Slipstream','sparks'),
(560,'expert','qhyVpwmpWLH7nvqVgAYkF2KhqPGzk5EVJjq2Z8K8sgFP',6,4,6,6,0.038290,'Violet Burst','sparks'),
(561,'expert','Gscv1e9tydd3JHLwTuYnahbgHaGYJgTWTYNff21RhYUQ',0,3,7,2,0.032537,'Fuchsia Prism','stars'),
(562,'expert','C13vkP7dFsSnDBSgVt8cubuYZRkGb7NNxnBZdtx4vS5j',0,1,5,7,0.047747,'Fuchsia Slipstream','none'),
(563,'expert','SpVp9Qash2x2HvYkb6RFeW5nCaYdanHXDVj5xe7dkEGg',3,4,0,4,0.035380,'Fuchsia Rays','embers'),
(564,'expert','MA6ozFvmmnhf9kFqncoxEFg4A44peB8ceVUTkacLurEd',5,5,0,7,0.052227,'Fuchsia Cascade','stars'),
(565,'expert','H2Dy3XB1F13dGrqT7PLSJ3ZVbDxtAynXU57jko5Q74cQ',4,3,1,6,0.076780,'Cyan Burst','sparks'),
(566,'expert','9vghpBaP5LTdSrQ5StTyX3hwVAQEGsDtTEPgSisT2utY',1,2,2,0,0.053777,'Violet Slipstream','stars'),
(567,'expert','eEAYGPuNjJdrAxN6HQvaQxMSkxBCXknviMHawixeDEww',3,5,0,2,0.048957,'Magenta Cascade','stars'),
(568,'expert','S5SZywZXoQ4UBGqKiiTQaQpDhfD1Du3ruB592RnsyTmR',2,2,1,0,0.052130,'Violet Slipstream','stars'),
(569,'expert','wvn2KB722zb9kqCS4GGJzGYse82yZm4GcYPiBR8TYGiP',5,8,2,0,0.032353,'Violet Prism','sparks'),
(570,'expert','KdeB5iwydJfJsMTcxk88cRPXiMVyKARaSs2w6QoJz66Z',1,7,2,6,0.040567,'Fuchsia Cascade','sparks'),
(571,'expert','2zoc2qgLf4ZDtFUnTmxYiMCeSTQ2AnmKpMuC9jAj4xVr',2,4,6,3,0.037250,'Ultraviolet Fracture','stars'),
(572,'expert','HuDvYW4r3x3izzRgx8XuLCerJ7ggqhwxJfyxPraYguVQ',5,3,4,3,0.038693,'Cyan Burst','sparks'),
(573,'expert','vHuWBCLQBxbYFMzEz9xsBvxhiRMZatZjsDm9FDoRroRu',5,6,3,9,0.030453,'Ultraviolet Fracture','none'),
(574,'expert','Cg3Hwcgo9ZXPMAtg8QC6rBqHwPaTHbmuZPNMZQ5mG5rY',5,3,4,4,0.053973,'Violet Fracture','stars'),
(575,'expert','o3fEGRRDbZMSDTxK1GbG1GzS4jEm2x6qydYo8WizmvL5',6,1,4,2,0.056193,'Fuchsia Cascade','embers'),
(576,'expert','V4VYSsixm9dQVBsuXXkGb4t1VahmpUohsAznAwXRQqfw',5,1,4,0,0.043720,'Aqua Rays','sparks'),
(577,'expert','5V4RWuZniF4ATpUCb8C2dhSVcuPSsgHiBTaqfTAjhN3C',1,6,6,7,0.046363,'Aqua Cascade','sparks'),
(578,'expert','evyoxyJYowmeffBbK6ioAUcXda7Bo6wtKRy7VZCPPFYC',2,7,1,0,0.043797,'Magenta Rays','none'),
(579,'expert','mDF6FphjE9WfJXfaKudt9UGMnXDBbcbgRLSPiY6tPTLV',4,8,7,2,0.057093,'Fuchsia Rays','stars'),
(580,'expert','iRSGpXqHoT8PCkHcvezffzD7NBFvkSn7R4SannH8bBPb',0,1,5,8,0.032090,'Cyan Slipstream','none'),
(581,'expert','hiTjwkG751LFnSAmwtbqqCYdS4HyvnC17cd1an8wjMif',3,8,0,3,0.038267,'Fuchsia Burst','none'),
(582,'expert','pyt3UrsWMV8EYfAWjRCBuhTvtf9yHnyGivNo3rxHJuVj',3,7,6,3,0.048187,'Aqua Prism','stars'),
(583,'expert','oyuuaNUrTm6kk1sYp8qSkJzbZSvuyeTKhzZquDkzwSPu',5,9,2,4,0.045537,'Violet Slipstream','sparks'),
(584,'expert','Fc8mEDiQJPeyunEioCd9vAkmB3bPLvmGAYBtBk2F64Sg',5,5,7,9,0.030033,'Violet Slipstream','sparks'),
(585,'expert','VyCvnwJSHuj4Hm7BJmqtJvGmy3jdDWj2QwqTbQFQ3X2z',7,3,7,0,0.025127,'Aqua Fracture','none'),
(586,'expert','kdxSWv6HcA3tuLp3v9TCPKbKcCp9WgX7AnGDK5mBaMvq',5,9,0,5,0.053040,'Fuchsia Rays','sparks'),
(587,'expert','BYBRZBUX5BEq7RZMExCymz5hEP2b62hPWeFQyyDwWNuF',2,3,0,9,0.054013,'Magenta Slipstream','none'),
(588,'expert','KHsU2fD2dpDxgWS6QqRwN9QXGaDXBYwKZzzs7XWM8beA',3,7,7,3,0.034870,'Fuchsia Burst','none'),
(589,'expert','3SWnvYbTzGRuKU5MwNM2qcB3T1L5iAZxdLMDLw3xgy64',7,2,3,0,0.043747,'Ultraviolet Fracture','embers'),
(590,'expert','NNZnaHMnQ198rBpNy2GnodM34ubcpWzR8P32mKVJFTiP',4,0,7,8,0.041230,'Cyan Burst','embers'),
(591,'expert','M1coMMgSU1FtiRBLNdb5VHg92surXHL54dQVC9LMYiLt',2,5,7,0,0.035980,'Magenta Slipstream','sparks'),
(592,'expert','xNQ4tikxrnTHBjzU2RorD4E2QqRvcKbrg4Bab8cJHnLJ',5,8,2,4,0.035187,'Aqua Rays','stars'),
(593,'expert','ki42kbGWpkPLnn22fPVrRsddwN6a2gGXshViEDjSSuUD',5,6,1,8,0.043563,'Magenta Rays','sparks'),
(594,'expert','Y5mYgtkxugAV4t39JEAkPx2pR1xQrhvbgKeYthAXvB6t',6,8,5,8,0.038967,'Aqua Prism','none'),
(595,'expert','nrgeoytZihi1C1sN6K2d5C4TCZnvpaiQhLZUowTJqy52',2,6,7,8,0.041910,'Aqua Cascade','sparks'),
(596,'expert','x91BLYmDvC2kC5rvZUn4qQ7J89nVvLBvUit8wktftLpF',0,2,4,6,0.076243,'Cyan Slipstream','sparks'),
(597,'expert','DX5fTCheXHdoFmnXNeufikg5F6VhRw2pkkiDySGXD1Sk',6,5,3,9,0.036107,'Magenta Burst','none'),
(598,'expert','hpBSADXm6itg6Qbw8EMdDeL32zeWtrq7ZHEGYU9Areb7',7,6,6,7,0.046593,'Aqua Fracture','sparks'),
(599,'expert','Xcn25JpvWknyPL5TeFebqmAiktevtyaiT2DdyW3k4tMA',3,5,1,5,0.049480,'Aqua Prism','sparks'),
(600,'expert','TBS9BYu61EhjFbtU6gGFJ9QLkbCDHvwgYHTFQi5e7SjT',6,0,0,0,0.040527,'Cyan Cascade','none'),
(601,'expert','BV3c4wPmGRc7HuGthF7h5YfU3WTt6M2ioYnghNX1mgkN',7,3,7,2,0.046177,'Cyan Prism','sparks'),
(602,'expert','64SVuoMyXmFPFheZoYjsRNRyKXbfrfZ9E1wNGMfdoSLK',3,6,1,4,0.045570,'Aqua Burst','sparks'),
(603,'expert','faAP3vz6dBwyFVWK41jAMMckKC9A3xabmJLaCWmXXD5p',4,2,7,3,0.037807,'Cyan Slipstream','embers'),
(604,'expert','hL37i6t9hyWshNH6PX21Pe3gkpn2RRHfcDvmxL7ahJUv',0,2,7,3,0.041203,'Aqua Prism','stars'),
(605,'expert','UN7fkCUqVxPCUqYzEPFxetC7BKcVSyfGXyrtzxjMpmsM',2,8,6,7,0.045380,'Fuchsia Burst','none'),
(606,'expert','Qax2CdzHEXM1fBSceFqNzgrpAuBPM4y8dQqDVo34D3NH',2,2,5,3,0.046593,'Magenta Rays','none'),
(607,'expert','BHrJPudHNtH4VzB67Qzr9K26d1AgA9vfuweWMwDkT4NV',2,6,6,7,0.039780,'Fuchsia Fracture','stars'),
(608,'expert','VSWVCA1ZFjChKNtuoDxBHWH9imz3syw2UWRmVFir9Hkx',3,4,3,6,0.039440,'Aqua Fracture','sparks'),
(609,'expert','GvkxfPJCQNURbtYKLy9FrLBfEQbqRSLAA4cQcoafX2tV',6,4,1,0,0.055230,'Violet Burst','sparks'),
(610,'expert','QMqAhZxZBytKm5a2CLiMXgSdULYqJ1n7SSD5BJ8FGjTm',6,1,5,7,0.037180,'Magenta Cascade','embers'),
(611,'expert','p1b4Y5cYs8S1ix7fY7xY5vyTMHFea28oFiznUSjxMDaT',5,3,3,0,0.056603,'Fuchsia Prism','sparks'),
(612,'expert','n4xDTkUvp4ERVMeXenVGkeoGiYTGi7FUmvKJHKuYuzDd',5,0,2,9,0.045283,'Cyan Prism','stars'),
(613,'expert','q5oSyvgg4PqJT9vp3usNyLKh3dP32fQ6VY3M3CCZkbN8',1,9,5,2,0.035887,'Cyan Slipstream','none'),
(614,'expert','ZYnbNXmERqUPaXMsK32ivvepVX2S54sBc7vQn9qygt57',7,7,1,3,0.043827,'Fuchsia Cascade','sparks'),
(615,'expert','wxAjV7voY6kCAYF39UuqqjZ24WzL7xj5MbFHHFZ2V5ce',1,1,7,2,0.049450,'Aqua Fracture','stars'),
(616,'expert','fULeqk3QJbCDXgjmexhv5wCC7WppaT47ScQLfrDGK3p7',0,1,3,0,0.039367,'Ultraviolet Burst','none'),
(617,'expert','JvLcrAGA9rJzbbnzrCUPLHv3QMmJhGQML3rDWKMT5AvY',1,2,0,3,0.049067,'Magenta Burst','stars'),
(618,'expert','izXfQFYMWxxdq3pj6i3rgyvuYVVxJVxnxHN8GNDAuQY8',7,4,4,9,0.065693,'Cyan Rays','sparks'),
(619,'expert','RrCDSWxrQvMiGmJLmoZBi4DnsDRKFTWA6RrDVnAoDiS3',6,6,5,6,0.044590,'Ultraviolet Burst','stars'),
(620,'expert','WS4La6UH5d1MYKgL85TW1Uuhz8tTWyL9RBaoQJoZLgjG',6,2,7,2,0.057707,'Cyan Cascade','none'),
(621,'expert','zuyjaYoE47Qu2qjPmzwSorMVV63J6xcmAcCczcQmXbuf',3,2,6,4,0.041393,'Magenta Slipstream','none'),
(622,'expert','ri3n6QGqdRr487gsYCF2XFrku5LzLGws8f3ocpNtihpq',7,5,0,0,0.056950,'Cyan Cascade','stars'),
(623,'expert','Y4dB98uMsDBgHS69596QHyP5gnHq2Mb1WbyPqQzo3GKk',6,2,5,9,0.034637,'Violet Slipstream','stars'),
(624,'expert','grusaJNvf4cm8pn3hNaTkpSco1Pnfj66QcYW6NheV11J',4,6,1,4,0.048593,'Fuchsia Rays','stars'),
(625,'expert','n9aKsKZJmUnRz5hC7uojXaTCdLNpsRMfkhaLLU4CgTQj',1,6,6,6,0.047567,'Cyan Prism','sparks'),
(626,'expert','kSPPRikKxup7yQTb9CvR1i6r3j6T2btYmD3B596VoQkp',5,9,6,6,0.036707,'Fuchsia Burst','sparks'),
(627,'expert','NFKt3C5WJJnvcy7pegeJ2wWcjRgNaBD7qTNAY754kh1b',2,2,5,7,0.053617,'Cyan Slipstream','stars'),
(628,'expert','gXTgS51cBy9QtPZBt1WYePr9XgABDfaisE3aUzQkEPji',4,1,3,0,0.038607,'Magenta Burst','sparks'),
(629,'expert','o5P8g3DHYPdZGFLixP8BuJG8Vn7ktTp7YQDJoh1aGvQH',4,7,1,2,0.049300,'Cyan Prism','sparks'),
(630,'expert','qF11e4vw6sNjjjFT7DVfN4R7b9CUrJ1VtWcaojgc9VZL',4,1,3,3,0.053643,'Aqua Prism','stars'),
(631,'expert','iVBx3ECLB7MettB7EVc5XrFw5hiDTAqwsvjAhfMQeHSY',4,7,3,8,0.034507,'Violet Burst','stars'),
(632,'expert','eWkDNreDomWu2gwqviGHv5EyPTDSVn2rxoRih3kfAkyn',4,1,1,5,0.041913,'Fuchsia Prism','sparks'),
(633,'expert','ZSnNq5LwAp3aMr8nu7rtXbm2Y7FxkuNMGS1ZDvqjhjMp',1,0,6,4,0.035893,'Cyan Burst','sparks'),
(634,'expert','V9KwuvxxptL7yJm9ekzHtHZUCeDLd4aCA5KnaKQDp6zE',4,3,4,7,0.041417,'Ultraviolet Cascade','none'),
(635,'expert','pHoFHvp5dKSN7so5vM1qq35u1L7dFsPfpiXbLRgLKTLZ',4,4,5,2,0.036387,'Violet Prism','none'),
(636,'expert','CzZ7EhkrY4oztZMrQKhL36Cy4iZAx4F49buDoaJxhbPf',3,0,2,5,0.051050,'Aqua Slipstream','none'),
(637,'expert','YohFiv5xJBSq5iuL3d6kGhVFHdKmG95dZta36c67WA8p',2,8,4,5,0.049540,'Aqua Cascade','sparks'),
(638,'expert','qnNjZEezMBvhEvZm4i6mETPew67hQWWPnasjV3ADGe3K',4,9,4,0,0.042947,'Ultraviolet Burst','stars'),
(639,'expert','ygiRX3bxb6SWuXZ129FgomrDGoFWYj5YGjEJeen7RVF4',4,4,1,9,0.041313,'Cyan Cascade','sparks'),
(640,'expert','Q2gx7C8UoZycsUdqwAUNhsKghskZEvTmeh3kFgsbncev',7,3,5,0,0.047970,'Aqua Burst','stars'),
(641,'expert','yeQ3GbQQVs3AcKqg3N4euKWejkWjFk1yknf9atN971u2',3,2,0,6,0.029007,'Fuchsia Prism','stars'),
(642,'expert','d9rNaDRdgqHiFYJQuFBvw4bvfnMU3Z5YyPTnj7Mq2rcr',5,2,0,0,0.032027,'Violet Burst','none'),
(643,'expert','3xg49sMiUZVgvRnStQyXeFaRLjTSby91mnFPz1LPfHAv',0,3,6,0,0.045030,'Fuchsia Slipstream','embers'),
(644,'expert','XWD8e5CNBHj6Toe8RZzp1yJngte3CmXHz1wsR5c6c3df',5,0,1,9,0.041553,'Aqua Fracture','stars'),
(645,'expert','uofeJispbaeLcb5LZofyNEx1gjN1y9WHjPZugkfcBiNJ',3,9,1,9,0.038420,'Violet Slipstream','sparks'),
(646,'expert','zVBsnuHck5wjxXK6MZBach6iLY7PKXM4AVqGjFD3taHf',4,1,2,2,0.037493,'Violet Burst','none'),
(647,'expert','8UpfPQgbTQKBshtgsN4xw2Ze9f5vxkGyGLpVcLMefTui',3,6,5,0,0.038207,'Cyan Slipstream','stars'),
(648,'expert','dHEZYmHGjKowunCdiE8rMmHE18Th9qyZ11euEV6FejxB',7,9,3,5,0.030730,'Violet Fracture','stars'),
(649,'expert','4ShUvqedwj2WGGSK8Au96ng213RDWZY8o2h9fanCepDh',1,5,3,5,0.048793,'Magenta Slipstream','stars'),
(650,'expert','b2HAGyvyzpnqjCjTHX6HuYUjUhD4qzhwmKRh8fFUmaWK',2,4,0,8,0.033357,'Violet Burst','sparks'),
(651,'expert','ebEthyxdyHAdG693MukrpDbagYkZwoZpUsBKyP68yeth',5,3,1,8,0.034560,'Aqua Rays','stars'),
(652,'expert','kLcKQU7bTLfosoe6nKezWxr7gCLCthqUQxfKGQgqYmwN',1,8,5,8,0.048900,'Violet Rays','embers'),
(653,'expert','cm5AxoJ7ozioq8xZuMtKwkyYTYw3ciYBnQAY7nxEY4Nz',7,2,3,6,0.049843,'Violet Slipstream','sparks'),
(654,'expert','jqFt77WfLmLbzQFaRZBMmCuk2CcWaPKM41nhkjzzvzwN',7,0,6,7,0.042947,'Magenta Fracture','stars'),
(655,'expert','Ff3Bcj65os135QLxaYBbsUpZTtL7g5wNXGSJe9Gbgmfn',7,0,3,8,0.059383,'Ultraviolet Prism','embers'),
(656,'expert','3fyqHbNWXbTuspWP23sX8AZDZUbZo3beDNsGSd3Bv7d7',1,2,2,8,0.044893,'Aqua Slipstream','none'),
(657,'expert','R5Ly7L2bRqfoXsTtdbEGc8JLKZhcLbXkZc7RKQcaYsnG',0,8,6,6,0.039777,'Fuchsia Rays','embers'),
(658,'expert','VCehRz9ChWfYJPq49mm6ia7AYC9JUpB7AjZDjnttJ54M',5,9,7,5,0.048503,'Ultraviolet Fracture','embers'),
(659,'expert','Ux2df4tm3RFyHbtNLNVEiFkTgzNyxB5qAXGv49jngd4X',3,4,4,0,0.054943,'Ultraviolet Prism','sparks'),
(660,'expert','jMdM8FoAykfbtRvKsepxNKwG8Nc5WHiCx8SX4devdmLK',4,1,3,4,0.031040,'Ultraviolet Slipstream','sparks'),
(661,'expert','5cDTsSk8wGPH2e4Z6zpuKne5Wg4tEiHaznXJT6wV5WS4',0,1,6,7,0.054753,'Magenta Fracture','embers'),
(662,'expert','dXFfPrueNHDiheyLCw9XhLGRSBNPseM79kuFzRQDiGQG',7,0,0,0,0.036667,'Violet Prism','none'),
(663,'expert','FGY82trVgK6pPcyPK7xCt2ckVkjGPfNjJBmQgfWNm6Kc',3,3,2,4,0.047753,'Magenta Burst','stars'),
(664,'expert','ariA15em36ib6qhvjQqTeq4X7w72p8R1Di75mxAoPXQA',7,4,0,2,0.039757,'Violet Cascade','none'),
(665,'expert','kPwVDMruP2Syh2y6WbLbqNdWjgynN1e8hrpKVC54wa36',4,8,2,6,0.032630,'Violet Slipstream','none'),
(666,'expert','s8txssKiiNkwyVJfyi2ePFPvYAGnqXzkSts6q1Ujwwwx',1,9,7,9,0.066710,'Fuchsia Prism','stars'),
(667,'expert','Ny42YMvdG2taKbeExJ9PxDSfMVRfY49dSzon3oErMJ8i',0,5,6,6,0.057377,'Fuchsia Slipstream','stars'),
(668,'expert','uCM2agW2WnVRtbk2NJjrih7Tx1YYBtrJaJXKxptkVNzm',5,8,5,0,0.052320,'Ultraviolet Prism','sparks'),
(669,'expert','Sb96fDCxyWoGDvHWVXR5K7EVCUcMCYzspWPYMAWiL12f',2,6,6,0,0.051160,'Fuchsia Fracture','sparks'),
(670,'expert','R3HncocXyxCuhPeuCE7qxGuJ5zyVatK1Eb76XuTzwWiX',7,0,4,5,0.041150,'Aqua Prism','sparks'),
(671,'expert','6RCYvpveZ3RR9fTuyXQ8JEzFhE6m8bJZ1r8Absz1Y6fk',5,5,1,6,0.040407,'Ultraviolet Fracture','sparks'),
(672,'expert','shc2PwRRncXZ6BWhAKS4cxYoFHjxFHDBBjRAgncpziaq',4,8,1,6,0.045010,'Cyan Cascade','stars'),
(673,'expert','cim4L2Lz4s3EJQKjbe4BLVW2nCHQEAAn4ewocdNpuDEF',5,3,6,4,0.038960,'Magenta Slipstream','embers'),
(674,'expert','yqiSQkSiuTCyeb2tKHUjJ2ME92nFQ3zAGiPGz57NABYG',0,1,7,7,0.040327,'Magenta Burst','embers'),
(675,'expert','vofUk1nfTakbxBWLoX133yrhzb1CCioSueJmEUvFV7zT',4,2,1,7,0.033067,'Fuchsia Cascade','stars'),
(676,'expert','cmhBMKbuXkJ9YrLVpNup2PbPjhehpXhyrsSuRvLXVeMX',6,0,2,9,0.031483,'Violet Burst','sparks'),
(677,'expert','qNwr3Ux1pmCAikQ1ZMTB7bSFFL9Kbgvp7pG2A3dj5Xw3',7,4,1,0,0.033180,'Aqua Burst','none'),
(678,'expert','kLZUDgyFvZb62dirbw96sKdYg18Yu6socncuGnJz6qSF',0,0,6,4,0.035353,'Magenta Prism','stars'),
(679,'expert','zyaiFUhth9ze8MhcvHbNNaGNewitG9uYnt8nJwZ1vnfn',1,5,3,4,0.049937,'Ultraviolet Burst','stars'),
(680,'expert','2wAjshPTmFPwgudJ2dJRBri2mA2vbMd6L7WVaUmxZFKa',4,3,4,7,0.043743,'Fuchsia Burst','stars'),
(681,'expert','8DAaJs5fmzeXaTbi2owbRzWTncnL3DLkbG3RYN6M5e6D',7,3,7,9,0.080493,'Violet Fracture','stars'),
(682,'expert','yzScgCC9FA16HNv87xyBxDUqzKT1jt1wpvAaNcxw8Q1m',5,2,3,0,0.031580,'Ultraviolet Rays','stars'),
(683,'expert','snxnXg1xvtkip1ifdgwJ5XNYcdrwW7Mnq6pk6jaE5gM6',2,2,2,5,0.040973,'Cyan Cascade','sparks'),
(684,'expert','AqoKMjPb7KpMqMyHxnwpsXMvoQRRLQ3wyJj8qWmStrsd',2,1,1,0,0.048937,'Fuchsia Prism','embers'),
(685,'expert','1Yjoa31RgAC6kVD9Fwdn5KhdbhUbM7mYVVWPxc4ANeMs',4,5,4,5,0.044253,'Aqua Fracture','stars'),
(686,'expert','2oawrbaJaUMuKSrVLLqwVMijVz62F5xec8yRPAV5gQCy',1,4,7,0,0.062197,'Violet Burst','sparks'),
(687,'expert','cCxrjNvq2Fa8qGi5QbkDJe3E7P4ZiKZ1cjKheRLPPHqx',0,9,1,2,0.045587,'Aqua Burst','none'),
(688,'expert','KVRc4S4RMLHoViLueyTEgGfRZqgi8hsDw7wiy7kqqADc',4,8,6,6,0.073870,'Cyan Prism','sparks'),
(689,'expert','qc6tPmPeTsnT5Mda4ghFcy6HTCRcpUaezhfcgfe1fRqY',2,5,1,9,0.036867,'Ultraviolet Slipstream','sparks'),
(690,'expert','igGDXDtUhqqkJANSgzhq314k6D83i6GAkiaKLzwaPnze',4,8,5,0,0.043800,'Cyan Prism','stars'),
(691,'expert','uKWAaQQf7Pbp1QyVStbLTYjTrCkPtHm8K4pEAq5H9dfS',7,8,1,0,0.053630,'Magenta Burst','none'),
(692,'expert','2HZtFTeqtugq8fr16KTc9tmN32f6Q4XHrBXhM1cSRi6a',7,6,2,4,0.041147,'Violet Rays','embers'),
(693,'expert','e6WpVkEi7U2pxokbHNLoVJzbFwiAyEUePx96MtKfQcwz',2,5,1,9,0.038613,'Fuchsia Burst','stars'),
(694,'expert','57UbFn6a2BsmErjEKtWCczj5EjjE3qm2SkoWyMhY8sqq',1,1,1,6,0.033093,'Cyan Prism','embers'),
(695,'expert','rme8TZFzsSFfvd42fUDwzJx8taVVKRQAt7RCZYVS1Qbs',0,7,5,0,0.037333,'Ultraviolet Prism','sparks'),
(696,'expert','wRtKDn3ZhXbpxR47rn1Qo95Bv1AS5VoDavWJU7HhJxuV',1,4,1,0,0.032153,'Violet Fracture','none'),
(697,'expert','jrd2CZU5NbzKnUTv7MmisAWZHDSbf5EBdwjDBR9iDW9u',3,9,2,7,0.050973,'Fuchsia Prism','embers'),
(698,'expert','NRah25z5mXbTa8Eyimf1wTPX8PTk5WhmLGzFm17wMoHM',0,7,6,0,0.049047,'Fuchsia Cascade','stars'),
(699,'expert','s9HYyJ4rKAVsrZ3rbDpjchSk5Ltw41KMsDRGFB1s5yX8',7,3,6,8,0.032147,'Cyan Cascade','stars'),
(700,'expert','NnxZmaMcprrJypensnUrnk6z1zbj9s627qCT8ehxeTop',7,3,2,3,0.047997,'Fuchsia Fracture','embers'),
(701,'expert','JPuhCjpq5dzLiS6eiCnwNWSxJ4hp8f5BuzZW4QyPbBM3',0,8,7,0,0.053373,'Fuchsia Fracture','stars'),
(702,'expert','Zp7HptGNw1erhcUeHCBhBR2XYYyMFjV5RtSTw7KvCbiz',5,9,7,2,0.045147,'Ultraviolet Burst','stars'),
(703,'expert','3UXJVpJ8aPoyjB8DYujKgFGTmbTykMi6YwgocWw9QXNh',1,0,2,3,0.047967,'Magenta Slipstream','stars'),
(704,'expert','GKczuA54RGctrZXnS79NaQWzgNxcvn9kNN5DvJUY826u',4,1,2,8,0.046687,'Violet Burst','none'),
(705,'expert','Ls5kTXNK61yPzUUmubA716EdKWwqDzjNCVKwMu8pdbR3',7,8,4,4,0.058770,'Fuchsia Burst','sparks'),
(706,'expert','c37WwLnQWzd5T7pN2buNJNnzUoVo4sVV9BSh35GkA7qN',6,5,3,9,0.042853,'Ultraviolet Slipstream','sparks'),
(707,'expert','5JDCgmLUUsawgWP2Aohy5E9L5ztv157r6xJqgCSwNJqW',6,5,5,0,0.057987,'Cyan Cascade','none'),
(708,'expert','1hyoEcWAuRBJrF2KXEoggUKLHmR8SzHMjEj1QtzxGYEU',4,5,7,9,0.035243,'Cyan Burst','none'),
(709,'expert','XyE8YQ9S6uzcyHJioh4kHb3gVG6ZL93JKT57Ku9qi1kf',4,6,5,3,0.043680,'Aqua Prism','embers'),
(710,'expert','YUvK7rcDaGWqALAkzbc9xAPkMtoaVmCXr4spnhWZykdi',6,4,1,0,0.049173,'Violet Fracture','stars'),
(711,'expert','meHe1J7pLUpN5xnRmBkfpKHeCRQVC9L5XgSYRtbxroP5',0,9,5,2,0.039143,'Ultraviolet Cascade','sparks'),
(712,'expert','ZwDWJfyVyzrGrmp9U4yQwR7MFhpCD6vSr8UZCo3cEyLC',2,6,6,0,0.069500,'Magenta Rays','sparks'),
(713,'expert','AAz7TEiPci4SYTSndDQWpvjuNPrpxbEkyc73FYy4smWr',7,4,6,3,0.055063,'Violet Prism','stars'),
(714,'expert','6MsyVTMYSDUq56eqjJFEwmMMjg1kSoz5qL1u9HJ6a87v',7,6,0,5,0.036297,'Aqua Fracture','stars'),
(715,'expert','ijSsaqMk6nZpqc8qJvmfKBMDyr5Bwm2qGqJBruxaBzwS',0,7,6,6,0.053827,'Ultraviolet Burst','stars'),
(716,'expert','57ZJ33ry49pCtprJYAsJ1hgBeVDQAwpw2c5bN5GpvgRX',1,0,7,6,0.045697,'Ultraviolet Prism','none'),
(717,'expert','JRydbLfVnTS4pWpQNUa5k3yM9XKYKhgiWmXuUKdwHMPa',1,2,2,4,0.052973,'Aqua Slipstream','stars'),
(718,'expert','i95W54zkHELxHL71FNcV3UAVAQRNJa9KbLYY1jvysSsH',4,7,6,5,0.036213,'Fuchsia Rays','embers'),
(719,'expert','spByZLs1tk7qLiD3cq8vzpc12G4zq7z9k6w94G7m6K2k',0,5,5,6,0.029740,'Cyan Rays','stars'),
(720,'expert','Bhy43s882R4F6pD2Mj2Rhr3rRRKn7enSYrLhRVtDncsR',7,8,2,2,0.053790,'Aqua Cascade','sparks'),
(721,'expert','xyMvFj1HZ9FXUpx4D4763b5sxVu4perghjBweuzHFrip',4,2,2,0,0.070527,'Fuchsia Burst','none'),
(722,'expert','u9hTwHzSnJoxKc7nEgRrZZ7kDc19rUsoGGPkis22owKx',5,9,7,2,0.070883,'Ultraviolet Rays','sparks'),
(723,'expert','eRzSqceRp1x6HzbpFyX8B2RQUpHVFpFmDtQJetwomKt6',4,8,5,9,0.043573,'Magenta Cascade','sparks'),
(724,'expert','BDBDQXFHvdJvfdKE3roK9PSuX7bJLijDa417ZKj7cW3C',3,7,7,9,0.043677,'Ultraviolet Burst','none'),
(725,'expert','KshviCMFbyG5qow4dmzY4sm7D5cXxgSxFMvbCQN8TU1U',6,1,1,8,0.032120,'Fuchsia Burst','stars'),
(726,'expert','MdM6LaD9XncCzjgH2FHDreUXDzcHqK7SXgnqTUhkHNya',0,0,0,9,0.044637,'Ultraviolet Rays','sparks'),
(727,'expert','2uXfGBcWR1pwrBnxyTQ12X78Vzj4DHt3aXq1zr255zZ1',4,5,7,0,0.047237,'Violet Cascade','stars'),
(728,'expert','JMSdr2DGRsnJv1UHYaHjKwMd6uXjaFpeZiRYcYFCg5WH',5,5,4,3,0.052510,'Aqua Rays','stars'),
(729,'expert','c19s6fkGCvSYhzG7rHsoFUUwVokAsBZsiVRjF7YeW89b',4,7,1,6,0.047160,'Aqua Cascade','stars'),
(730,'expert','Qkb2jsU9TTUcnZW59nZahurkMNhZmWBK9VrRsHz4GhX6',7,3,0,5,0.046300,'Aqua Fracture','stars'),
(731,'expert','YWSfYz676TEwNMfocWTMrAULwX5zs8JczHzJU6ZKwsV7',3,1,4,0,0.045463,'Fuchsia Cascade','sparks'),
(732,'expert','Y1y6mXW3cZqDTybK1SPi4145iQArxStWvbmNQuASkw82',0,5,2,8,0.052020,'Cyan Burst','none'),
(733,'expert','NWDkZRswxaPMoH9ekczpWA8o8yC53NnXDSzygSEKYqQG',0,4,2,3,0.035213,'Violet Burst','stars'),
(734,'expert','dJrs42MfG4ZyxeVH9ruWCReFfnu7DUe4PUoVQKX7C6vH',6,6,1,8,0.043043,'Aqua Prism','stars'),
(735,'expert','TER1Uo8etc9LHGtQmBEgud3zebYHxGkQkz9isNofngV4',1,1,2,2,0.036680,'Fuchsia Burst','sparks'),
(736,'expert','743m1NySy4qKAXo7uAtZEMgHpjJ2FV6nbhL9m6H2vZEx',4,2,1,6,0.053363,'Magenta Cascade','sparks'),
(737,'expert','kFrPxVPfAJFiYqZZKGeXb5pCwKCj3YtkS1MgyX7qmqoo',0,0,6,6,0.031440,'Ultraviolet Cascade','sparks'),
(738,'expert','Jr7PNXLa4Jok9RZaWJLBrKg1P2Q88QHLq5Y2oRe8bAf2',5,9,0,9,0.038553,'Cyan Slipstream','stars'),
(739,'expert','RDSf2jEULB1VFAVnpi2ma2enMLafWgkNZKVZ2ksHPFqy',6,6,1,0,0.057877,'Aqua Prism','sparks'),
(740,'expert','rmUvbmEwx9PRPfx2hU8pN2CX4CNjwWo8gCG9QRxsSfDR',6,8,2,0,0.055597,'Violet Prism','embers'),
(741,'expert','qX2jZDbf5uAGZoKtaHfd7g84ntvJ5KRp6zExLESMSMkR',7,2,0,0,0.050147,'Cyan Fracture','stars'),
(742,'expert','bD6Wy1bN6wbSCU5np7J5pYMaRv3wGUHfqMuHMUpTV9K3',6,0,4,3,0.054510,'Violet Slipstream','sparks'),
(743,'expert','nMDu53EeTWzoeiLgaFFg72pgA3qeuNoW6D171F3SEPCb',5,5,7,0,0.052573,'Cyan Slipstream','none'),
(744,'expert','PEWzDFBFZHytTV9yE6NGZTDBnVs5DEJKvoDjN5D67qHb',5,5,0,2,0.048327,'Magenta Slipstream','sparks'),
(745,'expert','W2TH1wv4RPZkg12HKivt53MLuADkKydiNnMwpWrQCcFg',7,9,1,0,0.054880,'Violet Cascade','stars'),
(746,'expert','iy6XRFTKkUhpzZYKqJBxVGjd5NcE9FuQA5GyTt8ScZqE',7,0,5,2,0.042613,'Violet Slipstream','sparks'),
(747,'expert','xqTbrT565bMFFaVH4V1V3wCWDtpbC7vPdSokFHyvBntY',6,1,6,5,0.045673,'Fuchsia Rays','stars'),
(748,'expert','xtkcg3aD6yXcsqf1hPtstBeuJZXwMT5BzqgnBiyMfH7o',3,3,6,5,0.059637,'Ultraviolet Fracture','stars'),
(749,'expert','KY6fr4d4NeVAfNC26aLUuRYcP67SeexT1MQNxKmLTSDN',1,8,2,6,0.047080,'Ultraviolet Cascade','sparks'),
(750,'mid','HrehacGs7g4dDcmBj6YBHEsQLWNghBMQJrX9Syw5mfLv',3,0,3,0,0.028950,'Terminal Blue','none'),
(751,'mid','wLcx1f2qptzJzgCVjRjbT4eKJcDgbiBGjc87hHXNoQKs',7,0,5,9,0.051560,'Terminal Blue','none'),
(752,'mid','AatGeiJCGLFN8fFj4Y6DbYd8St9PjsTchyoBu82Verec',1,0,4,5,0.040760,'Deep Signal','none'),
(753,'mid','3X4zur7sr2uoVSVPKmyPweAL6ePsxCNdnTHgQ9pUaxRo',4,5,0,2,0.041535,'Settlement Violet','none'),
(754,'mid','8JQEHEydgC5VEUHvEXJPMFnS6PpPFmJbGe5i2SrUA5Dt',1,0,7,9,0.033560,'Ticker Cyan','none'),
(755,'mid','fFxD2cPXrkAVTWcA2FJXnUybrebgAWg9b8vuNHm2ta3s',6,2,7,2,0.039745,'Deep Signal','none'),
(756,'mid','SqkLEMnhk768XaRVXLKYECRR9aUbCPSYfDEs8umyb4FG',4,3,1,8,0.058785,'Liquidity Teal','none'),
(757,'mid','HPcce2JR3eLB7ywEu37xW1bQWf9wrZX1eiwJCMfX1p6H',2,1,1,7,0.033465,'Index Indigo','none'),
(758,'mid','5kVWspzCiao1RoakGXXNNxvmFv19qd7rCVcDmtgD75Vk',6,9,1,2,0.051945,'Ticker Cyan','none'),
(759,'mid','weDa3voNNUDPGKXqkhAHvhRwH3UZc5uBTsjXogGo8Qx9',5,9,2,4,0.048600,'Index Indigo','none'),
(760,'mid','NyjiFC46vhiebuxyUYkwESpPSjRnEgRhRr3BjVJP7ze4',4,1,6,5,0.044465,'Ticker Cyan','none'),
(761,'mid','R84a9JqeLEJvBuLLVrNpgSvaQZqWE1bPTwotARrMPrYf',3,8,5,0,0.046145,'Settlement Violet','none'),
(762,'mid','Ec7LcCo8vW8q8geLtbGWQBftQPKF7gba78npDRjvSduk',0,2,6,7,0.050095,'Deep Signal','none'),
(763,'mid','hzjGdmpihpaXXrMN5Jn8Q98A8CcTqrhV7exzB67DnUS6',1,7,3,4,0.055770,'Settlement Violet','none'),
(764,'mid','27ygpgVBUMDMHQXT2bfW9UonoS8UEuHcSohJfjscd1xE',2,1,1,0,0.037270,'Terminal Blue','none'),
(765,'mid','fP688QErqKmNnAAcyJTjkJSGg8wENNGhLNni7xMGDkex',1,0,5,0,0.049650,'Liquidity Teal','none'),
(766,'mid','f7yMHC5pWYR6ChDvy2HkTnjgiqa1ubLrqGALcHz9jAPw',5,2,6,3,0.037700,'Ticker Cyan','none'),
(767,'mid','VUVyzbM4isPu65pKHRPdNu4o7DNLrGks7uee19mmLJCc',4,9,2,0,0.045480,'Ticker Cyan','none'),
(768,'mid','uRyXHibw8qfeR6nXP91H8bCAeqEZcJqzUmCBaGtUa8m3',0,8,4,2,0.042160,'Custody Steel','none'),
(769,'mid','T8zDWnv3VKf9eBm2Ms5k2XpH3BQ92RLkaqAgBMXG3biP',6,2,1,9,0.056830,'Ticker Cyan','none'),
(770,'mid','8EQvxNtRdexP4HxSAv5cvL2vsVRAuGQYtYa1UwRTbupo',4,4,5,5,0.039350,'Index Indigo','none'),
(771,'mid','8Jd18RvXQ7EnkzBFVdNoLkJ7VUmdxP5adrMD77hCnndx',5,9,5,4,0.048545,'Deep Signal','none'),
(772,'mid','hsWyCJNXUf1qXAZ55uf5gwjgPuCeAbedyrMpEN41J4cJ',4,5,4,2,0.034240,'Ticker Cyan','none'),
(773,'mid','qP5FZC47j9zpfYm3mzzWbNEBEnS8KyYXxoY25Lpf9tBt',7,4,3,8,0.078140,'Liquidity Teal','none'),
(774,'mid','Ftobgg8jwdVDiiPinC2USnExv9UyoAkU7BEJFnMTF3xo',5,8,7,4,0.055565,'Deep Signal','none'),
(775,'mid','KA9b859dnpLRWunmphovpW34bHJFYcQicf5eK9jSuckN',6,7,7,0,0.039785,'Index Indigo','none'),
(776,'mid','91T37Y8kbvDyL84r5jxQ8Stry3tqem8ABGKYUXKKZFu4',3,9,1,8,0.058080,'Ticker Cyan','none'),
(777,'mid','k13iN5FjnSF2EH28rtBPJAakvq1dZBFU7rFCx7KQS1Sg',7,7,4,2,0.056395,'Deep Signal','none'),
(778,'mid','E22zoLQSSB5aBTtNwqAfxSxMWNphB8kDAZgz53AAE4rS',2,6,3,3,0.032820,'Liquidity Teal','none'),
(779,'mid','C1zbFHRkbmGeHgHgUh7jSHDu76gdsFcLgWJax6d8sk1T',7,8,0,6,0.052275,'Custody Steel','none'),
(780,'mid','nJdSx6q232S5H7sJaUvnXLMZUhxqugiLZKdNvWj8a3c5',0,7,0,6,0.087630,'Deep Signal','none'),
(781,'mid','rMD4FGCY7Yp8cuyFm3h13LZPv4qa6Eg7E6SACR5cotrQ',4,3,1,9,0.043020,'Custody Steel','none'),
(782,'mid','AkjeScHJvJp94aULeZ2XHrbtRaaHCN6teRxqp8YHAc3t',0,2,4,9,0.040735,'Custody Steel','none'),
(783,'mid','LGZ4GcnzQVcVvEhN5ZLVhEusR6HsM3GhtnMV4YDvdxVL',3,2,7,5,0.046360,'Ticker Cyan','none'),
(784,'mid','XiwZEZQTTVY7sFnxTD2BcerJR9e9LUUx2nXHRQ5TWNgn',3,9,5,3,0.054745,'Terminal Blue','none'),
(785,'mid','eDHQU2zPUj8htrRdyUC4aXXK5rM2FCmmEFniL4qJu1Fn',3,2,6,4,0.042500,'Index Indigo','none'),
(786,'mid','PLRwKNorfgYLaLRMLX52C4jKbvkkfc9kEifpS7gGcXfn',0,0,7,0,0.060690,'Settlement Violet','none'),
(787,'mid','TwfKMgr1YHFJU4h4oXnLKmBUEG4UVnWy1sHG9K8N2xTg',6,3,3,3,0.098580,'Settlement Violet','none'),
(788,'mid','WcCAJEo2Pi7qnckmSmfzpaqH4dBLaoRiEubnvA2Sd3aU',6,8,7,9,0.054370,'Liquidity Teal','none'),
(789,'mid','565wKdueXLrUB9PexCQiaCG5392oda5uMETDLxy4JDpe',0,5,3,6,0.063685,'Liquidity Teal','none'),
(790,'mid','2839Zx9yftx3ma9aQmKHQNTdApzQUcJw2PaZaBJkr8eK',7,7,0,2,0.049635,'Terminal Blue','none'),
(791,'mid','t6mkQdr9RuydHzMm1arvoLkoPeRAiCFv6W5ERwGU8FRT',5,6,2,3,0.041510,'Settlement Violet','none'),
(792,'mid','T6iDcNC6NThR3bqFUt1kmaLSFFgCYfeT57btECz61YtB',0,4,6,4,0.045330,'Ticker Cyan','none'),
(793,'mid','qNupNopY1Nkkabt1d4yta2vMTeiDLJRCNbvJiNzUQqHK',3,6,6,9,0.048970,'Liquidity Teal','none'),
(794,'mid','E6TzcgR6FMztgb5v2EHNMqCS34vgH8oKUQiAWWNDGqA8',5,2,7,6,0.044420,'Terminal Blue','none'),
(795,'mid','9kgPvrST4oBDqFLD3XUHHfAVCqkKdQvugtJr1wDbhGX7',4,7,3,2,0.061780,'Ticker Cyan','none'),
(796,'mid','uCCGknM8WMhYcbEjAwjjzbdkKNNBd2GVbRzGZW4m1Br1',1,6,2,5,0.027400,'Deep Signal','none'),
(797,'mid','2STALCUZ4yuXMU5ARZmsT6pzs3hzMWhCW1ytnb3Nr8Hd',7,9,0,8,0.032080,'Ticker Cyan','none'),
(798,'mid','1tbjdX5HrEDZezNsqmotHTPWnKn2FhdsHYsaSSiywXEQ',3,9,7,0,0.072385,'Deep Signal','none'),
(799,'mid','xMcPApPjF4jrMsJ9PGnnTuVzxL2yCH6vnbXeeoALQv3Z',7,4,2,0,0.043660,'Deep Signal','none'),
(800,'mid','9GR7dQEtsFRYMVcS2uLuJVAAXKdm9AwLNTiow4Rbd5gx',7,4,7,9,0.053870,'Liquidity Teal','none'),
(801,'mid','zVepvYxEUdAJVNfE77DxcbR1iGqJmgADkftnW7wzLQC9',1,6,4,0,0.051685,'Liquidity Teal','none'),
(802,'mid','vqkpfWHQ9KtGHijDEuTsEGNouXgWgrSr2QHGvKprN1vB',3,0,3,0,0.052720,'Terminal Blue','none'),
(803,'mid','apMe6CjprzQLijyUgzY9yPaUHC6v3sMCNLtdh8eLAP4J',3,1,4,5,0.052580,'Settlement Violet','none'),
(804,'mid','5a2GSXfp5b67jyVA3YqgCPrsve8dvH4Zo1wWK2atqRL3',5,4,0,0,0.040080,'Settlement Violet','none'),
(805,'mid','kkEZfz9fDLQ7L72X9hSrSsSyJsieCgx1mCk3srvp92wr',7,7,6,9,0.040635,'Terminal Blue','none'),
(806,'mid','hAegtttJCQmyi6yWh9c1jXJFAh1hBFErDndKeqRSLzbs',6,9,5,6,0.052320,'Index Indigo','none'),
(807,'mid','7748xLW8coJ6m5yLEV2FzXEyb158rYL7irogsp4ygaW9',7,5,3,0,0.035560,'Liquidity Teal','none'),
(808,'mid','4CGRiqjHVpJeHtBchut2S7fxfZDrk34H5kYsjAQkaLR3',0,2,6,4,0.039610,'Ticker Cyan','none'),
(809,'mid','7MK6tiUmSJ7rkKyALifkMp2XU5QEbRmxfS1yr4rGMdd6',5,7,4,8,0.043200,'Ticker Cyan','none'),
(810,'mid','XRi6BQqroRbjrFVJp8qAEYG2WqZX9oksMUqxpqrYKyHw',5,1,0,0,0.043140,'Custody Steel','none'),
(811,'mid','UPniQLJMEPpDjkz1TTMapNfPiZbBsPVGHCVXDLC5RyAy',4,8,0,3,0.047840,'Liquidity Teal','none'),
(812,'mid','qEHjwLe1cvPtq3kUziA8tZqZkHHptxTm8TeziMXT6Hid',2,8,6,7,0.050105,'Settlement Violet','none'),
(813,'mid','3va7K5UqGDXiPSHeGKEEXSaMF92Hno6LcG7z69zBZugm',3,3,1,6,0.051300,'Custody Steel','none'),
(814,'mid','2zVBCBJuJffodqyPHry7tuHsEm8wA8hkXEkMEtLKo34h',7,3,5,9,0.046330,'Terminal Blue','none'),
(815,'mid','7dBBFFY4BKw2c9F8aXemEobfK6YvUFRhRRrAjhcVcTGb',7,8,6,5,0.033040,'Settlement Violet','none'),
(816,'mid','NF4hDqtUhUNb6kMSEmtRGNJp5a7f2WN1GBoR53uYgAok',3,8,6,4,0.047940,'Custody Steel','none'),
(817,'mid','C6wyrs2mCMWyR2jSD9ndX6UiBJDab5ZBhT8WrmLrGmzW',6,5,0,8,0.062465,'Deep Signal','none'),
(818,'mid','gJNTKKtnPQwWPoLTPa6KzjPbsSJUWvZ6AEuL8pnRnqmj',3,7,7,4,0.038100,'Liquidity Teal','none'),
(819,'mid','PhrYqLJM2gUeKvHgSfmEbDMpW33RzCWpLVafUKRd58Wv',1,1,0,8,0.052870,'Terminal Blue','none'),
(820,'mid','ZoqouAawBLMtiMmmGgpJkVHphyZa3Dw9EqH5TPL9dRrW',1,5,1,6,0.049500,'Deep Signal','none'),
(821,'mid','2TpHghJVuPCixoC2mvBGgF73uSXEwL8XFGGHmfT95D1t',3,3,6,0,0.045185,'Terminal Blue','none'),
(822,'mid','QZwQ5ECV4JnfWQMxKYxTkCmkEyHGWQkJNSsCzXvD9qrK',3,9,4,5,0.039610,'Index Indigo','none'),
(823,'mid','9SXfSvgagR1KtVSry6CrjX4Cg3kh72Kn8Tav5NCHaUz6',4,9,7,3,0.044230,'Index Indigo','none'),
(824,'mid','c9hjqGWk5kmkbw4j5Gh9kkibHX5NekYKS92tkYBbUNgT',1,1,6,4,0.026850,'Custody Steel','none'),
(825,'mid','Bj9qFg73gZcozjx5GqnpFabVA4GLJFmWfA2HvcwNsFEU',1,4,6,7,0.044330,'Ticker Cyan','none'),
(826,'mid','wkXuQPvuV4aTSeK3Thzoec5LmCGssbDbqS4Pjt6vn6gv',2,5,6,0,0.049070,'Deep Signal','none'),
(827,'mid','XnySw9wS7BKwiGDHStc8VgQ8Gc2qExZGkzjxP8ZGo5iv',6,8,6,4,0.053110,'Settlement Violet','none'),
(828,'mid','k5bf2We3wEWVNURbn3PVgLWEC12cepC2bydJGLzWQyF8',4,0,5,3,0.045900,'Index Indigo','none'),
(829,'mid','WiGwk29NTmxTWCXXz2gRWRaLLjseegZg3acKf3JwVug2',0,9,0,7,0.043965,'Settlement Violet','none'),
(830,'mid','cxbhcv2wZZinuu5waJAVdZ5htHmCN112A6pjcv5EF6mS',3,7,5,6,0.032200,'Liquidity Teal','none'),
(831,'mid','YpB74KT17mPnfYNhFFYugqJKH4ybrupNg383ezrugy9f',7,8,7,6,0.043040,'Ticker Cyan','none'),
(832,'mid','HLobv7qjvByKGqHP3M9nQr2Z7i4QLRw4CBVtrtpbBRDG',2,2,7,2,0.040560,'Settlement Violet','none'),
(833,'mid','A9FP1NwveWmiEF9FNrT7wBshHcmg6DZa3Qx1sMrWRb8y',1,3,7,0,0.049300,'Settlement Violet','none'),
(834,'mid','FZeRubkUhuHz91ohQyaxF51L75r6u8dRbDrpaf8f7yzy',4,5,1,6,0.038030,'Settlement Violet','none'),
(835,'mid','XVQmdYNGRwowBczRXVGWXUNrFBvFU1uxRpjtSH6w6CEg',5,4,0,6,0.048820,'Ticker Cyan','none'),
(836,'mid','nmEm89vXPkLKumF9RuozUes5jfJ72Y1kZsxXiSXG1u1e',0,7,1,9,0.031560,'Custody Steel','none'),
(837,'mid','wQta3VJ36hrY7vZ3AgcDT9os12N5iEF8mF2dyJ2SM53k',0,0,6,9,0.055520,'Deep Signal','none'),
(838,'mid','soaHkyZKCXpVJoqr5owwRdcU4bRkuE4W1YrseQqXeBNp',6,5,6,2,0.091710,'Liquidity Teal','none'),
(839,'mid','n4GvsUjVM6T8JtRs77TfwYbBAK2uwEyBzTDzuGSDzGK7',3,2,5,7,0.036150,'Deep Signal','none'),
(840,'mid','unZXMrEDUHwwiALhyU4gSuS9xWymfTYujsm5FHTPSDcb',6,4,7,0,0.043660,'Liquidity Teal','none'),
(841,'mid','wSn5RQ6piLihwxfA6WU1vMsW4icP5CZnNmSNhACpRBzg',7,2,0,0,0.031840,'Custody Steel','none'),
(842,'mid','4Zc642H7BhmwJHzsjHZuF3iiky5q5BhYE3Rf4WWqCdRN',2,3,7,8,0.043715,'Liquidity Teal','none'),
(843,'mid','vF2YjartacvRqsxFdTy9vDXHSUojwiv7gnnS6zJyvPyV',4,1,1,9,0.056305,'Index Indigo','none'),
(844,'mid','eR8P2tWyq8MMn5vcLJdkQrfUp2ZLAg4rfVEWFRo4xzL6',0,2,1,8,0.053310,'Settlement Violet','none'),
(845,'mid','Z6RuKwURCsqweHhwf8UoTyxuKwd3vQRAzGVnM3rfpcW3',4,5,7,5,0.051320,'Custody Steel','none'),
(846,'mid','aA8x58NnXLJyGvZQBDUHsvvfvaJwNjqLXwH5ihAXMVp9',3,9,3,9,0.044970,'Liquidity Teal','none'),
(847,'mid','V1mZp16nFiYmB3ZVATAfvoRUHj3kLeY8WNEXffQeicpg',6,6,0,9,0.028920,'Settlement Violet','none'),
(848,'mid','QQHiPZcnfLpW4CYxZ7T6NEvp6shnDDwWPsJUxcrP92jZ',6,4,3,2,0.047055,'Terminal Blue','none'),
(849,'mid','jtirnUaQJETn9KkiXUSkKCXtxem9pPTMcs8M21Mpfv9a',0,9,6,4,0.075860,'Custody Steel','none'),
(850,'mid','ejQNziwXZU3MnKwfNNFih3gFkLBCCWyXkVEhSA8dGGKt',4,8,7,9,0.047560,'Terminal Blue','none'),
(851,'mid','LiqAyHm4ZQ5PNkRaXffVAuC64QRkp1xkY2pdaG3jv3uw',1,7,3,6,0.044600,'Terminal Blue','none'),
(852,'mid','BkQSvMtrRNAQbPChSvsem31zWpkWjf2egMeFqdzPomdD',1,1,4,8,0.037840,'Ticker Cyan','none'),
(853,'mid','XwHwDVQYRCjhYJMpdsLxUhpihv25KjodubhxTtHiW1Hh',1,9,6,6,0.043730,'Index Indigo','none'),
(854,'mid','msH4Dh2vp4LfzgXku2mjkyZd71EcWSqCdQwBANS3Zy5F',2,4,0,7,0.041450,'Deep Signal','none'),
(855,'mid','in9jFgd9dFprDpFrJkpNqrkhDABzuCZy9FpEVf99qLZ4',7,0,1,4,0.026960,'Ticker Cyan','none'),
(856,'mid','j2vaXhpmLGp2dpoGu3xLpxX37nZqdtXRADuqf8XvhGwD',0,7,3,2,0.042080,'Deep Signal','none'),
(857,'mid','qw6pdqKraboQVUt5VxdQxTPnxvDnV9bn6ntyLm2V2kq4',6,2,2,9,0.041255,'Deep Signal','none'),
(858,'mid','pAesdqnBDzi1TVmfTH1rL83J68DwePav6T1pidt4iK9b',0,4,2,8,0.063005,'Liquidity Teal','none'),
(859,'mid','B5DTvfjAGsYGpdzHVEpirJ3PeW5rzNW4CSLnXb94y4Y4',7,3,7,9,0.050415,'Index Indigo','none'),
(860,'mid','QAMa2H63fY63mz3AfG9BJvTebasr84aq8XvZnq6tJ4PP',2,1,2,0,0.040060,'Custody Steel','none'),
(861,'mid','L5TdHpReHtVM1NNHGCGCdE5SPNZXX8yqCtyNydcMaA7d',0,8,2,3,0.051685,'Settlement Violet','none'),
(862,'mid','Q2urvbwk7hSFKF4V8QDcJKgchTB8popyPC1JocgCL3Lh',5,2,5,7,0.047460,'Index Indigo','none'),
(863,'mid','DbAWbShg23LbJoqxEdnxHdkU5WHpU7cMAW8JDrmrPh5k',7,7,0,8,0.049945,'Custody Steel','none'),
(864,'mid','n4xg7um96yBUggk2Kka8JhwxbBr8RrnHAwM1M3cD8kcZ',1,3,5,6,0.052615,'Ticker Cyan','none'),
(865,'mid','hhUnvRhkijxV16J26TJHYb45YQShXErj2BfE9Hy9sbMr',2,2,7,2,0.040600,'Terminal Blue','none'),
(866,'mid','MpNaFZUhUcmoHrpX2KTKFgZ9zUrYxVV7JgHH9qC2mBrw',3,8,6,6,0.043050,'Settlement Violet','none'),
(867,'mid','NYY98w9eityj7sqpbq4JMEe3ttcve4cDStbM5H1Ui7hc',2,2,1,9,0.042165,'Ticker Cyan','none'),
(868,'mid','i56Br5useDVxUvFFVjeYhYP9B9NsLLZXRaZsB9hZYB1u',7,5,1,5,0.043430,'Ticker Cyan','none'),
(869,'mid','5XRJ9RzusUj7XVj9aCLnbXoj6DJmKbGTwa6r8dTU6VWc',0,6,2,0,0.045155,'Liquidity Teal','none'),
(870,'mid','Ltwn3fjx2MuytFBoXp4CSKAdQJBepuaTtt9q4KAriU5A',5,5,7,5,0.040465,'Terminal Blue','none'),
(871,'mid','9hYAFGM8zNHFSHimDftS8DqLUXQvoq3Swqna73QZpnwj',1,2,5,0,0.040020,'Ticker Cyan','none'),
(872,'mid','c2mEmbpt6a689r4Qb4ntsUtqQfAdfsUxJKz8GEZyYvMK',3,1,5,0,0.048650,'Settlement Violet','none'),
(873,'mid','UcXPEhNmyEUgoL5AHwmpeC8ofAYpdhtMfKTirwK7QH1y',4,6,4,9,0.041820,'Settlement Violet','none'),
(874,'mid','x5s7qcGy6xVrNi97y56jJvfBzkzULqzJUxEF2qD7F4TY',7,1,1,5,0.031960,'Settlement Violet','none'),
(875,'mid','pXrJ35cHBf6kko6jM4GA6BafoTg7dVciBtVAjiYwYoWJ',7,1,4,5,0.051855,'Settlement Violet','none'),
(876,'mid','UcAPPkGkF9cjFF5QvhR5K6z8mBjjpQqMWkWkYaqKQSdh',7,1,7,9,0.043905,'Settlement Violet','none'),
(877,'mid','rKyKS5ePzfRnaeMqTgLkSNooD3H9pe2eXvPiM45fxfPH',7,6,3,5,0.046100,'Liquidity Teal','none'),
(878,'mid','gvjHnv4qF7TdWW62Atw55pdXnb3WhKZ8Q1rUKKjFEQWi',1,3,3,0,0.071820,'Ticker Cyan','none'),
(879,'mid','JYHdgpCLSMo46YuSuAH7sWsze3UuQrF1XJgVexmx9yfg',1,2,0,3,0.026200,'Ticker Cyan','none'),
(880,'mid','WbHGMBuzk6m9NLGs8jYSKq7nVzwfTkCBoKTfmAKUQWNF',1,4,3,5,0.039970,'Index Indigo','none'),
(881,'mid','EKHRHumZr61bdh1oTydXKDi8U7587oPE51Khp5UwdbQS',0,4,3,3,0.068050,'Terminal Blue','none'),
(882,'mid','KJRfMR6vtxFVDpGhH9EPxxrZygJL84N11uVdcGUh3GTn',6,9,1,0,0.039850,'Index Indigo','none'),
(883,'mid','vMoaEo4uiqmRsoKP2g3mQUrHXNBZkwwz2oqv7KbxpUpd',2,3,6,7,0.066770,'Custody Steel','none'),
(884,'mid','mEqzuFLHfHBoZjCS5P6hdMbXwbBsL7aydhL78mu1Km52',6,1,3,8,0.036310,'Custody Steel','none'),
(885,'mid','vBMtWE6iUiw8iQQVxCakPAWBiLDY5T9j5ThsxHGczrJa',1,6,6,0,0.053750,'Custody Steel','none'),
(886,'mid','a6Meu3SMPtrgvnqBUKtjZAn1Mu6iQP3DY8gwzPXM6wuc',1,2,4,5,0.035710,'Index Indigo','none'),
(887,'mid','XaCV5W8jUaiBsh3zKLzSMx53qQCF7z4VDVDf3Fu7nth4',2,7,1,8,0.052865,'Liquidity Teal','none'),
(888,'mid','FLQ2NqkbUqfNZuiCZk79aumTGvVdX9w9LjpKcZg2TC8q',5,0,1,2,0.051245,'Terminal Blue','none'),
(889,'mid','XCRWuY1V4PEe7HnyDGDFt7TEK3heEDr9UequjyTv9H1w',7,1,1,3,0.043680,'Liquidity Teal','none'),
(890,'mid','4QgQCsCw3HpqFWH1A6cjjy3xFVTHbyPwd19bKCE573J9',6,6,4,3,0.033360,'Liquidity Teal','none'),
(891,'mid','hj516zPA79m2PHGpc6oVxJkWzt9x7LgArwT8hDVne5Qi',4,4,6,2,0.070920,'Custody Steel','none'),
(892,'mid','6ftrPr5wG26Hasbdf7TK8zhXYDcVVe5BoDg9mWUmJjME',1,8,6,0,0.040690,'Index Indigo','none'),
(893,'mid','pNezczHLPbK9ZwJU91bwfd1ArPNTfcnvquwapymK8mX4',1,0,0,0,0.040200,'Settlement Violet','none'),
(894,'mid','S92dByGwuC4sCKzmRhw2ZkM6Tn8p63QybPVFZPuvQa3b',5,1,3,2,0.041840,'Custody Steel','none'),
(895,'mid','Yie2n5N1fUWsc4owSBgHiP2wqQT3tuuxssuTRq4oaCz7',1,0,5,9,0.054970,'Deep Signal','none'),
(896,'mid','geNexaYeEvQGoPv4nbphGdRCxnQ7EskwFNHcnxUiqRSD',7,0,4,9,0.062440,'Custody Steel','none'),
(897,'mid','L1qwQhe59Z2v3F1rhcUyL4RXuy4GZDSWKMK84vSwvvxY',4,0,6,8,0.043320,'Deep Signal','none'),
(898,'mid','WTHN3KDUACEt5uxaVaJyH5mu3g5r5mUWQcbkiozLY8ci',2,9,1,0,0.049145,'Deep Signal','none'),
(899,'mid','RBpXYoCgznFjQQKN6MASYnxknDThM3NWBWXVZuDH49DH',1,7,7,0,0.046930,'Custody Steel','none'),
(900,'mid','AFW7kV79ZRUJH6vUEtMEmgMaQu3ZCDpcazHxsYiKJLAn',6,4,0,7,0.047440,'Custody Steel','none'),
(901,'mid','aeQYRRSMt8HSjyDVBUJbXmeZpDiZ3mNeJAz7anyn6rnH',4,7,6,5,0.032280,'Ticker Cyan','none'),
(902,'mid','MSGPAxLtVZyWvM5rgHi5Q2t16JRepnH5eXq9oEJ659Zp',0,1,5,7,0.038290,'Deep Signal','none'),
(903,'mid','A63DHZwPAZEh1p6gChFH8QBG9MJqsnnsQ8k48Xmb9piH',2,5,6,3,0.074020,'Terminal Blue','none'),
(904,'mid','oPrvMfmwVsqWL9SdHHbPGw6haB2pBujYovLYLcjiXe3a',0,2,7,5,0.063765,'Deep Signal','none'),
(905,'mid','WsDD1ERZn8yCEukAXsj5h6pm3juQSfjLhbVbDMAorTN3',2,0,3,7,0.027040,'Deep Signal','none'),
(906,'mid','5gAUh99S2b4sEkToChxiQZ1WxQ933HD5at9Rb44KEbWY',7,7,4,9,0.040980,'Deep Signal','none'),
(907,'mid','DYNjAWTaR2dngYWMQFdPoRH66Cast7WySAjU1kk7Vxyv',6,3,7,0,0.049215,'Terminal Blue','none'),
(908,'mid','eGxK1rkzu9Fucc174w9JGteRCsmjHerbW3KW2c1mcZmJ',1,5,3,5,0.031380,'Ticker Cyan','none'),
(909,'mid','uwbQhS8cyantc6vsrnJVE4X1A58SBtuJQ3fsXhB8d78K',3,7,1,7,0.044100,'Terminal Blue','none'),
(910,'mid','1vWyTFq34scxiGuCZU89DUA1J2jkUJNXHGQhAMFzdveg',6,1,3,0,0.032320,'Custody Steel','none'),
(911,'mid','oXBwrxK7V2JZVQpKhiYSugj6YjHsSS7r9ez1zYpDMX94',4,7,6,7,0.042030,'Settlement Violet','none'),
(912,'mid','ZLgeyqdLK3ikma9BNUipxobVaGj7ve4KGkNmZ43Dzfrn',3,1,5,0,0.052430,'Liquidity Teal','none'),
(913,'mid','yqms5JY5MB5JuCwucmMkyFrznaLQsDWrK25ASK7GjBv7',5,4,5,3,0.058430,'Liquidity Teal','none'),
(914,'mid','tMMRWfqFVCe9MCgaWAJwmUrkUuVrnkjrPqGqBtyApTEX',6,8,2,0,0.039860,'Settlement Violet','none'),
(915,'mid','C3Pyhrhi75okLANqXjd3LSpocEWWP1vXsfqVKMjRXygc',3,8,5,7,0.044640,'Deep Signal','none'),
(916,'mid','B3w5pkNZFshxcrSJiRHc6n6eP2wmaJfJ6bs8kytHSwCu',1,4,0,0,0.041580,'Custody Steel','none'),
(917,'mid','8KNEMifWjpVw26vbA4iJpurWdu9shuf7gunpZbgUEe97',0,5,4,0,0.039710,'Settlement Violet','none'),
(918,'mid','ETrYyEXNR6LkAbbAXFzKafgcrqdjTTcay5bR7aay1b5Z',7,3,1,4,0.037580,'Terminal Blue','none'),
(919,'mid','pJxVJtEdHaWVg6dkfKou4X9Wixo6dioy5UAaZeq6NFTb',3,9,2,2,0.060440,'Index Indigo','none'),
(920,'mid','MrpF5L6Jv2vhC761pm5fjpDxuDFfy84d1CmZD2cKbDpG',2,9,4,7,0.040460,'Ticker Cyan','none'),
(921,'mid','VqBJCfbffHAnA4YcRRYrE9FVTCuXH5rbgDMRcqLVVSDA',4,8,6,0,0.033100,'Liquidity Teal','none'),
(922,'mid','v21Wbh1ha1seNyNJr9mQsG1Rx4XRBcC67KfqakSKxG7K',2,8,1,6,0.032800,'Settlement Violet','none'),
(923,'mid','rFp7nNqfKQyiqb5GMF6J8Baf7TUqFevTr6EBgMYttk2T',6,8,1,4,0.042435,'Ticker Cyan','none'),
(924,'mid','FN5GBbvNBbQRAVvPM5U162eeRNVB5ZWsVrmQqViG6S3X',7,5,7,0,0.042230,'Custody Steel','none'),
(925,'mid','M8EJJdQDuj1GL2w1PYWsoVowUfTNba764cS6UjUHpRDq',1,7,5,0,0.050830,'Custody Steel','none'),
(926,'mid','HnENUBN3xcKKK4pDKfwqksVXuNNr4LbP5W5TTYv8bGuF',5,5,1,8,0.041115,'Terminal Blue','none'),
(927,'mid','szKsKV7ZkkTRWYMa4aHjBSAd1wMCgMKhux2QV75UCZFa',1,6,0,8,0.045560,'Index Indigo','none'),
(928,'mid','3m71Wty8qWYKm8C3MwyNm7oQLzBiJRWQ9LStj7UyWNJ6',4,5,2,2,0.035140,'Index Indigo','none'),
(929,'mid','SiDzyowSEN6Budjw99VBNBzPuq5zbSx35e89A6SwjTgG',7,5,3,2,0.098100,'Liquidity Teal','none'),
(930,'mid','oE3jqiJDqR4LiSnBvVQbncRFC8tGhuuvBU59Gt4B9kij',6,8,5,9,0.042640,'Deep Signal','none'),
(931,'mid','fL5MaA1Cbj4LW5oomGos68XMUVfCgcLTNbhRG9v1p59y',0,5,7,0,0.071640,'Terminal Blue','none'),
(932,'mid','PdUAoaX1x1opBWAzq4ERW1QPK9fmtW1zzxQ1jRdPhhdW',5,1,0,9,0.067290,'Index Indigo','none'),
(933,'mid','D3JGUN5QwX79SUnmkNpQUULNSBkg5oc5b2LvD5jmzTSG',0,2,0,5,0.053420,'Deep Signal','none'),
(934,'mid','qtQ1tyf6AgyXmRdHUE8z5raH7E9saFhoTDNv8A2w2bMo',3,5,6,5,0.057635,'Terminal Blue','none'),
(935,'mid','nFhQgJGg9NoMgDx4M84XWCQVEKEzfyV4kBHzsGPgw6yJ',1,4,3,9,0.046070,'Terminal Blue','none'),
(936,'mid','4xdb4CGVjELgxratwrGdgomsZ8cwcefvqy8S3Mye1qxj',1,8,1,9,0.044350,'Ticker Cyan','none'),
(937,'mid','jDVXnP5t1tqWpzXNbXmr8ZFtaNjiUadWHhUDdrVbyu4G',7,1,4,6,0.078525,'Ticker Cyan','none'),
(938,'mid','LVm8U1Cc71PCThq7y1jvUmDVTJdzkoYfRf7s7hvXHdRn',6,3,5,3,0.041370,'Liquidity Teal','none'),
(939,'mid','oqrAcJG2XbxkKqu4v5CynA5pmRSzYF3pFYFV9z1NtB6v',1,3,7,8,0.084170,'Custody Steel','none'),
(940,'mid','DxpYA3xa9AYikcikqDdRbEq2S3vUQ7qAxHmgS1usHCPa',6,4,3,5,0.041860,'Custody Steel','none'),
(941,'mid','kSyq7NcX8w8DZzhUzhfGVcw5tSegeGH5ZjDwenz6qucw',5,5,3,3,0.044390,'Terminal Blue','none'),
(942,'mid','NoDt74FtDAPumZSY4JoLkRdnxoU3UoyjqjwoUUK1y3F5',7,5,1,4,0.031600,'Deep Signal','none'),
(943,'mid','qM71VfqZWvB5bV2vwSptabXtLekhZScir5PHJ5k9UYjp',6,9,0,5,0.051290,'Index Indigo','none'),
(944,'mid','UJRBCwxGkD1MTP7kadWbvf6qGrRShiAUop8xB9Cp84rS',3,9,1,9,0.033520,'Terminal Blue','none'),
(945,'mid','TRtTUnNgeJHRvkdF5zhy8Xa1t1t93uHruQ75bKySRbmv',4,7,0,5,0.045965,'Ticker Cyan','none'),
(946,'mid','cNfdXRHjHTQJpRgsFWBKVJaBWKoz9gwhzUtg9daaE42y',0,6,5,0,0.068640,'Ticker Cyan','none'),
(947,'mid','LX8PzZYAX1aLc1JZenqYQev9ZwPtuLyN1ZimTZKJ3vPy',3,3,4,4,0.055295,'Deep Signal','none'),
(948,'mid','dpGEd7Xn3YAMKb2h2Pu616LdiMXoxzZdn6j8xyrEYobn',0,6,0,3,0.049385,'Terminal Blue','none'),
(949,'mid','XnE1oyJr9eLHMyE563waygTQrTDTM58VuEM3yWsPGJM5',3,6,5,3,0.042080,'Settlement Violet','none'),
(950,'mid','oW9j4aCtDU57MtuhkRzJ3AxMTMV33EtzcsJ5fdHpEHXu',0,4,7,0,0.038130,'Index Indigo','none'),
(951,'mid','PqKFun9VQN4yakPmmsZv9JA62V4NG6QVqRKrsiEnGBbK',5,6,5,3,0.047440,'Terminal Blue','none'),
(952,'mid','xp9qfPqQ8tjTnop3Tx5ReZKEzgLRnnFwhZoHaebeKBDE',6,2,0,3,0.049430,'Index Indigo','none'),
(953,'mid','BgcX5D6jEpjnbmGrcydNzNdJN8pqkYyBBeRCgqBXxScx',7,6,2,4,0.036960,'Liquidity Teal','none'),
(954,'mid','2R4hiA1KWMeKAt7vytbon2YFwS3ZVmez9rM9RAhhifu1',0,8,1,2,0.046350,'Ticker Cyan','none'),
(955,'mid','rBjV3m9sXoyZrS8MaS2MRSidavSf9SGGHPVe5WBwK3bT',0,8,5,0,0.055670,'Deep Signal','none'),
(956,'mid','KFn7tsvGKwzwVDKhhGme6a2Y5yyBhwfG59buHjjieqgY',0,1,7,8,0.042740,'Index Indigo','none'),
(957,'mid','AQJETrPg66QSrGfihhkjmfywkaKx25K1BaA8YgkgxSPJ',2,5,7,3,0.056525,'Settlement Violet','none'),
(958,'mid','dEzEtM2ew5mbz4wtqogwJtd1XmuWtURGW1css1JZ4qQv',6,1,3,0,0.047360,'Settlement Violet','none'),
(959,'mid','sQm5CX1iTAenBZL3c2t6CC9RbKo5rrVuWVSBHkaStK5r',1,9,5,5,0.044580,'Index Indigo','none'),
(960,'mid','w8j1dQ1RbXUtPzKRKDobaq5WrPzjVPac1WzMQU4CQRJF',2,4,4,5,0.042080,'Custody Steel','none'),
(961,'mid','vnuZBUugodmN5nNVJ97CXgeouUynYwo5R33nzFV1Y6D6',3,5,1,3,0.032880,'Custody Steel','none'),
(962,'mid','pbnaZqbp8HhMLrJesYKDq1ygEch99bWNaqoqn7W9tgmN',7,5,4,4,0.039640,'Liquidity Teal','none'),
(963,'mid','bTxeZR9BG6yq8nUG7zZSpcFDifMf3KoSa8fRtNhB4ciQ',4,8,2,4,0.085395,'Ticker Cyan','none'),
(964,'mid','Kf8HvQwtrkSWUACy18KqHTfws76Ckzm1AXdsDcxZ7PYi',6,8,4,0,0.030440,'Terminal Blue','none'),
(965,'mid','wyEQr92w5U1mcxp8qeEzemUfaWzTkxdXefvCNAf8ag99',0,4,7,7,0.048820,'Terminal Blue','none'),
(966,'mid','petY5vtoUAn3DFpsAgLCsiMxiyvjZ6GzRK3qKSbEfUuW',4,4,2,0,0.057030,'Deep Signal','none'),
(967,'mid','bYeiEv7j8AoBLgnKqjsFpbtjvpqeyoDUYRx6zwLYA1U5',6,5,0,8,0.047870,'Deep Signal','none'),
(968,'mid','v782wVsD7WFYp5cAooesyb3cDVtCbTNcJvd9bgpHMUDL',0,4,0,4,0.046225,'Index Indigo','none'),
(969,'mid','x2GRsQKEfBCiriMayiHKdWEcVSrAVwZDcdukBce2iXbv',1,6,6,6,0.051465,'Liquidity Teal','none'),
(970,'mid','xa6rgWZfY3rpiJNPPuXZkZEckBiztzAin55dE25bxtQM',4,2,7,5,0.033965,'Terminal Blue','none'),
(971,'mid','QaYYbMkWngZd4jzb6ELaFeU9DzjuDXXiHJZv8yVDdhK5',6,7,4,0,0.045390,'Deep Signal','none'),
(972,'mid','qALuWt8yrca6fVnaA2ohNZtUoW1N2pocNhQkDX7Hkng8',1,8,2,0,0.038360,'Liquidity Teal','none'),
(973,'mid','R1HK4K8Lnoi2UL4WhEEvQtqr6o75JH5ENSugsRZcreCK',7,6,3,7,0.050050,'Index Indigo','none'),
(974,'mid','69EB1PdXouGroNPNJnothGLZdxnricL4f7puPCp4oL3D',6,8,1,8,0.037200,'Terminal Blue','none'),
(975,'mid','c6ikW2nySDPykYsdiyvMmpovirrRfW6oGuou2dWsv6Bu',5,4,2,3,0.037800,'Liquidity Teal','none'),
(976,'mid','uMDctB5DqC6ad1yRKGGsoWhFSN5QBMBzp4mHgZi9q5XS',5,3,1,4,0.059370,'Terminal Blue','none'),
(977,'mid','9KDcmPVJqnTNdBqvNHqJ8FWmDj2Gjjzm6doAPZikgjcW',4,9,2,3,0.035360,'Index Indigo','none'),
(978,'mid','NcDHvoRBVxq9WVeLDRUTzVRQrXosdBXaQCHdKZQRbpzx',2,6,6,6,0.051370,'Terminal Blue','none'),
(979,'mid','jqkz4MHCJ5QikZ4Gn2SMfVaCPFbqj1YYC2hPUTSLuRXB',5,6,1,0,0.044540,'Ticker Cyan','none'),
(980,'mid','8ZE87XWvjC8xK5uDR7o6Hj1jJSNMYNi7YKeecYgwJCe4',0,9,1,0,0.032320,'Index Indigo','none'),
(981,'mid','M4vwtsMobPxBqzp51QxHGxnY57ywUY1K1NDXmAPoiC5t',7,8,0,2,0.044710,'Terminal Blue','none'),
(982,'mid','cEcGUSJYKjVRG6vCChzWaf7ySaU33NUhwhGxU96B74B2',1,5,1,6,0.044140,'Liquidity Teal','none'),
(983,'mid','ywfzM8A2zLhLbAJykCNYVsxXWEUYcqFFtNtPZymqiVRW',5,0,1,3,0.031080,'Terminal Blue','none'),
(984,'mid','KPoxqdUk3mxdXmzZwszY42w3GFd4jGMdMMziAw5J6EfU',2,6,6,6,0.033640,'Settlement Violet','none'),
(985,'mid','Ce4v5hGdhNrgEoRkhjyQkyhFs8D8MoBU2cnKGTaeKTxS',1,3,7,2,0.033800,'Deep Signal','none'),
(986,'mid','mC7pFV9Md2Xsw2uiqjE25tjeB86vTMmWhN1ifoRtaBcj',6,3,7,6,0.050390,'Custody Steel','none'),
(987,'mid','53CLHH5DWToshhfSCwV3VPGFUZXKS2dy8YChVecbqhps',1,2,4,2,0.038560,'Custody Steel','none'),
(988,'mid','r7hQE21ddHNUY6bHFfxFTtGQTrXKUiHmFvHds7hWYKK1',0,1,4,9,0.025760,'Liquidity Teal','none'),
(989,'mid','ZZwhxLdRM9KeAdNQZYk6UhDibMKZ4Qxb2GhFzunJBtE8',5,8,5,4,0.065940,'Ticker Cyan','none'),
(990,'mid','4uW4pAcwZ57SMxmRs4ybWW9W9ThjpdrkFphdVoxj8XfK',3,4,4,4,0.051705,'Settlement Violet','none'),
(991,'mid','E12rCGxBQqWuLyJVwVwny7kfsqb2Ltr51AcLXDUnxyQx',6,3,5,6,0.046525,'Terminal Blue','none'),
(992,'mid','toqWDjEP9bCz99PsC8ogvJvBhaqTvUppy4AJrFXwAAjB',4,3,5,7,0.034375,'Custody Steel','none'),
(993,'mid','QntkvsGduY2L2W5sy66CDUSx33KGJ9N6C5Xo6g258D71',4,4,7,4,0.064870,'Settlement Violet','none'),
(994,'mid','o8A4ShVAkDEangTu4DcwCXwEmA93S46f7gddtsW6Pq71',2,3,2,0,0.026320,'Terminal Blue','none'),
(995,'mid','czA6ziuz4FxNVoCL17fEt8ma7WfNntFS6xRgrpVMr7Ut',7,2,2,8,0.062400,'Custody Steel','none'),
(996,'mid','o9tXgchVyXwKNKwP9P4gVURsevDpoM8nBCJAfoGCSt7F',1,1,1,0,0.048140,'Deep Signal','none'),
(997,'mid','kEbcY7W5bqM78oSekpgguybzuPGVfEz6NTBDyef3HZv3',7,2,0,6,0.056810,'Terminal Blue','none'),
(998,'mid','Bt16rFhTykme7cXvhGx5DsUo3aV5c71q43UCknY4vBVx',5,1,6,5,0.050915,'Deep Signal','none'),
(999,'mid','spYa2nHCpdFRq6tdvnsbVzjYXhULN8DpT7Fr6wGmaahS',3,0,4,2,0.049500,'Liquidity Teal','none'),
(1000,'mid','zVGawRrbjnFpC4VKSKe5XZnvs9sK4zJVHptxi8jXMKbN',3,5,7,7,0.049100,'Custody Steel','none'),
(1001,'mid','vJ4n7iDn4XpVH75seHrHfLB8hy5LzNWbqBQM2abjCgtw',2,0,2,0,0.055690,'Settlement Violet','none'),
(1002,'mid','ShkFP6SCth99uLczZLxo38PZBvg2MeKGrHLFYBetabTt',1,0,5,3,0.052615,'Deep Signal','none'),
(1003,'mid','9GTD1Z5xR73Y2oYFm8cyHkGM2KKh5b2gCizHDiM7jF4Z',5,3,5,2,0.045545,'Liquidity Teal','none'),
(1004,'mid','BBN3EmSDe1XTap53Zx7eXhfLDLicWWdmMjLqpPDtPQYZ',3,1,4,3,0.045250,'Index Indigo','none'),
(1005,'mid','9WkUDGdxzkeRsgw7iTRpvvEDLsSjgL6acRijoo779E4w',3,1,2,5,0.040820,'Ticker Cyan','none'),
(1006,'mid','oR9sP88mUogDztFgHyc3evTjdrBo7jhiqjjJjuN6gydJ',2,1,6,0,0.047390,'Deep Signal','none'),
(1007,'mid','THpvrnPmXhztkjHyzzmCnqiRouA3eYdTVpZ2LWeqMMew',3,9,1,3,0.040360,'Ticker Cyan','none'),
(1008,'mid','9BCDn7MT5sTZx68K6obLrJLugJMxUKxX8gvumd1WKPu9',2,7,3,7,0.033090,'Deep Signal','none'),
(1009,'mid','NWKWxcHZdH2AKT43AyVwBPaneGiQCQksLFjRdb8qLeRE',4,6,4,9,0.048660,'Index Indigo','none'),
(1010,'mid','oDmsuS33qVBX9WVDkytXy78LKHswg5iL9853pboqReM8',0,9,1,6,0.038860,'Ticker Cyan','none'),
(1011,'mid','76fg6jMKoi22R7zEPN39YB2AXLcvv7d2o2bvhRFaGmPh',6,6,4,2,0.043500,'Ticker Cyan','none'),
(1012,'mid','FCQH353dRFyxLjntzFjMziGfN8hNf2UYnHdVAfNQH32n',0,5,2,6,0.036880,'Custody Steel','none'),
(1013,'mid','6jZrobSijZkhBqP2nAx9WjA3ddh6LzLYZezmrAb4TcPm',6,5,4,0,0.036480,'Settlement Violet','none'),
(1014,'mid','przaCJfzYPjWi8jRxW5jjbq9y6XnjKRAW3aoy6SfUNW1',4,9,4,6,0.034560,'Custody Steel','none'),
(1015,'mid','1CJsxRhWwUj5yiTFa2R1sidFsrHRJGpceuNq6fd9LTGK',0,3,0,6,0.068430,'Liquidity Teal','none'),
(1016,'mid','Ymcy2XsPXfwUzvG9VtZF5AjYHNusuEXZJvspSv9iUdLq',7,1,1,0,0.043935,'Liquidity Teal','none'),
(1017,'mid','nvnqgxR8BY8ohN1xXaGvtM8YrbA5DbB7Aj528TRea6nE',4,5,2,0,0.034060,'Custody Steel','none'),
(1018,'mid','ABrgjYpE64tzZNbvhdyqBXw6D9R8hkPLSZ3yBYwSMNrQ',0,3,0,7,0.042000,'Index Indigo','none'),
(1019,'mid','rQc8B7ZXVSRZJq1j9vneiqJ98iHzvEQKVeb7JkRgJPhn',3,0,6,9,0.069000,'Index Indigo','none'),
(1020,'mid','cQeZtbn6Pi4cwE4n254DGhpqJSnXNUrpvb3BnVKuyUvF',6,5,2,8,0.055395,'Ticker Cyan','none'),
(1021,'mid','o3n43S47XmordFMh7DWt9K7ZofreFzsjLgvQZZGprf2g',0,0,0,6,0.049350,'Custody Steel','none'),
(1022,'mid','41HUb9h5EeEtv6a8jjH4P1aRDnKDLJUSodHKNNawbuH1',4,6,3,3,0.054665,'Liquidity Teal','none'),
(1023,'mid','gT4rUMgztS7Z4F3EH6jFNRafZPfvsjiVQtSAPcx1vgMn',7,1,0,2,0.044120,'Index Indigo','none'),
(1024,'mid','jVRR4z2F851XSmG94Ju19KZQwyGYrt8vfZskRZzuAiHd',5,9,2,7,0.050265,'Index Indigo','none'),
(1025,'mid','v5TAN6MrR5C41Qfk3X7Vb4aSYyMESrJPMpQaqKCWwgzT',7,2,3,5,0.041920,'Liquidity Teal','none'),
(1026,'mid','LkHHS2jH3HxiXQh8X1QC2LDaxNiVh1xSRspBTABwetUx',4,9,1,9,0.053915,'Liquidity Teal','none'),
(1027,'mid','c5yHKN7x3jT8BqUXgQphpJsNCQy5DztqVUX4fFEhSvTS',4,4,4,5,0.076800,'Liquidity Teal','none'),
(1028,'mid','TpQYRbYAs39rtr5m5VGDFycKLXBXz6uJeLCy1f2wKwea',5,9,1,4,0.035025,'Liquidity Teal','none'),
(1029,'mid','mUXRxhpufeKNvu1J1S58Ca9fUXU5A2FUkzR3V787u7od',7,3,0,0,0.047830,'Settlement Violet','none'),
(1030,'mid','6qmi57DW8soBaL82BqfmxBhkwkJ7dfRHDSaFVCTyT2vm',4,3,5,6,0.059080,'Index Indigo','none'),
(1031,'mid','TrcSwrJHZkKEXUrkdKLxaoJSREH9QHJNei3vGn2aapDB',0,4,0,4,0.037170,'Ticker Cyan','none'),
(1032,'mid','GX7e481dCXWNNCgESz4DYFADezh2rLeWGxaqrQ1BfFVX',6,4,4,9,0.047660,'Terminal Blue','none'),
(1033,'mid','VFBuwf511JvFVD3PEfDpr5N8RogBRsizSKAFer57dAzj',1,1,5,0,0.031520,'Custody Steel','none'),
(1034,'mid','kZHeZ2nhVvJkMWpvf2FBvckxtJathg8ftatHpBqUgB7r',7,9,0,5,0.063030,'Ticker Cyan','none'),
(1035,'mid','SWvhK4j8swv8MzduweKNGxTX6ThT37B1yv3h95VeZ76E',2,1,4,2,0.043750,'Settlement Violet','none'),
(1036,'mid','1SJKLzpRGXuB2yAqWbMDMK5FSp7x9FS76qzjrp3fikKk',6,4,7,0,0.052855,'Custody Steel','none'),
(1037,'mid','ec5ga4dZiaxcxbH3ao5yz13xnifau6XDm5QfzZR5Rs39',2,3,6,6,0.085860,'Deep Signal','none'),
(1038,'mid','ZvPvBx9vsUwomCMm86Rw7qvtk5dMWRJvqHr61Lf5StME',0,4,2,0,0.047930,'Terminal Blue','none'),
(1039,'mid','HHajcso4XuvJmjyzej2Xu6e49ar3cmMWUHNVbzAcw5jJ',6,2,0,0,0.034310,'Liquidity Teal','none'),
(1040,'mid','6b7zn3SCExhT8DwdDQNEYLAtw3PQQQegp4DTGJRjeAFq',4,7,7,2,0.039690,'Ticker Cyan','none'),
(1041,'mid','SfrbvHSRstQcrEyykMMaCD94e1z8U16fcufVj9DChWMr',2,5,5,0,0.058870,'Deep Signal','none'),
(1042,'mid','kBrUquuk4jwUfLyCfsqdcE38ocdAXx1sQm4MmaWg6HWc',5,2,5,2,0.043125,'Deep Signal','none'),
(1043,'mid','YRng7WNXg2SAc4VcRRmduw3JJzbGqdU3xaNP2DtkGfBL',1,4,1,6,0.059185,'Custody Steel','none'),
(1044,'mid','gYPMf73fGbtcyuddkvxR8UWRkHxS1EeEzsQq8X225pNP',4,5,5,0,0.056080,'Settlement Violet','none'),
(1045,'mid','Zb65VZgDRzELHy3Rsqd6a11LdmRvB39JME81cXDFqh4c',2,4,0,2,0.054370,'Index Indigo','none'),
(1046,'mid','Zu7VoJescbtxhJW581P2SeriQameBQcYGFdNEKcFgYBf',4,6,5,8,0.043000,'Index Indigo','none'),
(1047,'mid','86uPUG3mpSRfNMcs2wbss1e4xUuePkCNchKukJhSg9Bg',6,0,6,8,0.058525,'Liquidity Teal','none'),
(1048,'mid','M3yAi4ZJRAjJ4E3Q5TMPKaqXfhTmmdRGp12hhnRFEMuX',2,4,1,9,0.047965,'Settlement Violet','none'),
(1049,'mid','zpvRAtu7SkuzeG8LsZcuxRXR7gb4APWX2Va4THpKHnPB',0,3,6,4,0.049495,'Index Indigo','none'),
(1050,'mid','4BVh7R6azrtu9KSWn8NsgBZqTFdrfE4y2qEZ1pjETvzi',1,4,6,0,0.038990,'Terminal Blue','none'),
(1051,'mid','KSDxfEkLqHxFJByJFQVMELrKPbqhLUvMtr7W4J5uuK5b',1,7,4,9,0.053565,'Ticker Cyan','none'),
(1052,'mid','TXKNrpecufrb6P9if471kQyMdjxCH1xnGUJha9SKPTMT',4,2,2,8,0.035440,'Liquidity Teal','none'),
(1053,'mid','Ju5xQUpjAEpDWfPD2kMcn79xnvvdhMXvNvEKdffYXRR4',3,2,3,8,0.060295,'Ticker Cyan','none'),
(1054,'mid','o1xys9KN6uWpDXLs4cCh5xnNQez1S9bF7UbSn2DQcCWe',3,0,5,9,0.034310,'Index Indigo','none'),
(1055,'mid','uSMVrNULaxtqUorCbfan9JjNBX3j1Xhx735tvxACY5mx',3,2,0,2,0.055260,'Custody Steel','none'),
(1056,'mid','pHEzB3yr7hgJhKpEEzMSLuWFe2mTqYbB436KEQzhnFJN',5,3,6,3,0.037220,'Settlement Violet','none'),
(1057,'mid','sFjGs2U6c5iuzb1o8s8mF9DG9JW52XWvnHXSeg3WKj8F',3,6,7,4,0.035600,'Terminal Blue','none'),
(1058,'mid','mntYB213isV2JYsSBho6UxyLCZQoGbJAEXzygQMJTwBL',0,2,4,0,0.038390,'Ticker Cyan','none'),
(1059,'mid','CWHsApjYe1fGEygBVz2J9ZDhZ8Q2mWSwR6UuX8jfSGmz',0,7,4,2,0.031590,'Ticker Cyan','none'),
(1060,'mid','BN9DXLyuqfWfDgFCRET1MiuqEi5vkbUhgPCZnuQTiLe9',6,3,1,0,0.032090,'Custody Steel','none'),
(1061,'mid','CaWXQG4S29pWZXpNv6SCaqo3WUr5ixEkE9L1hzR9ugWu',2,7,6,0,0.044680,'Deep Signal','none'),
(1062,'mid','Teu8FzKc6r2G7zspxz3W68XR6sqZFUwuqmnVJMNJpiJ3',7,3,7,6,0.037250,'Deep Signal','none'),
(1063,'mid','msULMt6vq9KjzEuC45W2WsV1QJE4rL9BwdWSGJmNv1hN',5,3,3,0,0.057400,'Custody Steel','none'),
(1064,'mid','9vSTzwDXY7eVM5utrRQkLfyDoJiMposDn54owvHpZHt7',1,0,0,4,0.045070,'Settlement Violet','none'),
(1065,'mid','ujgnx53q7BGqeHsCnxS8fS1nUEQUUhkaoXgz3ayFMCWg',0,6,2,0,0.040900,'Terminal Blue','none'),
(1066,'mid','SDpyTRwLZ3RCFhjZF7qbpiahJ7hpnh33aUuxE5WekgPb',3,0,0,6,0.051015,'Liquidity Teal','none'),
(1067,'mid','GJj1bQnKtR96MCMdi5wjwzKojaafRbjLp29WgqbCtDGw',2,9,4,7,0.045580,'Index Indigo','none'),
(1068,'mid','kYttwnM6D2aS8K45WMPBdWWVFx9TtKv2UeNFSNX9xAEh',3,2,2,0,0.062605,'Settlement Violet','none'),
(1069,'mid','iZcUcZ7HxF3PxQQBvpB6fPS4B3bgVtemK1929EywjEYF',1,0,1,6,0.046535,'Custody Steel','none'),
(1070,'mid','rUCSqMgYQTMNAxXBSrwpcbVUryFtv3Sr654453skPJ95',4,0,2,9,0.072510,'Index Indigo','none'),
(1071,'mid','qSRtkXj9Zo6hdzmRpswn96Jf8A4WHqbL31uawBt2ZL2j',2,6,5,3,0.043635,'Liquidity Teal','none'),
(1072,'mid','QeubLvFzytYbNcyVbnmYArV5wrmpw6spg9r83UhnuPcK',4,3,2,4,0.046585,'Ticker Cyan','none'),
(1073,'mid','s6DsLdAkPgLrPKTAW3ak3CJfiWxySkKSdc55G2HEarHi',3,0,7,0,0.035660,'Liquidity Teal','none'),
(1074,'mid','d2VoXXJqvib4fGubejvrhsss3rXeEccQEMkdTUignxnE',5,1,4,5,0.055140,'Terminal Blue','none'),
(1075,'mid','SSh9afth97woCojsb788J2vxmL5c6RXhEp8f3K75rivm',1,0,3,7,0.051595,'Ticker Cyan','none'),
(1076,'mid','dFXFAiYwQWdx2SVV4YBcAspd33e1Z9sm4u6b1v76LyeW',0,5,5,0,0.038170,'Terminal Blue','none'),
(1077,'mid','cX9XoU1Fepf6XktUnvWq47qZb1jawKGAp5U7LHqPq5BQ',2,5,3,3,0.057675,'Settlement Violet','none'),
(1078,'mid','w8SEXK7ZTu5KWtRCj6KRxbuFfRM71VYC9HwJHUFcPGyx',4,9,7,8,0.043140,'Index Indigo','none'),
(1079,'mid','RoZWscyQpgouJWu9sjC3b5AuiN6RL33dfbJsUaBUPhWG',2,2,4,7,0.031960,'Liquidity Teal','none'),
(1080,'mid','VoGnUM9xDzYjDL1FuWTUFbSwzYVQWnnnyEFDkbUQn9AT',4,5,2,3,0.034900,'Liquidity Teal','none'),
(1081,'mid','qUvtpjyeGhV2YYMmdzLawM4cfZuvdUoQtFv17iF1A7wi',2,3,1,7,0.027140,'Terminal Blue','none'),
(1082,'mid','5gJY33AmD83p6q3cXofnMp5HVRN61zkXnYR37a4VLv5e',6,6,7,2,0.052200,'Ticker Cyan','none'),
(1083,'mid','gVdD6kCJiYCb65fLKKQRUQbkxyrB1dMpW3aX5BifxJuN',7,6,5,8,0.056290,'Deep Signal','none'),
(1084,'mid','S3fvzC64t5tCuTuxQDHvuUWBQvPkCggExBpAoGwcutFx',7,7,6,8,0.051075,'Settlement Violet','none'),
(1085,'mid','CXbQDatauGkPapUdjSyHhewqyS2NCmS3Q98MLaHBVgti',1,2,2,4,0.050495,'Ticker Cyan','none'),
(1086,'mid','nKAusWitJW6mjsqGcWeRs2BkT4i1qTpQjrjqE3sF22bT',6,5,5,0,0.052520,'Liquidity Teal','none'),
(1087,'mid','KLXyDVFvvt9x1GTwnKT9JxprYefJERWBbhBukgxxNTiZ',1,3,5,0,0.072825,'Liquidity Teal','none'),
(1088,'mid','ihGKynb6yxUF7CMMvSMtX7RG8usjpccuAVphjSVpV1Ho',2,3,0,2,0.037850,'Index Indigo','none'),
(1089,'mid','GybTWbi7JrGai72CFAyXoN9tQzbdh4Cjpc26uboZDwVJ',6,1,5,6,0.028910,'Custody Steel','none'),
(1090,'mid','rJd1perAH55LYfzRey3yVKRtYe7qqVBTVBNcP1g6F1Gz',2,9,1,0,0.066300,'Deep Signal','none'),
(1091,'mid','Pp8Gdnz9nauCnwBP9nMTrfbSWahCxzu7vHV7nqZ8oGVC',7,3,3,3,0.035400,'Liquidity Teal','none'),
(1092,'mid','2F4NYnxjKopE3nPQTH2LW8Hcv7EoipkEhZM6NDeNET1W',0,0,7,3,0.042055,'Liquidity Teal','none'),
(1093,'mid','D8yYtRZGBh5MsT8qYg1LwjMf9XoAWCf6PkNsskacvcqA',6,3,2,0,0.063260,'Liquidity Teal','none'),
(1094,'mid','uoSuJyc8ZkGtEzQt6Lu3Dse1nR41YKh76Btmb2z89LVZ',0,3,1,9,0.045790,'Index Indigo','none'),
(1095,'mid','XfGu7WvnmfeNEreFyismyKPkt6GCZrJnY3JL3mNb2BxE',7,1,0,9,0.028640,'Custody Steel','none'),
(1096,'mid','3LsNaqAWacLbNKEM26CnUcp7HCjns1SZdHcnAWYgr7Tw',4,9,2,5,0.028200,'Liquidity Teal','none'),
(1097,'mid','LvbPr1oaxhf6jSbegA2so6SCZr63BXiNKTQ5Y8XMiKrh',6,5,5,7,0.061860,'Index Indigo','none'),
(1098,'mid','vpnhGcS9s8woLDdcZ59JeJBTeZrG3feeLW9tc5LFWsiv',2,8,5,9,0.048350,'Terminal Blue','none'),
(1099,'mid','aU4yUoxFymPzwqCELJ6TNd1c7miN5tqwS6SikBQRtHwS',4,3,5,0,0.064890,'Terminal Blue','none'),
(1100,'mid','ZK1aPan2keSD7RCeahMNBpyHKYATw5dCvZ8cSMSYGJSB',2,1,2,9,0.044450,'Ticker Cyan','none'),
(1101,'mid','3ueXor9haiVcPdTKPFrAJJjPqXSu9oAY69MyFtJbmsvn',3,2,3,2,0.047400,'Settlement Violet','none'),
(1102,'mid','7F82seFAZ4uzdCW56uKwAVaojjGWAh5UMnxXdoUtJyhd',3,1,1,0,0.038890,'Liquidity Teal','none'),
(1103,'mid','Zei115oCAgzw3aZZoZk9jfTqSdbrPap4ASz2atW6GtPN',5,9,2,2,0.037290,'Index Indigo','none'),
(1104,'mid','9mBwTMRZNdYYtq4dsAejKkAmVsMfcAV2byKK3PGHCyTy',3,3,3,6,0.037740,'Ticker Cyan','none'),
(1105,'mid','GEu3VGfzLCumqxZYLmG5o9n4jaxi4vQcfhkiwQSjBf3F',4,3,4,5,0.035750,'Settlement Violet','none'),
(1106,'mid','pZwXxYtZEG9iLQfaTAaupMuJyzHxSdbsUSiiBJqL6TUu',6,7,7,3,0.087365,'Ticker Cyan','none'),
(1107,'mid','TemAeN4h7crVJd1yj7EaSWnZuFPjMHN2RZanWJ5gRs2T',6,2,0,6,0.039240,'Ticker Cyan','none'),
(1108,'mid','Xvdbo9tEc3APeNcnQXHXusAQ3Pe9s5TmLpecetoXphrc',1,2,1,3,0.056385,'Index Indigo','none'),
(1109,'mid','mWfGxxYcMZ4EAn12muB1oQTxceiZQaxGPLr9pnuqsRun',6,9,1,9,0.047630,'Liquidity Teal','none'),
(1110,'mid','DBcFsbxRitSQ4tFcoaF9oRWCEjC46FYwt7kvwcM6ySkD',1,5,3,2,0.054905,'Terminal Blue','none'),
(1111,'mid','KfSXjHHGALDKQS8rSiHp9NaMKqXAGencPPbchmvdh4vD',7,7,5,8,0.024160,'Terminal Blue','none'),
(1112,'mid','kcAZLQVqbRsAh7A7h14xLqqYZnywn4XRPcU5vxUtmepc',4,9,4,0,0.035730,'Settlement Violet','none'),
(1113,'mid','UVzjKSme77DAYjuLVX7F162jn4AYnd8k6Yqzw9bVxgjo',0,6,6,3,0.033000,'Index Indigo','none'),
(1114,'mid','84kfL1DaDNBn6pVQFotbTGFRz24v352Lx53Yt3sewec1',6,1,0,8,0.052700,'Terminal Blue','none'),
(1115,'mid','WL48kt3Z8iCt3LdLbe7syzxrhP2p8uteQM6KcMtTaHYU',6,9,1,8,0.046790,'Terminal Blue','none'),
(1116,'mid','q8RoJBDRNBXctqtddRZePNiJm6cJSpjXFT5AYtGK9G2x',5,9,6,2,0.048530,'Settlement Violet','none'),
(1117,'mid','yczFqHWhMcpsVPFPrkjm9TYkgFmxtkBJmno66eaxqLzv',1,7,6,5,0.031520,'Settlement Violet','none'),
(1118,'mid','HEqUgMjjAeRPBCaqnKuGDEHVqT6KbKH657ecaU2YK69T',1,6,3,4,0.038440,'Index Indigo','none'),
(1119,'mid','nmYejn3hjdgaZDfsCgrfo7rAKMMwYosyW4o5ttFwSYKf',6,9,1,8,0.030500,'Index Indigo','none'),
(1120,'mid','EWRSyf3Cy8SWyfyrhY2SB1TpPNTvt4UimxyFB4efhLNr',7,2,0,4,0.039465,'Liquidity Teal','none'),
(1121,'mid','gTi6Fim1kAqL4h7ivviFpsEMBFzyvkUFa9muXwLpAruV',2,5,1,8,0.038530,'Settlement Violet','none'),
(1122,'mid','8MgbZkPCzVmBz5jZXRgXA2JEfPxrSPvPqRYBXW8hwTgP',0,9,0,9,0.049120,'Settlement Violet','none'),
(1123,'mid','MrHBWswA9LTzEEVjEYwmoQ8qp2Ri9FVgoDj5iyPJCLad',0,5,0,9,0.029620,'Settlement Violet','none'),
(1124,'mid','V3HVsf8rr7b6esU1X67wXEdL3KPwH711XTPLY9hXcEZU',4,8,1,3,0.043740,'Liquidity Teal','none'),
(1125,'mid','9AvK9tzv1U7isU2CiuUnSWB7YsKjRgZkvjZzqKj55jMA',5,3,2,7,0.031140,'Custody Steel','none'),
(1126,'mid','VkVHYNSERt34tRPR3ZJWuxkJCM3Nroxy9meHDK3Q5xfw',6,4,5,5,0.035450,'Settlement Violet','none'),
(1127,'mid','Mw1P9u3zNfB87ULRyvipQXvrLetaervvWKSvgfeWfJC6',6,3,1,5,0.058860,'Ticker Cyan','none'),
(1128,'mid','vsEJ8xtX2pGMSCX93pFftvMY3XV7UBWQNvZmJSKerrBk',7,8,0,6,0.035020,'Ticker Cyan','none'),
(1129,'mid','2L7kihFtsX56L9sLMsVjauWMeRkdFw5LpfYiB5vUP9hJ',6,7,4,2,0.038500,'Terminal Blue','none'),
(1130,'mid','i3MHNnBFHT9DEv8XgiKBHKRJdmNM9hASPn34BSfFaz2F',1,1,0,0,0.032120,'Ticker Cyan','none'),
(1131,'mid','vUVWCxNnGGknvETNxyURUCNWTS3xcGUo6dqCKk1wR1gd',0,2,7,6,0.031580,'Liquidity Teal','none'),
(1132,'mid','hf9qFDpGTBy3DYHKBMN8ybqYTqe4yE1fRnqa5qNQEixH',4,3,6,0,0.040690,'Custody Steel','none'),
(1133,'mid','CCJwpARRKU9PqwUXjYiAsDDYGdjknm4j2j3XpM61iP9z',5,2,0,7,0.032580,'Liquidity Teal','none'),
(1134,'mid','9i1DtmYCdtjw7kV7tQjWHJQXiyKHMtVfQGhZfUKiDjQx',1,8,2,6,0.043285,'Ticker Cyan','none'),
(1135,'mid','t7ZXd6gpU4S4mymhC2LoKVELu19gvbAnTozQxWzTLPQD',1,2,3,4,0.041370,'Liquidity Teal','none'),
(1136,'mid','RTh18GGHgdxudRaBfGbUEr3vKYNEfefMknS92dBRVpV2',2,1,5,6,0.056945,'Ticker Cyan','none'),
(1137,'mid','ETyQfhobNJnpNvseTYFdPt1NRs8Caojhr1gRfxpveViP',4,7,2,6,0.048215,'Index Indigo','none'),
(1138,'mid','mRFAiLNHLCkG1RxNeYyWHad9JXG1BSZiX1mDN6nhwYgQ',6,1,4,9,0.037440,'Liquidity Teal','none'),
(1139,'mid','rtuwoeFUEKLNEmYmBm3jL4RmYikzZFdEYhcaNqKKhNQq',6,4,3,0,0.042960,'Index Indigo','none'),
(1140,'mid','Yvyc5vsgZzBE9ewjyM3P2sAabnAxqg73KYMFStJJpVjt',7,3,6,4,0.045250,'Index Indigo','none'),
(1141,'mid','WKqpYHYXphUgwbj9ajCxGz7MvCFJ3sGokodRYk2VRADY',3,6,7,5,0.041430,'Ticker Cyan','none'),
(1142,'mid','DMkDTVUZ85ruPo1tY2cKcAgMCW9cWtYLCTPTmeQwYUXp',1,7,1,8,0.041250,'Ticker Cyan','none'),
(1143,'mid','21ewuzndVocnYjWZjumc5Kd45UA3sZqngmk29iYBHwir',0,4,7,9,0.064380,'Terminal Blue','none'),
(1144,'mid','yZ5ue17txVTyoEv6jNDLYEJeSmnczNUbrGu8Wq3Kr3Ni',5,6,7,2,0.044570,'Settlement Violet','none'),
(1145,'mid','APd2X3p4LNvTwf1k3rxY8fhAjSxGDqAMWYo8DWd4Km9a',6,8,4,6,0.044870,'Liquidity Teal','none'),
(1146,'mid','CqadRxMoBn3PQJvgjor4mV5ZAcUjHA3bNQX4jsat4t8c',2,1,2,4,0.044170,'Settlement Violet','none'),
(1147,'mid','4fcpkEVN4xysfEicq89QGpKg3UjGKYYpTGCfFs7tKToX',4,5,1,6,0.047340,'Ticker Cyan','none'),
(1148,'mid','arCNP4wNt8uGp7EUyZk1KvDgfa4FzxniNFWB256hDV8v',5,5,4,3,0.036310,'Ticker Cyan','none'),
(1149,'mid','FgVcFK5UjY9aTpvHxfk5Anu7EhoEbd7yWqsvGi3461rr',3,7,0,0,0.028880,'Index Indigo','none'),
(1150,'mid','i6MgBre2JtkEJJ3rFy7CmghEVLKLZBAYeUgccdcVW2Jt',3,4,2,0,0.053855,'Terminal Blue','none'),
(1151,'mid','6gfYb98SGrraPTCxtHAcoqv4WzPCRNeUBPux1STVBKRg',7,1,2,4,0.055260,'Index Indigo','none'),
(1152,'mid','bF9JAsyizMfDrvBhJPqXBA7PkEKn7GXT4hCSF5kLk4FF',0,8,4,0,0.051500,'Liquidity Teal','none'),
(1153,'mid','4hbS3iwqCzy2CHKisBXuh1b8uyQyAY9Kz3DfqmygHXTk',7,1,2,0,0.043630,'Liquidity Teal','none'),
(1154,'mid','qRtYgWf5szTpMrnC9yzvCuCtwFi8LN1HWNxyJw1NaDmz',7,3,1,2,0.071925,'Index Indigo','none'),
(1155,'mid','HeE9Wtvna2C7dpx7ep4MUN7xsFh837EUxcU7JYd69mi7',7,1,6,8,0.034900,'Liquidity Teal','none'),
(1156,'mid','qVZiyD7gFEq4da8vcqcJsS3g51z4qNS7kzFyE8TJjZJp',3,2,7,8,0.036110,'Deep Signal','none'),
(1157,'mid','9MsoQM6zjaT6Te18rV5yePCXkrHvkTwBx4BmU7edd5DV',4,8,3,3,0.053820,'Liquidity Teal','none'),
(1158,'mid','MjDaXdJ9ib6mtPWefnr3c2XrsqtZqWd2UWnvqWTJJKPN',2,5,7,9,0.079380,'Ticker Cyan','none'),
(1159,'mid','gtQUbokeCxET5iCZz1NN9LyGBnhEhWmPKNfpzkojbsgZ',0,6,0,2,0.051515,'Custody Steel','none'),
(1160,'mid','fewX5cpNGrDnuCU2aLXfzUNux28sjgzu4JTzfKcZo76H',1,9,5,7,0.036960,'Custody Steel','none'),
(1161,'mid','DbvpdJLesgpPTRcKpecFxT2sQLCsoHxKdBRSYmVSo8Xq',6,8,2,5,0.040960,'Custody Steel','none'),
(1162,'mid','QxzVrf2AiS5fnjuqRwsB7tzJeBtVoKehQx3WXCPhQjNe',0,1,6,2,0.031450,'Terminal Blue','none'),
(1163,'mid','x2AJhRyyG2iAFpcVzLLdg5pGLuzMLqEyGwuVXTJDbN4s',4,8,6,9,0.055365,'Deep Signal','none'),
(1164,'mid','S4n3JoueSmh1mevkEpFNxRT89nRTfmz1h79563Vgjse1',3,2,0,5,0.063690,'Settlement Violet','none'),
(1165,'mid','3gkvqViLbQhk4CcBcki42vgWSTqb2J6evF7TiMitopDv',6,3,3,0,0.046470,'Terminal Blue','none'),
(1166,'mid','mgsvgkUccmDgnfKByt52q25YeqCjpD6jLSKiN1SYSeh4',0,3,6,4,0.041600,'Ticker Cyan','none'),
(1167,'mid','afdy48Seiq5ofaP4HGUikFJVDHYK96dGUAmmhfPsjHVe',4,3,7,7,0.054780,'Liquidity Teal','none'),
(1168,'mid','hKwC5Jotxfhtg1YjQHZHNpJmtCqT3KgoUaDtdZVtAZUe',0,0,2,5,0.060790,'Custody Steel','none'),
(1169,'mid','obyVtfhSvDhqGBDZPueneNYsQV98u8oPDHyoJntpcXUL',5,1,7,6,0.056250,'Liquidity Teal','none'),
(1170,'mid','iwv8LaK431Sg48J16cjeLLwUm6s8rkdZ7yx7URKazBUH',0,1,1,7,0.066755,'Ticker Cyan','none'),
(1171,'mid','1xnDj9n2b3MBsJ2dMUFPGpgy35JjZFCk35A1fSGfFLDs',1,1,1,3,0.034185,'Terminal Blue','none'),
(1172,'mid','RfWY6tB125F1924GCkNPENRqrT2DnyjX91nbNTYJQ5WD',0,0,6,5,0.046335,'Custody Steel','none'),
(1173,'mid','jnguRFuP5XAMSBNCp8SNjWUV7CkLqaP4qNrfqducE2AP',2,7,2,9,0.051930,'Liquidity Teal','none'),
(1174,'mid','NduaRZqS1khQpo1uExpfKJMezRPa7nizxzkzFDQS3UwR',3,0,3,0,0.057980,'Index Indigo','none'),
(1175,'mid','fxjoBksNUcUTdid86K6KwkCJ8qtoSrU45dJPKNaNC36x',4,2,3,9,0.057040,'Index Indigo','none'),
(1176,'mid','ABxgDRnqvSGkcygwpHiRx1YEgeiXhBhPoGEmSJY327RH',3,5,4,0,0.041220,'Terminal Blue','none'),
(1177,'mid','qziZjaM5YgcRs2WRHnwqj2XcpDYrg1A9BBPu3a6AZ6z6',6,3,4,4,0.045835,'Deep Signal','none'),
(1178,'mid','d4kHCzpU9MUg4JgYydu1M3w2pcy2hZ7K9ABURqGuJ4wb',2,8,6,8,0.043910,'Terminal Blue','none'),
(1179,'mid','QKvTT9KPCFoemyRYh9En1rozHZkJ88erTLfA2unL4Exf',6,4,0,5,0.041910,'Deep Signal','none'),
(1180,'mid','2fZM6eBUYxVwLquP6HqPhYZ2XGqnewnPsSfsMcPYZMfN',3,2,5,0,0.054065,'Custody Steel','none'),
(1181,'mid','hU6bK2ASzbHgKwV5dq72FoEvz6UhyG2vdJUj5h6WxfKv',0,6,7,4,0.028560,'Settlement Violet','none'),
(1182,'mid','1cmE3vFEJEqiibdxfSiBD2A9LT6d9Zf72FyWbxMtjxkD',0,2,6,5,0.030520,'Terminal Blue','none'),
(1183,'mid','pkm5PC4JFhe3AZ74Hdc4ZUKhtgAgNSSWYvWSnVnNEfSV',1,3,2,0,0.076260,'Ticker Cyan','none'),
(1184,'mid','54L1ih1Y2LyTWs6WyQz8H7mw1qf8URdBaVma9BJdbPUZ',5,7,5,6,0.046110,'Settlement Violet','none'),
(1185,'mid','oUyMXqfvVN3WCsB4kTBcfBFW7XtDmz2L2frxobf7pf3g',7,5,6,9,0.035220,'Deep Signal','none'),
(1186,'mid','S2Pgxj98tw4KgXtDPFUV5vmKiXP54HPfTbgJHNcYRzT8',2,4,4,4,0.042985,'Terminal Blue','none'),
(1187,'mid','SCzctzv4yqugjoeaVvDZar9BTtdioKFkdvHY6Bqr2vf1',3,2,3,7,0.035840,'Settlement Violet','none'),
(1188,'mid','zYzZLbVi49PD3T7Wr7d8dCKeea8ZwQDDLXtNSFuwj7Y2',5,2,0,0,0.037450,'Deep Signal','none'),
(1189,'mid','GLQcE28q1ohMsNufS8CvS1pYysrH7VESPcVnSSXHJHmi',5,3,6,9,0.047650,'Custody Steel','none'),
(1190,'mid','gcnU9Capscro8a1jS5APirxjnPFQDxbiaYxEpkD3jNP8',4,7,7,6,0.066450,'Terminal Blue','none'),
(1191,'mid','sGomYK8U4X3qhP2SZizWzWsWRRAP7FeJ8bEpgWn5n1Y1',1,0,4,0,0.052635,'Custody Steel','none'),
(1192,'mid','GBZ9ykTmh5JgYB6NFhnkUfn7zWVcP958m3sXx2b4XRU6',6,2,2,3,0.029620,'Liquidity Teal','none'),
(1193,'mid','gMb9XgQZwQKXBF1LQHzwh84i9NfCN11ksA39ncstGubw',4,2,4,2,0.042030,'Deep Signal','none'),
(1194,'mid','GPJuevAyDL1xMcg6UGsQ96xVz3oZLNzH7uV3Jg5ATumX',2,5,4,9,0.033540,'Settlement Violet','none'),
(1195,'mid','WBxxBQFuhSpDbgSe2ujrRdvacyP5K5b2EdhRwtAfe3kW',2,2,1,0,0.061480,'Deep Signal','none'),
(1196,'mid','okmRZKTAzDFDgNc3GSTffxTyVYEH8bB55y5x89rPwbF5',0,6,4,0,0.040775,'Deep Signal','none'),
(1197,'mid','XP2Yibuth66oBPw3EWCd9pM6CM3HcyUN7sqUeeuWrm6B',1,0,1,5,0.043045,'Liquidity Teal','none'),
(1198,'mid','d3uFDECaPvbzycZ8ZUkLTYGNfsaCsqmEK3vDteX171XJ',3,0,6,4,0.029040,'Terminal Blue','none'),
(1199,'mid','GTMLEQMXox5ThnTGPQ8osYFYuVBhTfqppwRJqcPx1iT4',6,7,3,6,0.051655,'Index Indigo','none'),
(1200,'mid','5hJQXG7GGwiYPN3DwUknbVdENGZfdS5xUzVuz3qzjZB7',6,2,0,0,0.038040,'Settlement Violet','none'),
(1201,'mid','Z8VGfNj9Qh1WtaE2JCjiouUa4W3fBTtWcnutAixfjuAY',6,2,7,0,0.055120,'Deep Signal','none'),
(1202,'mid','aLPut7HonuwYVC7WowZdPXeoitispUUHcRHPrFYnpm2g',6,0,7,9,0.046185,'Liquidity Teal','none'),
(1203,'mid','JEzWbMJ5BjK6PLA3YxL4WSv4hF1x8p9NzBd7zpMd3EV7',4,2,4,4,0.051975,'Ticker Cyan','none'),
(1204,'mid','CDP94tQc3BL1SkWyYs9FvuvgJLT685grMfEbQNkuf62X',2,3,6,9,0.048595,'Terminal Blue','none'),
(1205,'mid','7197Lufw2wPTw4JvKwoWGsZrmBjDKwhwnh3t61EaXQKn',3,4,7,0,0.056750,'Liquidity Teal','none'),
(1206,'mid','mNiwq1M7ugEC2PZFe7KFW6pzfUJe1VEVmppNoZRFvQpj',2,5,2,0,0.028160,'Deep Signal','none'),
(1207,'mid','pGc3mfmv8dKMZo2n8ygKqDw2XPXwQFU8CWhDCLxa7zEk',4,8,6,9,0.054765,'Liquidity Teal','none'),
(1208,'mid','Gs7CSuuKmRtMZLAAbGg6HPL1yzf3KZdQU9AWwA3v1XjY',6,2,4,9,0.048285,'Settlement Violet','none'),
(1209,'mid','8DdE2E5gjsybJdDueS7Qc6hMzFZGpDRkLNz67tALxVQY',2,5,2,5,0.042540,'Ticker Cyan','none'),
(1210,'mid','F2aGpQKED8VoqWfMZDkpcs5t91bsq3ga9JyGQ8mMDVUQ',4,0,5,0,0.037650,'Deep Signal','none'),
(1211,'mid','p13qRQmaeXLBvJDCACPGDof2rvVg5SXVCeX4oCRDcXcv',1,4,4,2,0.050565,'Deep Signal','none'),
(1212,'mid','nx4qdQ3PEoY2pMRnQ4fRiq3SVKfrmdkshhG68hVxFkFV',5,4,7,2,0.036790,'Custody Steel','none'),
(1213,'mid','cfXj7sRmJDrc2Ak2jshXKMwYeeQY17WRFXcLuUWgNznX',1,9,2,8,0.037580,'Settlement Violet','none'),
(1214,'mid','vx7RoUgFYH6hi4w1aMxpDuFLvCYx2CSZ7bsiQF71wevB',7,3,5,8,0.035080,'Liquidity Teal','none'),
(1215,'mid','ARAaaszB4iYA6ecbUXR5VYNCMYJrcAEfQLC12Nu4VG6J',2,9,5,2,0.056925,'Liquidity Teal','none'),
(1216,'mid','3GcAVXajyTS2ViYJsrGP3pvDExfTSTackRjGfac26yRq',5,8,3,8,0.059260,'Ticker Cyan','none'),
(1217,'mid','qw24QDKQpWJzXbSLWufSLsBz2VKxpjp3SgXEc4zSTFqX',0,7,2,8,0.040645,'Liquidity Teal','none'),
(1218,'mid','6MskeffnkuAzjRLRE3RvUtB7WE6D7kVSckrutgmEEPdV',2,3,1,0,0.067855,'Ticker Cyan','none'),
(1219,'mid','LhnKp1YkHzrjk3JVqAA4FUsUriZmEmdGxahCxJw8c7Ey',1,5,3,8,0.047710,'Ticker Cyan','none'),
(1220,'mid','WyVjR4EHo5W5EME6inHe35pPJ9X5uSXhCdEjwdtkMqAx',3,5,3,0,0.038610,'Liquidity Teal','none'),
(1221,'mid','nBxvJ6diWLTC5yVMFQxbiRac1SDaSdvwN9kAXudBQeoV',2,5,1,6,0.033600,'Deep Signal','none'),
(1222,'mid','pwC7iKnQqpHnVNj67AMfLujuDoV8xRswp454wFuZMXLC',1,9,3,9,0.036010,'Settlement Violet','none'),
(1223,'mid','s9xww6PgiRn5fVzNPXz7Ea2Rsz3BZseJG2BinmM9JfyV',7,5,7,2,0.048605,'Settlement Violet','none'),
(1224,'mid','cwxGZX6NZEWm8jZp6PuiKJHdtdLAo2XzF75sg8A6CMfP',4,4,1,8,0.047040,'Liquidity Teal','none'),
(1225,'mid','Z4BMM6oUChJnDSpcjen6Yuaf47EPqBWVjwTttb1cyN11',2,0,7,6,0.051255,'Ticker Cyan','none'),
(1226,'mid','zYjGymjWLTR9scECvvmfjfGS6Uh7mjeAXmXJjUNHJatE',0,1,4,7,0.049840,'Index Indigo','none'),
(1227,'mid','sViqDYisRMtEjEhktUdn9P5BAL9RtHioR7MshpsaGmiE',1,8,5,2,0.047040,'Ticker Cyan','none'),
(1228,'mid','PhwLPXtbYL4VV5P1AU2LCmkVGnaK4xPnsAJ6Kc8z7dF5',1,9,0,7,0.040030,'Deep Signal','none'),
(1229,'mid','exGTsxYE4Q87cQv8PsATSRzarBdTFfm4TMkLKTjsdJdU',0,4,0,4,0.037620,'Ticker Cyan','none'),
(1230,'mid','ynEEpDn7Ag4ULoHQcvR97y9LB5CQVfJg4VhBA3Y91vP4',6,3,0,2,0.033680,'Terminal Blue','none'),
(1231,'mid','TzMymiJhcWnFTas1efrWdgE42xX5R9gXcn5B7e7HsBvx',7,2,4,7,0.045875,'Liquidity Teal','none'),
(1232,'mid','ejkUYS5juVgUuby4MxHBdoSaEoTKBJ9jKnQXURV7vaz4',0,4,3,3,0.052730,'Deep Signal','none'),
(1233,'mid','zZHqMz3CCUayNQkxeKwgdYTpXVASTTbbcZh36BYC9gki',5,1,2,3,0.042210,'Liquidity Teal','none'),
(1234,'mid','fYqE61jY2T34vVshXneRBXzNXomaKygr7HnTAKhnvSU1',7,2,4,8,0.045455,'Index Indigo','none'),
(1235,'mid','aL4UB1Z3VPkvwt8Zgp8YocNrUrb17zd25t9dhRNUBwcM',0,2,4,2,0.039960,'Deep Signal','none'),
(1236,'mid','AahcDkwjGiFakQT8dJ15f6mzron2MsqeQScwZ9ACjjjp',2,3,6,3,0.036980,'Settlement Violet','none'),
(1237,'mid','6M3em1ER15ijTBK4tDhjBsLy9WHA7v47YouSFhuXXRyr',2,7,3,2,0.041775,'Settlement Violet','none'),
(1238,'mid','C1fMJDUUGpGi9JWwX5kpQDPmiZ8gtZbVcX8rQyU2WbcW',7,2,6,0,0.033270,'Settlement Violet','none'),
(1239,'mid','8giLmRJeiia8StopQBecL8xNcNetzN4m5KgwurNVbtuR',3,1,5,2,0.038720,'Terminal Blue','none'),
(1240,'mid','sh64gMfs2WaSchPsnhqUAWAmFZXuotARUs82CMwwmYPf',5,7,4,0,0.038280,'Settlement Violet','none'),
(1241,'mid','ypWADLNkNUFrm433zvMAp72z8LTga82vLSjnzqEqbq8E',5,1,7,0,0.050340,'Terminal Blue','none'),
(1242,'mid','EygYnW3gvmysKHbuk5MVy84EikDnPzfFcqfvP9d3ugCr',3,4,0,2,0.045095,'Ticker Cyan','none'),
(1243,'mid','NEDfUdWCHXD2kqTjH4mV3YWCgA9LmTGCwp8heXUmGhLe',5,7,1,4,0.041465,'Ticker Cyan','none'),
(1244,'mid','ycz7qXGcFMuWoFnEgaEj5s7DbsgQCZ6fZAqdFr4DiqLA',2,8,0,3,0.043275,'Ticker Cyan','none'),
(1245,'mid','mGyT1x5yk5H5GiZ63DJ98VFErAbektJfbHFZGUSqMzFA',5,4,7,3,0.053440,'Deep Signal','none'),
(1246,'mid','v5i1nfhdzahfDjKi5cJzTNYv7bRfbQccmq43yuh9dQVu',5,5,6,4,0.056810,'Ticker Cyan','none'),
(1247,'mid','1Cjt7iS98LncXXmRCuBDMMiYq7JfaBg9ZcwhQgQtUYbE',3,9,0,8,0.040165,'Custody Steel','none'),
(1248,'mid','MVgZepA5uktLejvrrraFaj8SJaD5R5UiQJMrWWtHfQRb',6,8,5,4,0.035310,'Terminal Blue','none'),
(1249,'mid','nN79eY4FLYcHLkQpEce8rrPqwTdxJpbhg9Y9Ep9317yi',6,8,0,6,0.039100,'Deep Signal','none'),
(1250,'mid','CZvD59NiX632Px7CFQ6L5MRBPyJ9ve5VGDpzaSis8bEj',3,3,4,0,0.035880,'Ticker Cyan','none'),
(1251,'mid','19NKkMR7T8suZ8nCXwSTYaMBSub9dzmuWsFYYFmYmaGH',2,2,5,0,0.064145,'Index Indigo','none'),
(1252,'mid','AWp89HoTz292hgj8B7uieb83NcwNViwMWcSvoUxg4WZH',2,5,2,9,0.039220,'Settlement Violet','none'),
(1253,'mid','4EyZWtmRCp5TFx6wMoEWFu4t7zisJ7da4XBu3jD1u9xR',2,7,1,3,0.027180,'Settlement Violet','none'),
(1254,'mid','KWusYKksxsHncoqWhcr5LcTwfc94Bv5ewUs3e47dPhDa',3,5,2,5,0.050035,'Liquidity Teal','none'),
(1255,'mid','v2L6Nbq7Gm6g2HDexrsyiDcL62asoWLWupUTxPEpB8mq',0,7,7,9,0.054380,'Liquidity Teal','none'),
(1256,'mid','Q4fgUY9qFMiEFmAEiLQgtkAjAAfh2YTyssnhP15a2Vt2',2,0,6,6,0.066725,'Index Indigo','none'),
(1257,'mid','pf9Ew8W1CtPSvWeErA5D9As9dvREta9HVWpkqu27xW7p',3,1,4,7,0.076850,'Settlement Violet','none'),
(1258,'mid','zLYCSzmsoXZmTaa2UAChS65doUkPf44WokFNrDs9ZJ6K',4,7,4,4,0.035960,'Terminal Blue','none'),
(1259,'mid','h3EyCPJXDmw395dLzzHpS49qoj55qw8v5CPZG1BsETp7',3,8,2,0,0.040310,'Deep Signal','none'),
(1260,'mid','e42H8GoEBnptMkoS5a2ryDLQnNaYnKkCnBinxVr5fMjZ',7,3,5,3,0.027480,'Deep Signal','none'),
(1261,'mid','EqV31XxksMrToB9G3fzKbjoqNDmxQTK54MZjzT2wCiDV',1,4,0,8,0.039390,'Liquidity Teal','none'),
(1262,'mid','12FyRhebV5pmaZsmtuWofXrqeAMzxTaf7EXWY1ru1Ls8',6,9,2,2,0.048580,'Index Indigo','none'),
(1263,'mid','2BQujRCtAjNSYqyKuPL3RrUPzD8syZs6qskeyYiPgDgc',5,5,7,5,0.047480,'Ticker Cyan','none'),
(1264,'mid','AuYUKSccVy2x22sVg3VQWV26mF1qCbwFPF29apF9tJdM',4,3,5,0,0.058290,'Ticker Cyan','none'),
(1265,'mid','vXsawzu9PCdppGVZKwKHNCUgDkbjhQgjzT9Tj7Uh8EhQ',3,7,6,2,0.046615,'Settlement Violet','none'),
(1266,'mid','epUYQxvt1MPz9EwqT4rQwpMXCP8xDuwfamRtgNs2MaAG',6,7,2,0,0.046525,'Ticker Cyan','none'),
(1267,'mid','MnRzMfMQytGhA1P4CaMz7vqBeS7TTNhoAqFtacuCL5ix',5,3,3,4,0.040520,'Terminal Blue','none'),
(1268,'mid','fXjPU1Rc3Usooi68YPSNWwz69bUgQxUNAktTzy1L864s',7,9,2,6,0.055800,'Ticker Cyan','none'),
(1269,'mid','8cAn9ZEmWAZje7AUkGyBF8b9WTsADkaXzD5LyAfCDkqn',1,3,7,2,0.088550,'Index Indigo','none'),
(1270,'mid','RZmi5jggtLVoV6zBRcTwoHW8VKs7LKNrk44jexikyaUC',6,5,5,4,0.060380,'Ticker Cyan','none'),
(1271,'mid','pR3FoZ793xuPY2unzggWhynvSqHBFFbJztcHWauDjxpU',7,7,6,2,0.046300,'Terminal Blue','none'),
(1272,'mid','GUwuiHmQuYduDeiPGzXKkpr4SGu3NRpJpJdWYZQkCkRx',1,7,2,4,0.047385,'Terminal Blue','none'),
(1273,'mid','A1ymLATdC5SYhegTKQCs8V99hqHB2yro1dcmehJ2VAZa',3,0,7,5,0.028520,'Index Indigo','none'),
(1274,'mid','rhvbLB7qErNCCmzHbz5XFhgnbrRVUsb44CuHA5un3itt',1,8,1,6,0.046755,'Index Indigo','none'),
(1275,'mid','Qzh8SF3bhjK9fQfVHeDDUmZmqWVUJqnwJBuAHuBfFbju',2,2,5,8,0.045065,'Ticker Cyan','none'),
(1276,'mid','XnmNHP5xRGKUV96ikEq9WWAT25QuAwZRvQcLtJbk3r7D',1,4,2,2,0.046790,'Index Indigo','none'),
(1277,'mid','bWs2Q5EGD29hTAXYJrBe88TA18E3Yn8exJN8tjb3i45o',1,0,3,0,0.059840,'Deep Signal','none'),
(1278,'mid','Bt5vnV9nimx8RrjjeEYsGkAz9RjsEk5iN3FzCMoBjSbn',1,7,7,0,0.064980,'Terminal Blue','none'),
(1279,'mid','zdH1kAistWKSQyfRFP7eiVvV5fjH5eEsUazxAMdPTL6c',0,8,0,0,0.037220,'Terminal Blue','none'),
(1280,'mid','TGBPn116eCA7XEUMFtT9Rh89St3sQtN2Do5xQdgD2FRr',3,5,5,0,0.038330,'Index Indigo','none'),
(1281,'mid','uoXC9LYdt6iYoSSQdkhbASwf7oorEiNKcZNWdPC6X92u',5,8,2,9,0.049155,'Ticker Cyan','none'),
(1282,'mid','iqMHt1V8KVzB2Qpg1Pfd4JvtHFgDKFCMBQ5TZPupTbLD',2,1,6,6,0.036910,'Deep Signal','none'),
(1283,'mid','4MwALw5NChWxbNAz2z5RtmD7j9zQuF2PoBvcAQLDQZmZ',2,1,2,3,0.049620,'Settlement Violet','none'),
(1284,'mid','Dh6e3jykyiZG84uFs6gbPVMT4b5BgVcJtabR8pwzrXNs',4,4,5,3,0.043700,'Settlement Violet','none'),
(1285,'mid','D5PsFZQjSNBhPMyDT88jHYnB6PfeGGe2tYjfu48wrTS1',4,2,2,9,0.057640,'Custody Steel','none'),
(1286,'mid','Lr8o8dS3xDTvqPJHqsZtmqBYoLSs4ThY2wxGV4zQCN9H',1,8,5,7,0.049720,'Liquidity Teal','none'),
(1287,'mid','AA6mHMWdtavAyAop4U8bWbCw4A8QvVgtTmn1Jhz5npVy',3,7,5,7,0.045175,'Deep Signal','none'),
(1288,'mid','ZshHeLXpQPZUTPE4WSjD1TKX62D2LPeFH33sYz8sWbZD',7,0,6,5,0.028470,'Deep Signal','none'),
(1289,'mid','gJSiAYZw47xFhzVzLCPByMfDQznsL3pTbpArvko3UZVm',2,5,1,4,0.045435,'Terminal Blue','none'),
(1290,'mid','9esDhRGuts1qisJ2yp8PaLeHQtykdDNCgGr3K1SLWLXc',1,1,1,2,0.040535,'Custody Steel','none'),
(1291,'mid','gB5ANKvjUK1VX4FSse3du3xfdzu6Z1WfSLNZAF2cfXmP',4,7,5,8,0.048465,'Index Indigo','none'),
(1292,'mid','HJxLLasNTz1rZuFvCaEHTgqRotN5TFTdqZUyycSmNqXG',6,6,1,0,0.042410,'Ticker Cyan','none'),
(1293,'mid','f9UHrU7ffGPmnspjWvG8nb1kw9MkvQdUH1XDMQzou8Nw',1,7,3,7,0.035140,'Deep Signal','none'),
(1294,'mid','1nN2pGF8a8Z6Sey2Kv3szX8N1bYdna2Sen5Fwm96UH9H',3,5,3,0,0.039830,'Liquidity Teal','none'),
(1295,'mid','D7Q6shANYNhFTLcmjP6VfCJGvqhzpR1SEZQjTnfQ1hXg',0,0,2,3,0.062910,'Custody Steel','none'),
(1296,'mid','pZGCStAGDay9oKekg7kfM6SrXYqv6UTX8wQCwchp2FC8',0,1,0,7,0.036920,'Settlement Violet','none'),
(1297,'mid','hwhL15TFHUsCK62GgnqsJwfaDrRmGtxGXAMkTqV3FTpb',1,5,7,2,0.034235,'Custody Steel','none'),
(1298,'mid','mcpbkYUtEq3M2EopN1pxK9skD4Bm6HKhJq88QuWL6U13',5,3,1,9,0.029700,'Deep Signal','none'),
(1299,'mid','mGiYtmAX5HAemsqy6X4aRNeKowyVJVK8Qmoz6nrXuoYJ',5,0,6,5,0.090780,'Liquidity Teal','none'),
(1300,'mid','D3ZgumSiWdp8DFhZnDAeX5b4k5Pau8VS5Smaq96YSf81',7,0,2,3,0.058500,'Deep Signal','none'),
(1301,'mid','szmh8AgXDbigwRrtycN5pfRnhsiWSkKH9oeSwrqjFtR7',5,7,5,2,0.033460,'Index Indigo','none'),
(1302,'mid','AksGGDM4EhFnTNGkzD816oABgJ3fd2EjxwntURDjpyXC',6,6,2,3,0.049870,'Settlement Violet','none'),
(1303,'mid','EcSZF2dbJrFeYsBa2irRsS8Sd329EKN4Nzu4AAVqFTqF',7,9,4,5,0.041240,'Liquidity Teal','none'),
(1304,'mid','GaFa5Wv5gamCwswjycabg5dD5nKmRu9sZ3g21Pv3no9a',6,0,7,3,0.035040,'Terminal Blue','none'),
(1305,'mid','fUY4KUcHijXi9oLnkDU8qttgqqAssPkfYf7xa7QVbyPd',4,4,1,4,0.047770,'Custody Steel','none'),
(1306,'mid','jfGFmzXWAgZGyhbAsLRemz2powVAcxnjUi5sBL15Hm1k',0,3,0,0,0.045450,'Deep Signal','none'),
(1307,'mid','3LfseBDtcjBGeRAVWWrkoeYfXHJskZfZXHb18hmnTbBz',1,6,5,3,0.060635,'Custody Steel','none'),
(1308,'mid','Dr8paGPhjJ8StpPyjapyTaRZDcwASuD35GVnxxub6gPD',2,1,3,7,0.042095,'Terminal Blue','none'),
(1309,'mid','gZmPayxihtg6QKbwdAoQGW5bmVN3PfHkKRx7wVud3PUC',0,1,5,3,0.044025,'Custody Steel','none'),
(1310,'mid','TALJmSLffFVQanLaNDuERFuACU3V2DzrAzzvKaKd7Z8h',2,9,0,9,0.068485,'Custody Steel','none'),
(1311,'mid','S3C1GFRRLiy6UFpj1tPLeGvHfVqFf8prMuoPMxVS4UpV',3,7,1,9,0.027160,'Index Indigo','none'),
(1312,'mid','NRxW9vk8h6PFttD5e7gHVUPeSyFWvd3bgUWYbQf96AkT',7,2,3,5,0.039280,'Settlement Violet','none'),
(1313,'mid','Up7gsYSyU5E3hGoLrLHwgLTep3JFSi56CvUi7miDGR5D',3,3,4,6,0.033120,'Deep Signal','none'),
(1314,'mid','nvM59hZjfJ2SxaapvFSTbJXk7KEcQNrfP425Syi7uv9w',0,5,6,2,0.027300,'Liquidity Teal','none'),
(1315,'mid','u2sTV59TSxUrrgnx22FMjLBtdgHfEni2Hb3ENQmzSoMB',7,6,3,3,0.067040,'Custody Steel','none'),
(1316,'mid','KduQXvfLKK1CwvoryY3xKAUHhKPc3ErsSFBXQJyMm4rt',1,3,1,9,0.037685,'Custody Steel','none'),
(1317,'mid','iYFNuxpAC3PXMmP6tWaRGLVF91ATL1FytxoumBZ1a9hW',0,4,2,5,0.066195,'Custody Steel','none'),
(1318,'mid','L53ZquwQpY9wXrGrH2yBgL3mqMahVE3x5N7k13Hteg8N',7,6,4,8,0.041490,'Ticker Cyan','none'),
(1319,'mid','xzX729DGMsb44oA4kgDPG413fr21St8ewyzNAxqpxiz7',3,5,4,8,0.041880,'Terminal Blue','none'),
(1320,'mid','RWF8vRdSF9UAVTif46PEnxcveEDuytFctwsBAxoXHVWH',7,6,2,2,0.041420,'Liquidity Teal','none'),
(1321,'mid','rH1Y5DFprEXottpcfY1rRbfDAjSGnYT1RvETpmqTGU6c',6,8,3,4,0.037060,'Liquidity Teal','none'),
(1322,'mid','tBAVqNGyDSi8dNP4WKnZTkxTWpLPirrZPbaipy3NGNZu',0,3,5,4,0.041380,'Terminal Blue','none'),
(1323,'mid','c6Axw76BtgRDP9nKaGkJGBEoSBySGUWgf1VqGLrwnbjq',0,4,5,3,0.061690,'Terminal Blue','none'),
(1324,'mid','ys6VgXHYo3rkqdXJNQwA82XfVeeYQBTpb1M94E5SeKjR',5,3,5,0,0.037470,'Settlement Violet','none'),
(1325,'mid','Rn92yp7D4WEbBC7iV1avuzawRaeTfTydvNELnnsEtPza',0,3,0,2,0.053735,'Terminal Blue','none'),
(1326,'mid','EnMSk4QpwpCQn3WNGmEEVazffyZnrrfaKRch6c7omC74',1,7,1,6,0.086780,'Liquidity Teal','none'),
(1327,'mid','Ns8UYVrZmik2GRp8sRGFAtqFmqhjE4NHikFX1KprLPos',7,5,6,4,0.067675,'Ticker Cyan','none'),
(1328,'mid','inaAMay89v2uXNCWeKbaM3FfvYg4EkDtbUVHnZu2TT3d',3,8,6,5,0.044120,'Settlement Violet','none'),
(1329,'mid','YVEG3feTuFHPdC55ZTAirAnBcMeCrvXMcmZ4zssexake',1,3,3,9,0.061910,'Deep Signal','none'),
(1330,'mid','epuwDVFxkKBeNW9oL8QkAgSk8A6HWWyYziQtRSDrzzj4',3,8,5,0,0.035200,'Index Indigo','none'),
(1331,'mid','HzMv2KK4jW4thpPAUUt1wouwctZScTpvXEgHVufoceN3',5,0,3,2,0.036760,'Custody Steel','none'),
(1332,'mid','ek9i6eKMVndSZ7gMTM2Arbi8kEaqar8pBAiuNgaonsgk',2,4,5,4,0.053505,'Settlement Violet','none'),
(1333,'mid','fGximu1suc1879RHrxK2qm2LRkaBUG3s5N6jXWdicZ2s',1,8,2,8,0.028680,'Ticker Cyan','none'),
(1334,'mid','VBZwKNbhv5QieiZwk3ULoqvERSse4xdTM7pxdx6zUxcf',0,1,2,5,0.047880,'Ticker Cyan','none'),
(1335,'mid','VN5DQVpUBGyBo5U39QYCTzQ3BQGD8mRZKqein2XNLhoq',0,4,2,2,0.038500,'Custody Steel','none'),
(1336,'mid','yJNmkQfDBWxTbSeJeLH2vgScp7Yjs3F28PxzAGFYa1U1',7,1,7,3,0.035720,'Terminal Blue','none'),
(1337,'mid','WvfuRkbFfitHbAWMyvvyryeWpwbEtaB9W4ptAEmoW2t5',6,5,1,0,0.058840,'Settlement Violet','none'),
(1338,'mid','WAAbktv31ejbxfXcSK4FDgmbSNkX7CTXKtVT9Aa1pnJV',3,0,1,7,0.042055,'Custody Steel','none'),
(1339,'mid','dNAZehfn9jWP69Hcr7gw1bu1VdNq1kf5aM5ARwYLHRd2',6,8,4,0,0.038820,'Terminal Blue','none'),
(1340,'mid','Po428xirDzQXbvaMY7ManVB1ZNxDyXyT88MNHFNdCeNY',0,5,5,8,0.036900,'Settlement Violet','none'),
(1341,'mid','232aZz5aRPXYjvHv9z3M9uWeYkcmsWhEZj6Qejq7F2vt',3,7,5,9,0.032870,'Terminal Blue','none'),
(1342,'mid','E1zuNFqE3pYycrBbzmvzHEmhvobNrHwhJgDb4NqT12AQ',2,2,1,0,0.053300,'Custody Steel','none'),
(1343,'mid','PxsnFpDqCYsqoTV1pBWEF8U3G6nfBC7j8BJsxLLATZPa',0,8,4,4,0.048060,'Index Indigo','none'),
(1344,'mid','e8mhFkTfqW52hD147eSXVaUazSRh7tma3Z64ZNQvQnbh',7,8,4,9,0.029680,'Index Indigo','none'),
(1345,'mid','YYAoEfbFTXjLNeMLfwibg7jod8dco1vzh2KW7i53WPdf',7,8,0,0,0.061380,'Index Indigo','none'),
(1346,'mid','52dr2BEwYpbU6RqNmbSdyU9cp1vx1KVcf7WYcEd18nfk',6,0,1,7,0.026780,'Ticker Cyan','none'),
(1347,'mid','Kx3awtue8xbhZmJLLJMF4uhEb3Fp74gq46MWt4xTYaki',4,8,7,5,0.040070,'Index Indigo','none'),
(1348,'mid','VBb5WSCoXVHWhudmfFwVoP1JWL3zoUrjdnaXhyPx6Qa1',5,6,7,7,0.093510,'Settlement Violet','none'),
(1349,'mid','ot6a1yAF2FL6DWyoWvAZtjCdJvniu4rUzNr1fRDh3taR',6,1,0,3,0.030420,'Terminal Blue','none'),
(1350,'mid','2g9FLoU44iznzUCRYy4CVNjm5NJ57qhVARkz3bM9aCXV',0,4,2,2,0.036910,'Ticker Cyan','none'),
(1351,'mid','bkqu1JNXmxJ9PkeAbr9gDokt92f9xUeunPZPGJJZGeMJ',6,1,3,7,0.064540,'Settlement Violet','none'),
(1352,'mid','XjmsoSJPXA6QcLXSbnY2wxwdfQRADUSjhVRyryqZdsDx',0,0,4,9,0.062415,'Deep Signal','none'),
(1353,'mid','yo6qEJMkXc7CQimxpkzUh4pkkDW7zJjNcAPkiKZ2H4hN',2,9,1,9,0.038430,'Ticker Cyan','none'),
(1354,'mid','N26xAbZdXUqHGCvyEKDHn59orFpSpWjLp3dPcA1zCGKC',4,5,1,0,0.049840,'Deep Signal','none'),
(1355,'mid','kgesoLaK7yT8z7giBMjG6QVWU3LASbETwoKxB6PRrhBq',1,0,5,9,0.051515,'Liquidity Teal','none'),
(1356,'mid','SQf8bCALewZ9FZDUZ3UtWebs54Y9TKmjHhr9J6kRewuf',7,2,1,2,0.051860,'Settlement Violet','none'),
(1357,'mid','LwumaTg1WXQ9UCR42hHz87VZmZU8xpv7jRSM5nQEX9bK',7,7,3,9,0.042230,'Index Indigo','none'),
(1358,'mid','yqZSQHx6zk219gK2kaARdUWdyWv5zWvUuaJq7dTSxNkd',7,0,3,2,0.039645,'Custody Steel','none'),
(1359,'mid','duNrpXGxHhdCxLZ5vV2CrxvwkwWhbqXCZfJgVoHc5ZLG',1,0,0,8,0.061495,'Terminal Blue','none'),
(1360,'mid','cTSKaA5gfXiKP553YLBX4qJCaep2WMQrzeU1ErdG7Avn',6,3,5,8,0.052150,'Settlement Violet','none'),
(1361,'mid','hza64X86GAMMWEVW9xfvXf5pkNVygQneVEt3dbTGZEC5',3,5,1,8,0.064260,'Settlement Violet','none'),
(1362,'mid','tSc8Htu7Xh8HLPaRLyoi6V5HDUXUb2NUtBZSDJQHXZYP',3,8,7,2,0.049335,'Custody Steel','none'),
(1363,'mid','bsVfrUWdwfFfoEZ1nceBCu5wGrEXoHmk73mCKTLgDKL7',4,0,1,9,0.057080,'Ticker Cyan','none'),
(1364,'mid','p3fntJ3NmNGoDMuE1urr5QJdS2wEHppV3JLPvwxGtM4i',3,3,0,6,0.042095,'Settlement Violet','none'),
(1365,'mid','w9smMnPvGjt7LFz5ycLE7PjFYpfjbs8B9mopm4GFxGdB',4,2,0,9,0.049350,'Deep Signal','none'),
(1366,'mid','qB4AygUJW5AVkKCpnv4c9eXhBVaQYSkNSG9e9fxpd3kF',2,5,4,5,0.056885,'Settlement Violet','none'),
(1367,'mid','cv7cB649V9nqWJehJsk1H5RckSVHA8ADaXeWSxF7XhRm',0,6,6,3,0.078910,'Index Indigo','none'),
(1368,'mid','BZvJT2vTh39m8UQE33cjSPbJ3QwuGpBsiZmboy63WUio',6,7,7,0,0.034320,'Liquidity Teal','none'),
(1369,'mid','fUd3aov2HpQECYXnuKfxqHzjEmDYSaMUARXahNiqgWiK',0,5,4,7,0.056625,'Settlement Violet','none'),
(1370,'mid','nsSRSZu8rXQBxESrCZs4SPwMVSemLapau5BVJvEZt6jL',2,5,0,0,0.036280,'Index Indigo','none'),
(1371,'mid','kCNE67WVtwbNBiiFd7Zk2uqaYz2wDrzEBtaoXqrcCY5H',3,2,2,4,0.043520,'Index Indigo','none'),
(1372,'mid','o3ZKdJhmoeB9zVPNzqdJxN44q8iqnY6CjMuJ2cvMjW9i',6,4,1,2,0.051440,'Custody Steel','none'),
(1373,'mid','8JDBkbGxpiRZFXCJj9dqESzwMY8p8zAjzMGGutcocmM3',3,8,4,0,0.099510,'Terminal Blue','none'),
(1374,'mid','rv6EF3FJRV4YH3JpajoiP4B96XfvFVKMZgJUbrL2pQCv',6,3,7,0,0.048215,'Deep Signal','none'),
(1375,'mid','mUM61HUiW93N9jz9q17gL9NPQfBqfMjV64YzRRitwpNg',5,9,2,5,0.037800,'Index Indigo','none'),
(1376,'mid','j1a7oAHwNxTq3VorspZnZTnkVPdJUq4yGhrgAxg11sZ8',6,4,6,2,0.046520,'Deep Signal','none'),
(1377,'mid','XCK36ot92Es7epokXvowF2f5jvXoEQwwfq8BjQ34nevB',2,5,1,4,0.041685,'Terminal Blue','none'),
(1378,'mid','uURxCkPTR1wP4BGmAfMxkScUoWxukfKmCwRaC7i9MDee',1,9,5,6,0.035300,'Terminal Blue','none'),
(1379,'mid','c8zJXfHvQynoK9RQDF87K9H8f2kAowpxHQSn9RAo7QK7',6,9,3,8,0.037280,'Ticker Cyan','none'),
(1380,'mid','AQKXBU59kMUPA6EJA9guqFspu8bPGLFXrhPvrxQ3vDXJ',7,1,1,0,0.043480,'Settlement Violet','none'),
(1381,'mid','QXnjtDp84kF4zVRUJh8o478sVYiF2KY29AVCEteLQSjm',1,7,3,4,0.032860,'Index Indigo','none'),
(1382,'mid','6a3tTKNCnY3rRpLVeR74Ma3K5od286hEkD28Trhi8wR7',7,7,1,5,0.042830,'Ticker Cyan','none'),
(1383,'mid','rjhosnSViUtfu5UcKJcXMowGNaDC2g4pitqVkjjPEjXv',7,9,2,2,0.055720,'Settlement Violet','none'),
(1384,'mid','sQeDczmjEeBFF3tJDUZX5GbA4AQ6UUxVVKQjSSfeEBez',7,6,5,4,0.046355,'Settlement Violet','none'),
(1385,'mid','NsH7GPuR35QD9j2wLsgnvBkvscGA3UXcyvpG6jpxvJRA',2,0,5,9,0.046605,'Custody Steel','none'),
(1386,'mid','oHHAr1bvtPupN2eXJGt4eQfQuqHQTdjYmw5h5ZugzvZY',0,2,6,8,0.052720,'Settlement Violet','none'),
(1387,'mid','ySKavReKAWpr3RFiWeT7qBawoJvyAVL7HWhuMg9Ay5Pt',7,1,7,3,0.045590,'Deep Signal','none'),
(1388,'mid','FvsHRvtuizvvu47RW2v7B8ECwVR9pdR3eYtfyrUoXF8c',6,5,0,7,0.047200,'Ticker Cyan','none'),
(1389,'mid','irAVzFyAApvmW8dqk1a9JP4XKSKSn69Vk49A9cDY9ueh',5,0,5,3,0.064290,'Deep Signal','none'),
(1390,'mid','iUsWDCS1p4QpU3Y5ZWWuxk8wLvHkzLjPJcujQJMFKWTM',4,7,7,3,0.062195,'Terminal Blue','none'),
(1391,'mid','2CV32GsY3hxRtHdsRRHjnQZjAgnXfVSSQysZ4p32wurD',2,8,2,9,0.042350,'Deep Signal','none'),
(1392,'mid','6TqLwWHVeG2C2iimCNpNtDhzUZqirHM58Q5moEP1goXX',7,3,7,0,0.068150,'Terminal Blue','none'),
(1393,'mid','TUs2wqEFrN5JjFipnpm4cEfaUqo2PtdRZLyCu2miJZ6X',2,5,5,3,0.051795,'Liquidity Teal','none'),
(1394,'mid','ZQ9jZZKiSwpsD7c9pnp3GomMyx5iv6fEzRq25wkcSQLo',5,6,0,6,0.035450,'Settlement Violet','none'),
(1395,'mid','JZcd7KeyNYxv9i7RsDq9ikj5VmJu2BCapcXL7LB5BGmh',6,8,6,3,0.054170,'Index Indigo','none'),
(1396,'mid','L1Bb2SFarbUkWaTzSFJgigTnp4143ooRjU6kPnMfxSCi',2,2,5,0,0.037710,'Liquidity Teal','none'),
(1397,'mid','17fJuzMmqAQgoYMrycGFNHS81rjyULwBcWytA4e3BCqb',2,1,7,9,0.029040,'Index Indigo','none'),
(1398,'mid','UEiPFAfd2Rn96iXDJmU24TkTW698FfpFy6YK3rfdSKkQ',1,7,0,5,0.038640,'Deep Signal','none'),
(1399,'mid','azaVktj8DTgE43wYNmEzLkQ3XwWkSMC1MGKvHotjSV3C',5,5,5,0,0.038220,'Settlement Violet','none'),
(1400,'mid','PCFazRDBqbhHhf2XBJYrGhgRDGpuxvBpsWCHUQdp6z5B',3,7,3,6,0.055830,'Ticker Cyan','none'),
(1401,'mid','epFMgNFrqMjJ7JPH1DwRhmRiCZrjrGU56zg83QUtD1v2',3,3,1,4,0.036860,'Settlement Violet','none'),
(1402,'mid','L5UGFiGXtrSdWQwavSiRwANDGgBLym7iGyD1oq8jRJXF',0,4,6,5,0.034030,'Index Indigo','none'),
(1403,'mid','wkZBRc7AaTbFHoEkMpyAKkXVxuHjVbnbzsmtL3RYfkea',0,1,1,0,0.044600,'Settlement Violet','none'),
(1404,'mid','2Q3brDcdc5VRPPevaCtdzUJsJ2mVpFvtB8iT4VsHCy4X',5,4,5,8,0.037995,'Index Indigo','none'),
(1405,'mid','ZVU1jJ6SxEjMamumQ8QXs2UXheBdBHf93BDRDjd3ALMX',3,1,4,8,0.048130,'Liquidity Teal','none'),
(1406,'mid','ExSfwNGG1z5JKzEqirVvAMNNbTb6rziST4szMRqkNPYp',4,5,0,9,0.055190,'Deep Signal','none'),
(1407,'mid','1BnBVS1nApey4MnuP33yUmkehs7W2J7ZzLkqe6FDZL6c',1,1,0,3,0.032360,'Index Indigo','none'),
(1408,'mid','vRXnsvKNXWdJUad1fGEWGoRy7z6duZ9TZ7bRf9JX48CK',4,2,1,6,0.061490,'Deep Signal','none'),
(1409,'mid','JnMMZBd8mqtsFxW9jsUBPneHX53BfjADL5T83CpL1NuU',4,5,7,8,0.048070,'Settlement Violet','none'),
(1410,'mid','8ZDYvD7yFEktrmNwdhmUJxk96XX755D7NjBzid7NGCi8',0,4,5,4,0.029240,'Settlement Violet','none'),
(1411,'mid','8MwbFAihzHFm3pBnzYLygohnvxBgm7RWsGea2SKuT22k',4,7,0,5,0.036940,'Ticker Cyan','none'),
(1412,'mid','63WbPt3Kr9N6aHpw6WWzA57WQQMiiwJ28MnAHwi9Ab11',7,8,6,8,0.080715,'Terminal Blue','none'),
(1413,'mid','bbbHa4yL2xUuGdrHvbALhEwu24Vy9gEZb13QAT3ZtE28',3,0,0,3,0.043900,'Settlement Violet','none'),
(1414,'mid','7gNrvjrZuQaLFJRfN3wfWwr1oVaT3tbD5EDgyUZ9kxLj',3,8,6,7,0.039135,'Index Indigo','none'),
(1415,'mid','her4nUdPkRsVgPECU4jbBuFkUSZyRLhXqWGEBJynCYbx',0,4,4,2,0.025200,'Index Indigo','none'),
(1416,'mid','UcLM5uSakajAiBAsKi9FHFSA7LGa8YGjxRLzdVR8dSs3',6,9,1,6,0.042020,'Deep Signal','none'),
(1417,'mid','NNHUTk1LepKwVNJTNEd6KepkL1sbpbuo3ksbAUGtjD6J',0,2,7,0,0.045660,'Ticker Cyan','none'),
(1418,'mid','r5mH8oSaG5r8hEYBuxzsXTSLy5yVMAsfRwgxxQtuNGKX',6,1,0,2,0.044610,'Terminal Blue','none'),
(1419,'mid','csV9oFgT33rMVBvYNxnQLwpo4DxjwhjFN1QfsP4fSD7X',4,3,6,8,0.035000,'Liquidity Teal','none'),
(1420,'mid','5XcRZnuaxPL25PHCPLwpWGkYsPBrJVvBdZGQkXq2KYuN',2,1,0,5,0.055335,'Deep Signal','none'),
(1421,'mid','cGUs3vvGvxU2AjArEuCbAdPbe73wYipAsLfpsgPd9DcX',5,2,7,9,0.059630,'Liquidity Teal','none'),
(1422,'mid','9FSSS1FxpUoZ4LhGcsA3jwYxqF5mRdjosa2J8medurHs',0,8,0,7,0.036680,'Ticker Cyan','none'),
(1423,'mid','oNRXRg3dR2aacgdviquBX5HsDK6UoEnXcW7HZfFsRVbr',3,7,5,2,0.035680,'Settlement Violet','none'),
(1424,'mid','kGc2tHCo9rGieHzPsa4Ft2SDiGcsaSLjVK6q2hYMt1Fb',3,4,7,2,0.048910,'Liquidity Teal','none'),
(1425,'mid','XfN8nRLydyVt9CNP72UPKSEukAn6Ch6pN2rVyXRxztHM',7,6,7,3,0.037280,'Liquidity Teal','none'),
(1426,'mid','vF3edQdbpTQWQrBT5ZfN3naFfpxhqsCijowBfFPVhzVB',3,1,2,8,0.072100,'Settlement Violet','none'),
(1427,'mid','ku3pvhzjrLSdirjWnUd2VBVTCUr1X8W7EY6QUFLptcFj',2,2,2,4,0.042100,'Deep Signal','none'),
(1428,'mid','GvjrC1HdzrLnWh6bLgih9yp5aANsqTghS4fzSVJn4gP5',7,1,7,5,0.051410,'Custody Steel','none'),
(1429,'mid','CHxYPAxZkhEWsD9t41xQ7kzxvzoGTWk1e785bht9xRta',6,4,4,3,0.037400,'Liquidity Teal','none'),
(1430,'mid','qZfvV8YvEvvfNtwBPL5TTNcSfK3ekPzY4jSERuppLXeV',2,7,5,2,0.028740,'Custody Steel','none'),
(1431,'mid','d19oSH1W7D6CHBfnuBGFkDjXAgeyxahSascqZkj4EHsJ',6,6,4,8,0.040060,'Liquidity Teal','none'),
(1432,'mid','Qbt9ncnYKYvjWsTwfaMbdNSKDQP4oLp7mzcRieESH1Mr',0,3,4,4,0.034130,'Index Indigo','none'),
(1433,'mid','KaT72EkWixRJzU1sNetTR3tnBGYzEkmDt1BUvEadD4xj',5,9,3,4,0.043710,'Settlement Violet','none'),
(1434,'mid','SActBN793dtwLAWD1cccQKcZuBrTE4ux1nZ2stGsKZtg',2,7,1,0,0.041360,'Deep Signal','none'),
(1435,'mid','gaRkkWcfbc3E37tNkMEf9sS5TZS8cqKm165X9kfA7sSn',4,4,4,9,0.039560,'Ticker Cyan','none'),
(1436,'mid','FFWM7H5cX8cniorbjBXa11muxuS2hBoy8DapudodUCJg',3,9,1,2,0.029140,'Liquidity Teal','none'),
(1437,'mid','6SYC5yzhsJsDLWviMgMTbbJSVs44ycRYvbEHF6uNmEHt',5,2,1,0,0.089050,'Custody Steel','none'),
(1438,'mid','H2U88NVUvw7BvytCYNDEQ5iYqqSZjFTiMT4mUCP8xj8S',4,0,5,7,0.047620,'Index Indigo','none'),
(1439,'mid','xqpXvTfLiKZgZvktXHkZfMeysJPiTf74cWfBu7vF835d',2,4,3,8,0.051175,'Index Indigo','none'),
(1440,'mid','DgmUsdTHu6XmntDFRjKVjcA2C8y9HALA3qgiNoxghgWp',2,3,7,0,0.050540,'Settlement Violet','none'),
(1441,'mid','zsar2Uvp7QqWVhcj5A3dsDjFEZT678jom6nHoH57cmYY',3,2,5,7,0.076095,'Deep Signal','none'),
(1442,'mid','DV71sC86jUVXPxbKDdVZ3if1FQKTATpCNej8WHDZYWMD',4,0,0,0,0.046095,'Custody Steel','none'),
(1443,'mid','5T4usMupkiQxP5uQ9SESk1PbeGHtXMFqMpkTCxYNSnyT',0,4,1,8,0.053125,'Terminal Blue','none'),
(1444,'mid','SozpMA2rPXPdLedqg4Ai1htowPVyo9ZUeKg2BZjPBtnm',5,9,0,8,0.057900,'Liquidity Teal','none'),
(1445,'mid','XMpbhu31ipzsfv8otSUSCT4edmeuHYvMAfzY3zhtm1hZ',5,1,6,2,0.055215,'Settlement Violet','none'),
(1446,'mid','hwxDfCL6U5CnL7bF8DBja6jtUGzPW9vAdvH7u3pKRVKs',2,4,6,6,0.035900,'Settlement Violet','none'),
(1447,'mid','e1xg2uEbaQMKg6BJCikPzw99vt2Eu2AMLw2SsTb3ygBa',5,9,1,3,0.049750,'Settlement Violet','none'),
(1448,'mid','FuPbiwayn5GcoPmSxci8FjUHxZ1yHJiy7Zy6kK6Mcb2M',0,2,3,7,0.033460,'Custody Steel','none'),
(1449,'mid','QQXwCCeBq7vWKHxtWjXJR6GwBJMm1otwfsqf2TrwDman',2,8,7,2,0.034870,'Custody Steel','none'),
(1450,'mid','F9k74zGVxseY6XpArwRRpvWpaneRBziggSgADrhU14Af',0,2,3,6,0.052810,'Terminal Blue','none'),
(1451,'mid','bC8LPBsM91pwJrfARrcrGBX4MfLXJR6LqkA3YGhrXjab',7,7,5,6,0.034600,'Index Indigo','none'),
(1452,'mid','6Tf8UrHZ9TTDv8DMVhYKprVmcqorxvJVZyPyb6cpeUqX',6,9,5,0,0.031500,'Custody Steel','none'),
(1453,'mid','K4xceoDEyeBEA3DBfpQY2Z1RqKAg7hsjjDqSYXLLnMhh',7,3,4,5,0.036520,'Settlement Violet','none'),
(1454,'mid','wAJXu4KQxrx9zVKSm88P1kwVWPoxDZmctfMA15kpbrQQ',2,1,5,7,0.056460,'Settlement Violet','none'),
(1455,'mid','91YeDcTkFymsSkyx7g3h1UBv4qLkp7gTdcxuvR8nyDuX',5,5,0,2,0.046800,'Ticker Cyan','none'),
(1456,'mid','3V4FiejW3r1hRda3QCEadQrLyNWMj2iExyA7A5Tt8A7y',5,3,0,9,0.048605,'Index Indigo','none'),
(1457,'mid','1tKeL1aaEayETgxCuX4AzsVQ5XkUXSUxVssnE6qSdYQF',5,8,7,4,0.041180,'Terminal Blue','none'),
(1458,'mid','CZBeKVpQLzgB9VBjHiPsNUpY6FMV3gxJe7j53f6bGCLo',5,5,2,3,0.040160,'Liquidity Teal','none'),
(1459,'mid','BgbFNdtqzyhArWTYBG3Yk9n2jk99u9umu6a7V2u48dHg',7,3,5,6,0.039660,'Index Indigo','none'),
(1460,'mid','5MLVhUKotTtVDE6k3KUspfg2hetatAgA22m4oHkK1T6R',1,7,5,0,0.077395,'Liquidity Teal','none'),
(1461,'mid','DhJMqccAa3WMGRqSC6ZGNAiUysMHZZaLQP1U1TeRDn3W',6,9,4,2,0.044410,'Settlement Violet','none'),
(1462,'mid','6Aot9SSWYry3cxywzGezPi9U3SrZ5MwmZ1MVJRmozbZe',1,7,6,6,0.054720,'Index Indigo','none'),
(1463,'mid','TnztdpifVizx9uk2UzKBRMmTNXUnXyfWf5ffepnKSJDn',6,1,1,4,0.044590,'Ticker Cyan','none'),
(1464,'mid','srLeMXTJKHrVJ2e6qUxyQJUCMwVrtKCJEMry1UZPCsjc',3,9,5,8,0.046910,'Custody Steel','none'),
(1465,'mid','CC3wXQTE9aCHsqERzpuL5x8NywvM8fHfr2MEzBHvLL7A',2,9,2,3,0.033735,'Terminal Blue','none'),
(1466,'mid','i3ebKZ3ypMHXzN6MfjnHcoBiozcqiHUowbTuJg434VLH',5,7,0,4,0.058390,'Terminal Blue','none'),
(1467,'mid','v2fQh7gAPDbV63tgMuuoikF4HnwJBM4fVbX7z7JAEacj',0,2,6,4,0.044260,'Liquidity Teal','none'),
(1468,'mid','8ur8toEuAnYXjDdSLHo98ULwCTkkxbC3maY1Tq2BhtAC',5,7,5,2,0.039560,'Terminal Blue','none'),
(1469,'mid','bBpqQ1SRjGQPCxhtutSE6UJDiW87uDLDYqSaGNNCwYuC',4,8,7,3,0.036280,'Deep Signal','none'),
(1470,'mid','4bGkRUdYzn6AT3Q2s31Udxjf9yZgzR49UkV6o5SUFvzw',7,7,1,9,0.026520,'Liquidity Teal','none'),
(1471,'mid','t3dcoKWXCiMN618DaiWGYNjdRkgFZUdMu4wEz8fNAKp9',2,1,6,6,0.050840,'Ticker Cyan','none'),
(1472,'mid','FAZ9d3DBwVgpuDckN6CWsMt7z3WachJbh4E72zeLVquh',1,6,4,0,0.045900,'Liquidity Teal','none'),
(1473,'mid','7yvgQ1aAjXS2ssXnus7L4pf9NRGqRngNoQ6qWCJY4toi',7,1,1,0,0.045590,'Liquidity Teal','none'),
(1474,'mid','TAvdK9dcUw7m1WMXM31mZnZagBGS2DAGwzcEaug1B1CV',5,0,1,6,0.058105,'Settlement Violet','none'),
(1475,'mid','uW9HMYFBSyNtZCW8jFUUHUsN9DWT1v8vzSAmGxdULMbu',4,2,4,3,0.041370,'Settlement Violet','none'),
(1476,'mid','46j6pfih1nPJV734QaCyAac4VXnohRdLNKQRZdnXqaWd',0,2,3,7,0.058445,'Settlement Violet','none'),
(1477,'mid','7i4fFdoLefxsbM3CBTsXQLVFRuwKQDyBhiGU3wDbWan9',1,2,5,0,0.054340,'Settlement Violet','none'),
(1478,'mid','QvtKV5bjwRcqZ8XZ8pko3ZDtTTvT7FVpCPDtnV4mZie6',7,2,4,4,0.051080,'Custody Steel','none'),
(1479,'mid','TSZ7RS2WpSJbcNgoNcqCu9sJb6LGETJ1GRY6FghDvno8',6,9,5,2,0.044490,'Terminal Blue','none'),
(1480,'mid','McNcvqNyD8Wxcu1CtasW1rcgTR6kugpNeeuSEAE1W9dL',3,7,1,0,0.031680,'Index Indigo','none'),
(1481,'mid','X55Km72bMTetJj2Hw76Cp68YFfnTB44kMEvCM5z9j5mQ',7,4,7,0,0.050380,'Custody Steel','none'),
(1482,'mid','gwofkNLnU1EQcs9Q2ErpYXDdFFUDKfMAuHG2kNiki97C',4,2,2,8,0.034205,'Ticker Cyan','none'),
(1483,'mid','zgdVVpc9eLCwJkpCZJtNFrEF2iP3bVbAVxAsEKXhqFs3',4,7,0,8,0.057035,'Liquidity Teal','none'),
(1484,'mid','EpPtGTWU7bZPktYKDBhXEd43zYJZtTbEUgSaciEnU2xq',1,1,0,3,0.047165,'Ticker Cyan','none'),
(1485,'mid','ohqjdgp8H14xRCkmFM2jbHQGjwzjMvtWLZhi6kW5GZNj',1,4,1,4,0.029760,'Terminal Blue','none'),
(1486,'mid','2s2D5Dd4zBbkyincyUvaRmJGiAHQpNsooTqMmRKRKgac',1,9,4,0,0.054780,'Liquidity Teal','none'),
(1487,'mid','1dhGzSNCaShnGDGp5BQjr3irhsYG1KxZN8CcEhtHm9JA',7,1,4,8,0.055090,'Settlement Violet','none'),
(1488,'mid','wJNg6GSHJCcDuEfj69tk2p2DGgKZnf7cz23AppstfEXy',0,9,3,5,0.040460,'Deep Signal','none'),
(1489,'mid','pnn4wF1HsFrAWgXbaFmm9Cvc7eWQmi2vUjhb45nXTxzV',4,9,6,4,0.042390,'Custody Steel','none'),
(1490,'mid','yjXbRDViDf1kWCZKvj24ZUtzUVnKi2PMFGmLFyN38HPE',1,8,5,6,0.042600,'Ticker Cyan','none'),
(1491,'mid','X9PddFz6hSKUhrzwTemKSFuieU1EXFLJUYkKmcSz3cJ6',6,7,6,4,0.044055,'Settlement Violet','none'),
(1492,'mid','1xcNKFdhChCu1wLYGGfEciTmWYHdwjCzfjUYD6bnKPPM',3,6,2,5,0.041450,'Ticker Cyan','none'),
(1493,'mid','EoXcB3XphsZqP6yUjXjXF5ekfzMEo2Danso1cDAourcv',3,1,2,0,0.039550,'Settlement Violet','none'),
(1494,'mid','YfpYJWDNsVr2B1GzaYPKjicfU81xykKVkorwv3NPvTZg',0,8,6,6,0.035670,'Ticker Cyan','none'),
(1495,'mid','nsa7Jhrh342kXwBUERjGoohdUyx212j1tnZn8ZCVbFsQ',0,2,5,0,0.037840,'Deep Signal','none'),
(1496,'mid','ATLSqeCygLXNgZjBBiVuJDEyqwUBvvV5e9UUtNhmwjfH',6,1,3,2,0.050145,'Deep Signal','none'),
(1497,'mid','3GfFFGniAL62yQGAKbfWqsnb3NRYA9LV8b3nNvZHjTvx',6,7,0,3,0.052140,'Custody Steel','none'),
(1498,'mid','QYKY23H16gdU6Poeok7xvEA9H9hDPHBxKxEao1dZfe45',0,4,2,4,0.045465,'Liquidity Teal','none'),
(1499,'mid','LsyKAk3Vqj2PjkooJfiJhGnnuLcXvnq37fJL6bTyaYMf',1,8,7,0,0.040720,'Settlement Violet','none'),
(1500,'mid','zJ9JC5CB1aFDLfPkToAwv2KCFSTzVSCy3qTiM7c1wkvu',3,7,6,7,0.032920,'Custody Steel','none'),
(1501,'mid','VhuU7e5n7yGuouNb5T1Xc2452DMSDSZtCWqKykjStwJx',0,8,2,5,0.040080,'Liquidity Teal','none'),
(1502,'mid','5kNQq9srCLEUexiWuyrBAbVZh3XeyzwQ8DhmC8sgWaQx',3,4,4,5,0.048975,'Liquidity Teal','none'),
(1503,'mid','1y9P5GCQQe33xznCHgWk8qiJM3TeZngke2QvpReCxEuw',1,1,4,3,0.040440,'Index Indigo','none'),
(1504,'mid','QeWf9yDwNjssAqZvz8Hx3vTV9n1nyVfKbFrMr5rdCMnT',6,9,7,2,0.043335,'Terminal Blue','none'),
(1505,'mid','6x45Hi77SfHkhe7Q5kE4iZpeQz289y7s125MzZu6cDFw',1,7,5,7,0.045330,'Deep Signal','none'),
(1506,'mid','Re8HTdJc9JCcLtEVhPXsmL3HfGHBizgUSR8rwjvJ2quz',0,3,3,4,0.058860,'Settlement Violet','none'),
(1507,'mid','2xnyBvm836X7UVXFmuDqWKoMbd931JJPDXJDViqVP8ux',2,4,0,0,0.031590,'Terminal Blue','none'),
(1508,'mid','BGaexBP86P596meE41hjf9Pm8xtobka7YixRwfrCpd1w',2,6,3,3,0.035275,'Terminal Blue','none'),
(1509,'mid','hGaH8vSJCxynZWTd98phTZuFLd5tDGSc9wScgiKtdzbS',2,8,5,5,0.049430,'Custody Steel','none'),
(1510,'mid','aALZZJaTTKG3AZ4XvBt912bvwS26ycu6NZege34Az3rB',7,1,6,3,0.047800,'Index Indigo','none'),
(1511,'mid','ov1eEfDsFuwDfpuWGJxZEh7wQ1GZpDY2aJqBVtKA652C',7,9,0,0,0.037040,'Terminal Blue','none'),
(1512,'mid','P9eTtZAr1h8pFpWidNtVqqoHRCt9mdS9hvb4s8YjvniZ',3,1,0,7,0.038785,'Terminal Blue','none'),
(1513,'mid','aa7ZmwcQLA74GcBUzx87LjFzFHFtKR3AxjjBMDVX9Zv1',5,2,2,9,0.054550,'Terminal Blue','none'),
(1514,'mid','z2PeuwKiYbXJPZ41wLgSknSmR6JwY7bqC6TSWhnBeVqT',0,5,3,8,0.037180,'Ticker Cyan','none'),
(1515,'mid','aGMpAAkASXt3dLmo9Q55mQJU7S6k8QjjMCfK3FwLmxiM',3,4,5,9,0.026660,'Settlement Violet','none'),
(1516,'mid','cbMAgzmnnMpN4xFUhFwjHxtQo9Pgg2B4og4gfUgsDDJK',1,7,5,0,0.050960,'Settlement Violet','none'),
(1517,'mid','dieexyzkSVPGZ1JWuaTbuPhMnBtjn6Z5cQPVaHGE5soz',2,9,0,0,0.033460,'Liquidity Teal','none'),
(1518,'mid','7kRT9oeQTxoFxixdKTTg1BB8qRHQwxjZzdLQ6TzHDKzZ',0,0,0,6,0.079300,'Index Indigo','none'),
(1519,'mid','TvjpcBdmLpnZbyGU7jUeddA8nnzT19x2XGcxd4ngfYEk',6,5,4,7,0.091890,'Settlement Violet','none'),
(1520,'mid','MSGPtzLYKrLf86N4VJWRc8mPaZWy85ddCduNexxVFWDA',4,6,4,5,0.046600,'Index Indigo','none'),
(1521,'mid','rumbhDMTFqM5TtvRiT25HNuzJMGTZ4dwPV5Nm4v7jCPd',4,8,4,6,0.055610,'Liquidity Teal','none'),
(1522,'mid','HfgvA8YnPQLZhZrNEeyoiZizqashNB55iBEoh56MM8Z8',6,6,0,0,0.033590,'Ticker Cyan','none'),
(1523,'mid','vJsPNSRc3hCdP5ubyd1FMDVT6Q719fGRazWH9du1vBpS',2,3,2,2,0.047110,'Terminal Blue','none'),
(1524,'mid','irZoMpusu2WKr5U83TiVhGMTqwN53d6udXVnUodQGYJJ',2,7,6,9,0.035120,'Index Indigo','none'),
(1525,'mid','hqg7gqGLb7UevySm7ZPofjEWbPWGaUVGjs2Bhse3btqp',7,3,4,0,0.044440,'Terminal Blue','none'),
(1526,'mid','kzvMt2SSbEvAMtztVDsFaRSq9D6WvboX8zEj87oehwUU',4,7,7,0,0.048900,'Settlement Violet','none'),
(1527,'mid','dQQ7TLFYRLQTBU3SkV6mcmKjw7fjr8wLMjPTjFMwck1X',3,1,1,9,0.055555,'Terminal Blue','none'),
(1528,'mid','teVQ8sxjjNh4ZXTfSVazQepx1vyfuV7PzW5pm8gFff3t',2,5,4,3,0.042600,'Custody Steel','none'),
(1529,'mid','EUhYAReVMSBU3DzvdYZiS3zBDw3epj6X22uwsyc2Vgxx',6,5,1,0,0.035000,'Ticker Cyan','none'),
(1530,'mid','2LreDxKvywxPGnDM45GMtqRxNbxAG7Gp4JaA9omKUWTa',0,8,2,4,0.043415,'Deep Signal','none'),
(1531,'mid','imxNAcZkM4akWAQExpjk4TWoGbrwwLHecsCsjJGvJfHi',1,0,2,5,0.062500,'Liquidity Teal','none'),
(1532,'mid','uAsDmjMmRdi8CNPpVvWvN4G2yDZS2Bq1RFcZka2QxRa9',2,2,6,4,0.035820,'Index Indigo','none'),
(1533,'mid','DgebchaCNrahq6cobG1rNEtbk2LSVM4KYmFHYN2vxpMD',7,0,1,2,0.043330,'Liquidity Teal','none'),
(1534,'mid','kQYXfKtKcJNrYTPB6StVCMsDfB1iHNxzJyGQpQRbP7sk',3,9,0,6,0.052865,'Custody Steel','none'),
(1535,'mid','fbWyrnWMouNsiD738wvCcyqdLPxb4hEtuUoyoms16wHK',3,4,5,4,0.045955,'Liquidity Teal','none'),
(1536,'mid','nuZaMDGUtE5rJ8DJiYQYmQgKS5wMCDkWpwuypf2D7SPr',3,8,0,2,0.046785,'Ticker Cyan','none'),
(1537,'mid','fME2ww8YmXKte1N21NYHc2GxhMBgik8pK6mPnqP4dY8P',4,4,4,0,0.034070,'Index Indigo','none'),
(1538,'mid','6QcJYpBgHgkLj5Mk5eBQB6cM1VQWfbEbqWHSSpR4TPwV',5,1,2,8,0.037020,'Terminal Blue','none'),
(1539,'mid','zP4cqiRH24H1Sjdc6qKF91fFJT6rr1pvRkJ1wqgd8vqw',3,3,2,6,0.049065,'Terminal Blue','none'),
(1540,'mid','u7Cs4GciQ6CEAWsVogsXnQEEjkW8ecxdDJkGQBeNRAox',7,6,5,2,0.051010,'Settlement Violet','none'),
(1541,'mid','AJtqqPF66aMHUcJrAPniNXGonpWx5syTW1tTvTRYjYTi',6,1,3,0,0.045500,'Deep Signal','none'),
(1542,'mid','FgwyX3diRNDJCDHMTSwujVccavrm4odUm6EhRrXRGrES',0,5,6,5,0.062745,'Index Indigo','none'),
(1543,'mid','9J5J4pCMLnDaX8s2BLyJw58kgMMVTFzRnGGXEkfDPK7b',0,3,0,5,0.045120,'Deep Signal','none'),
(1544,'mid','CXuwPrGbMeTHJ7PkPcNMJpic4RTPEhSwN643bFyi4Bpc',2,4,4,5,0.026720,'Deep Signal','none'),
(1545,'mid','2WvvtBDfJYM5LCDNYRmfW8dVgtatAuYpDuk5AkL3dQd5',7,2,2,3,0.088520,'Settlement Violet','none'),
(1546,'mid','MGYB2nXGFZ8avHQvGK8s1Hok45TnT9R8SDmoHP8qvEwk',3,1,4,7,0.046410,'Settlement Violet','none'),
(1547,'mid','kTgj3P2tNNL4WJTUxTfGovYNzwS7P5A1cNDXBKWAkGqo',0,5,2,8,0.041360,'Ticker Cyan','none'),
(1548,'mid','YcQeuddXkg4u4V3oJDbamq7r6bXR2Q7LREKkkBwoC5Z6',5,7,5,2,0.039190,'Custody Steel','none'),
(1549,'mid','FKAPgXD5kHv7eCwW4viYiWy5MjP1p3s7Rw6Q6hq1W9pK',6,0,6,9,0.043060,'Index Indigo','none'),
(1550,'mid','Z1DUyVMbovPDTcnHqQLtsvWRno5en2CwgGdj2vDGtjXy',7,3,3,8,0.042520,'Deep Signal','none'),
(1551,'mid','uKP9FbFc93iWmbrdsLdXLDmuCcDMTGnL2cCrWKM3HQ8k',6,2,7,7,0.047325,'Ticker Cyan','none'),
(1552,'mid','8qqmnsTLUJELX26WFBFR8h3rkKV1s3qA8Lr6V9nUJin8',4,9,0,9,0.052005,'Settlement Violet','none'),
(1553,'mid','npbZev8vyv8UHbfuZmixATcVegeAbkD7faEt5kAejjbi',4,7,1,6,0.067560,'Deep Signal','none'),
(1554,'mid','o2PcDZigs8ocLddo74w9qbK1EbfevKFy9yRY4gYDA4Js',7,4,5,4,0.029710,'Custody Steel','none'),
(1555,'mid','qqd3qrxRnjqD34qr1a8rGyCdrpHQ3KYUianLTzXZ4Rm9',6,5,7,6,0.041415,'Terminal Blue','none'),
(1556,'mid','s4jUQ2CSLdo7kqffyZ1768ZQ8qp8TowzkzDZHptrPXoG',1,4,5,7,0.033010,'Liquidity Teal','none'),
(1557,'mid','8VcVosEThcWgLatQjNz93KawhoewQa5raQVPGiJorfy1',3,5,2,7,0.042725,'Settlement Violet','none'),
(1558,'mid','rNPPnEzHuSZ3UYDVXjiEfYqhmBSeDQz768odeFLPrnb5',1,9,3,7,0.039240,'Settlement Violet','none'),
(1559,'mid','9TKpLUm5w59GFzzvF9oaiUVet3uexybbayB7UKAu5yYg',4,1,3,8,0.049960,'Custody Steel','none'),
(1560,'mid','k6Yq26yuzBrjkkSyMrR4s8AK8rCUWqvUR5vrzyTTEmm9',3,7,6,4,0.044910,'Custody Steel','none'),
(1561,'mid','cW66CScWVGa49ChfHRzprHBg4VX2zERSD65yVr1RCDe9',5,7,2,0,0.027040,'Settlement Violet','none'),
(1562,'mid','Z3ytkWHvJj47uB6UZtHgo1hMw61mqq35P65PLyxXWMVx',5,7,6,8,0.048380,'Custody Steel','none'),
(1563,'mid','au5HVMJwf7FqFH4ajEywCBXftmBhVKDYkhnUMxW4ErxP',1,4,5,3,0.033920,'Deep Signal','none'),
(1564,'mid','dSJDgcp5szRwbeAAQdF6rJxCrB7wBsJAsrjWU3otmb98',4,1,3,4,0.064290,'Terminal Blue','none'),
(1565,'mid','WwNfHNAby3jgN48FcLSadERNahQiQ8jX1akAr9V1F1H6',7,8,3,5,0.039020,'Settlement Violet','none'),
(1566,'mid','QM3AmSqT7M4cCip3sCb9rNxBkymWYcwuZZfkXSAw4gGf',1,5,3,9,0.039580,'Deep Signal','none'),
(1567,'mid','gxTEVocPPdoVJQswDn1NVZys4spjGzUGPWY7NEoTjAqH',3,1,0,0,0.065435,'Liquidity Teal','none'),
(1568,'mid','suhxZZ6Fdof5PVe7Wv8rFjCk9uebkF9vJfB4A52BN5F7',2,2,5,5,0.057860,'Ticker Cyan','none'),
(1569,'mid','NcZWPP8iFy3h96ZiyZckgc3KosfRJgCXHe6sD9vwLFyc',0,8,5,3,0.046800,'Terminal Blue','none'),
(1570,'mid','7KznnNXBestKojURDfE4g6JCQAZnewE1hLCDtVTKmVk8',4,5,4,8,0.040990,'Liquidity Teal','none'),
(1571,'mid','yHwe4khf7fq3JncDmkzGwpFhdaU4wpDYvdFmT6tJ4hxv',3,2,7,5,0.087840,'Liquidity Teal','none'),
(1572,'mid','ogT9CKdXtmnyYd8Lw5Ca5QYjfTBz4z3eKyCbJvgFLGML',7,4,0,3,0.043850,'Settlement Violet','none'),
(1573,'mid','eQncpeJfhp6fRfQGQJ23Nzesa96twZe5H25k3b6BXQgC',0,2,3,4,0.042280,'Settlement Violet','none'),
(1574,'mid','KPsYbFhrZ1QKV4Rc362ammVmZanEHC7DK9EY5P8MDYEw',7,1,1,4,0.045255,'Terminal Blue','none'),
(1575,'mid','W96ZgNzaTGTUE9U4ix77z8TAqA93k7nEqfhGumai1pK4',6,7,1,3,0.056975,'Terminal Blue','none'),
(1576,'mid','CdWVx6EdsMTke1e3cXazB4u8a3aLYjyfNwxEmoMhkLwZ',0,6,4,6,0.028680,'Custody Steel','none'),
(1577,'mid','41FBPppdZCf8mdMiC55TnwB3dwG5nce3rHsux6ag3cki',7,9,2,5,0.036880,'Ticker Cyan','none'),
(1578,'mid','zCVwYWcUfwmr4eYR8Qpc5cfU48sDCLFtBVNLoU2vSEd2',2,8,0,4,0.047465,'Custody Steel','none'),
(1579,'mid','YCxCigqYfEKipMx4RPgarLKwVahcKJ5HQ9zKvhiLHrJx',3,5,1,0,0.047965,'Deep Signal','none'),
(1580,'mid','LHQtqqpDrrhmbAi114LPfPcgP7k9hLnfpts6dis6rgxx',2,7,4,0,0.035680,'Ticker Cyan','none'),
(1581,'mid','kgGVgS6SbVuqpo5pWczqjMSg5xsngPF6tirScomsd3Lk',2,3,5,7,0.033175,'Settlement Violet','none'),
(1582,'mid','5VquWXVG4bwBrsYbVeFQExL3PkBTUsoypQcubQ8Ti9Pa',3,0,5,6,0.083805,'Terminal Blue','none'),
(1583,'mid','PFUuoRvJLzYBCtbZbhkkTMbeZTYR4ncPTuCqFEZjnyNg',0,1,4,9,0.063815,'Liquidity Teal','none'),
(1584,'mid','kynTF7EBp1tvU3isUYzYz8WAFc9YvnbqsjPphsTqtPp4',2,8,0,2,0.032920,'Custody Steel','none'),
(1585,'mid','cyMFhrRrQi5kMT6k33tFgtPBXwqeJtQcbmDCRNSVaq5X',4,6,6,6,0.039710,'Custody Steel','none'),
(1586,'mid','1z4vzoToR9GPzPcHx3yPZafU6KPDtCmCkNY4dqio1A8L',0,9,5,2,0.043100,'Deep Signal','none'),
(1587,'mid','4XZtEBrqX9pdeSj4PTmo8TQpbErg8W8NdzVxvTcUUabC',2,3,2,4,0.053720,'Deep Signal','none'),
(1588,'mid','tUdTPHsspfH2GrewNcpXG6H4CCTDjrzrANxwboVYukGp',7,9,0,0,0.042365,'Deep Signal','none'),
(1589,'mid','EoWT5F8byRgshAaCj7KTXF2qR2PxHrDyzWyG7PKkLien',4,2,1,9,0.055880,'Index Indigo','none'),
(1590,'mid','c6qdbBGGEVgS2Ub39wBEJGjVqA7beHUwUP8Mumzg9Vkv',1,8,1,4,0.044460,'Deep Signal','none'),
(1591,'mid','PMMgVnfQaC9WG2n5NfufGdemy4JyfAUVVs9D2y4jSWgP',0,7,6,6,0.040140,'Terminal Blue','none'),
(1592,'mid','LsdrC6R8bwbC7AaTkan7T1wzVh8R1Lzxxzk4LfvV6rWc',0,7,0,3,0.027000,'Terminal Blue','none'),
(1593,'mid','7tp9Crt1z96uqMagjmtCDFobZbfiEvWyc3ofZnbHJHBo',6,0,0,7,0.046550,'Deep Signal','none'),
(1594,'mid','7TJiPxLE9SZh4c15rfrJX1zxNDGhb9hJJHS1bSvUjfoc',3,8,1,3,0.043100,'Settlement Violet','none'),
(1595,'mid','zXq6xLfPFsp448fhtrmG4eru5WCT8B7ZUASfhVRKUmjx',6,7,7,4,0.053405,'Liquidity Teal','none'),
(1596,'mid','23Q2gm2n8v2xAfiz2nTeHFbPd5faMzimgY4vszkMVWj3',5,2,5,7,0.057015,'Ticker Cyan','none'),
(1597,'mid','a5UgGBbpAERVtnBeALojHvfHkfBDME1DA8gDZyVLuNq4',1,5,2,3,0.037640,'Ticker Cyan','none'),
(1598,'mid','rVJFv2ENqPKTK19ha2PGjbzja4ARi2PJZrVmrcmLyfg6',2,3,2,0,0.039275,'Terminal Blue','none'),
(1599,'mid','pTK7LXzhtm6y3ESq9LA11kUeDRDWtmNEGYaE9HyxroBm',1,1,0,0,0.033920,'Liquidity Teal','none'),
(1600,'mid','UuXkUstQ28q3sbAiQV1Gb3SmkXfDTs2U2YUnBErN7YMg',7,3,5,9,0.044525,'Ticker Cyan','none'),
(1601,'mid','Vj4eyzfFzQhhpL2E2hwEZQvRtyiU82AHsrqjAu9brp6S',0,2,2,0,0.085575,'Deep Signal','none'),
(1602,'mid','DVgQTRyAVJRqo5AepME9hLCEggita7ntbyqnPRmQHp8B',1,9,0,4,0.054350,'Deep Signal','none'),
(1603,'mid','fkFCqVfGkr3if4frZQTvskCg8F56XFGCHN43fZFoTbZH',0,6,3,7,0.050645,'Custody Steel','none'),
(1604,'mid','QeMnCc5SijKNenMgNuetph8J8WkpqfDtiEiNxkP5j8sm',2,1,2,5,0.050285,'Custody Steel','none'),
(1605,'mid','oGhx6nFBSnpwL9aQBP1omd7vJiNeBQrj6jyMCk3icbm2',5,3,0,3,0.051880,'Index Indigo','none'),
(1606,'mid','x65vE7nM9yF2DUg1Q3D5wmaBv1oNrE5NNmH1g2K1hWad',3,8,6,5,0.045675,'Liquidity Teal','none'),
(1607,'mid','WuJJ68Zc5xb7VHtpEGcXtj8sgtseQNaJ9mhm3mnHs3hn',4,2,5,2,0.075935,'Ticker Cyan','none'),
(1608,'mid','WNWpNDUE52sRDDZYng3rYXvs8F6zw9Sf7QVmsy2piM46',2,5,6,4,0.034295,'Ticker Cyan','none'),
(1609,'mid','pEK8nhvSbYF2RMGHCaCT8fVAfccof5QxrX9c6ShRpenW',7,5,0,4,0.052870,'Custody Steel','none'),
(1610,'mid','jm3PURCSk8s8pJkMTaMChm4yQHD3GKhSskrtpNQ75ZwC',4,5,6,6,0.072390,'Terminal Blue','none'),
(1611,'mid','tkFshURyCF8zX7kjtbDvanvjz6QdCYmdyvtx6iYiF5nQ',2,1,5,4,0.071220,'Custody Steel','none'),
(1612,'mid','bb7e551c3VZLusKGf1MKNMioUhQNDpDTR9PM2mXCVk42',3,6,0,7,0.046430,'Settlement Violet','none'),
(1613,'mid','9Ry4qzifJSq5SEJKm7XqiJmcNZSjw41HVerw8rsxFKxh',5,2,7,9,0.054550,'Deep Signal','none'),
(1614,'mid','oQevacS2tWpKKvcVWLXUpQLnUrhdB2ANuYPiZurRZerE',4,2,4,9,0.061260,'Settlement Violet','none'),
(1615,'mid','4MD72TQcFUtBVHsbUVNJiJGnn1XhwxjJAMTHnXKvoADn',3,7,0,2,0.049730,'Custody Steel','none'),
(1616,'mid','WnWUB7ZeLVgG5noCjg7dH3R9vxpALXvy98CpjyqaRDqV',0,9,2,0,0.049495,'Index Indigo','none'),
(1617,'mid','RVFBkgVFs2ESXa7LHJYWGcMwuHrXbq58rVrSgDSQrEQM',4,1,5,8,0.067060,'Liquidity Teal','none'),
(1618,'mid','x9qtFuPvxkPwVpScDRJxK5YKMvi2p7MFEdVLNufcXmp2',7,3,5,5,0.045765,'Settlement Violet','none'),
(1619,'mid','gAuKZABxPNDf4meSJnVtTA3nJACqeSEkSegnt7Z3p4VE',4,9,1,4,0.033820,'Settlement Violet','none'),
(1620,'mid','TJuowLxMtuQHEy7fqKTzmemwmZyBn53TAoxUrAsXfMwQ',2,8,5,9,0.068710,'Terminal Blue','none'),
(1621,'mid','CchrNKvV1an328jcnpx3LVK9kpqwTtx3hPHL9XBEWDNJ',3,5,3,0,0.037940,'Settlement Violet','none'),
(1622,'mid','ZNnNkmxr2b95abMN6RjTKL8EJRRHH8XeuQ6gGTU39vgY',1,5,3,4,0.044700,'Settlement Violet','none'),
(1623,'mid','2EzB9UMCPvCNaPoXQuF4Q7773MgxB2vaRZdatcBdTAZV',2,4,6,8,0.047925,'Deep Signal','none'),
(1624,'mid','y943xwEhYNhbMKFVRYJBpZjQV7Bgz1PFzEozTApZnT6m',1,1,3,4,0.050580,'Deep Signal','none'),
(1625,'mid','kQDSVoJzZ8ZFPL93pU2yzPZoU4qoPhtAUSaN55eZVf6m',2,5,6,2,0.044140,'Terminal Blue','none'),
(1626,'mid','jtzXisBQqiwsSDMpXh11miy9L6DaouK9i6C1hPdeNtPj',4,4,3,2,0.051425,'Deep Signal','none'),
(1627,'mid','6KiYT2ZLvotdXHKKmK7HLiz8UtSt1F6iNmT9XafvZYgi',1,1,1,2,0.037050,'Liquidity Teal','none'),
(1628,'mid','36v2wJba5A27jGRmBg5jPhyxe2ZCJ3BgVpHDpgeik3va',6,9,6,2,0.030320,'Terminal Blue','none'),
(1629,'mid','1YGrV5wTjPwC193RAY4wtJoU9gHDyJi5tc2pN2ZVK9ao',7,9,7,2,0.029840,'Custody Steel','none'),
(1630,'mid','KQP9CV5vCzZEkutfk3CL3cTzf4YdVnxouoFLYyWzPbew',7,8,1,8,0.086260,'Settlement Violet','none'),
(1631,'mid','tf7n5Lvvs76x4A14nwbCyWAAE1EJpvbjgaVEuqEnfhdX',5,8,3,6,0.067910,'Index Indigo','none'),
(1632,'mid','ZLuy1nJccqp7syEaZjkvtTS4E9PZ9fqDLuodEFwAqRqH',4,7,6,5,0.059130,'Terminal Blue','none'),
(1633,'mid','DRpEei9CpvdisTvuN2yKj2734epwH8iRJsGWKWD1KV4m',5,0,6,5,0.052695,'Custody Steel','none'),
(1634,'mid','Xmj1kjqucJUu2m2bBsUKVDoR5XWyXPedN5urmNzhpJiS',4,9,0,7,0.035040,'Liquidity Teal','none'),
(1635,'mid','7hzSo1oxJnn8kGZX1Z8HVa958M3MqiGqW9WhJjmUa9FU',1,0,5,8,0.047500,'Settlement Violet','none'),
(1636,'mid','5s1JzP9qMXzT1kR3zn6xPVtrc72Ce5fKxkKnZT3PQeRW',3,6,7,0,0.082690,'Deep Signal','none'),
(1637,'mid','xyJgC6iBNmmCgBM8yG6MLXT7jX8cfeQVAxaXtpGubiko',2,8,4,4,0.038365,'Deep Signal','none'),
(1638,'mid','QZBnkXqWPqSNnMeyfPuW4rmBFf74xQeh3ZmRaH9mxv8h',2,5,6,9,0.034280,'Custody Steel','none'),
(1639,'mid','ob58qffNzv1pWry7EFso927tLvVrmjWzYHLdKDizeakj',6,9,5,7,0.038480,'Deep Signal','none'),
(1640,'mid','MWDK2QbQeWJievGVnuNfUq4ofpLv9eDyNbpRcqAhcFJB',7,6,7,4,0.027480,'Terminal Blue','none'),
(1641,'mid','bcGCT7kKjSVtrHnjSy6J8tWZzwNzw9TDn2ms2yNYJ7gm',3,8,1,0,0.055265,'Index Indigo','none'),
(1642,'mid','1GL7L29TnTJrv3Cz7jwEtRusVSVap9xmN6srTzFa2Vd4',4,4,4,2,0.038940,'Settlement Violet','none'),
(1643,'mid','ZgUA6XK5YGTAS1iZRCEz2K8GNKCp7uraDqso2E6bdcLw',7,9,3,0,0.039730,'Index Indigo','none'),
(1644,'mid','xu9i3vqbxYM422CjYypQdDn5i7q8iyJ3PNg2wo38h8By',4,5,6,7,0.034175,'Deep Signal','none'),
(1645,'mid','mXLRbmKM6At4brYAc9BHbbbCe7CYxsjULbhVeeayYm9Q',4,6,2,4,0.047160,'Index Indigo','none'),
(1646,'mid','tAmzt4RH7naQtnPny5pjro5Gouni59iYLXPsRDZnjcRu',6,7,0,0,0.044810,'Custody Steel','none'),
(1647,'mid','PQQ347LpPNaPr9JJV8NCPxoU9tWvF8fJZMEPEQikpemH',5,4,5,6,0.052450,'Settlement Violet','none'),
(1648,'mid','LhwZrF6xKbRabsU1WGhsfbzVWjbNrstzW5LWoL8FFSxe',6,7,0,6,0.047410,'Deep Signal','none'),
(1649,'mid','MoXovX8HaJoRNpaY8oGAkdjJewQJateK18PPXyBd75h5',0,3,2,3,0.039470,'Deep Signal','none'),
(1650,'mid','J4kLqErA9G1UngZ3GqoriR6tJVTuE47cfRVeBDwCiNcz',1,9,1,0,0.047820,'Deep Signal','none'),
(1651,'mid','cYhccherFtDZiQdZE9PTJE34EwdVQgkmSBZtse5JJ3WT',3,6,1,4,0.085185,'Ticker Cyan','none'),
(1652,'mid','omUfydR4r9rxgnFP7WMqQESQ9faRBrFwKJtENSwhNPqw',3,1,2,9,0.043900,'Custody Steel','none'),
(1653,'mid','tDPmHVZBWUGGWefFSibAXHvW1sL5NSN24mEKUygjGn5A',4,6,2,0,0.027560,'Liquidity Teal','none'),
(1654,'mid','SqujQRiTbghuzEeh2UFRATFZMvG7t3oja1Udhsw45gDK',7,0,4,6,0.046795,'Index Indigo','none'),
(1655,'mid','AZKgKSdXfSH4TZjtqvyDbPJ3wKCMVVQrHACzB85Yim1e',6,8,5,7,0.043480,'Settlement Violet','none'),
(1656,'mid','G2UaYzZy6uQCoZ9x6V3JhkwqW7SgpLZfMpqYaokUGue5',1,9,3,4,0.046970,'Settlement Violet','none'),
(1657,'mid','SNK7px5Py4D6UNPPaya1zpxpgw6KueSndvKagR95X415',2,4,3,4,0.048780,'Deep Signal','none'),
(1658,'mid','vMTy1aXFkwPNPxevBANeDe4TjKTXuE8yU4zCsMptEbUL',7,5,5,2,0.043110,'Terminal Blue','none'),
(1659,'mid','dekfSKKYpE2vq3SPKQSbmKCutkPQYkQ859PfrXEU6FRs',4,8,7,7,0.030880,'Deep Signal','none'),
(1660,'mid','XbnwqBRVCjU1oMEMTehDRcp2gbNxxiu6X2T2UomJgpvc',2,6,3,5,0.053140,'Settlement Violet','none'),
(1661,'mid','6SQHhg5CEcp9rogUNxiMJGGtu4QYE9yqvT2YJx7q5Q5J',0,4,0,3,0.054150,'Settlement Violet','none'),
(1662,'mid','dYJ5eDAXcZQr6c9agPj3goVH9aHEYyTXCkoAuRK3r8B7',2,2,0,4,0.048175,'Settlement Violet','none'),
(1663,'mid','TzhpwU6QtBcoLccB17fXZPDT69gquH4oPBf42uZACNgr',0,0,1,9,0.060000,'Terminal Blue','none'),
(1664,'mid','p3a6D6wnYWZJufqF7MSpdRJFzUVFHVuA76EVRTrd5Aue',7,0,4,7,0.031480,'Ticker Cyan','none'),
(1665,'mid','k8C4Qh5nJWNQYMcKaAUxtsyJfa2efPLKbbbAzJ6oHchu',4,7,3,9,0.059955,'Liquidity Teal','none'),
(1666,'mid','4PfbYc39yGmt7TRM8fjkp1VSSsmMPQx9RuzGxrkvUMtJ',6,4,2,0,0.033030,'Custody Steel','none'),
(1667,'mid','FjJ92oVNAjDiY4CHZ4dPanWpDYvy5zwSU9g8t52za9NK',0,0,0,6,0.043800,'Terminal Blue','none'),
(1668,'mid','3ETrBQmUYfJzzA8d1xfKWTgAZAwgG9uEmfNm8tSUMykC',3,1,6,6,0.038330,'Settlement Violet','none'),
(1669,'mid','TvcbS65wiNBrbY5reEm4LQsK2CppV6CWuJcvUGUm4tpc',2,9,1,0,0.067390,'Liquidity Teal','none'),
(1670,'mid','djW9ySBrsiiXzKNhhQirpb6wKbC88hu2JQpJprG2iTin',4,5,0,0,0.094445,'Terminal Blue','none'),
(1671,'mid','EtqoSmUTZfeyPhiHv1eq1w3xGMsD7YbToXzCdAsLJArq',3,1,6,5,0.041355,'Settlement Violet','none'),
(1672,'mid','MbABrkFEZXQ8AM2VL4iPdPK6RPBsQSUaZtkp4wiYoRHr',1,9,5,8,0.052740,'Index Indigo','none'),
(1673,'mid','FBSQjteNvHmfh8Wqkij9H5zLNjVESL3mxWCHnAdZz5Q3',6,2,5,3,0.050540,'Deep Signal','none'),
(1674,'mid','NbcFhLzVY3s9RMDDKhVLmmKyhUGmBSrgxQBzSqEejQXL',3,9,1,7,0.054460,'Liquidity Teal','none'),
(1675,'mid','ak68vYERKbxQDDaKvcjhVP51W1CTGx1nXRzncMp2r79H',6,4,0,0,0.041735,'Custody Steel','none'),
(1676,'mid','QypoJko69xSGBwEbgf3QYZXYnctW6qhdkkH4KYWZQ4Rd',3,2,2,4,0.070490,'Ticker Cyan','none'),
(1677,'mid','DMrvtzKotKUPkpU6CkDETMrJR4UDoaBoHZfnktsPhDwp',7,9,7,6,0.035750,'Terminal Blue','none'),
(1678,'mid','8Ck5ocSEMNMttFXjLr8BBDmqRZaMoRjHnqmGnSnupDoE',7,6,3,8,0.027040,'Index Indigo','none'),
(1679,'mid','U17CjTQG5HXx3PQg5m4bRRoRHR5foLCnEZEviYVPzPH7',0,4,3,8,0.036220,'Settlement Violet','none'),
(1680,'mid','hmz4Rouk5SFktAUdKJRtyYnSNVg2nqWqY55pqHaNymup',6,1,3,0,0.049290,'Index Indigo','none'),
(1681,'mid','VpQp5PFruGzhFsniYaveMc18yEN6a3atgZRK5w4a8p8Y',3,3,3,9,0.058530,'Ticker Cyan','none'),
(1682,'mid','TpjtkSr5BM26JSNKgfJK6reYmghixNRWncZxWh1J9xE6',7,1,2,7,0.040450,'Custody Steel','none'),
(1683,'mid','5SQXv17GRuCKTGVjgAYpTu5oJViMEmfKXAvyPDSMAVW5',3,2,5,0,0.045190,'Liquidity Teal','none'),
(1684,'mid','4wiU3ox1nCg9nfv13beTFFuvJTT67ZBLteouSZt3Ekar',2,1,3,7,0.056360,'Deep Signal','none'),
(1685,'mid','e5vbKkLibSNNvY7QTbmcPqjbNKs5nRhLadP5uFZ7MuRL',3,8,5,0,0.043130,'Index Indigo','none'),
(1686,'mid','FZ92HuhZZRQGrCpGpU7iFc9xziFVhubW9RxV85QMqLRJ',4,2,7,0,0.033560,'Custody Steel','none'),
(1687,'mid','bzj9CUuoyc7Dydkizov7Xbcf5DMkCvPGaF5HXQR7inXV',2,6,1,4,0.047990,'Custody Steel','none'),
(1688,'mid','3XW9ujG3eis1UKEAXcyqw4xEfWo61wf4TEKxNW2YmFGF',6,4,0,5,0.059410,'Terminal Blue','none'),
(1689,'mid','dfJaLNHtkvpXJsoZi2Lv64mttdofjbJJPrL8T2C73GRX',2,9,4,4,0.070480,'Liquidity Teal','none'),
(1690,'mid','BVwCvSSmFEfGoPVwkqpqJGouJmvht2L58pjhm98EetBG',2,2,6,2,0.063375,'Ticker Cyan','none'),
(1691,'mid','6qjTNSEBCeGA82UnuFzM82c7LJQZqi5MdWi7hvLHQNCS',0,2,0,7,0.038450,'Settlement Violet','none'),
(1692,'mid','jtaJ1cNMGkZFqxZ2dsEs6scb2Eat2EhvLhaCc2zmTF6n',0,3,4,5,0.057495,'Liquidity Teal','none'),
(1693,'mid','ayS12psvcDeYRFbet7yoYuUTYrWjV1js87qC7U8r2L8Y',6,1,3,3,0.048205,'Terminal Blue','none'),
(1694,'mid','FykvaGzWvQGoTLuJ18CWTMzgf2W6deXzK6miA6ZA9Lvj',0,0,0,0,0.028900,'Liquidity Teal','none'),
(1695,'mid','JVzfEAuibbEqdzfRVd4AoJTunCWcECVsvK8ukuE3mUJz',2,0,0,9,0.036560,'Deep Signal','none'),
(1696,'mid','PNjTmTdvjmEGo8iZRewXeYQEarNH3be3yCmExv6mTqmo',6,7,5,4,0.036920,'Ticker Cyan','none'),
(1697,'mid','CqT6K15fcBzZ4h4akJkM8RTzYLcVc9xWY79PWzBAxcfZ',2,1,6,7,0.045970,'Index Indigo','none'),
(1698,'mid','vpEZHhozuSDeLgqnamsRDc1WpN2Sn5MwT2k7dKz4FFbp',5,9,5,3,0.046205,'Index Indigo','none'),
(1699,'mid','s4znMUmeuThRFsgE7VKLAwMYb9wMWVgtC7PTUTiwMu6F',2,6,7,6,0.032145,'Deep Signal','none'),
(1700,'mid','zSnjx6fx4A8N6EUe1Non2nZN1Q6xDD1RAExUWFapPxH5',3,9,6,4,0.048795,'Index Indigo','none'),
(1701,'mid','8nSwp1U1q45mkG9NMCe2pqYKSDVdFQqbJQHEuS2oPQq7',4,5,2,7,0.042430,'Ticker Cyan','none'),
(1702,'mid','7ytLjDsdm7aiTm9utwxexuCn7XcnFx8RoCrc8wNHCes3',0,7,3,7,0.049995,'Settlement Violet','none'),
(1703,'mid','25VpKDy3aje5hJgeWRLVCLAbsPerCWcYfyxEwrZD5e16',1,3,4,9,0.032800,'Index Indigo','none'),
(1704,'mid','bHKxi2D3Wh9BeYU2fy2KoPG9hggiqdhMXNQjLuukSQuY',2,7,3,6,0.048700,'Settlement Violet','none'),
(1705,'mid','U69LDTuZrGpeVnPMZMBJaS6jM9MTVXadDQCdNiMs6hM9',6,9,1,0,0.053860,'Index Indigo','none'),
(1706,'mid','rZDux9tUhPwENT6oV9r3vggF86yBVLu22q7JcKxNYTyg',1,8,1,9,0.051535,'Liquidity Teal','none'),
(1707,'mid','zGSgwtdcFC439T4ETMu2cxcbour7pfX9GeKsZK9uLWXf',4,1,7,7,0.039620,'Index Indigo','none'),
(1708,'mid','DNcg5Jf2inCr3HiP1yA5rgiA6nqPCUt9hXjUmtJVSvaH',2,7,6,0,0.037650,'Terminal Blue','none'),
(1709,'mid','dV9xUsLUKEgoWwopaizwfduUVZxa7ey1hYgVek57gnYw',0,4,1,0,0.048495,'Custody Steel','none'),
(1710,'mid','UjmxEL2QamECXAAbEBfubY2uin728ue48nYErAxYaxnK',7,0,2,7,0.050530,'Settlement Violet','none'),
(1711,'mid','65UaBxxzznohNkvev7QWUqLVTN5tVuENJ2amKXTh8VP3',7,3,6,3,0.053545,'Custody Steel','none'),
(1712,'mid','B6J1p7Ltww5fL8MAdCP8udqXC7GEy3sy47Q3c2CTcA5s',4,9,4,2,0.038620,'Index Indigo','none'),
(1713,'mid','XeRUxjiapMZGaF6rLYh55hq7pcxdMzWgSaWsr6tLh99p',5,6,3,6,0.043795,'Custody Steel','none'),
(1714,'mid','pMhnPhSfT56UDLCqFvMPvYyheWomCUd7jxfzv7NH7v9h',5,5,6,0,0.053640,'Settlement Violet','none'),
(1715,'mid','JJiVX3m7kMboBG7yGTKmrTu2CeV2rMZ8Gbr43e9vNty8',2,9,7,5,0.044145,'Ticker Cyan','none'),
(1716,'mid','wzUAqKmmceZMCp55NtTAoP2PbJNYTcjj663D42BoviHH',6,2,0,4,0.054650,'Deep Signal','none'),
(1717,'mid','Sr3WKhMnnBsfyB4jSXgXjMtg3m8S7ijEtdoYYjeBdzAs',3,9,2,8,0.044875,'Liquidity Teal','none'),
(1718,'mid','6Qj2Ap3uZDUbQ9XN1HKcKosLnntLM7befD7Xhz34BWqx',4,5,4,3,0.047845,'Terminal Blue','none'),
(1719,'mid','wudPNFPxUdHYETHmZ4sgaJCNWUeiRbaC11DBLXu7cDo9',0,2,5,0,0.029970,'Settlement Violet','none'),
(1720,'mid','Y7BaV1mF6DAa2LH1y38xFN4J4idzDexZ9RGcKXMMVFyM',4,1,2,0,0.048700,'Ticker Cyan','none'),
(1721,'mid','7gSNP4crLiHEqUu635VjA1dctDGbbQKte1BkGNXLfYMG',4,7,2,6,0.042905,'Deep Signal','none'),
(1722,'mid','B2a7HkxDctw9ra5yinhE2pXGURhETVEBqHA8Bfx9yy6D',0,6,7,0,0.036540,'Ticker Cyan','none'),
(1723,'mid','dGSbLX7N7ddjyVLs7TtA1ANKU25JXH7bNriwaoNEwRUw',6,0,6,8,0.052060,'Custody Steel','none'),
(1724,'mid','fCxUHaXdemmzsv9geJBfHzGHNFKJkMjCwMaB4UVMyPGN',5,6,0,9,0.046350,'Custody Steel','none'),
(1725,'mid','ENhyYoMUF5WvCFXLqAJu8xDkEgE3nrtCBFyMVRnJMCty',0,1,2,4,0.033420,'Ticker Cyan','none'),
(1726,'mid','JGUUTkc6RzQxeQhnauuuEcoqsz2kNBsRaKTXL7M9FijD',1,0,5,0,0.035760,'Ticker Cyan','none'),
(1727,'mid','evSTdjmE49A3wqYJrUsNCU3ZkqXZm1z9QUcLKoEokndf',6,9,0,8,0.037800,'Terminal Blue','none'),
(1728,'mid','afE8LKNNGMJRAjb8fiUKVACTLdWz6SGfiFjYj9FWna1c',5,0,7,0,0.058035,'Index Indigo','none'),
(1729,'mid','7WFmaEdtzq9WHMPh5SoiVeK4fQXQhQr8dFjcZJQzyWwK',2,9,3,5,0.036220,'Liquidity Teal','none'),
(1730,'mid','FRng7X8uWYn8pcdA3NkK6WizFFniYvQKUjSkxavgadCw',5,9,1,9,0.049380,'Liquidity Teal','none'),
(1731,'mid','D2LfGNeZGeJ27n46fWxA8uJrPridyNgT3JxgJu7MN53g',7,2,5,7,0.036160,'Settlement Violet','none'),
(1732,'mid','WJwPuLc9kLP36dUScE2sapiyZaAnhwgGCN7pSYJsaNkV',3,6,1,5,0.043485,'Deep Signal','none'),
(1733,'mid','opdxr4sUqDaeJozpGWMZ8JTkC2DKy4z9e7jW9YkUdXnq',0,5,6,6,0.059080,'Terminal Blue','none'),
(1734,'mid','srXkRqF4Lfi7SFsvMEpEqjf9Js5rAXHfFhCFCa29QLR2',4,3,6,9,0.037570,'Liquidity Teal','none'),
(1735,'mid','w76j2DSfevXD7wvtYM6oqFNSGfLqJMFzJgjPfiNire2Y',3,0,2,6,0.033520,'Deep Signal','none'),
(1736,'mid','6tQE7HETyAjxrHSmQpYZLL2t8hjDDwvEEtvaWX1v3w3y',2,3,3,3,0.043835,'Terminal Blue','none'),
(1737,'mid','HWdTStk4xvyBRw58LgS5TiDRLTbfHwqPKAe3488DDXv4',0,0,1,8,0.049330,'Terminal Blue','none'),
(1738,'mid','Ac9tVyLdka94MYomE9xKC43QLH7v5EMLsmaVLZzf8Vk4',5,8,6,4,0.054340,'Deep Signal','none'),
(1739,'mid','g4D6uEwRToDeXkBppZPznX3B3NpNAzBeoKYinDacVCWC',2,5,2,7,0.031470,'Ticker Cyan','none'),
(1740,'mid','qwqybarZhkVodQmzs6o62DaG9LTwq9kLy4t2FsnyfDhC',3,7,5,4,0.049790,'Terminal Blue','none'),
(1741,'mid','XMtSQfd7S5KqhD6WMjW534jhQ5TYhCkHyGcWdvJqf6Rz',2,0,3,9,0.034160,'Custody Steel','none'),
(1742,'mid','DUhiGDo8FDz53sSCWVxr6ARmzsRvKahb7e3qDhi3py2e',0,0,0,8,0.034660,'Ticker Cyan','none'),
(1743,'mid','VAFZNqduYAXya5Qn1r2QJ1kkiBnNP4ewr6QWkwGfVi7f',1,2,0,0,0.041420,'Index Indigo','none'),
(1744,'mid','YDPPyo2RanCMCfvJzzPnDL8BDD2LYH2N1aFzRnSQ8ikc',4,5,3,3,0.054680,'Deep Signal','none'),
(1745,'mid','KDCVGDXij3r4qu6Jc8qB4oUm1B8JPzp2Q9WHRGb3nUcr',6,3,0,4,0.051525,'Deep Signal','none'),
(1746,'mid','X8RwunPhZkzF6iVcVqxgq86ta353A7fwzWm6Yku1x19M',4,7,2,5,0.045620,'Custody Steel','none'),
(1747,'mid','7n2kHLJve7pwfZ9bsaqiDJGyNj8wngpcv2XVy9Sbv4r2',7,1,3,2,0.038180,'Terminal Blue','none'),
(1748,'mid','PXSY2g6wY5JZmNe3NBJhY9yfkDxrY2idvaAFDudW3FRE',3,2,5,0,0.050785,'Index Indigo','none'),
(1749,'mid','V6DeFkDpWQf2RQB8hqy9QxAd3uUcGkP2uv46iDc6cBtd',5,2,5,7,0.062705,'Liquidity Teal','none'),
(1750,'mid','GKB79dbS5qa35bWPRbe8Xn9EN8KLjTJrATLmZaVAY1m3',3,6,1,4,0.044880,'Custody Steel','none'),
(1751,'mid','uArPsXH2VzL1mCXogHnA1ZakHJC7Hv5cadgfkGa8PSvD',3,0,3,9,0.046590,'Custody Steel','none'),
(1752,'mid','7uB3GYe5dDGUqbhQpmcJcWayXTFmQYWC7qa1a3Xu7B8L',2,6,6,7,0.040015,'Custody Steel','none'),
(1753,'mid','QvchWmK7BcKqU7zVCWUgESP4sPMEQYrLNTwszJxLKBsd',0,8,7,9,0.052020,'Index Indigo','none'),
(1754,'mid','wHyoDsLPmxCW3TJj3Tfio8aj3UJixbgtvmaJZTQ4kkBt',7,5,2,0,0.040625,'Deep Signal','none'),
(1755,'mid','rggSY49YV8ccjDYoksoCgBdoz2NTj5Gm9usAxbE8uDbD',6,6,1,3,0.041630,'Index Indigo','none'),
(1756,'mid','Fvx7xSy4FZpkrJT72ddXTwknvQ8h3kfYb1MRgEb3Vsyq',2,7,2,0,0.035760,'Terminal Blue','none'),
(1757,'mid','7PLF8vWUau1WbUjiuzk13637ei2sjrPJB6P9ksEGbw9B',1,7,4,0,0.036980,'Ticker Cyan','none'),
(1758,'mid','JLc9uPJstJkNv8BA5DwEVfV35Av9PRUdV97k9CWniEdZ',7,8,2,3,0.066415,'Terminal Blue','none'),
(1759,'mid','NxvBoyzmuWVSZ1Hywa9q7Lp4KmBU838uD5JY7CFzui7o',6,2,6,4,0.044340,'Terminal Blue','none'),
(1760,'mid','npbWLewEUCAaL8VG6dKxinhb5Dk7QWCWx6asqxy8oL38',1,6,2,8,0.035330,'Settlement Violet','none'),
(1761,'mid','brRJ6txu3VLAas9T5qX59qkqFv5DQniS7fMufGSayfvb',2,7,1,0,0.037910,'Custody Steel','none'),
(1762,'mid','jnRcDhpDmc58PYmiN2r8LG7BEEhurAeVFGGgdzRBiLxq',1,3,2,6,0.045770,'Liquidity Teal','none'),
(1763,'mid','VUb9e5tjuNFd8foQSBSthMCXzQnQY6bkpnkz4QCT5cQd',3,7,6,6,0.037820,'Custody Steel','none'),
(1764,'mid','PgX2dbupRLafjVHfokNhMFVXGitr1xpnmaQiKVYMxN2U',1,9,5,8,0.030265,'Terminal Blue','none'),
(1765,'mid','BXi6DW9hdxnzyA9tXuX3m3poWaJ49sYNQ6RLC4gaoADx',0,4,2,2,0.054950,'Terminal Blue','none'),
(1766,'mid','xdZ3ckToHNtCgKn5DVyVjaoL7TpivQugjgA2cRWPJwXh',4,0,4,0,0.049220,'Terminal Blue','none'),
(1767,'mid','PT8WfszLjDTXoxm2VLP6Q8UScK6gHL6eitF2GJp1UPGK',4,7,4,6,0.041600,'Terminal Blue','none'),
(1768,'mid','8Hb2exXMuuUQSycdUwiTU7fDzn4oeEje1TraVGJ5JvqE',7,6,7,8,0.036680,'Settlement Violet','none'),
(1769,'mid','RoYwePoqiMdHw2xKJiRmc5ozxHYHBhUdDkrH1ATb7t9S',3,4,2,2,0.056980,'Deep Signal','none'),
(1770,'mid','PYDAPN5oCBPon7oXW6BGqPUkLvXh1mybkt6giBBHxBxP',2,8,5,2,0.033840,'Ticker Cyan','none'),
(1771,'mid','zP4dDK5d38SVMLpnW8Ky3ByxS1DkS15Ttvk2Kxb52Aw5',0,6,2,8,0.038675,'Custody Steel','none'),
(1772,'mid','rp4dBgQGg4jyL5qJoUy2ECwkyeLcZdAiAR5EwBSorE6x',2,5,3,8,0.024960,'Liquidity Teal','none'),
(1773,'mid','7JZj2ZFiLJBMcquVBzxoZjjMUcV9PEdDZkuPVXBs4hmo',1,1,2,5,0.047170,'Custody Steel','none'),
(1774,'mid','1KgH9wrTMcjHNgNmJkGbBNscd7qubrF9QMcq2bbRxYdu',5,7,3,9,0.045175,'Index Indigo','none'),
(1775,'mid','wuWCZNbQrJbvvhV4BbNvWEq8ivm87mvhBMggnTy1C2eP',6,7,3,4,0.044695,'Index Indigo','none'),
(1776,'mid','Dj6CXuBRGkraJULYDhbzmJMxuuTCJuJQHmZAR5iqUTwb',1,4,2,7,0.035060,'Ticker Cyan','none'),
(1777,'mid','me6qVKSeCJcYm6tUnZfSEyPy6UQzToukN6i8hVRQ57oJ',0,8,5,6,0.062440,'Custody Steel','none'),
(1778,'mid','7LSpre7dnYSYYKT2Kvso8it5X8NXyJvN5R2yhAtraCRS',7,9,6,6,0.044405,'Terminal Blue','none'),
(1779,'mid','5uk2WroBBoA1uFjTisWg3xN5A4urmX6Za34YjAorLALm',5,9,0,6,0.045480,'Index Indigo','none'),
(1780,'mid','J1wNDjbsi41y2qXJuNGHQ1HvpMu1WtcdxjpLmuC5AncS',2,2,3,8,0.052400,'Index Indigo','none'),
(1781,'mid','RJ97Tn4fDYKZjW4z3CuG3BbqFLmrbWVfPBokuAEuJmpP',0,9,1,0,0.057105,'Index Indigo','none'),
(1782,'mid','EtQjTuQTBdXanoAAAq4bvoqgetiBUgFDV7RS9xFZQUqk',1,3,7,7,0.081000,'Settlement Violet','none'),
(1783,'mid','BLvDmwyo2z4R8djBseXsUGUJDcDdVASUQq8HrAhEDRep',2,5,4,3,0.077645,'Terminal Blue','none'),
(1784,'mid','Dxk8p6rH3RmF17Kc2h1PtQ1cvaktLhtgR5RpTnnJcgJk',4,0,5,0,0.092540,'Liquidity Teal','none'),
(1785,'mid','DwkuQaWHSqmeDCpAwJTaYQvV3noGB4afH2jPwmyFooA7',7,3,0,4,0.048340,'Deep Signal','none'),
(1786,'mid','LxfU9UA4qM6pHoBfExPnNps2Dfe56yHcMePjiCriZyfY',7,2,5,4,0.046840,'Custody Steel','none'),
(1787,'mid','1oZ7sgbScw4iWKrRBgLDGbVQ54GdB2dAf4VHPAYqEH8j',6,0,0,2,0.041415,'Terminal Blue','none'),
(1788,'mid','eNoUaVh9EZb9nksHQVuRCNJzsV6jm7NKEDfQunCpFQW7',1,7,2,7,0.053865,'Settlement Violet','none'),
(1789,'mid','ZG7tgk689sEHVJF2eWJfWYGS2EmYRjeYcxmBTBhK4QYx',2,0,1,0,0.051260,'Liquidity Teal','none'),
(1790,'mid','caW8QhUL8WSPtfBzS53vf8LVq5XR1o8mpQ5eNckewwYZ',2,0,0,2,0.031740,'Index Indigo','none'),
(1791,'mid','5Zmk9epBMrR5xBJeNWbAB2yPkfAuZ9w5yfN327V8AcZj',3,1,4,3,0.040400,'Custody Steel','none'),
(1792,'mid','UUD81xd5ygzJBjyKFGbRyqBmKe2WdohGFwT8bUKS4ANT',3,3,2,6,0.034970,'Liquidity Teal','none'),
(1793,'mid','VyUyqHdH94BWjVYK6i3tdG27S6E7yyVBd8mweo19nn87',1,3,7,0,0.053280,'Ticker Cyan','none'),
(1794,'mid','B7ZBwg1ybS6NREazBVrSVTj4xRitKUZnaoEhVFUms6Xs',0,4,0,4,0.043720,'Custody Steel','none'),
(1795,'mid','5cqe9WZtG2aNHy7b7ZBz8AfCujNKjySUYzzPCJjpz34Q',6,5,0,9,0.057010,'Settlement Violet','none'),
(1796,'mid','8d8aQvBc41tkZTeFs8He7ceyeXgboZppB78SwHLWjgRh',2,0,6,6,0.052100,'Ticker Cyan','none'),
(1797,'mid','EDtwra6ieEtfs5L2Gi4awCMeBMyyULxtu4BnGoFsNRUN',6,7,3,5,0.052730,'Terminal Blue','none'),
(1798,'mid','sDsvgGnAnjo7PJ6oHYg1su97DsYRbLkBJRZCpyuHGxra',7,9,6,5,0.025780,'Terminal Blue','none'),
(1799,'mid','8NW9tUdADM9mPd9bikrPQt3ygi1axFWPUKsbYrf6WM3Q',5,8,7,2,0.040480,'Custody Steel','none'),
(1800,'mid','4kU1MnXvucuoJy1UoH5GcamhoDuoR1Kk6avK7jADEzn1',7,9,7,5,0.054380,'Custody Steel','none'),
(1801,'mid','cP3PFngjkyWMgSuAxn3v3e4PpRdAoukqob6WTxURf49g',6,8,6,3,0.047850,'Terminal Blue','none'),
(1802,'mid','SzruLPMNnp4eyU5WYz9DhWZ9CyMnr2dKZdfszxJ4voWG',3,8,4,9,0.063540,'Index Indigo','none'),
(1803,'mid','m4opbc9Y7bXxrcyKtWtv94a7x36hqdWkNUd1wbfhz6YK',6,1,2,4,0.033365,'Custody Steel','none'),
(1804,'mid','SdtYBVPfEW52cSm6iuubPaMpa3QfiUVU9mxLiT3JUifp',2,1,4,6,0.039740,'Liquidity Teal','none'),
(1805,'mid','Bb11fBM1dUyfX2m4JqqUHYGTDyByXFzyHvoNChhPxQq7',6,5,1,2,0.037140,'Deep Signal','none'),
(1806,'mid','po5D1WYxc6LAXjKFRAyRcLndeDpYgaJ8w6uiqbX2oFZK',2,8,3,0,0.046660,'Ticker Cyan','none'),
(1807,'mid','pG3w4Nb7a1fpqYc7SuKaQL2vFUWfjUb9nMuQEt82ED7E',5,7,5,0,0.072990,'Index Indigo','none'),
(1808,'mid','zWtRLDZS1iC5d3p1T2v6CSURfLMQtnWTBda3KorEqpkw',2,8,7,8,0.038210,'Deep Signal','none'),
(1809,'mid','EWk9sorzQ6NYcJ9LqGk34VDt74mci2fRRM6t2tLjDmQw',0,7,1,7,0.033660,'Liquidity Teal','none'),
(1810,'mid','Wv57M5qeL5Lzr6ycpdxFLwjZ6q1Fuy1JKWED9ngoE9MZ',6,9,1,9,0.046860,'Custody Steel','none'),
(1811,'mid','Dung7DivoMxhQW8iuxKvWzkgUpDwPJapgKXHh7rr5jiH',2,5,1,3,0.048845,'Terminal Blue','none'),
(1812,'mid','qMenxE4k5cStwE7N7kQThhHV8KugqFVZ62qoYrzomxgA',5,4,5,2,0.063030,'Custody Steel','none'),
(1813,'mid','KVZJFB9DXaZudEMgSGjXYcwJTVL2YpDq6yuBnJv92a1u',0,8,5,3,0.036370,'Liquidity Teal','none'),
(1814,'mid','S5eW54u3Uxyn2MShWeangfoTveY3mYEzRo5AvaNwyGng',5,4,5,8,0.064685,'Liquidity Teal','none'),
(1815,'mid','NbNFMm28DqunUf4i4FBv64xCjhGTtHCoBs5QxNeK1TMX',0,9,5,8,0.057405,'Settlement Violet','none'),
(1816,'mid','T9LKwyAZybmMQviS1YoHXJxJd6yUwwZwFVqKZkstiAgu',5,9,3,3,0.045085,'Ticker Cyan','none'),
(1817,'mid','WsEnZdauNmKmCryC28syZuLJCstz8vAV5jB4hRs9gr4x',1,7,7,3,0.045810,'Deep Signal','none'),
(1818,'mid','mbfJ1q77KwJfVKej7VgYR5yxaYWqb5S426mqtA7fdnRt',3,5,1,9,0.051075,'Liquidity Teal','none'),
(1819,'mid','ocfGEMeUhxyhETr1mMeG8Pdzym6BHUAaL4FUT7GrCaoQ',3,8,7,8,0.052150,'Ticker Cyan','none'),
(1820,'mid','YHeju8GbuhhVfF5P2o33p4kCswfyANZHLF6ndvUrgKy8',3,7,6,6,0.040590,'Settlement Violet','none'),
(1821,'mid','6sXjKFwvFovdCo9HEZ2g3va7vESzRfPMSfJtxmMVwG3o',6,8,5,5,0.058055,'Custody Steel','none'),
(1822,'mid','x3wruNmbsJvD5B7M1ANQtLFgDTvwErDeFCaaV2aLioAN',0,2,3,4,0.042100,'Deep Signal','none'),
(1823,'mid','H1S4HqvBYbRdxmbLzRudGZ65PBPcftgY73Z7SqQxcDd1',0,9,7,6,0.031040,'Custody Steel','none'),
(1824,'mid','gbMvx8fPw4LP5dMJ9hoWB9AwwQk9jF4PSuqvuVBcAqv2',2,8,7,7,0.044700,'Terminal Blue','none'),
(1825,'mid','oLwie3GY1gV1i5jhyog6AHaqdCjse1RruUpQkpX3yDPW',5,3,0,0,0.034640,'Ticker Cyan','none'),
(1826,'mid','6AHzFhLoBsmL1ByCQX2obLSL7iDWufDSBQu8Z3B9QRfu',2,4,6,5,0.057400,'Custody Steel','none'),
(1827,'mid','nSaz6XQmG9KKdwazTAVzAjnKqMe1c2HQRCGUFsgLBeAe',3,5,3,0,0.035180,'Settlement Violet','none'),
(1828,'mid','mS4pSiYo5MSTrXgNVRHX871x9WMmEEDtF5NZuVkFw8qa',3,5,5,0,0.044860,'Custody Steel','none'),
(1829,'mid','hY8myECJ19hcDGmrv9PC5vJt8pFxc5dSJ5Akfu1ygavX',5,3,5,8,0.043485,'Terminal Blue','none'),
(1830,'mid','FZfgkRZt29BD5BVh8WqoTBxejyiNndjXAnprsTucqCTP',1,0,0,7,0.042480,'Settlement Violet','none'),
(1831,'mid','zvJUD9QgBCLAXxLpybZEHV8HA9pdsubaYCk1wrpLFjCy',5,9,7,8,0.044330,'Custody Steel','none'),
(1832,'mid','Mas9yHAbzGLpw3Y2AN3FE3h5KwHMJgG5278taTnkQhLY',7,7,4,0,0.056380,'Index Indigo','none'),
(1833,'mid','tnJ1V6MMWJtgmSKpjGbmzfDwcZPd1ZP7yNhtbocr95kh',0,9,7,7,0.034470,'Liquidity Teal','none'),
(1834,'mid','kSs9pfcaEtRDcUnebLXC2Ux2PCxYJuP9PgESrQho9cXu',6,7,6,0,0.056605,'Settlement Violet','none'),
(1835,'mid','FCcfm4tAhMpMqjvE266ShywyaDN8DgdguDajcjVteynT',5,8,4,7,0.041990,'Liquidity Teal','none'),
(1836,'mid','UjjJS1zqPbrNUsMgNxVYbcVev6hEjLmiADbdUsYEu5ip',1,8,6,0,0.056005,'Settlement Violet','none'),
(1837,'mid','jtqRpYxzKYcfTsxYAc75hsMe58muyFcoFgCupCfZA5HN',0,7,4,6,0.033410,'Index Indigo','none'),
(1838,'mid','uXyoTSnJWZ4GwJvqoKu4gDEvYovy2jRxNWDa2kfJtCP8',1,3,6,0,0.037250,'Deep Signal','none'),
(1839,'mid','tGKwfiTFXqy8CM7odNwAy5bBVtLADuFjBuyZkALZsnxz',1,2,4,2,0.042305,'Custody Steel','none'),
(1840,'mid','29vtCsri4qt1tq15iSPpg5seYQBQ6Db42peRzVrHbsoN',7,5,4,3,0.059325,'Liquidity Teal','none'),
(1841,'mid','KaTubQhdxMLqUHR8uZXZFBD2ztShsh5UvmKevf7vHsdZ',7,3,3,9,0.042270,'Settlement Violet','none'),
(1842,'mid','NhoXmFM4Ahv4NxDwotgmvH4hDMc3VcHDcCcEaYyqCPtp',5,6,3,6,0.054595,'Ticker Cyan','none'),
(1843,'mid','kpoAnw6JCZPBme6u1pwaCidoZV8kXwKwocjWLZjAZFvD',3,5,5,0,0.047460,'Index Indigo','none'),
(1844,'mid','oGRqDMa9WAJJ4U8g3ucBiwLRr16rw7bdcywLRpnecfUB',7,8,4,5,0.028870,'Index Indigo','none'),
(1845,'mid','1T3Z1URTgQGoyPaLhgNwYCL6cRc78JULXTPK3BrAqHUn',0,8,6,5,0.068400,'Custody Steel','none'),
(1846,'mid','5zcDXQueeijPbz5bwoRAp6BrjQcka8jtX8jqRfy9mD2t',7,8,2,8,0.039060,'Terminal Blue','none'),
(1847,'mid','EpFE6XvfkCehw7DfDwzWFiuiW7khzX7sjgMgRfr2z6ee',7,8,1,0,0.038180,'Deep Signal','none'),
(1848,'mid','hufJqHgV8HCftWfbrEPrDxhmYCWRPZoeFr3qozhBsGji',5,6,1,4,0.038700,'Deep Signal','none'),
(1849,'mid','VYJj5R7P2HgNSm7E9HjoUfgJPuTkHM9JvtbU3fHRpncP',3,2,4,0,0.047500,'Index Indigo','none'),
(1850,'mid','qPYKRLJwZGLpPxWgPFxFKnXQNH6RYqpDtB7vduDHado7',0,0,3,3,0.048360,'Index Indigo','none'),
(1851,'mid','EnevQhTGwnhv7rYbQbKLcCwKURve54sMQNEuPZ4UdCvE',0,5,0,4,0.045930,'Custody Steel','none'),
(1852,'mid','m6KNQSB7EddH1EsFTijheGPnr73nT2WvmcBVLfeq4GYB',4,8,5,5,0.055580,'Custody Steel','none'),
(1853,'mid','Niwmxwo3MuwSFxmvx16nYod3BsWWxpjjUtaUBJEzhx6c',0,7,3,6,0.037515,'Ticker Cyan','none'),
(1854,'mid','cPMLvVwBLjvPrwffr4VbLytZHWLYEoUNQcDiQvz3ihvc',5,9,0,0,0.051200,'Deep Signal','none'),
(1855,'mid','R3RtL8EQ4R38Db5hiyW3yTAWemrSxmyruSx3zpxw6Cf9',3,1,4,8,0.050305,'Custody Steel','none'),
(1856,'mid','TPQYPooJekAEEf8ReApeFiDKTNQhmSWDi4GDo47HaVut',3,5,3,7,0.027280,'Liquidity Teal','none'),
(1857,'mid','sbYAtedhUCGRUdYqmYTotQMhWtyaYo1HiufKTBHDWf6y',6,9,4,5,0.030700,'Ticker Cyan','none'),
(1858,'mid','eGGgAgVmTXZ3mYFNvKRJEkw9gBrSmyi2YZAie88PtA7Y',7,0,6,9,0.032960,'Custody Steel','none'),
(1859,'mid','fqGH3VPn583DCLmNP6BtfeP7y4kWboos4gWmXvPacym6',5,5,0,7,0.073090,'Terminal Blue','none'),
(1860,'mid','Jss4uEHBxQa5R6sEciPBKoHHCgyHJss6dsvttnu1Qerg',5,4,5,3,0.045720,'Settlement Violet','none'),
(1861,'mid','E1CzQNpk1FC1fXzqS1jA1zeKr6B2P2hTwzUckKThUBwF',1,6,1,7,0.077820,'Liquidity Teal','none'),
(1862,'mid','MQDCuihBEuHs1LDdUJYVZjwHvzMnhrbqaKMAvgmzB6Yy',0,5,0,4,0.034000,'Liquidity Teal','none'),
(1863,'mid','zMgJTz4ACU4DMnChqMMXgxtbN1WyR5riG5Fu2KiUnEit',7,9,5,9,0.039100,'Index Indigo','none'),
(1864,'mid','2tqBkb3XQUVpWuHwUzKkL4G4WcijALJ7ChNGeGwYje3c',2,6,5,0,0.044980,'Ticker Cyan','none'),
(1865,'mid','vs9h3pTstfpCqwjRiRNevHPSZyQi7ryL6yn1AVtuh2WQ',6,9,1,5,0.032350,'Deep Signal','none'),
(1866,'mid','7K43prUEoQGuAGe1GLeF8yWgpqd9nqsTV2Xx2birwSif',6,8,7,9,0.036460,'Deep Signal','none'),
(1867,'mid','8rCW77obkXruJnmgJ2mxgDzVLN8xNrE6ZC4mXhWQzupj',4,2,1,4,0.040625,'Settlement Violet','none'),
(1868,'mid','D9y4WxPNn6HvScKWz1o59KG6oR3VZDb9QN3jvGT7zdiB',4,8,5,6,0.036740,'Terminal Blue','none'),
(1869,'mid','h1bAuguvRpBeKYiRNbThnsCH9NEcCV7wTT3xxsgVgoeh',5,8,5,8,0.059250,'Index Indigo','none'),
(1870,'mid','apoJ3gx9N9H2xYQrq1WAWCQ8iZ9Td5SUaE9bxpZmWraP',4,7,0,9,0.033210,'Settlement Violet','none'),
(1871,'mid','bmDSCJa3ToytC48qYJY45mvoaMq3CHCsgz7PM4oUij74',6,4,3,0,0.070835,'Liquidity Teal','none'),
(1872,'mid','aH9wKoyoVyNN5oM8DcSr9vBUN7bm6JVmwoLSsRHcieVv',5,7,6,5,0.043550,'Ticker Cyan','none'),
(1873,'mid','zkaNDTC9bZ1qz4ineVxQixnBQ7xDQwYb7ss5BeRwHhH7',4,6,4,9,0.036100,'Liquidity Teal','none'),
(1874,'mid','xKZs2FrDgrUhDgZm2qvGuUphHKJF9khtd66XSJKARqUL',6,0,1,7,0.056970,'Terminal Blue','none'),
(1875,'mid','q57zNrF6TgjNqFGUR7im3oFuY7sADWajb7GjQkfmG4vB',5,6,1,5,0.039415,'Terminal Blue','none'),
(1876,'mid','A55iL42vv4c57bqoD9gWWHizWqQQAey87YW6tpoQRUk9',7,7,1,2,0.046965,'Custody Steel','none'),
(1877,'mid','p31ZSQz6umiLYe4JqeCpb42Fi6HThvNcp5dJYxTNdfaz',5,1,0,0,0.057410,'Custody Steel','none'),
(1878,'mid','KKvuacpzXXB13CBARxLCouEKC1GCMJcDfKin2LnP1V4h',1,7,6,0,0.037040,'Ticker Cyan','none'),
(1879,'mid','1tvCEQnFSyjoxq6XThByA8UciHaYd7bKX69xuFEvH2Q9',0,4,6,2,0.035930,'Index Indigo','none'),
(1880,'mid','2ffeGxP1RgGzjS1BMbeYmuBYMHJahf3P5eMg4cqWK4Kn',3,6,6,9,0.041455,'Index Indigo','none'),
(1881,'mid','ZQXN5sp2JRtfoyJiVBSg3MSy2h8a2HQKTsi5wkQnnKdL',6,0,1,7,0.047815,'Deep Signal','none'),
(1882,'mid','UzPooAPt2rNLtfhEoCSQrVZjy2MYQroSSjf3pJzjQTU7',2,8,1,6,0.052150,'Deep Signal','none'),
(1883,'mid','3iauMAAKDzcQNpLuSGug1ffbtB3rd3Rpw9Bx48CySSuG',7,9,2,0,0.039100,'Liquidity Teal','none'),
(1884,'mid','YjdgcfXrtsQzzTHsifYpB6p94nA9aubA3AWQpXzaPT9G',3,8,6,7,0.039480,'Liquidity Teal','none'),
(1885,'mid','wmeeFbKsKt2fcpTaVxrFV4U9wiCqgjvqE6JEB9nScLue',0,2,3,3,0.052740,'Ticker Cyan','none'),
(1886,'mid','BsSrRBMTrfvndfCP4NPU2LQ4W3ty5J4SYnWJnndhmnnz',2,7,7,7,0.039000,'Settlement Violet','none'),
(1887,'mid','Wrdr434DmJYKibbETBnTuBQ5sSzYFsrPXzHUzGE24YXc',7,6,4,0,0.037920,'Settlement Violet','none'),
(1888,'mid','JDyT6Y25J3r7qMRQa4mGyXUCyauMMTyJSXnm9tr5dxpd',4,1,3,0,0.061180,'Deep Signal','none'),
(1889,'mid','ELwPaXLBABsgD2jM44xwJdS6QLGubcERErz1tCKamNNb',2,1,1,3,0.032080,'Liquidity Teal','none'),
(1890,'mid','ho6qVwDFw2MJVvcNA9BUDD6xUTgNpHRPgeve7yk62Txa',0,8,4,2,0.052230,'Ticker Cyan','none'),
(1891,'mid','xojK8HDdPHTYWRxxaz27o9BBd8KiyrR54YjvjyFRnMzr',3,1,7,7,0.035660,'Settlement Violet','none'),
(1892,'mid','g1TYaCcoY766T27pCgy4dqCoc1RLC9T5XaYKHBpazwPY',6,4,4,7,0.046930,'Ticker Cyan','none'),
(1893,'mid','ZGdsrsW24PRyPKNfMiG6biMxCYFrxf8URe1NjywEmLEC',6,9,0,5,0.044550,'Custody Steel','none'),
(1894,'mid','WcVNEoJdgoMxZAaRGZoyRLuzYBpQ1qj8xQcVseHzomry',4,6,2,0,0.064565,'Index Indigo','none'),
(1895,'mid','cKePdph7PYmapf3xbNDFwaBTxtuVoirjiKmPJMosNchB',5,2,2,7,0.056260,'Ticker Cyan','none'),
(1896,'mid','Pt3srF6BQ96D7KY8uBxUvZkRM4r4RxamNCV6tX3rNQaQ',1,7,4,7,0.052040,'Settlement Violet','none'),
(1897,'mid','hZX4hT6QxNhHWtccJdGG3m5mpnqTFTXgKhFGCPkBPph5',6,2,6,0,0.066105,'Deep Signal','none'),
(1898,'mid','JU1Xn8bxj5sDXtbwpBkpRKeq3wg8rvNTfKDJuBw2Cbe4',2,5,7,9,0.042620,'Terminal Blue','none'),
(1899,'mid','Mv6jkN5YGUvorpvS4gSdQusrbQVRPdpjTv6XNqEM7JQx',4,7,5,9,0.047380,'Liquidity Teal','none'),
(1900,'mid','vMhWNPApe1aGAadNZEzTaVi7MER1QLCxpiVgpFZTX7DE',4,8,0,5,0.059570,'Liquidity Teal','none'),
(1901,'mid','BBQiqzVrg19wGS1vi2u44m1ByNGEw8rDTvqjSKHQXqWH',3,2,7,0,0.038795,'Index Indigo','none'),
(1902,'mid','bSQ6c8FniKHjrcZci8QgYDeCZwmxWnJYkTxGCwwjthXt',0,6,0,9,0.026940,'Deep Signal','none'),
(1903,'mid','dejfFiarLQFrHZu8FiMab9CLnRpeiWvXcDGuwpE68mgB',4,1,3,0,0.038240,'Terminal Blue','none'),
(1904,'mid','WtjsrRfwB2UKAFLJrfpCQbkkiYvCuGGuSs9Hjp2u4yiT',7,1,6,0,0.030860,'Ticker Cyan','none'),
(1905,'mid','ELgEtNJZMNFU43Ge6xPXN8uB31fX9KiiwiQnh5WNBqST',6,2,2,9,0.053805,'Index Indigo','none'),
(1906,'mid','P6EyVpV1K2nKYPrQP7dgte1hg1cBmXbUzG5FeUfAkaK8',1,1,0,7,0.050580,'Terminal Blue','none'),
(1907,'mid','nXy696Hq1cLQcbP7PBqJww4gkmgWFMSPQdpdfbWzQZPb',3,1,7,5,0.050325,'Ticker Cyan','none'),
(1908,'mid','4CHyW5F1AbJkuZmA2xZ1fyEtudRViq2CzVeV3UMPqZ4G',5,1,4,3,0.058385,'Custody Steel','none'),
(1909,'mid','9BNa1kQTReh1Sj5sQhhiKCeW46oZRrXst5i5SKE3NRN9',0,7,3,2,0.042765,'Ticker Cyan','none'),
(1910,'mid','PLCHHVnr3PvvPc4ttXqZPHzzx7NBhund9EziSkeJKWps',7,3,6,3,0.046075,'Settlement Violet','none'),
(1911,'mid','YRwLjkex4xym5zWGyV4FhvThCEVqkJcLUfSB7baxy3xV',1,4,3,4,0.034520,'Terminal Blue','none'),
(1912,'mid','Fb5y4Pq9noW5zAQMNSyC22Lo1xz9ZdVjzsTF97E1ZChz',6,5,6,0,0.045810,'Settlement Violet','none'),
(1913,'mid','vmZ2oenBLU8ZLkyg9sZmvF99vG4eVdmc9Yj2ZDNP75j9',6,4,1,9,0.041560,'Index Indigo','none'),
(1914,'mid','sMBVQSAjsv3ys3kJBESNdo2iNYe8h7pegdb8shQSFcRF',6,9,2,5,0.057340,'Terminal Blue','none'),
(1915,'mid','3x6Lf7FBhKVa7C2Jizf8kRrQ6cbictiPMeY1i9wzuXgd',3,0,6,2,0.062820,'Liquidity Teal','none'),
(1916,'mid','my24jNEKwPoWEit8wRLfZzjvpDWkfkef51Vfy8dimXnX',6,1,7,2,0.030930,'Terminal Blue','none'),
(1917,'mid','uxpQQCtk3MtaSke4viRnWLqAD9aXZG7FLpToCAwzsydK',5,7,2,6,0.041940,'Liquidity Teal','none'),
(1918,'mid','eyWEE6vra9RnVQCfL7uWsC5L3PxYyfxAHwdma6rkTrr1',4,6,2,7,0.050555,'Custody Steel','none'),
(1919,'mid','8NQCiUoUrQyeUkBZHvqnetcMQruQcS1y4ggSLAW6wbgu',2,8,4,7,0.051725,'Terminal Blue','none'),
(1920,'mid','dLuEXEM1VQnGyzKCVxswWQEnEXkwcmybAPwrG6MjGSyt',5,4,7,0,0.033240,'Terminal Blue','none'),
(1921,'mid','PqQwZQKVbVHFcaC7CsedXgALFzxV6TdBKe2tm5hgsgTS',3,9,0,8,0.038505,'Custody Steel','none'),
(1922,'mid','P7iCn82fRrQ9yKet9eVYzmpf8Nd2v1YYorSbKaKB6U8w',7,7,1,4,0.049440,'Ticker Cyan','none'),
(1923,'mid','2CG1HdvQFv7CJxiMqVdsq7VfNRFTkuRUAMBuJmMUHjtF',7,1,2,2,0.055425,'Liquidity Teal','none'),
(1924,'mid','hfgiSzkn1UadHXugv8QgjGfEgcA5upWMqbAEd1SQ7nXT',4,7,3,2,0.033030,'Terminal Blue','none'),
(1925,'mid','GUf1PcmUByBc7FW49hzTjLDSGsh1HxBpABCxYuGmqziQ',7,4,5,0,0.045845,'Liquidity Teal','none'),
(1926,'mid','ZTXUVadB5quY93CDjhsRoeKYtrdgQqghCHSBV4PU2h64',0,4,7,5,0.058770,'Terminal Blue','none'),
(1927,'mid','1nm2tZ44JNrAvjtckZKRRCwy3ENMaF6cMkj16UJKyoP2',1,0,1,0,0.051110,'Settlement Violet','none'),
(1928,'mid','zn7E2s9JWKDDBmf7XJYxekZmAW6pwKpF46p7YQjh5eUc',7,7,5,5,0.047920,'Terminal Blue','none'),
(1929,'mid','kugpNjwjYZeHVPyJbXHEYY4xWLbCeohrk8XYF1X7oFx6',7,2,6,5,0.042495,'Deep Signal','none'),
(1930,'mid','2iXoFrJYdgFHKiQnjBfwGUsZLb2tcpBKPvwf4rRefdqu',6,6,6,9,0.053455,'Terminal Blue','none'),
(1931,'mid','P9qwybF6FmMzuB4HZFGwGxgV6y8ymnMZby4nsg4yqvC2',5,9,4,4,0.091560,'Index Indigo','none'),
(1932,'mid','8VAkEzM2tUGNpADPjXfiFGe2NMk5GPm9vDi6sB1JGzUU',7,2,1,0,0.059390,'Terminal Blue','none'),
(1933,'mid','teSNwainvcs1Cg319mY7XUTbkucwpsj1KpUW3sQXKobP',4,4,3,0,0.039545,'Ticker Cyan','none'),
(1934,'mid','t487wrS9Zpb2SofvCckKZJ6vzrmN8tFXDhvavXNUP5PT',3,6,1,0,0.049200,'Liquidity Teal','none'),
(1935,'mid','z4yr51MKxgya6R4fWsxd2HLUrJ1DQFC24V7PPotzTH6E',5,3,1,7,0.044400,'Terminal Blue','none'),
(1936,'mid','uhx7mHry5ArrwzhyMRBbjrwBTjJo7wz3qM8jjzNPJKke',0,4,3,6,0.044630,'Ticker Cyan','none'),
(1937,'mid','aVGJ3PWX9v5bgaeGZ6rTgKgS63NewXSWtwhXvG7yBEyY',4,6,3,9,0.035680,'Settlement Violet','none'),
(1938,'mid','Mq5KrVQVbM4WKKsg5unt88ftqZBnsE3Ukhz75Us75upN',2,5,3,0,0.062725,'Settlement Violet','none'),
(1939,'mid','3xDUezQ7yeBnb2vMAVwPrDfBBcs6BHixN1EXoUrBWVWn',4,5,5,0,0.083030,'Deep Signal','none'),
(1940,'mid','5DmQa1Y74JxTevqCa6mAV1W9JJGGCCH5jDH13VPMvY94',2,2,7,0,0.031360,'Ticker Cyan','none'),
(1941,'mid','B4hDvQ1azPmRn18TRV9mVrihsorXmtqFZ4UyWXvPwatZ',0,6,4,3,0.058650,'Deep Signal','none'),
(1942,'mid','GwaNFWkMKHvdFWnAmd4tDhtzbSEVrMEqNdfeJeuax3Q6',4,1,3,0,0.040460,'Ticker Cyan','none'),
(1943,'mid','MDEWKB6xYfs4SFcd1HhZtqwfTWKTmRi1FF4T4jP5LSrb',7,5,6,5,0.034715,'Settlement Violet','none'),
(1944,'mid','uAG7Tr8zGofj4u5JhJWeMn2ZbSwLCHD8u6KaTpk2mXgh',2,8,7,5,0.033220,'Ticker Cyan','none'),
(1945,'mid','zfRE2GSfGaLmAsJS5qP54BThaFz41bwuPGvdHvB9wueh',3,7,6,5,0.068590,'Settlement Violet','none'),
(1946,'mid','mGiaztYXv9BvqfRwfBbzydrth4FTWDU1VHpsfb6PE3YD',0,5,1,0,0.044010,'Ticker Cyan','none'),
(1947,'mid','qYA4EiGJQd7ip6feASMWUxGZbpvqFcRkyWKwniuxA1BN',2,9,4,3,0.036700,'Liquidity Teal','none'),
(1948,'mid','qaVUCS8uYTNdLQGUSss3AuD68jqEfAq3TYUboYEZSpWj',0,6,5,0,0.055550,'Settlement Violet','none'),
(1949,'mid','hSczTrxHWKrexLbcGm9WBeCu5ZggKGdRsqeTsKneix62',3,9,1,0,0.054080,'Settlement Violet','none'),
(1950,'mid','YTd3vJ54yDFPwujqKnfeuo6Db1tTP9WCGR9Y4cKKACsq',5,7,7,6,0.032020,'Liquidity Teal','none'),
(1951,'mid','RsEyKUxcW8CYBY2NHwo837xazodGE8Q3RaSwQdii9toH',0,0,3,8,0.038140,'Custody Steel','none'),
(1952,'mid','Gnkv6E7RjTZejn8uWGjUM4XAvbfEpG7HjwmxCgMPzpkb',6,2,4,0,0.048080,'Index Indigo','none'),
(1953,'mid','HYmfp8E2q7knM7fDg9gWFB4CJiiTMrMAT8pT8rqefFwf',1,7,1,2,0.076290,'Settlement Violet','none'),
(1954,'mid','BqwxrizU2RM8nAeACRoLMKU6HQ7vX7sgjDygRKTZTbF2',3,0,0,6,0.038445,'Settlement Violet','none'),
(1955,'mid','BnwCcH7reTMBPbmnSSXjN72GgiskKP1cgcZKLSyS2HJ1',4,4,5,0,0.030120,'Terminal Blue','none'),
(1956,'mid','Nrvnyhw8QxR6zoyGnT9MLn1xmBD9GDTjESrhSXJypC8a',2,4,4,9,0.057195,'Settlement Violet','none'),
(1957,'mid','X7KRkZeZcYo5kmZi1z6Z62iHPFxXrusYcjADxivsThsA',2,9,4,4,0.047430,'Ticker Cyan','none'),
(1958,'mid','ZTdA1nwLrUF4EfASRuyH6t8Vx5NNxCqYyDz8KfYh53RR',5,1,7,9,0.034730,'Deep Signal','none'),
(1959,'mid','B55TrDNGj39xMDQfhMcq1UrEz1CUa6krBjSB3gr5T5BA',6,7,6,0,0.063915,'Deep Signal','none'),
(1960,'mid','7Yz5opPUHHsJYM4zVpQCxA5p2dfp3pvNCGNKPs2APQf6',6,5,4,0,0.048275,'Terminal Blue','none'),
(1961,'mid','hUAS9fDTRW7gg2fsGrDEaWMDPwfMGUwWB9bu7yohxGrc',0,9,0,3,0.040110,'Index Indigo','none'),
(1962,'mid','RB91puTVqzC86PWRALwAkEo8FLR9H3JXUyeEfM8ndnwY',0,2,7,2,0.052545,'Terminal Blue','none'),
(1963,'mid','hjRoVWaCtWoGA4EExNGHi8F4YrYNY9SWM4kdJASwCcGw',1,6,1,9,0.068010,'Custody Steel','none'),
(1964,'mid','kjECj3xR1dXJksgKPMSmLJ3K7WGigsXtyp1XvawZEEJG',7,0,6,9,0.045150,'Deep Signal','none'),
(1965,'mid','ZnajejgtQeDZANF7DhQNF3uNua7SXqi8yZQ3R8pfWfax',6,9,1,6,0.038410,'Deep Signal','none'),
(1966,'mid','kL58gpEvYM67CAo24GFndFkPDxyv2miPxiCsSHtWTfMa',2,1,1,4,0.030060,'Settlement Violet','none'),
(1967,'mid','Q8h97jtqm2bKLsqVcAyanCbD4u2cw69Vj31HA3sXg1kh',0,0,3,0,0.042905,'Custody Steel','none'),
(1968,'mid','FVYaGWgyP6Q9BoiPsruXDqcBvAHLrUBQfrrZcae49XyS',7,4,7,6,0.043725,'Index Indigo','none'),
(1969,'mid','pNVVi8jhTxqcxEcTG2Uv5Wvp8S62gqZpKgrj6QHw1GiW',0,5,4,0,0.033320,'Index Indigo','none'),
(1970,'mid','vV9URC53AvVQ1gwppDt6MxunJat997rKC7E6z3u8JCGq',7,2,5,3,0.059625,'Deep Signal','none'),
(1971,'mid','Q6J6CGe1FvfknXvkB3qz2rAZUwNCmSUdfDg1Gc5Zk1xi',6,0,6,8,0.037220,'Custody Steel','none'),
(1972,'mid','tmkdNzXUYHHTQYLiGfG6Q9bfBgmtWpKXrMtFyytokmVf',6,8,0,4,0.065485,'Settlement Violet','none'),
(1973,'mid','UBUskxN1QbbvFDHuGqb7LAFLPXdCKQkeLuzMfWm85ir1',6,1,6,6,0.033700,'Ticker Cyan','none'),
(1974,'mid','2sYnDrorvZxxTqNADiQXCnLp8N4MdWP5FQZrjTFqFqkQ',6,0,1,0,0.081715,'Liquidity Teal','none'),
(1975,'mid','m4jwr24nUPBv8CbNocbtDHZz4cy4DkB1zYVv4d4Bd5H1',4,1,7,6,0.047385,'Ticker Cyan','none'),
(1976,'mid','s8FzaWxU2aNJEJsRxBg1rikEKZfVGr2XP3CSuGYLhjS1',7,2,7,0,0.056860,'Liquidity Teal','none'),
(1977,'mid','uenpMQHvpkKEofwqeLyjXyLLAFjX7saKrTkdx44uyDtY',6,5,5,9,0.071080,'Index Indigo','none'),
(1978,'mid','Sf8BJaqfsq2Gd4q15RQq1sN3x4uGCEmYaPYnKSNdJAXF',1,5,5,0,0.047925,'Liquidity Teal','none'),
(1979,'mid','rNcH3eEKJzaNpfg92FJbw4nsZMdAThFDKajP417Y59J9',2,9,0,2,0.049035,'Deep Signal','none'),
(1980,'mid','U8W1az7399UwvwSB9xseNCmgq7XLWKLcemY7ECRif59h',7,4,7,8,0.036820,'Liquidity Teal','none'),
(1981,'mid','eenGP6ttW26bR81RBfGAZr8X5yXL7JtGZLGyUVdCpwKY',5,5,5,9,0.056380,'Terminal Blue','none'),
(1982,'mid','ZDGmSR14GUf68zHbYapCc9GM45Fn613z3WUecJKcu82T',0,8,5,0,0.045310,'Settlement Violet','none'),
(1983,'mid','rNbX2twGs5CrPEqUfwouKMZg4yfUum2DZuSurvc8g7BB',6,6,3,7,0.039870,'Deep Signal','none'),
(1984,'mid','iBzMUAQv8jAx7MMh21pwLBddpT8T3HQHXGWH7FL8V5UX',3,7,4,9,0.044330,'Index Indigo','none'),
(1985,'mid','ugAJHFuyAQyxMbS9Dt5CVBCfEFtgHDJoX9sCoR9cC16H',0,0,6,7,0.038270,'Custody Steel','none'),
(1986,'mid','PT9HtDD25K96XbwnEQmg5GauhmgkopYC3oq5hLNxKGSg',4,4,2,2,0.062900,'Liquidity Teal','none'),
(1987,'mid','NrAaUEKDmja7o2iPBc1Q5ijbeM3u7xfqnJvSCXb43F9x',1,7,6,7,0.052400,'Settlement Violet','none'),
(1988,'mid','xZwTbd5tLpjmUaZn5LyzcL2qkojs9YWxZuAm4PALDT4M',7,7,6,7,0.030320,'Ticker Cyan','none'),
(1989,'mid','ZrSmRPqvAKpMVBiQBHHrurBLU5pgYEPaypU3iGjxNfsJ',2,7,4,4,0.045370,'Custody Steel','none'),
(1990,'mid','8R8tFB1rMsPoMfbZxJpE4K8QjwWnnkt9cJNJ9UuGvmpt',0,9,6,4,0.045500,'Settlement Violet','none'),
(1991,'mid','nqxpKywn8P57GyJv69XQoSTXykvUsJeVjB3MfvP2C51H',7,3,1,3,0.047025,'Index Indigo','none'),
(1992,'mid','mXPKwLtYYAU4mcqkBvpExBoYcHCAk3Vv8SmYfniykyrS',5,1,2,9,0.050135,'Ticker Cyan','none'),
(1993,'mid','wzQrBKFE6Ja5asEXwbKGSVx8iKcjtuspKBoJgJc1NmQz',1,0,6,3,0.047835,'Settlement Violet','none'),
(1994,'mid','Hk4wdQMG3n9KUbNvbLykALcG6SnUYEPd3yG2D7k7Bg6h',5,1,1,0,0.040020,'Settlement Violet','none'),
(1995,'mid','TDX6nHMCUhABss17QseJ6qPjKbZvN7o3HqFcV2TJWNvi',2,4,6,4,0.044985,'Settlement Violet','none'),
(1996,'mid','jQPCSUcbGom5gRxPC9upauKMRUqCYSn9fZR9sQ3DbPK2',1,4,2,3,0.086340,'Index Indigo','none'),
(1997,'mid','ymjoGicFMSaTLxu41EZT4JxA22YLU6Edh6vabe8qUk3L',1,4,7,9,0.047490,'Settlement Violet','none'),
(1998,'mid','v45AWnYqrc5U8FhUSGUinFfA2ejkBsAJffUoNy2SWdA1',4,4,0,8,0.041825,'Custody Steel','none'),
(1999,'mid','6RJFcZxdp3rtrGX7HUGniX9rh73fVkWf4Fx7E2LrFoan',1,1,7,0,0.042775,'Deep Signal','none'),
(2000,'entry','dna6UNa2kg24qLHz3JVFD1gBvV4siURq63ySjLxfwYBP',0,8,5,0,0.033880,'Ledger Green','none'),
(2001,'entry','XufJ9zD9ESSnQ4eUfAJ2xaCt4naGbyDQppxSqYBLJtBY',0,1,1,8,0.045540,'Filing Grey','none'),
(2002,'entry','NGLu3ZjQ2YZXuUovDJnnPebyPHiXpReGk1oeqDHNsEET',6,3,4,4,0.055610,'Breakroom Sage','none'),
(2003,'entry','cvkGqz3qebiycLymKKi1yvctKyCQoiknAifdgXaBDYQf',2,2,7,8,0.037600,'Drywall','none'),
(2004,'entry','F6DWL665xTefbrqo9QC9raq5eZE1RyCSosPS1RrQ2hHj',2,5,6,2,0.042480,'Manila','none'),
(2005,'entry','pT9XknkqqZGrPG8nmTYMHGr3TnkYEz7VxSyxuX8adQsR',0,8,6,4,0.036000,'Drywall','none'),
(2006,'entry','pUgCwz16K4So9QN7aRbwn68cnunfhotYYthR8CuY792J',2,4,7,8,0.036400,'Toner Dust','none'),
(2007,'entry','v9w5RmgqXmUU3ZJpF3Csq4inFBaxrzRVWjLaF5zvNSGm',3,5,1,7,0.049920,'Ledger Green','none'),
(2008,'entry','wQyaKJZxqiMKE2H7sz3YTpa5qLNNwbATxb2NVaoXEKWg',7,8,5,9,0.050410,'Ledger Green','none'),
(2009,'entry','voBmUBs5DnKFMwzunoTwH8ArdbJEzT9TaEunV8d83SRF',0,7,6,5,0.061420,'Toner Dust','none'),
(2010,'entry','6zwvWb1xtLj4iNXeFX2pBLMvVpJV7cRSRejxM6xf4XRy',0,8,1,4,0.039160,'Cubicle Slate','none'),
(2011,'entry','LYWA96sdDDfpTcxT2fD4SzDQ1GDsqwswmt1dkcXhMMZ8',0,8,1,6,0.045820,'Breakroom Sage','none'),
(2012,'entry','nxnxRBcSDeAwfK5rRdUTbAF2PkMVDGM2spyjVDELhZtQ',7,9,7,4,0.056260,'Cubicle Slate','none'),
(2013,'entry','DDUGpnajnxqNgdWzhhP6MkApYMB4ZM7bwkMGDY1Y4UfC',0,9,1,5,0.033880,'Ledger Green','none'),
(2014,'entry','Vj7HQmhAeqApFnyD1gh4YqwPJjdQakwcVHSt5ysKeqzZ',1,0,5,7,0.051040,'Manila','none'),
(2015,'entry','PQxRLt1dDFdb5sEK7wkZ2KgXrLLDQAiUoR1vVovsXQbe',4,7,0,6,0.024960,'Drywall','none'),
(2016,'entry','Qam4QRTsCiDKFRuSwfQgVc5RQ5vrcMtzKnJGvC8tixRN',0,9,6,0,0.079380,'Toner Dust','none'),
(2017,'entry','g2qnPmF9geCzTWarL8XhmWui6ynGngvgj8CRNxWQwhmc',0,4,5,7,0.028800,'Cubicle Slate','none'),
(2018,'entry','7BgPXDkntdKKczj2H8e3ERazbNFidcNBsp7kQrUg4BnZ',2,7,5,5,0.029480,'Drywall','none'),
(2019,'entry','wViRwLXLT4wA9uqUMM4CxkrD4g36XVkLDUhqzc72aiLt',1,8,7,7,0.039360,'Ledger Green','none'),
(2020,'entry','kvrzodNcUJ85ERhn3qE17Nyv48Et3NhnjahBrHxidDP7',3,9,7,6,0.041400,'Drywall','none'),
(2021,'entry','HKAubDPXL4GJ3ASBB4oAeYm9qzqvivYTo6C6NdtgoJUp',2,8,1,5,0.048140,'Breakroom Sage','none'),
(2022,'entry','RKjrJLR8MwbrRpr7vRJHNUQ9UV9E5wjyxaDXa6sJt77S',5,0,3,2,0.035420,'Ledger Green','none'),
(2023,'entry','yU6MFpriHrHG3tUNGUMhDLWYfE2w1Pwyiy2N8aeSH8HT',7,5,4,7,0.036480,'Toner Dust','none'),
(2024,'entry','YpkuSmjjjypntgw71vr9L1xJixLtN1AYu3HmfYfALTi6',0,2,2,7,0.048720,'Drywall','none'),
(2025,'entry','5VKtfj5T7ibsLHHhu5PeFvshGLbT8oTxteqoE15YZHwu',0,3,5,5,0.043680,'Cubicle Slate','none'),
(2026,'entry','oUpYKaP2S5EUJwjDd3pvrSEgC3i8rYgucfNUbrXti436',0,8,1,3,0.039520,'Cubicle Slate','none'),
(2027,'entry','RWkxwHnxdkKMCtRaJ2DDhttfgVS1BPTaAySujk4K5kM4',0,6,6,6,0.029760,'Cubicle Slate','none'),
(2028,'entry','s3AX6DqJNR1rg8jWmeqbCsRrEXWaUrCw42rsqeZhJSdi',5,9,5,9,0.033120,'Cubicle Slate','none'),
(2029,'entry','rex4WmUvotzRbdZxJtCoBu8bKZq1AHN6FEwuPCezpipu',6,6,2,4,0.052510,'Drywall','none'),
(2030,'entry','VfTuFCa376T6vcp6SNFnRnsuw5MNc2hrbC4tnV9ZbDR9',3,9,5,4,0.040600,'Cubicle Slate','none'),
(2031,'entry','TTZZX5p1RgsQPx8ygnD7QLTGQKSU9D2PxVguBNCswPEC',4,5,0,0,0.030240,'Manila','none'),
(2032,'entry','Fb191hKbetUYg8Ftop2AUapRva3cKaMgrLnAaEJ48gsa',0,3,5,5,0.035040,'Manila','none'),
(2033,'entry','mgJviC4M98XyvAiWs7BBc24Qm8Vz3rNCr7RhEMNRSgkP',1,5,7,2,0.047250,'Cubicle Slate','none'),
(2034,'entry','1k5dtQ1pAhvd7tKnfvuZwbMKT8iMxihYLMWt96Srv9rT',1,9,1,6,0.067000,'Ledger Green','none'),
(2035,'entry','njkmNjNGu6NkkkxgjscGUZfmAMnzxXoqHGXgGQTbu3Wq',4,7,2,6,0.056640,'Breakroom Sage','none'),
(2036,'entry','moNZy1yQgndV4hLQSCLUykDCSqDN1DtTW9aWBdP1tbkS',5,1,7,3,0.042320,'Breakroom Sage','none'),
(2037,'entry','D3zWr2825VtUd6HJnsJRExZZ29S8v3RTSaTPySZRojWn',2,2,7,5,0.045240,'Toner Dust','none'),
(2038,'entry','sa9f1Q8oynE5C6XVJtfkcPZPMbnKfoMHFbHsDAjf2N4h',1,9,7,0,0.104340,'Ledger Green','none'),
(2039,'entry','y69rsvcvk2FsVx2uXK4CBGztnyyXCxMzZS5mMUmiqovo',0,2,0,0,0.043470,'Breakroom Sage','none'),
(2040,'entry','qtGVrYubL8j5ukBCr4UGmfPZwnS2ewFF164erZXxW3k3',0,5,6,9,0.034960,'Filing Grey','none'),
(2041,'entry','SYTJEVgHooXLUhxLYVaMmCQitVZT4dEjSWanMSt8qpfJ',0,4,5,8,0.040040,'Cubicle Slate','none'),
(2042,'entry','9gNSAxxvBJFznkYKzerZkCte4yJUpUhQtp6kEz7BWSNt',7,2,2,4,0.038000,'Drywall','none'),
(2043,'entry','j4soEu5U4Ucz2TxT3PfM4rcSt2QXijFX3U5a22QKsZGn',1,0,4,3,0.063000,'Breakroom Sage','none'),
(2044,'entry','V884hVGrrJNkqs9HsH7HEK652ScGATaY9jvCQg1mJk46',3,2,1,5,0.035640,'Breakroom Sage','none'),
(2045,'entry','yWbQyMDZM2e6yv34y9gCR6wF4f4j1EtnaLUzWtBAhh16',6,8,1,2,0.043560,'Toner Dust','none'),
(2046,'entry','ySVKX43YRtpYqfGsVt7ZzF5pUT7pZzZPoZaAc3oPkrzB',3,5,3,2,0.056280,'Breakroom Sage','none'),
(2047,'entry','HzNNLgMyTsi7Q2JtKouehUBE9LdHXRuWP65pfcT2ZKwZ',0,8,2,3,0.047570,'Manila','none'),
(2048,'entry','KwQHx9nvVUhwJYCM5Gf2YSAkDh8Cab7BYhAQFAfB2TcH',0,4,4,3,0.046560,'Ledger Green','none'),
(2049,'entry','UiHgmFfbid7rMYheHvC6aB4EiqjEkuZmiYpRxjL2sD7P',1,7,4,5,0.044730,'Filing Grey','none'),
(2050,'entry','y2pdjxKcbXpG34Y2aoffBMNyXLQXBM9hqQqN25vHGgtg',7,4,7,4,0.040020,'Toner Dust','none'),
(2051,'entry','MS7pS2UKaXDr19LHrLzg7R1QYNHZDrUuL1AZ5w43Wygg',5,0,1,6,0.031200,'Ledger Green','none'),
(2052,'entry','tBuqi8y1Xv9RVMDTdHhEuTwcViuNt2emhRYghuiJGsBv',4,7,4,6,0.044400,'Ledger Green','none'),
(2053,'entry','JeqG2iEQGs55futD7arCUzi5Hm9J1qVi5WGPEAhcEzPj',0,7,5,0,0.030400,'Filing Grey','none'),
(2054,'entry','gN38nDwbDeGg4b5QJR8sx2sBdqLwDq6uW6cCHqPrCcAL',7,1,0,7,0.035200,'Manila','none'),
(2055,'entry','YHWHNCWcKpwuodKgHPKsaTQd6Dq1LH4NrkiTE2v2XWvg',7,2,7,2,0.032760,'Toner Dust','none'),
(2056,'entry','aMYVpq7KuAR3BYQHu1NBG78DRooJrZyShWspvXapZiCQ',4,9,3,5,0.055610,'Toner Dust','none'),
(2057,'entry','TCdhLC2XqCtEZJck7dukGgaGLNM4x4aFJRs9kvsGgEf6',6,0,1,5,0.043660,'Toner Dust','none'),
(2058,'entry','ZvBgG5w8PbHryADVdyKhj9rBgtkXUpKjPi3pWQggBaZF',6,7,2,0,0.048000,'Cubicle Slate','none'),
(2059,'entry','y9XGSUPnFdAy6gizhybHy38jdPwkN9tfuAQXo47sESb6',1,2,0,6,0.044080,'Cubicle Slate','none'),
(2060,'entry','NmF3h21y2HVPuiZGaq21cG3ac63znbFNc98HpBrqyYT9',0,3,5,9,0.038400,'Cubicle Slate','none'),
(2061,'entry','of5RcPkV6PXtuEtuPVTqorYccJCZz9Wp1A3xNA6FoeMX',7,2,7,5,0.069560,'Toner Dust','none'),
(2062,'entry','Ms6V8WAnYivrbgkyt6zzfehbQsfgxYABsqgy5ref74BU',2,9,3,0,0.060300,'Filing Grey','none'),
(2063,'entry','dWWDag2iAcw91br19pepiHxyU1JY8R6bEES647YdkSAA',4,4,3,0,0.049920,'Ledger Green','none'),
(2064,'entry','zMCiCgfWeT2CLDhKnMtobuwByvEuZhKqHsRcYhmbwyT9',2,9,2,7,0.044840,'Cubicle Slate','none'),
(2065,'entry','za23igQHc13BUEb3tkpvFH2TJP92pssi5MToQRctxmVM',3,2,2,6,0.038400,'Filing Grey','none'),
(2066,'entry','ybtDBqh6ompqr9PXkW5bdwEUDmxdm9iCjH4PxuepsZpy',1,0,6,2,0.053550,'Manila','none'),
(2067,'entry','BTCYkv9VW2Do6MKDA5igPKfTp1WHCtjdS5Wobf1oRxrJ',2,8,6,7,0.029280,'Ledger Green','none'),
(2068,'entry','uHJrMkVRrJQp21Mo887REVJngQ2VpUQTgPo4dnqJFFuj',6,8,5,9,0.043700,'Cubicle Slate','none'),
(2069,'entry','Qi8hyGW5q4Spp6GKeXEfMQ1LcqWWzqccCb22KUi7T8pd',7,5,0,4,0.050150,'Toner Dust','none'),
(2070,'entry','LUBV3qU5cNazSCeZWqnrEifhAbow7zsdq1P7noRbFRwU',6,4,7,0,0.070300,'Toner Dust','none'),
(2071,'entry','MwbFFyrGSaz4WnV76jXHZU1j5QD2PJxWeoNaqLr1jiiF',7,6,3,0,0.040020,'Manila','none'),
(2072,'entry','SjAuqE9vJdaPntQsLBrSZtTUCoWHGW4sgrUDQXbhpP5L',5,7,6,2,0.061560,'Ledger Green','none'),
(2073,'entry','Sz45QXaWouQUhJDdzC9TBqcUqupRwP8rpLoNz1McLMQB',7,2,2,8,0.044250,'Drywall','none'),
(2074,'entry','SUCLoqoV9Eojzai61QpGYEzxjkvNZ3UwJBVaUkJectKH',1,6,4,3,0.048720,'Ledger Green','none'),
(2075,'entry','WLtQWqSWmyStmRBgR1JERBFFeesszyuaTLDXovhpP5ef',1,1,7,5,0.031280,'Ledger Green','none'),
(2076,'entry','KMgLdwuJKGPcCLccaV9tx6Q5ZGKtW7BaWjTNYnVqVGkd',1,7,4,2,0.063990,'Drywall','none'),
(2077,'entry','GoLskXRCRmhEjiayVcMxxKGZj5m53xsgq7A2Ktm89HQg',7,5,6,6,0.032640,'Manila','none'),
(2078,'entry','itJmubqhMYqjsueuAj8rGr1129cwgecDysEPMwdLUbJm',3,7,3,7,0.059940,'Toner Dust','none'),
(2079,'entry','3k9ELvYqXP2N9rFNfADAjReJYgHxTY9BuUMQbeXdWGxi',5,0,5,7,0.038180,'Cubicle Slate','none'),
(2080,'entry','D3tCvmrqW3L6R8Kexnw7tkmKHAazEHXELgzVqruSce9E',1,9,7,0,0.048360,'Toner Dust','none'),
(2081,'entry','HHpeyPn38Ksb6Lo1hQJ3oKzbSS5KRufhsAmn6fgLDSCx',7,1,3,6,0.032000,'Cubicle Slate','none'),
(2082,'entry','ZofauU4J4nMBhX6ZyQsn69xjNp2aJAeYfWeScBwCcTvY',1,8,4,8,0.035380,'Drywall','none'),
(2083,'entry','K7AJRQa5RM8XdD8uARU5bBbxNPxM5o7dkgf3oznVVKJw',7,0,4,3,0.044100,'Breakroom Sage','none'),
(2084,'entry','8RLV6oUxC9rPAz9wnTSXnqnAoSEKHZPtcCDncpzb7krG',1,8,3,9,0.065660,'Toner Dust','none'),
(2085,'entry','Fg18AuaQA33a5T3RmzC4fLLAGPYeGfyBzMw5pMoqyUfn',3,3,7,3,0.076360,'Ledger Green','none'),
(2086,'entry','JQnpMptCKCZYLdze7VfQSB7PcLEFSXTdwGvFyA7xazdr',2,9,0,8,0.042480,'Drywall','none'),
(2087,'entry','GbSxb9ypBTfyWRHA8pKCynry5UqvqvmFT1aYBLuW9Avc',2,5,1,0,0.040320,'Breakroom Sage','none'),
(2088,'entry','6N31E7WAcAHtZxRgbazU78Z4vp78qemXDY7dYA3pWm7H',4,5,7,0,0.108570,'Cubicle Slate','none'),
(2089,'entry','2ufc4WuRpXnajFQK6BWBBfCVKY8oYtpPAAJkAC5fBPqT',0,2,7,0,0.040600,'Toner Dust','none'),
(2090,'entry','kZ5StQWqZD1LZSjm9yEAHGD1C32bjgkhW19ab7PEi3gp',2,9,6,0,0.044160,'Manila','none'),
(2091,'entry','DuooWfUZLhHjX8TjsW8eVcCEMFNFvDdeuYpEc17YMjV4',6,8,2,2,0.029440,'Filing Grey','none'),
(2092,'entry','BbSFkj3g3UeGkvHYMdGgMZZrJww85AqZDRmDy76Sajpw',3,1,3,2,0.034840,'Ledger Green','none'),
(2093,'entry','PAxJ6dDmhs3UuGYTWpGwmGUK5UsLGi9v76aHPb4u66Wb',2,8,3,5,0.067230,'Drywall','none'),
(2094,'entry','9XThGbfp6t6jFkEpwwHQKajx3vg5MT9Rq3LZdFeme7wL',1,9,5,0,0.028800,'Ledger Green','none'),
(2095,'entry','ychg9gSQBV6Cxj83bzLwumYCR6qsyWqmfrXE1QnRQbwP',6,5,2,6,0.026400,'Toner Dust','none'),
(2096,'entry','8CnWrnLL3D6ETW7XGjjMzopoJEPMVcUiYpTn9TCNzG27',6,9,0,0,0.108360,'Toner Dust','none'),
(2097,'entry','JMXdSQqyjFQCdXc6EZkPyWsduZsboWU7mkudq5CAYYuJ',4,8,7,0,0.048840,'Breakroom Sage','none'),
(2098,'entry','6NRQdNVKhAYH3hRL1jDT739PatU28fyCBqy6FNCY5E61',3,1,4,7,0.035040,'Filing Grey','none'),
(2099,'entry','DPgEikkDsRR8RXkj5WNjFXgFoQk3nzEhvrZZfvL2Qwwj',1,6,2,2,0.038640,'Toner Dust','none'),
(2100,'entry','vZrYSwLPHPWyP6bHUiMvGfAbaAkiBAgDMaq49WeyBABM',5,8,6,8,0.034400,'Breakroom Sage','none'),
(2101,'entry','FRjxZCUicbH3iUBGkr18Akfa7J9dJB19Hofm1Q5ghvBb',7,2,4,8,0.024640,'Toner Dust','none'),
(2102,'entry','rgKTsA8bpY7sQsomw7yh3QNpKkjLpWKpAHEPcJrVRbFQ',1,9,4,0,0.037440,'Filing Grey','none'),
(2103,'entry','vhk1KbvXedEDg9Qv6VfgPj1XhJSyrhfTb5NbFgwgaEpT',0,5,5,9,0.065320,'Manila','none'),
(2104,'entry','cyGLZp7asLHvY3pCxFagDtGAwMJ2YeJ7fs4qzbNRM7Zj',7,4,5,4,0.040600,'Filing Grey','none'),
(2105,'entry','ESwMWqyq3JB8zkUukGwJegv1tQeXEGqykxcMpADCo1Xd',5,5,4,3,0.124740,'Filing Grey','none'),
(2106,'entry','7mW53g4z59AupNAMjkcsMo7UcRP65PZvowcSAj3o418t',3,5,5,5,0.061640,'Cubicle Slate','none'),
(2107,'entry','Hcd8yQnvoepoRA2w7FuPQXNHbKUpwcVMMAoxxhhAMbXm',3,0,0,0,0.039440,'Filing Grey','none'),
(2108,'entry','wqhCQzsFsngaKfLyQhSJb5LfufGmHqigXKk4CHC7AR9Z',5,2,7,6,0.061640,'Toner Dust','none'),
(2109,'entry','PSQvbbJ3GC8Pvh17oXLLBvd3oos8UCj2bbcTBhje6AyP',5,1,2,4,0.060970,'Breakroom Sage','none'),
(2110,'entry','c8PAa4WoCw5Yr7BFgGBcvrgf97BEsHFuFtxYnYeDC19S',0,3,7,5,0.028060,'Manila','none'),
(2111,'entry','qRWyhJwEeHPTM3zb1yvfxhQsyXy9S8HhA9662b6pqgxo',0,3,5,0,0.034000,'Cubicle Slate','none'),
(2112,'entry','KLfTf41Mxwye8YDkoZj7US64cLvTkx5QwpG4ov3vRT5k',5,4,2,3,0.028400,'Breakroom Sage','none'),
(2113,'entry','VEq5RELHRiBC6ukw5a6bzvkr27D72VZKaDhqFLXxcEEj',0,0,0,6,0.050920,'Drywall','none'),
(2114,'entry','AKMVbWvvxHguxpKedLEHr9v4yGVjqm4oD6vZZ2SWuhkU',5,8,7,0,0.045560,'Drywall','none'),
(2115,'entry','h1NfVEQeBa4WzPn8ztkqwQQn6gL6d2qQXuQG5Co6qK5L',1,9,3,5,0.100110,'Toner Dust','none'),
(2116,'entry','74T724gozH2ZV9jifQnffiC8pNZ83DuuZGPxGQq64RiR',3,4,0,3,0.069580,'Filing Grey','none'),
(2117,'entry','XQ5etsB9TVZfitNZZHZETcCpxnQgLfWr9FJaA2N8QtZh',2,5,5,4,0.044160,'Ledger Green','none'),
(2118,'entry','xCcrmbhqSJqAKQ934pFLyGkHGGQKekd2jfu5f4PjSSWX',3,6,3,9,0.053250,'Cubicle Slate','none'),
(2119,'entry','ovm7SSvNEUkE212JU4a8dUHCES6jM6vwrXGccXJ6tSpc',6,6,0,7,0.032400,'Toner Dust','none'),
(2120,'entry','btpqSKheN9KRCxGnrHDSJStPRdNGAcsYMXPvsiVqKDuG',7,7,1,9,0.027280,'Ledger Green','none'),
(2121,'entry','tQ1Eh61TPYnGesChGYDqWNWsQ3nPMsFQT4ySxNcYaHyd',7,7,4,5,0.040870,'Cubicle Slate','none'),
(2122,'entry','wCDB6CYKwavvvKeAg6baH2maoPE5wxXqkE7iCQkEp9aT',7,1,0,7,0.034960,'Manila','none'),
(2123,'entry','r3sTpMioMBoTEUwftDuZUAR3LvFRRtRULmKkfQuJYWkt',5,0,6,0,0.021760,'Drywall','none'),
(2124,'entry','7SBjfVk1R7y5itB4VY6jnmtVCH6hhrapeN6Fw7qUqgci',3,9,5,5,0.061560,'Filing Grey','none'),
(2125,'entry','acuEmPQqLmGAxMSj2XYqkLXkneRB5w6uBWNo61djL6Hs',7,4,0,3,0.042680,'Filing Grey','none'),
(2126,'entry','XwSPj1L5q6YzMYLvj4V7CAVekcbiQzEETJvSoNEZiQBG',3,5,6,3,0.072520,'Ledger Green','none'),
(2127,'entry','U1zHEfS8jtabVQc8n6RoVsWRpfwRhQ5GzFtGFF1YS3Qr',0,3,5,0,0.041300,'Drywall','none'),
(2128,'entry','udCsn3jMK9GHzoFkkMqGbXjUoTChsPVreTp8MjmoDwEC',1,0,7,6,0.030360,'Ledger Green','none'),
(2129,'entry','q5sycsPQaej5Q9W8PXZJS6W9juqRRzkWYxQfonZ6fvin',3,3,4,7,0.037720,'Manila','none'),
(2130,'entry','cZapmBuEgBZiejedYPw5C4S4BxHNZ9xgX9pvTj7Yh1vw',2,4,3,9,0.039160,'Ledger Green','none'),
(2131,'entry','9JDSrasNoa46k2mks8YNmnewNHgMmx31PauiDXZJWJes',1,6,1,6,0.037800,'Toner Dust','none'),
(2132,'entry','5B5wSY2hdroAdJEKnKiLa433PaDTaxrxC1eREuugVRqK',4,3,6,7,0.036960,'Cubicle Slate','none'),
(2133,'entry','EFWKPeUe6KiJVaXMkx4XCvnGUZXKw8TDAkAzLu1G2975',4,8,5,9,0.040920,'Breakroom Sage','none'),
(2134,'entry','Z16XHnfDLMK7Tv3835rew4GP3ebkZHDV96NBa37Zjnei',1,1,6,5,0.064610,'Breakroom Sage','none'),
(2135,'entry','CvkKAqfk6AZUaeTmvyKfDpxujg5quq4tr6nWGWT5WZr7',6,9,6,4,0.024320,'Cubicle Slate','none'),
(2136,'entry','xtSAFQhui6NoXnyA2hhyTPY8BxASPEnZMipw1vGQkd7j',2,9,7,5,0.019840,'Toner Dust','none'),
(2137,'entry','edNXBGB3kK2RQkfGuL7Jnn7ewzVwxLc7qpY1nriTqpDg',1,6,6,7,0.038860,'Toner Dust','none'),
(2138,'entry','mvsoNJgbjmBX4B1LMt44wiP51Fd7Wixu12Mjj8fz5Nq4',3,6,1,0,0.028980,'Breakroom Sage','none'),
(2139,'entry','9dZx2YfTkFY8hZUPWWvWyR3kCtrg2mQ4wmHdjFGzRaxV',4,9,7,7,0.031680,'Toner Dust','none'),
(2140,'entry','TM7SM3ZBwbNE4t46DvoyZfjEswJNEhcprEwv6UkTAv5k',0,5,1,2,0.042920,'Drywall','none'),
(2141,'entry','GD2GMS9rDbebqr1jgkGGMfbrBQ9Ku587KhYTQUkH5iMh',7,3,0,0,0.027600,'Cubicle Slate','none'),
(2142,'entry','NCK6J3xZfhoMtknZAmVc6jZ7bFhEFmLdZHR1EAhrAUUo',2,2,4,3,0.035520,'Manila','none'),
(2143,'entry','zeYZFiAGKYTMbgPLafePQJmmywh9HA89WW7RmD2eu4RA',6,5,0,4,0.058290,'Manila','none'),
(2144,'entry','d2tYu8SsdHYKmECMYDgpwWSaLRe5gkAaYtY52R36pGF4',3,1,7,6,0.031040,'Cubicle Slate','none'),
(2145,'entry','6Tomtz5h9iwjAjZCH2EFbz5P4gKufSCeKbCzKEPSVKca',3,9,5,7,0.046400,'Drywall','none'),
(2146,'entry','yrc4YtKRG9P7pJ534WEKTiWXyrC6RMm1Z2W2qRFDXNaL',6,6,3,2,0.034960,'Filing Grey','none'),
(2147,'entry','3nitMW3DfWFGQz8KSbnAQJCtAPHbPSh6wNZkxVaZthH6',3,4,1,7,0.038720,'Toner Dust','none'),
(2148,'entry','jfguNNUq2EeEwrHJt94zFBeyHKwa77Za7ASe88axAJ3Y',7,9,1,3,0.093060,'Ledger Green','none'),
(2149,'entry','bb1ecY6bFJQfy8EoVjaebZGUYowp4guEu3Kcq7NEJHqZ',4,7,6,5,0.020160,'Manila','none'),
(2150,'entry','Z9AXFoC9HeLWaqrSMy4M4BZ1D4ArfBGb9bkfnbmLdvPd',2,2,0,7,0.038280,'Breakroom Sage','none'),
(2151,'entry','1ufwQuqGkQPH9sADDztyZiaKmjAGeG2Sso4XsJTbJvxj',7,1,5,2,0.038800,'Toner Dust','none'),
(2152,'entry','5ZXeMJbF6LqojSyjnK89vLGT5NPcuPGVeX57ewoFLTQ5',3,6,3,0,0.031680,'Drywall','none'),
(2153,'entry','iqUw9v1Ys39y9XXzsTwvFoWt2jTN9nPcW46zWrmazAuU',2,2,0,9,0.069580,'Filing Grey','none'),
(2154,'entry','RNK7LkgsEuiVFGhxabh1wYoWjiDX3QkUN6cf7wbSUkEB',6,2,1,7,0.033200,'Cubicle Slate','none'),
(2155,'entry','6BiqDnHUMQe9vVsjEhQapDFBVFTEDxb7Dbfz4VhbQBEn',7,5,6,3,0.029200,'Drywall','none'),
(2156,'entry','cxFUqfRLNr2Puh2v7g4VQNqGtqPsVF1cUmz9rUrfHjGn',1,5,1,0,0.039060,'Manila','none'),
(2157,'entry','oPQ7S9UriFVowgbzqdkcqr1v4aTtYXYftgtaZdpQyvWN',4,1,1,8,0.056700,'Cubicle Slate','none'),
(2158,'entry','wL8mvLqsL87ANPDStbLjtEZgAYeh9S8F2T6qPyMeBxWa',1,3,4,0,0.051660,'Toner Dust','none'),
(2159,'entry','EQYdt9igwX6vjM4d3irahppn4yFRdYJGzYGxhE1BekrZ',4,0,4,7,0.041360,'Cubicle Slate','none'),
(2160,'entry','swbLk9V5pVZPxibDE2rM7vBiFq7VYS7wfAXpEXaWVBzz',1,6,1,5,0.026800,'Filing Grey','none'),
(2161,'entry','95n4d1wZJLpMhbsyKRf3bmeu35Dddm9PAMhaqaX4yfZJ',0,7,6,0,0.043700,'Drywall','none'),
(2162,'entry','3tUqcR3mbmkgdjFZpd3FRuGP9HiwRiu1VPnGE1sx37Jd',6,1,0,4,0.049580,'Cubicle Slate','none'),
(2163,'entry','p8pnbbtBnQWEjZryvRPBQjPmoTfCoZRHSg4webZasTF2',3,0,7,8,0.041540,'Breakroom Sage','none'),
(2164,'entry','PCd5kXjdPv5TYZ4rM549Bkj58zLMwzzuzgHeJQu5BTZZ',2,2,0,0,0.061060,'Toner Dust','none'),
(2165,'entry','yreH2tkjqxehti2DrcfL9wCk4rpLGfHAxUEGGJpjhygu',5,7,5,0,0.041300,'Manila','none'),
(2166,'entry','aAs4jAMKbWP4WE7Y97aUCyWcUbCLLRhfvASn8LV3QXri',0,2,5,5,0.050220,'Cubicle Slate','none'),
(2167,'entry','Nko32m6QAGnPkMiKDxYR48ouMGbyHrHoCdnck4aQG9of',1,0,4,0,0.045120,'Manila','none'),
(2168,'entry','eA6WUpkBcAyhCDWe1gdi3uynXDeD3V6ApL5NcHwNGksP',7,9,1,5,0.064990,'Ledger Green','none'),
(2169,'entry','hwTyNCwJFS8XJ8oqWBUDnCvWX8BVFYgofGEGY188g3ZH',5,3,2,2,0.037800,'Ledger Green','none'),
(2170,'entry','kdJNjEFXPmqSzJdjUomKG6jWEXd2xpJ1XGQuoqej1M7k',1,1,2,4,0.063190,'Drywall','none'),
(2171,'entry','BP8QZSZY6Urx6FKu7cHJw4vFMeyn5DiiQ2DF5j7MuHoo',5,8,4,9,0.075440,'Filing Grey','none'),
(2172,'entry','96jyE9XkKsJbHqn5nFao6C8nJc493PagT4BF154Br6b2',1,6,1,2,0.033200,'Ledger Green','none'),
(2173,'entry','ofKx2fq1YfxA8YBLAKisPag7EBpEx9uSreyjQYKANvzx',3,7,6,8,0.031200,'Ledger Green','none'),
(2174,'entry','ebVoDko1Lxg8yfTPfHH1jy8qmMRL9jEZcQuhYSYRBYUc',1,5,2,5,0.034040,'Toner Dust','none'),
(2175,'entry','LS75WMGE5EmkkNGGenHs1wdKtSnuwpYqZFqiyFW3SgK9',4,9,6,4,0.056640,'Filing Grey','none'),
(2176,'entry','sZbuN3L4s63YQeNyaVVCvxRm4z2t27Q6HXSj8mVcBAkR',3,0,6,0,0.025600,'Cubicle Slate','none'),
(2177,'entry','x3rRbWMyYAkivsuKLXxiqhusADryebx67JeV6C59Fjkw',6,8,4,0,0.038280,'Ledger Green','none'),
(2178,'entry','xHvcqNoqLvadqzavM1agREvh6bYf3xryhzCZUMDkExHX',7,3,3,8,0.063640,'Drywall','none'),
(2179,'entry','J4ttQCWPmZFtkNCCghqeCvREG4uP7rJCcmyH6DV6qqvV',0,9,6,0,0.048380,'Breakroom Sage','none'),
(2180,'entry','DUDiyYrXbuGFDv1uPp6SBBfWJhPTXfTpDxnrT7Wd1Pnq',6,6,0,6,0.032400,'Cubicle Slate','none'),
(2181,'entry','9M53CwYLsnjpnvRdhMoab3XRq7qxA9WRfz6faRdyHPst',3,1,4,4,0.032400,'Drywall','none'),
(2182,'entry','HckKJ5KYidk1ADNfYQ4rpfoUeahBybuLWqYNbUhfq5Vg',2,1,7,3,0.026240,'Drywall','none'),
(2183,'entry','2B3bozxn7zkS4YGKxeebVnkRSuASP2bNZrhXATwFSRRu',6,2,0,9,0.056980,'Drywall','none'),
(2184,'entry','22RME1VzaijDXYa1ZaRxRsVW821TJrmybty8Y7F6xxoB',7,5,6,8,0.036800,'Toner Dust','none'),
(2185,'entry','bf852xM3o9V8Qz2BZAGkwJ1Nnern5jYJq2xKhxWUtApD',5,1,0,3,0.042120,'Breakroom Sage','none'),
(2186,'entry','ra8WVgaFdzx9SGGysEUwohyWm4YGxVkqfBZU1VU6UUaC',7,8,6,0,0.030080,'Filing Grey','none'),
(2187,'entry','QtKJK16ZGFVn7XsHZs4RGsN6EavYJ8SceSHgTEEpYXgw',4,5,3,6,0.023680,'Ledger Green','none'),
(2188,'entry','dzazvUxxqGR3aAo2nH11BAz7XqzDNX3eJZ7Fb9Pm5sHz',4,8,5,4,0.026000,'Cubicle Slate','none'),
(2189,'entry','nkTzXW8EJokVf6M5nn2BGEZfRaP4FqsZ9YJwBy64EtKT',2,9,7,0,0.032240,'Filing Grey','none'),
(2190,'entry','xK65xnwLNjNoY9ep4p4wfRcScWbixQvHpu5MHhYLdfeG',7,1,4,6,0.032240,'Breakroom Sage','none'),
(2191,'entry','MKpJNPKRQpcK7bBjbuQJyTYz2TijKu8swEZfRdfYsyiM',4,8,3,6,0.024960,'Toner Dust','none'),
(2192,'entry','m2kSiKqchRSHugu9pUQh6UkdR5JJGbbmLiVQBX27krRh',4,3,7,6,0.109620,'Manila','none'),
(2193,'entry','fUqcrcsK4VKjCP1bZ3KSYxHKFsqYcptdTv7v5V8Kbcay',3,5,6,8,0.028400,'Cubicle Slate','none'),
(2194,'entry','A5D4W2NcdowdD2C1Ab9rEKcLHFh92PrTDdhEm9MATXFi',7,5,4,2,0.049580,'Toner Dust','none'),
(2195,'entry','K1kkLjg8yFAr3Vpq53JVJugUN5DtJ2VgMEvanM3BGR8R',5,5,0,2,0.052930,'Ledger Green','none'),
(2196,'entry','rbvhFskYaBFaM4F9Tn4kH4b4hZCYgQ2EfChZQVjsGkgJ',2,5,0,4,0.031680,'Toner Dust','none'),
(2197,'entry','UmeGoxuUpXjmAYsdRay4dkKiMksndSiLzkQCLm1RKhKK',3,5,2,9,0.080190,'Filing Grey','none'),
(2198,'entry','SCoG7zyWWD6TXrxqE5ifpnQFEH5pxLza1woRfAFSTZE3',2,7,2,8,0.040940,'Filing Grey','none'),
(2199,'entry','KZxJJwpSpaYCAZHRW1GniMcDYtk9tjLrQvkYaXAB9ye4',2,4,4,9,0.035400,'Drywall','none'),
(2200,'entry','tTAePQYA71vcv9CPBwpFL5dv212PYcACTsTKhFQC3eMn',0,6,1,4,0.025600,'Cubicle Slate','none'),
(2201,'entry','3v3Psrr2yqzGnfoLXun96mMy8HkKKZy3GueXifWXpgUT',0,9,0,8,0.033580,'Drywall','none'),
(2202,'entry','To8KqmpCJueQqzJyAKzhZknhCWC8vATuTksJNdXioYNk',7,3,7,9,0.068870,'Filing Grey','none'),
(2203,'entry','jsx72j86qeTDvELtgjgdvoUYYxkwHZLngAuTdACZtJDn',4,0,1,9,0.054670,'Manila','none'),
(2204,'entry','SVmVXgRTT3CcC4MX62u6JyFf7yzJiAeXsYJjzJ7F61Je',4,6,4,8,0.058290,'Filing Grey','none'),
(2205,'entry','tyiHW6iDrZuJmxcHoaBAKkRo2sh3zmYbNCMDZBpfyZ4d',5,1,6,0,0.038350,'Filing Grey','none'),
(2206,'entry','ZNkdNVpdHhiUJhWTQfr8y7noWVYHuJZCXn2oSkL45w9x',7,4,2,3,0.037840,'Ledger Green','none'),
(2207,'entry','WkvhfqXj9UF1HgcgvZfgF9XzPFEpfpkpAbR5xbMiQAPv',3,7,5,6,0.047790,'Breakroom Sage','none'),
(2208,'entry','MEQQsgSQCabNZmruoBVsoGXEJBFNUq7c7dm7HHb2wJnr',5,2,6,3,0.039600,'Breakroom Sage','none'),
(2209,'entry','vRpRFViuPwubJ3HYbhGJsttJp7a6sxyQ4JEpd2LHntgm',5,5,6,9,0.067000,'Breakroom Sage','none'),
(2210,'entry','Kjdo8UYu8jDev8CBkyZMGdqpb2osgUejuMG8RyUJGSke',7,5,3,4,0.062370,'Ledger Green','none'),
(2211,'entry','XG9BMviBbpAQnZt2MFr6aCMmgxfeVphbN8CzNdznrqPQ',5,5,4,5,0.071760,'Breakroom Sage','none'),
(2212,'entry','Ch2JBGN4otMxNrYHkdvXpxYry5J469FJCSzhgVSMFUWC',5,3,6,3,0.048720,'Filing Grey','none'),
(2213,'entry','bJY9F799G8nyqd6eHpcPts6LdZ6J51CYZJ5EKVSkWPYs',6,4,4,7,0.051030,'Ledger Green','none'),
(2214,'entry','7xuVW93N2bbwM655SEPu34ADkzYAPNasSxArHk4UNLJo',2,0,7,3,0.035600,'Manila','none'),
(2215,'entry','7R38Q2tMA4KQsANQZREhVPkioGJah8eyYasS3XbAy3r6',1,3,4,0,0.044400,'Filing Grey','none'),
(2216,'entry','ymwC8nUoL5qmik2LAJnDtzt5txjaLQ6TU13BQnRp7xzD',3,0,3,0,0.030400,'Drywall','none'),
(2217,'entry','XKH3h2vLASyzytWbe9sq8UA2ZNS3VsrnDuz4bcoM3SGz',1,5,5,6,0.032200,'Drywall','none'),
(2218,'entry','c8JXoeAN5JbK4HXTbqaJt3qB7imXegQcasw94SJsqX8h',3,4,6,3,0.060680,'Toner Dust','none'),
(2219,'entry','vt9GMBckMo6jUxJC6RmQYZZevfztCUgHDvGTXzLZatYT',0,9,2,0,0.037800,'Toner Dust','none'),
(2220,'entry','Lm3XD3VYP1kzMHzZiTeWW5wZaf35KbcgGeQAXb2uJshP',1,7,1,5,0.054270,'Drywall','none'),
(2221,'entry','5WwaZs3CUcXGVbACv4TJhwJvzeJuyJyaTbfvV64Y7wSW',5,8,3,5,0.033120,'Drywall','none'),
(2222,'entry','MvocN8xVyBTawftTMXpgdg7bPa84K3J98mah1MoQFhUC',0,8,1,5,0.053690,'Cubicle Slate','none'),
(2223,'entry','Ux3X4B6fUw2WvpFbFBQqavgxAMbWr2SBSKDHHNYKwcpT',3,4,7,0,0.044100,'Ledger Green','none'),
(2224,'entry','vSFrdJHNvK11GeKLfCrWjYQZufTze3MXy2EqkUMhbVAE',2,1,4,5,0.044730,'Drywall','none'),
(2225,'entry','p7KvkSZMQFx2trto5u9Rrxrjtd4ghYhYfFTKbMxsoftC',4,4,5,8,0.051030,'Cubicle Slate','none'),
(2226,'entry','CSfQeMrwmwgLXxSrKdn3gaPGJiQenioRh9kVRFspwf5f',0,1,4,5,0.048000,'Ledger Green','none'),
(2227,'entry','q5c9iTZEZMCW1izxMNjctaHiDnr7NnoDpdWGNm6r8g7x',2,3,4,2,0.118440,'Breakroom Sage','none'),
(2228,'entry','gRupLaci2PSJEUfZLus73XoUukH4ZWtPPqLcE1njsPTc',1,8,1,8,0.031740,'Toner Dust','none'),
(2229,'entry','92cdLbSbJF2eSXaNkcyvpZ5a72rLs3byvdK9Mxif5bLR',2,7,6,7,0.068040,'Cubicle Slate','none'),
(2230,'entry','o4JiZqTJ78Ee3zsAD5cVREWqM3RWpH81gr1ZGkTLJkk6',5,4,3,4,0.031680,'Cubicle Slate','none'),
(2231,'entry','3WvbMz3oKBDk8Uyit92Wrx6rzs5kL6mX4UtiDAxHj67r',4,4,7,7,0.053940,'Ledger Green','none'),
(2232,'entry','VmxVxG25uWbxAh2xePRJX66o3TL21b9HHpZWS14kaYqr',4,8,7,2,0.038180,'Drywall','none'),
(2233,'entry','MhQrkSLVnAuRTARLyqHyppRT2eLKSwYTDoD54cCHTx9C',2,3,6,0,0.024000,'Drywall','none'),
(2234,'entry','PiNdxdiCN2ysyVwZ15FaGmhxo1iMqdrmCjsjK3Etv5gv',5,9,6,9,0.042880,'Ledger Green','none'),
(2235,'entry','iGXdeTxzsMmZ7HisPN8onJ5uczp2zD7Q62TVDxre38CA',5,9,5,5,0.031740,'Cubicle Slate','none'),
(2236,'entry','cRidLoCwSArpdpzUQhCeB1id8xRBfdtZgSXkaUShWs7W',0,6,3,5,0.029280,'Ledger Green','none'),
(2237,'entry','KJKzqrrD7mSBAighy9DA3hwFEezfK3qXXpjFPdGHL8zx',0,6,7,7,0.046800,'Toner Dust','none'),
(2238,'entry','yEHm2LzyGUgeqWkkZ6DWYmqPNWQWXqY2AkF4sQnMN9pE',6,1,0,4,0.059220,'Filing Grey','none'),
(2239,'entry','doxYBsRZTbyYrAFyBxz9b1sFnYQ9fbF9Lao6k7AN29Ai',6,3,4,4,0.041600,'Filing Grey','none'),
(2240,'entry','CyatE1aaRnRFcXrLoSDHBh525pkrSSUaubmxdAMkQEQj',2,9,4,4,0.036520,'Filing Grey','none'),
(2241,'entry','xVtoLctWkMXce6vYwZSRPq5zh2kgGhpK13DoYassbJ8R',7,0,3,3,0.046400,'Toner Dust','none'),
(2242,'entry','KL7TU5FCNpDZfHd5pro7ua9LAsPWt2F7s5t8qbB3hf69',6,9,4,8,0.054270,'Drywall','none'),
(2243,'entry','6w8zQuy7LScFE7tToHxweZe911JHQd5th5rLUmMMYMxg',6,6,1,0,0.058290,'Breakroom Sage','none'),
(2244,'entry','Z6mpVL4qmZqFdaUBJsVJwWMK7mVnzV71BXdqRQZvSaN1',4,4,6,9,0.034760,'Filing Grey','none'),
(2245,'entry','MQcR33fUJFeX7CBJYJhpjundqtXrp1SjvS73Cn3vAwoy',7,1,6,2,0.034800,'Drywall','none'),
(2246,'entry','MNWp9FCVJyrXRXvD7zh9K3eaVnZQD91X9JLdYthxpEix',6,7,0,7,0.033800,'Drywall','none'),
(2247,'entry','eSa1nzs7iiaeYYCjxN4JQ9oX3DZzNY4t2zCziUsPnHEP',0,6,4,4,0.037760,'Cubicle Slate','none'),
(2248,'entry','urFewtsyoJ6DBeSfJhnc2aJAeB7b47nAZZnrQQfRYe9t',5,2,1,4,0.025920,'Toner Dust','none'),
(2249,'entry','gpzNBFZ1cKuYjVz7XDo3yTPgk1aUYgeAE7TzeRTwfbcE',7,2,0,7,0.042600,'Cubicle Slate','none'),
(2250,'entry','6ut8m8FYUznpobaafvRbnncBGT89a3PotbyH4duKZ1PX',0,2,6,3,0.035380,'Cubicle Slate','none'),
(2251,'entry','nUEa36JHtUsCSceGe9vdTZw9aAXJyNtDuW5Zcv4kyeEo',6,4,3,2,0.044400,'Manila','none'),
(2252,'entry','bHCBiAPicXTvLLnzm6h5iL1rqZFe9WswHfTmXFyK2WQS',2,4,2,5,0.053360,'Breakroom Sage','none'),
(2253,'entry','GdFA9XBaayBny6Z8XXmENBKqJBzEC7nqGSwLWFN7UB46',3,3,6,5,0.042880,'Manila','none'),
(2254,'entry','5ihJb1yxGz8XcvAWCw4ysLxnaMAkMdw1VLjCn5YsE7bw',5,2,4,9,0.030800,'Toner Dust','none'),
(2255,'entry','Po1WmMVMPSVGoJ8zCRyJB4aSDiE5GmVch1rAND6Ur5Fw',6,8,4,7,0.024640,'Ledger Green','none'),
(2256,'entry','q5wwGZzRGgph3fU2jzNEVLB1dxcGq9a7CpFSeW4mUTRH',3,8,3,0,0.039360,'Filing Grey','none'),
(2257,'entry','oCNrstScDgYjA5c24vTBTiK6oibWQcNCZ7HusoJ1MP1b',2,8,7,0,0.028400,'Cubicle Slate','none'),
(2258,'entry','JgXn6oi8QYQwakmn9ixJ367AcXYD6hzAijaYLFayrNC4',0,3,3,8,0.029040,'Toner Dust','none'),
(2259,'entry','6rgrtqAWabqL7snB16zfLJhYyykAv6FTwDTwLhLJqpUn',2,6,4,0,0.053600,'Cubicle Slate','none'),
(2260,'entry','XAAD1vy8a2MWHpMuaGntN2GtPMY2bnRopekZPXNkRrAF',6,9,4,5,0.135360,'Ledger Green','none'),
(2261,'entry','oEoEukfLjv3Xr4egtGDQoY58kPi7CCRarMtHiRauxoZP',0,8,2,2,0.062160,'Manila','none'),
(2262,'entry','K4foNhtMW84zEM2AS7yxdXyxN87dFz2MaR1TaigYTYW3',5,0,6,7,0.050960,'Cubicle Slate','none'),
(2263,'entry','RmMuJ29jGatdm3zLPiKRK5EfHCB1chfxun8cC1feWoJg',3,2,1,7,0.053280,'Ledger Green','none'),
(2264,'entry','mnoXjmFCG7qEyHxqKtWQ3TfxSfbMZV8cmKB2oR75ttLX',2,2,4,0,0.037200,'Breakroom Sage','none'),
(2265,'entry','PExWS5vgJeLSw3hVGk2zH8HRp3MP9XfPFbgSGkqgWipS',2,6,6,7,0.066030,'Manila','none'),
(2266,'entry','PSp44aXqppYhZpUtx27CkPXXXQWxr1anQUsJmhvRfsKT',7,3,3,2,0.024800,'Manila','none'),
(2267,'entry','cX1LveAQ7ZLYJUNoPFTCjm2RFMyCcNYwkw1HyeXKVUaf',0,3,3,5,0.040940,'Manila','none'),
(2268,'entry','7RHQE8YS6KDZxXyrWVWhazHfVXpsdnyrseg8EbtUTXwK',4,9,0,4,0.051830,'Toner Dust','none'),
(2269,'entry','bmqr6MBk1BFtcAkvTAAk4BXc5ucXBZgmMrSLAzrYzaqT',5,3,6,4,0.034960,'Drywall','none'),
(2270,'entry','uxJAwKJYr5mbxShwDZeKX3WxzkKqhHbM9jmXBnUQbydx',6,1,3,3,0.052780,'Toner Dust','none'),
(2271,'entry','SwKkUEJg4hTbHHfxnCErNfP1qWdrzonoePb4JpvaV1g3',5,2,3,8,0.041360,'Cubicle Slate','none'),
(2272,'entry','1FDmvuF6y23Xp96zTJJisev3cS23fBowgRcy6jMw9f3o',2,6,6,6,0.064380,'Breakroom Sage','none'),
(2273,'entry','5t3zx5jv1zQDik1PopgNG8FreC9VUrxFwT4BBZPEAVN9',3,5,3,4,0.085560,'Ledger Green','none'),
(2274,'entry','wSGktZCE6mcsp1S7F7BjNqQmdtmeYQy2mffkwTu8LJkT',1,0,1,4,0.056950,'Breakroom Sage','none'),
(2275,'entry','gaZZkJsrxZm8o7Q9N4LtDisq6EFtJ6vECR7Cq2aTWwuZ',3,0,3,6,0.033440,'Ledger Green','none'),
(2276,'entry','y47rHGnKRYWkNMNQmagtSw4q6KXpewuukAqV7St5Y4Tj',0,4,4,0,0.053550,'Ledger Green','none'),
(2277,'entry','Rz9K5geaBLJv2qeV3vTpAvmtcAkD3v4urZ8pbgqxg4zN',5,0,4,5,0.025200,'Filing Grey','none'),
(2278,'entry','oS1fwJ4Bi1zXAECm7mbvyxdHb9hvgt4M7eCcb726uABR',1,6,6,2,0.092000,'Breakroom Sage','none'),
(2279,'entry','d9akvQy87U8aqmoU6rcZiVb2Dye4NdWa39ngTHSHjdZs',1,3,5,4,0.039160,'Cubicle Slate','none'),
(2280,'entry','Jui7mRif14ttxbRrGocG6PRWXpCAMJzDjWNzQtr6SzGQ',3,2,7,9,0.040040,'Manila','none'),
(2281,'entry','HEFTv9kHSA9SsptfJ6p1c7h5gGYbWbjqpSjYQuS6t9B7',0,9,4,7,0.035200,'Manila','none'),
(2282,'entry','JV7q2oYSdBNjTCiZ5uvQT754VocXpyTgjEjSYgFCDXJN',3,0,3,9,0.047560,'Breakroom Sage','none'),
(2283,'entry','oBoZEwZwb6Dm4RRcgwYLqLgXvfRuQ7CPccmfGYe6h3Kq',0,1,2,7,0.037400,'Filing Grey','none'),
(2284,'entry','X5P719uC8uKDsgi5DT86XHzbdZLgrM62GRPQpp2T9awb',3,7,2,2,0.031680,'Toner Dust','none'),
(2285,'entry','RvnwhPXQyW93To6PgiUwBUA8oRm1wHp6e6hgjwHCwFqB',7,7,2,4,0.055500,'Breakroom Sage','none'),
(2286,'entry','eHv8UTBcgXs6nnEnHfoe2XgksHyPpn3UqZd9n1oFteRC',2,2,4,8,0.035880,'Toner Dust','none'),
(2287,'entry','XJs1xbFGRPUw9kRv5HJ6up61nPBwbsCa2dPmbDmYcu8r',2,6,2,2,0.019520,'Ledger Green','none'),
(2288,'entry','YtrM2uQU6G1L8Sa2w8tP2xwVTxg4XM8vSstTr2Q46PhL',3,5,5,0,0.063180,'Breakroom Sage','none'),
(2289,'entry','byzFzgJHy6iXYz9haCNzrJuXBU4sRzzgUnXS7H9UDvVR',7,5,6,3,0.029040,'Filing Grey','none'),
(2290,'entry','z5gbXoywfNwJDDbaz9eQSAsC5X2PT6cZv1KJ6pedR23Y',2,0,7,5,0.029040,'Manila','none'),
(2291,'entry','SPF4fhQe2skr6L5gQXgxVUiU5b2h15giDuJxJxGNBVCc',2,1,5,0,0.054020,'Manila','none'),
(2292,'entry','KqSAitY6vguxLiAnedH93t8hseVadwtcEBdYpaUs6BKp',1,5,2,3,0.038720,'Cubicle Slate','none'),
(2293,'entry','D7rAADtZX1Z9KMFe37NyZf9JfhwcRxwkL1P9TkKnPwHe',0,6,6,0,0.023360,'Ledger Green','none'),
(2294,'entry','46E411aTS5qtw7VY1LTNpYNvUZqkyBBB8zq5wrJFCCmS',4,6,0,4,0.031240,'Ledger Green','none'),
(2295,'entry','pY9AeCuWcbaZZ5zjyJpi9C2Go6huafwEZDD7SeXUsrwW',3,3,7,4,0.051660,'Manila','none'),
(2296,'entry','bsRiM7b9tw9TZ88yFZLBWBL5eb5U9GQjfoXgYFRgn5gU',3,9,7,5,0.048140,'Toner Dust','none'),
(2297,'entry','o5AfpUDVSoBpUGnHNMfRCGHjSDSxoTDhH6z3K1rFzWis',7,8,3,3,0.036800,'Manila','none'),
(2298,'entry','utrdb1dicKivTRoTwytmuEt7bMGBbaUKj8KqAtFZcDSh',6,1,7,7,0.067340,'Filing Grey','none'),
(2299,'entry','EabYP8ksi5j8ASeR1wjNJP9VrTHBqNr15i2DupX6NdK4',6,9,5,6,0.028480,'Filing Grey','none'),
(2300,'entry','JVnAtyqRD7MyPFMxTKRsmYRpkZ5AcavMHeMk7DvHZyif',6,2,4,9,0.054670,'Breakroom Sage','none'),
(2301,'entry','omL9duv1xa39XGWT3jpKSi5BFX3mFJyEyBnBPrEcfD8t',4,9,1,0,0.024960,'Ledger Green','none'),
(2302,'entry','EYQQ83XDisdNCTwFEbSxENPQeEciuyXz9Qx5t6XGv2ws',0,8,1,0,0.060300,'Filing Grey','none'),
(2303,'entry','t6dhtdH9iFaz686opW514EUrVGWk5s1NMBxGwcENTLeJ',2,9,0,4,0.061110,'Toner Dust','none'),
(2304,'entry','ZeQRrukPbUNc363tzHQYBihjwXDUg4vYcdQKaCLnoeUh',6,4,0,8,0.050960,'Drywall','none'),
(2305,'entry','3J64RxzhbHSWmZg4CxrEL3KMtXsQ4Wb1aemn8KkqNaNV',0,1,6,5,0.029920,'Filing Grey','none'),
(2306,'entry','TK8vgTffiYrKmgJo11v4bHmgpuDfnaRTugV48YnkQTru',0,9,2,0,0.042210,'Ledger Green','none'),
(2307,'entry','QTCZpPRSEnJsmBnmkvRBw5ExqZGNWTwzqUprzcLCHxFG',5,7,0,5,0.056950,'Manila','none'),
(2308,'entry','X5PjJZZsTdWDQdLfnaWRNQVTtDxQxtxcaPBtuEosxmp1',2,4,4,0,0.058220,'Manila','none'),
(2309,'entry','T6xRTu1ujjxXw8MJWATh2nJjkcCAwUbr5bpctfvVXkxR',2,9,3,5,0.059850,'Manila','none'),
(2310,'entry','LfoTed8J5aLcg88dxqWkZQkZsS7tRVrW1gzCJs2bwAK8',5,7,4,7,0.066420,'Manila','none'),
(2311,'entry','HcV5tMDiabZMUXPTizMACJEVEg58LzY5LiKFp1fcdKFn',1,4,2,0,0.067000,'Drywall','none'),
(2312,'entry','4MmNC66VjFXaVC29kqwYf8ozUfv41NExrGh8GJMaMYxB',0,4,4,6,0.028800,'Cubicle Slate','none'),
(2313,'entry','j8voUEymTYiSUuP4MWrGgdMYKLkmkZg9TVMLwyCKqpUQ',2,1,4,5,0.030080,'Cubicle Slate','none'),
(2314,'entry','XzRQVVYvjwxBDeL4wbPk8dZKVS7qq7CNZZGHhAckQuQa',3,8,1,0,0.054870,'Ledger Green','none'),
(2315,'entry','KetH6Kj1QZ8493PdHTYafJvvQiQW3jNgDgaA1RedQtgT',4,5,6,4,0.030800,'Toner Dust','none'),
(2316,'entry','sh75GdiihzSMSoQtYYMVWmHExoj9PpkTidBjADHvCnKT',5,0,0,0,0.032240,'Manila','none'),
(2317,'entry','Ea7WCTniXoeXqSgYtnRnQwwAU59YykYpkthBijn3WDuV',6,4,1,3,0.035420,'Toner Dust','none'),
(2318,'entry','i7iBECFWnMvSWr4a1avXnhvGnhozk38m1KG7ApnTHSB8',1,2,2,0,0.045820,'Cubicle Slate','none'),
(2319,'entry','DCkYmf5TUmfr6qeQRrZgGdwydGdhrxfEFa6JNHt3FEcF',7,6,4,7,0.037120,'Cubicle Slate','none'),
(2320,'entry','QEtp494UvEXqXb8KnLRS65znBuVtmTYgbY2ZaWgRYh5A',4,6,0,2,0.094470,'Breakroom Sage','none'),
(2321,'entry','Pro61ARaFvdJpoBjyPzMxJALHgDqipTNuwuhszBfWr6r',0,6,5,2,0.032000,'Manila','none'),
(2322,'entry','qfxmkDFA47xcCFEFp5G5TnyZgHmBG7HGQSgaAWRnRLmU',1,7,6,6,0.037170,'Ledger Green','none'),
(2323,'entry','t11pHyFW4ZxxcsDz3b5fZYykhH3eQox9eP7sonuK8di6',6,0,1,2,0.041360,'Ledger Green','none'),
(2324,'entry','ugbZqJwzwYCSqxHeTPsPoUXXip6NbTYm87hTJB2oHtC9',4,5,1,5,0.028800,'Manila','none'),
(2325,'entry','mnFi5kh5yxtPLYeSbvU3AXGnJe6p1Arq2kE7ajz729BB',4,0,5,9,0.043310,'Toner Dust','none'),
(2326,'entry','6X7rKkHw7Z6VF1zVWjCWVrcLqKu7ZPQ33kEaaquzohZV',4,5,3,8,0.049560,'Filing Grey','none'),
(2327,'entry','uPTSfQ6UmjFVAM2w19qTJw6DoUExeJ5ZCxjaSSEUYjMJ',0,1,3,0,0.068080,'Cubicle Slate','none'),
(2328,'entry','HGP2VYCt7p917CCU4k7xe9FwTxBb5q531Bi5jMqLMJPX',2,3,2,0,0.059940,'Manila','none'),
(2329,'entry','PefK5X3HZUGdATRCmD5crLuBfu45CJmtcDnaeXUsfixj',0,3,1,5,0.066420,'Manila','none'),
(2330,'entry','7ngBhS92emjbBXwsBcjHfvvq5caJYcyefcra3AKTSgGw',1,4,6,0,0.056240,'Manila','none'),
(2331,'entry','CmJg7TxJU8nD7WnjoufqhAzza7XpTcuQajC5Fi1P9az7',0,1,0,6,0.028980,'Drywall','none'),
(2332,'entry','pwxCdmnM6SGJ5hwpJUZek2Dtzh5KzXpVgYkyohwHF2UE',5,7,7,2,0.041890,'Toner Dust','none'),
(2333,'entry','8Xx9KF65tLKJ1YMpXEzeBECjDmvuwNt4i2kn7rxSTCvR',2,8,3,2,0.076140,'Breakroom Sage','none'),
(2334,'entry','fLhTrQ7JRSWvd6cjXYNdvurUEhjdAN8frPbji2dmCT8V',0,9,6,7,0.062900,'Cubicle Slate','none'),
(2335,'entry','VG8bsUPYuJ6Eytvo2NXhwoGxP4y8TW3Rj4ftDU1bqVCu',4,3,0,0,0.037840,'Filing Grey','none'),
(2336,'entry','6UWRminEot5gPHuZqWSzbX5PRqwmMsXn8kdiucrgi13T',6,3,7,2,0.069660,'Manila','none'),
(2337,'entry','41C3TXpey9fxzhArFRCmme47sD8eZ4QSGcEasNbKVBPv',2,9,1,0,0.034000,'Drywall','none'),
(2338,'entry','5fVbFqS6DqZAreTnU2mR7SbokVeiqUxzr2Ea3oUsZHnm',2,8,0,0,0.046620,'Ledger Green','none'),
(2339,'entry','3FSe4YzdEEimiYyS7QdHCzgzWPkMaNvvxQkhHvS4t9L4',7,0,1,8,0.037760,'Drywall','none'),
(2340,'entry','b1NsxL1BanPc4gbafCgHrJLXrTB54jgqc823D3rsmdcF',3,2,3,5,0.042240,'Manila','none'),
(2341,'entry','WohJCc5nNfr7tvjNni5nPuMx1f5xfq4CjKZN7wTUByVM',0,6,7,4,0.045120,'Filing Grey','none'),
(2342,'entry','W66fd3XdVmznHZjjykTsshVTGYbhG5DqJ1GqoWNAdUfc',7,1,1,9,0.061560,'Cubicle Slate','none'),
(2343,'entry','Ap6awFdsAwECYKvtbRD3Tg1xTPu3kSBBGPEJYnq3sCu6',7,3,2,7,0.047040,'Cubicle Slate','none'),
(2344,'entry','VWJqkuHa6RwoKgDswtSBN315sXq35mVMgJRnm8Wn1Hf4',3,9,6,0,0.051800,'Manila','none'),
(2345,'entry','VWMDQiMLLJLe6rpMXBv7b3pdYjfMgxL9ZjhLfaxvzoiD',5,2,7,0,0.029900,'Ledger Green','none'),
(2346,'entry','NNB1mHgQBoxyPQpR317MUq1gNF6jyW6Cc1bFj2mEgZr1',7,1,2,6,0.033600,'Filing Grey','none'),
(2347,'entry','oynNmPrUe8G8jE9AjrN6kdETnp5n2a8Pjo9xwykgdYfK',1,0,2,6,0.046080,'Toner Dust','none'),
(2348,'entry','XWGEsNjk6zMANDAmPcBmLhaouEepLKNffivK7ZHjJDQs',1,9,4,7,0.051800,'Ledger Green','none'),
(2349,'entry','NJrBMWWBZyn3FjVNvhAzoEFaQvpaiEhtNmuyhm56Fuy4',7,6,2,9,0.062160,'Manila','none'),
(2350,'entry','5L4T68Lq7y1ajENrGMDWgbEE5Wdb8KVk4oQaoZTev7r2',4,8,6,9,0.026400,'Drywall','none'),
(2351,'entry','xBshA5iUF1YjeQM6faLEk3MK2J5CL3sgGy9397SyJfV2',0,1,3,9,0.043070,'Manila','none'),
(2352,'entry','DVbFkGnrV59LGQ9UMjvnQqTo5RupPXsCPSB1Ce2XnHyu',3,2,6,8,0.028800,'Breakroom Sage','none'),
(2353,'entry','A6t7dtiZxSbFPsY1LbmQ4dR8nRBEe5rsAGnUmgdRfJyb',1,7,7,4,0.083160,'Toner Dust','none'),
(2354,'entry','nKHUZ5oXbsZPSohSWtkHjTYWDQDbDZR4CXe7dTrVPyvo',5,9,1,4,0.038400,'Filing Grey','none'),
(2355,'entry','CJdb7zbhtKujWRfXEYofg1pkhHKV4eTWL49otR7TASrA',1,3,2,0,0.041360,'Cubicle Slate','none'),
(2356,'entry','TkskW5M6L3dzXhcgDQNXDZ9GUfAUsZGBxcNvcnZ45hpf',6,2,0,2,0.038280,'Breakroom Sage','none'),
(2357,'entry','wahA6KBqKVWx7MkvJtbpfKYfqan5mEeAX4bRnKbHfn2H',7,0,7,7,0.030800,'Manila','none'),
(2358,'entry','xcvF3bcgRQuCEHEbTR6oSmQqoRWJcNhDt9vcnjJphyww',4,2,0,5,0.040320,'Toner Dust','none'),
(2359,'entry','pU3JRAaAT1h5ezdKXVhNEMFN26VyzVMEN4BLXU6qBXNi',6,3,0,9,0.059630,'Ledger Green','none'),
(2360,'entry','EFpyHwntP8kch3XDxBVRSav2X6F7ngkDLEbeG1GwX2jG',4,5,6,8,0.046620,'Filing Grey','none'),
(2361,'entry','ddjs2RAYeTBmSEy71mCrQ2ns78pbDwDNd2NeTU5xcWLq',6,1,3,3,0.030360,'Toner Dust','none'),
(2362,'entry','jJEmaGXurLWXkvbQLLaDG5rJG2U2HsxRepPGwmvGU5Wt',7,4,0,9,0.034400,'Toner Dust','none'),
(2363,'entry','dSc9yfCF2LtwaMMYKQf5dr65A4aJANzVsu2cn6Z39CMU',2,1,2,6,0.052510,'Filing Grey','none'),
(2364,'entry','v2baCsPj4p46RnME5o1hXDMEywovwSbY8q4vVpfBXQaA',6,0,0,2,0.057960,'Drywall','none'),
(2365,'entry','a1bZnbfo6C4qxrZGxmLeJq416tEax96WWuqmc4wzXDD2',4,2,3,0,0.041180,'Filing Grey','none'),
(2366,'entry','FbM3uJnxaDC2u3DEVv94waScQKFX2Z5zebbAuTnExfic',3,5,7,0,0.032160,'Ledger Green','none'),
(2367,'entry','Dgjjk9ykaPjtz67e9XFzdx2MVnNbw8ZCi8mYqWXSZ6ti',2,2,7,2,0.029900,'Manila','none'),
(2368,'entry','Tf2HDso2e6gkwBfGxoUCptYAFqknX65yqhAwZx7Yo6c4',7,6,5,4,0.026560,'Filing Grey','none'),
(2369,'entry','pBcPocs6HDmbhSfoEijvpffcF5CFbZDKTLJEMDvEgJ92',5,8,6,9,0.068870,'Toner Dust','none'),
(2370,'entry','mQNp6dcX2z28Hzchb7MNKsvVjumYcqc4tkJgACLsLzcV',0,1,2,8,0.041180,'Breakroom Sage','none'),
(2371,'entry','TRxdYSdEcCk88b6uJTHfxYF9HxHsjveXgxZSVF9Jzgzz',3,7,0,5,0.024320,'Manila','none'),
(2372,'entry','o6ZpFsiVyb3oM63ZB43anrhLmtgD9FYky4vAEurWgwZA',4,8,3,9,0.036800,'Cubicle Slate','none'),
(2373,'entry','pynAbrH2dNreouMV9XxYwXmZU8hUzU34zGWJATVQoupz',0,4,1,3,0.029200,'Drywall','none'),
(2374,'entry','CuYaA1bmu48d4FSgq9ikujV9X5yvnWi6yuSDLC8ndp1E',7,3,4,5,0.041860,'Drywall','none'),
(2375,'entry','ziXYH3u9ooTuy8WuXk7busCdV3ykz86okZ7w7BD7Vz13',4,4,1,8,0.058290,'Ledger Green','none'),
(2376,'entry','6g1C2wMnRB7vRKBx8zMaJCwtjpZnwR67iKfXS5XmyYGG',3,8,7,8,0.062160,'Ledger Green','none'),
(2377,'entry','FLjRmPnBcWbkN5G4SEbTFbkcspTd3Ehob95PRz4KEpDg',5,6,3,6,0.037440,'Manila','none'),
(2378,'entry','AnDRyovSjkwk6ZbSueWme8EdxG4dZRcFQwzNpcdZbCKd',7,8,2,6,0.062980,'Filing Grey','none'),
(2379,'entry','Mr3tN8NQz33ne2DaX5kZ3pNeXYLy82iTwDMBXEh3nAa5',1,6,0,3,0.049580,'Ledger Green','none'),
(2380,'entry','4pYKzeumdmfxXd3HVMXSEW5MdkKUrbZVv3591s9erB1u',4,7,5,0,0.076950,'Toner Dust','none'),
(2381,'entry','YrfSm7XWXiDsko56Rt53tF7eZBZdtbaREQ88oxPFihbk',7,8,0,7,0.043070,'Drywall','none'),
(2382,'entry','NrGm21zYNTgZPrik4axLkeRcsP6ywuVwNyCptzmd5U5Q',0,2,6,0,0.037400,'Filing Grey','none'),
(2383,'entry','H4j63UDmhqmQjZbN154DawpmhV65dUTwJ6kySfjaKLqq',0,7,4,0,0.033580,'Filing Grey','none'),
(2384,'entry','pMUEAq42mJkHe4wKkTvJMXEo23CgGJWoB9j8gqYCaicF',1,3,1,0,0.034080,'Filing Grey','none'),
(2385,'entry','Y5KVduTzcnLkTmVSpF1kacCXhMxGgV3s6Xsk4XqukwvJ',6,5,3,7,0.020800,'Toner Dust','none'),
(2386,'entry','u9SU5Db3gVfyGftMgEc7jX28YtqFmmv4f4J4LhW5LBgS',6,0,3,2,0.028160,'Cubicle Slate','none'),
(2387,'entry','jsyorQh973QNzNmW3DiUtV8GcyzeBoz8DQB4SsjinsXk',7,3,6,9,0.044640,'Cubicle Slate','none'),
(2388,'entry','futyBKogCSrDWSq3jRFiDXEybgGQLjKR4P4PT6v7ZyoY',6,4,3,3,0.030720,'Manila','none'),
(2389,'entry','7YgwbR2uzJDv84quhKgmX4rB6Bb9vgsUA4VFsCD5uNBK',1,2,4,9,0.053280,'Toner Dust','none'),
(2390,'entry','4wVQDD7tVfqZTJnS3hyN5xhzbtzhGNFPpKFTa3H3yxYR',2,0,6,7,0.045760,'Filing Grey','none'),
(2391,'entry','3bjDBRzmEgktpHEhZ3bDNYunEyHcoFvKHQ3kxv7mX7g1',2,9,3,3,0.048910,'Filing Grey','none'),
(2392,'entry','4EHdAERXHK3HVtygoFP7uRS4rwe7vRS4cuu81Hmzanr2',0,9,4,6,0.042920,'Manila','none'),
(2393,'entry','KtooFXZZCDCdikMXU7z3Zp5QqTG9EP12wLJDEYGoRZd6',2,8,4,9,0.032120,'Breakroom Sage','none'),
(2394,'entry','J3TuDHMuqzheUt9LWSqg4voNHGdKydydpxFK7GAamz4D',7,1,4,0,0.102060,'Drywall','none'),
(2395,'entry','X9tYsjRB7bWrtNysD2ARopmNgu1wePH3Ewor6mPprntg',7,7,3,8,0.075440,'Manila','none'),
(2396,'entry','2eH4qknQp93c6u6hKxZ7RQj8PbohiFk6EiNGXTpHMWka',3,4,3,4,0.103320,'Ledger Green','none'),
(2397,'entry','uNb77zyEKRovnK3AdcYZUL7n9oV8P76rARjaJPsgEmuY',6,8,0,0,0.042920,'Cubicle Slate','none'),
(2398,'entry','odPjBKbdqP2jjvNBgqk8qbj4snXRk1j6ir63XLbzroKu',6,3,4,3,0.032160,'Breakroom Sage','none'),
(2399,'entry','qiTUsbTtrtqZXCMBxkBUMw8rvB9qHLBdH5yUaoynCYH9',4,7,2,9,0.037760,'Breakroom Sage','none'),
(2400,'entry','RhWn7qz1o7U4gA96DTC7DQakVYNMWHAwUGkWGN7rGyuT',7,4,0,3,0.035420,'Breakroom Sage','none'),
(2401,'entry','7zpE9Tgv3siJMmRtV1MuZDJKVMAGBWfLA8rLLTxZpXn2',7,8,4,5,0.036800,'Toner Dust','none'),
(2402,'entry','CkyBx1YHvVHbwpJ3tk9XZFfb6Vhs2S5bP96GMfB7KHRy',6,7,7,0,0.044160,'Filing Grey','none'),
(2403,'entry','bHRtPXDPPpjf4K5K37uSGs1vbjPUgjwhHdxrwXCUcpYD',4,2,2,6,0.028600,'Toner Dust','none'),
(2404,'entry','ntxnRTuZpF3QpKYKaysYRaRFNqAzudEkzTLvgY3VQKAL',7,7,2,9,0.044020,'Drywall','none'),
(2405,'entry','5BWjr7TQofSEK8HAaziNxYRJZ3wQrLQwgbDUnUjnJhWk',6,6,1,4,0.041800,'Manila','none'),
(2406,'entry','BY4usVLJRPTBgtV1zEwCkuFBkeKGqEu2bGJRYqKVDYUx',5,8,3,0,0.049560,'Manila','none'),
(2407,'entry','chncRRPGVs2cCTrQAM5g4zTLELjc5pyadJ3F5ucZatvR',5,8,3,5,0.031680,'Manila','none'),
(2408,'entry','kWY3svkc6YGejNLbpAzUtgxn5DV9v3zWHBdfDnNbWCfj',3,0,0,9,0.031680,'Cubicle Slate','none'),
(2409,'entry','RJrkZmHYLbuLsLuhffLj5GrxpGWWu8FtJi3UCmkzqMSz',7,4,0,3,0.037800,'Filing Grey','none'),
(2410,'entry','rxdBiLZbjgrGioemBap7KpoSS6Qzq9vZbSCtrWLnVvJT',6,3,4,5,0.028060,'Breakroom Sage','none'),
(2411,'entry','DZDeeSJcsiKA4ETp9NCLR9dA7BHfrSCTnziNSBWS7ngn',2,6,6,9,0.030800,'Drywall','none'),
(2412,'entry','TsZXra9Rw7XNYrkvbRvqgZXJHAHVHgiDBFVevQDvft95',5,7,7,2,0.034320,'Ledger Green','none'),
(2413,'entry','NGq5PdTNCSP3QDkeumJN91BZpr1uVaTHQvBjgc9q7vBu',7,5,0,3,0.029440,'Ledger Green','none'),
(2414,'entry','rUmCwyWxxi7k48Wi5HX1cWo3ndryvQyKucnYcdLSYwgY',6,5,6,7,0.081900,'Cubicle Slate','none'),
(2415,'entry','rmofj1JGRNykD9sRu8K3FGAMU6DX1VBL3stG1JDJK84x',6,8,5,7,0.048840,'Ledger Green','none'),
(2416,'entry','BXfNRaj9ESeJkFJWu4TUnzDuWwijcQHVvgMs5vqrbB28',4,1,4,4,0.055500,'Filing Grey','none'),
(2417,'entry','gcuAkefwPEuPryrhuW8F9vAKrFjaL6DzjQNBcuGTDDN2',3,7,5,7,0.080640,'Breakroom Sage','none'),
(2418,'entry','bRyxUeyLqVTgwmzzdAxdgJrBqKnZbjdMeMwzYFNHcNyD',6,4,3,9,0.056120,'Cubicle Slate','none'),
(2419,'entry','YkMyXeaZ7TaGdJpogp4Kh1VrYCMT53hYXgdDzaCvPCdv',3,9,5,3,0.042120,'Breakroom Sage','none'),
(2420,'entry','MNc9MEspUPkfyNGASTPzi6PCVLG9GQUkzKMsyVbpyog9',6,6,5,7,0.026560,'Filing Grey','none'),
(2421,'entry','hPyeog9fYCn6t2haQe31Lyussxu5LrmH8f4CB8GDDYu3',3,7,7,7,0.035200,'Toner Dust','none'),
(2422,'entry','QG8QUNZ5jpjhT9vRfxuMNoMUTRLZSCjjnCigmqRqZY8w',5,4,6,0,0.031680,'Filing Grey','none'),
(2423,'entry','ZNfGJ1NS78emREpVUe9YXbZa7sZDPvLRqcytuzdrVLp3',3,1,1,0,0.046230,'Manila','none'),
(2424,'entry','5NVrM4TG9WmrXkrAMNfaKbBMMG14mntrVPj8rSMRJg2M',6,0,4,7,0.028980,'Ledger Green','none'),
(2425,'entry','dY1rsK8DXSSoci3bVCzeU6ieNy2ULk9Mbp3R98sapj89',6,2,5,2,0.075440,'Drywall','none'),
(2426,'entry','vK6igxbhU9PFomSx6qLasgSFfPi78PrNtgRy9NhfunyP',1,4,0,0,0.026400,'Manila','none'),
(2427,'entry','qc2JNKDMcpJFCSN5DLNS5J8gtDG4mAqjwXFERr7nj9cF',2,6,1,0,0.046980,'Toner Dust','none'),
(2428,'entry','3dUVJHuzGQ9ASMKARQEcHxJ38zDXqMFFFQSgfc5djU7W',4,5,3,7,0.037720,'Manila','none'),
(2429,'entry','fA9aQ5vFcThnraMsKJPLgFNALvNV67b4StSWaJaokPvs',1,7,1,4,0.057720,'Filing Grey','none'),
(2430,'entry','4PfUoA33mQTSKpTAoTXxF3d56TcD2tw5d87re5dgMEgp',6,1,4,6,0.043200,'Toner Dust','none'),
(2431,'entry','ez3YHdZrZQpwtPRmnrbVJxsBgXNto8ESDJfAuUUKreG8',4,4,7,0,0.033200,'Toner Dust','none'),
(2432,'entry','kCf4LYxaKVsAwia1bYiRhgTnUfVw2A7FVhiV7sPegNMS',6,7,2,5,0.040200,'Cubicle Slate','none'),
(2433,'entry','pPUKbGoRbybVHMPvMTYF4H4sMoeEZnJqY6imoupxU1y7',1,4,4,2,0.029120,'Cubicle Slate','none'),
(2434,'entry','QXRD7bWhKmC5EaunRjKLAwTSH8ST3koCGxzuBiVBNgr1',0,0,3,3,0.057510,'Toner Dust','none'),
(2435,'entry','mePqmypAKHpV9s1FaXwMdxQmvGSu35uNrfkyLqiTiDyG',4,3,1,0,0.037440,'Breakroom Sage','none'),
(2436,'entry','wyaqo8UbhG69q3wcHG3YHurcebyFG6n94qwUwnY7EAQA',6,2,6,7,0.039060,'Breakroom Sage','none'),
(2437,'entry','cMcZp8dfn9pBqJZZQhMqedUyRhwn8QALByNXt1ripUSq',5,0,7,7,0.038350,'Drywall','none'),
(2438,'entry','zyjA1F5SBkqME57hDmqUyV6spt1t4YvQ9LMomR1iRwBz',5,3,2,5,0.029040,'Drywall','none'),
(2439,'entry','EEQxLqQ4hcBiCXs87xERMvR6m4wjcSCXbT4qis9nexna',3,0,6,0,0.054760,'Filing Grey','none'),
(2440,'entry','eGMZ3vyTYnCrHXizo7iwDyU6XMLG2mor1hrThaVcfhCi',5,5,5,8,0.052920,'Toner Dust','none'),
(2441,'entry','eFjaZPENZtiCjxkowAMGC3oTLu3RnU2rp2boJR5i4nDy',5,2,7,5,0.042840,'Filing Grey','none'),
(2442,'entry','nLtDEmGKgBVWTTbFjeWpKykZsBDBQ1gNxxB6NpiHqmew',4,0,2,2,0.037260,'Drywall','none'),
(2443,'entry','w8BkNGyxC5m9zKLCLmZvuKTcZZAMsDAGxKUCZvA1mDqy',0,5,5,0,0.021760,'Ledger Green','none'),
(2444,'entry','S9MH2gvdbky2pQLR2eWdXE32inpC5ttvomALNG5KTcpE',2,9,7,7,0.033600,'Manila','none'),
(2445,'entry','v8qDciZARtmzJpYHuzgZ1734kkgW7vxCmuckdR1toT36',7,5,2,3,0.039530,'Drywall','none'),
(2446,'entry','axNZ9sHWuAqWPsGiJUguShJJ5MiH6U3Fd4xCbzVJB5VK',0,6,6,8,0.028480,'Breakroom Sage','none'),
(2447,'entry','78Bi8g6pgrW37diMQ89MvMtXTAsfEPEaQvojW794Q41f',5,9,5,0,0.027840,'Toner Dust','none'),
(2448,'entry','EmH5pg1FNSaueJk9fMExhWVvxR6kAj2BxSb6TiZBrSiw',1,6,2,4,0.037600,'Manila','none'),
(2449,'entry','6ng5smEMwzDPgbV61tTVPHXpdgE9vDyEwqeduC55hzN9',5,3,4,0,0.043070,'Cubicle Slate','none'),
(2450,'entry','cfhF33w1jZTR7LFRT8L1tkmvxfa8HMo5YcZPXcyQSefn',0,8,5,3,0.042320,'Ledger Green','none'),
(2451,'entry','gfJe2nNXve2KU6ARngEjgVLoJWcmQ9jhn54QVx6DrKKq',7,5,5,3,0.034080,'Toner Dust','none'),
(2452,'entry','PztiKvD2B1cg1mrnyyHHEkjU3Dt3bYGz68C7b6m2KQQj',4,0,0,3,0.051330,'Toner Dust','none'),
(2453,'entry','DngBXcsaQoTkdcLcB8gwdsHAi4JKU96UA95D7z62M4Fp',7,8,3,2,0.035880,'Manila','none'),
(2454,'entry','U7BLA8Z1X4ivVwivEygvZoKdY1jj8gbZpyPmpPAgtdpB',2,3,0,6,0.049920,'Manila','none'),
(2455,'entry','i7JeDS5E4gSaz6ngWne3jEb6QsH1bGhUAC31TcxGK6QU',5,6,1,0,0.071000,'Cubicle Slate','none'),
(2456,'entry','kdGhAf1xc62bip4pMxQeZZhKo9jxDdnVfoZaX4BhJBuP',5,1,7,8,0.052260,'Breakroom Sage','none'),
(2457,'entry','TXjbpYYnkswDmgXbPMFU3rfQjiwSEmXKZ2iP9ztcPH7p',6,1,6,5,0.042600,'Cubicle Slate','none'),
(2458,'entry','tmEN5Akr3U5bRg1hRUCPZg7pkbXLRLMwoKYkN7jnp5iB',3,9,3,2,0.043700,'Manila','none'),
(2459,'entry','tXebeSMwgX7d9zE2sve6Rk3MhdgvBP5WQ98A2d7Mt9VN',7,5,6,0,0.036960,'Toner Dust','none'),
(2460,'entry','AnM4yR31VQGXCzWTTwPtDm147Mi9iPQXgjAQyKm3gwBF',0,0,1,9,0.039160,'Toner Dust','none'),
(2461,'entry','VZyAYPSFwqiaCQNeWMXNwCnNGZ5f8dUqVTKdpq8TDBou',2,8,2,3,0.056280,'Filing Grey','none'),
(2462,'entry','6JoTtLng7TVe93TwdrA7RfiJ3695fQCH5PKipF37nYLX',2,0,0,0,0.033200,'Ledger Green','none'),
(2463,'entry','uKJjb3HhNG9iAUicAB5DBjgmkAynJd64R65Q8QqLtEnW',6,9,6,4,0.033600,'Breakroom Sage','none'),
(2464,'entry','y3jBZ7jPqkXjFEFPAu3bSCSUmjXpbJpe6deUfu8PY8bU',3,2,1,4,0.044200,'Drywall','none'),
(2465,'entry','RGFqgx39e9ua5xqrDpRrQPMJ6WaAg3dctY8JHpprCKPT',2,4,4,4,0.032640,'Filing Grey','none'),
(2466,'entry','PwVK1T2ofnMECVqwhgdvRW4G1s8rhRrx52hxeGZtgF7E',2,0,6,4,0.057820,'Drywall','none'),
(2467,'entry','pv71yT1fQ1bze9yATEMNsG6SGsqP8qxweYhn9Wcr1XUB',6,3,5,3,0.120960,'Cubicle Slate','none'),
(2468,'entry','XQVdQP75wr9E3E2VPeD51v9n7uCeLBDPZkJfTNVx8HYg',2,7,3,4,0.040600,'Drywall','none'),
(2469,'entry','39zSCc1vDFbqb4EuVd5nT16PL99mZYojKT9xWipejdNM',6,8,0,3,0.043550,'Breakroom Sage','none'),
(2470,'entry','BA5voRyP6wi7cEi4X8CU2Se93qrvwCLmMU8qzx6CbJ3x',5,9,3,7,0.047570,'Ledger Green','none'),
(2471,'entry','yWEgBZS4nGVEJkSjP2k9ozuh9KgC71fa1hjDoCxtqt7V',5,9,6,9,0.074000,'Filing Grey','none'),
(2472,'entry','BiciwP4M3J3VLkXJuvnz8hvjv9XuPvXqo9KB7H23m2tY',7,4,7,5,0.047040,'Breakroom Sage','none'),
(2473,'entry','LGWthsJun1bcDSYGZ4NLRxJ6SVRWLfSs5nYweCnDGZWQ',1,5,6,0,0.036540,'Toner Dust','none'),
(2474,'entry','kNj9tWBgLUyDu5MMbXCEx1s9Jnvi92FsJ4pyJCkDXcjE',5,1,6,0,0.025600,'Breakroom Sage','none'),
(2475,'entry','qsKE1zWdb7MZBU8gKQeFd6eG8nEVDD5amm31z5dzvQVo',2,4,4,6,0.029900,'Toner Dust','none'),
(2476,'entry','gi8xV6vPjXZ74kqqUPPmJ66qni7FuJ1VUNWpqm6xTTgR',1,5,2,3,0.038940,'Toner Dust','none'),
(2477,'entry','y2P5XK8YEAr5vsXTkcmP2QERDKjr54uJadijckDeg4by',3,2,6,4,0.059850,'Breakroom Sage','none'),
(2478,'entry','NYYpuud79URX9S3hJsg5eGNrGuNFQPik9pc48J98UMuB',3,5,1,5,0.045990,'Manila','none'),
(2479,'entry','R9vHfZUTtkkEsMc5FYzcdN9CtwVcAYNXJPQCShMz7UaM',6,6,1,2,0.041280,'Drywall','none'),
(2480,'entry','szcjPhXJ3Ldnk5LDMs8gjQwQkft6dfyxrEANFYnvTKp4',7,9,6,9,0.037600,'Breakroom Sage','none'),
(2481,'entry','vBECv9ZdXmV3GT7jemoxR7s6xdahSWYRvjK32NRdtDkb',3,7,3,9,0.029480,'Drywall','none'),
(2482,'entry','gwEu77ytrGTyum8GEYqY3jGe4BeCH9kAu7uep7yCQDQZ',7,5,3,0,0.086010,'Breakroom Sage','none'),
(2483,'entry','qRCrxEy3YbWkcGSrEqD6T2BNdoxddVp9cXHHsM4YLokV',4,6,2,8,0.037600,'Ledger Green','none'),
(2484,'entry','5XusLtGkqwnaQJtAKA64urPFT7ycoDsTVJmZt6HP4GdE',2,5,6,3,0.037920,'Toner Dust','none'),
(2485,'entry','WSyT4DxxzY7YNgU9yo5imHGaj7p7pPbRwCpdtdx82jG7',1,0,1,3,0.058960,'Breakroom Sage','none'),
(2486,'entry','8dDeHscfLTwPX97qHf5fh3QQrVpiFMCs6Qih8SZFnGZ1',2,8,3,0,0.055460,'Manila','none'),
(2487,'entry','CjueCFjCgBStpWfps9wzcP2AchoBu38cdhYSeTc3bBjY',2,5,4,2,0.044720,'Breakroom Sage','none'),
(2488,'entry','NKs6eVyG4RwEgcVkKHaRr16hpYioMnz39WXyUJqK2dbb',2,0,0,7,0.042720,'Toner Dust','none'),
(2489,'entry','mm15zuVCZbXvy7VVvehHrLg23QwHvYsbNQ7WeFi1JSzx',6,1,2,8,0.052540,'Manila','none'),
(2490,'entry','2DdMXU7Yc8wyZoskt83SpzKaPENCwEM5U6gH2h8VvG6B',6,7,4,2,0.046080,'Breakroom Sage','none'),
(2491,'entry','tHhooDwH3KVDX1Q3GX3J2SGYQ5VEYALyeEKsrNPBrHRU',1,5,7,5,0.068080,'Drywall','none'),
(2492,'entry','ooNtZgzrwMw96MgqzN8woWTNE1jo1M5F7pUqNWaFHqUW',6,6,2,5,0.039100,'Manila','none'),
(2493,'entry','Y78SvauvFyBCjMPw8r9NfBDK3VoZWMFFkwfYCfnbwzMu',3,9,0,0,0.035400,'Breakroom Sage','none'),
(2494,'entry','qeKEdeGV18gEFCRurxQtW4rHftBQ3HL2vptsVcMUZ7MM',4,2,4,4,0.046860,'Ledger Green','none'),
(2495,'entry','9WVtXTr9xv1d4Cv4upaPdkaZCg7At1NErc4RFGpgfLyi',2,5,3,9,0.033600,'Drywall','none'),
(2496,'entry','6HKBSY9zEBCyKzSY8qkr796cEhbpPy5TMPBkSuXLjQci',6,7,0,8,0.050460,'Filing Grey','none'),
(2497,'entry','VUXchwMPFScy6X4HLLPH3JTedEAKJjrMqEj83ioVpQdy',6,1,4,0,0.048140,'Toner Dust','none'),
(2498,'entry','uNmcGmB4t7U2HUY5rSsTafEa2s1Wqjsg4KGebYGwtLW3',2,5,7,6,0.055460,'Filing Grey','none'),
(2499,'entry','BNnoFd2Zza9mME9wQ2vjT1Zcbq7fJE7SUFkwpHx3NbLW',2,5,7,4,0.032560,'Manila','none'),
(2500,'entry','6LBfkLdhttvceMsA8ec3WZ8b2iQaxPxggaMZK3pNtR5q',4,1,7,4,0.068160,'Manila','none'),
(2501,'entry','1jERCCZBkjVQ9SjYH52FcuLxTvMyAsfbsSomkcgX5X9a',7,0,6,7,0.090720,'Ledger Green','none'),
(2502,'entry','9RULBcMkjRhvDXdZ56KM51Wd9Kj5aGauVHAYGcQ4qMDx',2,8,6,5,0.039060,'Drywall','none'),
(2503,'entry','mpnN7a4nY734a2YyGfBJRSuFGaR8Kdwcnq377bCydfvN',2,8,1,0,0.047200,'Cubicle Slate','none'),
(2504,'entry','x8febLoQ6xcFdtruEoAEASvfG4vj738ncBnR4HWhxCLQ',7,5,1,5,0.043700,'Manila','none'),
(2505,'entry','bk3r3zutYQYJngYTE16XW8cciRwVpiJKDnDGJhQLYSVJ',0,5,5,5,0.030800,'Manila','none'),
(2506,'entry','RbP2RXrhdRbYqN9NgNbD7Xrt1pdTec1Ktnb2SQwbQ9JC',4,2,6,0,0.073710,'Filing Grey','none'),
(2507,'entry','yncytiroW8JSx5LbVbxyDpoH6AUKGryG42h6jimvfWhs',5,3,0,0,0.071760,'Ledger Green','none'),
(2508,'entry','s9jc7E94qKCYDj8NR9gXLNiQVvcTvUbfGzj6D1umybNT',5,1,3,2,0.055500,'Drywall','none'),
(2509,'entry','XvjWTnvdrbGgWapKVjxef2uPLvTaGsE3nJrPKy5pc62z',7,5,7,4,0.024320,'Ledger Green','none'),
(2510,'entry','Djkgv6hh4rgnaSnJgamFKjegKNGKwPomK2Gk6LdvbDMN',1,1,3,2,0.049560,'Filing Grey','none'),
(2511,'entry','w4irk8n5ky9BSfntX5xDpWCumy6YHwMxmQ6cbMDqPNRR',5,9,7,5,0.041280,'Cubicle Slate','none'),
(2512,'entry','9gNok6Re5roDugnw9wN4XVpVkVzkfETnmT3SV1U2WeDF',5,8,6,0,0.076360,'Manila','none'),
(2513,'entry','J9EtwHKdQMr6WSiDYz4k4nyyYhUPSFeATLZozTVuN8Zy',7,5,6,2,0.026400,'Ledger Green','none'),
(2514,'entry','VGzHKGNveF5FK5rPAJoY3DuThoYDkWk1u9dX93gf5WEZ',0,3,5,4,0.069560,'Ledger Green','none'),
(2515,'entry','FYs81BXosa69N9An2C1V8X3xeM9yDweNkgmKgQQwDJ7U',3,4,1,5,0.039840,'Breakroom Sage','none'),
(2516,'entry','pqb3jj5ab23TNy9uX6Z4GnziP3pCF5HivkebgHa861GQ',3,3,3,4,0.056980,'Toner Dust','none'),
(2517,'entry','LAgfuc9VSconwVxB82qKD26Gg6Zq19bAMedvvXLEqpUq',7,5,5,3,0.032160,'Toner Dust','none'),
(2518,'entry','wMm89Xei7y7CFUM6Bv39o918vy5wsYRymuFUBKVpEbz1',3,1,2,5,0.056120,'Ledger Green','none'),
(2519,'entry','yoEuGChyAoYgfbsw3pX1eVwSCJvfRhD3d57LD4ayUFkk',0,2,3,0,0.062160,'Filing Grey','none'),
(2520,'entry','eurFKjjiaGqXArvBnkcMn51cTmCmKHAbhorZKRNypjEW',3,1,6,0,0.060970,'Toner Dust','none'),
(2521,'entry','rogS4E1kSuQ9pCo3utCx7gAyfDyS8Pe7cvF2MgB1jtaA',3,1,1,0,0.036960,'Drywall','none'),
(2522,'entry','zUSqQvpiERSe9xEyExRJFrZnD2uQpWWqVGxgVzvifxVq',5,4,7,7,0.057330,'Breakroom Sage','none'),
(2523,'entry','Lfvxt7wpo4BdLay99C5NQDQdH9nrWrA1diMRBKLRGsdj',4,4,6,0,0.053360,'Cubicle Slate','none'),
(2524,'entry','ybkJwV4wauhubzoksrUEG93VByk4wUZxXDJdLtzy4qdE',1,8,5,3,0.044160,'Drywall','none'),
(2525,'entry','8PDTnkANiQmomtTrbAuTtHnN6dqniBov3RxJM8MogdzX',7,3,5,2,0.044160,'Drywall','none'),
(2526,'entry','umrtHg7LietGRxQ1LE8RvTMRPBaADJe5nzQpS8T5ywWN',5,0,4,0,0.039060,'Breakroom Sage','none'),
(2527,'entry','qJvJcBMqyRLkhj4uGG3hBqMC3iPGAaKfKRoAXG4sHy1W',2,0,4,6,0.038480,'Manila','none'),
(2528,'entry','U1T3Mz61BVEKaEKnKw2AVxXZ59ENZ5MaRpMkF49949Ni',6,6,7,4,0.046560,'Cubicle Slate','none'),
(2529,'entry','VeAEQm3x7GDC1Uvz6Rpmkf55ruzW2nPYuayN3ta8Duzp',3,5,0,5,0.041180,'Ledger Green','none'),
(2530,'entry','XKW7RBrDtmpV42fiyBCfFcdQSSaGEZDA4zBSJTRXtRme',1,3,1,4,0.041890,'Filing Grey','none'),
(2531,'entry','X3zqy1ZPAzUQz8L6Jm6odM9qcjtrrUnpP4a5wnMD12eK',5,1,6,7,0.061420,'Cubicle Slate','none'),
(2532,'entry','FufNyipBKgWeP1ScdGXjRa5GH9ckMyHeEBCudN84NRiU',7,6,1,4,0.030720,'Filing Grey','none'),
(2533,'entry','SitWSEXTbcCWNJENU8nDoRnRsdQRMmqsXFvpcG2wSAZW',4,1,1,8,0.034800,'Filing Grey','none'),
(2534,'entry','VeQiv4Wy6LJfFu7kx5fkDrQveM2tYw1MiJ7xuuTBJdUk',1,6,2,0,0.060300,'Toner Dust','none'),
(2535,'entry','4PbB51jfi1GNqoyojNLyWpBvcCzb1e8wijZb31Mb2ctB',0,3,1,8,0.047040,'Ledger Green','none'),
(2536,'entry','8TNumxSXYkUF6bWa97fUw3qvypBokKHkHVP1zT18CDke',0,0,5,8,0.039100,'Drywall','none'),
(2537,'entry','8crHRxWes9Nv5XmQDqWQ3d51nSnVkHwKz7duVaPGLK2X',2,4,7,3,0.041600,'Ledger Green','none'),
(2538,'entry','4rCfPEndx1MEjZ1mM7dtPtbm3mY4fznSYM6v9yCikW7t',7,7,7,0,0.072520,'Filing Grey','none'),
(2539,'entry','DXN7uLrdNhuvFeVefTifUNJaofwnuDLPt2PHWYiJKHYD',0,5,1,5,0.060350,'Manila','none'),
(2540,'entry','osoHw6zqhiqUBd3M67Eg8LUwipgYRiKQE6pQXkCKu7C4',5,9,4,5,0.038430,'Drywall','none'),
(2541,'entry','nrBrs85FYneWtHbusBi4TpVef2KVh3iyw7vnR1JBcJtA',6,9,4,9,0.070300,'Manila','none'),
(2542,'entry','B3mTpxhVT8bkeWmuaXN5nCvnQtS6cydoBdyPqn8AV1BM',2,7,5,0,0.042680,'Manila','none'),
(2543,'entry','Z2YoRqUuGhv9mLLju6iKqkgxauJM1Jj79t7tQb4gj4Kk',0,0,1,4,0.074520,'Cubicle Slate','none'),
(2544,'entry','jKBpyANh2LKfnLURKkbCAvGLDxfDsc4CKPdWTUeQxfuK',4,2,2,8,0.049580,'Breakroom Sage','none'),
(2545,'entry','fgrPudaJpF6nojV8to5nbA5HqmKFLzhXnRwimfvmqPMu',3,4,3,2,0.040320,'Filing Grey','none'),
(2546,'entry','gpPrj6RJZeUdoiZEroXTXWAa9hKrTmbffDgA3WtJpx3F',0,8,0,0,0.089240,'Ledger Green','none'),
(2547,'entry','AAxFUJJLywB5QCBq61pHBug5f8ML5ccrNLq5CLhWeRvz',1,1,4,0,0.071760,'Ledger Green','none'),
(2548,'entry','T3MrCSNT7qVow7GMYzr8oQ3k5rz8ZxnZWHiogwhE4Ybo',0,8,4,6,0.050150,'Cubicle Slate','none'),
(2549,'entry','34KZMYovkyA9WR9WiXDBBj1sUkemz8P4NcsRytoRhW9u',0,8,3,9,0.050410,'Ledger Green','none'),
(2550,'entry','RrPaCL3xthQVaCWQUAY5syQYyNkd9Rksdw3rQk5kJMsa',0,7,3,2,0.031680,'Ledger Green','none'),
(2551,'entry','VmqJeEXfTe5QocYaq8sWknP4Cq3AeznCCUKXLkoSHZTw',6,9,3,0,0.054870,'Filing Grey','none'),
(2552,'entry','X386V2GbVGhyWycd83aoxvnJEWCxf61u6ppXJ8RRC1qA',5,2,4,5,0.036000,'Toner Dust','none'),
(2553,'entry','3dpYrCLoRH87qsfNqMZF5ee9wsK7TSJNaWsZoBpF9tuY',5,8,6,0,0.024800,'Ledger Green','none'),
(2554,'entry','wH86323gEyFiPh372JAdvabbeABssXoE2ymEtyNSjSN2',6,3,4,0,0.036540,'Ledger Green','none'),
(2555,'entry','wedncRb5ng9dz3Ja5eYCw2xCsgKKMc7KEMyWFWQP7v8Q',6,3,2,2,0.031200,'Breakroom Sage','none'),
(2556,'entry','5whDgofKcqx9r1AGA9C5BvZi2HydU7TDhkHPAxJWBaCK',0,3,1,3,0.022080,'Cubicle Slate','none'),
(2557,'entry','wPD6ETBmqVJwC5zunm222E8iJaZzd9i8XLZUHgpELF8g',0,7,6,9,0.040480,'Cubicle Slate','none'),
(2558,'entry','ewbRAD7m4AFDsmqeenm89G1nY75rEXt9SF4GBdpehydF',4,8,2,2,0.039690,'Breakroom Sage','none'),
(2559,'entry','mkkNGnXmisHc5ASuD4AQ7owCGgQE4cD2oj3EZKnTgeyS',1,1,7,9,0.040870,'Toner Dust','none'),
(2560,'entry','ekZc4pBcMCd3UH4AAzokNVinUH1vPKJJ93NNa95t9bxE',6,5,6,4,0.045360,'Drywall','none'),
(2561,'entry','mFxJsHA17bKddw85LwZ92hT1KzFoCWKdu6v68RvEao5P',0,9,0,6,0.065660,'Ledger Green','none'),
(2562,'entry','qpmTebYwkJg2yPoVzBS3eZCZkmfqbWhEXha8v5ZuDR8y',0,6,3,2,0.057620,'Ledger Green','none'),
(2563,'entry','9DAB65neJQuPiBME2xSJBFbYWMLcUbmHPcsQCDUGnAvk',6,1,3,8,0.079120,'Filing Grey','none'),
(2564,'entry','Czco8Ecj7rgYbCZokPDZ9sQ5hsJ5hwG8hYj4XztkkazC',5,8,1,2,0.051620,'Breakroom Sage','none'),
(2565,'entry','Hv5yNVXxcopBSr39bNYdg9aQ6MiQSpu9eqczoVzahwWY',2,7,1,8,0.066330,'Filing Grey','none'),
(2566,'entry','cT12KX7c9D5m18Yf2gBnNqJZLC11sYtRo2qke94aUmwL',3,5,1,4,0.022720,'Filing Grey','none'),
(2567,'entry','HU8GVVCJqTLFD7HhXhhA8jRSnb5xCcKFRaAbosHXdibT',5,9,2,0,0.025920,'Ledger Green','none'),
(2568,'entry','nPYkTotjkkb9VjJxyN2yxpfk2zRanDwbgnmbsB3mHKp2',7,5,6,3,0.025600,'Toner Dust','none'),
(2569,'entry','JdDLrEBkWw2FqdxUwyVP1zoNWqCFMuYLmZwtYHkBB4Bs',2,1,4,2,0.058960,'Filing Grey','none'),
(2570,'entry','nyfKiZoipcGWUXhASMRkWRXQXHeva6bkBppLow5qwrXE',5,6,0,0,0.040800,'Manila','none'),
(2571,'entry','Hq7RrwiGwS3hAk2Yno9KfZusUsPGJeM3xrvnkNuxrP88',3,5,7,6,0.045820,'Manila','none'),
(2572,'entry','fwPdfFWqRodhuWBTPhq6E5heU7gonfrJM4nbip9xQA8r',7,8,0,0,0.052000,'Manila','none'),
(2573,'entry','F3f79c7d1G7uhXezvuJeN9qNTZirnEkacnJNvW2esfiU',4,7,3,7,0.051620,'Manila','none'),
(2574,'entry','TcNxZe2SJfZjuLHZ8bidpKWeohkaB317ypF4NXxJqL3j',1,7,5,7,0.054270,'Breakroom Sage','none'),
(2575,'entry','pCmsF7Bzdgh7WkPhy9ewyR5APDyAAbaoZTGDHXdvTpF1',5,5,6,2,0.067230,'Filing Grey','none'),
(2576,'entry','PfaFyxLjLkX1UfLYGhdQW39pQJ2cEWrPjGY8SdrokSR7',5,7,4,6,0.061110,'Filing Grey','none'),
(2577,'entry','Vf8ig5Q9jaAyyoHg52hv85nR3UjJeUAcMdD7RqcqZdhU',2,1,7,7,0.025600,'Drywall','none'),
(2578,'entry','DBqhP6MnsW6ekpxmphJgjTMgU6jQP3nHhTMzaBPrzTB2',5,4,7,0,0.025280,'Filing Grey','none'),
(2579,'entry','ArY7SbPkg4QwFrt54FVrqRskFSv5dZSmLJgafTzVsNNX',3,3,3,7,0.046560,'Drywall','none'),
(2580,'entry','9P4dJTWmYg1MxottLAkDMaidBp6DqFi3uSMZ3PjFzErR',2,6,2,0,0.031200,'Drywall','none'),
(2581,'entry','ckCGUnuTBomHZTxSuWXYQfpUz9wUBYzmAkaB7c3XBcPk',4,7,0,3,0.036000,'Breakroom Sage','none'),
(2582,'entry','eiRf282oBu4214doxVVekXYowbQS1TGb5kr5U5cTtyq4',5,4,3,9,0.141000,'Toner Dust','none'),
(2583,'entry','qWMaFyvSYFM8XKEqagYTzcRypoAS4BM3RRXhT83HtQN1',5,4,2,2,0.039000,'Drywall','none'),
(2584,'entry','KvuGyeEiG7buhJs6HL7ybpKEewv6E73YdWYGeqb2R8EM',7,4,0,3,0.026840,'Cubicle Slate','none'),
(2585,'entry','9Mon7QBkx78M97jxhxZY9uqTKwy1zMSbLYjwFMpzR1Tk',7,8,0,9,0.080190,'Toner Dust','none'),
(2586,'entry','1jSktLgWGJUw8Bn6gmSbJcEuNELJx9G3hWhCWE213oyU',7,7,6,9,0.053250,'Toner Dust','none'),
(2587,'entry','hNeoM6J6UubUkx4R4n2sTgT4MGUzGoqT4mEKHkcyjqEn',5,5,7,2,0.077760,'Manila','none'),
(2588,'entry','SZNo8FnpGabbNYaDSiMNADcDAxHLrhw1SxgbQ7LSpZP8',2,8,5,8,0.029480,'Toner Dust','none'),
(2589,'entry','HWByKNfw6zJz34A4NWTDdkkpwyU8RrSURoPC2sEsMhJC',2,6,7,8,0.032640,'Ledger Green','none'),
(2590,'entry','8xB4PLBFx8vxpThp4pueNtPcrxhGn35fPQG6FCB2971N',6,8,1,6,0.033600,'Manila','none'),
(2591,'entry','JcWTxZoSBaKRBugZvZ5ihPziQPTev1wSzNVz2vXE1RJn',3,8,3,8,0.026840,'Toner Dust','none'),
(2592,'entry','fmsjTM14SaE6xKkhMDhxdfDB8NAphPkxhJi6HvbuzEoi',6,3,1,0,0.063000,'Breakroom Sage','none'),
(2593,'entry','bhdpBW3FD7nU7yZriJBTToNChS7mGQDgtbwvG28EzpiE',3,0,7,8,0.040040,'Drywall','none'),
(2594,'entry','Xuwfm9fRAKXYm4MkzxzXALdYuJjp21KSefWwNMp2bYHh',7,8,3,7,0.040040,'Manila','none'),
(2595,'entry','jg8BwtgTvkNMjqC22gCEv7i4WCi3rGYUSnzf7oknUqKy',5,3,1,9,0.020160,'Cubicle Slate','none'),
(2596,'entry','fq29yvFwSNWRgv3CqcjYx4jqCHKikTDFbPR4Xrkv8LWh',6,5,2,0,0.037170,'Manila','none'),
(2597,'entry','yoEUXz6LRX7JQxfa2gom4x7RNsZdAA2A8Bi8stEaMoNm',7,4,2,9,0.024000,'Filing Grey','none'),
(2598,'entry','b72Wi81wp8CTBfy4qiEnHw81UQEV9fDKogdjELFqT8ja',3,0,2,7,0.030000,'Toner Dust','none'),
(2599,'entry','HDAQw2FZCBGZcpeqdybfBWQcCK49Yg2ETn28Heyfo3HZ',0,3,2,3,0.031600,'Ledger Green','none'),
(2600,'entry','rw3vw718rAYS1hTYddTGKFLs8s9kZwQbLppEH2XV3g7b',7,1,6,2,0.031200,'Filing Grey','none'),
(2601,'entry','wLdzE3N1HBaH7y59XWez4R7BxBZQ6159GZJgqhvsaGPg',1,4,3,7,0.051830,'Manila','none'),
(2602,'entry','X1hDxTebGRmyacr6Ewge4EP4zbh46f3UXMKf8AuqeF6W',7,2,6,0,0.054810,'Toner Dust','none'),
(2603,'entry','zxGEPNeW6C6we73YAs6Kcc9eeyGEF8rNY5FB9Xwebu5h',2,6,1,5,0.038400,'Drywall','none'),
(2604,'entry','6xRXxwnCSpiEswXw6z6QJPokyrAaziRG5qt5Ra55w7UE',2,1,0,3,0.045880,'Breakroom Sage','none'),
(2605,'entry','yKjL7T2S3zapPJj2GGmhtn4zxw3b7RvbwPikwNeByKHq',0,2,1,7,0.076360,'Drywall','none'),
(2606,'entry','71z9nwfPpoPzHjJQtc87XxMLRE1iUvMfdwoRvhMgyeTD',2,5,5,2,0.033800,'Filing Grey','none'),
(2607,'entry','knER2Jr1Y5hjYAyd3RwgN6cQiMdYRhBHTFRNcGK3P7ZX',6,0,3,3,0.032400,'Breakroom Sage','none'),
(2608,'entry','MVapYSbxgmMc9oVQNYEPNc226EdKvZxmJocEqUTNisgU',6,9,3,5,0.040950,'Breakroom Sage','none'),
(2609,'entry','hE1jcX3E5ipkc47jqfi8yw8ap6U6nGwkixVt4tpp8HxV',6,1,3,9,0.033580,'Manila','none'),
(2610,'entry','BEwV4PGMWfViCStdJwfmDPYQ7uPgxteoMq78yK4Em8UM',7,4,7,7,0.047520,'Cubicle Slate','none'),
(2611,'entry','g77RDng1tWcm9CY5Sva7egzD8KJpVxBwW4ZNTS8fJjsg',3,8,2,2,0.031720,'Cubicle Slate','none'),
(2612,'entry','w8dB9nmmJocBmQWLbrRwN2SBhaV5U5aLCGTYHGqXMYw7',1,5,5,7,0.073260,'Toner Dust','none'),
(2613,'entry','BtLyVWifLGX4e4XaoU5yQUJhpue6EBJmBJZnmvZKyHGh',2,7,7,8,0.043680,'Ledger Green','none'),
(2614,'entry','bLxfNyzSQgEqatdkVnPmkgEoZTGukawZG7UVAPp8Fpmq',5,2,2,6,0.036540,'Ledger Green','none'),
(2615,'entry','G2KFxB5DoWcQb9eDyrnPWz1KLyYDCcUVFS3gmfT4US55',3,3,3,0,0.061770,'Toner Dust','none'),
(2616,'entry','NsKrk7QxGSfQMv1JPX5pynzocdoCnMCuP5rxxz5Z3QcP',0,7,2,9,0.034800,'Filing Grey','none'),
(2617,'entry','g2rPJRELLxABxsiCMgBN7wEJ3fmsW9RKBLTRfv1Zvuz8',7,4,1,3,0.055440,'Filing Grey','none'),
(2618,'entry','3jNp9qobwWYWKq9G3KpF2Fp1sYbMNjSLmzZ8MmNThvSv',2,3,7,9,0.054810,'Filing Grey','none'),
(2619,'entry','qCKBZTLavGDZdHfCh9hHZgWJU5Xq9bb8UHtYkrvMtUuD',2,2,3,2,0.042720,'Manila','none'),
(2620,'entry','HN5jqDhctCrpJVizEJDS4BeVbaDL2hP86sS87xrX8U41',6,4,0,3,0.051330,'Filing Grey','none'),
(2621,'entry','bi1QiE2D7Sdi1chjQdS8DAefJ5zQKhngTWA9GWEyCxUd',4,9,4,0,0.036520,'Ledger Green','none'),
(2622,'entry','zhtUkMqEQbtrhQS9mYJQXbGkwxTShVbekg8AkSfhRqFJ',6,2,5,8,0.035880,'Breakroom Sage','none'),
(2623,'entry','iSu3T9rP1eboZprUqh2G1KvaPorN9beCqqwMv8w8DjmQ',2,5,0,0,0.066420,'Manila','none'),
(2624,'entry','wzRMv8sto7ygagoeaxyDPuHXKzP6uGWBQpGsweasKYRV',6,8,6,4,0.109620,'Ledger Green','none'),
(2625,'entry','Kw1q35Vt1NpttGf1iUXE4RZonDLUSWmNbrAoMcx1ep5G',7,5,1,2,0.029440,'Manila','none'),
(2626,'entry','EHBnbXyGoiP8Aw7LGGx4zKvhbh6gNi4GbiyXwWsn2nxV',0,8,6,6,0.020160,'Cubicle Slate','none'),
(2627,'entry','pFUPUtPu1jbZTq3E66jHWCE2XBtkEyWQthMaaCNeXiQj',5,9,6,8,0.040200,'Filing Grey','none'),
(2628,'entry','ojqjwRnWPhjATzLKfmNjDb4GZktpy5BaA4EQq3LB9DSB',2,3,3,8,0.033600,'Toner Dust','none'),
(2629,'entry','4GmRs65XwJWdhWGmN7TDi79jvKHcnfbygAozwCXjtQEB',7,9,5,0,0.070470,'Breakroom Sage','none'),
(2630,'entry','RqtqbBA4z1ZvViZRuhEzsJ7P9TNFLNpCJAY5hJmKCAHC',7,5,1,0,0.027600,'Toner Dust','none'),
(2631,'entry','JUk4rwmK16h1uk3mTcadSTNY87SR9R76CoCukGeBziWu',5,6,3,7,0.040940,'Ledger Green','none'),
(2632,'entry','woYxeVgtpHGow1un9S2oR6HieDUmg783Fgpzy3YTNwfi',0,6,5,2,0.027200,'Cubicle Slate','none'),
(2633,'entry','Jk2VbLK1REwvFoyEMMiooRtJmZDbPKsUVWAvfVUvsd8J',6,5,6,8,0.071760,'Drywall','none'),
(2634,'entry','9PJWD9bR7QR5bTpKBzwgMv7Ltx7DuJkw2qMpnVxL5AKJ',7,7,1,0,0.036000,'Filing Grey','none'),
(2635,'entry','Z2GFzLVNWFL9Cjrq3D2gkfPFy2dQQ6nj9TM4ww7TTpJY',3,4,6,2,0.032660,'Cubicle Slate','none'),
(2636,'entry','2hdh5wCdQq9owwRoZWzNEhk1TGiJKbW6bSAyArMK5xZE',0,5,3,8,0.029600,'Toner Dust','none'),
(2637,'entry','oDMye9zpDvRiRg86pYhjbXiVWztzPWhfK9WEpTqEU3du',7,7,2,8,0.032800,'Breakroom Sage','none'),
(2638,'entry','w88yMWn8WUJNkkYGKhXVQvXJa8rzTfaaqHu8C1Nsxbh1',5,6,4,4,0.025200,'Breakroom Sage','none'),
(2639,'entry','MeNTaKrym84CWKMtFaBefVpLXXo3U6ruwuwwLngF3TZn',0,1,3,8,0.063000,'Cubicle Slate','none'),
(2640,'entry','wUvEdyTi1nVs7dAJ2jTfRUEHiukSbn3sVZCnQZbUmrnG',7,8,2,5,0.049700,'Breakroom Sage','none'),
(2641,'entry','YfpfC6DhSaZzo3tVqKQpKtHEyt46hW47Vqitu8N29aqq',1,5,4,6,0.034040,'Breakroom Sage','none'),
(2642,'entry','WxzsW622Qki4fN1aPUq7TQqRW6MSs3HzFCXFDenuABMY',5,0,0,0,0.088200,'Breakroom Sage','none'),
(2643,'entry','JsEpBR6sySsqqXAwrvPqmVXhU1zeBfL6mg4PedEjBVRB',6,3,7,5,0.046080,'Breakroom Sage','none'),
(2644,'entry','38ZQasaWRSbi2VzWAVihuxjZ7hdfTyQ6GXwBxqErPXzB',2,4,1,7,0.061420,'Drywall','none'),
(2645,'entry','4eWxKrmxehw2RowcSWLQoNqwuocpQ6vKTzEPjt6i3tqg',1,9,1,0,0.037120,'Filing Grey','none'),
(2646,'entry','LLFKVhhZqxRqHr9HAWEUYz7HQ3jUMdQvwTEt3Fnp9VeT',2,3,6,8,0.076140,'Cubicle Slate','none'),
(2647,'entry','84gtQ4XUsvyNzUouZtKCop6LoEYBxfVAwgFNVj1U6Ft5',0,7,5,8,0.063900,'Cubicle Slate','none'),
(2648,'entry','PbdTpa4DyoG3wcsqGXKUVDqqNhuhUbCo8q9Ej13bnoaS',7,6,0,8,0.030240,'Breakroom Sage','none'),
(2649,'entry','MWZFQrz69cAJiPnjtehpbHmnicAtRDNXox3Ex4zw8rRR',4,6,6,6,0.045080,'Filing Grey','none'),
(2650,'entry','iWqgzRPGtxfRCZbRUBMYK2vndykaWxfK8MCbBLWczzBw',7,3,1,4,0.032120,'Filing Grey','none'),
(2651,'entry','NrTnTVy6ccsuztU8eDqvhgepVNTTTfxA9euvRa4bZsnr',5,9,2,9,0.028160,'Filing Grey','none'),
(2652,'entry','8CFMbaxE19gmFBi7MwB7zLn58WT6phnG9Cib2vVsgTh9',0,0,1,8,0.048360,'Toner Dust','none'),
(2653,'entry','deHSgJe5GX36SfwBdT5VhVW8bjAoMrLSSdm8vdMoRPE4',6,6,3,0,0.037920,'Ledger Green','none'),
(2654,'entry','zxziryQvXoLX8UUCMgZyb69JhZZZoK8pWnA9i32NViGv',4,6,4,0,0.029280,'Drywall','none'),
(2655,'entry','HKB52dSkvgfdgYqcemQKG85izZqYc3YHj1SzNeCL8eGn',5,5,3,2,0.021120,'Manila','none'),
(2656,'entry','Lu177abXkews1urV6SSTKNPwMbcPa4dvnrjtFrBRoWXv',4,9,5,0,0.040320,'Toner Dust','none'),
(2657,'entry','J4pQKcdXWNUGdkpAFonMYQkCU6EirkhnsCQRhzH91oxy',6,5,2,5,0.048240,'Ledger Green','none'),
(2658,'entry','1PketfCLsNyL8m6xf4fijdGpzoNBa57H5Hc6Cpc2P8ZE',7,6,3,2,0.066030,'Filing Grey','none'),
(2659,'entry','kCnrSCBW4rQwVzYTzbNtBrGpnTVMgKSFZmy1xRdMQXTb',3,5,3,9,0.066600,'Breakroom Sage','none'),
(2660,'entry','JH1qwoNfT9LMLr3hhi4JcZgx4Ds6UrQTsBMsshATeWsG',4,1,5,5,0.036400,'Toner Dust','none'),
(2661,'entry','YNTJw5hcGrypFc69snNMzaLUAyf9iKjLshXz9Sjwu3HT',5,9,3,0,0.040940,'Ledger Green','none'),
(2662,'entry','Gtimk1Y56L8NWEU3MCDeModZ6SLMARAX5ZeEhvtv8taY',1,8,1,6,0.034800,'Manila','none'),
(2663,'entry','3WrYoE4Hyz4pQt1BHuGCwLuxjeG7RbFXSDZSZ4hVb23V',3,1,0,8,0.041860,'Filing Grey','none'),
(2664,'entry','YqYckZW6cLUexQeWv7BcoGtYGejMtmhp6Lq8yX3kgRU8',7,7,2,6,0.054280,'Breakroom Sage','none'),
(2665,'entry','DbrpecS2LHHW3mfyx1yDx2Dqsc1FEzfwkKCssdYrkuVQ',5,8,5,5,0.027600,'Cubicle Slate','none'),
(2666,'entry','es4Ua3FSo6KsB9dAn8rkAcxSHbyQkJLusU7tFbTMRB6c',6,3,7,9,0.079120,'Filing Grey','none'),
(2667,'entry','3cLfmtnpKgqtYpyPKN25ZFvBrKaBBA21vj4rswudb7T4',5,4,7,0,0.041400,'Breakroom Sage','none'),
(2668,'entry','2R5KxnzTh88wPxjy9wXefYUovhC42smM3zvqNzjTGQ4r',7,6,6,6,0.029900,'Breakroom Sage','none'),
(2669,'entry','tneWwS29X3bmDfSnhBMNCK127dGaefs71P9MDtshE29K',6,5,7,5,0.050460,'Ledger Green','none'),
(2670,'entry','dJYGF8gnbWGgPexJCAaRhGFgq1x58nasixKPBR4vCyMb',6,4,3,4,0.042320,'Drywall','none'),
(2671,'entry','AiQQvh2Abd4vtCRrBpV1qdyVpYvav42LSSd19rLuMP3W',6,2,0,0,0.040320,'Cubicle Slate','none'),
(2672,'entry','qatcwJd8rrB8Bwi88nBt6gWf1FUnD1WXYeWb6Z1ZyWwW',0,7,3,2,0.028800,'Filing Grey','none'),
(2673,'entry','tjKYCEDPH9KpRXywUEsNPvvV5MPZ2mHgBGPM4fJegjpm',7,9,4,9,0.053600,'Breakroom Sage','none'),
(2674,'entry','Q5dJof3efekVVKLKQfhCcUeNEeSVHe1w3cG4BXebSGaa',7,4,5,6,0.036580,'Ledger Green','none'),
(2675,'entry','2nWNsGvDvBwEePEBNyNvbmavhKpfBNHe3FVLeE2a1gYg',5,2,0,4,0.042240,'Manila','none'),
(2676,'entry','DjJpH3L2aq1SPfVqxU1n161QQBE5t9ASo7fhzDw81EhP',7,7,3,4,0.040320,'Drywall','none'),
(2677,'entry','U9BSworiWD5BPxPGtyMLoEZeQyghPgnwff7VN8Dd9kML',1,1,2,2,0.039200,'Ledger Green','none'),
(2678,'entry','TWRhcYVX9Pnbm4eBgRyaDHkJTjckD5b8FXSH9berxTEZ',1,4,5,3,0.032800,'Drywall','none'),
(2679,'entry','rELyeGp2fLZQKduafbDgy6VqcESMnuqrSVw5DN6kLMWU',2,9,5,3,0.037700,'Cubicle Slate','none'),
(2680,'entry','zsi35cZNpws2GufUKQcELGV66iQkAZGY71f2L29wvWSw',4,4,5,4,0.040000,'Drywall','none'),
(2681,'entry','v4bsjHJFoDTaJNFNLK61ijyvx6iWxRWcbb3NWAzuAsrB',1,2,6,2,0.019520,'Toner Dust','none'),
(2682,'entry','Zg9h77Dxs3RqQrpqse4bh5AGmAHPHfBnmrWteZMJcSze',2,3,6,3,0.027520,'Breakroom Sage','none'),
(2683,'entry','Coft46786NMmHrANTZRrjnz27sxV3nLD2LvMheuzHtYT',1,3,7,3,0.057420,'Ledger Green','none'),
(2684,'entry','pAoLjVfLUZRuoQHrcu2zd55V3MPL9YaaB6SBPg7FWANt',1,2,7,0,0.045240,'Cubicle Slate','none'),
(2685,'entry','vaVrk3YmtAHxJfqCqW5kwusTDubc89gcTjn9kyrG4S1c',1,0,7,7,0.041360,'Breakroom Sage','none'),
(2686,'entry','djQeErKYbxA6Z7d9zqwJ1k6svykWXs5DQiHdqktrAMDv',3,7,3,8,0.045990,'Drywall','none'),
(2687,'entry','q7iFKDazb3w2mhTtvnqSRYLfyKPKkdnFg3aQD7VTSfyX',3,3,4,4,0.051920,'Drywall','none'),
(2688,'entry','76noLdoY7JZexEviZabMrLwaspNLrKRPkcWWb69pNBh8',5,4,6,0,0.040710,'Cubicle Slate','none'),
(2689,'entry','iJ3iwUv1UMRLFVoSr1Zy3RGAFDdTCKi2D9jvAd1CPDkf',4,1,2,2,0.053550,'Drywall','none'),
(2690,'entry','K1vN9GozZ7sP1fDLyfyM1W2zFhkgpQey9PgYHXBixzJW',6,7,5,2,0.046980,'Ledger Green','none'),
(2691,'entry','ZBqqosgdP7ox4PjpHQmQC8CY8RdVdpwn5YohaF7WnwFD',5,0,3,9,0.034320,'Filing Grey','none'),
(2692,'entry','CA85b4PTcCmL4VuMRGnW8px5kRGhiwRkwrigPrDP2WBK',6,8,3,0,0.039360,'Filing Grey','none'),
(2693,'entry','J6qd5g48qbgR8KVyJuUxu7dMvyMgoDN964dYRyuqi7rK',6,3,0,2,0.059640,'Manila','none'),
(2694,'entry','gXC5JdPY6H8geaDKvs64zF4ZQc2KHrEMfqNab71sGpFw',0,4,3,7,0.032560,'Cubicle Slate','none'),
(2695,'entry','AwAmJbN1JYfiA4sr1x2KPV256As4BRRF1AwKsCRESErj',6,1,5,0,0.049560,'Filing Grey','none'),
(2696,'entry','AY5FC6pk1cFjUQZ96dSfVYd5gyCAmxZx8jC9CXHzjGcV',1,8,4,7,0.028400,'Manila','none'),
(2697,'entry','PnGssuz8v5AwZukUxmv7rQpBa4hmEcGXn5ZoRCGjkzvx',3,1,3,3,0.040920,'Breakroom Sage','none'),
(2698,'entry','ibiS5ASvZvLGK6P95rMA25seKiMTivzBTbCSz7J5sFPf',5,9,6,4,0.050250,'Cubicle Slate','none'),
(2699,'entry','iZzCPBTMWbe22ELLz7vhS69ck9ZjjHizAsJ59AkPKUDb',3,8,6,0,0.064800,'Toner Dust','none'),
(2700,'entry','fWgfeRAC37zBcRkdQaEa8oE7VaTyYW1AXqPVSxrpyv3o',5,8,5,3,0.053960,'Manila','none'),
(2701,'entry','YADW9Eoey5gBPDGS4VdqqCUB8Rp4GXb9g593YGtFCfar',1,3,6,4,0.054520,'Drywall','none'),
(2702,'entry','7FMzheCZYs7M5jG8Fo8WJANoaeYHiTksNHE3HLpNsd1T',1,6,1,0,0.024640,'Drywall','none'),
(2703,'entry','iKJLSsAxggeGngFWnfFECkNip4sjUq6NTiAxcgS8HhZW',1,6,2,6,0.040800,'Filing Grey','none'),
(2704,'entry','c8Wh3mkhwyomigthap5zZSfXyeG3romTau31fPryqFkd',6,7,0,0,0.060300,'Toner Dust','none'),
(2705,'entry','SZm7iMEK38FwQhMhoerShiFcVWBUMrUtXprPCmXYTHrP',5,2,1,0,0.040800,'Cubicle Slate','none'),
(2706,'entry','Zy6SYpeQ7K1mAcPyaauR4o3cD3WaB3n9gSwCKX5UFEfR',7,2,2,0,0.033280,'Toner Dust','none'),
(2707,'entry','ihRD4uAtvg7Y2JMAEqH8ciG6vxFtc9xLZcDJwGKCjKXM',0,1,6,0,0.041540,'Toner Dust','none'),
(2708,'entry','J8BGP231gFyerpQDSa15YsXEuSffW4dxJ8ysnhcYc4yH',3,2,2,4,0.044620,'Manila','none'),
(2709,'entry','QSAmaPKgaibsMjQazA2PGQMkunRVmjS7G3X9LTVZoMs8',5,1,1,9,0.036400,'Manila','none'),
(2710,'entry','Rrp3RJyL8gx46vonDAghiEdTSr2fMv2sEmMbnmCpxXAQ',3,2,2,0,0.072090,'Filing Grey','none'),
(2711,'entry','5VLG7AdNK9v4G4qKe7DndCtXT38CsWeh4FsF1uRu7w6Q',0,0,2,0,0.044020,'Drywall','none'),
(2712,'entry','phCWGmAD5XdeLetmSKEPhguobC3RBd53MtEGTjQuPtuu',6,7,6,4,0.038880,'Filing Grey','none'),
(2713,'entry','UHWzzpnwt4455Z52QoNgXnFrBMqcNbFC3Lzp9HDk7X2s',6,8,4,9,0.060680,'Drywall','none'),
(2714,'entry','4PMHTKdf5Yjsneoy2CZexjYtUUn33zkrmuuHa8D2guPm',6,5,4,0,0.042780,'Breakroom Sage','none'),
(2715,'entry','Bi2wJ1ySReN4JrEPXYVKCPvL9ApGqzhxHFhgTue8W1xE',1,7,3,3,0.041180,'Cubicle Slate','none'),
(2716,'entry','ExiXs55niRYTwDd7iQqtqJHbDa4phTG5qxa5e8YV3RSz',5,4,6,6,0.035200,'Toner Dust','none'),
(2717,'entry','xHXy78XCDYD33iYzsy7BEmziiHmPAWFgENDbPbpYsyYs',5,8,2,4,0.024000,'Manila','none'),
(2718,'entry','7HE5H82wpMXYP3vZS2ucZmamHajDD68y15t2pYkVUdvM',5,3,0,8,0.067450,'Ledger Green','none'),
(2719,'entry','Rjh1KBnoyfMGLkePk1zmnFGcJ4sNF2RZpSuhfB7DHa2n',2,3,0,5,0.059850,'Drywall','none'),
(2720,'entry','QChqBHUwDCDamC7fYkmcjF3d8LoKiYwURhH3oNPe79Rq',6,9,4,4,0.057420,'Manila','none'),
(2721,'entry','TcRUFcf9aWpqUCcjz2xJxF16JZsrJ7XDMT4XmaqY659D',6,1,4,4,0.035200,'Cubicle Slate','none'),
(2722,'entry','oc167JwLz8PiTXKGUNt8FUsFkVNqWky3PVRiw9HYXcxK',4,6,0,7,0.072680,'Manila','none'),
(2723,'entry','MCigUCJDNw8dFhjsNtPhiyDkHjGc4QXDX4CzTXeH9rcH',2,5,5,0,0.054940,'Drywall','none'),
(2724,'entry','JdpsNdBXeVQGqgEryhvpex7HhzJ8aisjZsw1sZdkkWRa',7,8,6,0,0.030000,'Manila','none'),
(2725,'entry','tmmGwFFRzfyM7ymopzFzDcNSbWb6AqHS7HFGoSKwrqHA',3,7,6,0,0.033120,'Breakroom Sage','none'),
(2726,'entry','rGEhQWzuh5S3ukL4tWqcYuuMT9bapX8imm6RxAEQU1nQ',0,4,1,6,0.033800,'Breakroom Sage','none'),
(2727,'entry','WUCa3aPGTNxjrUe84c76bBf7ZeJgXKDFLegRfmDdWj61',2,6,0,7,0.033600,'Filing Grey','none'),
(2728,'entry','BeCMS1LPPaTMfFGntT3x3c5C21gctRantnY7oWZZ4HYs',3,2,4,2,0.041280,'Filing Grey','none'),
(2729,'entry','HnDbcKij3M32BLqsNsAuNGjqeNfoa8HkcwySHYsUfgmC',0,5,1,0,0.043680,'Drywall','none'),
(2730,'entry','aQSWvdZcQ2m6YdVwpAUXiytD37EBZf7APbrooCGC4SRz',7,8,7,6,0.046800,'Manila','none'),
(2731,'entry','S74x8pokwq1v3UKs3K458HDjdsid6sFmYrvrcnL4dfaL',3,6,7,6,0.028520,'Ledger Green','none'),
(2732,'entry','iQB8R9CixNKBxB11Dp3qrebWnm3CuDy2V8k5cTdSHuia',5,8,6,9,0.039100,'Cubicle Slate','none'),
(2733,'entry','FGCn27kXKhCFTY6q3UUjxaKiX2nJ1sff9hxUwtvRfGFH',2,9,1,9,0.052510,'Filing Grey','none'),
(2734,'entry','fNQMGavTptuybgR8qtmAEmbh2dd7wb1hYm5t542Ymfh6',1,9,7,8,0.026240,'Ledger Green','none'),
(2735,'entry','ypnKwgdtGqejFCefzL2Uuoh8cPcog85UXKWvPWnA3kAR',4,4,4,3,0.056840,'Cubicle Slate','none'),
(2736,'entry','wKNg1ewwki9yBjgirhJ47U8D728n2FwEJQnNctXbxxhL',0,9,1,6,0.049770,'Filing Grey','none'),
(2737,'entry','1yexgKE6KKwbxHVX8BELuBZ7EvcFQbaDznjgMnf4tgmd',1,5,5,7,0.080190,'Breakroom Sage','none'),
(2738,'entry','TaYnqHY3uEqaTxc9JbsbBZ8hEQX8Usjk3SgG5Gqd7vtB',6,6,4,0,0.050440,'Manila','none'),
(2739,'entry','CRWYrvFoHucpDDWsQYj5wb9TcPfbEtHr3y4qaQLAQgkJ',4,0,7,8,0.055500,'Drywall','none'),
(2740,'entry','eJW4Yyv2aTWHkgLPqaBzxenro4uMpnGUM63gto5cMmvR',1,8,5,7,0.026880,'Ledger Green','none'),
(2741,'entry','7npLvYuhHwiY1J5PxgmGokvVsvxTbLe7LgS57Ggj6NXP',4,4,0,7,0.066330,'Drywall','none'),
(2742,'entry','EA5EaYtRrLgzU56BwAon1RGdKf6w1vHLZ4BYrUCtU5Ny',7,5,5,0,0.104340,'Filing Grey','none'),
(2743,'entry','nB7F8KDD8mbLatC9izqRW3TcdCC24vV7sX1EpAyun3nb',1,1,5,2,0.046560,'Drywall','none'),
(2744,'entry','UfiyQMRREpyAPfc88ZFVf34w1Quc4nRLQqfyzkfxLScx',2,8,1,0,0.056700,'Cubicle Slate','none'),
(2745,'entry','rJpPxaLQuPyH4Mu7d7QpCNKmxCsUpDWKsNzF6gNVt6FN',6,2,6,2,0.069920,'Manila','none'),
(2746,'entry','Y1Ld8T8Wz6hrJ6BeSPWMkji8Ct4MygozNf5Qv7TLnDM8',5,1,1,4,0.042880,'Filing Grey','none'),
(2747,'entry','tanw7gbWgQKXUfgvi1xJvAR1Jt94cxQCmtbnCiUNhXxx',3,3,6,9,0.032000,'Manila','none'),
(2748,'entry','rrZgP5yuspTuhv79aW6sdNR7FiMstWZXe6xmgaSk7EY9',0,8,7,8,0.038400,'Toner Dust','none'),
(2749,'entry','hVhe4X3BG7wFkbV8V1uz1S2BmGSXcVx4r3wRZBuwJVC9',4,2,1,3,0.021440,'Filing Grey','none'),
(2750,'entry','e3HaPLWYujK6PdNFxWEwBYqbVPKpFDBZwDJ38hiJBybh',7,1,6,3,0.029760,'Manila','none'),
(2751,'entry','tfbBuE98WzgwSpsUQhCrLREZgJjmqwjZftmGq16KQCsU',4,4,7,4,0.041280,'Manila','none'),
(2752,'entry','h9xNC4GpAm1Bk4zRktYVRdAnKMivbrVJYpxdk3onPYTx',1,3,3,6,0.035200,'Toner Dust','none'),
(2753,'entry','PskDeDbdTBMN7sz7svG727pqGnHL9qaMSMrJp5PbUznQ',4,0,7,9,0.040320,'Manila','none'),
(2754,'entry','3MdFVw3WmqaLYqiGZ5WvXmwHmkrk4RXN16pT1q8BTU7w',4,3,4,5,0.020800,'Breakroom Sage','none'),
(2755,'entry','R9A5GnZo92G8rXv5nj69c4vZZFekEDXYAHqB4JgKZoGR',0,1,4,3,0.034000,'Ledger Green','none'),
(2756,'entry','wUpYZuiKh4TFjkMFMUYrFs21ZmWPn1FtZq5HvY33fzBp',7,6,7,0,0.038880,'Toner Dust','none'),
(2757,'entry','5Fay62ui32rqmbREoEVb8b6PCiMB5qqLuhN6N24rstGT',5,7,1,4,0.033800,'Breakroom Sage','none'),
(2758,'entry','DYeve7z2h3sGhyrjgi5rgAkfq6vU3Nw5Wn9SRYqPe8bS',0,0,0,4,0.037920,'Drywall','none'),
(2759,'entry','zFJw9sZXt9LxR7es8iHe7q1s8LqAMS9fqVvfyqkHoQdm',1,6,2,0,0.071000,'Breakroom Sage','none'),
(2760,'entry','tUP1JcHgrjKa2Y8aZAiCtQGpV1Wf9NbmQvAExKV61Co6',3,7,7,2,0.037440,'Ledger Green','none'),
(2761,'entry','kUEAVNnYmfFDvYYm7tYFbSjHBgZoiTw8YGezRdx7Cn35',7,6,7,0,0.030000,'Breakroom Sage','none'),
(2762,'entry','ZFhbLwGMejBLHu8T2V1uU7RyboJp5zy8xYej9UYpkEiF',1,3,5,0,0.045120,'Toner Dust','none'),
(2763,'entry','bUU7CBjThLv4BAEyVKTFCNTHBzuVCAGinG35LoVyyhy4',3,6,2,0,0.032240,'Drywall','none'),
(2764,'entry','VkFSNUo4kXQgUxgUWLoQQoRw7zeUcfsJ5fifqYy5NTfA',2,2,2,6,0.064990,'Breakroom Sage','none'),
(2765,'entry','3aA39MEZq4x5HkVZYKcKtHDLKntADW7JbyapEYAjV1Q8',2,4,0,5,0.024800,'Cubicle Slate','none'),
(2766,'entry','FQ1b6wxAW6MZJ2HiHSDuN3orLt52EoxrubQP6MfE53BQ',4,1,3,0,0.059220,'Breakroom Sage','none'),
(2767,'entry','J3Cqa37mmBU3VBxomRw6hdTT1vPnUgdGyrPyDSDMq7U6',0,7,0,0,0.019840,'Ledger Green','none'),
(2768,'entry','QoVUzKwX3B1x1G7fgCALmzCTC8g2bdqtqiw9d9RDzFV9',1,2,0,7,0.040040,'Toner Dust','none'),
(2769,'entry','C5kzZ3GddSBwrMfrHsKHDFQg2KbgZPJUGFr24pVGdhrm',4,5,3,4,0.026800,'Drywall','none'),
(2770,'entry','iv7QwYSzSRZs9BrAniiV4f2rz1Qpe3md99k1U82BohdM',4,8,3,3,0.040480,'Filing Grey','none'),
(2771,'entry','veEpaCdehktWccFm6eWgBsciSwokTepF1K79BFx1jZs6',5,7,0,3,0.041400,'Filing Grey','none'),
(2772,'entry','KwZPmzendsvqgmVBs9n8WFCWkz5y3XXem53tspdZr7SZ',6,1,5,6,0.074520,'Ledger Green','none'),
(2773,'entry','nEdqS4GzngfnngmBNGaV9Qht5tHk5Doi8Z4kVuG9fd7x',3,0,7,9,0.050150,'Drywall','none'),
(2774,'entry','qrNGRRegh6mr4sh7gp524m6wKvbtenyhPntKsJjSkJUH',1,5,5,9,0.031680,'Ledger Green','none'),
(2775,'entry','3fdx1gdZeofR24Rq444NWBATtKpLgAo335rPBtKSiVXb',6,4,5,7,0.042920,'Manila','none'),
(2776,'entry','bcJtm9qeUNazoi9iCY5fqEisooLhd8ZX9gvkxwLKrYEm',6,5,3,4,0.044000,'Breakroom Sage','none'),
(2777,'entry','k9XyG1mkTAQHGhqnrmVT3VmgnCfFr7WqoQa39Fw9Mpso',7,3,4,0,0.063180,'Toner Dust','none'),
(2778,'entry','yk7j431nHJct6zXWw7vNBzogHcKDVgq2ipiqETNMd79a',7,6,7,2,0.049880,'Ledger Green','none'),
(2779,'entry','W2nK3dwdWBJpbrsC8NiozMu9gh3ozMxKTwtPpADxAHmN',5,7,5,4,0.040000,'Toner Dust','none'),
(2780,'entry','Gjs5CNCRqz4kU43G9wpeRGFncTpeEBPuYM72gT6VS7Lt',1,0,0,2,0.056260,'Toner Dust','none'),
(2781,'entry','eaNUk13quKHsfHUnRTtmMcXtnYt6A4JCVYxpgegPC23t',6,1,6,0,0.022720,'Breakroom Sage','none'),
(2782,'entry','5Co8xG9BsmbkFxq3Hg7gCyn881sUsYCEYJyPPt4yjGCM',7,1,3,0,0.039600,'Toner Dust','none'),
(2783,'entry','wakVtLtQLrZndRSTHngDbnGgHhR7pSYvNXWDNVNVhwRg',6,4,5,3,0.039530,'Cubicle Slate','none'),
(2784,'entry','XT2WVUJb9xLAQ2rxpibsYZoQnjvf7uNcGRPdXLAnELW1',3,9,3,4,0.027720,'Toner Dust','none'),
(2785,'entry','9zPJF9rbeiTV8A7LfcxpmXnYurZ5vGY9x7TJX7E9gsX5',6,3,2,4,0.031200,'Breakroom Sage','none'),
(2786,'entry','GVvjDFUiFWQssR18vwR6fwAGm2wxd39ViSAvtCsLa2Xh',2,2,5,8,0.066740,'Cubicle Slate','none'),
(2787,'entry','rHXWxXCRaZjojwQHi2w2FY8i7QWaTEPnpV26WH5o3SSM',2,1,3,7,0.031680,'Breakroom Sage','none'),
(2788,'entry','zSxsjf8WcYFQ4JFVJsqjZvs4yECrVJk2tVPZVCcU9bHB',4,4,6,5,0.056260,'Filing Grey','none'),
(2789,'entry','7PfTfhGXXyZspsP9Y7uLP9YZJqmfZtfz7nbahBBNkKbV',1,1,3,9,0.040800,'Cubicle Slate','none'),
(2790,'entry','n3cs3KRfaEiNJ8Uk7hnYpmkCB9XF21v6VGmkYuZqbhSq',4,3,4,3,0.045880,'Cubicle Slate','none'),
(2791,'entry','JpFcsYRxakPRQH6eLjviCKBJ7Pi6fyE94EYoESCgox6z',6,3,5,0,0.038280,'Filing Grey','none'),
(2792,'entry','UvFLdkZvp1k7EMF3KXY5SkGrW494hBwaT62QJWn8gUtY',7,9,6,2,0.031200,'Manila','none'),
(2793,'entry','bD1hvvt3A8AUm1GbFnugZoqhSRFzJVQMrRMV6xLuXZuA',5,3,7,7,0.049770,'Breakroom Sage','none'),
(2794,'entry','i152NXSPoSJip53Ak6z7h3aXuwAWPc5vzWQp4itQGM91',5,5,7,0,0.031680,'Filing Grey','none'),
(2795,'entry','BTPwMf6EgXhz6ZS4CEpNFGVRHZAKgYCBruATUVNaLhvK',3,6,7,5,0.042340,'Toner Dust','none'),
(2796,'entry','YekUeBychpK8zyDRsDezcbf2hr7zoWjoiEbWUoAiRmxM',4,5,0,3,0.032400,'Cubicle Slate','none'),
(2797,'entry','xQr3yxJtXHXK2e7GfWE1JFzZP2qe3vxr65aiCdaBKTdj',6,1,2,5,0.090160,'Breakroom Sage','none'),
(2798,'entry','ksZdXnpFM7MqTp2tZM3mE9KR8mV5sR8GW65N2BuNHnNa',6,6,1,9,0.031240,'Breakroom Sage','none'),
(2799,'entry','HQViZAJGE2SmFE5YYBgoVaAaxiAF2RYc8LbBTC8F5Pmx',1,8,4,0,0.036520,'Cubicle Slate','none'),
(2800,'entry','5VEkdcjxvUczYNUMWCvLku1xiEuZaCcMoBVB9vdpVXmC',7,9,5,5,0.042680,'Cubicle Slate','none'),
(2801,'entry','MUsiRF8iR3LYg9WbQUCK5sphnHKxtMWfMKL9F81GhExj',0,4,3,0,0.065860,'Cubicle Slate','none'),
(2802,'entry','SXn6ybxZ85Hn8zhZWX9PnqkWLzbzQ2uPfov4woHyJnsS',6,6,2,4,0.030080,'Toner Dust','none'),
(2803,'entry','BFZFmVaxnW4xMLX2VXntBLjid18pkc6MAsB4QiNkNKuf',4,2,3,6,0.078200,'Ledger Green','none'),
(2804,'entry','s9oWcu4naZ6dV8tUMKXmXMaMNb4XmCHrLALTnCazc5xB',4,1,1,9,0.040920,'Drywall','none'),
(2805,'entry','GAksH1smQ5r66HnpPWd938CNUEoGJq8yaFEGMKJ4GhcH',7,1,6,9,0.048990,'Filing Grey','none'),
(2806,'entry','FUzqCpHfbs4Z9hc1SjB7JcEcN1iwZfy9b5PeqkgHJXYN',6,8,7,8,0.037920,'Cubicle Slate','none'),
(2807,'entry','14XNcDTGFuSUEsZrnAQA9GH4kmuFG3w6Y8QfAHxGsHSW',6,9,1,4,0.034320,'Toner Dust','none'),
(2808,'entry','ERthrX3Aaq2gnCK8dbEksHiNtuthLFDBZE4nFYjyCLuV',7,3,2,3,0.056800,'Toner Dust','none'),
(2809,'entry','bYoo9aXkk412fUgh7hpvBY8KauDkqzw1zUwX7HNJTf1K',7,1,2,0,0.047840,'Filing Grey','none'),
(2810,'entry','L2d7bh5H69apeY9J6WcCqAYHxGFXrN7AH2Y2eYfTUfg1',2,0,3,5,0.047880,'Breakroom Sage','none'),
(2811,'entry','hjneniCyv5PcTxD1sx9E6jBdGbN3bVpNyWXtGLiuRh2z',6,6,4,0,0.103320,'Manila','none'),
(2812,'entry','sP4KBrb819CurjSsZc7d4KzSChzsdDKr4hsqVZVQUsRc',0,8,1,2,0.068080,'Manila','none'),
(2813,'entry','g8L78RN5jyvuZfJbN6nnbmUBmPeZSfrfZQzjBvGS4yjo',2,7,1,3,0.037600,'Drywall','none'),
(2814,'entry','wCP9mdYy7YesX9Vbv7ioJxCKq28paeZthaqcrZWbwPaf',3,0,7,2,0.047320,'Ledger Green','none'),
(2815,'entry','WsjFQAPcU9JPubdsi5zv4txrqGFfdRgP8sENtLqtxHmQ',4,6,2,0,0.042680,'Ledger Green','none'),
(2816,'entry','MQ3mRx1ie9RGk5S3CY8NczHpsTkQRknkWjXVxZ6F59Td',3,0,0,0,0.047200,'Filing Grey','none'),
(2817,'entry','3iaYrPgc2pfdE4znts1X9wCwQ1WqZoXUMcSaYwTH5DuS',3,2,1,0,0.042240,'Cubicle Slate','none'),
(2818,'entry','A6Az1kQm4JSJeWSyAvfajdxTivfphyW9HWUJxLG24kNB',5,4,0,2,0.047040,'Manila','none'),
(2819,'entry','p7i4QCizngs54MRWu3d9GgYAT6ESSotUZkAKG51gX5i7',7,3,2,9,0.074520,'Ledger Green','none'),
(2820,'entry','Z1RJZQwsyCmDGTxkTKGhwpxN1FuXx69Lxuj69d4zwrDD',5,1,4,7,0.089240,'Manila','none'),
(2821,'entry','RBdhti6tjnpJCkoJNPP5vFANHQ9Z8mXxw7jhxb8L2AcU',6,4,2,3,0.038280,'Toner Dust','none'),
(2822,'entry','xikLrqCaUtxHB9SosFUDGKrsRYFV1WLZR5TyrmeSLZYS',0,2,6,8,0.052000,'Cubicle Slate','none'),
(2823,'entry','S2JvrCwTaiF86DEw1vXJLwkwtgBYsyDYFoKhH8zDCjDX',3,7,6,2,0.087400,'Filing Grey','none'),
(2824,'entry','6hBAXtQuw4jzvu6uNdqu44cLynkZyyiYvY1GPEgcLTaM',3,2,6,8,0.027280,'Manila','none'),
(2825,'entry','7zxTB5eDKoCQ7vf9BeJGrMgabMPpqtqnq29URhP7jj5L',5,8,3,0,0.041760,'Toner Dust','none'),
(2826,'entry','NdnRJgczjBYCMmpHrFVh8FZw9hpDPzWcY9tx4PqdXAaX',2,1,4,0,0.030820,'Cubicle Slate','none'),
(2827,'entry','1M9gcA5pPFvKfQuznDLUTYDiwch3x1knLTH4r2bGQe5m',4,5,3,0,0.052780,'Breakroom Sage','none'),
(2828,'entry','gRMoySiAhFnmkrRU3iw85eHxt2XfJ8ypmxpYTv5sCjGc',7,7,3,0,0.033600,'Filing Grey','none'),
(2829,'entry','M9yDWP21rB3LE8GRPxuTRuJhNDfq5VYw2W18KjiFMjuB',4,7,2,6,0.058460,'Filing Grey','none'),
(2830,'entry','enTkDX9fPccnprRTNS63KqcqdvctkYK2mMnPy96LvDrg',7,6,3,0,0.029760,'Toner Dust','none'),
(2831,'entry','e91T1Eb3Ne4DSQZurZhqgJeVao1tXFrFYX562qYEypUu',6,3,0,0,0.054670,'Cubicle Slate','none'),
(2832,'entry','PfPULLpKft2Rdu5aKF4FAUF2fenpug2mDPdqecPq7h5F',0,7,7,6,0.035960,'Cubicle Slate','none'),
(2833,'entry','cLMhBQoQYwymvTkPJzmbQ8sZJxLwpgAFsPgs2zNtXAce',0,7,7,3,0.047560,'Filing Grey','none'),
(2834,'entry','SkXSB91ZbGdowEBjyYee3wdTCAVuhTc5t78q8SgWssqQ',6,3,6,3,0.062370,'Toner Dust','none'),
(2835,'entry','BgjspVRWAFvKZTbaUaTNVcJo54y2SjZJ9GZzJrhBAfTW',0,6,5,0,0.035200,'Drywall','none'),
(2836,'entry','KQmcfgD68oCru6wESRV4GoDTraznGihtUkbcBsFsZc4Z',7,3,1,8,0.031720,'Manila','none'),
(2837,'entry','zH9p67KzQuq3rozPEZhusp3te6HY4nWSQUMa8UjF2vj8',7,5,0,8,0.047200,'Cubicle Slate','none'),
(2838,'entry','5gPrXMRFGDsc9RsCR6MXM5qfCYCh1bqKjExJHyw87wvX',7,8,4,8,0.048280,'Breakroom Sage','none'),
(2839,'entry','jar2gr4BMSeQAwFsJQnAq1RTbuQMWmp9dPZUNN5DfBxD',5,2,3,0,0.048000,'Drywall','none'),
(2840,'entry','85tuW1pV6YCi9pPHgDNBd3Uy7WMgDx3tWZZ7JpVetASv',3,2,2,4,0.050740,'Toner Dust','none'),
(2841,'entry','m5i6mLAFsyVqFUtv1vji5jz7HkebYv92yfbgULh779dY',0,6,4,0,0.053250,'Manila','none'),
(2842,'entry','zizBawN59RwRqkcPzD3oAysJn6r73X5hgAf1icDiWa3B',3,8,1,4,0.043560,'Filing Grey','none'),
(2843,'entry','3bEr8k4cEa35p35koJeiVp8BWysE4vyXzDHZFr7nLdqb',6,7,4,8,0.039520,'Breakroom Sage','none'),
(2844,'entry','Qw1Q2dbNLG9ZGUCm5QHfzYezwomNH2DNPuWnsDQt4bCc',1,0,6,9,0.039440,'Cubicle Slate','none'),
(2845,'entry','tF9qG6U7qq7shRmjmM7irAp4AAECg6gawjsXn5nsMmke',7,0,4,4,0.042640,'Filing Grey','none'),
(2846,'entry','Hd3kWXQfnwXA6hzutkpzUvUYkaiXY4rNHz5tUFBLK75j',2,0,6,0,0.030240,'Filing Grey','none'),
(2847,'entry','iXSyv2cwtiHNjB7Ly65ED2ufrB2vaEMZAk8zS1vXcHQi',4,6,7,0,0.054670,'Drywall','none'),
(2848,'entry','m7kqMEK9o6Z48GjqSvqhfhAkYSs7egPTeKP1TcPkSZfo',5,0,2,9,0.042680,'Breakroom Sage','none'),
(2849,'entry','zQRSqcR7S6WVcq3gtwE79SUNFYc4REYrahRjgmC4PTmf',1,5,2,3,0.025600,'Filing Grey','none'),
(2850,'entry','hfFsJPVNgz4Vu9jwpPWp4YAzemg3EhDkQzK3G2NK6Gog',6,0,5,8,0.038860,'Filing Grey','none'),
(2851,'entry','gt92eJDrS9R5aDcbupdsJzGMM8LhbWLdJMiA8SfzSN5S',5,8,1,7,0.039600,'Breakroom Sage','none'),
(2852,'entry','ofyT7rCxVsEutAL1L5Lt42X9FVhTSKf9zi2Bx9hHiHbi',2,2,4,2,0.035990,'Breakroom Sage','none'),
(2853,'entry','DmS2LWDC2Bx1aKxEbj1WAZR7nNhxEW674YcupVPTQp8t',3,8,0,9,0.087400,'Toner Dust','none'),
(2854,'entry','DpFYBR7GhMC6hiPFCmTME7wSoJLoZSXp194BfvTpxLop',1,8,0,0,0.037440,'Ledger Green','none'),
(2855,'entry','kd18GDfX3aAQMYHnB7XfwREPxUsyKm2FF26oMJ88AhUT',7,3,5,3,0.068080,'Manila','none'),
(2856,'entry','tgJzNdAJpd51MSunVGmdPkCvnoyiMh8P1YQXwLdnNPbo',7,9,6,0,0.068040,'Breakroom Sage','none'),
(2857,'entry','qmBJdMWFQUDmcxi6vUQZhxLzVEKchPHFUpuM7LPEY1Qd',3,2,5,4,0.019200,'Ledger Green','none'),
(2858,'entry','15r69BrqkY1zqHjJWuk7Sm9AgCW9gFREgwjN7cdZh7Lk',2,4,0,6,0.126000,'Ledger Green','none'),
(2859,'entry','Vg2RUDM8yt6KVgxoApA6jdRKGjGsor7nSMDwmmzF2bBi',7,1,6,5,0.047200,'Ledger Green','none'),
(2860,'entry','iHye1swHPYEBoKpaCftehG4KS8gbUcy9qzy8WByb4VEd',6,3,2,4,0.023680,'Cubicle Slate','none'),
(2861,'entry','QTwmLVHqbRxQe4fa2CLZM8E99fjnnxLj2qpvXGQzrUV3',0,8,1,6,0.045990,'Breakroom Sage','none'),
(2862,'entry','db85tYNZcG4r9yBbyEYYNZX3iVnGn59eSVdX3Ldwbxfk',2,2,6,5,0.064380,'Breakroom Sage','none'),
(2863,'entry','LvRHWtLzSQSgnW6XNEXvkthNzQTXp6TFA7fVspxWRsfa',7,2,5,0,0.031680,'Ledger Green','none'),
(2864,'entry','HzzLundhd6XcrRjr3MVyCECcrYGcZLCwHTdQ96gYcV9n',6,9,7,4,0.040000,'Toner Dust','none'),
(2865,'entry','ehRPu6eABxdPTB4RFn3E4qemGRCUPF1558X4BD5E7mHz',3,9,7,9,0.054180,'Drywall','none'),
(2866,'entry','Cb7uyNz6eUr5pCCpqBFAUsAex6GzcThcVrxSXo85bLfj',1,7,6,4,0.048990,'Filing Grey','none'),
(2867,'entry','XFptj7KEwscYD5AqvwHBXYiPLPb7g97yFDPwxkJv9XN9',7,4,7,7,0.111390,'Drywall','none'),
(2868,'entry','Djf966Y26zktzSzpu9E6nw753yKWRqmpYuAq95ESUpcr',5,5,4,5,0.038400,'Filing Grey','none'),
(2869,'entry','sGos2B3SbCN17SaFJdsdoUN9g5B649fbjQfX38sjFcf9',2,2,3,2,0.029280,'Toner Dust','none'),
(2870,'entry','LJFGwqAdhZfAc4WzLB6mtFH1g6CGHVjyvkM8RMwmY2nG',4,0,1,0,0.036960,'Toner Dust','none'),
(2871,'entry','AUPxCMrkYYkXAu3SZoJjrcZnp3Z4xNovTikVF3JMbyyu',4,0,6,8,0.037720,'Filing Grey','none'),
(2872,'entry','myT3b3An4UYZuoBBnqPqeJp5XtpB2rN64xkcqAot5tyY',2,7,7,7,0.044020,'Cubicle Slate','none'),
(2873,'entry','xVGERd9oRnr7PMPwLcu1PGaDpZTLNtpjZZLKND9wTDgE',6,7,4,7,0.029200,'Toner Dust','none'),
(2874,'entry','rybo5G43yEgCf7sQyZKxF92rkMKQAsoT9gsstgAWyPXs',5,2,1,6,0.036520,'Toner Dust','none'),
(2875,'entry','XFLkF3iqbn8itsLbN2YHx2onFiWSJnCUPhtmsb29czaC',3,3,4,9,0.040950,'Filing Grey','none'),
(2876,'entry','6Zgfmi3Yy7LmUgXTTLZM4QaPkA4AfVz4o78ME51DLHA8',4,2,6,9,0.050960,'Filing Grey','none'),
(2877,'entry','cstHaWA8Dkgiiq6J1caJUo8VcCUuAj86X8UMYZTZ9vwD',2,2,0,0,0.050400,'Toner Dust','none'),
(2878,'entry','u2wsKFtptpDJ5dDxvB7j7XVf3qr2g475eiHGCYTYXd9K',2,4,2,8,0.112140,'Drywall','none'),
(2879,'entry','ZBCnWtrVeJAZ7BBSqB2QHcbXtbKJf7v1oDngz1MUCDgV',1,0,3,4,0.023360,'Manila','none'),
(2880,'entry','G7D9ZFmV7d3Qar7JgMZVYjuQtT9diR16189UM42g9vmq',4,3,1,6,0.038940,'Toner Dust','none'),
(2881,'entry','a3Sx9rqLvdr2TAeQ7PpWX74t5vcqxwE7PrNfZZCzCMom',7,1,0,8,0.057720,'Toner Dust','none'),
(2882,'entry','vkrgVFAZEWUDRS8fKoYJ1GjNkRSgiYoTscEz2deMWbfh',5,7,0,7,0.046150,'Breakroom Sage','none'),
(2883,'entry','eDtVvFN12Skp5NAkm2URvvw4subZJVRLApUjxu5KhJLY',2,0,3,0,0.041280,'Drywall','none'),
(2884,'entry','nna97v4wuudSsu9csu7oQMsgWwErUtwX3Gt2eDQeQsdr',2,2,1,7,0.055680,'Breakroom Sage','none'),
(2885,'entry','DzmH5iFrSKNvB5T9bhKsfJLN2SidpBUeTLFqycqnf8SB',0,5,7,5,0.025600,'Filing Grey','none'),
(2886,'entry','m5UChKzMMVs43Cih4vHbfot1WWVWwafbm5fBP8y5dy9R',1,1,0,9,0.043500,'Drywall','none'),
(2887,'entry','ntYXngQcwgq5QshxXbyWfqqW8gvUAAcaYGRMBdfSWt4C',6,2,4,8,0.047790,'Breakroom Sage','none'),
(2888,'entry','RSk22zwfej8hsSwQtNUR4kdzhj6i5xeMTmT44SmNh31C',4,2,4,5,0.050740,'Ledger Green','none'),
(2889,'entry','k2uBfMN2ZYetrrwc5sKLbv7qQJW9L5J9XziMnXX6Cnnh',3,5,6,5,0.046980,'Ledger Green','none'),
(2890,'entry','QB2PmUb1AGDhrhUWHGrVCdYTzVAQTSmV124G66AvsWMp',1,7,7,6,0.037720,'Filing Grey','none'),
(2891,'entry','F2CE7u88estq39Rag2bvW7A1EsaDEzHMPJJd1LvtKcjh',0,7,3,4,0.059940,'Breakroom Sage','none'),
(2892,'entry','fanKhnrVvMA3YwvDVRemL7XFPqwiMK1ahob6MdSBHG6u',6,0,5,8,0.118440,'Ledger Green','none'),
(2893,'entry','LFJnRYcEmMnv8Gr8phwKSbHZMAkYojydQne4uahUckcT',5,9,0,2,0.101520,'Ledger Green','none'),
(2894,'entry','fq125TWmbJLKNtWQSGWhUeVSuHKcaRR2cHwAUDyUaQse',3,0,7,5,0.026400,'Manila','none'),
(2895,'entry','uFoVBMg2M9pP5m4BZw44pjzCeGZQWmExeEef7X5atpRU',6,6,6,6,0.034080,'Breakroom Sage','none'),
(2896,'entry','BLve1rXLTMyXMDkakr5AaJudrwXFdMVRrT6VftUbvcok',2,1,4,7,0.044730,'Drywall','none'),
(2897,'entry','9WtVQD5En4cb94f4RRQdXGQZv3m52C9WbxVhJ1w74pwb',5,7,1,2,0.029760,'Breakroom Sage','none'),
(2898,'entry','3CChHJ6DXpVLSigtRxBe8rQJhTYUEmDnr5yZZ1g9P5hK',6,4,1,2,0.048380,'Cubicle Slate','none'),
(2899,'entry','d8qPLawomw9ZzEXejTc7GyTdfbKnF2LL1Yqu7A3zuKC8',6,4,4,9,0.054810,'Cubicle Slate','none'),
(2900,'entry','iQxNMGW6bBWrmiW4J6jByGHh4mTGUj9U2xHxERygjnT8',0,5,2,3,0.031680,'Filing Grey','none'),
(2901,'entry','kN477tmFpScEfDVqdvmX62zpiNz84KULtjvPznMeFTxQ',6,9,2,9,0.041760,'Toner Dust','none'),
(2902,'entry','KvKu4yjVVecQw41vmW6zJXEzcy3dcWRCoAF3qScApkeX',6,2,0,5,0.040200,'Toner Dust','none'),
(2903,'entry','SeKJWagwTVAxnDntWB3i3ebMpmwcyB2RGJTrjBjh5jvP',7,1,7,7,0.077280,'Cubicle Slate','none'),
(2904,'entry','VDiM3G8Pdhfw1MxDruwu9Tiox5qypxJ9Xa2SMif78CUX',6,4,1,9,0.039360,'Toner Dust','none'),
(2905,'entry','5XDhzk3LTTeFhZN1wvGCS61x8YgPbAna1Ysuo9baerNb',0,4,2,0,0.030800,'Manila','none'),
(2906,'entry','rR8PaQBCezcq1htj3bqS7rqoCPrPZ5xkfcfrS3fV2bMw',3,0,2,0,0.060750,'Toner Dust','none'),
(2907,'entry','g5X1z4gF9VQKf1ms1kg2JmP4ktWxRQSrMec1KVQfuZ4w',3,6,1,2,0.057510,'Cubicle Slate','none'),
(2908,'entry','UYdjK1TdoMr1FzNr9gcaw1GgqUQo1uUAvodF9SSnpd3Q',2,4,6,2,0.037840,'Filing Grey','none'),
(2909,'entry','jRUPvT2dVN1Rk2qz5hYfkMuDLXo1uhV1xsE53KknyZ1K',6,0,2,0,0.117180,'Drywall','none'),
(2910,'entry','goQCojZZt188aFgvcog4WsroAHqwNqD1YoPt9QxXHdGz',4,2,4,0,0.052920,'Drywall','none'),
(2911,'entry','3wpW6k2tYuJZCbnBWEKwnGCeNs9vq9Kxgezni9QQbxDN',4,1,1,0,0.044250,'Ledger Green','none'),
(2912,'entry','3UtporyzVvHx13uyB7oC7pK8Rdgwn6GHHeZy2qQedEmx',4,6,7,2,0.037440,'Breakroom Sage','none'),
(2913,'entry','D8GEz2CkPzXFLPqWHL7xDZgPRW5ZHdCrbJ521iTvpqUb',1,2,6,6,0.042240,'Ledger Green','none'),
(2914,'entry','R3ydzmmYA1XxXmw8N3Rp4esV1T7hoHc6icdFhDvfnYfV',4,8,4,8,0.022080,'Manila','none'),
(2915,'entry','sfHac2iBcQuPHkwkzX9U8tVaduVnSeVc1CrDCa4Nnwsn',5,8,0,5,0.036540,'Cubicle Slate','none'),
(2916,'entry','cJRFRf5zAvUgcUfUmS1zZDLRWswCiEAQTCppLLxZrxeC',1,4,6,3,0.039690,'Breakroom Sage','none'),
(2917,'entry','mSVpGqw9R9t4YVpT2F1W5CscnGJsCLFWR1noUCqcqbzE',3,4,5,0,0.026840,'Breakroom Sage','none'),
(2918,'entry','7EGk4kggGf7Ns7mbNNvJAxzpz6PcLhCzt9taxMrxjsHz',1,4,2,6,0.045240,'Drywall','none'),
(2919,'entry','RiwEq44wib9JgK7X9ARNSx93ASDep5pYU5Ga1YeVDhW6',4,5,1,7,0.037720,'Breakroom Sage','none'),
(2920,'entry','cEssyFDBPudrfMSWcwy8uqNVTiKgPbVLu5zbFR8yfE9n',6,7,6,8,0.095880,'Breakroom Sage','none'),
(2921,'entry','eaKiMQD7naFhCJHhKXf6JvqiDnZSvYvvaWijBPWxjqo9',2,0,5,0,0.063900,'Breakroom Sage','none'),
(2922,'entry','Q7jfebgpsifZHmfY6nSwb9HwGKgeo1vJ1ERPvWWETwEe',6,6,0,7,0.055500,'Filing Grey','none'),
(2923,'entry','TfKv2YkVAM4vVrPPW2zLYxxkNfcrTjn6X7MiwAXyemAh',5,2,4,8,0.123480,'Filing Grey','none'),
(2924,'entry','k4R9RdXEfZpfxRksP8fPRte5RD1qugdNjbX9WaVYitYk',4,9,6,6,0.041760,'Ledger Green','none'),
(2925,'entry','uDD9LCuwMfd71vknGbUtM9j4SQC8H9bsUB3wY7zR6C3T',3,0,1,6,0.063900,'Manila','none'),
(2926,'entry','SLRu3uYKmdGbCs99eje62U111gfDstxV7HGpms3oYLso',5,7,0,0,0.035040,'Breakroom Sage','none'),
(2927,'entry','pYV6Ju98AgR1EguPMXU15fEP5uCPC1rrWjTRF19LY1gR',7,6,0,8,0.038480,'Ledger Green','none'),
(2928,'entry','rUarovja9Xj7ngC4ZLErEbch7EDwW9k4J7kfJAG9M7JT',3,8,1,0,0.036400,'Toner Dust','none'),
(2929,'entry','wHzz2YtqHrNwYUBsgofWnNFi5uAu2rBH4SJ325QwMfSY',2,1,0,9,0.050740,'Filing Grey','none'),
(2930,'entry','RcRMkA1cwuyqrJtNqXPxu3GkjkGqoWYNTdNDkKskV9yA',2,1,6,8,0.036800,'Drywall','none'),
(2931,'entry','XWxqNXEfokFzX8ZZJkso9SAcXHq89NKxMbRCw4bfkKhw',2,8,0,9,0.039600,'Filing Grey','none'),
(2932,'entry','6jZ7tVgjcmh6XGFDGqmP5FroNkGWAGqwL6giQh1BuhbS',1,6,5,6,0.050920,'Manila','none'),
(2933,'entry','WCauCAwtpK7LqQ598HgL41CzFZRybjPJhvgTpg4KTfCh',7,9,0,7,0.049300,'Filing Grey','none'),
(2934,'entry','Z5B6x1GFPitwWXQjjuuBMUjvR2zoTXc5B4PEFxKx29Mp',3,3,5,6,0.023360,'Toner Dust','none'),
(2935,'entry','qfW1o5HB2sqHparWtkRqzn1ofQk8jcMC1UukR9i5xMih',2,7,1,0,0.078200,'Ledger Green','none'),
(2936,'entry','1XSW8UL24tjA68F76x3e7yMjkVKxHoMd5sDvKK2r7Jhj',3,9,5,0,0.045430,'Cubicle Slate','none'),
(2937,'entry','7U7PGPr1HpC8xaWaronjHqdr4kJVSTWJzBbqgQuQqeMA',5,4,3,0,0.046080,'Ledger Green','none'),
(2938,'entry','8Ztu66YZQaWCiU9QGhSB1seFByKAeqeKGUSNnk2sZcvN',3,9,7,0,0.049920,'Toner Dust','none'),
(2939,'entry','Cpa69MhBingsVqC8zFmnSko7ADbhAiCr4NQxDw9xiHwx',1,8,1,4,0.057330,'Filing Grey','none'),
(2940,'entry','zJNsDXG3ky2tgxLtcyMivpf6xqcYcvyEW8tvcBHKEp86',5,7,1,8,0.031600,'Filing Grey','none'),
(2941,'entry','dEgucgnB4fag9SDA1wT1kTKnyLKST6zm4vANZqGN11MF',7,5,3,3,0.048880,'Manila','none'),
(2942,'entry','TLyxVePrQEac7BHFGLYcrbBNf2dZVKWaiup5u4HQtKir',6,6,4,5,0.048000,'Manila','none'),
(2943,'entry','2387MZWnX32Qbu96zyB3gwW51H63Ens4hhag1k98HDMU',5,7,7,3,0.054940,'Toner Dust','none'),
(2944,'entry','NJStM2egRL15ZrP6MzCH51ucyXYPNbSiUmKGt52UYDY8',5,6,1,4,0.055100,'Toner Dust','none'),
(2945,'entry','votFyhRDywtRSDPeP7aWZ7ejyyjuJ9iuNgCCkix2uu3X',0,0,4,9,0.049580,'Cubicle Slate','none'),
(2946,'entry','U8PEiKrJR93BNCFd5PDn2YmHgiXW5oHNMLNA2sX3HHR2',6,9,2,9,0.090160,'Drywall','none'),
(2947,'entry','HohM7hPdjw2GCpfzbPS1VVRou2drzD1MdXre7VcXs78j',5,5,2,0,0.035880,'Toner Dust','none'),
(2948,'entry','TbMnaB88VBdJBN2x8N9wWMQk77xXtyRA4VCEgQ4cpjZ7',5,5,0,3,0.057720,'Breakroom Sage','none'),
(2949,'entry','GRYP8UfbXoqRGtkeJ8LjzacwziVVi8gjYtXDEGfymDU3',1,4,7,8,0.063990,'Breakroom Sage','none'),
(2950,'entry','xHcu8UGxyXKr9Jgb2pvGHYNAYTEMKEcsHj8ZmkP9Yrhg',3,0,3,4,0.040120,'Breakroom Sage','none'),
(2951,'entry','5tYdqgGJ2LPsv96KcdKNdYyEFyvcut8CRNVxTLa3KyZU',2,5,0,3,0.039060,'Manila','none'),
(2952,'entry','FdEUD6JuAKWrBjxzW1qmrDczj3xVdSTCSGdiYkg5xT64',1,7,4,5,0.034960,'Drywall','none'),
(2953,'entry','XUJfGPbyDQzx2y87rTBW3xcCsZQiWXP9eErKgwhncvWJ',5,8,6,3,0.058320,'Toner Dust','none'),
(2954,'entry','h2PD786jZSLNwcpJqivc63sWHqr3SkP9cud92i9wesYB',5,5,6,0,0.057330,'Ledger Green','none'),
(2955,'entry','6RBwR7UpJ5n8Yosf2CrXQjgmUcQx2p9cncr5MfXAcUQz',7,6,4,3,0.028160,'Cubicle Slate','none'),
(2956,'entry','QwHujFsAr2HqrvWMDZd3eogTFSFhzCAieCAUCPfcxdUU',3,1,3,0,0.081900,'Ledger Green','none'),
(2957,'entry','UBfXSrLtDqBUAabcpzpDTodppFPNkbtCBVZQARoGtxbL',4,0,6,6,0.043240,'Manila','none'),
(2958,'entry','BW2kwFiK3CF2Kz45GkzKCYqLojFkFWfdrm17ZdvP7wFc',0,2,2,4,0.064990,'Ledger Green','none'),
(2959,'entry','pQ6TpPc9SaNgXa1jUXUxupVxTcp7oeko7ALTwG55fqBV',7,8,2,0,0.052650,'Breakroom Sage','none'),
(2960,'entry','mQPUDnrUv3UGmkWD2NwNPvsbdHgPapYYAVR4p2ousi4V',7,5,4,7,0.028520,'Ledger Green','none'),
(2961,'entry','Ab4tPMGwYpEecAK99YPRDNKwmKoy8Sjeq9N5bGyN1f1h',2,8,6,5,0.060300,'Filing Grey','none'),
(2962,'entry','U6qiQiPaF445FJciWtpCa71A9zE4e7Jugr1jUJMi8cuy',0,7,7,3,0.066420,'Ledger Green','none'),
(2963,'entry','aq4dgHPVyPdxBLe9mkC7c2WfDFAQ1NtAsCqxYsbTEHpQ',2,8,2,9,0.064380,'Breakroom Sage','none'),
(2964,'entry','MvwAGgd1mZojNb9BhMJ57h67NPpxEfoSyi3aPGYjeSd5',2,6,0,4,0.047570,'Cubicle Slate','none'),
(2965,'entry','GnRiA7oHyUYx1jE3iZdo6C8LEipufoLiuaziwWBa5XRV',2,1,1,3,0.062980,'Toner Dust','none'),
(2966,'entry','5sPkubwhbsyufco2KFWj6cEc9UjFiZMPLXuZ6ea2BPSj',2,1,5,8,0.030400,'Breakroom Sage','none'),
(2967,'entry','b14aXFXDg6e6GyrZQCXHFwTzie2FNCNnChFJyDbvPhLH',7,8,4,0,0.051480,'Breakroom Sage','none'),
(2968,'entry','wYZa86bi3tcztTCP8GBbEpYnnaQpaH88ST4XRVVQu2Wm',4,5,2,0,0.049920,'Cubicle Slate','none'),
(2969,'entry','1B8qiwNcLenVPd51uy9CwiGLpPXtVcgBizmDGUTZcnqz',1,3,4,4,0.068160,'Drywall','none'),
(2970,'entry','mX6UDYZ3TuUrNUykBrJC9pn2db5CsZbExP8XWHeVuDbN',3,9,6,5,0.051040,'Drywall','none'),
(2971,'entry','DeHxMzPf94xrcibj9x99oCT4oNYZC5aWNQ9nV3TGdUQR',5,2,7,5,0.046620,'Drywall','none'),
(2972,'entry','UShWRrfWwR9FirnGLWXQ9AC4vgfba3MUxbU3Uh45d7sf',5,3,3,5,0.050150,'Cubicle Slate','none'),
(2973,'entry','WS7RcLSGMeiMF51xyPJ9JF3XQwpVZCm4wLbTkkYsZtTE',0,4,2,5,0.042640,'Breakroom Sage','none'),
(2974,'entry','RnpuJMpdTDX3TWfDYm4SoPXJiC4sMcTgeqd6WhznVA5C',0,0,2,9,0.030400,'Ledger Green','none'),
(2975,'entry','qSsZrwx5nsnEKm37gofAUt6Vz7UKZ4xJ3NvxMStBPZDV',0,3,7,9,0.029040,'Manila','none'),
(2976,'entry','d55VHAdiRgr96gTDy6yV9PzWnpYgm5HTKYSC1CLrSGme',3,7,5,2,0.050440,'Manila','none'),
(2977,'entry','Sj6ZsWubft3VNAXsxwkDhDwUzj4dJZf4qpSgghoQpmou',7,2,5,9,0.021440,'Filing Grey','none'),
(2978,'entry','juYVkx97SgXuanMDGCcq9foHCc1X7wZoEAyUCvDmAFwr',0,1,4,3,0.047250,'Manila','none'),
(2979,'entry','qTpJ2wfrrdXBmGGxHk6fVxYS5bGV7uV5hQjNdtuMwQJn',6,7,6,5,0.036480,'Filing Grey','none'),
(2980,'entry','f7hPnmstuAdGVJ48EEtKtuFAG4hp3kcNaf2dLZMwmGZg',3,8,5,7,0.043560,'Manila','none'),
(2981,'entry','47ranR2RFJkf8wGsQu4CuurAZLqTXnmFrJTJ461BwSRT',4,8,6,0,0.112800,'Ledger Green','none'),
(2982,'entry','7GiYfN2rmZpBFT1RbmbBtXnek3wMrdTSeaT4NXTtsBCW',2,0,6,7,0.032400,'Toner Dust','none'),
(2983,'entry','EcAuKajoac2ZGaBZQVP55k8gs564i4AnGHcYcggqk6Jb',0,8,7,6,0.065320,'Toner Dust','none'),
(2984,'entry','bHdGmNDE3HcwoZ7kfwUX9Xd3pUQajSZJ1PNBgs3srPMu',5,4,1,4,0.042720,'Filing Grey','none'),
(2985,'entry','7u7QzuMUk4g7ZtqfcQzAHcXXcz37yDmudQYSp2CYMwMQ',4,0,5,4,0.081880,'Ledger Green','none'),
(2986,'entry','9b52YkMCaMkNySVuPpPey9SuUs5wouxgjGAH6wM6EVhz',1,9,3,4,0.053600,'Toner Dust','none'),
(2987,'entry','a4VTWporSbsVAindvveuKFGRaDeFhgpe7bk86RpzXrXs',4,0,3,8,0.062480,'Manila','none'),
(2988,'entry','kQFBfJPBAehGdSxKgxovAxjcX9RGehkDiVifNXtks2jc',2,6,3,2,0.034960,'Breakroom Sage','none'),
(2989,'entry','znjWzi9kNcjz1TcePCPpqa448vGD5KtoFrTUCVyaXSMd',5,5,1,4,0.062160,'Ledger Green','none'),
(2990,'entry','1HwBGJQmmY4X5VphokD2bMsU5LFBNx1sfSjYXvNAvDhW',4,3,0,3,0.028160,'Toner Dust','none'),
(2991,'entry','UoSEBrbgowo8SpHkhJ3mBm7DADn3ZGkbeTSXkzoDcUEn',4,5,7,4,0.061110,'Drywall','none'),
(2992,'entry','HYiCQPegMyPGgG1aLs9RdjpsEYTfFxzLeu3bFcMztgR3',6,9,0,2,0.040120,'Manila','none'),
(2993,'entry','vwp8Zv5RF75ssgnu1TiCkA5GZEjXRZiisyXAhj9Wqpjv',2,4,7,0,0.026800,'Cubicle Slate','none'),
(2994,'entry','1Zt6tDHqwJ9wPkuKmAVNkCx4seE2XwM5fFPP38pC1Z9K',3,6,1,8,0.046400,'Cubicle Slate','none'),
(2995,'entry','qease15SpuM7iH5SHve4KDa5UXxNGoTMbFW5ePUrE4wu',6,2,5,2,0.036000,'Breakroom Sage','none'),
(2996,'entry','hKh3vYtAydQTvZLSzVBZboe3TFo3xy2pPTZve39r4YZy',3,1,1,3,0.041800,'Cubicle Slate','none'),
(2997,'entry','mhZAD3sMjEadi67PhQdRz56YXWZXAeSDPVjCUkFjKtr3',5,5,5,6,0.037120,'Filing Grey','none'),
(2998,'entry','AweGCdGMQDZoHwmdwaWp1Uy2r7ma7i9jE6xyUKDY2Y6Y',5,3,2,8,0.074520,'Breakroom Sage','none'),
(2999,'entry','4kRwn7RAfxkzHijbTrucQQ8rFDUAXdPvGutkh5Lkyw6F',3,2,0,0,0.050460,'Cubicle Slate','none'),
(3000,'entry','bYvgqdqimsgHfiBjfx1S77c25cRk4Si3wjAg88hwZhxg',4,7,1,7,0.050960,'Toner Dust','none'),
(3001,'entry','gnVbX3AAoDTCY1rvSGxV5zJerymgb8VgSzTQdTBqwA1G',3,2,5,6,0.055080,'Manila','none'),
(3002,'entry','c7GY94f5KAW7sawQ3zwyhH8nqoz7ikRsScBy8HmuQ2R8',3,5,1,8,0.051830,'Ledger Green','none'),
(3003,'entry','Tbq7cy1mAdonDoGRq9jBbBzqpBTuNZdFaTBxxdCAiRsk',2,8,7,2,0.027200,'Ledger Green','none'),
(3004,'entry','Wtviydv8j5CV8hsNsHg3iC1NNbLd1s1gdqoCWs3HserP',3,2,5,0,0.034800,'Filing Grey','none'),
(3005,'entry','ZszRrcf22RE3xMGwEUbb5WuysRvpP3V2At8gk9a535RL',3,9,4,5,0.024800,'Ledger Green','none'),
(3006,'entry','4VEJyQrPTrpnwVunsQrbA7rdTgryuBUk3z6d26x8umGf',7,5,6,2,0.032800,'Ledger Green','none'),
(3007,'entry','hEkcweRQGEjYZhpJtYELKiiBoHy4grvUqyVovJ9PKvdh',6,9,0,2,0.047200,'Filing Grey','none'),
(3008,'entry','48kp5Sd5GBs8yEMaTuTTYxBL3xGuVVfAV31Du9W1pNnp',5,8,4,6,0.027280,'Breakroom Sage','none'),
(3009,'entry','6qUUPAQr6xAzJqZAtyLfFJubmEwfzmbu3P83SJzp5KQy',3,7,7,5,0.024000,'Manila','none'),
(3010,'entry','Tka5Qzb65Wg8Va2VcZaRuzdHW3DRSPVBJzVM69RdyRX8',3,0,3,8,0.030400,'Toner Dust','none'),
(3011,'entry','hUt1LXSE3mdXbJYCGDgwvZHFXPhLZt7MRtLRPw8tKmWo',7,2,5,7,0.044220,'Ledger Green','none'),
(3012,'entry','hJRbNuykb2scurB8gYYA82UREEp6kguAHnyzrjkHvLBN',7,3,6,8,0.057510,'Toner Dust','none'),
(3013,'entry','RXzCnPX91VhhmLz3jedqe7KZd1casMp4puhtZ17JXTFw',1,5,6,5,0.031600,'Manila','none'),
(3014,'entry','E8Dn5naapkBXrNedtoxAtGoVUQVq59thxtaLvd7sU3Ay',1,6,6,9,0.052510,'Manila','none'),
(3015,'entry','YRNcmZvQ4HotSNkeVGDEz63zKtAX4iT9Zwaima8Fj5Y9',4,7,3,2,0.025600,'Filing Grey','none'),
(3016,'entry','6kqnuSmhBaqMNhhdeCxg6Xr4C4Vyy8B4XtYu5FGBscrb',7,6,1,7,0.031680,'Toner Dust','none'),
(3017,'entry','cfPvWTJ59XrDDzV4SSe5UH4b1vLKxYMmY5JQ1EhRPp6f',5,4,0,7,0.068080,'Breakroom Sage','none'),
(3018,'entry','GCk3HQMmnV5GybFJ6TwKbnorsLmYd9S9RekLtWAS5Rwr',4,8,4,7,0.055460,'Filing Grey','none'),
(3019,'entry','Uzi6BjBGmXBy8ebr9ZxFXucX1TAoSHMkKfCh6JfSUMqR',1,9,4,5,0.050440,'Toner Dust','none'),
(3020,'entry','zP4qXQQHvHAYUrAe7r4Ki8eD5N7b7EUAWdkUnFAcmFXA',7,6,0,3,0.039560,'Breakroom Sage','none'),
(3021,'entry','AzutWcgVfwnjqb8p2x7bCoQ4Fsjitf825Sg9NcymZzTm',1,1,4,6,0.043070,'Drywall','none'),
(3022,'entry','wvNk8gsCXmfTQRydREgGLHy39qrvdREEuCXxeCpcQLNW',7,4,1,0,0.034800,'Ledger Green','none'),
(3023,'entry','Kwsi4gGjESMWnUhj7AqRjPziFPChdu5k1tf2Vzm1FSE9',6,2,0,3,0.056240,'Breakroom Sage','none'),
(3024,'entry','HAkRedqHPEgnWdSGczYjZa5Hu7EDtWVY56GkNQwfuxEe',5,6,7,0,0.067000,'Filing Grey','none'),
(3025,'entry','Sepm7CmSSQMMgefUC6dtvEF8VSXECPnyER2pJ4LcVfjf',1,0,0,4,0.087400,'Manila','none'),
(3026,'entry','An6nuf48WQLa8T7HNbYDzS9SvJiHncfF9hvpaRJ7oqbF',3,0,4,2,0.039600,'Toner Dust','none'),
(3027,'entry','aSa7DyQDwRxfwTgctzkzQLem2DoHsrjK4wu1pLAAWbc5',0,4,1,2,0.048970,'Breakroom Sage','none'),
(3028,'entry','L13tQfLX54HPpnStNt8pvVo6uFWV97dqEnfmd9KGdUK1',5,6,4,6,0.093240,'Cubicle Slate','none'),
(3029,'entry','6kStbBhUir4AAbWfJaLLddh2b9p14v4dcGWrxARdSKYS',0,8,1,7,0.024960,'Manila','none'),
(3030,'entry','xNAxjpPP1SYaRE75VnKQrDKZ62mLacNfeZmCATdg3oJD',6,9,2,7,0.036000,'Cubicle Slate','none'),
(3031,'entry','JncxupL3kWDLWTURNPWyvBxAm4qe6LGpB11Dac33gNxA',3,1,2,6,0.055680,'Cubicle Slate','none'),
(3032,'entry','qx4QJx36XJi6R91W1w1RVoBEDxeTPpq31yqS18gnshTP',3,3,4,8,0.054870,'Drywall','none'),
(3033,'entry','GhbbTNZUoURnNV2K4GxX3442qyuibRzqG1fHRkcyzxQV',7,2,6,2,0.058220,'Filing Grey','none'),
(3034,'entry','98KFJdjJJLvbqXPHcktDkVTki353SvQYA7Hb6X65azhL',1,8,6,7,0.024800,'Toner Dust','none'),
(3035,'entry','quxyuycdaYS5kDAJVhCJqikdxgVwiuq4dD7gLdp9eSzj',4,7,3,0,0.074000,'Ledger Green','none'),
(3036,'entry','MvcnXKATnWmic15uUB7ryDGK1ZJEn5CZHa6TVAFFNsvS',0,6,2,7,0.058460,'Toner Dust','none'),
(3037,'entry','sJViHzZPojZeQVSA6S527q6JdMohvCqMafHP9c2owEtY',1,4,0,2,0.069000,'Breakroom Sage','none'),
(3038,'entry','FZhmP7JdnC7BZQwabSRRt3fVJXmVLLEsW2YsSDpTLrw8',2,8,2,8,0.072520,'Filing Grey','none'),
(3039,'entry','QraowYftasBojgj2oRbSy2Pvs1G3LxcvxLc7XgcFjx6K',6,4,7,7,0.054940,'Drywall','none'),
(3040,'entry','LwRko93UKRXHVaypyvKpcobpXTKYY5mmyQDE89aYbXRg',7,9,7,3,0.061420,'Ledger Green','none'),
(3041,'entry','nVLjJvGSNebY8YxgUELzs5CL8Kg3CLgvn7d5WfZQ2vBp',2,0,2,2,0.055500,'Filing Grey','none'),
(3042,'entry','CgJfsBQRX9Q86hw1Nvm9zhihHawjbRgf5M3sshH72cVc',0,6,4,3,0.064320,'Toner Dust','none'),
(3043,'entry','hHfCzuXZsAsC8mHfzK4FpqijDERJdN8TXuAhJdasa75n',0,6,0,3,0.053550,'Filing Grey','none'),
(3044,'entry','qgDNNtDL4aAUeb1CkRCJgHThbzkhjCrEmdLvmLn9KsS5',6,3,0,7,0.037200,'Cubicle Slate','none'),
(3045,'entry','ww4HDAPyvkFzkvJA6ntZoT3UwqLm4D4RXZ3DEvvKJx4f',4,9,3,4,0.054940,'Filing Grey','none'),
(3046,'entry','LMcAqg7fAJXmcusxiz8o1rtrZMhPUvmXoNSmwRvPNvno',5,2,3,4,0.063640,'Cubicle Slate','none'),
(3047,'entry','LV9AjG2mepbyEvMyMmDRbG96B3hMq9UEmEZPQqxFp5nR',3,6,4,5,0.080040,'Filing Grey','none'),
(3048,'entry','x2SQzuM5EaAeX8i6uuHfmtMziTX8oqjjYJCNVgynQPnP',0,9,4,6,0.083720,'Filing Grey','none'),
(3049,'entry','kro8q3cXiGjtPnViZ7WTkiJemjwTp7JDxvD5uKn2tmcm',6,1,5,2,0.032560,'Ledger Green','none'),
(3050,'entry','tgJDRmcLgzzEAxNP8U8nX5k16aE8EyzdGsfDom8KigAh',3,0,7,0,0.038180,'Ledger Green','none'),
(3051,'entry','2jNGTVwWGAjRaqo2g1GjezgJyu5AMCdGtqQaR1SgQwui',5,7,7,3,0.124080,'Manila','none'),
(3052,'entry','X7ZT1nZAx85kkt1Cg4EkhXrktaiNEdhTj2hCRrWEqumm',7,1,2,3,0.114660,'Drywall','none'),
(3053,'entry','UG3BDmU1BRvkzJKFRkcLvGdzHFayLy4g7HaQPfjgPT3P',4,3,7,5,0.037440,'Breakroom Sage','none'),
(3054,'entry','4nNjutHbiM9YdboMc8yPXyLUBToJp7EJKG9PS52RJUsz',2,9,5,4,0.041080,'Manila','none'),
(3055,'entry','U2VfUPgay2LovxLRRdeyPodYGiVDXrN4JuZ4VQwj6rx3',4,5,2,6,0.071040,'Filing Grey','none'),
(3056,'entry','9A4fFRBCUk4ekwc8XeYr5m6GcBAvbndWAMWaiMiG1nqR',2,4,1,4,0.068080,'Ledger Green','none'),
(3057,'entry','PbYmsdpNWM5qCbemLMuu8AJYUWiE4UN9q8DsEpaNoH5n',4,0,3,3,0.033880,'Manila','none'),
(3058,'entry','ZNyxAPwmwQozn7anr76dT3J1h5Gc3djfjd9d5uLa4p1X',0,0,6,4,0.029760,'Ledger Green','none'),
(3059,'entry','nJmMGdhL3MxremsQNEJ5QjpjqDWBpehUKVTduBq9ifdj',6,7,3,6,0.054870,'Manila','none'),
(3060,'entry','Q3QrhkoPb9WJty7kLA56oHPUhjUDYdwhLqdPWAnpcrkR',7,7,2,2,0.041400,'Breakroom Sage','none'),
(3061,'entry','Pems8y5em2GD9YvNct53Z5f1u69Lto8mA6cC5vJXJFJq',7,2,2,7,0.041180,'Manila','none'),
(3062,'entry','H4xn6zjTn9zDPqkHfDMHSVjnHCaFhs2vbQVQMu4V4wJU',6,8,3,4,0.029600,'Manila','none'),
(3063,'entry','nxqHND47mdSPeWpxsUBahEPKjxtL3feuJBWz4L5fFcod',4,8,6,8,0.028000,'Drywall','none'),
(3064,'entry','fQ7s74THuQW6TzdHBpV7iPcSCPowexGJjnDZvfwPs3XH',2,9,1,3,0.045080,'Cubicle Slate','none'),
(3065,'entry','wrXUKXEddcUReqz7YnjV9qTCcHJay7FuuWJ5Hc7mEDua',2,2,6,2,0.041800,'Ledger Green','none'),
(3066,'entry','hf6cGwFq7c2G8eGRVUN6M4FhTanck3BU99WwmYxKkoVs',4,9,4,7,0.032560,'Toner Dust','none'),
(3067,'entry','2oXZAoPwQmET5pJg9xYrQQHiEKwErPMooZVRAtaiD7At',3,7,6,6,0.054810,'Ledger Green','none'),
(3068,'entry','mEYf8jgqHHZMpKNLTAfYCMNXn1yySqdbwCsWZxchoduk',0,7,7,0,0.038400,'Toner Dust','none'),
(3069,'entry','Ei1qPzaEgZwGXzQW7L3TCAJP56jaVyCzJia561wX82gu',1,7,3,0,0.024000,'Cubicle Slate','none'),
(3070,'entry','CcUvRC6DX3rW65GtLkHhuSgRoUoJXQdMpNLZYp4YncSm',7,9,4,0,0.031240,'Manila','none'),
(3071,'entry','nBrBfsQbqf67mVqWAWFLXNibWMUPJTXFUS3c4iJZxMN3',5,8,1,7,0.045880,'Cubicle Slate','none'),
(3072,'entry','vvW84TN8uae6jHLhbqdtrSkaaZSaxAFhnVZXS4tcTPhv',2,2,1,5,0.031200,'Cubicle Slate','none'),
(3073,'entry','UyoP2BwQsMwxkXw9WR3BGVPScZ4xEDrxTVuUkj78gmos',5,2,6,8,0.032000,'Breakroom Sage','none'),
(3074,'entry','ybBbkiebQa7VVPfMJ1PRcAfnyePSSczPKvhVDgZGUm8B',3,7,7,3,0.062370,'Breakroom Sage','none'),
(3075,'entry','ZzVvKto18HKRjDZ2jBPT3tBA8b6NrzPADpLpsSGFbe1v',3,1,7,0,0.025200,'Drywall','none'),
(3076,'entry','jCkCkzxSxpPYV3nPK4rR5Gkr7smEMrYerHxUG44hR1Ci',4,5,0,6,0.045820,'Drywall','none'),
(3077,'entry','FUyin2RY4SncDJwnRWaPUqoJemYJ87wmvLSbJuNg4LPg',6,1,7,2,0.031740,'Cubicle Slate','none'),
(3078,'entry','Df53e7Eqo8xLBqxqdfCvSYCJBNdnpMNw54XpzXs6JWug',4,8,5,4,0.045140,'Ledger Green','none'),
(3079,'entry','jBibBncm2AwxgQh2vu6NudTRJjUZGgMqswdvs5mNa3Hj',6,5,3,0,0.043240,'Breakroom Sage','none'),
(3080,'entry','4iwj5jkkveKhqHpstNhK53HmvtZiNipgmamx2gQfv2t3',2,4,4,8,0.048100,'Toner Dust','none'),
(3081,'entry','MEap5PhkzfUeohTTkAk8D2oBpWQ8onkLHQHRgjZhUQrU',4,2,6,9,0.033800,'Drywall','none'),
(3082,'entry','7ekFiVyvBFPhu1E8gBSoU3aVmAhXjsgk4meC1vjxFhuW',7,6,0,2,0.068080,'Toner Dust','none'),
(3083,'entry','ezrX133k7GfsVMArAQTtsrfqzMW6sGHho5jVgi3J24Bo',1,1,2,8,0.064610,'Manila','none'),
(3084,'entry','vtLRaSne1bn8BjqDKtnNhKD6ucZkMszVDE1XpXmQZrJL',7,8,3,0,0.026400,'Toner Dust','none'),
(3085,'entry','edZ52tUonhy9MqVp1RziP8FcNbAoZX5jKn9N6sYeq9Wa',4,8,5,3,0.060480,'Manila','none'),
(3086,'entry','zhGeuXVUyi9p4UxEP8jrPQjbtYirtSdkFEHVSZb6vDUe',0,8,2,3,0.035880,'Drywall','none'),
(3087,'entry','j1CLsXRCGTNBrZkQz7eBBPGTBRV7Lm16mX2Yzvc379eS',1,9,7,0,0.033600,'Manila','none'),
(3088,'entry','rwGqR4zLb1xyv9a2NpTRcombdqgqah39Y8LgV5yPaWL4',0,2,5,3,0.031740,'Cubicle Slate','none'),
(3089,'entry','2tevgWnK3RQ1f8DA4gat6vT8exCs9sYLfkuAVxotfaJK',0,0,0,3,0.041580,'Manila','none'),
(3090,'entry','FFVC8jfAy7CzbbC2RHa69vfaJAVXHsgZhCoywn8vjB3G',2,7,4,6,0.039840,'Cubicle Slate','none'),
(3091,'entry','RXBNWk2tBW8M5HgDg18feiBez443Xgd6pTnjL3vASUVC',3,8,1,2,0.033600,'Manila','none'),
(3092,'entry','JvnKPN5Z8yGSNXCXBjRNWvLN1o54XTwWZikiR2zjfSmH',3,3,4,7,0.035520,'Cubicle Slate','none'),
(3093,'entry','TxCF8trzXSUnASibAZABbJHemKVhgzxjhmunbXSP4s3x',3,7,7,6,0.034760,'Toner Dust','none'),
(3094,'entry','khqQjQGy5kz16pfjkQ8BmM4KJwJNZe93MWQbnLfKqtJj',5,6,7,7,0.035990,'Manila','none'),
(3095,'entry','xFF9E4vUVoA7JTF9dFC4gao9q5SVtA3jDEk3m5on6Aky',3,3,0,4,0.036400,'Filing Grey','none'),
(3096,'entry','3z3iaGKPAoqonYQpKxByatb3mS22bWpJXMJLaFMDYLRB',7,9,3,3,0.033600,'Filing Grey','none'),
(3097,'entry','Jzmc9CkmuNb5KPmX1kPNDJu3yswTAzgeoGA4ysx4QThU',3,9,2,2,0.032160,'Breakroom Sage','none'),
(3098,'entry','TzQqwERXdvP7mhBHXSjFaF5T2eUt4xWCWxtgtkusvaW8',3,8,5,6,0.051030,'Cubicle Slate','none'),
(3099,'entry','AMMXgrzMnacN3VQixynsUQhTN517EZnSMnH871epu1T4',2,6,1,0,0.056240,'Breakroom Sage','none'),
(3100,'entry','BoR8uHLgAEZWr2E2S3wYFDSinLnCxvSt2pc436rn7Wpn',7,1,6,4,0.037440,'Cubicle Slate','none'),
(3101,'entry','cWyfMa7Q21d5qteHnanp2WEW5WUDBYsNJsnNku3UbeKU',4,7,2,0,0.028800,'Filing Grey','none'),
(3102,'entry','cjTQDXoTqaKb4jusnjR8phxqgE8pQgm8FxfBERcATdyy',2,8,5,9,0.056070,'Ledger Green','none'),
(3103,'entry','oMCmNdqaPdBsKfq3KjpRq5hxSJHZgkLRPha8uPPuYNsN',4,1,6,0,0.056070,'Breakroom Sage','none'),
(3104,'entry','bdDRCP7F8WWKonHdnRty8mdDTuLBgSZwQH5uJh46wXKu',4,4,2,2,0.041760,'Breakroom Sage','none'),
(3105,'entry','aEXHiqWbazQ5sy1dguTMdNNzi2YcBeodxxxFVVvQ4Ru9',3,7,4,2,0.074520,'Drywall','none'),
(3106,'entry','oyecEPPghWScrBsLyF1LQx7xMCGzkjdLvVADabSs4Ews',3,2,4,0,0.029760,'Manila','none'),
(3107,'entry','nuVMStemqGb3x8uJSPrbvAqDTkWe7aCruVGqZtuxhmZP',6,5,2,7,0.043200,'Toner Dust','none'),
(3108,'entry','qQfKso5xABXULiEECi2cTMppQPcArtYwAKN5nQzZDXge',7,2,1,6,0.062370,'Breakroom Sage','none'),
(3109,'entry','pmNaVt1jvrvPnVxF8siD5VXyoJb72cDk9VnemfCpZ6Vb',7,6,7,0,0.023040,'Ledger Green','none'),
(3110,'entry','uA68WbabXBgQd9ZRXtDWjmzbjurnfNKi49VtCNhxUKnz',5,6,4,7,0.038800,'Cubicle Slate','none'),
(3111,'entry','N6VDFsk38ySkXJ8XPf4dKaR9E6sS9bVw5aC8sSrVRYEa',4,0,7,6,0.040940,'Toner Dust','none'),
(3112,'entry','QZ2bENuvhAPrFs7xssDcsUGY1jRVsHsizLm5PbLLReGj',2,2,2,5,0.047200,'Toner Dust','none'),
(3113,'entry','gK9RBUtkGj1627Z49ZDhY1hci11nifcyq3HqvZMPKxhn',0,7,3,6,0.049400,'Cubicle Slate','none'),
(3114,'entry','s2VFgdREsXAJeiQk5dDyvwiLMWXzF9vpA86KrRpMys77',1,4,2,6,0.075440,'Manila','none'),
(3115,'entry','EsEpBqyRBfQ7VQTNkDYmZGC722NWPUZED554jCrG552J',5,6,2,6,0.072090,'Toner Dust','none'),
(3116,'entry','gCLBLsMr2GRkvvNJMybfLKZ8Tzmd4tx6uRqbb4v1JeKK',2,1,2,0,0.043470,'Ledger Green','none'),
(3117,'entry','cDs5nVsdnjWqdytd7RWv6qmtT21wPJUeaAy1UekEWA8X',2,8,4,6,0.048100,'Breakroom Sage','none'),
(3118,'entry','GTva1PvFe8786YydPp2v3wKZgaqjrWcPd7MYmyagSNZd',1,1,2,0,0.040000,'Ledger Green','none'),
(3119,'entry','AQMnMYD1rH9Egp1bPB29GZHUFBYFnDwQPQaZ99fmqC8y',5,9,6,2,0.033000,'Breakroom Sage','none'),
(3120,'entry','dnKoFdCLmSEA43jzsGVNRSofdwJZjkgcmxngEBxSWX5Z',1,2,6,6,0.044200,'Ledger Green','none'),
(3121,'entry','E6XhiKRJZoj4ezwEVxCrdCwp7fcRQ7S6Q4SJzmoCjx5s',4,9,5,4,0.066240,'Breakroom Sage','none'),
(3122,'entry','9sPGaPGXQbZb148vmt3zEwcYSr4gMJCzvnAYYLxisQh9',4,9,5,9,0.048910,'Breakroom Sage','none'),
(3123,'entry','ihkEpx1Dv6FxZCJhVuvkyzSdS6kofomgKcZc4aRcLGed',5,3,1,0,0.050740,'Toner Dust','none'),
(3124,'entry','kqr3fguKnLFeWPWoCgs8US7g4ZxsbBFk8fiBC6VXSKfm',2,9,1,2,0.028800,'Breakroom Sage','none'),
(3125,'entry','xptipXDeKXLY28YtuRx7WkFR4YWFVFwHZgHsRgy4RSfW',5,8,5,5,0.030400,'Cubicle Slate','none'),
(3126,'entry','scsBnHSRhpSProruee8JSTZFEaFgjJbSnTtbtEwbub3c',1,6,2,7,0.033580,'Drywall','none'),
(3127,'entry','KFFKfhuyVjdV5mEbZ3p4QRqmQPL3KwqYLVECGDw4cP9u',2,2,2,7,0.035600,'Breakroom Sage','none'),
(3128,'entry','67okh9eeaMQTwwozUVTKdbMciTiFuHUY2WXsGX734yY4',7,0,4,0,0.037960,'Breakroom Sage','none'),
(3129,'entry','XL6kzH84wAqUPKeyTZXjRqCuGzim1iJangSayhc3m2fT',3,1,7,2,0.054520,'Ledger Green','none'),
(3130,'entry','v5QVfMcUvCTLDppBgTExF7UwrquC7GtdGEjhoFyLYLRB',2,3,6,0,0.054670,'Manila','none'),
(3131,'entry','CyYGxdueBBFJYCvic6hd9zzFc7trscBPfdvJ1iWPZEEY',2,6,4,4,0.045880,'Drywall','none'),
(3132,'entry','PkuCdgum8tBxiPM8k8cgLMYeRRk2YHp5M64obAFmBUp5',4,3,2,2,0.028980,'Toner Dust','none'),
(3133,'entry','2c5WC7761nMtv7wzzjD5FHn4rifhCgVs4Q2icbjQ1TUL',2,1,3,6,0.057960,'Toner Dust','none'),
(3134,'entry','k3ETtW6sDBLBcXww8EeFx9tyTfKqpfbVJfiyc3gZsqzJ',4,3,5,5,0.040950,'Manila','none'),
(3135,'entry','d48mgn2ag9V4jFmjmBCfpMzDgXKP9FKqSQbEw8yjcQEu',0,9,4,2,0.060970,'Drywall','none'),
(3136,'entry','cDkR3gh5aZYAPE6iwwqYjTfyUYbLA7sMurXfmvucgRiU',0,5,4,9,0.039530,'Toner Dust','none'),
(3137,'entry','hVbeGSD5QpEPvxvKvmKfHe6vSLGTpbKAu8t4wkNqGUME',1,1,1,2,0.027600,'Cubicle Slate','none'),
(3138,'entry','aSqrDiioR2xecSr5psMzKUftNNoPjyUUcLdJfNyGQFp2',1,9,1,6,0.029480,'Cubicle Slate','none'),
(3139,'entry','xDmMxemuVEJ8QyrHKg992qzsu9HFyUcSARaasAaSRZPo',2,1,4,0,0.037600,'Manila','none'),
(3140,'entry','61PT5VbH7232Qg6ZKUgg9s8Anp3HUjGg4phqT2qvCCcC',4,8,5,3,0.035880,'Manila','none'),
(3141,'entry','5DVgAZSs5SwRXZwfVYRCKi5qFNgnbcfMegvBU4jezjDM',2,9,7,2,0.027720,'Ledger Green','none'),
(3142,'entry','XvyjdJHd2TPZ7kTw5LXu7aqyFA5EdF4wjn6qKE3gFzWZ',0,7,0,5,0.064320,'Cubicle Slate','none'),
(3143,'entry','JpVfdADa4JQiFzBEMMaEKJyfWte166DN5m6NCH1zVQzr',6,6,5,8,0.058290,'Drywall','none'),
(3144,'entry','Fk8QQrx5TTcvBNfSNEcu7NzbL9mJTTzfvS5mHhDkCJiW',0,6,1,0,0.034400,'Manila','none'),
(3145,'entry','PGZbHNJbpCoeSRSoumtdihBtYyBFvFYVQpDbNB1nUSoq',4,6,4,5,0.030400,'Toner Dust','none'),
(3146,'entry','N9dZh2coWpEyr17Wa83uNafCWDEy7YMEXYDGuswL4uFV',7,7,4,6,0.050410,'Filing Grey','none'),
(3147,'entry','CLJ8n57yTNmmv96UXMKeVCbFHhRYHAsyMV23jSiwELrX',5,6,3,0,0.035040,'Drywall','none'),
(3148,'entry','RQUtJsUTh4FBfJk3DtYVuFEwFYiZBW4cm7NURV4quaNX',4,4,1,7,0.046980,'Manila','none'),
(3149,'entry','6toxxyoC1qUr4qc8NqCQVyhBWF4dWg4hyRumSt6vx6QC',5,2,6,6,0.036340,'Breakroom Sage','none'),
(3150,'entry','s56tx8wS86aVM6tQSwErKYv5Fow9t26JHgQU5Y4jwS5W',1,1,1,3,0.086480,'Filing Grey','none'),
(3151,'entry','27evhJExZXNDYDHaeZPFGTHkQfsZjM64gz32B7zVW6Ur',7,2,1,6,0.040600,'Toner Dust','none'),
(3152,'entry','mrrzBaJLZFvALJmRS1VNpyprvWka9EW5TKRiJNHtwGgU',5,7,7,4,0.038280,'Breakroom Sage','none'),
(3153,'entry','xsUZofRwu339txbzRyob44utCbejX1qh8jLqfJsnSySj',0,0,3,5,0.099540,'Ledger Green','none'),
(3154,'entry','JzcpfkoNBEpd5ecn6GUbhmQkYTHp7f5kDUBqUVTTg5X8',5,0,2,9,0.045080,'Ledger Green','none'),
(3155,'entry','vrCjTS2xrs9vfJjoHLbAGSdpGDCX3FK88tDd2tfEArvy',4,5,3,2,0.035360,'Filing Grey','none'),
(3156,'entry','5Y3c5WH8zrENcJEQj2bs34qBR5Gr2V12LELkEk3dkRiF',3,5,4,6,0.028980,'Cubicle Slate','none'),
(3157,'entry','fF2FQmufpxiSfhxFhQ87hEbpN7Vq9JdStKAKvXjSRJZw',3,5,4,6,0.031240,'Manila','none'),
(3158,'entry','saAEEs6LVWD2Rm3wf5QNhXPcwuH9vmWTNUKmuUxhbyde',1,1,3,4,0.029480,'Toner Dust','none'),
(3159,'entry','DqQAp54utjnTZ22EAL8ciDaCsFmCnkWG8gfd9VQMfMkN',7,3,5,0,0.064400,'Cubicle Slate','none'),
(3160,'entry','s2Z35pFLMCWUSNfhAKkCgmvdXHwKzgzbDpBPDKwV1QXX',7,9,3,0,0.044730,'Filing Grey','none'),
(3161,'entry','SpTdWA9KiSqXT1xJ3ZMmzWjKqspkAZH5R2dpgfAUfu7o',1,6,6,5,0.035200,'Manila','none'),
(3162,'entry','gp1TBFeCVvoPjsybB9HF1epjVN6UPnpw6J71xaPqxYfb',5,6,6,0,0.058290,'Drywall','none'),
(3163,'entry','gLpadYuAXntGBoS59gToRxgMHMKotMFhYbKLaaYeyQdv',3,4,5,6,0.044200,'Breakroom Sage','none'),
(3164,'entry','AobataGhX4S9qt1giLvchsEL6oQkER6aPQTm3DCUyu37',5,7,1,0,0.044640,'Cubicle Slate','none'),
(3165,'entry','UposWLphpvFjQCmt2Wqz6mMx7cLW9bcVScVJWoNcNFWJ',5,6,1,4,0.036800,'Breakroom Sage','none'),
(3166,'entry','e1t4snkmgHHeqhoSLuoyogYepWmRxU8Tcjo2XFcyCXWi',5,7,7,9,0.060680,'Manila','none'),
(3167,'entry','VbSJQM4WCTUdvUCX7xhEsUsayH8B35mE27YmoM7LskDY',1,5,1,0,0.048380,'Ledger Green','none'),
(3168,'entry','Ksr5N2E4CmijakoPcvhiKY8hiHACJXsVgt17Lr4jmWTa',2,8,6,0,0.033580,'Manila','none'),
(3169,'entry','xRtEwKwC1x9U7WPkCPQLnP2TXdMghu8qpugEhWcTKvPb',0,5,6,0,0.101520,'Toner Dust','none'),
(3170,'entry','CsiH3CXHVXbV8eF1sXw9ZV8sXns26ioWuCWVSxGdwRrB',0,2,7,8,0.040120,'Toner Dust','none'),
(3171,'entry','GMjbNc9HbuVrx9yx8LjMtccVAUFUxbY3ViKeQp3SZj5h',4,4,4,7,0.047570,'Cubicle Slate','none'),
(3172,'entry','YessAU6BexHEsMqXrBubQmQJaV2mhSGBCbT28FbcHEU2',7,4,2,4,0.128310,'Toner Dust','none'),
(3173,'entry','kwxf6kgxcD2TktKNSL7vXtXS9M1YLWW66rcf9qegxjvA',6,7,6,6,0.061770,'Toner Dust','none'),
(3174,'entry','JqK2MehCzJyaTg5Sdw1dVa7Xs92bXTUnjti93JyQpJXc',4,2,4,9,0.073260,'Breakroom Sage','none'),
(3175,'entry','wpNTDvwGZajYiTVybPAy84VDKT9MZ1drZSz3q8UfQKw3',0,7,0,0,0.032200,'Toner Dust','none'),
(3176,'entry','BWAZMeNnP4KSboPitK6EN2CN3S8DxB4c1GwNKFLQ629P',2,1,6,5,0.054020,'Ledger Green','none'),
(3177,'entry','ta1GVeMWUJMZ2ThtLwrGrPKrsDBYrMMfY6KmQNmAdPNP',5,1,1,5,0.044000,'Filing Grey','none'),
(3178,'entry','MFrSBPyEGyFtsuK6xHts8N6MAy8Pct1LR84JH7a3oggm',2,8,6,6,0.034960,'Manila','none'),
(3179,'entry','2HGNuA2x6i59D6n5gqsYHquwTyLfXMcGAyr5NUhAikbv',3,3,4,5,0.049920,'Breakroom Sage','none'),
(3180,'entry','jvJpUfFor5hkrgyUmADfEK4zrSerAUgkQdPVb5h1CK9K',0,8,0,8,0.033600,'Manila','none'),
(3181,'entry','b2VPtm5g6ghL7BdYXn7ayxd68Co1P5VHJ73so9eEa5K1',5,0,7,8,0.042600,'Ledger Green','none'),
(3182,'entry','HiNM3UDfzYPuRYPiFVYkenkkjpEWk45RRz19uxqhks7S',3,3,5,3,0.055500,'Toner Dust','none'),
(3183,'entry','kMGBvLh5FmK8WRJGZBA46KUWrQ127wjNhJ8Qufiak4z1',0,4,6,3,0.045990,'Toner Dust','none'),
(3184,'entry','EQhKoGvXYjAj8BNZWWYzRvrBeg5TMsWgHStutqnDAWhR',1,8,4,0,0.038640,'Ledger Green','none'),
(3185,'entry','TrgojYimRPqn2q75UbexDG9tkhGcnUZDqLFRcrfGhbvH',2,3,2,0,0.054810,'Filing Grey','none'),
(3186,'entry','RoHw7Tqbj3RAdrq4fDNSf4tRiy8M4XTGzarfy5hpfmE8',1,9,2,6,0.025600,'Ledger Green','none'),
(3187,'entry','q3TbBEYArPRnPsnzTS8jpqhJaS6F23hk5MXwNxqpHXCK',1,3,7,0,0.029120,'Drywall','none'),
(3188,'entry','bGCR6w2NYj42TBHGXByYyA46HhPrsX2qXBVMkqecw8Yq',1,7,0,7,0.042920,'Manila','none'),
(3189,'entry','cEZWLCmRiJpxFtJoF45kgLtUkgEvRMchkMB6LNnjHFba',3,3,2,4,0.022400,'Drywall','none'),
(3190,'entry','Rar2KCu192odMEzvJFnNvc1tqqDxMQzgnUvNVCVJNVGE',0,8,4,4,0.046980,'Filing Grey','none'),
(3191,'entry','q3X4DtgSaoLEmyKLib2MZoHJTQCMLy7LnUAt7gNCAzMz',2,2,6,0,0.020160,'Drywall','none'),
(3192,'entry','wZAmobrxWXgYfDjXJWWqJomHhFjSD6Fgpn2QYp8ts9G6',1,1,3,3,0.032200,'Manila','none'),
(3193,'entry','d5nhUBNDxGN3ZxvymfPMkknCwQbuofWzb2pnP39NVyQp',4,8,7,7,0.036000,'Manila','none'),
(3194,'entry','PM5g8GjJxNnTKEDugEaxAJrbm4omRFugWUCG3texPR5D',1,4,6,6,0.042240,'Cubicle Slate','none'),
(3195,'entry','zoPkjgvRWPLSJMKn415rPH4X3Cj6MA1oNQbFopduVvxE',3,0,2,7,0.033200,'Ledger Green','none'),
(3196,'entry','CDkZEbiRFG3uKJEXw9amgJm9Wm3FnTWXV462V97d9voq',2,8,6,6,0.031600,'Drywall','none'),
(3197,'entry','AdCX3Ymbzky5PpD8L7HYeV6Cqg5h87kCWmy2P1HZxAFq',7,3,1,2,0.107100,'Ledger Green','none'),
(3198,'entry','tEPo7h7wgC2eJrAbruxk1gVMX6oi9Q38U6c4tzpsUgnD',4,3,0,8,0.069000,'Ledger Green','none'),
(3199,'entry','cxWvKq3ucjtiKgEcncQGR1Afx2reFjYs4P1WCYttD7qn',3,7,3,4,0.043680,'Ledger Green','none'),
(3200,'entry','bJanzmLYSNUVas7cNiB6rCmrB9VDuH2ccm2sXo5gcQJ3',2,0,3,9,0.039100,'Cubicle Slate','none'),
(3201,'entry','eNEemQamTCqajX1q1MBi5HK9C4k45qJa4xyW6BPmuvzR',2,3,7,0,0.038400,'Cubicle Slate','none'),
(3202,'entry','RdWfct24CptSWGJNHxgwuspHNSwyM22ntiV5rU8RNm55',5,5,0,7,0.028160,'Breakroom Sage','none'),
(3203,'entry','uNa3t238AYMDWq3hkSjLAwkEJz382qQQNdrCWt6iuKgr',2,2,2,0,0.044160,'Ledger Green','none'),
(3204,'entry','egdTjrDm7js6DSs5JBpcsA8LhHmxunGSGsFqTD5hSZho',5,3,4,4,0.040320,'Breakroom Sage','none'),
(3205,'entry','GaqmWE9fft3gWU1u1FVkMgLrjpip4BABnxw2mx7fMYWL',7,8,0,7,0.042640,'Ledger Green','none'),
(3206,'entry','ELgdAkebAHZdnnb7jwPws4MK6dZ8xo4cPUCskjtBGhvj',6,6,6,3,0.042840,'Filing Grey','none'),
(3207,'entry','3UxMbAznyY8EH1FLxH2jmd5CSw3NEKQpm3LA428vDFJq',4,6,4,5,0.044100,'Breakroom Sage','none'),
(3208,'entry','sCY3qEC9kVt3eW8SUxkEL8TmSobtGYY66BsYWyXxf91M',3,6,2,8,0.063180,'Ledger Green','none'),
(3209,'entry','CosuVfRbaDQc99PVLaEVn4CMdfVfdsDmNvpfiMtTu92q',7,3,6,0,0.040040,'Breakroom Sage','none'),
(3210,'entry','bDQM4fM5asXMh7VbW8fQ2RJrgcQFVdkQa9q1WueSVkRL',7,5,5,8,0.037200,'Toner Dust','none'),
(3211,'entry','XWCa4hCPXXx2Q9jS9nP48HZXa9vFvhZ4mzRg7wwFQwBR',3,5,3,7,0.027720,'Ledger Green','none'),
(3212,'entry','2J2fwApQa3ppNCQUFXcjitB8B77GYidGnWKigt5muy2q',7,6,0,3,0.044220,'Filing Grey','none'),
(3213,'entry','jTLgQ6T3cQqMCn7QG5LhHeev55N2pWgdsdbXmC21N7qg',4,3,5,2,0.039600,'Toner Dust','none'),
(3214,'entry','RwnVcKLTEiVjLfNwWnBZG8UiW2Yh6FMnag3Md52KegH9',1,6,4,8,0.044720,'Manila','none'),
(3215,'entry','CFneDGg2qnDm39BoBCsZJEas3FDJX3US1ALC7vp89vnN',6,2,0,0,0.061420,'Drywall','none'),
(3216,'entry','BjgaGcxukkmCJByF48JLghSLE1od6wbJS68dtXD26YcU',7,9,1,0,0.033440,'Ledger Green','none'),
(3217,'entry','73gbCgsHwRpzZBhGVvYP7dDPD2mKrC1tTq7BpiTMg3Uv',3,1,1,8,0.044890,'Ledger Green','none'),
(3218,'entry','VoEqrYcMu96gitfsoMxWjhFamJ2wS4TpYy3XudHCD2B4',7,3,4,3,0.085560,'Filing Grey','none'),
(3219,'entry','PnEmrwQrdW4gPLCBjMeB1vFwdSdYvbo2MDbijkcBJzQe',5,4,1,2,0.045760,'Filing Grey','none'),
(3220,'entry','Tc8bEbB3PwZmaVzTvJbBxq1cR6McT1Qw7P35d9PsEZAG',2,2,2,0,0.030720,'Toner Dust','none'),
(3221,'entry','y6YuQJ22CT7iEeNeAKfkwDqdyfLc1LWZUEtXAoqyQ2pv',4,4,6,2,0.038640,'Manila','none'),
(3222,'entry','XMpH5pWvT677ngVQkWe46D2b3fbH3TTim6AzMxsvFKMn',7,2,6,0,0.043470,'Ledger Green','none'),
(3223,'entry','4YqwhvctrMS3sd1FQL8ADnb7njck7boADrbRvbGz95QQ',1,6,4,8,0.044160,'Manila','none'),
(3224,'entry','8ZTFKc15ELTKqdHeZkXrRVWdBQMB1vrsgR8U2qgS41iK',3,8,3,0,0.058960,'Manila','none'),
(3225,'entry','R5kJHN2g3nxAWrHwZW5nEf4gvZiT9p9BsL3PyfFZkmJ3',5,7,4,4,0.044400,'Drywall','none'),
(3226,'entry','ifAJeqSz27tX9f1sRuPNdTCMhx2DCBeBNvJocfuGwUyW',0,9,7,5,0.022720,'Ledger Green','none'),
(3227,'entry','bv8bRbBBvQ6m4b26TsXrjqhJrn5cmoi6A1ZbrNYcaepe',7,2,7,8,0.031600,'Drywall','none'),
(3228,'entry','woWTxRu5ocrBJndrg6amLbgcEG4VgA3CumgYC991ivmc',3,9,0,2,0.026800,'Breakroom Sage','none'),
(3229,'entry','NqY7sC1JsoN8TcXaNUeN1c2YauDnwTKP5NsPyzx9Kkdk',0,5,1,4,0.049560,'Breakroom Sage','none'),
(3230,'entry','Li2jHLtCztoFjumb7KqBpsQBVJu54mxugBftTzLTBNPi',7,8,2,9,0.039600,'Manila','none'),
(3231,'entry','6wEbxfWrRzEATh8Se6wpANZetuVivUtVbbYRz9sSbL64',4,9,5,7,0.052930,'Ledger Green','none'),
(3232,'entry','DcA3mfLJ6nvT1KULxEuu2C1oU5jac31HSsS1GFVGsahk',6,3,5,5,0.032160,'Manila','none'),
(3233,'entry','6Hgs5hjG7J9raNtcycmwTtTEgYZsL6guPYc6nPaW4ZVM',6,2,3,2,0.031360,'Cubicle Slate','none'),
(3234,'entry','Tvy4srsyhhYipAYU2GhoSMUTTJK15AdNNsNJjutqQPov',2,3,2,9,0.027600,'Drywall','none'),
(3235,'entry','UrEBbEvTLcAh7y4gh4fyWPSeBAGNQP8tsxCiN3Gonsgw',0,5,0,0,0.025600,'Breakroom Sage','none'),
(3236,'entry','As2QkNeAxjJ97Xais2THs1hyMsFsgekeQtpVqNLVcRer',2,7,3,9,0.031240,'Ledger Green','none'),
(3237,'entry','usRcdk6KxFSUx9CjXW3MBTB7PMR9Twj9W14fRT5SaGmF',3,4,0,0,0.043470,'Manila','none'),
(3238,'entry','Xzi2fhZyJ5QJzLpHFSeRoR4N9yssXG1VbrmneYYhyC4K',2,0,4,9,0.071000,'Toner Dust','none'),
(3239,'entry','6J8chtXaupQTL1MwmKsF34dsgWsLk4oqrRVtobBa7znz',3,8,6,4,0.040940,'Drywall','none'),
(3240,'entry','GTePYfHDx4CKb2RVoF2XbHx4FrJ4y9k6t6n2CXmsmewt',3,0,6,7,0.053100,'Cubicle Slate','none'),
(3241,'entry','aUh8AmFdR9GtVExojYC4LHZaAG4nV5X6yeySHScqZxu7',6,3,2,0,0.036000,'Breakroom Sage','none'),
(3242,'entry','dhjKVSNPopJeszqqmxoGAvXBsciB7JkQ2uCFrtBxbYKV',6,1,6,8,0.055610,'Drywall','none'),
(3243,'entry','ocNtCGjEP91gtboeaKVFQPiio46MgsXRAUnv4Pg2d2o4',0,5,3,9,0.060480,'Cubicle Slate','none'),
(3244,'entry','xu7gffncpMXA3YMwqLtGdd9BoFFpkt6dkyDCDepWLonK',7,4,6,7,0.067450,'Breakroom Sage','none'),
(3245,'entry','6BFXjGVcjvBAdDw6MoKw3b978h9HG3dLqVhxaSx76Uxn',6,3,5,0,0.051330,'Toner Dust','none'),
(3246,'entry','GCHF3ZFzM7Y5F1MW7bYG8gzLxxSKGJhdgekshJQGM9zr',7,3,6,4,0.034760,'Ledger Green','none'),
(3247,'entry','zc8eWtWK9aXG8zYXfXPB5iMgjag3ir7MkQtHqHHe6K4e',6,8,2,3,0.031040,'Breakroom Sage','none'),
(3248,'entry','ozB24jaMPGHWuafVJ9qcXuksABT9Kv5L5bHb4NZkfdHM',0,1,0,4,0.060300,'Toner Dust','none'),
(3249,'entry','EJyXXzgZ6Wg33GAKeMsqW5HtoGuffQJTeJktwdEKm4Ds',4,4,5,9,0.044400,'Breakroom Sage','none'),
(3250,'entry','VJxdzDt7e231bJ5yG75HqwrL5T6KNGkBYVPvvd5AyjD6',1,3,3,2,0.084640,'Ledger Green','none'),
(3251,'entry','TtcCAf2GuRCn6GNETAemTrJLw63qr3MsHy66D76G9zdU',5,6,1,0,0.037920,'Breakroom Sage','none'),
(3252,'entry','qVYVPRK5VCZmxEjeK13HMkcASDJJD9HiqyifwGof6PHx',2,5,2,5,0.035200,'Drywall','none'),
(3253,'entry','NDzJBPQY1MPS6358BDrkmYofiBxii1xQs4P3N7FfAo2E',6,9,4,4,0.046900,'Ledger Green','none'),
(3254,'entry','kbgvbgqeYAoHBi3X27PueTJSGhs3RBGijRqh8PyaEpoN',1,7,6,6,0.034400,'Breakroom Sage','none'),
(3255,'entry','zmfYcgFMPUtJkNq98AuDcEuroKxDAXW9ou5t9iFN8PcS',0,7,4,6,0.024400,'Cubicle Slate','none'),
(3256,'entry','PPfNQAnT7HeuVdNwo75zkTxGFmdsKphSGJU9AeKvcMGP',3,6,3,7,0.031200,'Toner Dust','none'),
(3257,'entry','kWCe8vh7tKGp1TTuhNRDnWjW5sk229yAkwt3qgvxRWj2',2,5,0,4,0.046860,'Cubicle Slate','none'),
(3258,'entry','6jCb1MCSZ8ffjzop7FyinUvWRwuoXchaLrCVsvKMWxJi',0,2,7,2,0.053100,'Filing Grey','none'),
(3259,'entry','uQG2Q5HMbUCRiNB9wg5TKKUWYjwU4nixsATbiVYM9m7Q',0,7,1,8,0.038000,'Toner Dust','none'),
(3260,'entry','7WyLqKKuYRb2v8j8TgKfBqi3ff52UfWPq3kfTmyxSfmW',5,2,2,8,0.033440,'Filing Grey','none'),
(3261,'entry','Pj55iuLnGpjnViUM7JNUuiSrWkuvBR6DbHGmwgsPzjWF',7,8,5,8,0.061770,'Ledger Green','none'),
(3262,'entry','ZUsjhNkmNCcDXNbJuhmMMgGvzzXTZLNGcSqqGBJxBibZ',4,5,3,3,0.044730,'Cubicle Slate','none'),
(3263,'entry','x6v9bo6fMpwyJP1BCVoYNasJT729qfVr6yY86GuvQvu7',2,6,6,0,0.049560,'Breakroom Sage','none'),
(3264,'entry','8BqsUs7B9WEGv1gAeEujkZSGnNkSAWWWLny5D3g1Ngev',4,5,1,0,0.046000,'Manila','none'),
(3265,'entry','j9Loz4XiJXgSvz1LYg88bug55ejWkoBP1da6fJKtLNdH',0,5,2,0,0.041400,'Toner Dust','none'),
(3266,'entry','mJCX6T3XqkKaAeqepxmrSxvjUB9hjyyqxqoVMQ6jBgsE',6,1,2,0,0.036800,'Ledger Green','none'),
(3267,'entry','gABeHN4LEaWz1raCdJnBDiuW348ezwdN1KH16kHBcDey',3,9,3,5,0.030240,'Breakroom Sage','none'),
(3268,'entry','eji8gCxa3MEZAtnGzz1UpaNWdWXF69TxzSsEi7DHoCQ6',1,7,3,5,0.049140,'Filing Grey','none'),
(3269,'entry','hC5oyMrRuaP6A2zsvR5Mfhg8jXCCrpVdRL5EMyTsH1Du',6,0,0,0,0.038400,'Breakroom Sage','none'),
(3270,'entry','EwjyenRE6cwK8jo4jASeSpKkoREYRhPJAwJ42azr8tz5',3,1,2,3,0.041280,'Toner Dust','none'),
(3271,'entry','wfoZhyguYFxdb6wm5HPGuqem9MP8PJ2eV5QBtMDne5mT',7,1,1,3,0.054940,'Manila','none'),
(3272,'entry','gHK27Krqugsfpp23H6ug7NQ3mUqVVzvrLJsmCpMNnrbJ',5,7,5,6,0.058000,'Filing Grey','none'),
(3273,'entry','dVCKVz6JLeKUJFsYFxiYNDNJsTudAjAKLaoggrQrTiy8',4,2,5,0,0.051590,'Breakroom Sage','none'),
(3274,'entry','tfSiJkXLcX7YUbSiTeiTUP5DJaxvxuF3xUqPuNbWUBFJ',7,0,1,6,0.026880,'Breakroom Sage','none'),
(3275,'entry','odyRVbas9Buk1xUKD6z9yZg5gMDiB4ZdHa4pFRedreVf',4,3,2,3,0.031040,'Manila','none'),
(3276,'entry','v4JyHopFNZSktZi1LdmhsVnjMv4tqXcgmwHBsP9qXPwr',6,3,2,9,0.064800,'Manila','none'),
(3277,'entry','3YX2badajFbEvJxMMhyB8nNGopHxSHvMtPuyxEycU4Bk',0,0,2,5,0.044620,'Toner Dust','none'),
(3278,'entry','Q6m9rCUkeim1w64a3RvcSKeu8MzJpxcX5QjAUAQKWN9d',1,0,4,3,0.046860,'Filing Grey','none'),
(3279,'entry','ZiSeNGk1hhdNAPASnPL3B2CctTjJ6QvtuWhqCdPTrK2u',6,4,7,8,0.041600,'Drywall','none'),
(3280,'entry','eDkBoDpubpzn8dmC6yymHzm13ih1mSECA1EEEDWFtTw9',0,1,2,0,0.042210,'Breakroom Sage','none'),
(3281,'entry','BwcqHu6YYLyQYyzWmV7uG42phs8mgrQcKzccLuEYGji7',7,1,2,7,0.058590,'Cubicle Slate','none'),
(3282,'entry','aSWVb6SZXyNFMYkqepAStSpzNXQgQRUE3pgk1yvjM7Un',2,7,0,5,0.045880,'Manila','none'),
(3283,'entry','ZCtMpHxJeYyhfwqabc8E2NkfkV1yNnGWAx6HNqjoVayu',0,1,5,2,0.031200,'Breakroom Sage','none'),
(3284,'entry','pYr5E5ovLgvFoJPtjn71U42jw8ka1y8eQ5LWPXimAVbW',2,5,0,6,0.028800,'Toner Dust','none'),
(3285,'entry','uemg8uDUCizFkJX6vUyqSHkEzAkRq8CNnqcMKKW6qFBJ',5,6,3,6,0.032560,'Ledger Green','none'),
(3286,'entry','2x2srWFA66be2GGa7bePXH3Jn35YgrSt19QVK2L7twW7',0,6,2,0,0.044080,'Ledger Green','none'),
(3287,'entry','hHywNXjTDtiEVvsycKD9Xd3v6nwPLChEWNPyCfvBGfqY',5,5,0,9,0.029900,'Breakroom Sage','none'),
(3288,'entry','7idjHg9H4uKbzdBC9eSjrwioRAoWGBy16C1Qv5iprT52',7,0,2,5,0.057230,'Ledger Green','none'),
(3289,'entry','RmTmoaLmxkHrjBwJpmcEZwYHL7kDh9aMiHjCYBmvDEEe',6,5,2,4,0.049920,'Filing Grey','none'),
(3290,'entry','mz1HgoFyuYp4M6mu3dHH5Q3jJoEUJrUuEa38vMkpaVJL',2,2,5,9,0.062480,'Filing Grey','none'),
(3291,'entry','5gHfbMsVLBYaRtWPBKUdmzEMZvPP5nDcVrj1U8HdHwdd',3,7,6,8,0.031680,'Toner Dust','none'),
(3292,'entry','GUs5NdN5d9VmQc4s2AiRQ12rQFJ6xgPcRehzJSXA6sAF',5,9,2,2,0.040320,'Drywall','none'),
(3293,'entry','p6hWd6dEKaA8RR1DqY3dgb9pfBwMA64ByXrWV7tPq24F',5,7,5,6,0.026000,'Toner Dust','none'),
(3294,'entry','x3HQobi63KrJBPRbmAzuTZAezt4agMGf4fcaccrVFgtU',3,8,7,5,0.044840,'Toner Dust','none'),
(3295,'entry','mBW6xZyRjm35hjqvi7xGaKBLnEJdxgEF1VvfgwWCiRUp',2,3,4,9,0.069580,'Filing Grey','none'),
(3296,'entry','BWcsoU4h7hWvYFNL7mnNvq81TPRFqxzM17HTNkUbwEb7',0,9,6,0,0.039060,'Filing Grey','none'),
(3297,'entry','sk7JvRmfFNXjhsKz9bcCFkQu2seJq95FztRbyUgoGvuS',0,9,0,0,0.032120,'Toner Dust','none'),
(3298,'entry','GXuZQqTYxWZExEgoMPdChKwqjSfSH3116sHuXw45SHPE',5,8,5,6,0.050960,'Breakroom Sage','none'),
(3299,'entry','DoZECPSztWH1DVGs1WKbRp7udQhrhCHxu86ZK6cnedND',4,0,4,7,0.036520,'Ledger Green','none'),
(3300,'entry','vZ7g8tEFfGbkhX5ri4KbCrUEtc3R8ffYqiRMsHHqXXbj',3,3,1,7,0.065320,'Breakroom Sage','none'),
(3301,'entry','mP2BtoSdNWSCpWRqFoxWxDrK81c7g5JxL9nQFoaHUHUk',5,4,7,9,0.093240,'Ledger Green','none'),
(3302,'entry','vA7NxLQTtmPX64PryyD9PijCrYU86jnYxL6VX2qptoEA',7,9,7,9,0.033000,'Drywall','none'),
(3303,'entry','qbD3qbnQextpuceERea9p7Z5xPFRHztzryjFVkvd9rH5',6,8,6,5,0.024960,'Toner Dust','none'),
(3304,'entry','RYK9Laikz5iqGFM7wweWP5p3Xh5HC1xgj85suMarmGzN',3,7,4,7,0.048000,'Toner Dust','none'),
(3305,'entry','ZsvaKa8fPKJdsygUGn83z7AzR8FzAFDzDudyLQJL9NVR',7,0,5,4,0.064800,'Breakroom Sage','none'),
(3306,'entry','hvvNw5YK1nNyBKjaJcvtZLYnR4ZfNQei2K15d88U6z1M',6,4,1,2,0.030400,'Toner Dust','none'),
(3307,'entry','AYBj2RMRa4cqHkaCZ7s8dDbESvrxpVvPfQ7FLJYVgPnk',2,3,7,8,0.053460,'Filing Grey','none'),
(3308,'entry','Rmuu6TCvBoo5wCfmxcGTWoLEnVgJtpMuJFF2e1o731o2',4,4,3,5,0.041400,'Drywall','none'),
(3309,'entry','91n73stx4FExbb2ByQcvVLFpCEbM5RfZkz66bR1MExVj',7,8,1,0,0.028980,'Manila','none'),
(3310,'entry','EJpeCV4VayMMcrCCPXJJ2LcmJBxJHhZEbUnA1i74JUHx',6,4,2,4,0.068820,'Drywall','none'),
(3311,'entry','8GCfVbkwo1cJMjGj7HS3tkn5RHHfKJumry9J26XKJqaw',2,8,2,0,0.031360,'Breakroom Sage','none'),
(3312,'entry','bbnehKJsoFZDgeS9vb8ea1dxuqvwzfwpwMSLZb5rdZLg',1,3,6,3,0.056260,'Breakroom Sage','none'),
(3313,'entry','mYSxs5HqhEsJg4kihmDhPPPEzKcCiMrRBSUyGpiwH5sz',6,7,0,2,0.081880,'Toner Dust','none'),
(3314,'entry','htKDFnq8ak4VENRTvwQNENBvK6rktjgpUwEnxB8trQQP',5,4,4,8,0.041860,'Ledger Green','none'),
(3315,'entry','Wgns7aXGDLiei7LuVgZCdqTPvJE7LXjGzLtpW7FUwgWJ',5,7,7,0,0.053940,'Ledger Green','none'),
(3316,'entry','Ad8fxQBxsG9hPwXrXSXb9d68DykMd1sFMDAdfJoa9qub',4,5,7,8,0.049770,'Drywall','none'),
(3317,'entry','4qiBArc2Jc6hrfNrk4HtV5qvojGfnFPfrjudnXZLMVZ5',4,6,2,0,0.059940,'Ledger Green','none'),
(3318,'entry','xgWw8oeqrdhVmB4b3erLmwq7DFELG4n1xAF33QsbVNck',2,8,6,0,0.042240,'Toner Dust','none'),
(3319,'entry','DkGBZQ8RHUZHdMQzAiQokXTyPPx5VAMpq8hnFt1iqgc9',0,5,0,3,0.061640,'Manila','none'),
(3320,'entry','WbCTed7wYfrcYwLDjEw4RXPnLqCVz9vCeN899a4Y3cyr',4,5,1,0,0.027200,'Breakroom Sage','none'),
(3321,'entry','opcVFRwM3pT414nG2X8Z6Luv2KtACknGQbbBPwKxgg1U',1,3,5,6,0.030000,'Drywall','none'),
(3322,'entry','CskGWRhAAdFFSPZF2kcqCpwwrUpMbT4rfT7GDCFYkaYo',5,5,3,6,0.046150,'Toner Dust','none'),
(3323,'entry','vKTpXEefZsq4XVEeFwYXitrJ6jHcmuBF5rDEh7TQPP6G',3,1,2,6,0.028000,'Ledger Green','none'),
(3324,'entry','tbTBAhFTQYnvCfvD3U4YG9M4MyKUkjrDd8bdrrDD46Xh',4,6,4,9,0.028800,'Cubicle Slate','none'),
(3325,'entry','78SA8RqutjHAQ6VnVxdCqTLaSLgyarnSD9WXte3RwqeV',5,0,2,9,0.059940,'Drywall','none'),
(3326,'entry','n5tajanmmqHntenbKhtUSu6VmevowZPC3dy14DyfyMdY',5,3,4,7,0.089460,'Drywall','none'),
(3327,'entry','GxBEYds8pTcHYN3chRxR54eqFpZvuRgWUWSgGouUCUjk',6,8,7,4,0.040560,'Manila','none'),
(3328,'entry','WYd24jfuQe4fNXBCx6HySQXyQwKJVfJdyAUgqAiWSCWE',3,6,5,5,0.037440,'Ledger Green','none'),
(3329,'entry','GAfUYbpUZvsfpyT13TjhWUgiYzh57ACzvP3pWAfYjMmX',1,0,7,2,0.046400,'Drywall','none'),
(3330,'entry','XGsfRxBz7UcbboTWXRGVDKSUraTSiYYLhswQpjTWipMe',1,9,3,2,0.056640,'Toner Dust','none'),
(3331,'entry','2VsH9Tv8a8PEaFSs49DSvA8xDA7VHTz3NKBDNN9pAe9E',0,9,4,3,0.030400,'Drywall','none'),
(3332,'entry','H3ow4oYcdtnMtdV96nsh5RkASUFWdJ8AJav2SGjajM5T',3,2,3,7,0.077760,'Cubicle Slate','none'),
(3333,'entry','PNqArbu2dVMLAVFqdTPdugSFUWBWVgDmPQ6BDaVR79zm',7,3,6,7,0.059000,'Manila','none'),
(3334,'entry','e4Dug7sNjYcQFFdAU4wQq51c85JGiEdtxK93n4XwNfAS',6,4,4,9,0.057040,'Filing Grey','none'),
(3335,'entry','cCVSsShkJ4JLhELpDu82DFPUfyLSPCiby7Jx4Cp6CwYy',7,2,2,3,0.031280,'Drywall','none'),
(3336,'entry','6Bns2PjaHSg4Loq7spsFTexvrQCojB36BsufAFNaJDYo',5,4,4,4,0.035880,'Cubicle Slate','none'),
(3337,'entry','jxJfz1UcAwwzDtNwcpjDx2G2Ek5Q66uynYsRE8nMF6Az',1,4,6,0,0.022080,'Toner Dust','none'),
(3338,'entry','kfdspaTnxoSEVV3LJMfCVtSoWy2cKup1fdwQGdMXbcKN',6,5,5,0,0.028000,'Manila','none'),
(3339,'entry','XBK46GZ52SherBE7TuxZisac6nwHpVSEPFZjJsiDNWuM',6,7,6,3,0.034400,'Drywall','none'),
(3340,'entry','vpthxdGJT1VbZBGPtvkHJqe7Vvp3tLyWz8BZRDmpLuc4',5,9,7,3,0.028060,'Ledger Green','none'),
(3341,'entry','HU9W7WAQVHnsGjT9J7M3rW4VGi6QVhJYkCu6wkEdyiVg',1,8,3,5,0.046610,'Manila','none'),
(3342,'entry','DMX9f7oyBT3xJagUKo1uiCb5JPSE4u5bwPN2PzV5n6dh',6,8,4,8,0.056800,'Filing Grey','none'),
(3343,'entry','RZFjEMtHwti7AcX4HLbq8QWA8xp4a13oXaERTwDor4Pk',6,6,2,9,0.046860,'Drywall','none'),
(3344,'entry','e9WV15V1vADWXhv1V1Pn1taHsG3HH5QLRAkaEnBxmFvE',0,7,4,2,0.025200,'Toner Dust','none'),
(3345,'entry','KBhFkj2UfH4xnqphgoqBpPA9KFrp6h7vJboz72rgrzuo',0,0,6,4,0.045120,'Ledger Green','none'),
(3346,'entry','hSs6zwj6Utd1RZQ6DvjEwv3gJF88Xdsfyu1KjGT6Yo2v',7,5,6,0,0.056070,'Drywall','none'),
(3347,'entry','nbMLDwTG2pipYCf2y1Ee1XWW9rjC69y9RptZusg4DP4P',6,1,4,4,0.027720,'Drywall','none'),
(3348,'entry','Bjv2LX35vode64Yb73SUiVkuBLSiTKRn8f7zW8xtj2Ri',7,1,3,5,0.024960,'Drywall','none'),
(3349,'entry','pFU53Veme7gUXwh44Bfy6YgiFiUAXPy38sfBSNRCYEy7',3,9,2,7,0.035600,'Toner Dust','none'),
(3350,'entry','5L77czKnmmQsxsJ8GGYfMCBuE3x6qdzZ7WJKjz4szWYY',5,0,5,4,0.064610,'Manila','none'),
(3351,'entry','zq7jWnciWzAcsN1CyZqrDvQa86CX4DKpprXLYLdsvuQd',3,0,0,7,0.059630,'Filing Grey','none'),
(3352,'entry','s3mY1iWeA2L4QjjSFMMdciPFkYctFZfu27NTumWcnwWE',1,5,6,7,0.046610,'Breakroom Sage','none'),
(3353,'entry','VXNrJsRqNFK59uacw7s6snZwkXpQP3qxdtuvWvBso8VC',7,4,3,4,0.020480,'Filing Grey','none'),
(3354,'entry','fKy8MbKKxV5XYiCN5zix6kf9LHut9neavW5TLFy3tq8p',0,4,4,6,0.071760,'Toner Dust','none'),
(3355,'entry','B6x2TmQTEcdLKZ99a3BhjUDveiWX8jVxR19f6ZdrTrzQ',7,2,0,2,0.076140,'Toner Dust','none'),
(3356,'entry','dB2cjNC5tpmTEdgukNMj3TkPJDVefotbGVV5MBPBCrGL',5,7,5,7,0.035380,'Cubicle Slate','none'),
(3357,'entry','n8JNQ58YQBS4V3JXkHGP6s8moaAUPQHuFNFC5HGF14rA',6,8,0,8,0.046080,'Drywall','none'),
(3358,'entry','eMH1dgTUGoKm2rREpfRqedeHQb9mG8GCTb3ZAu1dv71m',1,7,0,3,0.042840,'Ledger Green','none'),
(3359,'entry','ayRbPRSHz1WnJushSrcp94rFtf3XBHw4UNx9GXBTB9FZ',5,8,0,0,0.031040,'Drywall','none'),
(3360,'entry','32SZWJMh5LhHhuyr3rhzogjPdxeLcVX8ogEuPDNMvX3V',5,1,4,5,0.066600,'Filing Grey','none'),
(3361,'entry','T4Hgx5WB1kBiq2Gw5G1jp32BB8QCMiWBuXzcPDdhvvH8',0,1,6,7,0.055080,'Cubicle Slate','none'),
(3362,'entry','fG58gdNwB1c4TKTRoyqZm7ZFhY7e6X3PpiKHcBz6C1XQ',4,9,1,2,0.029920,'Manila','none'),
(3363,'entry','WGq8qHsZNYim5BrNmRGDSvT7JWj771evyVuUaaVrgXye',5,6,5,6,0.087400,'Ledger Green','none'),
(3364,'entry','Ebg6gK9v3vyTwXqWS6kSeapo6ZqfKJUaN5VDXEb82bnk',5,1,4,0,0.035880,'Drywall','none'),
(3365,'entry','VnhhzewFZ98cMFoUM8PWFmDHLEbscvRAzexQC7pocgAf',1,4,6,9,0.050740,'Breakroom Sage','none'),
(3366,'entry','NSk3T172PMG9h6JMsn8spNLY35S54CMv2MpMUjqsqdbH',3,7,6,6,0.059850,'Filing Grey','none'),
(3367,'entry','rReLJ2AMT5xFmKV44Wc4sWoEN47YMZTQa9hpfPiLm65c',6,8,0,4,0.088200,'Breakroom Sage','none'),
(3368,'entry','oAA59VoArq2eBqaHS6bTshWQzwH7LdemNutQ18HXRVWR',3,2,2,6,0.051330,'Manila','none'),
(3369,'entry','7ahre9zMFeF2pJrY6ndKkjxeyKJ5xRGGo9UVa65ikHiw',3,1,3,3,0.046860,'Manila','none'),
(3370,'entry','t3iqKZBHd8JgWJp6LrdgW8AVB4pSzBeYHKgMrMzS4xNP',6,3,3,6,0.050960,'Manila','none'),
(3371,'entry','swFwcAYjuGfpczzqpnzRpVhS3oLYyhoKzumVYh4bAvRJ',3,1,7,4,0.043560,'Filing Grey','none'),
(3372,'entry','q3XRba1A3GuKupspCwjWX483TjEBmhRXw7cuua3BnZN9',4,5,0,0,0.032120,'Manila','none'),
(3373,'entry','8mXRxMDqifP8aX8jhpD8SfFYFcKePEd1pvmLvfLynv1A',3,7,4,2,0.056260,'Cubicle Slate','none'),
(3374,'entry','ELE9SjvE9efnXdGuH4cUKpBiVUjzfW8ckFQydGytHHfV',6,4,2,7,0.064610,'Breakroom Sage','none'),
(3375,'entry','xGAWLfFmckhTBmgMYxzRfeXcMgmrsq6GNHfcLTgFJYvz',4,5,6,3,0.019520,'Manila','none'),
(3376,'entry','DD1p6xAS8ZKbYJfN2wpmtfDk4CbwNwF4r5bqobXvdDm2',3,7,1,6,0.088830,'Breakroom Sage','none'),
(3377,'entry','LTkft3WpKbqsBk5ebypcXdtdXBrdBtKzjeAZUJJ8pB2X',2,7,6,0,0.032160,'Cubicle Slate','none'),
(3378,'entry','GwSDeRGh7xW4EUt9oKGArDjJUnqDLMPec2dKJXKzR28t',5,7,5,8,0.026400,'Breakroom Sage','none'),
(3379,'entry','t3o2vbQHt5gF3y1e6tKpcSyjYQFt8ohwV24rT8q2LjZR',0,2,3,6,0.055890,'Breakroom Sage','none'),
(3380,'entry','N514RPAGpkd8L6sX7zAvSjD6ufYfyHCbDpWVvgwPgTfP',4,6,6,7,0.040800,'Ledger Green','none'),
(3381,'entry','rjN37L7ob36iRJfKFXawqw5ecgPN88v5jMvxMyCehC2r',6,7,5,6,0.039600,'Filing Grey','none'),
(3382,'entry','c5ZvoT719BTufEfsswvtWGjcQymVHjWAr937rj5Frgux',2,7,1,2,0.072520,'Drywall','none'),
(3383,'entry','AfoYLp9xjTV4tk5eTWGCFEMLYG1ygtkrfaGLHQcXtCVU',3,0,2,0,0.071280,'Manila','none'),
(3384,'entry','b99ddV8wVbBT4b2yy4VdDB8TXTjLe4uobAxR9dgcfWxj',5,7,0,0,0.021120,'Manila','none'),
(3385,'entry','mzTHW7eMGEDTCSq4nwQ51LERtAojyfk8X6pmW9QCTRUb',7,7,1,3,0.046610,'Breakroom Sage','none'),
(3386,'entry','DRXgMP3nEijJvRmNoh4TXgy5TH19ziekANEvUnPiqv2e',2,9,7,7,0.061740,'Ledger Green','none'),
(3387,'entry','S6wZBiiAeDazUVJPmKSvPKgQeUmsqH7VdQx5bLBLL6zH',1,4,1,6,0.052510,'Cubicle Slate','none'),
(3388,'entry','FA7RyEwxQEoB4S2aV4Wh4XSWpjz3ZLf4RBAGHGccsYkv',1,8,4,8,0.044080,'Toner Dust','none'),
(3389,'entry','kybFcgM1AeKEBtmu3AqjkzuVAAUbggpJdouJnWX94D6E',6,4,1,8,0.067230,'Filing Grey','none'),
(3390,'entry','VW2H9fEc72WK1ghwkmXrS9KLuKedPpUkMyBib2Tkts9W',5,9,7,0,0.054180,'Cubicle Slate','none'),
(3391,'entry','rdxjSu64cRaDvqb5Fh5PzwWAt6akmsjT3NkR9zWSAepC',1,9,3,6,0.037700,'Breakroom Sage','none'),
(3392,'entry','CbpFkqT6rvKswEYDnT3UiRoVqXYycNo8zRG6KGhyuT9H',5,5,0,2,0.034080,'Ledger Green','none'),
(3393,'entry','LbrVfGJByzpNRuWQNPhn6itoeizYJY6ce1KhSg4KRUf7',4,8,3,6,0.056090,'Drywall','none'),
(3394,'entry','uojZn6mcLYiqFyqKjsiT7dKDJoW3urbcqQ9NmckhkcnN',0,0,4,9,0.038400,'Cubicle Slate','none'),
(3395,'entry','ES51fJR3s4EaHNB11Y7vTHuhB3DWPUHzBtiCGi9vF7xo',5,2,5,3,0.030000,'Breakroom Sage','none'),
(3396,'entry','SVcUZEn3YcvCUzC4MtpKQj26pjk2Sj2G9NhM9ZxPyUUZ',6,2,4,9,0.030820,'Toner Dust','none'),
(3397,'entry','kDzobvpGnY6otcLJoyUdfE8XYDGDxc8pbCg8QUowH8Fo',7,1,7,4,0.051480,'Cubicle Slate','none'),
(3398,'entry','ewXU4fepZ1Th8UZX6yggGwSi3H43iE3ABZoBaL8rvHEf',7,1,4,0,0.033120,'Filing Grey','none'),
(3399,'entry','MmtkAHLFJQGGUZx2Nfrjk7abMSYkBwrssyYAkosiV73Q',3,6,7,4,0.062310,'Drywall','none'),
(3400,'entry','r3hhgP5K24dNQAqPunUg6VyBHDQTFN8etSmUpo3vyRHY',7,3,6,0,0.024000,'Drywall','none'),
(3401,'entry','pSZzhXSUzQ2Aqt3iYsC1FUmX3NXc3tKchUveygwAAPom',2,0,2,4,0.045540,'Filing Grey','none'),
(3402,'entry','3q2iqW8sH42CikcTvk3qiFYMSEsZvMS5ax18tqkgK9eM',5,6,5,5,0.036800,'Drywall','none'),
(3403,'entry','zRhLYPFBBANu5NEMCbsaQn9H32QAk3G7PfEcuSdmsNCB',0,3,0,0,0.031200,'Toner Dust','none'),
(3404,'entry','RrgNp2o5Xi4knWBTjCHbesb7sTviJBND21cGkjSxnSdE',1,0,4,9,0.072090,'Filing Grey','none'),
(3405,'entry','bt1JQiWdi87HCwdu5wtAgyM2UvsPbqQBv8VMy6dNgswb',2,1,0,0,0.050320,'Cubicle Slate','none'),
(3406,'entry','gQmrqfheMbMEwNQn7e6dRLLFJ8GFrvF18yih4AXV3gu9',4,3,6,8,0.025280,'Drywall','none'),
(3407,'entry','nVoozb7YGTNFoHvh9hd6TBEvEXBwKT5c311eSotjNFgY',2,9,1,4,0.074520,'Breakroom Sage','none'),
(3408,'entry','teMfRgdNdv9eE4Ebj7svcfmWMDvDXoh3gLtbjaHjgpgD',4,6,5,7,0.027280,'Ledger Green','none'),
(3409,'entry','DW3WCbstY3reWQadZ1BxLCrTjEonUY48Fd7oEgieJv54',3,0,1,0,0.025920,'Filing Grey','none'),
(3410,'entry','MWbP7D8xkoFTFFUsuxTS7eTmeGeN9qX5wFNawbEyeBWt',0,9,1,0,0.028060,'Toner Dust','none'),
(3411,'entry','QaSn6FWQpWesdAHgTHcQ46cMvoCisgPH24PcKewuWFp4',5,7,6,7,0.115920,'Toner Dust','none'),
(3412,'entry','Eu4pRqwmJ5mpS72d1byFWAFYCuzuaiEkHCRDJMuG6SQd',3,7,0,0,0.039600,'Filing Grey','none'),
(3413,'entry','NnSNTbdnHJYaSwyoVXp6P6qFiMG1vv6NGBEWSSKdU5ok',3,8,3,9,0.051660,'Ledger Green','none'),
(3414,'entry','DSvUy68rbGUV8aMrxzqLkhkzwE2Z2aRHWzHNojYZyRv4',1,9,4,6,0.047360,'Ledger Green','none'),
(3415,'entry','VeqrCZ4BruozhARVV3fRuNqAz7gmJsKbviNGvaaC1VjZ',6,6,6,0,0.026560,'Drywall','none'),
(3416,'entry','J3t2MiPpBteAJKKg9ewYrmukojgJCZf4C8Jvv8BScFN8',5,7,0,5,0.049770,'Breakroom Sage','none'),
(3417,'entry','hU5PpaUy3Npy3dTUVCQ5ZgxHmoB2KBfN9wgQPQaGqx3J',7,8,4,3,0.032240,'Toner Dust','none'),
(3418,'entry','nTQGRj1p3ZGv7GTMTNgPCPP5hW2e4bYBur5N6LWaj6GF',1,7,6,3,0.074520,'Toner Dust','none'),
(3419,'entry','5NgAZ5RmXKaCH6nbtfaSxtCve99iJr6xGpwk8u7RFw66',2,4,1,7,0.034400,'Toner Dust','none'),
(3420,'entry','23wG39b1dVWePdLemWRptgHmbDnhgTPicmfNqzucgJTZ',6,8,2,5,0.138180,'Cubicle Slate','none'),
(3421,'entry','irzNt6J94aXdRgb4YRJZaN9ED9mTC6mkiKKMwb83pcFz',3,1,5,3,0.033120,'Filing Grey','none'),
(3422,'entry','EQNSEPGQAFyihKemxqUceTFMy6NaiGfSNuWhZ581L9qY',1,6,7,0,0.070840,'Manila','none'),
(3423,'entry','AZTnL4rTnJnKNEbtJZNydjsaWzmYvYzUstgAcQAnWSbc',5,6,0,6,0.052510,'Filing Grey','none'),
(3424,'entry','X4yqJGBeJHQxb1vVttYgx4TuxvcbewRfyFBjU6fDKbUj',4,9,0,5,0.062480,'Toner Dust','none'),
(3425,'entry','wvw8HDVjvDkNjbCgwuCZFBN3mTTSAUkve1uDw3Xize3p',1,2,2,7,0.043700,'Drywall','none'),
(3426,'entry','GzZ12jK1dybkMtYH5xhbnoFjgi4BMKxehMd14tmhdJvy',3,0,0,9,0.041540,'Filing Grey','none'),
(3427,'entry','xJRroP2sPRK6diVHfBEeDujJcoKFmYeHXku46KV5GWEs',7,4,6,8,0.046560,'Toner Dust','none'),
(3428,'entry','GmzuS2VaVYmka5kkm1KZFFeh3Pgng2rnrTLHLjFCdCJS',5,6,5,7,0.057820,'Breakroom Sage','none'),
(3429,'entry','g92twKPXobDPjAYpcuaUmromufsar2pFDDgbxSKurp9t',2,4,3,3,0.046080,'Breakroom Sage','none'),
(3430,'entry','XN8fxey9FDfFVQK53KVNh1DM5t9pPmHN5DDgDks1abdZ',5,7,2,8,0.041360,'Breakroom Sage','none'),
(3431,'entry','5wP9HEP5EznvfSDAinv2Pcf9Y1XR6f5A9CcrtPW9gwN1',0,6,4,8,0.073600,'Toner Dust','none'),
(3432,'entry','YDte7eA2R6yK6NUGojpbbY9xJnNyotd2yHKEKKBRAbMG',4,3,1,9,0.041180,'Breakroom Sage','none'),
(3433,'entry','EsyWm6BtpgE3TwoswXFPY7k86iEheNX4HJYwWzkCyFqz',4,2,2,3,0.039840,'Cubicle Slate','none'),
(3434,'entry','xsrR6NM5moq1b9SfNKTjFNx7C8sEKCZzLXgkjuc8T8GV',0,3,3,7,0.026400,'Cubicle Slate','none'),
(3435,'entry','N6bqrrMUGmbDJQF4Er74xkvAhBQvTmjEA3mSKUY8GWPo',0,5,3,8,0.044080,'Ledger Green','none'),
(3436,'entry','SSgGqtteDyqBohmBPRNNAdsj7m2EZ2pHRTRcu7wJdDWy',7,6,7,4,0.051590,'Drywall','none'),
(3437,'entry','NBCxRh8F4Rupr5gJs18WW5mYJPb4XYvrrwPszfwCWxcL',2,0,4,7,0.020800,'Ledger Green','none'),
(3438,'entry','AeL4cKdBJ6idjt757kZv5161CgkqSR1Kd5qRAivS5RA3',1,1,5,2,0.097290,'Manila','none'),
(3439,'entry','NLs46s2YfXb1776nCpwnFSDpKfF3rXcLDmhaZZ69wgMe',5,6,3,8,0.041280,'Ledger Green','none'),
(3440,'entry','SpgsguFTpwvpVaGThMYsevm45zpqh6ft9xqWvBBjXGQd',4,8,2,4,0.056090,'Ledger Green','none'),
(3441,'entry','KiEycPgfcTsW47x78e1EpZzjd78vcKuL6kzquuwh1t1y',1,6,6,8,0.062370,'Breakroom Sage','none'),
(3442,'entry','LDaoFnT2hEbkuwbUfrhqqpUFH3q8j1vZxe5S2rvDcN9e',4,8,3,5,0.049920,'Ledger Green','none'),
(3443,'entry','Ux5JL8sUEp5CNXTcjyV7J4asydFE5k5RE5RSH3SVrVSF',5,4,2,0,0.039160,'Manila','none'),
(3444,'entry','U8VewX5z1sJZJ3nij6BL2M7tkc9CQg9q4UabuzGbzCWX',0,2,0,3,0.051590,'Toner Dust','none'),
(3445,'entry','vdt7BYgUc3FqzPdWyoXz9UWSaHZRgTBgbRYRKyEvLnTS',4,4,3,5,0.054810,'Breakroom Sage','none'),
(3446,'entry','HXJC8ycbKNBgR8J9L5HQwEhFpaQaJ3N8gWFRM6ZYWeBH',0,2,4,7,0.037800,'Manila','none'),
(3447,'entry','kZuDmZ5j4Xni14DKFN3jYFcjXvxMJfoKhSYTREDrzHDU',1,1,1,2,0.047320,'Ledger Green','none'),
(3448,'entry','LA1KTMi6yvSCCpTRCzq3tLDid3XkD9n7BH7GA5aX4Cdn',0,3,1,0,0.046230,'Manila','none'),
(3449,'entry','KgXwcm8qjBDcJRaa58Ae6GkH22dvdhp5TSEPR2UVS14m',5,1,4,2,0.045760,'Filing Grey','none'),
(3450,'entry','TPmpHEA9EWeszrZyYgKERaMLFpAAZ6LbKvyM8Cre579A',3,3,6,4,0.045820,'Ledger Green','none'),
(3451,'entry','MZEv6EwaFemrTvdqEktVrnwzveztyppgcCwD7qweWGyB',2,2,1,0,0.066600,'Manila','none'),
(3452,'entry','BTGaV69K2bxFaKGPgZ13RXcBQMgL8tSAxtSqMSV3Mvms',0,4,1,7,0.048280,'Breakroom Sage','none'),
(3453,'entry','eSYEecU6ttjmExVfgm1JYBR5UU9M6FuQXYYoWSXmxcsh',3,2,2,6,0.041580,'Cubicle Slate','none'),
(3454,'entry','NpCzLydPDUGgtbGmXCGFGw7yPZzPKr6YFozfZgsVxdWP',3,1,2,5,0.030800,'Drywall','none'),
(3455,'entry','SMrzAbDf5fv4HvN31hGJx3QGp5qeoD9ACYqm6coXnhXE',3,7,4,3,0.024000,'Manila','none'),
(3456,'entry','Z5QAMypZ6cedmaZrU9sQGWbe9ybYwZAE3szBfZUHZGia',1,9,0,0,0.055440,'Toner Dust','none'),
(3457,'entry','1Mks5WtLpDUR92N2QXZLCTyvpc9rqWmhGSwQegBHhDpd',2,0,6,5,0.043160,'Cubicle Slate','none'),
(3458,'entry','68PFBr6eaQrPURW6mKMg7oVhEbkEz7frGo7hNVHcyKXF',5,9,7,0,0.036000,'Toner Dust','none'),
(3459,'entry','E9Si9rwM74tdttDUPymA5G6VHCaLtKWr1MfHLL7PBCSh',2,4,2,6,0.026400,'Cubicle Slate','none'),
(3460,'entry','8Cm9iCpxURc57w25dibhEZVzHxndGexQWo5UaAsB6D3M',2,9,7,7,0.038280,'Toner Dust','none'),
(3461,'entry','YHgkyTg9jBMfMSdnGf3kRWPj4R6dTbTjiBpjxabzBv6z',2,9,6,7,0.039560,'Breakroom Sage','none'),
(3462,'entry','3oBFEv44Fq7DdtU6FzGCPgnwoaG6M3PuogeVkLvKptjL',1,3,1,0,0.083720,'Cubicle Slate','none'),
(3463,'entry','HCuUewxXgQozEnC4p5Gw4pSCS6JStoYEoXoaGjgjr1Fd',2,4,6,5,0.032000,'Drywall','none'),
(3464,'entry','eBpNUBYwQJeJbe18fac3DnbEfrV19i8P6JcLd75SnAaJ',6,6,4,7,0.044730,'Manila','none'),
(3465,'entry','F5vchEA3qJw9Tzmr4g2fJqF5UzNY7sCWqwU4kkJndwFj',2,8,2,6,0.028520,'Toner Dust','none'),
(3466,'entry','Z2DHCLhYJhNKagtRNeUvpYViAPkjQxMp67h6HKfnkqLM',0,0,0,5,0.030720,'Cubicle Slate','none'),
(3467,'entry','15api5CE6J6R36BwowdndJkUBTmKJdsLUr6F4G982ERq',0,7,1,9,0.040320,'Toner Dust','none'),
(3468,'entry','7C3DrTFpJZFo3Q4gQe9hAKyt2Eagz7VArWa2CWtGg9kY',0,8,4,6,0.044080,'Cubicle Slate','none'),
(3469,'entry','GuvxduucmJuAJNSrNo1fXu3zd4zUrpaZBRT5xdztyeTF',5,1,1,2,0.042720,'Breakroom Sage','none'),
(3470,'entry','pH7ynE545rBbiXd4PXDZqPUcGqH1bcqrgttuB7zXFAxn',4,7,6,2,0.065320,'Toner Dust','none'),
(3471,'entry','8nb364b6Nh1jqDxPXMAgd3RNrnDeZz8yFYnr2hXY3GDu',7,1,3,9,0.038800,'Ledger Green','none'),
(3472,'entry','mrVF3HgmUFsecmALcA8JqihjRpZezuHUBnevEXydjeG9',3,0,4,2,0.031740,'Filing Grey','none'),
(3473,'entry','r5wWmsA4PfGokuuQViKEUqkfNJRjSrT7bpLbKjYWoGj1',3,1,4,7,0.057040,'Drywall','none'),
(3474,'entry','xtjmjr1APbPPvBmAxBWycv7L7UUJ7tN7D9QZ5zCBgUkg',0,0,7,9,0.043680,'Toner Dust','none'),
(3475,'entry','3j5YhapUNArUTaLhLZxNKatAWNaMAnjs96huYgmGAsw8',6,1,0,0,0.051840,'Ledger Green','none'),
(3476,'entry','TgUbYWYCSjyGGcie3e1AcsYt7RCWqfXhFP2CB7ZqQFmD',5,7,6,0,0.045240,'Ledger Green','none'),
(3477,'entry','VpiZSkYsCbw5yoxVrTVseNZZUhD4mWZVEWXcCiY6Bq9v',0,3,2,5,0.041400,'Breakroom Sage','none'),
(3478,'entry','6PU5H91cUJsN5P2nmEzyoAQzMvVhdYcgdtNCq9nQxup3',3,2,6,5,0.072520,'Breakroom Sage','none'),
(3479,'entry','xNxyHZutkCSrxRc4uEZxG3vJzHuG3iQ91D2D1CNfdQM3',3,4,3,0,0.079120,'Breakroom Sage','none'),
(3480,'entry','mMDqa3oLFTGnUwdb9brGAPD8Ltud6niHz73GpowJxdhR',5,8,3,0,0.044080,'Ledger Green','none'),
(3481,'entry','adpVYFqFYjU1NjtRiij5oyANVQLNk7mYxmgA7pY6gWqA',2,5,4,7,0.031720,'Filing Grey','none'),
(3482,'entry','WpFFkVdHc84q4t29LFQPbRj4YW8B8mqzzcXzeEoLbapu',0,0,6,2,0.046560,'Filing Grey','none'),
(3483,'entry','2gwfpNoU4KhDwSP7RcaaXReLDf6SyFLXT2Lg5ZTVkaW1',1,1,3,5,0.055500,'Breakroom Sage','none'),
(3484,'entry','Jm8Yu5oF51Ri9NjnMC7FTYMrL4WKBs1v3UKquFgRTXuj',5,1,5,4,0.039840,'Ledger Green','none'),
(3485,'entry','29nY2cVKhDfGMaqB1vMqTjSNycRXBjzEohSkenQE6zaA',2,6,4,8,0.030720,'Ledger Green','none'),
(3486,'entry','HPvrBWNpz7WkwJAFV5RK6DC9YtHGqmGG77AJkGKjgz27',5,0,0,6,0.045760,'Manila','none'),
(3487,'entry','EFQZ915jmJFVx7KqqqztXx8RvqKSBLEkawVfLLW7deWR',0,2,3,0,0.055500,'Toner Dust','none'),
(3488,'entry','9wZxAfomVfe42ZLxyBKZSS1GYrdfXEGzUd1zBmUQPGW7',1,5,0,2,0.048100,'Cubicle Slate','none'),
(3489,'entry','kzEuJKLqxUQ8XG5Wni3SGP8CS5dN6U6b8cRh6WBKrZDs',1,5,1,0,0.037600,'Drywall','none'),
(3490,'entry','6EAJ86aHg2FSDZC9T5LPyS8dw5H8pwT2H3zJMBqWokxZ',5,0,0,9,0.026880,'Ledger Green','none'),
(3491,'entry','X3LEM1Mzsggv1gEXhLvxohxYP6bqrwJ4ppG8y6UbkPc5',7,5,0,2,0.037800,'Breakroom Sage','none'),
(3492,'entry','TgwUAmurrKeH3Gberqi8zMST4fbovtSVMa4SWLHpmxKM',3,8,5,7,0.034000,'Manila','none'),
(3493,'entry','SjBhY6TM4rTDvC3bcMF7MaDUsvW6JyAGuVygSmHdq4cU',5,0,7,0,0.028520,'Filing Grey','none'),
(3494,'entry','AMfvSxDWmD47oHU3rMYZk84P1XfBEC8PDR9WGqVYdBqs',0,6,7,3,0.051840,'Filing Grey','none'),
(3495,'entry','RN2zDXbgTXTYEbnHa234p8FPjLRwTGBbjcEcwGukpUcX',6,7,3,4,0.040480,'Toner Dust','none'),
(3496,'entry','8MCf5Eb1qedyAHvYfHG4zE5HLPhZEEXBbmAcqebrfQMA',2,4,3,3,0.024960,'Drywall','none'),
(3497,'entry','uihXVHEzE52CxfG77XkrbVd3BLwwzwBMAn9eMZJAJtkV',1,4,6,3,0.052260,'Manila','none'),
(3498,'entry','diSqALyMEvFUhv9husxBWgHfvo8upe6Y52vnsCTniVd3',7,5,7,2,0.028160,'Breakroom Sage','none'),
(3499,'entry','REvuzoabW5o8o8XhAZP8pEWB4zjs3eGBnHS6HyQdxB98',3,3,4,5,0.044200,'Cubicle Slate','none'),
(3500,'entry','dyTxwrFmksfoNx7ToHbrzczsPTQRdSdqnwYqyMTdD9Zw',3,8,3,2,0.044160,'Filing Grey','none'),
(3501,'entry','2zFqU6JVy59HEe7zFvWDFZS2weabqKphnDKEK1kHQ53K',4,2,2,0,0.046560,'Breakroom Sage','none'),
(3502,'entry','W8JK9KDaz4GpsjdSV36drTo3WPqw7pz67hR7gEDBj7zz',6,9,0,7,0.023040,'Filing Grey','none'),
(3503,'entry','Qrt34iR85Ttm7aFtx633CCefNhxNTjFeF7suT1QoJVL8',5,8,7,4,0.027840,'Drywall','none'),
(3504,'entry','sszzfPMVSYVxBoRmzWwf3pFFbYCcmdMcDdZU59PkCFcG',2,2,4,0,0.057620,'Ledger Green','none'),
(3505,'entry','g7MFsnUu5NkF5ooywcCbzdnEVA8Z894yp4RRjj2R9jTY',1,1,1,6,0.031680,'Ledger Green','none'),
(3506,'entry','eanRcGdLGzGoMuP3NtPz38hM25Z8CYB62KkKDuWmKYN5',0,3,7,2,0.037800,'Breakroom Sage','none'),
(3507,'entry','rbHpdw8ispgaamtd3NftWPaEpbsVskFA4qjUiZEbLTjd',7,2,3,0,0.055100,'Filing Grey','none'),
(3508,'entry','ikKCQGeL7k2wACAw4VeHVHga5euA4k9oWx49w2ABBkpD',0,1,5,0,0.031240,'Toner Dust','none'),
(3509,'entry','giCX7o9xXXFRPNH1qofEp6DUaDuDGsCnp2GXKo78n5H5',3,6,1,5,0.053940,'Filing Grey','none'),
(3510,'entry','pVZJaxsNSWCaswmTytC8wrPjRv2BibyRmrkjubhJV7qV',4,5,3,2,0.047790,'Cubicle Slate','none'),
(3511,'entry','SSWktKn28uSoejuA1234gxgUTFc8EjjjaWos2pF2qv2S',2,5,7,0,0.042640,'Breakroom Sage','none'),
(3512,'entry','g8uw32juuCUrupRZFsJofW3hcevtsznx9APd3xXCZL5R',5,9,1,0,0.032120,'Manila','none'),
(3513,'entry','tgByvSX2aSXoPEegKQueynbU2d4wVi24vx6vbRUYMMWm',1,3,0,5,0.057510,'Drywall','none'),
(3514,'entry','Kd6EfdxBGJaaxHmJeDiY2Fp8L3ZJtb7Kz5vcjSePUp9q',1,2,4,7,0.040480,'Manila','none'),
(3515,'entry','Cc9HKRXZRmkr5JyoDMehrYJzLu4EbCGUgqpUcTVpCruS',0,9,3,0,0.080640,'Filing Grey','none'),
(3516,'entry','mZQgCCixmgpCwocg741z8nzNNwr1hTNp1LAFVMz4M7Tb',3,4,7,0,0.058290,'Manila','none'),
(3517,'entry','msc7T8twSAmDcexeFXaHYyp69T4TWRygbLQHkAGYQcV5',4,8,3,5,0.095760,'Ledger Green','none'),
(3518,'entry','97kmYe4YZU1xiJ8z74Yxk3HPrEfzSfqJNZQoeVgsfS7W',5,1,7,4,0.045120,'Toner Dust','none'),
(3519,'entry','K4VbHP7J1jG9SpejDmxRxNU8oxnCpF52HB2oSAC1wRrm',1,9,3,3,0.027280,'Manila','none'),
(3520,'entry','nyYzEuNtTMYKPvwpxh67CdY2stPftsks8D7KBjSukMuq',2,2,3,6,0.032760,'Drywall','none'),
(3521,'entry','ryBzWzjHUxL6U5PmTJBe9WacejywsozCpQd82D4edNrr',0,9,3,3,0.044250,'Ledger Green','none'),
(3522,'entry','qGzFJ3nijgJVvSTRK8eyJV2EaSZKBt8dQkcHWfFPMaeX',6,3,3,7,0.034320,'Filing Grey','none'),
(3523,'entry','gpSHmGEYiZkvVQWFfzPBfwkwqgXjiWcWQ7NXmTpgnF2j',1,7,6,0,0.044220,'Ledger Green','none'),
(3524,'entry','qczj1dDDGBbxVWdRhRfMGjcJCB2KfNchWF5c9uh7StAJ',7,9,2,7,0.031740,'Ledger Green','none'),
(3525,'entry','rb5jUKBYrVM7c584BSsxhkcbZky2kVPjrmAu2rrMa6Dj',1,6,0,6,0.050400,'Drywall','none'),
(3526,'entry','BLH1Avx2wM1hznhs1uGiUZ69LcpX5Jqw9k5fhfYtN2s9',6,0,5,8,0.051120,'Breakroom Sage','none'),
(3527,'entry','EozAz2TjckkLTsuxeLcqfabUquhMRDt4kb64eUMTF4uF',6,6,2,0,0.041580,'Ledger Green','none'),
(3528,'entry','qdRSQk7EK9bMPLwv99SKBUSQ1Vkx2KeLrNVxqRUU6Zeg',7,0,7,0,0.090160,'Drywall','none'),
(3529,'entry','z3RmPFoJyovSfZfy96ASa5t3TrL72o15g4ti55dMDnLj',1,6,0,8,0.054760,'Drywall','none'),
(3530,'entry','cRTi9Ygyx3xoGdnLepZKqKjmR11pxLRyn8navCXVSeTT',3,6,2,3,0.046020,'Breakroom Sage','none'),
(3531,'entry','fT1K9CeaSGVzifsBmk7s74eKtSEkcVQYXEE6KGdadSpW',0,4,7,9,0.047250,'Manila','none'),
(3532,'entry','ZoawwU6brDTTq8KriGbAuDBysUdtuST6rLWTKphuQxk7',6,6,0,9,0.084640,'Filing Grey','none'),
(3533,'entry','zyCZV5yRLGs2S2eDCiDXFuM2YXoLneRKYfD9XG2EVLGZ',1,0,5,8,0.050400,'Toner Dust','none'),
(3534,'entry','pjVyDDqdPEEiZCwX44ryvasBxqodTHo55fgQ5bvUHTMa',7,8,3,3,0.035420,'Breakroom Sage','none'),
(3535,'entry','5qjajEzodfJUT3sdZnbyU25TTK1BSkPwrm5JQgV86J6r',3,6,3,4,0.041300,'Manila','none'),
(3536,'entry','aGULjqKiN12RzSVuTS7PAVq7TVHFxpWeAi2gJhoWLT2E',5,5,2,0,0.039840,'Filing Grey','none'),
(3537,'entry','rbBoWp5ckWmiEqqtWzvtBtdZ9MEt3fExPCAZeFfqu5Hn',7,2,1,3,0.041180,'Filing Grey','none'),
(3538,'entry','R7fLbYAojWA1zdt811wMURJ8cNKkBHp85Ld2tjKaVVe7',1,3,7,9,0.036520,'Manila','none'),
(3539,'entry','eSE3MfBQ2Bv89BBZKypXosisyNBnaC8sPLvmDjQsyvUp',7,8,7,4,0.053960,'Breakroom Sage','none'),
(3540,'entry','Vdy7cLL2dxqhccPDcBchr9xb6VTkyfPNbWetfo1Bqqoc',4,1,2,2,0.031360,'Filing Grey','none'),
(3541,'entry','jgZuAoarHmqZG2BatccTX7mKdwQpuqstXtLoA12ryZYw',2,4,5,9,0.027280,'Cubicle Slate','none'),
(3542,'entry','PMrRL92op5KuPquh9dt4Lrbzp56djdBwbWyTZVhTMZTr',3,7,1,0,0.075600,'Cubicle Slate','none'),
(3543,'entry','619c2FJBQwyrWMuGDjT3xnBBp1cqrM8b9c1LuFAH2qqF',4,9,2,8,0.059800,'Breakroom Sage','none'),
(3544,'entry','pqy3zR1B92aSfwWttZSGd1S7hhauHPiAPmiygfLPirUd',3,3,4,9,0.031360,'Ledger Green','none'),
(3545,'entry','9UE84pJufchAaWLVSsdohVAuKyccecwSTmLoSPLg3pHV',0,1,6,0,0.021440,'Filing Grey','none'),
(3546,'entry','xVeZggXHVMpSK3MVQZ9JsWGo4h7a8nHiTe8Jo6KhTdMG',5,4,2,3,0.053280,'Toner Dust','none'),
(3547,'entry','AMo1xW3vTsH2EsfBvXpr81hKtjKi8ggUzu7YLyW7GmUF',0,2,1,9,0.033580,'Breakroom Sage','none'),
(3548,'entry','9awtKWJeXcENezyrTMNu8vHdyxnkLtjfQQd8voKMdumV',3,5,4,3,0.048880,'Toner Dust','none'),
(3549,'entry','oiSr8XEqyg2Ynk69kya3j7kocfUa7fts9bJz6FxMQXqV',2,7,5,9,0.050460,'Filing Grey','none'),
(3550,'entry','HgLZcriXD56yi5mALZFu4MR5Kw8DZmu8Y7cHYVaSKWxr',6,1,2,5,0.037840,'Filing Grey','none'),
(3551,'entry','4ECCRdeRBxjryK84PVE4g2X959mytkan4mvcT94kk1wm',1,5,3,8,0.048380,'Ledger Green','none'),
(3552,'entry','A4kY95uqT3dZRcZHf7RdFr25DJuFXmCkmW9fpsSLaehW',6,3,3,3,0.025200,'Drywall','none'),
(3553,'entry','g64p4pMU81tRk9iFBZtaTaMjx7VCRv7BcpYQRyjzmyBS',1,9,0,9,0.036080,'Toner Dust','none'),
(3554,'entry','p8KTGdkp8nu48sAPYELbbKePVK3a1PyEVSWaphDxxXun',1,6,7,4,0.030360,'Filing Grey','none'),
(3555,'entry','jrp3CLUyM7hpDZrPfGBnXbL9voiegWVfpinwjteUqASf',5,6,6,0,0.020480,'Toner Dust','none'),
(3556,'entry','gRfDV6drHPZRuG6P4NbPmamCyMUsJHuMmpVPa57tzCV2',6,3,2,4,0.055080,'Toner Dust','none'),
(3557,'entry','9AKdCCjEgkkkS1gWBpQLZfQPxMppnXtdoDXqTCqjgqLz',7,9,2,0,0.042210,'Ledger Green','none'),
(3558,'entry','4yw5fPJViuZDNz6XJ9cFm6oyWvwkcuxxmZvP33xCTYHi',5,2,2,9,0.026400,'Breakroom Sage','none'),
(3559,'entry','cwc6aZx63ZPpUnEEWoasAQiRXB5C9V1z8YrkoU2CfFus',4,1,1,4,0.053460,'Toner Dust','none'),
(3560,'entry','7Y6FeiCk4zVuwSwmm8Kp35XUJwXKjnSXfoqE7JuzyHky',4,0,7,0,0.048100,'Drywall','none'),
(3561,'entry','c9SexSwq6CG8a1hn5ozvG2sSy4tgAG14p4TPe4ii4oJP',3,0,5,5,0.029900,'Toner Dust','none'),
(3562,'entry','YzjbL1DU6uMCJ6BRPwtyXvpcY2Qc2N1x8KP2CksYJUQz',2,8,5,8,0.055500,'Breakroom Sage','none'),
(3563,'entry','Hv4pg9badJ84HpLjZkJ872LvGTBxBEt1jJK7X8ZCRmM4',0,8,0,9,0.036520,'Manila','none'),
(3564,'entry','Z556vbp3Hj27YcHAzSpZwTAnnofZmhbM3trQ5iymeCt7',0,7,5,2,0.088830,'Toner Dust','none'),
(3565,'entry','fCN4GzBRa4mL9cWeJewHVwANtTqeEtn8yQUqfoR8y7Zx',1,9,0,4,0.038430,'Ledger Green','none'),
(3566,'entry','nqzLmKV9c6Cqq3Hfk8K8bwq7aivqXtkzCzM2ym5Fcrie',6,7,7,2,0.052000,'Breakroom Sage','none'),
(3567,'entry','2Q8ScACG7QovSaTYjUiTeH2geS7vCMqyCSRotDPL5Bgf',5,8,5,8,0.048880,'Filing Grey','none'),
(3568,'entry','SF5ynVjtui1cDREKQghRxTKfXjEiKjBH1Nn9M6UZjmQi',5,5,0,9,0.075330,'Filing Grey','none'),
(3569,'entry','fTyWSRdfcBYcWBjsuggbZ3EM5vURdzSy1kNDFHEWziua',3,5,2,6,0.029900,'Ledger Green','none'),
(3570,'entry','Jv11TcrrXy61DFjMAWdxTrAZKbdnKJ6EcoMNLZkjtN6o',0,0,1,5,0.056090,'Ledger Green','none'),
(3571,'entry','Qhz852MuGy9JGLkfchvBkyutkoaHz31ftvzNoopTuZ93',5,6,4,9,0.072090,'Filing Grey','none'),
(3572,'entry','HBXdjuUCNihTMui9Xne9jLW23x3bRx4V3cWAehTukSgg',1,9,6,8,0.073260,'Ledger Green','none'),
(3573,'entry','uKdwEqz5GUCpLB7meVGBNygSandeTpreptzLr15ugq6M',0,0,5,7,0.051030,'Drywall','none'),
(3574,'entry','z7gTRngFEzsqRHcBxKMmCy7HW9YTrsTBjqKxbPVQ5Rqt',5,4,7,3,0.045080,'Breakroom Sage','none'),
(3575,'entry','LaJPKFcekRPt2gtEzwkZtv6uGhDF541W46LuoW643eQZ',3,1,2,2,0.035200,'Toner Dust','none'),
(3576,'entry','k7vzvoBgs4qDkfenMoDbRQsgGB8FCiNJfFf4BHmGDX3a',6,3,2,3,0.113400,'Breakroom Sage','none'),
(3577,'entry','izTzPh59Quyehs54UkRMbbpNYdFuUAMtyzJHwxaqPM5M',1,5,7,3,0.040200,'Drywall','none'),
(3578,'entry','cGCpCXhtpXjm9gEX4fZ7UbYPoJTPFc8GeVRRqy5iXC31',7,9,6,8,0.079380,'Toner Dust','none'),
(3579,'entry','knDsBvN7E9G4acDGgTg36FZeezkjVdnLxnZkbvcezmx7',6,7,4,2,0.029920,'Toner Dust','none'),
(3580,'entry','eZkeHFDtfwZ8LKJ2trATNt9xPP2FxAs4uzDkCq9qCXtV',1,9,1,5,0.038430,'Cubicle Slate','none'),
(3581,'entry','QXZDXjYoMC6xgLx6T91b7tPYhMCjLhpd1KVKnabqEFLJ',5,8,5,7,0.038280,'Ledger Green','none'),
(3582,'entry','L7GbWjKc1Eyg2hX8agcnnQU3cZgiTA1YxuQS8twJh7jP',1,4,6,3,0.040480,'Manila','none'),
(3583,'entry','ffYHgz4PKb5HCnkkfdYWSWi8xmfBp6DVuDBnyS6tgm77',5,8,1,0,0.033600,'Cubicle Slate','none'),
(3584,'entry','ikrjwgewZvtgNGMstq9uyh6SP3rnFU6F7t6QAqPMJ9TV',7,0,5,6,0.032000,'Manila','none'),
(3585,'entry','XY8dNFsvVJH22zQxV6bShniNsLyisQAGFW8ZJMaoVmrQ',2,0,0,5,0.055200,'Filing Grey','none'),
(3586,'entry','wXKMBUJjEnhiMxXFxAn5Feh9D5fhDYyh3wuYLcZJ1yds',7,5,4,4,0.033440,'Drywall','none'),
(3587,'entry','LJDVme794pnH743eKovykYcfquvbY2MD139jxMY9WyKf',3,6,5,9,0.066420,'Toner Dust','none'),
(3588,'entry','trnBu1pAPL74xzG4qdy2Wdq5nR9xDriDpCpDF4S1mgxr',3,5,1,8,0.036580,'Breakroom Sage','none'),
(3589,'entry','LL849kSn9WK4wTYasSC5fWkoxdJzzgf3u5o8cGorth6w',0,9,7,5,0.058290,'Cubicle Slate','none'),
(3590,'entry','yuV17VM1REH7RYBckM2RX8KcDtwF1RnTDocTqgXrP1e1',0,2,4,0,0.032200,'Drywall','none'),
(3591,'entry','VT397ayZ4qUL1vceek79f2rANncum4p4ZTssK26guW6g',0,8,5,6,0.034800,'Manila','none'),
(3592,'entry','zjXgqAyCqq3zVYUQLvPuEBdcK16gCZeDrbgBQR4rmoEb',0,1,6,6,0.037840,'Drywall','none'),
(3593,'entry','xniVAMxfFLwNe9p3wEaYVgSKCvX4Wfq3YUE4hnJ19Qfy',2,7,4,0,0.026800,'Toner Dust','none'),
(3594,'entry','PToN32sW3AzWzoM73vRKLWbodk6978LMtV2EemiUsztb',5,0,4,7,0.058880,'Breakroom Sage','none'),
(3595,'entry','auRCwTTCZBqm4qMhL4kn2WgbdrZHDDBj4PwjM5KNxNTs',4,0,5,5,0.041800,'Ledger Green','none'),
(3596,'entry','UsWRmKw3LhVaGfc1gY4KPw84XQkpygkbTuaQueiN5kzj',4,2,6,7,0.051620,'Filing Grey','none'),
(3597,'entry','MVMD5encFpTt4Jp7YNgeaT71VjuoJWCwDaQ4Zk6YdmpB',5,1,1,0,0.057510,'Filing Grey','none'),
(3598,'entry','e8cf51GaUJhEKej2PoFAWsSx1VLQb22UMwyinxLsAomn',4,5,0,0,0.071760,'Toner Dust','none'),
(3599,'entry','EzEqQr9B63R5zAsinxiqDwRSjdaWZpDV1FKCRbv5zUUS',3,5,2,0,0.043160,'Filing Grey','none'),
(3600,'entry','SUw16wcfnJBiykBSPJmmw4J5ahULuXrwHXsNqgNnY6bS',6,8,2,9,0.037920,'Manila','none'),
(3601,'entry','RPxY5y4Vd7PFVHrqrqcidsnXSeWnhpEyi3hHiSuKsheK',5,7,7,0,0.038860,'Ledger Green','none'),
(3602,'entry','cahNaZbUPGSc5qYR2r9yie95jEzaxXYaYE2y362KCdXa',0,0,6,4,0.041800,'Manila','none'),
(3603,'entry','tMHX4kdqjdBFBft9GcmwhVdb3Arpi8496yiuRvLf4Bj7',7,8,6,4,0.042320,'Toner Dust','none'),
(3604,'entry','1vGbKJK69xteA5dG8KMHDHFQMfej45x3zekkkbVWDuSB',1,2,2,0,0.034800,'Cubicle Slate','none'),
(3605,'entry','DcqMft98qf9p3bCGuDm59y5ZhZsmcYAYkTWJAsBZK9XC',0,5,6,0,0.030800,'Cubicle Slate','none'),
(3606,'entry','tP2YHZuLKEZaSy9ifYQbF7yNzVR66j8QWJKrjFtZhP5J',3,7,4,9,0.037120,'Manila','none'),
(3607,'entry','dCP8Sf3DLvQeMKnosD12j5skTGbSTLZeZM5FJAPMybUv',4,5,0,6,0.054280,'Ledger Green','none'),
(3608,'entry','6NjZG8udoC1XKuQpMVUW8JQq88tnZTYUdY5LnoQdB3y5',7,7,7,9,0.034400,'Manila','none'),
(3609,'entry','ZbcqEmPWWtydc89PcMLiQmra43pqaAdWXAmJyYRFSuVo',6,7,0,7,0.043680,'Drywall','none'),
(3610,'entry','96PjoAZWFLXyRQHdCdgC4TGa5Zk91kySdjwQZjgwfM9t',2,9,4,2,0.051800,'Breakroom Sage','none'),
(3611,'entry','VAKFnJFfgUfGk6FimbNJbQoQBQm3sqvEF7qy8HpLBfiZ',4,4,2,0,0.059850,'Toner Dust','none'),
(3612,'entry','5bYfwYLvtBLq1kZCjtXZgXLf6VCDw8D8zjUvv2UWHhg3',6,1,4,7,0.027280,'Ledger Green','none'),
(3613,'entry','dMtxYG6aptyngmV5PyGNLeZPauvtR23CSCRcVGLZc9sY',5,9,5,0,0.024000,'Drywall','none'),
(3614,'entry','XP6LCvMZqFV96PH6386TbvDriGfAan2bkWuKxpcgcp8v',4,4,0,5,0.033000,'Cubicle Slate','none'),
(3615,'entry','TpWgWmDLqDScAZ7rgUTzoK4Wv6G3oFrAp5XjP5xbhy1v',5,6,4,0,0.055440,'Toner Dust','none'),
(3616,'entry','W8jXJ3dZHSfzU92h1vDqjAyYPuUP1fbvjnV1A2LPqxk6',1,4,2,0,0.052780,'Cubicle Slate','none'),
(3617,'entry','e4WLMh8axbYFQD75pj95DkuuExDnL3kgbDs4Jf9Yzx9M',3,0,6,9,0.133950,'Drywall','none'),
(3618,'entry','YqQxKDSsZRhSq9ndFd6CWobbviN438rNUe4GyzPhkFMe',3,2,5,4,0.028400,'Breakroom Sage','none'),
(3619,'entry','pmGkuek9WTzG2Vs8aTZuyMjqFUmDWvZhr3QQyb4LwsZn',6,2,2,0,0.035200,'Manila','none'),
(3620,'entry','cVdncXG7uBeg43Ea5ws8HBj69xZV6n6Rm5fbEMPZVdHR',4,2,2,2,0.073600,'Filing Grey','none'),
(3621,'entry','Em4QkNZDyUyLzDrEnW1Sb7Z5NDDoSqRyrhRh37oiadr8',0,6,4,7,0.045140,'Manila','none'),
(3622,'entry','daM9kPMWQS4iFuuoeQQLFnjkURaskWpZRFVnp2Wvkkia',1,4,1,5,0.061640,'Drywall','none'),
(3623,'entry','JbxKwRUVLL7e6Uhy7hX8PkPvhup8Qhm8U35XzQ5G66Mt',6,5,1,9,0.065660,'Filing Grey','none'),
(3624,'entry','F4KTmtYcFUwWGvTweHwEDmmMtEyppE9krkwT1ebkyKry',1,8,0,8,0.051330,'Breakroom Sage','none'),
(3625,'entry','LtqQtVyHiGdSi3eouU2fuDfQZxjGwTyLEQBuwNvzZrr3',7,7,1,0,0.063640,'Cubicle Slate','none'),
(3626,'entry','y3XEzmFmZGmhMpcBZo5zWmenhBQKAcQUoxy5WBCLXtGx',6,1,4,7,0.037120,'Toner Dust','none'),
(3627,'entry','MugqjGp9VvvqE49cubPY58SpVbSUdQQjwXfpXGLn7uX7',7,2,6,0,0.046860,'Cubicle Slate','none'),
(3628,'entry','6kAs4mVV2crYAhJiejUgzx3yMx1GRjj4uES9xQ6KLLWT',2,0,6,2,0.042640,'Ledger Green','none'),
(3629,'entry','cS2uyqgVPCHt9zErX2rTzCDGYtXdeHDrgfhQ4UPookLk',5,4,1,5,0.028800,'Drywall','none'),
(3630,'entry','bf7o9yKpxqUXVC5CW62A6kh6x3EV3EwRLnZSxwgMX29C',6,5,1,4,0.049410,'Ledger Green','none'),
(3631,'entry','fmZJCQkxcFAqWd884RsL1ddLohmJnrCeKfnX2vc8ifop',6,1,5,8,0.037720,'Ledger Green','none'),
(3632,'entry','cpiynazjdjRrsHwS2UQ589X14wmisT6JXZreTUKD2Km4',0,2,3,3,0.037960,'Breakroom Sage','none'),
(3633,'entry','1ppUVgYKL5nwTqoSUKFXH5LKVGDPsxmmEQLqWxyTQzC8',6,7,3,4,0.042340,'Cubicle Slate','none'),
(3634,'entry','SHoisAvunM1ecmWPDmdusj4Zf92tmLKAfhmH2cZhL3vD',5,3,3,5,0.055100,'Filing Grey','none'),
(3635,'entry','crm9QV37gafFA3WzZo86DM6uCdvBkDgM8oAkgt4D1vxY',1,0,0,2,0.047790,'Ledger Green','none'),
(3636,'entry','rjCbkcUZCaa8ujDYAwd8UJKqKh2kjTYxjQAj6XxsRcpn',6,9,1,3,0.091080,'Ledger Green','none'),
(3637,'entry','Ff52TfC9hStP4nDxJ7qKS9zQuHAASijvCMaJeGGHydjf',7,9,3,3,0.071040,'Cubicle Slate','none'),
(3638,'entry','zzcpLaNN9mnbdoAgynSKnff6T5cTKd69rTsDvnVYKbh5',4,8,5,4,0.057230,'Filing Grey','none'),
(3639,'entry','GnRWmjtdC55HWNmHjWPB1fsHWcSpLJo7T4sftQ1dsUCM',0,0,6,2,0.037760,'Manila','none'),
(3640,'entry','DV21Ypm4snPUeL6xY78WdRfz2qNgM1BVr4KRBg4nz4S8',6,7,1,3,0.038000,'Toner Dust','none'),
(3641,'entry','spUu5AA6RJmngYfSPARCtd1Ewhv7FuACvjUYwBiqTLjC',0,4,1,6,0.036800,'Filing Grey','none'),
(3642,'entry','qWZhcTss5QX6Q4nawB56JEnu98APT4ELPvHvQfx54ZPN',5,4,7,6,0.078570,'Ledger Green','none'),
(3643,'entry','y4dzM9BRNgLeNb7NSvHj3JQuW3uxxbDCHX7MegvPWWpR',3,7,3,8,0.040120,'Breakroom Sage','none'),
(3644,'entry','xsbAEvdmYVAmHsANYb4BJGaaLCuCw2cRQ885wzUCE4dF',2,1,5,9,0.091080,'Manila','none'),
(3645,'entry','KC6exTwDZPUp9NmXS9rctpf7rFgmzr1xoUp7ZSBvQDxM',1,3,7,6,0.041540,'Toner Dust','none'),
(3646,'entry','KH9EAxRrvrF3AmGiKybi7cSfpruENuZJYVk1viuceyg9',5,6,0,3,0.040600,'Filing Grey','none'),
(3647,'entry','8Hg61jcTXnz88xZaU8QinJx2sNZgdHVrkaB3cK7x64x1',2,0,7,5,0.037760,'Breakroom Sage','none'),
(3648,'entry','BLqvo2ZzAss5oRUpqYPA5uEYZ9XU4tmJ4D4xgJenytoT',0,6,4,0,0.039200,'Ledger Green','none'),
(3649,'entry','Yn88sXPKk13bdHcDAQvZzUj5nd1qzs4zYvxqzDiHfPLg',2,5,0,7,0.074520,'Breakroom Sage','none'),
(3650,'entry','VG3PySFri87wsoXQ98VfqmzC8N6X7fUMxMJPJsgdauNj',4,2,6,2,0.027200,'Ledger Green','none'),
(3651,'entry','4wWQyNTUtoXhGsayoobrL1ymqYxq62ndHavG9QGUwDZn',2,6,5,8,0.037760,'Cubicle Slate','none'),
(3652,'entry','may5EZTMrf7MWMJKEmeuv9Z1eXyAHZ5Qq12zWDfLvC7V',0,9,4,7,0.036080,'Ledger Green','none'),
(3653,'entry','iUiALwDYLCgfztRJnMVRgv3S8LrwmrutHdnXDyFeDJQJ',5,5,3,3,0.060680,'Manila','none'),
(3654,'entry','w5MfHs4jjYLRqn1sCJHtAE6ooVmskic6PLX7BVjFw1tW',5,4,6,7,0.078200,'Manila','none'),
(3655,'entry','U5VtjqrfRojY9z2JTjbVrwAyGPtp2yM3gF4t1To643qg',4,7,3,3,0.030080,'Toner Dust','none'),
(3656,'entry','pAWTbVUVaS5otG9h6Z9SEujx3nspMDxyuzDpc1uihw1Y',0,0,4,0,0.039520,'Breakroom Sage','none'),
(3657,'entry','98iaCVmj9FbqNPxi3ZJLdF5DCDhYR8TJ9QLPeqJH98jn',0,3,0,8,0.068160,'Cubicle Slate','none'),
(3658,'entry','oDoZyYh3s9A9apgosAfA6uQmVQWjzr2h53Mmrz8Azx1V',7,8,2,7,0.023040,'Filing Grey','none'),
(3659,'entry','WqDvtrEM5pXwELc2C8Vg3zHg4D6a3JNngHZEirKcQCU5',7,4,5,0,0.038000,'Drywall','none'),
(3660,'entry','MsYN1sEQgu7BxJW1hU9b4e4ArvkoXDj48jVfA1PqndVh',4,8,6,0,0.059630,'Cubicle Slate','none'),
(3661,'entry','6qTzSorNwgDCnhKVbdVRL4fK4sj4K1yggE7nWoJ6uu2v',6,3,6,3,0.035380,'Cubicle Slate','none'),
(3662,'entry','fZB3BXFGig8eUTnoDYugLbj4W8SkxUCqcsDeCs759oQf',0,1,7,2,0.045560,'Ledger Green','none'),
(3663,'entry','YyrPFJEaz6hFV2RKsmVQzBL3Uu4W7PpxnpUNddzc1tRf',4,1,0,0,0.112140,'Breakroom Sage','none'),
(3664,'entry','tx57jq656Wzj57VapKRdrfGwYMhHpVai49uJ2dpnJEFL',2,0,0,0,0.063650,'Ledger Green','none'),
(3665,'entry','Yi3KzMvwNVBReyzL937kZYTSFYXMoRoxwNknPXuUe5f7',5,8,7,3,0.027200,'Drywall','none'),
(3666,'entry','ECKyaABmDfquQAkPDF9mYGecSw9ANRnqY5ZsyzcCjmVF',1,5,6,3,0.049140,'Toner Dust','none'),
(3667,'entry','Tu8m8pkwpV4UAXJUhAZMpHyxL9z91KM8s5qjZseSmETd',1,0,4,4,0.036800,'Ledger Green','none'),
(3668,'entry','T3TvNnFZ1si9udbEvwATyKTPqnfPJMv5TAaFcAxUj2Wd',0,9,5,5,0.047790,'Toner Dust','none'),
(3669,'entry','RfukZLD4D9Wx7ai3g4rBJ8c9BxAigtALynjc3SSZpU5Y',1,9,1,0,0.055080,'Filing Grey','none'),
(3670,'entry','2woUTcj75nvgyAVrcVdDW4SPL5wWAbvejwSGpWNhJNNr',0,0,5,0,0.036800,'Ledger Green','none'),
(3671,'entry','HERDKsGeKBT5e584yx7hvnozerUEpiqGm1UBFG8fG43p',2,1,4,8,0.070290,'Cubicle Slate','none'),
(3672,'entry','w4Gchc1kL8adxR86vVbv62eADBXRhEWDSj186JRx19jX',2,8,2,2,0.048100,'Toner Dust','none'),
(3673,'entry','axm6TCNmDg92avzaLnDcqynGaVbJeYkCJMsWXkSJgPLu',3,8,2,7,0.033200,'Toner Dust','none'),
(3674,'entry','pm9wh1oHPR3eV4pHPJDcoRkURUnFvvEytAwXLWvNfe97',6,8,0,8,0.036800,'Toner Dust','none'),
(3675,'entry','jcyU59392kSAPRnUJFGy3ivfDDUMSXqGXbGmQGGCmFNL',6,8,0,0,0.030800,'Breakroom Sage','none'),
(3676,'entry','QdUoKup3scXqHrKeoFLy2ETJu5XVAAc2aQJWRTuHyP94',4,0,4,7,0.046280,'Cubicle Slate','none'),
(3677,'entry','DvUzh7KvuQvJatJkSzJGHgsT6U2s7N8dfiQs3gYrBXSZ',3,7,3,4,0.034080,'Cubicle Slate','none'),
(3678,'entry','eAC9EdwVmnGsBWSCb6UmnQCdFJNXVJuqLzver6EteXLc',6,8,2,8,0.024400,'Filing Grey','none'),
(3679,'entry','d8kKoDTbsXWkrXtAiC2g5wGAzbJuS1F1ohfcuYgjYYfq',1,7,4,2,0.040020,'Filing Grey','none'),
(3680,'entry','rzNHP5UPi8z97myFhvBP9zw2mWohJ3bwYVUkojY4VU61',5,6,3,0,0.036000,'Manila','none'),
(3681,'entry','v6oHUKM1JPbdAb5izMBrZLmVMSYCABpYMU2A2JCrnkER',1,7,3,6,0.050440,'Manila','none'),
(3682,'entry','jqHSLtGnS5dR3xqpQuoGWeS3ftUCGiCd6KXvboQH4ysC',5,9,5,5,0.051480,'Ledger Green','none'),
(3683,'entry','WDzVohrAyc1WiEGbF7Y7TNBopm4LQySHph3ZdsjrMEC4',2,0,6,3,0.027840,'Toner Dust','none'),
(3684,'entry','7zGqrxk2ttcaCe8cjeFbzmYBqgYUy9ojUaLKbfxGeEJj',5,6,6,2,0.048840,'Breakroom Sage','none'),
(3685,'entry','1msegVC8jMf8YPawGzeeqc2PpwnddBYsz4WUK3FNhRXz',1,4,2,5,0.043240,'Drywall','none'),
(3686,'entry','hhUVBEhxHCTF9vqfFmvdQvXoMvviezmSVkzoCtTfkGut',0,0,4,0,0.040020,'Cubicle Slate','none'),
(3687,'entry','RKgSwcmhb2dRm5UztkRUpaDSXgnGqz3icLgDqLc6wJ3d',1,1,0,9,0.035360,'Manila','none'),
(3688,'entry','3EWTfsj9D6DhmrMMeKwKGiWCVH6yBXVgnpfzYJTqV4yg',2,9,3,7,0.036340,'Cubicle Slate','none'),
(3689,'entry','kNR2Qm8GnHTYVv5KEy9EC5zaXoXEGLBzkVPxPD9Jby4w',6,9,0,5,0.036400,'Manila','none'),
(3690,'entry','hYCsWJujeZudJi2bMvxzp9SyLz7KEAbMpBGoHGSb7dLJ',4,3,2,6,0.049770,'Toner Dust','none'),
(3691,'entry','5Jjc6NeW9PAmafPktaNfaCeoiVwTHm2pftCThDS9Pe5d',0,7,7,9,0.042600,'Cubicle Slate','none'),
(3692,'entry','jbDiAar5pPamxiVQQCMVuM3jHLkuPwRG3Kiqb8LHFK9K',6,0,5,9,0.056050,'Filing Grey','none'),
(3693,'entry','FGCZfw4F2xDWZGfEhvsuA8SqkHLoHjjeQZJWAw28Rg6f',0,0,2,0,0.055200,'Drywall','none'),
(3694,'entry','Zkf6xVeNmTJmWgVL75iLfYkfYKqKgQrZq7Zhokwi6P3P',0,5,3,0,0.050400,'Ledger Green','none'),
(3695,'entry','P23v6AH3spTWVwJQEP4fmU9qirmiigZkehe6RGV6ZPNN',1,0,7,9,0.045120,'Ledger Green','none'),
(3696,'entry','2H76PNDMvp9rFR9Yy7hFsHiUhpK1fMhRHaEWw8adNBTY',1,7,2,2,0.053960,'Breakroom Sage','none'),
(3697,'entry','XzgkbKuhAj3rumzMsJQ3h4S7QE55d3qCiSnvtGHe6Vcv',3,4,0,5,0.029200,'Ledger Green','none'),
(3698,'entry','xQ2QMnE2FgfE54qJMN8M73xf32j8TLHbdMqsbAB3oN3U',2,9,3,8,0.044250,'Cubicle Slate','none'),
(3699,'entry','9JYWEk5KCw6zskp8szgp95w94NTmSdGr852RSSpnHuRb',6,6,1,2,0.084640,'Filing Grey','none'),
(3700,'entry','bWbEtRzgvMgUNB1sMJx4DjF5K7B1AzZCDxK8zExZSVq4',5,4,2,4,0.068870,'Manila','none'),
(3701,'entry','CqJBQXSV6U9m7ip63cJQeKHXsnF11TX2tJgxSgHmCkJh',4,1,3,3,0.048100,'Filing Grey','none'),
(3702,'entry','r5szvHHZfvQvCXutuJ3kxbatNuZg6HktzHmr8AGX1q3f',2,7,1,0,0.047320,'Breakroom Sage','none'),
(3703,'entry','nXVTjqzFM3PMXLxmLF7iXmUGBTcTi1BDLiPcwgAFLaad',2,3,5,3,0.053940,'Ledger Green','none'),
(3704,'entry','Mab5Ck8tmacyarRKoevbfM3bqTCBBpiTQVWtRYuaHnvW',3,5,4,0,0.054180,'Cubicle Slate','none'),
(3705,'entry','AMQAQkD1LoysdqU1WfupkaTmMcT3L7WXd21AktZgjJP4',5,1,0,3,0.055080,'Manila','none'),
(3706,'entry','v234BuGv1opGQseP5KrH92EM8JLePgDUpifCG91qDPpt',5,3,3,7,0.037260,'Breakroom Sage','none'),
(3707,'entry','j7ZvYuG17EHN8fa8CGK8on77zhDkDmwFmatt57AZXvtd',2,9,4,6,0.058960,'Cubicle Slate','none'),
(3708,'entry','1fgFhyngPh8HModiGsSoJr6ZKrxUJ19LAyHSTx1v7gRg',5,0,2,3,0.040200,'Drywall','none'),
(3709,'entry','iozdAHsEthMnYpZ6wcZubqbcCCvAxuabHV14XYV5wWtt',6,6,2,3,0.067340,'Breakroom Sage','none'),
(3710,'entry','urgDBm1YuHWkwv9whyWxfB6ZWo8h1GG6VPTUhHT4kbzw',6,7,4,7,0.043120,'Manila','none'),
(3711,'entry','GTEoNmFJDsRzNAih9oa3RXspUVvM9Ee3MSyPBWF1cvzc',4,7,7,9,0.032800,'Ledger Green','none'),
(3712,'entry','Y6nT2rN2ExPrEtW36d2EsqZ6kcqEyoEsgpftMgsnWPd1',6,9,4,3,0.053280,'Manila','none'),
(3713,'entry','NbzvbNgFo1CiaVqGitB9tpHwBSGxXrEFzwX6tktmnw6B',6,9,7,0,0.060750,'Cubicle Slate','none'),
(3714,'entry','yx86pwvDKpzCBNgPt3ddEYtwyKofJps7RGMf1FYnYT7o',7,4,1,4,0.061640,'Filing Grey','none'),
(3715,'entry','j6FRbxNJQMa9Wcgt4ropwV6JyvwsACuBZ9ea4Nvdgj9U',7,9,0,3,0.048880,'Manila','none'),
(3716,'entry','Ng553cmjTxHf7Vsn8qdsTJTgHYFZ82Grj2FXjhcr4Qdm',6,9,6,3,0.026400,'Breakroom Sage','none'),
(3717,'entry','Ep787tiRRdoiQAEULE8GzXAB76mjBzdB29qBfuH4AX8o',5,7,3,0,0.073600,'Breakroom Sage','none'),
(3718,'entry','ftAaTZfqde7pUaVLth9exDuUidnDNGDUUPmTBtwDpxfg',7,1,0,4,0.042680,'Filing Grey','none'),
(3719,'entry','idnkivr1AxTwqibmKxww9i19EWzY8VgdMZ6sJEGaGMZS',0,5,2,9,0.027280,'Ledger Green','none'),
(3720,'entry','13nxUmCz6ivkML55rrTsEy3oW5C6o4wQsCV33ywzbvpj',2,2,7,4,0.027600,'Toner Dust','none'),
(3721,'entry','TRnLsLVvBJewmWpYtMYfcSB5mDNqPimrgQvKWbCaNERM',7,3,4,7,0.043470,'Cubicle Slate','none'),
(3722,'entry','4vQob85zk2aASzoVkRomQqUWGGTD8vj1TCx6q6gpmf4T',0,1,6,9,0.044660,'Toner Dust','none'),
(3723,'entry','oY27hN9mSBFRwEYDbeHHrDGjcQQnyaR1fuGUmukB9QHo',0,8,1,0,0.027280,'Toner Dust','none'),
(3724,'entry','hobxbmskEsSm31xHEQESv4AaKL9pbdF8x72mBVFj73uR',3,4,2,8,0.033120,'Manila','none'),
(3725,'entry','dJnY6uCaDoS2GskkobadmNSDJy9W9StUvFbkgSCxMUUy',2,4,2,6,0.042480,'Manila','none'),
(3726,'entry','FR8QkZfPduoKh5WvSh544Suh2ivvkWZrur8YahhDTKMa',3,6,3,0,0.042780,'Ledger Green','none'),
(3727,'entry','jpbj2jSQXsPop3BVTffQ9BUVZQvg3zFCeKnkUheXiGs4',7,2,7,0,0.061420,'Ledger Green','none'),
(3728,'entry','beSzKm8ZzrSBVfD4jsn4mDVUuEmLa9CYJcBnPG5HRqvC',4,0,3,7,0.051030,'Breakroom Sage','none'),
(3729,'entry','ze7CqazWBAw9gTZCSTpVaANhzZYrtDZfkpt2BYb4Zatm',6,5,5,3,0.047320,'Manila','none'),
(3730,'entry','EQhsF6fyYPVRZJjLtNCnrbqYScCKtGEykXEptsv9PXSv',3,2,0,0,0.050250,'Manila','none'),
(3731,'entry','BDSpPfva6g2YKXo2fZJ4enFsantzxyu2nqhdJJujHoDV',1,4,6,6,0.084420,'Ledger Green','none'),
(3732,'entry','oFdPzr4Rb1HowbjyFodgRiwMq9ZsJiW5zwEV84tQzLj9',4,0,3,4,0.028520,'Toner Dust','none'),
(3733,'entry','5q8WPMtnTd8fj2exu9yEywqi1SBoVUgyGJUfShD1m1W1',5,6,7,0,0.035420,'Toner Dust','none'),
(3734,'entry','yEGwYEVG8iR3xaPXSHWwjG9taWDJcZCTyUZvMiHTmBEp',0,5,4,4,0.032760,'Manila','none'),
(3735,'entry','yA75WfSGZpg3Z3FujVCVVqZV4mVkf6XvNMmvLtcxMuV4',7,9,5,8,0.034080,'Drywall','none'),
(3736,'entry','mzD4nuLowaj3aPA4SFXz1Qhvc63FJ2oKGzRup1fKfeoJ',0,7,1,5,0.027600,'Cubicle Slate','none'),
(3737,'entry','mcHfwsBeiwCMySVuvJcad2YcdAzKG4JXq9c6NXXk2qJv',0,2,3,5,0.059850,'Drywall','none'),
(3738,'entry','CQJ3ooNkPToZRHgjmd99CM2RUqbdAkc1eMuDJNCZLcyM',6,3,0,8,0.030080,'Breakroom Sage','none'),
(3739,'entry','tNT7yfxJ45huGQniGsUwGfVj3y7UrvpriDiFC3aQodaW',7,2,5,8,0.043560,'Breakroom Sage','none'),
(3740,'entry','XWNPbwdbSMYcQ5Kssyp1iD8KaPTWT1AjYtA6Q6CPPGaS',0,4,4,5,0.047320,'Cubicle Slate','none'),
(3741,'entry','X8EgHSDoSLSc3pgLDbN8dgKSAjssopwqvnniNnCJj5cw',4,4,6,8,0.053600,'Manila','none'),
(3742,'entry','sjkaRN7a8K8KZPKJMtENiYqLqYB1SH2Ao48HJgPqTLLW',7,8,0,7,0.059220,'Manila','none'),
(3743,'entry','BCiN5Joa5qQL4oSiUyUJPArKQKvSjYABwYpVdRETbPuz',5,5,3,0,0.038940,'Ledger Green','none'),
(3744,'entry','TQS66cvaCr6CKGKLhzjpbqSSEJLxJhjBvGsGpc3jGXoZ',6,5,0,7,0.030400,'Drywall','none'),
(3745,'entry','XCDgG4nreb2X4eJoXP8iG4omWFY8TyUBRs5aVvKXkW7M',4,6,1,0,0.025600,'Cubicle Slate','none'),
(3746,'entry','hzYGDdaB2C8fmpuyYjvTJJndenMxyGTDTKFqmejZXw7X',1,5,2,7,0.052510,'Ledger Green','none'),
(3747,'entry','viN1b5xJUGoCiy3NR4inQoE4egYRmWTwFcBomnau7WRr',3,3,6,5,0.041180,'Ledger Green','none'),
(3748,'entry','KwMJG7aQ1CFjLTriK1hYnqsiXDYL5NYrxCvLtQm2cU52',7,8,3,6,0.037440,'Toner Dust','none'),
(3749,'entry','PrBdJWvA3dQjxZbJxyuDeLdMScGs2BnDaVz4JeoyeWvC',4,1,0,7,0.036000,'Drywall','none'),
(3750,'entry','GaWUfCQc9NiCzdzm9ZX4HabdAghjXVDSibG1pzJ5Gi23',3,1,1,0,0.037120,'Filing Grey','none'),
(3751,'entry','79Sk8V6JQzVVeyTPYTo2w1VQ7Ktdixu6P8WoGs1jRZMg',4,9,3,6,0.068820,'Filing Grey','none'),
(3752,'entry','72umie6jxHft3RwfRZFHyaVfmto47oHPQdabdUSbe9pC',1,6,5,0,0.035360,'Breakroom Sage','none'),
(3753,'entry','sH7Rc9XrvGsQaXyRrqnERdLSjgt1YABjusmZ3TkQJ8Ac',0,3,2,2,0.053360,'Cubicle Slate','none'),
(3754,'entry','4gyn8D9zdYThM4mjRtxPHtXXJD6kc5sfQDWQCqQtGRBS',4,8,0,7,0.047840,'Drywall','none'),
(3755,'entry','WcJQRdFo4xjzoh5LKFYwB4zgfmQfd7ESToZortWMhwmP',4,6,4,2,0.084640,'Filing Grey','none'),
(3756,'entry','eSiVCug5qHSkDdr5oENa56dXuDgvjuLaquBSjp6YzPyv',6,3,4,0,0.052540,'Filing Grey','none'),
(3757,'entry','f8kCZwjv1RciQhuK5kFWgwuo5kov1XvHT32qXLhfCMEA',2,7,4,7,0.037260,'Ledger Green','none'),
(3758,'entry','fErbgnKj4bH5ShChkezZdamFsCwj1QPHe8pxN2wUdNRe',2,6,3,9,0.036400,'Filing Grey','none'),
(3759,'entry','neijzGKF39at9m4cRGX6qqVVe7wz1LBrrwpvpcGDLgHS',0,6,5,3,0.060720,'Cubicle Slate','none'),
(3760,'entry','gFHQmrxEur2kycAUZssjBYVk1dDQkUEj9SJb1cCcyLNF',1,0,3,6,0.026240,'Manila','none'),
(3761,'entry','7aHHp65Be9mSY7TjHnZVc9uHgZM3HANBPtjn1WvDtyzz',3,1,0,9,0.053690,'Manila','none'),
(3762,'entry','AzmAnNeZF2RJJsKQd2k5BBWdfCJSHLUh9eLguDQ2WzHV',1,6,3,8,0.057510,'Filing Grey','none'),
(3763,'entry','2Q6C6Xkp2UFpnA2g1qsTNRvjR8FVU8ccYLaa6yZZuv5R',4,5,4,7,0.033600,'Cubicle Slate','none'),
(3764,'entry','2kWdHuDkcLYswmRNuqtqw7Hbgn8EKWVrwNjPje8NML6K',1,3,3,2,0.049580,'Cubicle Slate','none'),
(3765,'entry','BhTRLEkukYsPxeZ4gv9uL1hwbgkQe2yuHaeGbvWCWSyg',5,9,6,0,0.053100,'Cubicle Slate','none'),
(3766,'entry','gf2Mxmy7Nkb8SkQP8ZPrWwgdw7NyEKfYwrttCnTL6HSX',2,6,4,3,0.048510,'Drywall','none'),
(3767,'entry','KVSwExLitPs4VyYgNsRREtQFLjeTXcQuLSn5uY9EmR98',0,4,0,2,0.036580,'Filing Grey','none'),
(3768,'entry','qoKD4Hih1Sdy5Q11vokGxPvLe4x1YSfZyWPSD4BXDYXA',2,8,0,6,0.044250,'Manila','none'),
(3769,'entry','BdBee189pSyJdE39183F2SxQSEfaiRxBsJB6gs59MGLp',6,8,4,5,0.050440,'Ledger Green','none'),
(3770,'entry','Huo44PXgUkRUB3xR5ZcTBXHP1Nh5VP3uF6BhsocDdWD2',4,8,6,5,0.056120,'Ledger Green','none'),
(3771,'entry','SVkNxfP69NDG5ejJMdF5RMfDvRUWUs168Yz1aqSuHMDV',1,4,1,8,0.025920,'Drywall','none'),
(3772,'entry','o2m5ikQrixYy51e35fEiz2gLade7KQuh7efW8yNmMQuj',0,6,7,6,0.028480,'Toner Dust','none'),
(3773,'entry','bAwUJTLWgefTkmf9hbhEu5hCqH6JUauqT8e9D3eFdBhu',2,5,7,8,0.053940,'Drywall','none'),
(3774,'entry','e4JkvrakmwpSJtjqKZiB48Ry5BXsPw7QDxSc3pQEAQz1',4,9,6,3,0.037260,'Ledger Green','none'),
(3775,'entry','WnN1gMwyfBiqWTUVCWWmu4LhzRs8B4XB4Vg4TwADDArk',3,0,0,0,0.047880,'Cubicle Slate','none'),
(3776,'entry','amRe99XvzaNYYDD6SGeyjQZHjh1KayhUChc65Ri96Thb',1,8,3,8,0.038940,'Ledger Green','none'),
(3777,'entry','iko997e2xka8wTAb6q2b37fHnkkdQkhGs7oMWa9g63E9',2,8,5,2,0.057230,'Toner Dust','none'),
(3778,'entry','gPT76wsaKmNvaGpSqGzEM8Zy7TLZMog7DquzB8QeHv8E',5,1,6,6,0.066330,'Toner Dust','none'),
(3779,'entry','L3ZWDnnB7NM6gm5gujbHcXgg7CjG2657yEG1z4RDrJAB',4,8,2,7,0.053100,'Drywall','none'),
(3780,'entry','orZbB6cECtDwP51VR7MmLNv5539npDE4EhFWcDTRyLRc',6,4,7,9,0.054180,'Manila','none'),
(3781,'entry','MRCxYxN5DG9dhBbaaGZrVcPaAcWhmjJv2mBGvQtnc6LJ',7,1,4,5,0.058960,'Manila','none'),
(3782,'entry','ahS5aaYYaF1pubBxaqxnvHHAJepLdXeZkunRNkvD6ZPB',7,6,3,7,0.032660,'Cubicle Slate','none'),
(3783,'entry','QV5w8n6fQh13h9zwPT6Bs2XHyzYq7uyAfHt4W9uxWYMA',2,8,6,6,0.041760,'Ledger Green','none'),
(3784,'entry','zP4PztXnozYw5uNCXtSPuYQNLbtAzF3sgZ1LwQQsjVdc',6,4,4,9,0.032240,'Breakroom Sage','none'),
(3785,'entry','oxRRrytK9GrzJUuPwy3drBCz6m454jMoKKdFcE32v1ZL',1,0,3,6,0.030720,'Cubicle Slate','none'),
(3786,'entry','2ZnDvKwpaNJxtyUAnwHcerYsEj3yq6X1JypqTZS14hJx',3,2,2,5,0.038940,'Filing Grey','none'),
(3787,'entry','p6jr7tPsGQXFdjQnnX3bjjR1A8QhxHeFhB53qHgNY4Ar',5,5,4,7,0.058290,'Breakroom Sage','none'),
(3788,'entry','NMhLZBa1DNqMwYYropAot3qXfAoyyDrpZ7iSofj8DBJA',5,7,5,9,0.037400,'Breakroom Sage','none'),
(3789,'entry','jwiKXbdX2jQdNpud4jU9CBXd2154efCfKF1jdB24HPWm',7,7,4,0,0.028000,'Toner Dust','none'),
(3790,'entry','nm2zZa3tjkECeNiMUF2PKjAtScToHXJrUgu5KMmJFpGR',3,2,1,2,0.035990,'Ledger Green','none'),
(3791,'entry','Xq3rUWKeNeT86Xzz98Xk1kWfG8iYkkb7Di9WmRuawVSm',4,2,0,8,0.024640,'Manila','none'),
(3792,'entry','Zhktb4sAbMoK3EMzTL8ocwDSxNvwEjMchpp3Q6r1T48R',5,0,1,2,0.042920,'Cubicle Slate','none'),
(3793,'entry','9R7pmKXQEck2gZ3wfCcyajkL7VSFXgHEMvCx9GugBE9d',1,9,2,8,0.033600,'Cubicle Slate','none'),
(3794,'entry','zCw2pZoK82M7hSBC28Uh6rq9NyxXNLGwFqnx7jsLrHjw',3,2,3,8,0.048970,'Breakroom Sage','none'),
(3795,'entry','1QNMCfGzGFKCJXmuSsSaopQ5NnAfALr1NHFVupQbEZHG',3,2,3,6,0.064400,'Filing Grey','none'),
(3796,'entry','3cZLSP8M13YAdehrShtoukSFwwbjxU3ZrSvvyS26i2nR',1,4,4,2,0.095760,'Breakroom Sage','none'),
(3797,'entry','aUVUeiQNuSwu5kdcHJkB5r2kmiaw7BQDrqE3t3wfZygy',5,8,6,8,0.048840,'Ledger Green','none'),
(3798,'entry','GHDgYsWjX8acW9yLmBHXWvDMqASfZz2xiiAfVtgxadoi',1,5,1,0,0.079380,'Drywall','none'),
(3799,'entry','wvX94RDu7mTLLtb7dTn16FerhN6LiD6TD495Kz2JXfR6',5,2,4,2,0.046620,'Manila','none'),
(3800,'entry','VncCuUZ9rzc6Hm8DrMFhC6YNnp8aDx1Fee6mhAJMZi3k',5,3,6,7,0.043200,'Ledger Green','none'),
(3801,'entry','zFM6VyUX7CMKUPa6dUrHtpLZumqLSyy1aXBqLCwuEnva',2,4,0,0,0.071780,'Breakroom Sage','none'),
(3802,'entry','Y8oqyGqfQRWeGe45PYrQtiWxZi7Qv4hGGZvwbTw8Liop',6,6,6,8,0.051040,'Breakroom Sage','none'),
(3803,'entry','BmotozF9ViVS2gLm2ivZqPK2SEFaf3QBfac2FTAMUrUC',1,4,0,0,0.126900,'Toner Dust','none'),
(3804,'entry','HRAkHy2xQDWNC8fz7PbMgEFbPDpMrMSembdGQA8RHe7Q',2,6,4,9,0.097020,'Drywall','none'),
(3805,'entry','Ub6xM7fFg9u9mWEVHR9mgLZz6HocyVf5BgQLPsiYqLek',6,8,1,2,0.062370,'Drywall','none'),
(3806,'entry','9TGuTGJa13ypCK4NihScahAPG5E4RiBo24Pc36NTUbiT',6,4,1,0,0.026400,'Toner Dust','none'),
(3807,'entry','tKdd1py37GkNWkYbGHXa9RUp1DvJmvyziZXcfz81MfCP',0,7,2,0,0.039530,'Breakroom Sage','none'),
(3808,'entry','3xEZzjEryxUir7cPrBBLkyaAyYXo6coXw9rgXxbMozop',7,6,5,2,0.048380,'Drywall','none'),
(3809,'entry','PcgxfzHBJutm3csXoo6dCrZbzJxixJEqYdR2QXaW4V8r',5,2,3,5,0.034080,'Ledger Green','none'),
(3810,'entry','vhHgWRe4hbqJX3tXizD3WwFWAW3dGwU48KoGECEPNWp8',0,2,3,8,0.057620,'Drywall','none'),
(3811,'entry','a7Eddw838aSRNfiZKE2grBqpxKNFC4h4Ah2eUTB9dyzL',1,4,5,9,0.042680,'Filing Grey','none'),
(3812,'entry','F59zYPe9bA1rCjGJiyYh3sNdFusLWBrBRG3pEGVnZ4iX',0,9,2,2,0.041080,'Drywall','none'),
(3813,'entry','YoAXMdhnYCbLJgDmoPXBeEc5zpbBP7BtkcKCmxNRZryb',7,1,7,7,0.038880,'Manila','none'),
(3814,'entry','35NDs7ZcSex4sZij2jPXpnWpqqBeNnAdfy12p35UYrY4',0,6,7,0,0.063650,'Cubicle Slate','none'),
(3815,'entry','ZeEncGQK68SnHf7wtXBcsj5EmdRm3ZZW1Ph4WAg2vzYm',0,9,0,0,0.034560,'Drywall','none'),
(3816,'entry','dnLZFXGfGDR52nkDbFjzcwubnzvd8avJ7JbmsE44LRJg',4,1,3,2,0.031200,'Breakroom Sage','none'),
(3817,'entry','WBPYcTMUx2gfJ3W7jeQuZTvmMNiCRj2ZNhnoALBSFMpm',0,7,0,5,0.036520,'Cubicle Slate','none'),
(3818,'entry','k84pUyJSdvgiL7F3xeGwfrxhR5bWc22Nye86pmhjDMwA',4,6,3,7,0.029200,'Filing Grey','none'),
(3819,'entry','vG7ZK53aM6TNgajKZzCbPmy8hgYxUvKTaGhPxE7UmRHK',1,0,2,5,0.026000,'Ledger Green','none'),
(3820,'entry','uAD34sr1Ewfg8LQsuPCx5zaTckpCpiqixFrfoo76v6aK',4,3,3,6,0.043240,'Drywall','none'),
(3821,'entry','6kUHeRYrooD62z85BWjDv7vnB3YazdZ25PHczQWEdARq',0,0,2,8,0.034760,'Drywall','none'),
(3822,'entry','oDAU7VCuDrWWRPovuLUQLGV1tHpY62JNQ8rYZRQSWd6i',1,7,6,0,0.026400,'Filing Grey','none'),
(3823,'entry','4pTrjBMj5Da6ziJSctFjfFXrcnJNKD5nHvJ7MUPwKWZS',7,5,2,5,0.026880,'Toner Dust','none'),
(3824,'entry','K4oS4J37Ncf2STad2Vn9dnB5TtoZZExNPqA2fDFcLTeZ',5,0,5,6,0.025200,'Manila','none'),
(3825,'entry','hwtYP3QMFSUAjHncA3wLULKJz9W7HPaee7rMKthDsUFF',5,0,6,4,0.040600,'Drywall','none'),
(3826,'entry','ktm9Gtrp2Qy7XoAAkNcNDTN17oMqTV6zZgVLJD1spVfN',3,4,2,3,0.045560,'Filing Grey','none'),
(3827,'entry','TokqwmR9mvVjzsJxdwTwU4dkDm1TKbJBSRJ8PFJjUX7Q',3,4,7,0,0.069560,'Manila','none'),
(3828,'entry','BwbMFXER8ZU2xwLTvKJiGaRZyCx2WCLhg5wZJgaBjo1K',3,2,7,0,0.072900,'Filing Grey','none'),
(3829,'entry','aJ7qU4rvM7UTCvMSa5kqjHHubAgsK9JpbjyUBvCPVvux',0,7,5,7,0.034840,'Filing Grey','none'),
(3830,'entry','eeH59LJcwYieKYvivn5pw5ksmjUfRdMNS2vwFsMjehEr',3,7,3,3,0.035990,'Ledger Green','none'),
(3831,'entry','fMQpsABzjrEzPQqMcgGjnHchmyoeXtpwY6Ti3n2oMexB',2,1,7,3,0.034000,'Manila','none'),
(3832,'entry','Qs9aXH9p9stg9T7W7GsXTRjYtTBGxXEzFTyD5pKriGqM',7,8,6,5,0.041800,'Ledger Green','none'),
(3833,'entry','fbwe3h4xkQNCshDR7aoRBgc3crVmNQE8JBZ9LfPk4cSK',7,6,6,0,0.027200,'Breakroom Sage','none'),
(3834,'entry','dGsJh8X1wbvHcWAYHT8xQjAd397aZnP9ncucKKb2rVqh',1,4,7,3,0.056840,'Ledger Green','none'),
(3835,'entry','Umyu1GHBZzmKso4AEf6PX7sSn46x6JptE31ttCogmuuM',0,6,3,7,0.105750,'Drywall','none'),
(3836,'entry','vmTN3UKPToe555L2YFJPkSSHmRS55kQt5f1gLCUrScF3',0,6,4,4,0.042880,'Manila','none'),
(3837,'entry','qvudZpSKQEPDZ5AngAsgMEUaBejWwNd9w1oRY3fa6mRa',0,1,7,0,0.053360,'Toner Dust','none'),
(3838,'entry','KyTBbnbyjUN1hjWU6JCL6i8XW71hhxbUGCdaabUWej2h',6,5,2,0,0.042600,'Cubicle Slate','none'),
(3839,'entry','9QRigoUre5k6myL6KpDQ1wVUR9rJeC5KQYyFb42x7EdQ',5,8,3,8,0.040940,'Ledger Green','none'),
(3840,'entry','4cHpK6oU6xfPuNbgaac71NLd1QKvUrjaQr11MiFBUNMk',3,2,5,6,0.055440,'Breakroom Sage','none'),
(3841,'entry','W8qKxwxcWMY6LBRzXF3tSL4qvuJAMn4BDFEPZUAuxQwg',1,7,5,3,0.040480,'Breakroom Sage','none'),
(3842,'entry','eyfo1JzRNtixx8nXMrwMLvtS9cSvjtDrouge5ySa6JXF',7,9,5,0,0.029760,'Manila','none'),
(3843,'entry','bVxr4TgzaM5vanjoBxM3m57JHU6sCGePpx2NoVB5x2hQ',1,4,2,5,0.047360,'Cubicle Slate','none'),
(3844,'entry','y9WkguavUrdm2A7etS7CbNSyVkm7hisCFWuwfFZrniQ1',5,0,7,5,0.033120,'Filing Grey','none'),
(3845,'entry','S1yAtZQgZRLsqRKMNNjY35i7ewUo43aDYyRVf5D79LWm',3,0,2,4,0.057420,'Ledger Green','none'),
(3846,'entry','bVDgCkPKd8Jp9xY6dJC49eWaxqw4YMT2Wort9mm8TP5U',5,2,4,0,0.039840,'Cubicle Slate','none'),
(3847,'entry','zgLBeoCQX6U43VoGsYvtfSw9pgiyoy6u1tzcQYf5sTQG',0,8,1,2,0.047570,'Ledger Green','none'),
(3848,'entry','T7v9Rchaiiiqcchq7Egunopp1NZEermkSspvHu7xP3AQ',0,3,4,0,0.051030,'Filing Grey','none'),
(3849,'entry','LF2HwubWHwzytyqEqHxoTM1LQMd5Nr4JQBtPV1Hz7whi',0,2,0,5,0.043200,'Filing Grey','none'),
(3850,'entry','rN8HTjC6BGsgg371huv2rmy2ujPZXEhpYRaiBDarKEDq',6,5,2,5,0.025200,'Cubicle Slate','none'),
(3851,'entry','qaE3C84qD6Nv1ZCJdpMrwTb42J1Ew8QNr2u4GfikRr1r',5,9,7,6,0.054520,'Manila','none'),
(3852,'entry','wsXfyCcD8vmq4zWFBtHWiUSUcDaFMYrZKz94Mim3x9pa',0,2,3,0,0.036580,'Drywall','none'),
(3853,'entry','L2sfr5iei79TaDAnRnjZ1E2tHxYVrmg9WjFCs6jLyDxj',3,8,6,8,0.048000,'Ledger Green','none'),
(3854,'entry','6EHg4NToie5QsnEfdgkmUN11vkDTCoCoyC4f2uKfzuid',3,5,0,6,0.045820,'Toner Dust','none'),
(3855,'entry','u2AgZsQa3LoEzdbXJgWHs6uQtt7ugQT2nkGVR1CiLTHx',2,2,3,4,0.072680,'Ledger Green','none'),
(3856,'entry','JjiJ65rXcLaq9BMmAVxRTmS663LLnKSbeBKD3dz64eZG',5,1,3,7,0.021760,'Filing Grey','none'),
(3857,'entry','xBw7w3befUMft5wUpBUCmfvHgw1bh4bfX24hoJWL4pBR',7,2,2,5,0.037600,'Toner Dust','none'),
(3858,'entry','PkTzMZepigFitoXJSwtPpQpWkAqJthkgRBtnAxvLLzuG',7,5,7,2,0.042640,'Manila','none'),
(3859,'entry','eBrrknxDnPvCLYhgRzjfaENJpvihE57AUT9BTQ6S4kK9',2,2,2,2,0.022400,'Drywall','none'),
(3860,'entry','Rx6DkiM4vQobPjvgL1mkf6ddGudVYM7w6KXwWR7e66jL',3,1,2,5,0.036000,'Drywall','none'),
(3861,'entry','ZYbHmwcsvhNSRWijLo1wE3Rk41HFGCTx942kKtdGrNTM',3,4,1,7,0.042640,'Ledger Green','none'),
(3862,'entry','p1d3k64uMnAmsMx2NuRp3uL9D9i5jkRjZVie6rjJJ6nf',5,0,0,3,0.062310,'Manila','none'),
(3863,'entry','wYjDGZQBm2YP1jCcqokhenXTcW2CAg8fQotokfsbKCVQ',3,7,4,0,0.056070,'Manila','none'),
(3864,'entry','VSwL3v5oEa3FhvfS3wgZCeifvjovwHQAGf6YZkEKEShP',3,1,0,7,0.045120,'Manila','none'),
(3865,'entry','bBCEJMnX6peJhGvErA9JxAQqvYbmYmc7pzvET51ZxphJ',0,2,1,7,0.059850,'Ledger Green','none'),
(3866,'entry','7oPxfhnswHLxvPa4SaeAw5sXDFCSfBiEeBTXdwapxTs6',3,7,3,3,0.049920,'Filing Grey','none'),
(3867,'entry','ZGDADsZzoBSXEiyCifAu6bFPAPQJSDZnCed6W23JgAvo',3,8,0,4,0.046150,'Filing Grey','none'),
(3868,'entry','Z5iaecURqPSA6JhciizVnud7Pg184iJP8VB8v1N662KZ',0,7,7,8,0.027280,'Filing Grey','none'),
(3869,'entry','HUQKDo9jRaWGwf8A8a7LE4vo2JrCpTWXq3UPnQa1cdmd',6,2,0,3,0.071040,'Toner Dust','none'),
(3870,'entry','96pXKUbaLdg3T44faAiywZQw5yDTVYxGh6yfnZZcqY6U',3,0,3,9,0.041280,'Cubicle Slate','none'),
(3871,'entry','6auvjxDL5gyCF61Sd8Hc7fdL4gxASaVEEjabH18CvZfj',5,0,6,3,0.052510,'Ledger Green','none'),
(3872,'entry','eTThaFH46U3ZHwcBUbbT3AUMbgsEYvrNXij62wP1AgWZ',0,0,0,7,0.138180,'Filing Grey','none'),
(3873,'entry','aDV67q9tx6cxkrih3bMdPWP6LmR7onrAb4cK6h6GQacR',0,5,2,5,0.044160,'Ledger Green','none'),
(3874,'entry','BtiCJ1WAnPZcN96Ewr4GnEc2dFPEE6BkfKg3d81BsQJH',3,4,0,4,0.045560,'Ledger Green','none'),
(3875,'entry','jq95PjzGsacvNQctVf2nL1KNykDzVKHJxbPGpXdQ6mza',0,0,7,0,0.047570,'Filing Grey','none'),
(3876,'entry','GV9G1h61LEjmLuyuGXRGb4RUrWaYpFvvT958zuwYyEp1',1,0,4,5,0.057040,'Drywall','none'),
(3877,'entry','2hAEP7UDY5RPSXxdgGmRzCzDT5gbniB9o5tzsqoZvhjs',7,9,2,7,0.044620,'Manila','none'),
(3878,'entry','p53dtiUp3ERFgpgyF18y4SSA6qDx2kp51Q6YraSadPYj',0,2,7,0,0.053360,'Ledger Green','none'),
(3879,'entry','wamdv5uvwuWjktNSkMG8K1G3nzF9iyXFcvYNSb3X7iQE',2,5,6,2,0.078570,'Breakroom Sage','none'),
(3880,'entry','rfuj8H1fKbXq2io5aKbBygkfENwo4y9kntMbhgZsnjpw',1,0,0,9,0.040940,'Ledger Green','none'),
(3881,'entry','97Yv99rmrVhc25v4iCY599wCcWoB8WfqMbsF9e926xjp',1,7,3,9,0.048990,'Ledger Green','none'),
(3882,'entry','NsdmEE1rhZbTKqrjzwPekgMQwBZUxRQxgzsXjH3wDcPv',4,3,1,8,0.024800,'Filing Grey','none'),
(3883,'entry','HTpGViYPL9PtktfaAie97bCx5EeyjJihN5erVVqaJK6P',0,7,6,0,0.064320,'Manila','none'),
(3884,'entry','29tMXczrA92r75Qxwz1hUhZVQ2CKJMx9Yj2oQC7xQQGh',6,9,1,6,0.029440,'Manila','none'),
(3885,'entry','WDjqAVyTCPjnjX7qZFQ8kmtUC1hzj7ScjiLnzJ78ivYM',4,6,6,7,0.046230,'Breakroom Sage','none'),
(3886,'entry','WV236eUP2xZVJd9AFK9jY8xGMxhuJmudSVPjVNmemJZg',5,9,5,0,0.041760,'Cubicle Slate','none'),
(3887,'entry','PWDhF25Y9tFAp9HUvy27G99Fi2whmM4jnL91nFcULjLB',4,2,3,7,0.042320,'Ledger Green','none'),
(3888,'entry','MLhEHjBrjEEL5twS2sLuAqW32YiQNEaLRXDAapsUqnUe',1,7,0,0,0.034800,'Manila','none'),
(3889,'entry','1VP8Q4kc2XrswP13Lm7naS8yGg31jwVGTVg8BbAEXmRs',6,3,5,9,0.025920,'Cubicle Slate','none'),
(3890,'entry','sxtji6ENFrkRqZ6ugaAoiapcsFgSu2TZGAsdJ3GoiV8v',0,3,2,7,0.056980,'Drywall','none'),
(3891,'entry','RwojXbjTuD3mr7iNa8CcCF9u4aD1iQHgoQSdo3bZ9VPj',7,1,3,8,0.060680,'Drywall','none'),
(3892,'entry','4MwDSXXBcFfoS72HMhHMHJ6fv6rmegoz1DFuHhQQMrYw',5,3,1,4,0.035990,'Ledger Green','none'),
(3893,'entry','Unj4niNsSLHAzMq4TAvh2d861CvjWucREHpjnRrZcJhL',1,1,4,5,0.027280,'Breakroom Sage','none'),
(3894,'entry','us89BgWfLEtFdrWh91e3k6g5YDZC5udPezkPuPhpt7Gc',7,2,4,8,0.044200,'Cubicle Slate','none'),
(3895,'entry','NBGSAu5AbqLn8Sx1AH4DYmH6zxUsZQmFo1g3LNbYtQ3n',1,7,2,9,0.059630,'Cubicle Slate','none'),
(3896,'entry','GobdEJjBoh8yMuhNhbwJDEuvS6Bp2gRyWZxoftcaDBSL',4,9,5,8,0.037700,'Filing Grey','none'),
(3897,'entry','X31WFNsC75wbgo3vLBDrozr8HZHqcAhZWCt8oPtGg8m6',7,4,3,5,0.048510,'Drywall','none'),
(3898,'entry','YNvjEcGYtGQqZUi4mKUHxsHVoKis18yaRFtTXRA37SFb',7,6,4,3,0.028160,'Drywall','none'),
(3899,'entry','ocsxq4TJwJZiySRdPcy1xUVxwUkF1JCHgG72SUecY5Ev',4,1,0,4,0.040320,'Ledger Green','none'),
(3900,'entry','dtzfu63XayhdNPAELRnfiG9sgw8bkzthUKtEbumAbt69',6,6,3,4,0.057510,'Ledger Green','none'),
(3901,'entry','cqSuwgogBJy2yCG6zMjReHd2GBSwEuYHDQnAmwru7r5Z',3,1,1,2,0.041540,'Cubicle Slate','none'),
(3902,'entry','HYQJ4EmybfPU72vVb7AHjSbEt9yqHithNJVEpjZsZnBe',7,3,2,4,0.053550,'Manila','none'),
(3903,'entry','iTRoUgjD4K2pxT4qzY2orxQ32tHR1Upgk9Q9dbSjY7K3',2,1,0,7,0.057420,'Cubicle Slate','none'),
(3904,'entry','H7V9EsDYkfRTk4RFUfArW8gvBnGt5fXjnrgWqLFjshDs',6,3,6,7,0.034560,'Toner Dust','none'),
(3905,'entry','rsTKntUBEBdDceoxPhgMstvtxHKYJGuBM7cFCJRR3Dib',7,9,7,5,0.093240,'Manila','none'),
(3906,'entry','wqqBDxP3LJXod3wQtaY4Nujgy8RNq3kX9NZbs8aXSrb8',2,4,2,9,0.051660,'Filing Grey','none'),
(3907,'entry','Y3Uxgkd7ZWcK5mx9bJj2TXBKTwR9DaQEPaBfg5bSoE84',2,0,0,0,0.044250,'Drywall','none'),
(3908,'entry','eBHLN7V9catt8VnHXLmFTFrSxSFz7YT5D1fcGHs7cg4H',2,8,0,2,0.054810,'Breakroom Sage','none'),
(3909,'entry','kHmBABsCej8AM1y8wFGF7PMS3oDtqJmY1bb87gHP1aNo',7,7,7,2,0.033200,'Drywall','none'),
(3910,'entry','arkDGfBJL9uaGV6jEA1WXn4XbsBGwdakSyKLidXPR9uL',4,4,4,2,0.035420,'Drywall','none'),
(3911,'entry','bVW5oC8RKeF59KUHyhswZi49gtexg9BWFXk2hbjdxPGA',7,3,0,0,0.038430,'Cubicle Slate','none'),
(3912,'entry','JiUgo2wxPK3NWsQgMLJtKq9nw8P5iTubi9YWcAc41Q5k',0,2,7,0,0.047840,'Manila','none'),
(3913,'entry','33N8sEZd3Y6FmynyMHuoQ6QgbTvfEn99Z5Hru7HStPRW',0,2,7,5,0.074000,'Cubicle Slate','none'),
(3914,'entry','D9KRuwcnzKNTpL1E8DbXH7244S4LdN2zHswWTan5oGSQ',6,4,6,4,0.051660,'Cubicle Slate','none'),
(3915,'entry','E3kWeYCWTZccbRv8LfMEer9ANuuxnuNu2jhyrPoqr4Zo',4,2,0,9,0.042880,'Breakroom Sage','none'),
(3916,'entry','FWkB8w9CaozXKcoqT6QK6EnbC1mMdmhCruChZrSLLFpg',3,4,1,7,0.052510,'Ledger Green','none'),
(3917,'entry','8HsACLqDZ733SkjQu5bX8HvUNQg3VBUACGWHUe2ZutSH',7,3,6,8,0.063480,'Manila','none'),
(3918,'entry','NGo86M7PQuEkZ2fBCRcGhSRGNcxudDmDHtm4cH6XGMtN',3,5,2,9,0.027200,'Breakroom Sage','none'),
(3919,'entry','vnSpeRiPjVyfSDCBTghdEgfAVzw49rqj623AeCEdUftY',6,0,7,6,0.035990,'Drywall','none'),
(3920,'entry','Wk4pvQFfrNM8q88uJ1cQkWKKg2AEmsCYs8fuimZUm1f6',7,9,2,9,0.043660,'Toner Dust','none'),
(3921,'entry','V2NDjTYsc6SS5neftY7BDDSEwsk1RNg6H3R1yMu946ci',5,8,0,3,0.050150,'Toner Dust','none'),
(3922,'entry','fxiAjhfYaUenQQ2fUAYC2LKWqfgMM4q2yFLx381VCRdk',5,7,6,4,0.119850,'Breakroom Sage','none'),
(3923,'entry','dGb72fibDVDoqgKiTENrMaeoHANhjpoWcyoXv5X8B9JK',6,4,4,2,0.047840,'Ledger Green','none'),
(3924,'entry','R2WNLCyqztwd2srmmQWc2LHwa5YunyF1tyxAHiCfSTYH',2,9,6,2,0.071280,'Cubicle Slate','none'),
(3925,'entry','PMHQXZqkBTCRHFjsPexe5Kt9jwkWu544kHkXAy1GMVe2',0,0,4,2,0.036960,'Cubicle Slate','none'),
(3926,'entry','xLqvcsCazGJu4T1UMA7o2EpwjGrm3keAZCSB5jBqqoNX',3,9,1,6,0.029040,'Toner Dust','none'),
(3927,'entry','rB6oLmfFS1wayFgjwMrdy8TH5xXcJjy4gCGnMsEGMhXY',6,2,6,0,0.049400,'Cubicle Slate','none'),
(3928,'entry','fz3tpRjezZEnxqaefjcRG2PoqsasC8PLu1pK8nqmrrnM',1,8,1,3,0.046620,'Manila','none'),
(3929,'entry','BSw3f5QPx6n6kQxsyCCcJjQrvkmKXcQxzgjuhfmbrt8L',2,5,3,7,0.038400,'Drywall','none'),
(3930,'entry','66EE7phFpAPX5YagNPzd6Vh8V1DPYCcyygacqqks6JXF',1,6,1,4,0.029480,'Cubicle Slate','none'),
(3931,'entry','mN5vcEAGeLvhwSGyANV26WiM84aoYVG4fkB6pAgiFNSL',7,7,6,0,0.039440,'Drywall','none'),
(3932,'entry','HpDv6gNWXLGg8FRkA4m2coNuxRuqREgTQg66EmMzwopT',1,4,4,3,0.062310,'Drywall','none'),
(3933,'entry','DwoVb3DMTL3JcnWA8hcwY6DXsBhTu4y2GJRixTqdftWA',5,8,0,9,0.052780,'Breakroom Sage','none'),
(3934,'entry','m25nUiKVMim14kJkfMvAemnfRc8jXmSmzGFovXapCo93',3,2,6,7,0.028520,'Manila','none'),
(3935,'entry','BfTwvDs6DLGqQXa2geAFxnkWgWoFcfV5Azr8PVvaxJDC',7,7,5,4,0.026560,'Filing Grey','none'),
(3936,'entry','ujipvhDKdDpPvsGzihnmv1uLnx3vRYY8mwfuzWawhLsA',7,9,1,7,0.032240,'Filing Grey','none'),
(3937,'entry','Qg7Agq3ymiAnQ5hDJKpWU3cybLuDk2FDFw6vskLtNWLS',7,5,2,5,0.059640,'Breakroom Sage','none'),
(3938,'entry','NsamrucDSHpakHqUaup3bFaTRpxDgWrQ2yznbtroJ3jM',7,1,3,3,0.038800,'Cubicle Slate','none'),
(3939,'entry','hCF6Hz4mKUp8GpTSAPgX1XosjewUyMXovoXFZhoRGjCw',1,8,6,7,0.040480,'Breakroom Sage','none'),
(3940,'entry','Sk4mFGf7kJQvBwSjed1M3aT5LhBXZ1QeBN5tKkfpjf13',0,7,4,0,0.041540,'Filing Grey','none'),
(3941,'entry','uCS5FYjXVNYW4YXhGpeRy2UgvrXuqZxjAuSGBxjgvzHz',1,1,3,5,0.061060,'Toner Dust','none'),
(3942,'entry','Tx9VMTbdrZTtQjnzUQbMexBh5bTfUoBjj7wVfvBNsQ1m',2,6,5,0,0.044720,'Toner Dust','none'),
(3943,'entry','tCHky7Z9GPcnzMyR4QraRkAf9p6cHy3JHcpRjZva4bPm',4,0,0,7,0.041760,'Filing Grey','none'),
(3944,'entry','9j7iYg6FKKufHGQ4Z4Vn26o9mUiZYEWrqtwNdNiQ9T31',4,3,4,3,0.037440,'Cubicle Slate','none'),
(3945,'entry','BQkREyvrgCMEYBiwSMH6XWhnpssS85beUwpP5C2JWPi1',1,5,4,8,0.079380,'Toner Dust','none'),
(3946,'entry','AzTmuzCLEMaTTZYAdyiSVtpLsfdxk5CGC3YU61rzJhR8',3,2,1,8,0.067450,'Manila','none'),
(3947,'entry','NsdKmM4SnzBDVgNhDNXRQkibDm4zdhjtZEcnXqHEBwvN',0,6,5,3,0.026400,'Toner Dust','none'),
(3948,'entry','5F2gT3BbcXTGErYgt7zEySinxA9Sx1Ls7yLgcQc5pWmJ',1,4,6,9,0.039360,'Filing Grey','none'),
(3949,'entry','Dfzo28RdLY2AnATfabMsGy1GunjsjaQpFECjLkgFumyS',2,0,7,0,0.131130,'Manila','none'),
(3950,'entry','Np9ZNYpccmtuqaGeDyJBhab2neQoZaHUnAcQB1seLMG8',3,3,7,9,0.074520,'Filing Grey','none'),
(3951,'entry','YCJnb411YAdCbxg8yySUekDDksvaMUrCRurt8ut6qgeu',5,4,2,4,0.046980,'Manila','none'),
(3952,'entry','HH3kR8pGPjWmXKABNioH252bkAYqWzr8myuq7LtVWJKW',1,6,6,6,0.044720,'Manila','none'),
(3953,'entry','b1tBK4UTBuRchmmByGXsDwL7T5nifgWENk1AzJLmc964',6,2,4,9,0.059940,'Cubicle Slate','none'),
(3954,'entry','znZS43SSpGPn5yuKgmbb5CZGQ3Zd5AyE8nAuX93kZ5LU',2,4,6,6,0.052780,'Toner Dust','none'),
(3955,'entry','4JjR3fCrcL967MRZT686tDmZRGTWaWS5cDaRp5HDqDHj',7,4,1,7,0.031680,'Cubicle Slate','none'),
(3956,'entry','B7mRqE5eUoYSnnPGAwWz5kyyKxq2xcjV5bZaQ29ue5Th',6,2,6,4,0.061640,'Ledger Green','none'),
(3957,'entry','FHH8wusB9JpfKU9Ds2ZMrSPVan61dwmTC26H7PQs74WT',3,6,0,0,0.040120,'Cubicle Slate','none'),
(3958,'entry','8VwSLDPgi4723tfBhGEkScvTWKxb6ZpKaQ9TVi87Qxcm',0,1,1,7,0.024400,'Filing Grey','none'),
(3959,'entry','DYQpYnN8JiYVjiWCoDSKbZaMqZ2VrBVE1CE6j8ZMrvdV',5,4,1,2,0.071040,'Filing Grey','none'),
(3960,'entry','Dna1EyDNqSmtaDUmRTJqeZNntvHgwhuArvV2VpRhbDU3',5,5,1,2,0.040320,'Toner Dust','none'),
(3961,'entry','s4Q9AEwAThNKucG1hHbaqHxbDpPRAZHhcEhvDqpNS3SB',2,0,0,6,0.027280,'Breakroom Sage','none'),
(3962,'entry','9ZWskMkL2CFT4TWxaHHG32qni9UiG3ZoAN7sYYoiRhEY',7,6,4,0,0.051920,'Manila','none'),
(3963,'entry','1CYRzP5ar7rdUjuggdrnQxvZh2qqaHMNexGy4QEpg5Ri',7,9,3,9,0.047040,'Toner Dust','none'),
(3964,'entry','dEoBvrVnyYGpfMcLsmf6V7BCaf4JYDE1t2gVoMPhS4Rq',4,9,6,9,0.030080,'Filing Grey','none'),
(3965,'entry','USmDKdyAVmvkdoXfEh52CcAyPwqHXmibL2Pzs1juMj6Z',5,6,7,9,0.024640,'Drywall','none'),
(3966,'entry','jemq7vKKa55VV3LfyWtMeAP2gcv2W7rNkfe32wQJosSr',4,3,0,7,0.053280,'Toner Dust','none'),
(3967,'entry','bTDFkPetAZirTaUFXBvw9CCF3ofBpMhyQEuhxYSJ1fWW',1,0,3,9,0.042340,'Toner Dust','none'),
(3968,'entry','2SD2LquLCCZVvsX4SgtqDGadpSg6zcyVUwWyhxnAEurx',1,5,2,6,0.021120,'Cubicle Slate','none'),
(3969,'entry','qkKifZ4HC4wDupHvSZCMdvnM2vKDCyPTZM7PVsiKXnfy',3,0,5,5,0.052510,'Cubicle Slate','none'),
(3970,'entry','rRawyRfvDXbnE4Xq8H7M3soxwHY5xYZNArPAkbYK2PyN',3,9,4,7,0.048880,'Filing Grey','none'),
(3971,'entry','xTdERvb6KpiNacXJsB7z8nYbbw9vDMRYfGhJQ6cfXqus',3,5,0,4,0.052510,'Breakroom Sage','none'),
(3972,'entry','fK6XtvcDYG69eCUH5jxRfZm69dWs4g3oULMVcqV51tFi',1,9,4,3,0.029920,'Ledger Green','none'),
(3973,'entry','cmB6PM8pTHY18KGVXqrJGhUK1Eoy4rHddeNAeww2VVqi',2,6,1,8,0.051840,'Ledger Green','none'),
(3974,'entry','9ZnfqjZjJq76pAxhCykuqzTEVGuxEyGmQc11QL8PF7Yy',1,1,1,0,0.057720,'Ledger Green','none'),
(3975,'entry','ZnqF6LrMWa6ZskDeoNEdNZWzmSLuVdJCFXBq1F1zia1q',1,6,3,5,0.030240,'Ledger Green','none'),
(3976,'entry','Zudvpzszb78q9C4PgWA422ZVAPZAabGXTiVkHYaoBXSz',2,0,5,2,0.021120,'Toner Dust','none'),
(3977,'entry','5ESMTr6r6sxfCvQAi6oxL4Hy195fx3ermRq75zkPd2uq',7,4,3,0,0.112140,'Cubicle Slate','none'),
(3978,'entry','NTJfo7L1KbwMKUaSDPHJgGCjWpTpAxoD486AsbTirUUq',3,9,1,7,0.033200,'Manila','none'),
(3979,'entry','wWSu9rhaj8RJHmiAQxgQYr2jzBXEt8hEsR1tkza8nRx9',4,6,1,0,0.043200,'Manila','none'),
(3980,'entry','UoXC9MdYSQj3n1dGfodyH9BnejzgqxSJ58Qt5Mg6rYcu',6,4,1,8,0.074000,'Manila','none'),
(3981,'entry','zE3EbvXxboEwtRVa18i1Ykp14zLH7k85te4niWjH6wfk',0,4,7,4,0.045240,'Toner Dust','none'),
(3982,'entry','vvD2R61iEo7izB73kFinA1JHqnckRRUkbWng4hdt6x6U',2,1,1,0,0.065120,'Drywall','none'),
(3983,'entry','BxAxChFJmvntMoPEy7hapgsZuJgcsvw72b3Mz88gkSZN',0,1,6,7,0.062560,'Manila','none'),
(3984,'entry','aMTbnnLRiqytqVyx5zNWUdFZ6AS3tEuBMTfrBo6ana52',5,8,0,3,0.058000,'Manila','none'),
(3985,'entry','ewnkjmXkoSLEtYr1vwDKyqSjXDtGAhDAwKcuDqWm4H59',0,2,5,3,0.040020,'Filing Grey','none'),
(3986,'entry','4cHCjrMhQLZ9C79hdNAPAVTvUGvRVKSSR5dBX3ATeeTz',0,9,1,5,0.061060,'Cubicle Slate','none'),
(3987,'entry','r5wrKAwwkJx5UTuwSV7Md4Rdsk2vCmFDLh3pWhKsEyoc',0,1,2,2,0.056640,'Cubicle Slate','none'),
(3988,'entry','K648enq7qTpR4XdAiQUyWDGK6k2fepovseYW5DBjZFee',7,8,6,2,0.020480,'Breakroom Sage','none'),
(3989,'entry','JxEoT7FfEZwWzXd8tgSEwcsq3X8H6zj6vj2VDorR7GKL',4,8,4,6,0.045560,'Manila','none'),
(3990,'entry','CvrkZyh7NwtVTn2NXUEV4QqZ7v6NShvdhTrtacJFJJsN',3,8,4,8,0.034500,'Drywall','none'),
(3991,'entry','C8Zx3Fb7yF8brGrM9bdiGT4B6HpVMVUqwResyXHpKXzb',5,2,4,2,0.033600,'Drywall','none'),
(3992,'entry','UdUu831DhrtgFNCZMv14dnz48uDmaibLShSkrkAoXb5P',1,7,5,4,0.058000,'Toner Dust','none'),
(3993,'entry','nXikJtLxADhU6uDStdgVHUidcyo2xGNuzMXkC8QiqgAJ',1,5,2,4,0.033440,'Toner Dust','none'),
(3994,'entry','bGSd1WPMjSbqzsYuEQ1BWUc5wWeG677WnesYk4JSedAL',1,8,6,2,0.036960,'Breakroom Sage','none'),
(3995,'entry','Qkg7ix5jsrChvRi1LKB6SLjQqaQSqKDXN6ARRdCDZMzr',4,5,4,8,0.063990,'Breakroom Sage','none'),
(3996,'entry','qCbYcBSvufJnb2pcVib92DmE7SmK1hF1JpPbe1w9pHXE',1,1,0,0,0.030720,'Breakroom Sage','none'),
(3997,'entry','aZMdVvR9neVMfVEh1k5ZthiBpK3pYexKeU3zfKSPh748',6,2,2,7,0.029040,'Cubicle Slate','none'),
(3998,'entry','ZiT9q2JdA5u6SJ7vGiFgoMUJhyv4zZdG9Ty64xpTgPho',0,8,5,6,0.034560,'Manila','none'),
(3999,'entry','TGLKbRBRcWtr988c3WFY4fq8jvVMtkGA4CrcFeNWkCmC',5,2,2,6,0.038940,'Drywall','none'),
(4000,'entry','S4W77bVpu8ndDsj65h3531dLMXh2pj8SRRQwTgbhVrDz',6,2,2,8,0.025280,'Filing Grey','none'),
(4001,'entry','N3kMAqgXmui7LiziEADQBMEAtQr2LLLJEPLm6cxX6Rse',0,6,3,2,0.027280,'Cubicle Slate','none'),
(4002,'entry','wQL5z2Gna5b1oWoTQJaRTdHp2VbGNqNnGWsRHuMh4FPV',2,7,1,0,0.021760,'Filing Grey','none'),
(4003,'entry','WEJc9oRwdbJBNNY3BQWARSerYtSWJQadtF2kNLZVZEEm',6,2,0,8,0.031680,'Manila','none'),
(4004,'entry','ZAcatU63E41M1ScVhVCm4GJXd5BZB4EwogFHLoccvs3Q',5,3,4,0,0.032200,'Manila','none'),
(4005,'entry','9Rh5366pV6HWiaFvQM8WouWYXNJip8UrsCGkNJiBVFzh',2,7,3,0,0.023680,'Manila','none'),
(4006,'entry','2n36QEdWBHJ6ZiAetd1Fo7iMHvuTZFhwjidAZZqpEt73',5,4,1,7,0.036400,'Cubicle Slate','none'),
(4007,'entry','iE6udqQ9sPB94a7TVXGZjoMZCFjxQVcbA3jAPcnZ3Coc',3,3,7,8,0.044400,'Drywall','none'),
(4008,'entry','EACG1DrjwdnaSmr5UJYgSTe6dinEDs7VngE3aUctfP8E',1,3,7,0,0.034320,'Drywall','none'),
(4009,'entry','TtvnYukPVLTTtNAK6SmWB8dkEAA4B5Vk7oxD4NsNVA1g',5,0,7,4,0.035880,'Cubicle Slate','none'),
(4010,'entry','bu6zu1qPhBtBUqZjiVYT3rGE5nXekDR2gYQQmAffrot4',2,7,4,0,0.044080,'Filing Grey','none'),
(4011,'entry','mZJg8sLNYiJvjUg2RRcxFB51BWoLaQYuPEB7ErDaNeET',1,2,4,0,0.030360,'Drywall','none'),
(4012,'entry','8tEm1Q1urLDckZMc7Q7LyriTFjTgdGg7ewFPxHGLfXLs',6,1,3,3,0.052510,'Toner Dust','none'),
(4013,'entry','SzFp5N2WyDweXdWJLrm9Jz6GQNXvKQxMRWfP6p5K3pX3',3,6,7,5,0.051040,'Breakroom Sage','none'),
(4014,'entry','s3AYqstRAQnqhNWnx7sKBSiWz8DG9FxBPGvsngHS6Zui',1,3,2,2,0.029440,'Breakroom Sage','none'),
(4015,'entry','6mcR8UxDk3QxnaEjgCBWbrWKdYZecngs72BSm7zSyhWF',4,8,5,5,0.070840,'Filing Grey','none'),
(4016,'entry','8tDRgxSVyAkAGTnbNaaSZN32TZPy4nRmFBQikiBhKjjP',0,4,1,7,0.034800,'Filing Grey','none'),
(4017,'entry','Fpxg7dv1iKGAVfu1oX3YcBxzVzmJJ2Jsc39CCgEPLbhp',1,9,4,7,0.029920,'Manila','none'),
(4018,'entry','8q5EqSY6thE2bNqXp1oSdgirmS39RFUhkFVmE7tdsL7B',1,8,7,3,0.056260,'Cubicle Slate','none'),
(4019,'entry','x6Fh1fxwvRhHXgtzKt4sP9UdAV3ELbJwrwxrLurh4277',6,1,7,0,0.048880,'Ledger Green','none'),
(4020,'entry','8PR2JJKsVjkXR3WqhWjH7ma3bR5VioLKJFquoFD5Qd5y',6,9,2,5,0.044640,'Toner Dust','none'),
(4021,'entry','vGKoN8A61Sq8qaL5mGRCxTAHg4cuX4hcT6TgPNq3Mu49',6,0,3,0,0.030720,'Ledger Green','none'),
(4022,'entry','SGq9cp8WwG76yYNXYPivWpv6g38xWXi7nZ3VzkR7neZd',1,7,1,3,0.032000,'Drywall','none'),
(4023,'entry','t8UznA7YWsKSoGaJR5XXZxanvHv9f9Fo63CTHVEcLdve',5,2,1,2,0.030720,'Breakroom Sage','none'),
(4024,'entry','1gUASKahv625jJv2SycjtEr8mc16ugKzRr2ApyFkqPMz',0,6,4,5,0.031200,'Breakroom Sage','none'),
(4025,'entry','MS6tpsWFmJ8eiCx6f79D1qFmAAjJA3DMtdjzf1nq2XW2',2,2,2,5,0.041400,'Filing Grey','none'),
(4026,'entry','Dbprp5snwfw83DN6m684rdNK194eDwj5B7ANHaE5NCkL',3,4,1,8,0.031200,'Drywall','none'),
(4027,'entry','CWgJXAPtxVfsmVSQGDFciRPHkcemqZk8yHnJuvnF4i97',0,4,6,2,0.039060,'Ledger Green','none'),
(4028,'entry','L3rnUgWB3UNjVPPtudePPrXY1g4wDygNLUbKd8X3ZPwU',0,6,5,9,0.038860,'Drywall','none'),
(4029,'entry','4XBHcfjj2yc4gbG7kNSHkzenu5qdfdZ1U7c1LAvdtC43',6,9,2,5,0.020800,'Filing Grey','none'),
(4030,'entry','EqvyFrhXXKGPuuBaungRgLkBpZvdXZEtmBAzjmn9iBSM',6,8,2,9,0.082800,'Toner Dust','none'),
(4031,'entry','DanA9Ducq4D5eqqMuKpMpQ3GCXLZZZt9N6NRuoJaJDbk',3,3,6,8,0.045080,'Ledger Green','none'),
(4032,'entry','qgBCDEiBtWdNov1WUheTtjXdQaqUHCso5wHfUZBUyCPS',3,5,4,9,0.055100,'Filing Grey','none'),
(4033,'entry','EPotBpw3soUgn4vLuuGvukBtu24v1TJx7JAV4uzDR7A2',6,3,5,0,0.071780,'Drywall','none'),
(4034,'entry','P7mA7teSueavScZwMUVLV2mwnrww15NgQ8WPVzC8x49R',3,4,2,2,0.045820,'Filing Grey','none'),
(4035,'entry','TKA9FKzhxQSBRCGLPDQtGLbhom27qpsvdAmQUqQCRcut',5,2,5,0,0.048720,'Cubicle Slate','none'),
(4036,'entry','6tbam9HACenMZuqkRuBv78qGR6WZt8KiU5AnCxrmj7RL',1,2,7,0,0.058930,'Breakroom Sage','none'),
(4037,'entry','nopRZ36it1fwRiErJYckZsjduHsMFPGEofsVH1GiEjUC',2,8,5,5,0.036540,'Breakroom Sage','none'),
(4038,'entry','ASuUfCaUwy4XjxANErCsZXZpF5c3hvJqG9Yeqs1NeAQJ',0,9,0,8,0.053600,'Cubicle Slate','none'),
(4039,'entry','8wSa9h4r2STZBCR8xFH1an7i4sBZBHUamTByRPbBy7Kq',1,8,4,0,0.040480,'Drywall','none'),
(4040,'entry','KDjY9DYrp2mJYkrVXct1ARvRWUbM3vS6Ru1J4GAt4QXh',4,6,1,8,0.042210,'Drywall','none'),
(4041,'entry','oRpNjqmqhhJoFbFBRmuxDiBeXczCLBVJhH9rWDdJ4Aqd',1,2,1,5,0.061640,'Cubicle Slate','none'),
(4042,'entry','vV9tqEZh4SPuSSMvV7RsqYBWpwZc5LphXihZ5bkmzYPe',5,4,2,8,0.035880,'Filing Grey','none'),
(4043,'entry','bMAR3uwgQbtMYRqyZ2PomAwPSnwSAXcsa3XK99wmLyqK',0,1,7,7,0.054870,'Cubicle Slate','none'),
(4044,'entry','ERVLVfU5Y4XYrL6EBeo28TZJqp4p2mEHvZY3HRMs2o5H',0,0,5,9,0.066600,'Manila','none'),
(4045,'entry','z5NbFtcnYDQLux47hh66JryeBPi76Z9CacDMq3b3oK5F',0,5,6,3,0.035200,'Cubicle Slate','none'),
(4046,'entry','PTS65Jgg2EFA2y6AVw4jnSreFFfGyVTCnPvoog23h4gL',5,2,7,4,0.028160,'Ledger Green','none'),
(4047,'entry','Y8HkCTVKpwNvp78EzC1pHH3x58Pse3Bm9PUcHTQZtMz4',2,7,1,8,0.030800,'Toner Dust','none'),
(4048,'entry','SGNbku1QcXUoAUhFzrPkfZcnwZzNDApYMCu9nM2Wjkit',6,5,2,0,0.061420,'Drywall','none'),
(4049,'entry','aXFwboBmaz8LnVVKPwnzaEbVXMYzcF14J4dBGqYvX6KD',4,9,5,3,0.024400,'Cubicle Slate','none'),
(4050,'entry','2BqESC4iafFgZNJKfiaxSV6iaV8DiRs21kEFXvLffzLX',4,1,6,9,0.047790,'Filing Grey','none'),
(4051,'entry','RQD9KMNjWqQThwtCNKpgPchNUEA3cRcawCoZRNo5tMVC',3,7,2,0,0.044640,'Ledger Green','none'),
(4052,'entry','NksAgChgmbuUWzgbrNZLVE7yPWfmNLiVmWjWtjDJF1vr',6,6,3,2,0.032660,'Breakroom Sage','none'),
(4053,'entry','ces1MzMeKWitUPdDdSzRF3DWoSgyUWodXBkTWD1fQW5y',7,2,1,2,0.042640,'Cubicle Slate','none'),
(4054,'entry','kn3EPdXC1Raj2y7Awc39zQK1gnPXQhqvrJfvdvHhiYvB',5,8,3,2,0.027280,'Manila','none'),
(4055,'entry','MKmi86DDG5nvkpfJQ8Nv1ULkcXgLAPYeCN4RdFuHXTjg',6,9,1,0,0.043680,'Breakroom Sage','none'),
(4056,'entry','4ZMne5uKkjFTSkKUD4jqmMivJURA8UP37PXW9CQDWAj7',3,1,7,5,0.059800,'Cubicle Slate','none'),
(4057,'entry','ziKYeTSaunqD1n2hBdpVMBVszBX53pQM6jSxMhB4p9yk',4,8,2,6,0.057820,'Breakroom Sage','none'),
(4058,'entry','MJq6pRANmMpsg1u7nh5F7rBCP5i9EZa3SU4shnsRMdDz',7,4,2,6,0.081000,'Drywall','none'),
(4059,'entry','1x1Wwe8NoFGqAkcJA1XndJYdgPn2eZkvtEq7W8fPjVJK',6,6,6,3,0.035640,'Filing Grey','none'),
(4060,'entry','xBbMJsMfgWLTn7ofVoM9yoLM6g1vTRz3LU4HPEG3igBC',2,6,0,8,0.028520,'Breakroom Sage','none'),
(4061,'entry','DoqvtWTBdNuf6knZFXL74bTisYjR8XwipCASqhS2gmp9',6,4,5,0,0.020800,'Toner Dust','none'),
(4062,'entry','HcbncRQqEd86hNNfQP7mh48RpEFqYJhcesXANtHbsE5G',6,0,4,8,0.032640,'Filing Grey','none'),
(4063,'entry','fQGhUsvtLB4TvNJde3c2FyLYDSSJvKAtqKGuPVTMEoPV',6,2,6,6,0.044200,'Ledger Green','none'),
(4064,'entry','v3o8868J359AMQDEY64VmhU6pUyudgY6M5c5ghzE5YAw',2,3,4,3,0.045440,'Cubicle Slate','none'),
(4065,'entry','dw7HN5aopb2mHxRwq3bakHg6A1R14hqaCTEkNTLzc9By',0,7,0,2,0.040040,'Ledger Green','none'),
(4066,'entry','mTeCMWbJNp4swDeJfdNvEL8snWyXVdV5MLaUH29tZJDF',4,6,6,4,0.048240,'Drywall','none'),
(4067,'entry','rMBBZnMwojsPACFWdvokmLJk3KahH71Q2LP9ax3kUd9p',7,6,4,2,0.049580,'Breakroom Sage','none'),
(4068,'entry','kRwVTroYnEyguG4EKihGHA9txMzKio2QJpxW61bwU27e',0,5,3,3,0.045080,'Drywall','none'),
(4069,'entry','VRGVuuAXHJBoEepgSpMYdKN6Qj1uQHf8Y7FiGFZwWmjM',6,3,3,3,0.036080,'Drywall','none'),
(4070,'entry','7cf2yKAfsf59MkFD7RJ4AfsCbunR2Gp5YKnHmGJiUZEp',6,8,2,3,0.042920,'Filing Grey','none'),
(4071,'entry','EHWh3r2aBZcMX1kY2CQTQzd4dt3fwLfGgzABgE1DaGWZ',7,7,6,0,0.071780,'Manila','none'),
(4072,'entry','G36566ewzXksVqUBRQSV5DDnG9WYywzLMF4wkWaamtAs',3,2,5,7,0.024960,'Drywall','none'),
(4073,'entry','TBSict6SpFENdatAebTM16mVixzDibvcNCeQDtoVU1xn',2,2,3,2,0.048360,'Manila','none'),
(4074,'entry','EokgVE3AdMSYVoEiWB3ys5vRNrZTVRoT6885RHXg7WgD',4,0,2,7,0.056700,'Ledger Green','none'),
(4075,'entry','3oC7Wgt7jHUoEySHJSCYynw2zEAqjsT9hfrcQSCSBXiX',4,1,5,9,0.047040,'Breakroom Sage','none'),
(4076,'entry','RbakNJ4KgoWB8S4JftnVBswVAe7b7ogeDuFvmEuHTqDY',2,8,0,0,0.042240,'Cubicle Slate','none'),
(4077,'entry','pJN3Ci85GqJScmKZiRiTf1WVgTkKsX41nevF3K5yNHFC',1,3,1,6,0.045820,'Breakroom Sage','none'),
(4078,'entry','6TmzswW4LAE5WkzbwHExuKcZfoEsZihSCJXzRjKX2Z1n',2,1,1,0,0.026840,'Drywall','none'),
(4079,'entry','LrubxK31LgeceVb68FuPFfNZwQ6BwQhGiedPAzwdNHUN',3,0,6,0,0.037960,'Toner Dust','none'),
(4080,'entry','mn9seGP11ZSXfWqU9DM8ixqnwMyEKca6ncirYcfCSyRU',5,5,1,6,0.104580,'Breakroom Sage','none'),
(4081,'entry','iMUjej7V6HZN8fz91uk1HYPvWJFwKXxFYTxYch5NpUQ5',4,0,6,4,0.046000,'Filing Grey','none'),
(4082,'entry','4UqpcRss9ZDLdQuiYuAw8fsMj8JNcL6eU5A8p4UnxCFf',2,7,4,4,0.062370,'Breakroom Sage','none'),
(4083,'entry','GYRdj9vymWsWg6JTkzce8Gbgomxf1pkGzKZ8pPisJBvn',1,4,0,0,0.030720,'Toner Dust','none'),
(4084,'entry','pE7bx6aUaX43zFmFNNpJgh9HvNBdZ5jfexDHCk7YQWzH',7,9,4,0,0.042320,'Toner Dust','none'),
(4085,'entry','TF6GXouA7nZ31JzypmpK8wz1UD4yHs8YxhBM3eeoaftM',7,9,6,2,0.045120,'Manila','none'),
(4086,'entry','kWSuLaVCujCjjBNbHhkeQwT7CJBgxdGoUj5uy6FWkk5h',0,2,1,0,0.034080,'Ledger Green','none'),
(4087,'entry','486XPkW9nZuVxVCDMNbVcYHSBowXa1ERY7WkyHRZ3ph6',7,6,1,3,0.038880,'Toner Dust','none'),
(4088,'entry','2K6PntRV21JjkHBJtQdbYtDZofsExifbfRS8EHRw6VgE',1,1,5,6,0.089460,'Toner Dust','none'),
(4089,'entry','BTYnzh7HZXo7BUVRrXVLu68cun3YCfbJU311GfS9fY6N',3,4,6,7,0.028520,'Cubicle Slate','none'),
(4090,'entry','MCfwgXDB6N15meNWJ2oU5ZZx2aAzTFXYuzqPtmcsVPwY',2,3,2,9,0.044620,'Breakroom Sage','none'),
(4091,'entry','Sc9tqmcizChiK9yKcH6zzrr4LqRoDxxpgewnD5Ejdhkg',3,1,6,9,0.044620,'Drywall','none'),
(4092,'entry','cNx2wpT2r8FsHSjSHDyJsVQV63SPyuQmvEaxveoMVFKg',3,4,5,0,0.051840,'Ledger Green','none'),
(4093,'entry','w2ASGa3DW8qLuUAZB9ST5sP5WnXNgB3AEUB7o87zuv1N',4,1,0,5,0.072520,'Filing Grey','none'),
(4094,'entry','HV5p9cQUBfj88FtkbEMMp2xGXBuLmqwNaEVjHH2rxbXP',2,1,5,2,0.024400,'Cubicle Slate','none'),
(4095,'entry','7wh21p8h4b5uAS6x85bZjU1C7tsaF9CWpxRAhuRnF2dX',7,1,1,2,0.036800,'Cubicle Slate','none'),
(4096,'entry','MFGSPjCVVT8dP1js2pdxFxSYZTPFM51fr9PDB9BFBp5a',6,4,2,4,0.090160,'Drywall','none'),
(4097,'entry','hBoJNuM5BD4hs6ZevAovmbWyDQu4M8UQf7pAEBJRcTV8',4,1,6,0,0.056120,'Breakroom Sage','none'),
(4098,'entry','i1No43f7ScALDy9jdzMuLme193a5SjxtXcZfzdWmooNC',1,1,6,9,0.030400,'Ledger Green','none'),
(4099,'entry','EpapjCoccbZPhw4pEgeZtL26H4ZaGPnPxoimT23HYkQU',6,8,3,2,0.060350,'Ledger Green','none'),
(4100,'entry','apNGSLVhmmjpSKMv8iT5E1StK2KR5z5o8EzW4pPCvU7b',5,0,5,5,0.050920,'Drywall','none'),
(4101,'entry','9JZnmMp1yo4gJkur6K7QSWpmiGobGWFynhHYAeRPR82o',1,5,0,0,0.028480,'Breakroom Sage','none'),
(4102,'entry','p7hrYvZZPpcf2AyeXmoxKaKtxcGjCwqrfUhfMYMGn9NW',4,3,5,6,0.123480,'Drywall','none'),
(4103,'entry','hNG9VzEq9tKPPVUCFcDrBBbxbueDJzovcrJ2qN1Cc4Ei',2,4,7,9,0.035880,'Ledger Green','none'),
(4104,'entry','6NQVCunrfVvHhxMo49p15JVJPPLe994yoz6bKwKphYm7',3,0,7,3,0.027600,'Ledger Green','none'),
(4105,'entry','p9g6uyDEn46b4pGgtaiSPmbxqmjz2Y8YxvmvCspxErKK',7,2,2,7,0.108570,'Drywall','none'),
(4106,'entry','Dm9HfwVf2jkUSJph6yZw9am94T6nB4iBGP6yg5xjz8e1',6,8,2,3,0.037440,'Toner Dust','none'),
(4107,'entry','1xyd6Q7SnowXxS1nnKVkDv3YnZ12nr7RqwdKG2gC7uWL',6,8,5,8,0.026400,'Breakroom Sage','none'),
(4108,'entry','onu21n6uPaY8vn6kwLQhr7afLECUNX4m88xyt6ECW5dC',5,9,7,3,0.034320,'Manila','none'),
(4109,'entry','Crfsv3ZGXSQedGUt7JcGdmax48VtjoLK7JhyfWFtbrJ6',5,8,4,4,0.052540,'Ledger Green','none'),
(4110,'entry','SZ3M1UMA4yrYqgP3WRwz3kCNH9GkYDFZaj4iBrWHaEDx',2,0,3,0,0.045540,'Drywall','none'),
(4111,'entry','2rb5uzDLFzWjreYGQQMnMXPhkqXrXJu2EQVQZKhSaJuc',6,9,0,8,0.038180,'Drywall','none'),
(4112,'entry','mHyXd8i5RuVUZPKWge4YF8PyNUtkCkXHnv5hCwUSRdPq',6,8,5,0,0.030400,'Breakroom Sage','none'),
(4113,'entry','H6X3JVvhuBLVpuy8dYbYhN1LGf1Rf5FJP7dacScYZnJE',1,0,2,3,0.038280,'Toner Dust','none'),
(4114,'entry','tPwRRkERrb4PD1tpHUKTE7APiSGe5tKdBv7tGLPQbUhd',3,0,5,8,0.032120,'Manila','none'),
(4115,'entry','LWRbPLyJUXnPgMAURK4ZHyjxyftAiayLqhWx7q6QzBSf',2,9,7,0,0.043160,'Drywall','none'),
(4116,'entry','YYLdkQWHqWY4DWtX43ck58nHjowtni3brJM8X9UddiZo',3,9,0,7,0.045880,'Cubicle Slate','none'),
(4117,'entry','YhQEjwATpkGJKSbteUa43EsRSyAz1Xvma5r48yQhhNZe',1,4,1,7,0.042320,'Breakroom Sage','none'),
(4118,'entry','VZh4sSbvht2FtFksZWBvx7LCScK3E96eat5xmZCfz496',3,2,3,0,0.030800,'Toner Dust','none'),
(4119,'entry','L8W43i7wU5t7r65FPMasTe2a5faS9NtjdAXRr2Fid7NM',4,1,0,0,0.063650,'Breakroom Sage','none'),
(4120,'entry','W24wDoByYVMwCpqBR1rUBWSwG1LrY9gQfsKcwQsoQiEZ',4,2,3,3,0.036000,'Cubicle Slate','none'),
(4121,'entry','8WoZaCUbUMTB5bB6cA17kutht7UshjV5q4gKtJQHVS15',0,4,7,3,0.049560,'Filing Grey','none'),
(4122,'entry','D97tEq6uXcmSh3bBCJLgCdy6xzHYTr1pQ53FmVZkcQUC',2,1,7,5,0.055680,'Drywall','none'),
(4123,'entry','hJrXuk4FEkNR4wyrQdJga1dFrwwxSpKKMmjhtjpyucWS',1,0,0,0,0.047360,'Filing Grey','none'),
(4124,'entry','CqhsjsgZeE3zhZ3rPA8GhtrBipXvBQi28LZHDYt3hfY3',5,7,6,6,0.118440,'Breakroom Sage','none'),
(4125,'entry','oFXT3CujvqAVqk55Qp38jWiPhPXbzVA9hW871W3xqdJs',7,5,6,3,0.051920,'Toner Dust','none'),
(4126,'entry','sFMtPdLm1rVhcTjGCzkjGjUjWjaBCfKoACsY69cjeeuF',4,5,6,0,0.045080,'Filing Grey','none'),
(4127,'entry','EXgcGCXynckPfELjz67aWDWxCYzg5cHS4BXnYPhbccAG',3,0,1,0,0.050250,'Filing Grey','none'),
(4128,'entry','2ysxaz2f1gjWteP5pyt3UdgRocve5DPmmeWHCfWKwqMU',0,7,1,0,0.065120,'Toner Dust','none'),
(4129,'entry','wzUhWDzs2mHXg6GVKWJ7a9DYoEjYXCoqJh8nwUPoTZr6',3,9,5,9,0.038280,'Filing Grey','none'),
(4130,'entry','B3yHfkRNLwa4qk6HBJs8Bp4rwrYCM1wtAaDXiYe3sWYn',0,1,3,0,0.063990,'Manila','none'),
(4131,'entry','8VkL2Ts3YrWpgdbAKw3vCa6cLoZyQEXphtY5nNLgYTFs',3,1,4,2,0.036400,'Manila','none'),
(4132,'entry','YHPTrSEqXeULpsVJXSPyDbr1mqMFBMusfa8feHCcnZL3',7,6,2,9,0.050460,'Toner Dust','none'),
(4133,'entry','zCDzNfWxGdk1T8kyJiFtn3uvUZZRwG6pQLDqnAPwD5Sg',5,4,0,2,0.046620,'Breakroom Sage','none'),
(4134,'entry','jdc4fw9cZe5YPRQqvjMHqcyzdgZCNRvBcfPdRk5B27iB',6,1,7,4,0.040800,'Manila','none'),
(4135,'entry','CrjmJPwidCHQ9TtipnWZtbDehGXp4KZQXuJRh4DTUz8J',1,9,0,4,0.041360,'Filing Grey','none'),
(4136,'entry','r3HFvi34q1sro61h1gtEU4UJTwWPnj8UMoxPayxYtbjh',6,6,6,4,0.053550,'Breakroom Sage','none'),
(4137,'entry','YomiFZ6rbosWzQAhUJ9rQgKCmvrq78vJ5tcyUq4QJL5h',2,9,6,5,0.039840,'Manila','none'),
(4138,'entry','EjqdAsJw2y6rmjR9y6iCN2FRuDRPjAF7U2UFmjYR6DC5',0,8,0,5,0.045240,'Filing Grey','none'),
(4139,'entry','sTNtv9iaVE2CZq1g6hjdP4AkM6uw1UifQLzEoNceYYLf',6,7,4,2,0.057960,'Filing Grey','none'),
(4140,'entry','L8V9w2MKtF7JuQ4wvjDWkYLvvQcjHHiuCdXwWiEZQJtP',7,6,3,4,0.045440,'Filing Grey','none'),
(4141,'entry','VdPLGnZPXLMSDoBQHMWzc6RuE6uSYU47xv6cHgo9Rh1z',6,6,4,3,0.048280,'Cubicle Slate','none'),
(4142,'entry','8iMZ4zz1gtscUKtZCHdw6Mcg8qh3BwopyCEuaXqPkpcX',6,1,7,0,0.053960,'Breakroom Sage','none'),
(4143,'entry','kY1B7VCG8TRp59anzN1SvXPvtAYr2R9KWcbieenoYvgY',1,1,3,7,0.056070,'Toner Dust','none'),
(4144,'entry','Hp7XqiLkJoaLDHo324MJ9LfZDXmDJSDBxxZrz1gnsCG3',7,5,7,4,0.051030,'Manila','none'),
(4145,'entry','n2V6g6yUEvrfnf8Mpf21De5NWBH8WaYaVC73GXDnHr2C',6,2,3,7,0.029900,'Drywall','none'),
(4146,'entry','HpqDdsM1cY4cb7v6HqKAkobcsYWKutQeA12wfPfJ923n',6,4,0,9,0.046080,'Breakroom Sage','none'),
(4147,'entry','LoBR6Y7GgT2TtyjagWTGJperNQfXYNkCzZokV1nxLPkU',7,4,0,9,0.028000,'Breakroom Sage','none'),
(4148,'entry','ZozjFa5KRf88XrV2shrY5oUGByQSV76DpEEEqbayZS7g',2,4,6,3,0.045430,'Breakroom Sage','none'),
(4149,'entry','DcCCGd8w8h54GLykfHeJQyuczhnogkLV2LKtBH5R2kv3',3,1,4,0,0.031200,'Toner Dust','none'),
(4150,'entry','SAkUETafWvV4Gu3zBjhnd1FH8S3uBp5eVZv9sdLiL1Yo',2,7,4,3,0.056950,'Toner Dust','none'),
(4151,'entry','sauh6AX6aPjoZWPdS6dpghYrbQorcJL2sHYjAspM5dmn',0,8,0,2,0.044100,'Manila','none'),
(4152,'entry','A1daKNCaxLY5k1dq4w8gF1zX7iBR7wyAaGjHMy2RXuzn',5,3,4,6,0.065860,'Cubicle Slate','none'),
(4153,'entry','hWaoAUCz83fG37qRoHPc1ZQwaSGxvLR37d4GxDFS5k52',1,1,1,6,0.122670,'Cubicle Slate','none'),
(4154,'entry','7p8PL3ERLXcahow84TurJYMxhMUmdTrL92jiZ5pCKbf8',6,0,3,3,0.034320,'Manila','none'),
(4155,'entry','88MEjeJrY66V4Br1UZA5HT6RxcSedMcpqZK3xrHjpsYo',2,9,4,2,0.056980,'Filing Grey','none'),
(4156,'entry','c39Wv3GhBVeQrCcH5fGqRAjRSKQSwag9uZwkrcqWWGaY',7,1,7,5,0.042210,'Cubicle Slate','none'),
(4157,'entry','iZ4RdQ4nVWnsokDapWRgpmxWASv7ZrsEMn7CvdxDxUbx',5,9,4,8,0.029440,'Ledger Green','none'),
(4158,'entry','BurZnwSMwB6pNtjh54Un96A8WzKPHWcjcDPGArct685t',0,8,1,7,0.031200,'Cubicle Slate','none'),
(4159,'entry','auKgyYmrCNvB4m4so3ippU7wttYDQMMh81hx1G3LzbBJ',4,0,0,6,0.044250,'Ledger Green','none'),
(4160,'entry','xGY6QdKtQGBP9eB1zMAyPx7SQ1HCPWun3LLp6eFswo6E',1,6,4,5,0.037760,'Filing Grey','none'),
(4161,'entry','qrqjCmKKRhjbSRSfBJjPpVqjd3ACGasf7zAGviHoZ5Vn',0,3,1,4,0.033440,'Filing Grey','none'),
(4162,'entry','F6UCgVwf5p91LpjyV8xhQf5D9XkY9DdJtiDvjkhkC5uk',2,2,0,8,0.046150,'Breakroom Sage','none'),
(4163,'entry','nSfeFWFFjcGaok5zHTH8jPzeC6ZpXEJrmk96TF5j7DJp',7,9,6,7,0.031680,'Cubicle Slate','none'),
(4164,'entry','rsSaC3hcAyLhdUV2iFRfg4s2NYrbZUCCWnEUgRM9UGKo',4,5,3,5,0.048600,'Cubicle Slate','none'),
(4165,'entry','V6Lfm6VLeZbSqAXf3VUAzoJPS2ask5qhF1E5NK3DunaH',2,6,0,9,0.061640,'Manila','none'),
(4166,'entry','cBZZAhNZggzJEPRoF6U7aCiNBacjPaaFzvkkXg7sZ95J',7,3,6,4,0.054810,'Cubicle Slate','none'),
(4167,'entry','sGKWwuNTSei4Bny3T38h8w2wYWtsUKQ6hWbnjPCs2XQf',7,9,3,0,0.028160,'Toner Dust','none'),
(4168,'entry','tGyUjegCnMegpkDisBR82ytY1mpG62dZFTyfu497X3UE',2,7,6,6,0.059200,'Breakroom Sage','none'),
(4169,'entry','3AAb6JVaj7BpYAaQTTYJwre2ySXA6gPSZpqpc3W9ZUpx',5,0,5,7,0.049560,'Manila','none'),
(4170,'entry','DR9ZZR5UTEpmQ4yL4xSxkQtxY5fBcJaQR7MgNvM1rQrX',3,6,0,2,0.072090,'Ledger Green','none'),
(4171,'entry','xR3DwT5WzhgD3QH3eKSoVB2ijfRKhMGpM3zqZ4nbf1wh',5,2,4,2,0.043560,'Toner Dust','none'),
(4172,'entry','JxVVAHz5bPstYpJLxJFbpnDFqEJLxF9Kwy5dha2FPer2',6,6,6,2,0.048360,'Toner Dust','none'),
(4173,'entry','guvQqktPxxG7iWsP6GXSnpyZHSdEXYwKWgsj2J1M89i5',6,7,6,6,0.042320,'Toner Dust','none'),
(4174,'entry','MLsnPpUfdrkrRnzeW5BrDFAfQmx1CthAAGAc2umKWVsf',3,4,5,4,0.087420,'Breakroom Sage','none'),
(4175,'entry','1YqjB97ET7z8urrLju9JSJc1FDi4BnTQRNe77z2LDRy3',2,8,5,9,0.045540,'Ledger Green','none'),
(4176,'entry','cU6iXX3dmW1D1uZazAN2i1EvKPmetsQB5uKSnmuoC1cf',5,2,3,7,0.045140,'Ledger Green','none'),
(4177,'entry','ghhFQii2n47ckP3NbLLS8A29fs1uZAnnpYiuymbBSrMg',4,2,3,7,0.049400,'Breakroom Sage','none'),
(4178,'entry','cMyLq676ckMDY9GVKpN65X5ZSTTt49W9fYMfMTDV5jip',7,4,1,6,0.054520,'Breakroom Sage','none'),
(4179,'entry','nrbxzqveLAwCyD2obh1fgEdaBq54JfabaU1zP1hLqEqz',5,5,3,9,0.056120,'Breakroom Sage','none'),
(4180,'entry','UJTYhjTUmzKd1R1RWLtoMiHuVGdf6syX4wQkDoA6qz6K',5,1,0,6,0.038280,'Drywall','none'),
(4181,'entry','VEfdt3Kx4Vf5eTbstsg6XHYr8StxxVkgzy9jwCg7aqxc',1,2,5,7,0.032640,'Filing Grey','none'),
(4182,'entry','jvJCLuvh3kNmavbYQP9DmnCXmjmDn7r6g3rpw45H1mko',1,4,7,4,0.045540,'Drywall','none'),
(4183,'entry','W58KtuWgfT9A95zRpLhQAJmQuSXRsajKEjBRuVTX9ySU',7,4,5,0,0.065610,'Filing Grey','none'),
(4184,'entry','kfUNBCneoCmUt7AHYq8kM4Mwy1X2urg2EGWAD7D5rSom',2,7,3,2,0.043070,'Ledger Green','none'),
(4185,'entry','MEDBopPpGyJes9GXuFJhwHfX5cngo26fjDMHgcRFjkmt',2,6,3,5,0.032640,'Cubicle Slate','none'),
(4186,'entry','MZsMwk6n3iWfsYqxmGpR1aZ7AfJ9AJbyfh6BadzyuuDk',7,6,1,2,0.061770,'Breakroom Sage','none'),
(4187,'entry','1rAXoAReWvZct5RVuFtPanP4XpTWDQBiv686obJ4gf27',6,9,4,8,0.034400,'Drywall','none'),
(4188,'entry','z7ib9S4LuEPjGnrHSP33AUs8YhkkX8azaBAAQSHg6txZ',1,7,7,0,0.041540,'Manila','none'),
(4189,'entry','dvxtmpRdseac3mg4eVY3hAWfFn4jx97JMHUFEwfzvj4W',7,3,3,5,0.026400,'Filing Grey','none'),
(4190,'entry','cbTgR4Wzky5qf2tWgbLBMqy3KpGRnyibLsJFa1xjHDoV',2,1,7,0,0.061640,'Drywall','none'),
(4191,'entry','U77GTKwinoxmRypk4s6RgeugT53W7n9UjitzggRNZcyq',7,8,2,5,0.035990,'Breakroom Sage','none'),
(4192,'entry','zzBRN8dR4RsD8ga5TArj8ukgKCdFkxDBv471BZf56Tt1',4,8,2,7,0.061060,'Ledger Green','none'),
(4193,'entry','TdAFYMi5Dz4owztqXkQxwpQhPCPTAftH32i6DQhRg3Yu',1,3,7,6,0.040560,'Manila','none'),
(4194,'entry','V6iJM3Y3vUbeewMv1VkqVj75pDMHb4iJXqN5AQNxDHGr',6,7,7,3,0.041280,'Breakroom Sage','none'),
(4195,'entry','Ce3obaHWL6QAD3WnmS31sxJN1MW4bNsdJ9eN2YaFW95p',6,8,3,8,0.031680,'Ledger Green','none'),
(4196,'entry','ur89g1HmWpqke4dxvfpf5yLFLWXGQg3foe85XwCEPW1e',0,0,0,6,0.046000,'Filing Grey','none'),
(4197,'entry','yHjv4zETLj6czR7MnC2WSj8zFtBe1hrWJyvohfmb2Vbe',0,1,2,2,0.042680,'Filing Grey','none'),
(4198,'entry','CqBeC9etWmPHoy7iyRtpV6JyoGSLc1FekVRLkS21J35j',6,2,7,6,0.046560,'Breakroom Sage','none'),
(4199,'entry','jDzoSziEZn354vxKpME8fpc8pXLVpEEbxAqiwSN8kRZP',1,5,2,3,0.030820,'Ledger Green','none'),
(4200,'entry','SxcpNAtNCQeSAH7EuYGv6RWdsbr3TNyvMudJ7ArbfBon',3,8,3,3,0.026240,'Toner Dust','none'),
(4201,'entry','t5X88DeT9vLQQa1tC7qAt7QiRf8euNpY2XA5YmGKd1KM',2,4,1,9,0.051590,'Breakroom Sage','none'),
(4202,'entry','jrKVEyRd4ECxDeTsfziLtQC2MNKZY61gDPq8SiMARF8E',4,6,4,4,0.054810,'Drywall','none'),
(4203,'entry','8TFVLnFKA6myt7MCWYZpCDuULuqHe7Tp59TuSRxMUXDv',7,3,4,6,0.040480,'Drywall','none'),
(4204,'entry','7AUcCUU4umnDKmXwyMSawWKST2NYqyvdAd9D32vj9rfV',0,2,4,7,0.043240,'Breakroom Sage','none'),
(4205,'entry','CaeesRVGArf1aVk1ZuXaKQykvXypwzavhbukJhe3kwhy',4,3,0,5,0.038640,'Manila','none'),
(4206,'entry','FnjJdEu8ax9ZGtdzjWHbvPaEubMjV84B9jjKtRYxmNMr',6,5,1,8,0.082800,'Breakroom Sage','none'),
(4207,'entry','1EVLcFvbecYcwsnM2REaSmvYwwEAtrvapjqJwELiCbQz',6,2,4,5,0.020480,'Breakroom Sage','none'),
(4208,'entry','yt6M2fsZy2u8m9ewKHdR2fjr9zA4z2jFc7bGnUFTEMTN',0,3,4,4,0.062370,'Filing Grey','none'),
(4209,'entry','dUKTaSPDRdTamcRJ7qmDN6eAcSbjFMWPxnEchynqxhht',2,3,3,2,0.101520,'Cubicle Slate','none'),
(4210,'entry','H1EuErUKvsuiRDD6Hmwx873WXwRAbp6MpojBpYMQ4JeQ',3,5,7,6,0.053280,'Manila','none'),
(4211,'entry','tcmFtyDgjJnpRwXQhribFmTSd9eg9rsByWADhsDsqKag',4,8,7,5,0.033580,'Breakroom Sage','none'),
(4212,'entry','hiXfmuZSiNKduiFfHNShRwpw67TMHjMWiy6Q816Xaq4f',0,4,4,8,0.027720,'Ledger Green','none'),
(4213,'entry','gDwjhMWHN7eY5esywu37jHAogr4E6YnUQXjMzyxZqKF5',5,0,0,5,0.063180,'Ledger Green','none'),
(4214,'entry','xCJCHCtnD787GEdczwaeeRGP3LLeScBWsrMscFko9oxx',4,9,6,5,0.051920,'Ledger Green','none'),
(4215,'entry','eLUoaBhSpMu843HxkRuWW8RcdfhzmX4pzeMd41P7BKyR',1,3,6,8,0.049700,'Cubicle Slate','none'),
(4216,'entry','duEVf7JyBGw8CEmscY3XeWBjTnJnQJcPpRaWkJGSkXZb',1,9,3,5,0.046080,'Breakroom Sage','none'),
(4217,'entry','4bhcb9Jxy5AhVVAjwE8HZYtVcwLJ23aGfyPUFpk2vCTe',5,4,7,4,0.048360,'Manila','none'),
(4218,'entry','ew92ErfNeZFAYnp8YHyC7ET5611FraU2BtKEpj6LagDT',3,1,3,6,0.048280,'Cubicle Slate','none'),
(4219,'entry','8nzQW1LBAuXcmReufvAZSGQYgzSAJr41hmRaJb3nUxSN',7,2,4,9,0.053600,'Breakroom Sage','none'),
(4220,'entry','nLckcSkFNuqWzExrDfV2ZcmvUja8HR16fwTuYV76277B',2,0,0,8,0.052290,'Toner Dust','none'),
(4221,'entry','QxEXzjBtSttsGU6hFjLgdWbxySczFD55tyGxYZfug1PN',4,4,4,5,0.039160,'Breakroom Sage','none'),
(4222,'entry','tX2fcZxaBr2ZucjcuT4ikzGwoji3YbETgPE6TtQEJveg',1,0,0,0,0.047570,'Drywall','none'),
(4223,'entry','WQ6pHM52b9MGXVSs3CSWNHsEuMCjxaEmza16vStQiXrb',1,3,7,3,0.028800,'Drywall','none'),
(4224,'entry','uMzL6rTXw4sz8cWrdyLi4YxEorurMUKN1FvEkJrw5CsA',5,2,2,5,0.048840,'Manila','none'),
(4225,'entry','8LKPNTxYHEkHenBA22bLWRQZqkYfb1sy1z2jF3coe4wc',4,5,2,4,0.068080,'Filing Grey','none'),
(4226,'entry','RUkoHrVWvPLmzNjFXzYKKt9Cafe33WdpVkoDBGUrAWUN',4,8,5,2,0.030360,'Breakroom Sage','none'),
(4227,'entry','4B4X2bFNHmkUdAHgjz9TbhtW6F5ZQq4UfUuoSZszz2Ff',3,3,7,0,0.042880,'Breakroom Sage','none'),
(4228,'entry','L74uXgpKi6oyh28oAsjwB1JEuCYPX5CMaBPQafrpFho5',3,8,6,4,0.029920,'Drywall','none'),
(4229,'entry','FGvCn55K5DoAdmC13KCYjzcp63KcQvhjc8bLNdux5EMH',7,4,4,0,0.032160,'Filing Grey','none'),
(4230,'entry','6ghmtQk8yvCYTyoGNiQDWKVrBHKZqD8EGh5ghezZLoia',3,9,6,9,0.056070,'Cubicle Slate','none'),
(4231,'entry','DVvHERARwYG1keo74vFJx7PwT2gLUtWgbzGCAGMx3fAY',6,5,3,2,0.110880,'Drywall','none'),
(4232,'entry','XPrcAyPW8SE5RDi77znNVs7YrVowzRo2HYRxTXdE3LBU',3,0,7,8,0.044640,'Toner Dust','none'),
(4233,'entry','8akQPh93B9KC4aRB6MVhnuBF8NEQJQxzg3Ukx6j262r2',7,6,4,8,0.039530,'Drywall','none'),
(4234,'entry','VdyVSKKPpGXjmcMuiSRPxYgDgM5vRPcs3ArzDhkyQqCY',2,4,7,9,0.046610,'Ledger Green','none'),
(4235,'entry','Pe7qyoZZXob12T6GcLPCPWFEuhGu2BijVtUd8rR79A9M',0,0,7,7,0.041600,'Cubicle Slate','none'),
(4236,'entry','4FJFVGQEXvP2MPSCRtKX9oDo3265WW1ovYFLkBtwwbd4',1,4,3,9,0.032560,'Filing Grey','none'),
(4237,'entry','Gp3YwqV7WnbHJoZDQckR2FrrnPCzwkq5HkYHjxSAWf2w',1,2,7,9,0.042320,'Drywall','none'),
(4238,'entry','e52DW2CH1Acs3RotX8Eq9A1uYJrroEa7KTnwQF4bJiwp',5,3,1,2,0.036960,'Filing Grey','none'),
(4239,'entry','C417p9EtBmd1PiXUpSCXPCJfy48h8z7drWGHMN5mhPHF',0,5,3,5,0.074000,'Ledger Green','none'),
(4240,'entry','tLXmzPPzhcNr7EtFK1hFA4H8rBayEJP5bqjfkdACr6Qx',5,8,1,2,0.049580,'Breakroom Sage','none'),
(4241,'entry','hUuVaqmw5pQLtf7pG4P75fWKizEhpLjYcm1nED2NHiXt',5,8,4,6,0.043160,'Toner Dust','none'),
(4242,'entry','rAgxqs4K6T4z59hu9e8oAj7CzLy8hLoyquCVuuPwQ7AL',1,8,7,5,0.036340,'Manila','none'),
(4243,'entry','rgYJAjEt7ZtN6qzs9b9ZhQonrvXwsFh3NGs1LQN7w6Yi',7,6,1,8,0.036000,'Breakroom Sage','none'),
(4244,'entry','AQeJKBxt1TYkuTtYV45nT86SG37Qjht64V2vK2y9qQWh',4,5,7,9,0.042240,'Drywall','none'),
(4245,'entry','45QnR73w8m8vxqRjPMLtZP5DW4VAzvNqo3DzBSQp5rX3',1,2,4,8,0.043680,'Cubicle Slate','none'),
(4246,'entry','pziR7rqSYHqNEn2rAr7VgfYbNMsyi15akyQipL1EbCRt',2,5,2,0,0.053360,'Breakroom Sage','none'),
(4247,'entry','wTCTtp81VBCqbtc71w4pTQEknmAME4a8hM3iGd881isD',6,9,4,3,0.047570,'Drywall','none'),
(4248,'entry','vMd4xNnsYgvX6LBDyRygjcUvgLZbXpCMxm4hakgW1rGt',6,0,0,9,0.027200,'Drywall','none'),
(4249,'entry','UaDj8KVMJukYjdUsX7efMkpGBmDUzM8hViXBQHyoVnNU',4,8,0,0,0.027720,'Drywall','none'),
(4250,'entry','wvEw9cM12FGVGeiqpa4rhDWbCsTGxWGge6iSjVAPPkNo',1,1,5,0,0.027200,'Breakroom Sage','none'),
(4251,'entry','uD3XJRWY2d9adUN6hQaaae7iojbKhpEJHcxdmGCcKj2t',0,3,7,3,0.038480,'Ledger Green','none'),
(4252,'entry','6a1mZEeZiQXoVGqMtJF8vPp4pcsYi1KFvhS8QHCHw3Ya',6,6,5,0,0.063990,'Ledger Green','none'),
(4253,'entry','bKmypvFcuEYhNwNKpNVy34URCS1heEzfT9DL2dKNtiLw',0,7,4,8,0.053690,'Drywall','none'),
(4254,'entry','f37DJC2jrKZNsszoJCkmCCAZwLuRFFEbBVtvLHUynrer',5,5,7,7,0.076950,'Toner Dust','none'),
(4255,'entry','Gkw3RL85CpFfWSqkPnVC1MUHuRiSLF5qLkT53xP5oeeE',4,5,7,7,0.055460,'Drywall','none'),
(4256,'entry','StLePz9rLj1WrNQArznu4KTFcMfERGqkcN4RCiWB4ZYR',5,4,4,9,0.033600,'Drywall','none'),
(4257,'entry','e5h8b5hFz82QTxAw15Mfw2H8ornfxFfcBi5xSf4TgW5e',7,0,6,0,0.028980,'Ledger Green','none'),
(4258,'entry','FmMzZrQWwhWwJu3VWgoxqxpaHjcQEVMp7K6RovMNHqXn',7,1,1,6,0.082800,'Filing Grey','none'),
(4259,'entry','kUPfZi8w6GLYxXQkpDtqbAaiydKp4HDCx8p8M1VZys8x',2,9,3,7,0.034960,'Cubicle Slate','none'),
(4260,'entry','ds4KaGdb8FexwzRgtFmTTbsnYXJM23k9xo1JaqjRh9u8',4,9,1,7,0.037960,'Manila','none'),
(4261,'entry','6h6eGxW7DrBELbuBnxRAZZEn9XF9fDpTBrxyPQsWytKX',2,9,5,9,0.040480,'Toner Dust','none'),
(4262,'entry','bYEbqqq2GHJCbRomH5BJoaRvVefG76XUAbw5aUyHLQTa',2,2,7,6,0.030720,'Breakroom Sage','none'),
(4263,'entry','sydJnv71uYy9qu7hEMqot2bBRZ9xuJHvnFJfc4ziBK8h',1,6,7,3,0.035200,'Manila','none'),
(4264,'entry','3S8DWGTtofcpMXpXFkj246xn6zoKL9dJEw13MB31XPtV',0,5,5,5,0.076950,'Toner Dust','none'),
(4265,'entry','ZPtG8ewN8evsab9M45gexN8MECnJ2kMbGn2Be7wqeWyD',5,3,4,4,0.042480,'Drywall','none'),
(4266,'entry','gzP5oqJNrturxApbphQvgH5ZYcwM2AiWmN2zSvJN6NZr',6,0,2,9,0.024000,'Drywall','none'),
(4267,'entry','sn8nj2Mh5x8RU3qgiLDGAMtJBVrRiFnSAynSaXeJwL91',2,5,0,0,0.054670,'Cubicle Slate','none'),
(4268,'entry','q7xrtz6r2PTt75jyQWdBAqYuyGxXQQ2AZK3sJnKWg77b',7,7,4,0,0.037600,'Breakroom Sage','none'),
(4269,'entry','URmiRUuR2XnPRA8BC9wDEHokDqLSzjXDL5aScbxrJGgJ',7,5,2,4,0.043550,'Drywall','none'),
(4270,'entry','1VcBM3eL39WKHj2TUPgyVWy8aBsikRXsJTqpyuxmdgth',4,7,5,6,0.053600,'Filing Grey','none'),
(4271,'entry','f6q2mkTF9CBWcTiTDwcStVYgcGMtNhG8cQiMVeRDPzhn',1,6,6,5,0.050740,'Drywall','none'),
(4272,'entry','qZ4MoXHvcCbWCkepSRuTjeQTSwJrSjJm3hs4xs1kAxiv',6,5,2,8,0.080960,'Breakroom Sage','none'),
(4273,'entry','bYxXtB8NoZmsQBPyge4AXEjuis7MwFApiLEZqy71Nz4z',4,4,0,0,0.056700,'Filing Grey','none'),
(4274,'entry','KjfUiGcghM4zSxMHYerGbQd7s5mgw6F3Vjfk6oJ85aeZ',0,6,0,2,0.048720,'Filing Grey','none'),
(4275,'entry','rD3MRZ4e5Rnxw75Z9mGaYqjrv9GAAhoggyh47KXvqBkf',7,2,2,6,0.042780,'Drywall','none'),
(4276,'entry','C1HSKBTHW9uvmCDEGdwn8wbRzDqDBEQZtzrCi27Wk1Kq',7,3,6,0,0.028060,'Breakroom Sage','none'),
(4277,'entry','46gfZWupZHzf4ZbYxvYdRTrwawtvMw2zHY7jYPu5yscJ',6,2,2,0,0.032800,'Manila','none'),
(4278,'entry','rQjFCDDugvgPAodW6qung2JA3vFkiDETE1r6n8Sah8d5',7,4,2,6,0.071000,'Toner Dust','none'),
(4279,'entry','eTek8x58hbG9ZRzPh3mBGRNPZVSdXzkpBTRWXKE1zXF1',1,1,6,7,0.045120,'Ledger Green','none'),
(4280,'entry','Gpc5Fp3YhGLZ8VnQqaeuDSZzwnaUcEJ1kjR8XYA4FwKf',7,7,1,0,0.068080,'Breakroom Sage','none'),
(4281,'entry','UrHVwTDHpxdhffYSWW2NfwGHGdLoeB78W5W6YDAeYjPU',7,8,7,4,0.040020,'Drywall','none'),
(4282,'entry','7tj3xVXZsJ5UqvE52gAhNXxW4yJxfPPtGMbXDbzbHmmq',0,7,7,9,0.056090,'Cubicle Slate','none'),
(4283,'entry','NKsiCpCw3ihjw5kL6o6TCyMXfeWJeUAkV9aTKK1ESKrr',2,3,4,4,0.097290,'Manila','none'),
(4284,'entry','2TRNptjNwZBwTUgK9jCETas3YnAzz4BBwVg3zJwg79Tq',1,2,7,0,0.052260,'Manila','none'),
(4285,'entry','oiCoTZHAkTkhZWK156fQJ7BapD7EoGcxPNyweuguaFyZ',7,6,1,3,0.056240,'Breakroom Sage','none'),
(4286,'entry','7uoqi6KrZbLTtBgFSQ1WUcaozCWmJgaZT5CNhzXfeX61',6,1,6,0,0.047570,'Drywall','none'),
(4287,'entry','Uw6UBpgfjKyca6A1qoz4uM6k5U7GJkWmA1jz3BedfpMu',5,7,4,6,0.049700,'Filing Grey','none'),
(4288,'entry','GS7f3vqNWBaTaoT7U85FWgYjRDQapMt7np84yJmu4HyW',6,9,2,0,0.028600,'Drywall','none'),
(4289,'entry','uZbabiMK5SeusE31Sntnwa3uJGvU5TtFB7HZ4zmMbkFC',1,6,7,5,0.029440,'Cubicle Slate','none'),
(4290,'entry','t7KPQiE5eWrkSzHhoiDExWg5EwEHXWCnTktEwQhpx1Vb',6,2,3,7,0.043470,'Breakroom Sage','none'),
(4291,'entry','bGdccWKfJb2tupL5KXJHt6b2oFuQUzr4E8Uc3dePsUay',0,4,5,0,0.046900,'Breakroom Sage','none'),
(4292,'entry','kuKmGRBADDb9sBw92RyBqLG2Uh3meQidpMgY3JKruSKu',0,8,3,4,0.030000,'Filing Grey','none'),
(4293,'entry','mw8W2epWVbfFhGzdtDHJ5NKp81vP7VHQHawBRGi6v2Fd',1,2,7,0,0.030080,'Toner Dust','none'),
(4294,'entry','uKzFSmxJ3Jx2TsaBTB9PXtYr3QYLoz88AwsvMUBQrfk2',3,9,0,6,0.102060,'Drywall','none'),
(4295,'entry','WaRVjkLZ9q9v3B1L9PWuk7sk1Jd7T8DUNK2zmCRYXCPF',5,4,7,7,0.036520,'Toner Dust','none'),
(4296,'entry','BRYM1Ta18tcz8RdjjRLihTK15L11GZRiuMioFAywZWDY',1,6,3,0,0.032000,'Ledger Green','none'),
(4297,'entry','mzzhreSuwJ6Z3542V14k6k7qGdvEHRpuqBJx4wS5Jo56',2,4,7,7,0.036960,'Breakroom Sage','none'),
(4298,'entry','jki5HmwMpQehvW47UfFhatd3BLnoGUp85ES4KqthbZcm',6,0,6,9,0.024000,'Filing Grey','none'),
(4299,'entry','jQQo3LKF7uwedBqm5RXxyHzwq355XyPtVHRGNMRUcDdM',1,4,5,6,0.044720,'Breakroom Sage','none'),
(4300,'entry','tpbFzJjzLb8v7FhXiT27yuDjocxRDs9bEbTtdoZjURP9',5,7,4,4,0.044080,'Breakroom Sage','none'),
(4301,'entry','HXAYSxywzccVxxkR7FhdMnLHhbPLNzDiFP5ai3ERupWW',6,7,4,2,0.069000,'Toner Dust','none'),
(4302,'entry','nqVkpi8dA3UahnhYcM9WKq77M6CRZHLGy4rmwmYBK5rC',6,9,7,0,0.044640,'Cubicle Slate','none'),
(4303,'entry','U6QBe1KBBscsnqwDFd1cJqcBj86XwbBpu1ybP22GtdhM',6,9,6,4,0.034500,'Breakroom Sage','none'),
(4304,'entry','Uo3i6fR5MyEPKSTJfUjybMpfXmEVfH6oFFPBts4iUbWP',7,0,3,3,0.040560,'Breakroom Sage','none'),
(4305,'entry','at142pCJYzNozPXs29y1QnNwYKaGXKJUSQZQKPpjGWYY',2,9,7,3,0.097020,'Breakroom Sage','none'),
(4306,'entry','ETj4sjDmv1KjG7sp2AK3f7mp67Wyi6aAdpTVp3bDexb4',6,8,0,6,0.039160,'Filing Grey','none'),
(4307,'entry','9pSfuzBSXbH3bxSBya6CaWvatAg8wXb3YHfVgiPVowUy',2,5,1,2,0.054520,'Breakroom Sage','none'),
(4308,'entry','Um3tPkbnAPkHXmeistm1ZoeBGMTkgXJHfsm22dYpt7Fv',7,2,0,4,0.035960,'Breakroom Sage','none'),
(4309,'entry','zmCftME8sovZ8VGyZbwX6BN6mXtY7ovLJytJo2XSSPs6',2,1,5,8,0.056070,'Drywall','none'),
(4310,'entry','fR8gYXwqY3Xb5UQwDiZ3CfDVg4Ayc26aE1HbiLeyD2yo',5,2,3,3,0.036800,'Cubicle Slate','none'),
(4311,'entry','8V6bS8K9faHznUBRLzkyJWDesybdE31CDnCMUQEFeirp',5,5,4,4,0.028160,'Toner Dust','none'),
(4312,'entry','jqopnSzxrQYqPGP9GF9zQ8GL6Kxwx3czGHXbGpuJ74WW',3,5,5,0,0.088320,'Breakroom Sage','none'),
(4313,'entry','7dxj2kyRgFSao2k3CRhfzzdnQbq8RWRvTM6EGi6nJDdS',0,8,0,5,0.030360,'Filing Grey','none'),
(4314,'entry','NarQp2aGuGC4DEHVncZHS2hpU7guuXGYh2ufUmDz48M1',1,7,5,3,0.032400,'Breakroom Sage','none'),
(4315,'entry','nZQa91JYzC8WXFqbegcKt5D2CBL4u65ED2K66s8vrWCK',4,9,6,0,0.046080,'Manila','none'),
(4316,'entry','tTEdxYSCuH1ECU9Ekh8YLkcj7kRxQKhjh1ju31QXswgj',3,7,7,7,0.030720,'Breakroom Sage','none'),
(4317,'entry','jDc9u3nbWE3vYPbvdos58ocj8LU4sRmHJkSKGcTmZ5BM',7,7,7,3,0.032000,'Filing Grey','none'),
(4318,'entry','DphJHDU9hqKpVky5u6Dd6T42Spe3GLK9FQfdpgYEomSY',3,6,0,8,0.091080,'Drywall','none'),
(4319,'entry','sviKWTAoY3noVhMbeUARw3s61yY48fLP1gsFzcCi52rB',6,0,7,0,0.039160,'Cubicle Slate','none'),
(4320,'entry','kkDgAyiV9NQv1t2k3XuWh1s2mdxVo4CdSeuxBtvyAQdz',5,2,4,4,0.071780,'Toner Dust','none'),
(4321,'entry','S13UmzAqMYqHipaLD9D1BmFoz5teWJkWMnEzZcWDV5e7',3,0,3,9,0.072900,'Breakroom Sage','none'),
(4322,'entry','X7CzsBTF1gXFBei9jhxEJB3Q9dm2qxMspQFiBTibXz3c',5,2,0,2,0.034320,'Cubicle Slate','none'),
(4323,'entry','pYqr9T1gGEXmrrF3f2H8y72Xt59ZXgTTgwXiWPuuSkJH',4,9,7,7,0.053360,'Drywall','none'),
(4324,'entry','eFoHH7omPYE8rmH63BeYFgvf4diMcNFAubRhNNDJBXr4',5,4,6,0,0.037760,'Toner Dust','none'),
(4325,'entry','i1sPPDXqaZdS7fv86AEmVciCotF6WYke3amdCnsRJ4g1',3,5,2,4,0.053550,'Drywall','none'),
(4326,'entry','qeUB5XGBkmhwxB9rPWfZPqVuMh6goe7hqtZ4jfNPCZFm',6,9,6,7,0.035990,'Cubicle Slate','none'),
(4327,'entry','M9tsHq6s9wt3RzXxYzQPDsP2B3KGyPy9DCbUC5EAmraQ',3,8,3,8,0.036400,'Drywall','none'),
(4328,'entry','dUpdmq6Zb7zApsk7YimCuCF85otBrB6Q2NNB2JAdabLT',6,7,6,3,0.040320,'Breakroom Sage','none'),
(4329,'entry','WmiveE8dToB9ApcB9cUJnA1oigHpBLeKd9RkJPjai5XE',5,4,1,0,0.048360,'Drywall','none'),
(4330,'entry','ZXdFYG9zf6xTSgryjQUC5mujDAt4u9jBEodMxqWdXZnL',7,3,1,0,0.037600,'Filing Grey','none'),
(4331,'entry','cLyis4SxbkEDPwaDQm8ocsqqZD6MpftamZz3qe7Gu7yR',0,6,1,0,0.024800,'Toner Dust','none'),
(4332,'entry','gMz8C3M9HAPAD1U8fUbiYSc4NzSWfrMY8FiqdWiYEwrz',5,0,2,5,0.029280,'Toner Dust','none'),
(4333,'entry','nkGaGPyJfpRes1VoSZZWCuLYyGcEhLzrfVwvFRBT81NK',7,2,4,9,0.031680,'Manila','none'),
(4334,'entry','Xa4HoxKDxN6X76HCLSn1ocVzUu5buXLUfdHJiKimH6uc',7,7,1,0,0.119850,'Ledger Green','none'),
(4335,'entry','VwXGZu5fWBHmhERUpVxF5ksq7Pv22EzVqRTgYBBW8PVF',2,0,1,8,0.036000,'Manila','none'),
(4336,'entry','HmUiLWR41PPsZjDBUn5D9yQ1LQUyA6dGSsk6QTJNiAid',2,0,0,5,0.033600,'Toner Dust','none'),
(4337,'entry','bq3fVmkseE7WCar3y5UiuXFxQNGcqVHAjpU5ejkYgkT8',5,2,1,9,0.043470,'Cubicle Slate','none'),
(4338,'entry','j8uR4BAA1eN2hCJoMjSjaxQJJa6VMpxSKZNjNCuhKuW2',1,9,7,7,0.044640,'Filing Grey','none'),
(4339,'entry','CrQyZFzv8w44Yau24XysEMPDdWfrLwQXCedtxYtjrFoV',0,9,5,7,0.045990,'Manila','none'),
(4340,'entry','BGNBiey7HnwTEwWzk9Gw3gt488EJkvRnYnzz1DTwZzuQ',1,9,4,0,0.045360,'Ledger Green','none'),
(4341,'entry','wiRZbgWMh5U32J4rsg4umSMNxV48dbEEdt8GHoq1gtcu',2,5,7,2,0.032640,'Filing Grey','none'),
(4342,'entry','pcPMS5MWobzNWg7mcRW7t1EdrMqKmAcDpcfrxKYyivWt',3,3,3,2,0.118440,'Drywall','none'),
(4343,'entry','C7Uy6EVWMhsyV4Ma15rMdRthxMyRX96q2XwyqBz95Luq',3,0,3,0,0.061110,'Breakroom Sage','none'),
(4344,'entry','a6fDn64E7eQVqioNc2ouhHkQqUsrZNZCyMZ9Sf6BoH6J',4,5,4,4,0.033000,'Ledger Green','none'),
(4345,'entry','aGiKrKbhBiEZdW8Yf5XFj6hpe1V7xTAiSrBH9QrrMvL5',0,7,4,0,0.042880,'Drywall','none'),
(4346,'entry','tyhu53BCMsz8zK4CazE8pGqsaZMcFHTqfaAAvQD8unz2',1,6,6,5,0.034500,'Manila','none'),
(4347,'entry','KNV6i8rf3Pgj4FcRPoQZ1XrtqX2Msg8x8yJSJGXipwcB',4,0,5,3,0.036000,'Cubicle Slate','none'),
(4348,'entry','NWvjnbbnSnQKu9tZEBHBJCYfCKx5xzg8151sgUTzMkMw',0,5,2,2,0.039560,'Drywall','none'),
(4349,'entry','jNaSQtUbT9T1gipJJceszKTbhWRXa29wKCaaUSz23mWg',6,2,6,6,0.028800,'Filing Grey','none'),
(4350,'entry','MNuGLBqUYgQQ7Fm2Zm63HYZDsbXHVtcZmusKsjF718QW',2,5,7,5,0.024000,'Cubicle Slate','none'),
(4351,'entry','9WB46efNM4oCmZrLLB4Tg2ESXfjPKu7YAbK1QziZGpmR',0,0,5,6,0.022400,'Toner Dust','none'),
(4352,'entry','gMPMXBcFDnuL5VdTLxCM4zdMUeGbB6ybtMCa32R7k9SQ',1,2,2,8,0.028600,'Drywall','none'),
(4353,'entry','fCs94KgFDMxxwNW2ypytHsJPtekekfJ9zUBEH7k1sd5z',7,3,5,3,0.045990,'Cubicle Slate','none'),
(4354,'entry','19uGSLpYfQ6ixYGA3XoPusmcSX98Vkif4hpnBydDVMe1',6,3,5,4,0.028160,'Filing Grey','none'),
(4355,'entry','yjXmXqhnWJyXwxMMsWdHvorXAjWyFb1xPj6KrTJDFXxv',6,5,1,0,0.038400,'Filing Grey','none'),
(4356,'entry','gnmg9VKpgJx1oyH5K4irX9MiRntdqBsn22g3Zriy3CUW',6,1,2,6,0.048970,'Breakroom Sage','none'),
(4357,'entry','cxCgt3Z8tCtuHi85dtoXNnx2cVtG1RWvfjmiJCZWfgXv',6,3,5,0,0.046620,'Ledger Green','none'),
(4358,'entry','mzaeB9pSR6vHAuUahJKKdfQYqvShWLWKA6J8Sqop1D5z',4,5,7,2,0.037840,'Ledger Green','none'),
(4359,'entry','KHQzWVX8dakivBS9LfXCKjHHtk8rJmCduNHhKeoLndBx',5,7,2,8,0.031240,'Manila','none'),
(4360,'entry','sBgAW8X1kHqCX4M6LV5ac1JPmgiyfxDvdwu59G3TP6aj',4,6,1,3,0.027840,'Filing Grey','none'),
(4361,'entry','HJtJ2u6T2F9crvAd4JDuwscTuJRug5ZSa8egTLUGqqG1',4,8,7,2,0.035420,'Filing Grey','none'),
(4362,'entry','uACz4wc55v7Cw5yW47a7KmEYfY6MyKcEf755dNAHm7Lj',7,5,6,7,0.019520,'Cubicle Slate','none'),
(4363,'entry','wdtPBqZr6z9XMM9T6ZVdoqJbXmRNjRByKH5LFodDmCb1',2,4,5,2,0.042840,'Filing Grey','none'),
(4364,'entry','uZDSz7Ca7Ttgz46i6fyHJxarUx8wYKKnzuCr7bHtS6jw',1,1,0,2,0.042340,'Toner Dust','none'),
(4365,'entry','RfLVkY8hHA7Mqafrp6vJMNfF1JdP7tWFLcjsf71w3raS',6,5,6,0,0.019200,'Manila','none'),
(4366,'entry','t4gmin8iency275bqy4gKNSrcGpxkmwUahwPpkza8Bsn',6,9,6,8,0.031680,'Cubicle Slate','none'),
(4367,'entry','NcjDxFP5cBMs34dmBqi6soQCp9BWKTfNY7UcLjS2q812',3,3,3,6,0.040950,'Cubicle Slate','none'),
(4368,'entry','egFdZV37DqvAcG8AdtjUFnywKTFYgTx7sKsiRCu2e599',0,6,1,3,0.033580,'Ledger Green','none'),
(4369,'entry','6Dd762UpfuST4xYkzk3t35kSGq6YGBGDyiHk8z5Aydkb',2,5,3,0,0.051620,'Ledger Green','none'),
(4370,'entry','7NZLN4GyDNp7WZ29uNPHkNyYRezQLE6ZJvj6LPqswYvh',1,4,4,6,0.040560,'Cubicle Slate','none'),
(4371,'entry','HmvezPstoduZmdkq4mo5sGhNHiyb7xJUfyCRsXGJAHjF',1,6,4,0,0.051040,'Breakroom Sage','none'),
(4372,'entry','du8w4DKMpYCknHQR7m7xStif9bnPARy72kjugdxWDwW8',6,0,3,7,0.036800,'Cubicle Slate','none'),
(4373,'entry','5jCN78BZ7Ee97NqgCRZU5GGVy5CnATjK22iCTtnJAcYj',6,1,3,0,0.046610,'Manila','none'),
(4374,'entry','aiUUhkRKFWYAE8XnKW36TdXqUgbP5WiKzLMAdwvWNKXh',7,0,7,8,0.052650,'Cubicle Slate','none'),
(4375,'entry','tpbwQsSM9W3VikfZCAioAzXnPeZwiGgeGxpc5zeftM2K',5,5,2,7,0.028480,'Ledger Green','none'),
(4376,'entry','JM7ho6YPA5yj4dVyjgxBRQtwVL9myfKC9ChH5j2fayoT',2,5,3,7,0.037170,'Filing Grey','none'),
(4377,'entry','WS7eC7YfhYnyziPxKkBKNqy1gm4swRqrJ1qyHBqhNaGV',7,7,0,6,0.040800,'Ledger Green','none'),
(4378,'entry','ebQVcXZ4N4uDUtqN3JDCq1DHAhPpuLVLUbbuZmz2bbBV',4,3,4,5,0.040940,'Toner Dust','none'),
(4379,'entry','8n1ic9Sk5p7Vf1naMErfGhnHbjiyeHmp6j9QPN6C9AD3',1,9,3,4,0.030240,'Cubicle Slate','none'),
(4380,'entry','F24RzznJBjjGhE77UA5Bn8AkLAPzaXJE5capXNgL1D8B',1,0,7,4,0.113400,'Cubicle Slate','none'),
(4381,'entry','Xu3tsU9VMsL1PV5h2XVFaJ7aFex1aU8DQzNodG4uysvT',7,9,3,3,0.039160,'Drywall','none'),
(4382,'entry','mFNkvH2vZuvQdiWZ7Q1g9ron1nHvegtoHkZFxyQHUtGs',2,4,0,6,0.064320,'Filing Grey','none'),
(4383,'entry','X1hDV8iDJt5htVej86j5pgMfwfPGzgteKJqEVhWMfe5K',4,0,7,5,0.061770,'Filing Grey','none'),
(4384,'entry','w4NB8WoVy4PURyRDgZLvvHdVzmSDWMJAoCyVyv1cfeWi',2,1,6,0,0.045080,'Toner Dust','none'),
(4385,'entry','bJfPyNj2wytd7bY9s3G75bAAsc4192GQSJVGqNrGVHko',2,0,4,5,0.042210,'Cubicle Slate','none'),
(4386,'entry','AuwH9FJTZbcLFjfc5oMC3Qas6fyL26G7qx8X5ZMYU21a',4,6,5,5,0.048100,'Breakroom Sage','none'),
(4387,'entry','3KD9BwpkDMjkXbNSzmzu9GqzBhsZxCajDGCGcjDb6tRd',7,6,6,7,0.050150,'Filing Grey','none'),
(4388,'entry','m5PDfeHBNMcHJuNWZEgZtfJn1yBppUosKFFiXShQZuuH',1,2,3,2,0.031680,'Manila','none'),
(4389,'entry','5y5XSTq37UYasUb32Hty5HfiyaoXu1FAEyuHC6qj4CPM',6,2,2,7,0.076950,'Manila','none'),
(4390,'entry','7dyZiWU1EznBDXa1egA9zhpzN9Y6N4tArzRJNyUrREfQ',3,6,3,5,0.057040,'Filing Grey','none'),
(4391,'entry','mKkLawVkg9NrffgFSt71GKDYYeeipbJJG1h5jLM4VwJD',5,7,6,5,0.045540,'Ledger Green','none'),
(4392,'entry','kTFD9HAiMAqFSdQDmkuFLWGUS6kaUJw4zFS9UcKXXw1J',0,9,5,5,0.030720,'Filing Grey','none'),
(4393,'entry','bzJfZGDCqTWjn5xzHs2k3E6P5sEGAqiUZaWkHGNXR2Pa',3,5,4,7,0.029120,'Filing Grey','none'),
(4394,'entry','MKKpcw44XCzTMP3rjhakkAmfBrymt3NMjLZMnHuJzp78',6,1,5,3,0.048720,'Cubicle Slate','none'),
(4395,'entry','3VAN5Cwgf9T2LVj7vdQPN3NqfuJvwagweNDRr7QUB7iv',7,2,0,2,0.044620,'Ledger Green','none'),
(4396,'entry','NVK1hQyW8AcGLabBGsj8M4kbgv7j6aqcvoPdA45c1VDJ',1,0,2,8,0.031040,'Manila','none'),
(4397,'entry','oFQkdgLQ8wmKFRHQopuZkaFkGBvjKoEjVdrh4Z57DfNq',5,6,2,9,0.056240,'Toner Dust','none'),
(4398,'entry','bHE5uw7DHnDidEVqyAZb6mYQCN8GYB2uBGUn8cgy3z9D',1,9,3,9,0.026000,'Manila','none'),
(4399,'entry','U257oNZeqCHSPBv59HKxaLz3Q9MPkYHAA2J7LAYQ8dSN',1,5,2,6,0.027720,'Toner Dust','none'),
(4400,'entry','M97DYdXcP4NGSyojyyatWaxMSJJNpLey1EeRDpnA269D',0,8,2,0,0.029120,'Manila','none'),
(4401,'entry','B2YrrjQfM9bwRUtvmapDPBMtuK9C7DqZZKbEMbi8Hpe4',6,5,2,6,0.047040,'Cubicle Slate','none'),
(4402,'entry','aKy4MEhWxYydpfaCxbcbwm4n6PiE6PjM7KVYA7LBTVnT',5,6,7,0,0.058930,'Toner Dust','none'),
(4403,'entry','cnKHd6JUzJ8rA9X2CCBvExJf5rQdLx31iEVd12LuYFhF',7,2,7,2,0.039690,'Ledger Green','none'),
(4404,'entry','ftw5NCACvS54ibqZC6wphFqRfNfpFDAsiuzN1C1eBH6X',1,0,5,4,0.051620,'Toner Dust','none'),
(4405,'entry','k5hnzBsQpHC2fNiHf9gBscoqRVJj9Y3U8oiQjDPJyTrw',2,1,1,3,0.035600,'Breakroom Sage','none'),
(4406,'entry','tUgHfrJ9cSZ3jqTtSpv9GjLCJRy3mqDwLkwm3Szbid6n',2,7,1,3,0.044160,'Drywall','none'),
(4407,'entry','B5PU4BjUZjH2Z4ZDhoo5rHfD7wz31SCVybixqUs9ax8W',5,3,1,2,0.065320,'Ledger Green','none'),
(4408,'entry','9m8zSVMk6dDkPsYfm5MWQeAMh5aaN88V5Q1iyabhNU6Z',3,7,7,0,0.028160,'Manila','none'),
(4409,'entry','osgesRFv547JE9oNH592JA8LuuCvpMxjg1j1MnA3wfEW',1,9,2,6,0.070300,'Ledger Green','none'),
(4410,'entry','M8YXHTR4DTEnppvLEpism7B3AZcx3Rq8edSwn1PspD9J',1,0,1,5,0.029200,'Filing Grey','none'),
(4411,'entry','8RXo9LjugqNjLe5RVHm7KCoktxXaP7GCsomMZSq4Tc8G',0,8,5,7,0.027720,'Filing Grey','none'),
(4412,'entry','eGnAmvwXm3GbAaH7r88W5Jz5eDWLfY91g3ZyXBQv7QH4',4,6,6,2,0.081880,'Manila','none'),
(4413,'entry','ufT9VK2w47ERYphpXUYeEeBoMm5495pfruFseRJ9jmEu',6,8,6,6,0.042640,'Breakroom Sage','none'),
(4414,'entry','7c5p9cr2szoEqVGtg3N85F11zR6rHFcRBfiDAobFAV2c',1,2,1,5,0.042210,'Filing Grey','none'),
(4415,'entry','kQWNSvkDoybRLftUG5f2rSVEphXrq5jJvLvLYmwDyh79',7,7,5,3,0.036800,'Drywall','none'),
(4416,'entry','RfwrCNnPLMUfFuQP1h4dEdNRetdbtf9v4oTf7TAQdRb7',0,8,1,6,0.028480,'Cubicle Slate','none'),
(4417,'entry','d4fU9CffjxjspQg24zL8XMq1jQmzaEUQ9NPJVNFDYntu',2,2,1,6,0.080190,'Breakroom Sage','none'),
(4418,'entry','hzycY2RB7Bmqiuuh3TaZi63f69omC2mLiAYEwcxGaMAb',6,3,0,3,0.045360,'Cubicle Slate','none'),
(4419,'entry','X262sDxu9sY189FvVgSmBFbPszEzDtjgZMh8ZthxqhAX',1,1,1,4,0.048970,'Ledger Green','none'),
(4420,'entry','hD1AMdnF8iwEBV7WoBqb5VKGfe7iNk4bKq7mjtspRi8Z',3,2,6,0,0.047570,'Drywall','none'),
(4421,'entry','NqBjqNg2Nzmn2xvifq24kWSjENQx6epAU3YdaaBbFAX8',4,8,2,5,0.041600,'Cubicle Slate','none'),
(4422,'entry','wikBqyjgn3rigrS481iHesj6ihGX9aDRg7iVcwzG5rTm',2,0,5,5,0.029280,'Filing Grey','none'),
(4423,'entry','zcqbyiE3GTkSDjtWcmWtjrY9xT3AUBY8JXt6uYEhs9eL',7,7,7,4,0.029480,'Breakroom Sage','none'),
(4424,'entry','cRsuThxiAf9nGVfPy9o5YsuvJEAr6ucBLpoRsZuspg88',4,1,1,0,0.037120,'Manila','none'),
(4425,'entry','44S92gSroDfBPezsg1vJBuXLARi5r4KVHwpQZY8n6qbL',0,4,1,2,0.041540,'Filing Grey','none'),
(4426,'entry','KuxtMDtPH5tGRFfJ4ygKCF6C3K2xy3ZhzBTCWY2Vcttt',3,7,2,0,0.032400,'Toner Dust','none'),
(4427,'entry','wmWQUta1LeMpdPs4vXu4fseb8jGTo6M3kabunn2UEqYC',1,6,1,3,0.038720,'Breakroom Sage','none'),
(4428,'entry','k6BL4ukqisG13gkR3cW1tM2jknco5HS4FGGXSMDJ3g81',3,8,6,7,0.029760,'Manila','none'),
(4429,'entry','x3tUEcDDZaCMy8QyGnUV57nDfbofyH1wsz7PdWoXntHx',4,1,2,5,0.064800,'Filing Grey','none'),
(4430,'entry','xnSwx9sqmZUyeNXKBVLnfeem3UAbfXbYbXgChSbYkGMH',5,6,4,3,0.028520,'Filing Grey','none'),
(4431,'entry','U7vC3Dy9FJDZFs6vxkW3YLyPzxWSUJ2YpuXUBFqM8U3F',5,2,0,7,0.027720,'Manila','none'),
(4432,'entry','y9pmKAX9k4YKPxfEtidcsgVR5sfeHz1Ti9pCXnH7Md5k',5,3,6,0,0.082800,'Toner Dust','none'),
(4433,'entry','GJ9tMW99ucfpwG5mQBDeD2y1TCGSTJLCGRZupqVdf2ta',4,3,2,5,0.053690,'Breakroom Sage','none'),
(4434,'entry','Z7bbyyTaviLaN5pz14pMzaEcHrBv8B3ponihJ1NTfeML',5,1,5,3,0.055680,'Ledger Green','none'),
(4435,'entry','LoErYjTKySySnc9VqHsAHqT9ecmCncefJ4zBbUKzHh7z',3,2,3,9,0.030080,'Cubicle Slate','none'),
(4436,'entry','RUarXu83v7biBrYcGZZT3syoPbr6fZGfpfUjYKiax5K8',5,9,5,8,0.068870,'Manila','none'),
(4437,'entry','RVvuEKWzZKzbyifyehJAwEw4m6LoPWcJ4E5dQJzPjrAk',1,6,6,0,0.038860,'Toner Dust','none'),
(4438,'entry','Dwf3YB9hE8hqgGA5qTHP2qzwUMhUmFTgRCvMCCxbJVWY',4,6,6,5,0.048100,'Toner Dust','none'),
(4439,'entry','FLCCvbwaddXNXdhb8K2iufQTZHcsWanY74PB3PK2U8VL',1,8,3,4,0.056800,'Filing Grey','none'),
(4440,'entry','gV8wnPUNC9rmHHNF9WM9f7LEjFMmwN9v5F7ktSK4LheA',4,5,5,3,0.030400,'Cubicle Slate','none'),
(4441,'entry','nQ6Vu9gtdi24sNEpYkdFRi41YsepiHKnHpXV6KRQb964',7,3,2,0,0.042240,'Filing Grey','none'),
(4442,'entry','nhHNM7bGo8M1NrM2oRp34HuUQEBoTm7SmcHwnGDQXMu3',4,8,2,8,0.052200,'Breakroom Sage','none'),
(4443,'entry','JofK7Uzpc8uGvDfHcXre2uyqqWYysfNgn4wmEA62tbSf',0,7,1,0,0.036960,'Cubicle Slate','none'),
(4444,'entry','PfpHYg3vbfgXnmsHZ9Zzwdthzpuy8RqPy7PpvtsMuk8U',4,2,7,3,0.055460,'Manila','none'),
(4445,'entry','rTJL73VWDWia8EA4uy4aaTn9YKRvinxXDatzbHhTencu',1,5,2,6,0.041600,'Manila','none'),
(4446,'entry','iXj6guLsh4KwkSuagENrdxb1kC1SK9NSdGSWyGTcsiDC',0,6,2,2,0.032640,'Drywall','none'),
(4447,'entry','A6A7MiUoGxq4cAaSEkRZVCdjNA1AS5iWa1VJ6BadASx1',4,0,1,2,0.044160,'Filing Grey','none'),
(4448,'entry','66nWszLsQgjs4uJc6xW6g4qKbWNTuRYfMtmWupZsGtMy',1,0,4,3,0.025280,'Ledger Green','none'),
(4449,'entry','2fEiCGVWtN4AURsHiHASjmB8LDJBCqWW66AbfzZMTXmR',3,9,4,2,0.023680,'Drywall','none'),
(4450,'entry','fwAzKx6PCcSwxRT6e697BtP6KbGE3dJJTJBwqSRukrGD',0,2,4,8,0.038400,'Ledger Green','none'),
(4451,'entry','ZMpBCGLiYhxWjD2s7tgqPnpBxskEfExhCNkL6cGtgGNk',2,4,5,0,0.084420,'Filing Grey','none'),
(4452,'entry','1LrGU9co9MTXDQK4hhaN3jJnC6bJ5z7wyyMskNjhqxcZ',7,2,5,5,0.046150,'Drywall','none'),
(4453,'entry','V4F3hGnGPH8eJSUXJxg4CwDph99KNzUqWAf7YzDCdUgR',3,7,2,5,0.042480,'Breakroom Sage','none'),
(4454,'entry','E64rdzfyUB3QMYH84n25fTH8MYv1a43qcLYTeB1ir9cb',5,5,1,4,0.040120,'Toner Dust','none'),
(4455,'entry','EUix3FavSMuCr487Q1ypS5vmtniMZuNsPdhciA7Lax9F',1,2,6,3,0.039360,'Manila','none'),
(4456,'entry','NrxatE7xFq5xwxA5Ys9ssYATpNpX8cMHjJFDnK4gGnQX',7,9,0,6,0.041760,'Cubicle Slate','none'),
(4457,'entry','AwWgEpEH8BDq5HYAMBVFLQjJ8tqXDB9LN5Mu7V2SDBaX',7,4,1,3,0.023680,'Filing Grey','none'),
(4458,'entry','qVrck7mByqAGGRoJWDJ4393JbD7uh7FKiXV39w9FASTB',4,2,7,9,0.028160,'Drywall','none'),
(4459,'entry','MeVF4A9E6NaBR7Qh738a9Lpo3wroEzSEEpfeQbtrtD3K',4,3,2,8,0.054270,'Drywall','none'),
(4460,'entry','RicdBMZKMFRYRYSeW4dniD8wSe3JHmvvmmpzrT4n2aJ6',4,5,5,6,0.057510,'Toner Dust','none'),
(4461,'entry','Hj9L3b9T7ekWrCF26QhUdfR4cyp6kqLoosJRwwR3KFtt',5,2,5,2,0.050460,'Filing Grey','none'),
(4462,'entry','6T7oTg4xKERUtEhFJRLiJQAndn897D7PDaVxm6YKWLnZ',1,1,4,3,0.028000,'Toner Dust','none'),
(4463,'entry','BKj16F5KGL8HAmqaYYBBrjKDNfTmP3mftQQmqD2EucWY',0,6,1,7,0.047560,'Filing Grey','none'),
(4464,'entry','1QidvxWraqmtTzb9QruW8oFkeMjMvhrkTjjAEeRE83VE',3,1,4,4,0.037920,'Breakroom Sage','none'),
(4465,'entry','vNnkfLR78hVQbZMapFqDeYNUZQhUnuxFkY4ErM46hjY9',0,4,4,3,0.064380,'Toner Dust','none'),
(4466,'entry','4iedFbQyPgNapmxM29E6U71XqB7o4vQcmEnkR3x7G7Uk',2,7,1,5,0.069560,'Drywall','none'),
(4467,'entry','ZMGWLehkxTPhrUAbE6vwK5CBJQ3Tahkdkmw9mFuY6JVA',7,3,6,6,0.024000,'Cubicle Slate','none'),
(4468,'entry','Rk4N5tErqLzdTKXwBpMKHHFRtuB391otAez2Kpw9YUGG',2,4,1,4,0.039360,'Cubicle Slate','none'),
(4469,'entry','YQ2vzagA8v8cz7TV3bUdHQy98RURFXZyKBMraigEBbwy',0,0,5,4,0.047200,'Cubicle Slate','none'),
(4470,'entry','BVcUZkdx1YTGXAmpTcTRMegnMoxrw7swZ25npv9qdopS',5,1,3,9,0.138180,'Drywall','none'),
(4471,'entry','17FPVAAXFyeVBJvEA6oaX5idh7LUYFeZqGyJkpHoZhby',0,7,2,0,0.055500,'Cubicle Slate','none'),
(4472,'entry','YjvbW6Njfm7jReUEmcuz4CnEvCbunYn4kDCaStt4irF8',4,9,5,9,0.045430,'Toner Dust','none'),
(4473,'entry','pvkjjEab2QmrWDULz2uF1EmLB6HqxeytbpnnpzvJxze9',7,1,1,5,0.069560,'Cubicle Slate','none'),
(4474,'entry','69Ad6Z2ueqjBthSWFVVJYLShGv95uDeCxKuXZCd3EhC8',0,7,3,4,0.029600,'Drywall','none'),
(4475,'entry','BjWDewF3RYy7wXbEmtzTxk1aLeXzi4agyxsXpah2DMEo',3,1,2,3,0.051590,'Cubicle Slate','none'),
(4476,'entry','KsMcmGyTPa9Aey5rC31grKkwouHfwzMgVGGEx2Z5NX5t',4,7,3,0,0.049140,'Manila','none'),
(4477,'entry','DhC4FUF9pmehPBD8YGbKJLpFxKuGeTpx2JM6SodnRrve',0,9,6,8,0.062560,'Cubicle Slate','none'),
(4478,'entry','reM3CcCvUWAUQ81DaSb1YU8369AURhx4jcyTMNnJFKvS',1,9,0,8,0.045540,'Manila','none'),
(4479,'entry','Cr7vQ7bGKxLuVSCJwwRTWiqucLqfyhELCME1kVnQfWwY',2,4,1,2,0.048600,'Ledger Green','none'),
(4480,'entry','keND6fSNYSQGjM2TRsL6QdcD6gBSiXXqteXjsptYboX6',6,6,7,8,0.065320,'Cubicle Slate','none'),
(4481,'entry','ApprJJQcLSV8avVffEjYcmTcQvDsboKgujQzzCKkRF4C',0,6,5,4,0.032800,'Manila','none'),
(4482,'entry','TYkZgPWajjkZe4iLo5gqYZyDw39CRycF7cybJDbRz69N',6,2,7,3,0.046980,'Cubicle Slate','none'),
(4483,'entry','UCJ3CAvpbFmjxbjRRdfZAZW6nJApzCehStg5wwUtpocA',7,8,5,2,0.053550,'Ledger Green','none'),
(4484,'entry','iq315Znb5r7vmkZdK9vTSJDNFTnMzPu9x9RQT7RFHrsJ',5,8,1,9,0.042210,'Breakroom Sage','none'),
(4485,'entry','aNtz2kqqaPSgQwkPok4bGmwZ8dhuYP6pPqGriNJNEMmT',3,3,7,0,0.031680,'Ledger Green','none'),
(4486,'entry','dA54d754XSzW23Dmv35arYqedN2dXZJnbHjb7pngiyLY',3,6,1,0,0.070290,'Manila','none'),
(4487,'entry','pZ1LVj6B1zTHL8BZyfJZU1VkrBnUXxWKn76xNVj7yTs8',2,0,0,5,0.045140,'Breakroom Sage','none'),
(4488,'entry','CQRkLfgj4gzmvf42yyp9h1ANGYE2q2yx6XntZkorrkBQ',7,4,7,0,0.067000,'Breakroom Sage','none'),
(4489,'entry','1QRUNbmyDQePm6DQMQ62M6kdjuur731vf9Bx6gqFmSfZ',0,4,2,9,0.036800,'Manila','none'),
(4490,'entry','hweUwZYX7CHXBjShHGsyMHCdNWXY69qTCkPs5Ha53gEh',6,5,5,3,0.044160,'Ledger Green','none'),
(4491,'entry','1edQPVowyuVPeG5c9s4AMDAJ8HhHS7c3aCPxEE6gN3Lb',6,6,0,9,0.035040,'Cubicle Slate','none'),
(4492,'entry','14bWEf7vbr3ad6UstMtMQqAX1pn7U7MynB7Nw747YfxM',4,6,7,4,0.043500,'Breakroom Sage','none'),
(4493,'entry','eEqioMUSz1rLgq2gRreCEsZ4YNZHMdb9279ZqXD5Dn8W',7,8,4,3,0.066600,'Breakroom Sage','none'),
(4494,'entry','2oEMCN9bnwFPYhPuB1UuA7yvd5DGvyMtrbhk6UnhAqMA',7,9,4,4,0.071000,'Drywall','none'),
(4495,'entry','PGwDBzf8JWWGx4AyQxxPr8tE1Hq8DHczPE1ZbzKkqTCN',5,8,5,3,0.055200,'Ledger Green','none'),
(4496,'entry','hd4URrUB6gGCBkF4DWXNjwdVehttSB3brFkHUC9eHpg2',5,0,0,7,0.042240,'Toner Dust','none'),
(4497,'entry','kSQeKgmE2735bMm9TmcQGMuD5GuxmZTDJ2VzjAMKNksi',1,4,7,8,0.049770,'Filing Grey','none'),
(4498,'entry','TEXDzUFHCwp5UzbiV3qaNn5xM7BQvceJ9vsUKLkamFz7',2,5,7,0,0.040480,'Drywall','none'),
(4499,'entry','CwfUpVzv2xMFqEdxMJmGnJAzUriry9K4kamJh2uKfgTu',4,7,5,3,0.030800,'Filing Grey','none'),
(4500,'entry','9RT2qoyeGFXNDD2eBUW2obdh1RnENcq5X6j6EPbumfKj',2,5,6,2,0.037440,'Cubicle Slate','none'),
(4501,'entry','8QucaQfi21QmPrtRr8zNV661UKsRiV7cBBt3Nro5DSr6',0,1,0,4,0.072090,'Cubicle Slate','none'),
(4502,'entry','Q1B4zf6DHb81j75kfdtZxdbxpPeBiQKXsZHCUq3WDYGQ',1,7,6,4,0.045560,'Filing Grey','none'),
(4503,'entry','mPgJomagY4BUxA7QbTK3eJweBuGYyqgSqMEYNUDmSJDi',1,3,6,3,0.040320,'Cubicle Slate','none'),
(4504,'entry','LvvRjm52xm6YKhLm84jDXydcFVfCR27KJbny521yp3Kt',3,3,3,0,0.043160,'Cubicle Slate','none'),
(4505,'entry','4QksQkXiS7o45H4wXt9NqqTNjyS45HmD8AApwS7XEAec',4,6,4,5,0.053100,'Cubicle Slate','none'),
(4506,'entry','NPzPyfubNJFSf9Snove5RG223NCENpb43gjTWdTjJjs1',1,9,2,4,0.049770,'Toner Dust','none'),
(4507,'entry','vvJihUacq4CLcipxcs6yrRq3qHaGaQHkPzS2GegC42AU',6,8,2,8,0.061770,'Manila','none'),
(4508,'entry','7SprEGbTskrBGsMLGzwLTTf2maG2eCHRR6dd2XyU7meZ',1,5,2,2,0.025600,'Ledger Green','none'),
(4509,'entry','FBAnEy9q6TtV8hwEzrLT7J6ho425rHjUhijjXyxyi4TR',4,8,2,9,0.045760,'Filing Grey','none'),
(4510,'entry','KwugSTHbXhKALhhPuDAPaz668vfJQ7oA9FD2Bm2HMmFA',1,8,0,2,0.029600,'Manila','none'),
(4511,'entry','2Y9v4QUvL79k6M1YCs46q4bvrY2dUXm3hTDcZWf9D375',3,1,6,5,0.036480,'Drywall','none'),
(4512,'entry','uK8i7CJGYaeGvTw3dCFZQZNTY3TRYSm1jQ3DpLEJsHkq',6,7,2,7,0.031280,'Ledger Green','none'),
(4513,'entry','WfSsEwb9FMyXrbX4tnHVy2e7sYbAao2DuDV382yfszB1',6,1,3,4,0.037440,'Breakroom Sage','none'),
(4514,'entry','2sPhd8c53BGeC2dwYonQY8HsyVHJgdriDET2wL6naBb2',5,1,2,6,0.024320,'Filing Grey','none'),
(4515,'entry','uSiMiCLLo3KzoargvsrvSyGVfr9AUsQtadfQj2hkQvGx',6,3,3,0,0.034040,'Breakroom Sage','none'),
(4516,'entry','ivMV4Gu2Y71tYinmk1xvoVyTJ5y6SL2bonnMUySEsdcS',3,9,6,9,0.030080,'Manila','none'),
(4517,'entry','uwk9rJw4A33xLuEQHm91yZyBMf3UB2M5YAhLgDXFma1c',1,3,4,5,0.053690,'Ledger Green','none'),
(4518,'entry','B5f4WDy4mV2UXyTP5AFeygDmBdgLN2oTmuMxhc2AhcAD',3,3,7,6,0.033600,'Breakroom Sage','none'),
(4519,'entry','o21Ep8bHnB8BSSS6pwuQngQA2icDXhfaYu46RFLoR2K5',4,5,2,0,0.034000,'Manila','none'),
(4520,'entry','CSzB92K4FQCmrhFz5zWy3QuuV9Z6Gqtk7YBbrnnLxog7',2,6,5,0,0.065320,'Toner Dust','none'),
(4521,'entry','QXR8S47ZxEetx842Gwi48LRCp7efFeQA3AML3N6bVSN2',0,3,0,2,0.039840,'Drywall','none'),
(4522,'entry','HVY3m2hNCftpBSm3QaXtpPv7aKvEY7cdxWNC4Zo4cQbb',1,8,5,6,0.053690,'Filing Grey','none'),
(4523,'entry','fA14KREEm7htrgSN94x5jhkAMV3urTzfGyJ5ztDiHS5C',5,3,0,7,0.045430,'Manila','none'),
(4524,'entry','z73EruVVPa6QJJFay7coHBKyADEMF9xLAgfY2Gvjhd8e',1,4,0,7,0.049920,'Manila','none'),
(4525,'entry','eDHYNe9R6yZEnD6ASTrHP5xtY9UZ7N7Ksi2dJngZ2Tmn',7,0,6,0,0.053600,'Breakroom Sage','none'),
(4526,'entry','tzbW6qM5hJEYhjXoh8dnAcmUso38UMCyePatG6n68Jjw',4,9,6,9,0.043700,'Toner Dust','none'),
(4527,'entry','gWVKXkMwkPnvBsH6nV6MZCzs8WQpEmrdtMX7M2EBcEq3',6,2,1,3,0.057230,'Filing Grey','none'),
(4528,'entry','5wvDJvQWR1HauyEQtXEY9hGZSezWJHVUGCfWJac8kdkL',1,4,1,3,0.037440,'Drywall','none'),
(4529,'entry','qVMbJoq5ZwcfxRqJQEZZi3b4FGx1QxwCsmRrAUYaRCaY',2,9,7,5,0.050320,'Ledger Green','none'),
(4530,'entry','SFBT2swiDvDWRjshp4gLhgFKtqiGkex5eneJoW2JBeii',6,1,5,4,0.033200,'Cubicle Slate','none'),
(4531,'entry','28ByBxSgZb4yrxyjvs5az3MyzJNUSc1EkgnHFvf9bthY',4,0,4,5,0.049400,'Cubicle Slate','none'),
(4532,'entry','mwAs5oTEQbsAPtDCkDdSkkJHn5UdL776utScJXqRLHRY',3,0,3,0,0.058000,'Manila','none'),
(4533,'entry','DR7od4inm5Dai2k3Bu3417ryUVyCjnwcooT67M5cFzgb',2,7,7,5,0.081880,'Cubicle Slate','none'),
(4534,'entry','8ZMEagM5tfx3tvaHZzNLAEZDEkE4mdHNYBq4yWUGByZD',3,6,3,2,0.050220,'Filing Grey','none'),
(4535,'entry','gT65XHXY4cTbPYJGMvzgMKu2Ejdvn6Y9yNrMaw7r4ivi',7,7,6,2,0.035420,'Breakroom Sage','none'),
(4536,'entry','r9cwGzFbzTdeX4exNvnTi1p7tYHMJbuw64Yr1n5U6Aan',1,2,2,2,0.038720,'Cubicle Slate','none'),
(4537,'entry','aKq1a8uDEy3ZRUgwkpGCX7ye78jghfxhMxE9szAjGCg9',0,6,0,5,0.030800,'Drywall','none'),
(4538,'entry','85twVmTVNTmFeidE3TswJ6yiaJGVsxy9jNX24fbkcKFM',5,7,7,9,0.030360,'Drywall','none'),
(4539,'entry','AxVJbeQiUHCY3GbQFQNdRg2ePk53nCvfLbXEmof8TVt3',6,3,7,0,0.034760,'Ledger Green','none'),
(4540,'entry','Jh4a7UYTeWJTHSNxueL7yXeozxSdbTuhNZG7k5Q9htba',4,5,2,7,0.031680,'Breakroom Sage','none'),
(4541,'entry','fztDVoYFKzuSAqXfkrUie9LLkvYoRzKuByZeyJGd5w16',2,7,5,6,0.038000,'Cubicle Slate','none'),
(4542,'entry','LjoJQHkiWHoyzVKP2QVrtrZPnDsZPYoFXQxPyAmkpjdy',3,1,7,9,0.040120,'Manila','none'),
(4543,'entry','PrxbF87ZU8tKTaUELnpMUGtYBspjtzwrie6iarSavuXX',1,5,2,2,0.058000,'Ledger Green','none'),
(4544,'entry','4xt4j5AEf63Bi43C8N7ju7aKdf1auQsZM9T5PuT2rkXT',1,3,6,0,0.040560,'Drywall','none'),
(4545,'entry','U9fK69PDNVzEigi2qGUFfpxaZymimcTKSkASvYjqEjqX',5,0,5,0,0.044250,'Ledger Green','none'),
(4546,'entry','HTRrN98nrhiV8XfmLuFQfzXY36RpWrnNczNCzDiwAY4c',0,3,0,0,0.074520,'Toner Dust','none'),
(4547,'entry','byXif6fJQU15dbXwSLnJxNyUiH7jNbAjpEsdazm2KetK',6,8,2,0,0.037720,'Toner Dust','none'),
(4548,'entry','hFD49HsuQfcU6YAuFgKNALubAavmE1zqZkM4ZNKWDwvF',2,8,7,8,0.031240,'Toner Dust','none'),
(4549,'entry','vcGVY92RzM2eh1YgFytxHi67cpsACDd8guABU7kg3LZV',5,2,1,0,0.023360,'Filing Grey','none'),
(4550,'entry','to2HRivUtKvubGYnf2beMamqJB1Bargs42Z9iMsXowGK',2,8,4,5,0.033880,'Filing Grey','none'),
(4551,'entry','KW4pjQKbqGwzwprAnan9JWAaedDGGtraTpQDZ8Pw6RZN',2,9,4,8,0.029120,'Manila','none'),
(4552,'entry','3643LSvnkPGj1rwxmBNGc9rRfFmxRdgnYkfLU219vMSR',4,2,0,4,0.057510,'Filing Grey','none'),
(4553,'entry','87iGvra4bbfSMVWGUWQHSvQTrWKdzwDw1Vf8MC4N9X4j',5,8,7,8,0.035360,'Manila','none'),
(4554,'entry','asJZPcdjE3K9yy2sASNU7AxPzSJ9tTpQEHqdDt2LUhWf',4,0,2,8,0.055440,'Filing Grey','none'),
(4555,'entry','YXsGCs5oHjhM9MePqzeEaJjLYXQwEkwdiqjLxt9aKSDz',5,3,2,0,0.054810,'Manila','none'),
(4556,'entry','qXtAfztEidFF3729FEdKrTJyPkSRfZgTWNuyX321ghdb',2,7,4,0,0.032760,'Toner Dust','none'),
(4557,'entry','jPyXC3u5hyiZVj9z6DmS1FoPGcSLY88sfN149qqNY2c2',1,0,1,6,0.046560,'Manila','none'),
(4558,'entry','wzsqHpL4QY28etSoCCJD5jqPVj68c36gsqwrQroiXDom',7,1,1,0,0.068080,'Ledger Green','none'),
(4559,'entry','f7uJMQdLvEF5cLGUGtve8oumVcLDLn6WL8QnCS23UeyZ',6,2,0,0,0.057510,'Ledger Green','none'),
(4560,'entry','LhyaCsuSAwkifhjQmhQp3VLybHQpz2cHkNgQaBwpA1bv',4,5,0,4,0.056640,'Manila','none'),
(4561,'entry','sFiEKBwNGo1n29VCtgWBiau315kbry5EUde5dtMAcSFM',5,2,1,6,0.048510,'Manila','none'),
(4562,'entry','Mb28j87nNavqnUvqTKJQuTNgfJ9LFumEvYmmUBdBsRMt',5,8,3,3,0.049580,'Ledger Green','none'),
(4563,'entry','yMM1Cv2eh1mobFunk9M5udaBiFavHWh3MzwRiYqMteV8',5,3,3,9,0.059630,'Drywall','none'),
(4564,'entry','XPorLnmkzEWd5nBghgKQW4F3VVVb5nVwst1eM11vew8Y',7,4,6,9,0.035380,'Manila','none'),
(4565,'entry','jNn8rkJqEZLeC3WGLQtxhDUhrbbuB2gSvAgsYukf5YAA',4,1,6,6,0.038640,'Manila','none'),
(4566,'entry','FaZcdq11EeF1bWqka1HEF32sTsnpwAhBac7jhyvZ9m3C',6,2,3,5,0.042240,'Manila','none'),
(4567,'entry','BU6RyVxdzc8WM96nxbJuvRXSVerZfdggLmYXUSjeF5Nx',7,2,6,3,0.046900,'Ledger Green','none'),
(4568,'entry','S6TgUxgyiQTmTbnH1PxuG8HEN3qpBTVKKWs7XVMXimnp',4,7,0,0,0.044160,'Drywall','none'),
(4569,'entry','51e2H6SYyUx3XHcgHaV2wBeF1MmV4vT1gkE7aWjFFh3c',6,5,3,0,0.048240,'Manila','none'),
(4570,'entry','XXAfoq9c79YM9zzyqkunqwmbh1oPQ1pCGD2EtB9PtRxU',3,2,7,3,0.030820,'Manila','none'),
(4571,'entry','vfMRc6XgFB6dAuM3JHKws79r89Y2MoNPVeHVvDgHdG8C',6,4,3,7,0.054760,'Filing Grey','none'),
(4572,'entry','8E4by1DyFVEeVFkDoRH7rU1cNDLU3WHCH23PvVnc5zca',1,0,6,9,0.044730,'Cubicle Slate','none'),
(4573,'entry','2BF5eUW7k9RdWKfJQgBtWGGCasFPuHjRNcPF1Zt7rXjU',2,3,2,7,0.029760,'Filing Grey','none'),
(4574,'entry','Bmi8vYrmDt6i6cPYriQ9TSHoj9dXYuWzW6Sjy5bWC6oB',5,4,5,9,0.031040,'Breakroom Sage','none'),
(4575,'entry','81qrELsiQymKnZcFC5BpZDoVvvdMzCM5wFdoKCReUMpc',1,4,0,0,0.038180,'Breakroom Sage','none'),
(4576,'entry','bLiEbu7Gb8EAdTbj5mSzQJNZTqJxpDxs3oDhQtLV5Zu5',0,1,2,5,0.041080,'Cubicle Slate','none'),
(4577,'entry','Nj9UhGhBRB9sojhkczEgstFGpZN2jEU87KvuR6UjpZQu',0,8,1,7,0.028800,'Manila','none'),
(4578,'entry','k1Kzt58i5xLTsZAbvxZq9DpHJnJQ6wh9xuq7ar2ZwcqA',6,1,0,3,0.024960,'Manila','none'),
(4579,'entry','GuM8bpfS4pVem1nSTsnBbmk7mEx5Y1RECaHDhXtSst3J',0,2,2,2,0.032000,'Breakroom Sage','none'),
(4580,'entry','r7BpTnTV7K3N5Tu48aYbzhpfqQUxuuiwe1F2FnpCtY8w',1,6,1,9,0.042240,'Ledger Green','none'),
(4581,'entry','H9zopHMiF9kj6nrFxBmXmnFKwCm9CQ55EtDi7TaL665x',5,5,7,3,0.036800,'Breakroom Sage','none'),
(4582,'entry','9zkCDDKSu6syqE6fNcbd5ayxi7okfb45BMBpxcKd2pAY',6,6,7,3,0.063180,'Breakroom Sage','none'),
(4583,'entry','aUynVpEs7sfi6Ek5bXwbSE1kf9cKcxFwDg3R5gV41ys2',2,9,6,2,0.082800,'Manila','none'),
(4584,'entry','V22DL3grNWevKqETvpiGNAvHsid5JHzaQFK89g5qXH1W',5,4,7,6,0.020160,'Drywall','none'),
(4585,'entry','GUCjSvsufXySXkckBPxL7ExLH9w5gVV9mY2xGHyGqjJy',1,8,3,6,0.030720,'Ledger Green','none'),
(4586,'entry','x82SXYaeX5THJqUPSjSzjcmFCy1J3CtdYfw1GPGJWymP',7,7,3,4,0.031280,'Ledger Green','none'),
(4587,'entry','t7p5CiWKh4ZMUqeSoCEnyGNm6ugtWhbWBaNVsa76wSJ9',2,4,7,3,0.058220,'Breakroom Sage','none'),
(4588,'entry','Bna37vnmvBFKH31mbGcUtRTsFfXGJ5tUisXmLksS4aeW',1,8,7,3,0.048840,'Drywall','none'),
(4589,'entry','kDWgTD9pcQPuz9WZxEAmBnU6KYTFYAXxM147dhbGZFuY',5,5,2,0,0.063480,'Drywall','none'),
(4590,'entry','uF8dcpeF7zSuaHQDmKKYSeWciYtzDT8VfdT29JMVtiEC',5,8,2,6,0.029760,'Ledger Green','none'),
(4591,'entry','p9ary16SEykEmchxSZg2xuYjKouSiSzVppvCvNWmah7y',0,3,7,4,0.031680,'Toner Dust','none'),
(4592,'entry','evL7xLKgh7HxY8AZ5yA1LCMNHicDzeHgi6kmhv6QPzrC',5,3,6,8,0.027200,'Manila','none'),
(4593,'entry','ecRoaKG2hgKTye7qyaxHrTpgminYawZj4YL79fmwzcuH',1,5,4,8,0.051660,'Filing Grey','none'),
(4594,'entry','phs3TEquoLXKYsQX1i47N1N6Gt3LZThE2E5RrEYh2NJA',6,4,4,2,0.031680,'Drywall','none'),
(4595,'entry','wEFRBN5ZargmxVsM9tyTN41JYqkHe5ybnBnCYw97LUTJ',7,7,0,8,0.056700,'Filing Grey','none'),
(4596,'entry','q4sjyuJpQ5tRpaDr2yruW9bso2y7xDzqyX4zrMcJdBmq',4,6,4,0,0.047840,'Cubicle Slate','none'),
(4597,'entry','qqoWjGN27TaR7Aoc57Wm9ppnEWYb5VhDPkTN3aqGrG98',3,0,0,0,0.061640,'Breakroom Sage','none'),
(4598,'entry','E339YRqbx7YnnrEspCtMZ5dYoHxSxLLuXftagqokomSn',6,1,5,8,0.049700,'Cubicle Slate','none'),
(4599,'entry','QX7hBUqyL5rAFhBzEjrqjVLmVyFxoBBwDMs7oZSMqGDk',7,1,3,0,0.060300,'Ledger Green','none'),
(4600,'entry','cGLyub65h8Tb11x8g1qhRwvHseLwYyYT2HUM8pQtXGqu',0,3,6,8,0.059940,'Ledger Green','none'),
(4601,'entry','JbLBFUV4JE3nybUeroc5tTQHBF8WBqzdMRrj6LZ2tsVH',4,1,3,7,0.044200,'Toner Dust','none'),
(4602,'entry','6GSUVoP9nEf3qxgvqXgCtKpArFdkBovsuzEASQkcFnNm',0,9,5,2,0.029040,'Breakroom Sage','none'),
(4603,'entry','HChso6ANQ48ZensEXBZ95JA4qzSxs7oeYdGiGdzF9CuS',5,4,2,0,0.037920,'Breakroom Sage','none'),
(4604,'entry','nTk3fvudSHVQ4xUcuHN9pdTjbGZkVrHtNoi5cjCgJZxp',5,0,7,7,0.047840,'Ledger Green','none'),
(4605,'entry','Aew31imLJGwnW5oJ5hmNeNBr85kCX6tsQYN3X4YSDJLz',6,5,4,6,0.030240,'Filing Grey','none'),
(4606,'entry','jR8aJdta75594zFWrawE43mkRDp4qcVoGq86U8ADt8BN',2,2,6,9,0.029480,'Cubicle Slate','none'),
(4607,'entry','sj87yxh2zCQQCeEj99hcUp7zvVVuouqDQzbhx6FY4nuG',6,9,1,4,0.055500,'Toner Dust','none'),
(4608,'entry','vi3U8RKTTADRGam3i46U9iasDTk6E1AeSUoimZqKVAyp',2,1,7,8,0.032000,'Breakroom Sage','none'),
(4609,'entry','G7huPxubH6xrbE1je2JZjkZ5xsmKGNaUURHejBUhWSH8',5,8,7,5,0.062980,'Ledger Green','none'),
(4610,'entry','D3e5HQfK2nLia7VoBvSHXmsmyXi5nXBS5YLVS8mjno8e',2,8,1,3,0.054020,'Breakroom Sage','none'),
(4611,'entry','QRqh22CKaQFUJPxg96Rh4YdvYJ85aEtBFAdZcdErwXYt',1,5,4,3,0.028400,'Filing Grey','none'),
(4612,'entry','VMEea8dzsiUFaZNFb3yNSMbUStCLUfMU5RUgX6WZ33DM',1,3,4,8,0.041760,'Filing Grey','none'),
(4613,'entry','7AThAzZqQPfkCHC7smka7t3FtbdjAhDrre7W5DGpVVNx',2,4,7,8,0.036080,'Filing Grey','none'),
(4614,'entry','GbFKXSCweR6y2AEnh4VkFfT7KzQgmx5bPxs5aLdi2Ren',5,1,5,7,0.056640,'Drywall','none'),
(4615,'entry','gwMWavz69JDvWE5SbZgivKqU6HXJr7RmibZDD5YQKTvX',3,8,6,2,0.050250,'Manila','none'),
(4616,'entry','y26y2egKtDwhVhxoqcj7vDpA2pKS5y4RDC6k4UCrFo8q',6,9,3,0,0.057040,'Breakroom Sage','none'),
(4617,'entry','q5m9N6TbuVqaiLP8jqdXzusRNqYHhoKNiJeZgtbUfX4G',2,0,2,0,0.019520,'Ledger Green','none'),
(4618,'entry','LuzvD8oGsoSUrSQUFRuU49kuLQAFaUqhsV7GJGSbE6Mz',4,3,2,5,0.035420,'Ledger Green','none'),
(4619,'entry','1gKqqnNAEspCoNd1uLtAStmzu2AbavrMbMNzdySGnEDD',1,4,1,4,0.039560,'Manila','none'),
(4620,'entry','ra9M3HvJiv89dBN5ytpmLaKsuB26Si9pa9jcU7BDvPxk',0,1,6,7,0.060720,'Filing Grey','none'),
(4621,'entry','Tk25f5hJVYpJA1Kre7Z4Gva69tpkrM6onCSohixMBbU8',4,9,0,9,0.044620,'Breakroom Sage','none'),
(4622,'entry','ZyN7KYNs8cjGfjboZyJb7aPAAQJUywC44esB4Xu5AAD9',5,2,5,0,0.056800,'Toner Dust','none'),
(4623,'entry','u8xJEbxmy8pYSFE5L6rKp7TMaqrW4iggyzTDdSdh9SKi',5,6,0,9,0.050250,'Cubicle Slate','none'),
(4624,'entry','bpVFtdrpXFBxTH7KmWGBquKi9o6Up7vDyCePjZNpNXKt',2,2,3,4,0.045240,'Manila','none'),
(4625,'entry','WeTsWSC4aQx5gmBpMVZHWeXwJmGS5SvLK9cvk6FKCYki',5,7,0,0,0.031680,'Manila','none'),
(4626,'entry','aZFA5wLZdGpPcWZNzUUeHVfdC8XC9du8Kqj2dW4W4jWo',6,1,3,6,0.051620,'Manila','none'),
(4627,'entry','XEjxRYgs1JmfLmDDbGBoXTypSmpAqfwzskyHL4E4ruAn',3,8,0,6,0.050460,'Breakroom Sage','none'),
(4628,'entry','dEsEf2VWz4mFQdKutHDDSzExPeVqvr42ugcPbBoAuzpU',0,3,3,8,0.041760,'Toner Dust','none'),
(4629,'entry','9Xh6SJV8i4jEtPne549hhiLrykycWK1DWrM9dD4kykys',6,3,4,5,0.051800,'Toner Dust','none'),
(4630,'entry','EmXouzQaLGLArz5uGgo4hYSrbpZKq8bM8CnLGHFyinj7',3,5,1,8,0.068820,'Drywall','none'),
(4631,'entry','NSUeRoDohBPC8gYrcFCoUHpuE2wqHzkwSPoiN5H4HAxP',4,8,1,8,0.031200,'Cubicle Slate','none'),
(4632,'entry','gG616XSq9xFCth9CUctBDXTS9ZqDvBZu1negquAwBDi2',5,2,4,2,0.031740,'Filing Grey','none'),
(4633,'entry','JjKgJARYrSs1apQdHtrhgTPWC6aQK51EgmDwJJ33jKX3',7,1,3,9,0.038280,'Drywall','none'),
(4634,'entry','FgcCRDNQJWgyvNHtMNoPE5nCyXknu1x8G5ccezJKSXL7',0,8,6,3,0.019520,'Drywall','none'),
(4635,'entry','GcWQkyzwDYZEACUokpKFCTG8ee1z2SBogFB68P236QSX',6,7,4,2,0.063480,'Manila','none'),
(4636,'entry','CEEzWoWRPa9pDXLVM54k2UJe18yF9X9bVYMhS59N2AMB',2,2,5,7,0.027200,'Breakroom Sage','none'),
(4637,'entry','wmgjzUFqbbSoYbq8GQSNS8EWMLVZjNLsLf55mq6mTnLz',2,3,7,0,0.034320,'Drywall','none'),
(4638,'entry','3GXuBesZang4ywbPnpEY5oCo1tossP6VTubhwiAk4EzX',6,1,1,2,0.043680,'Filing Grey','none'),
(4639,'entry','yH9GiPB8VSQpi1DjeB1kyh7VHhdRarWQ6ekQhvtjjqFy',1,9,7,3,0.038400,'Filing Grey','none'),
(4640,'entry','tmp7Qegc6pnt6szGityeyVxEZg3nN91U1tFYBi8mcYvX',5,8,0,8,0.066600,'Toner Dust','none'),
(4641,'entry','y3rQayUBnbhjV22vPAKzEY8Yk39gi94cgCm4PGKpaNzF',5,3,2,4,0.025200,'Cubicle Slate','none'),
(4642,'entry','ZyEFPJsHxU6gsh8H2MJ9wUEzoVqB8t4bAGHR9pwGckH8',6,5,3,2,0.062370,'Toner Dust','none'),
(4643,'entry','rTAm3WeJDmmXA6Mqh17nAucu9xditoZa8bVs69f4uyTq',5,7,4,2,0.036800,'Filing Grey','none'),
(4644,'entry','WR1FNeYx21Uu6fHyfaYokNTKKdhVAazk42oFweoevtdz',7,7,1,5,0.051040,'Manila','none'),
(4645,'entry','WurK45Hvyh8tx375aF4tMC2Boc7F4R37SGWswqn1AMYV',5,7,2,0,0.069580,'Drywall','none'),
(4646,'entry','ZDxiLzVM9yXMKmpnRvoxXhRYAjYov69mWRXUpbRvCQGo',2,9,5,6,0.051590,'Cubicle Slate','none'),
(4647,'entry','U9e8P84MgfegrMzSHMEWKDrB6FXm5iKvtyc1GDfiRGho',0,4,1,9,0.043680,'Ledger Green','none'),
(4648,'entry','3D51GxA75rpU9ypLXiQEHrUSkBzCrjxcst68BjSRP2CT',1,1,6,6,0.056950,'Toner Dust','none'),
(4649,'entry','vhmMYU4cj81msbnPV3zizaXXGCAPvSQwJKKa8sd2P9Wm',0,7,5,0,0.051590,'Drywall','none'),
(4650,'entry','zgLCJ7EJJGagDb9hGhn3Day9zWY2EfWw5CQmfYJaunbh',6,0,6,5,0.048720,'Cubicle Slate','none'),
(4651,'entry','yZBqZixxWFytcdmSPoMudcpkA4u5wdgWwyt91ZcVc7F1',2,5,7,3,0.080960,'Breakroom Sage','none'),
(4652,'entry','AAQakuymrAAhj5P1WhW5qJ2y3AfeBfNdkwbzjjhq7ivq',0,1,7,4,0.025600,'Cubicle Slate','none'),
(4653,'entry','Acx3RumFWxiSnnLcDwSzLcfBsCcu6NT9gZEh5hYUKPHQ',3,6,1,7,0.030360,'Ledger Green','none'),
(4654,'entry','VQQSDnQVHqsXqUniAXMo6YEtY5iw51wTqXqvDteRxpk8',7,5,5,5,0.072520,'Cubicle Slate','none'),
(4655,'entry','5NQ5FLSjqFBvCsnYjNvzbrWwfPzazEzcuPLsLYg6kdkV',3,6,6,4,0.024640,'Manila','none'),
(4656,'entry','zngBCpj7WBQToJceHBTF9A6QRcGdigPuVohMgRFVHHLk',4,5,3,6,0.042240,'Ledger Green','none'),
(4657,'entry','QNw6pC14e6D122ZLvvuityiwSEmxxtC6Rb1pYqUaust2',0,7,1,8,0.037960,'Filing Grey','none'),
(4658,'entry','b34XztJQzaPsaArPus6ShPByWGkt6XxxGPS28CUsEeB6',7,2,0,0,0.041760,'Filing Grey','none'),
(4659,'entry','oRVT9B3S3B4ELJmva82pdWm5jSudUrE9ARbVGr2ZSrWn',5,9,2,3,0.068870,'Manila','none'),
(4660,'entry','HLU3ysC1Gj5U3kDaGQy7yqD3YuGTAc2aR7A6tvUqzYvA',3,4,7,0,0.042640,'Manila','none'),
(4661,'entry','nH2VZd66pB6wBEbkooBrQNYjiY6rCfjD8fr1t3F52KyQ',1,5,0,0,0.066030,'Toner Dust','none'),
(4662,'entry','DkN2MaxaoxQXw6GXEzmex4uHESy8xnixLxeXpMvtahfo',6,7,2,8,0.042320,'Cubicle Slate','none'),
(4663,'entry','jBVjAdWiJrJW242fr2e1wp78iYcDqEPpTpTFjgYZcMzG',4,3,1,4,0.044660,'Breakroom Sage','none'),
(4664,'entry','X2PwDvyUysRnRDx7fCpS5kQEe5ZC2njKSRxdqkkGZsDu',0,6,0,0,0.051660,'Drywall','none'),
(4665,'entry','58F6TZV8edmupEBxSkrDgUXLgUdQJx5t1Z95jXMyjSod',5,0,3,9,0.022080,'Cubicle Slate','none'),
(4666,'entry','nwYwrqJgRG1WoLmFUTtKx364nz9sYyZtrjgVoAZotrM7',2,1,0,4,0.026560,'Filing Grey','none'),
(4667,'entry','ze889aEheEWiWDyxLUoHiwuPa3kscAycDKUDFZE9iqK1',2,9,7,2,0.039200,'Manila','none'),
(4668,'entry','ohABvmU7c4oo39nnV9DQU547mtrLzfTSKRCre2fuh1UY',2,7,1,2,0.029760,'Filing Grey','none'),
(4669,'entry','dHHUSN35iLuD6k9oLa5xNh2WXtcCFmtNym4t1ddVhdWC',3,8,6,8,0.026800,'Manila','none'),
(4670,'entry','pVWy9Zu5VHqLwPnSZn5ceBZpSkuiM3kHoS2EWo4tY1uu',1,1,1,2,0.070840,'Breakroom Sage','none'),
(4671,'entry','16kfavpWjfCszjczw1qFPb11RA8x2tkfrnkp36SRtCQr',2,0,7,9,0.037600,'Filing Grey','none'),
(4672,'entry','zDbrVa7aogXEEsJfaf5CocE9V7MuLsbpRCEt5dtR5pFf',5,6,0,4,0.044080,'Cubicle Slate','none'),
(4673,'entry','rYQkTDdxQ5FcsfgvZYyA5Mj8UD8UG2u3sELYYijXdyAQ',0,6,3,2,0.100110,'Ledger Green','none'),
(4674,'entry','jMXsprJkKYQaorr5mroCXrCv7qGXyMkKL8TV31tzkopB',6,3,1,8,0.067340,'Cubicle Slate','none'),
(4675,'entry','W5Hvx1Tux2DKttq557omUrF2DGM7zonKELkbG6S4JpeD',7,5,3,7,0.042600,'Breakroom Sage','none'),
(4676,'entry','TYxksPPG2oMYp9fNCQWtJkMZFbFwohe3wxeHRKeFJhB2',2,1,4,7,0.038400,'Manila','none'),
(4677,'entry','v29f6JSDjVrhMv97h7nD22z5u3xA78rn3LHQigREuntc',2,3,4,0,0.028400,'Breakroom Sage','none'),
(4678,'entry','CZ3YXgrQ7ub3iiyMagGV5GAdmagNtF195bnN7Ktqpz5X',2,0,4,4,0.040870,'Drywall','none'),
(4679,'entry','S1bHN2oB5QnUfm98JiGU5qQkosZy2aL1vL7fBjokgiL9',6,9,3,5,0.059850,'Drywall','none'),
(4680,'entry','Zgz5oWB3oFBHAv9PfNWDFELjQxdo6RCRScuJf6JYPKAJ',2,5,0,9,0.038860,'Ledger Green','none'),
(4681,'entry','HftNqjmzYBFmhyPefuxxQiEqYmLpiBegcdYh5GAvn4vS',0,5,2,6,0.042340,'Toner Dust','none'),
(4682,'entry','eFBTBuxaHbSeT22JDJHF8XFQEbfpxBK2WWEQDq4TgiZ6',3,6,3,9,0.031680,'Breakroom Sage','none'),
(4683,'entry','9QK7mK9RZqGAiWRjkYK5aBs54s39hb7BoQUgSD4ww8y1',3,1,0,2,0.076950,'Ledger Green','none'),
(4684,'entry','S1fmj7on2R2nuJkG1zfSxu2bXRJNJimnfQT7X91stCqr',3,4,5,0,0.049580,'Ledger Green','none'),
(4685,'entry','NQJ2tr3CbbfixWkLcBunRktUbS3jdUHHDma2MU55YP1S',2,9,0,2,0.054270,'Toner Dust','none'),
(4686,'entry','sM6W24cgK6tgGjup7NWE7pvVuZWRuJCAs9ErjNwcCFLn',6,2,4,3,0.070470,'Breakroom Sage','none'),
(4687,'entry','27UL96CxWuM2tjoPvAV3F7tCPQsSwYoVSaq62yBkYrRD',4,9,2,0,0.058320,'Toner Dust','none'),
(4688,'entry','XAR4fLScULvAbPskfxezp1JznC4Q4fBdWyjGVTApcMgK',2,8,7,4,0.029040,'Toner Dust','none'),
(4689,'entry','cfC6FqfSM4Yw27RDH5haF5rus4hme1pzxGJ6mDPbudRz',3,8,5,6,0.070300,'Filing Grey','none'),
(4690,'entry','in6zRwFJotvHkui7QTqKNztKaWSnoxCQrWxJdsxrpeaG',4,3,6,2,0.034320,'Breakroom Sage','none'),
(4691,'entry','C1UdhaMWf5CWVL9FBxaeonBJKFGt8UMHNpTA4qDCKL1m',1,9,3,2,0.036580,'Breakroom Sage','none'),
(4692,'entry','RjBKx7sRfDMzh1sQHvzj7cfyCLnrH9RUua1mP8Dtgeu7',1,0,1,8,0.037440,'Toner Dust','none'),
(4693,'entry','QcsgBFmexXP3HbkCRpXC73MpdwSS3tkvajpMFRpFLArZ',3,8,6,4,0.044160,'Filing Grey','none'),
(4694,'entry','gGoCLobumzr6ycW9Bo9cbzucgzaxTidBACbQrXDGA9MA',7,7,1,8,0.025920,'Filing Grey','none'),
(4695,'entry','TvVkc8G9L7D1kdfCNovHdB7a7u82HGytHMjAU7zE8toa',4,1,4,7,0.025280,'Ledger Green','none'),
(4696,'entry','GCGKecHtkV3SAe7XWNyV85jPinXZDsPs72xQ9zr48CFQ',0,7,7,3,0.031680,'Drywall','none'),
(4697,'entry','GmU6UHxESmFAQxFKYoCuXtCBytW72fqhB4pSd5i6TwVj',1,7,4,9,0.042320,'Manila','none'),
(4698,'entry','e1DAMN1dEgDzw7D3gKyywzubLguE5FH957SARnq7deXT',2,3,4,4,0.029280,'Toner Dust','none'),
(4699,'entry','JE9ixy147UufM1wcbYXkvN3Gg8t4esuxT7pKVpdNP9tN',7,6,2,9,0.057620,'Filing Grey','none'),
(4700,'entry','qfFE2MVXUj8J2uDdwRQsoKqf459VyzMGZnewPdapFkQM',2,8,6,9,0.036800,'Filing Grey','none'),
(4701,'entry','j8XWdN5K79bvA2fiULRSQkotwtfaKemPZqBTW7vX8QEg',0,3,3,3,0.037920,'Filing Grey','none'),
(4702,'entry','bCqAnAvy9qfctbVseKyvvbzBqJ2a1qh5JTNVyUpmj8AG',2,6,7,2,0.047040,'Cubicle Slate','none'),
(4703,'entry','z5f4NB4t5VDy5DTEYHStF1Nib68EhBo76fhp67tPTmYp',3,7,3,5,0.034500,'Drywall','none'),
(4704,'entry','5wfcXGoXAmBJQVmvgbtKr1bikLQGkGY5ieEK51vCcaxo',3,9,6,4,0.040320,'Manila','none'),
(4705,'entry','PYSXc6pSTawCk5yto7kHJez47RaAp8VBVZFtxWvKYXsT',5,5,5,6,0.034800,'Filing Grey','none'),
(4706,'entry','a9ihbDYCTfDHUkC6qoZZLUrmwWTVX93zSBtjFxNLLnFs',5,9,2,9,0.024800,'Cubicle Slate','none'),
(4707,'entry','fNCGBKEWjf5jxK2DHzxLUkncpJebMxpjmiEXWkbyPxfa',7,5,4,3,0.021440,'Filing Grey','none'),
(4708,'entry','pQn9DeXn1bcXd7YPfDbRMkixJ6AcCDdmDgw9LX89ysya',4,5,5,6,0.049770,'Manila','none'),
(4709,'entry','fBfvPUg38YJfbKAhUodkjcWUVieUZtTfTJYkiLi7JPQt',3,5,7,4,0.033200,'Manila','none'),
(4710,'entry','cie1QGa2SMWBnUGrd9ShMVVbherfqPcbuxX6p7pmpxhd',7,8,7,9,0.059850,'Filing Grey','none'),
(4711,'entry','vhvKaJw8a2Vx2uwBPgeUtg2hp6ggRtDcPiLf4PKXtQdP',6,2,4,0,0.055440,'Breakroom Sage','none'),
(4712,'entry','vss1HoG61EpBbbY4QCg2PVfFgJPPxTGcFjuRMmnqaSwU',2,4,0,2,0.065660,'Filing Grey','none'),
(4713,'entry','ePPxEsUja7QzhnBa9mn5XiFrC9WeR5zFZHnvSjJ1i9rh',6,0,0,0,0.072900,'Toner Dust','none'),
(4714,'entry','7pAcXAwbBfhRbX9h22WRVNp3aMuJRxtnwE1hRXivjw8Z',0,1,1,8,0.056260,'Cubicle Slate','none'),
(4715,'entry','5F7pQrYGJWPoBmXNcc3FwhDsNfZSbdAygfYN2Lp47ueh',6,7,2,5,0.032000,'Drywall','none'),
(4716,'entry','fdDhvgDPQn69TWjKdW2wTRQxnagYU4EnXMYVbVAwZ1oH',1,2,6,0,0.041860,'Manila','none'),
(4717,'entry','YtG9184HFyvBa5ySRDsjuNX78HzU4acPypwrwPYoYkm6',3,1,3,7,0.030720,'Filing Grey','none'),
(4718,'entry','c49TzH4NPgZ3DkhxRNRPeq1Mzj7BqwZVGFy4ugZk2KAc',0,4,4,8,0.034040,'Filing Grey','none'),
(4719,'entry','UAYpq2BpKJU55f9sAWVjayP9wUqVdWEvnLZiqokUHTNz',2,5,3,0,0.058320,'Filing Grey','none'),
(4720,'entry','sf95cwt1CSFuAm5vChp2178Jqm7uswyWStngxHQ7mbMV',6,0,7,0,0.039840,'Manila','none'),
(4721,'entry','AdVaiRyCzAaFUTYaM9ZchtuVt2J29ZuTwnWYhuMGwMzu',4,7,3,8,0.026800,'Drywall','none'),
(4722,'entry','2RcKZGM1mg4WiSSq1cjX62JkqTMPc4JYffpEd4toQSL5',6,7,1,3,0.038640,'Cubicle Slate','none'),
(4723,'entry','V9VxDEwQmxJA6sypfonhd1xjAaeDfDR8seBYys69aLcN',5,3,3,9,0.041540,'Breakroom Sage','none'),
(4724,'entry','DQTTioTj1sooHPrTrC8xdasCqWUiHxxBBLF4Lz3CwqWP',2,1,6,3,0.027720,'Toner Dust','none'),
(4725,'entry','yiLm2FuRrXarHe1Q5m7xncacEH4W2wufnjX6rV7ey7uJ',6,0,1,6,0.052650,'Cubicle Slate','none'),
(4726,'entry','45SfnXhYZdW1ooHiQmzfWDk5NwJpXb14AMFSAHjvyWe2',4,2,1,3,0.056280,'Toner Dust','none'),
(4727,'entry','h623MUAEshCB38vhSNuW83JgvdU3FaRbgs5dGCPn58Mh',2,3,0,4,0.028520,'Toner Dust','none'),
(4728,'entry','cxojq7SP75yRQqgY9NWSqSBw1ZxDiNn8oYCqSxdHU1hL',7,7,0,0,0.024000,'Breakroom Sage','none'),
(4729,'entry','6Q42esSVNU5HDesqqux48aqWod1tR9JG6ox5G2cWRnCP',0,3,2,6,0.040120,'Toner Dust','none'),
(4730,'entry','NgriVtQATon2gh8XK9vQtiLcjFTRYRzq6CbSMfsnpRjU',7,4,4,6,0.034320,'Filing Grey','none'),
(4731,'entry','H1oGAiz6WoVpTHCTvp6xB2dpNsKHgvpm9YneZfJW8UA7',0,0,7,6,0.038180,'Ledger Green','none'),
(4732,'entry','jcM8GorhWii8N6ohN2PST2fV3aT3Lh88aqHosNeSmxUw',2,0,3,7,0.040480,'Ledger Green','none'),
(4733,'entry','HC6cT5vHq3QACxY6pgC5xCWUZgYnasP3uGjMfcqXWcej',7,5,3,2,0.047840,'Drywall','none'),
(4734,'entry','GFnnshTHNBqG8ngp4nU5Qx2Gp6LEXgA3r6eRGRcytpBs',0,1,5,7,0.035600,'Breakroom Sage','none'),
(4735,'entry','973xkgRH2JYBDmtzU4Xgpxp6RWcWA9Eoxz5eEkTTJTBf',4,4,5,0,0.038400,'Cubicle Slate','none'),
(4736,'entry','1Fqh19SMkKjR9hNUkLPx2aZH8aq6pTLfxWq1DDfrqM36',2,2,7,8,0.039160,'Breakroom Sage','none'),
(4737,'entry','xFoYN7922dEicm9S8321KRTBSWdBh7CEPYrYfHgoPNbR',4,4,1,0,0.025600,'Toner Dust','none'),
(4738,'entry','wgbS8UQ5cntnACFQgpmYNFidSnKoarj2acRhjGDTRpUy',2,2,5,9,0.028400,'Toner Dust','none'),
(4739,'entry','YkHcr7YnYmABbDebCc8oWFa5Ymmp7Hur2EbSpAi1fXq6',5,1,5,3,0.059850,'Ledger Green','none'),
(4740,'entry','4nzBFSN7bZjzhp5doY3iokkBcdzoN48jLskvmWt9YMuB',4,1,7,0,0.031680,'Filing Grey','none'),
(4741,'entry','YDCBBvLswDnKJRkyG9pTVeaTTfmjbDiPcmz4ZEKeSqDS',1,2,4,0,0.037440,'Toner Dust','none'),
(4742,'entry','E13sCFaGjvrydLDaG9bdnN4fC1Bu8RTxHp6fbbx6zqfd',5,9,4,7,0.031240,'Cubicle Slate','none'),
(4743,'entry','oDuSE8ts8CsCaQpzAV4LqYmNiHLGBd7EtostktbSAEcf',1,6,7,3,0.035520,'Cubicle Slate','none'),
(4744,'entry','Nxz652xLgk9gp4y4owHEFuBhY6o78y48HGJvNWtzbbQ9',5,3,2,3,0.039200,'Breakroom Sage','none'),
(4745,'entry','jGCaV3mvFBJSaR3ZW1BCiBakDJicz5811j12kFXQkaKx',0,1,2,8,0.034760,'Toner Dust','none'),
(4746,'entry','Pry8xpudjM7Jf8QvTg3LodxDfmP8k1fFCcFbF3syUWJb',3,6,7,2,0.022400,'Ledger Green','none'),
(4747,'entry','oM6bBasesg1ESsTuwFkWVTHLm7NRYR9T7GHpntD1m2Q9',4,6,3,0,0.043660,'Ledger Green','none'),
(4748,'entry','behJenB2UKybErsGyzRfx7uL6BSWyCLZgwmgT4ZgnjRf',7,7,6,6,0.025600,'Ledger Green','none'),
(4749,'entry','xRKwnabBfgTu95chrtn4TMnTMMn4B2z9tHzqQyQiR7bW',2,4,1,5,0.051660,'Breakroom Sage','none'),
(4750,'entry','Jn9W9wJXqAe4a6CDbPGhC4HvQjZLX5MkF1921HHAa35y',1,8,4,7,0.024400,'Filing Grey','none'),
(4751,'entry','bJrtgFwb8P2nDvRFDSw3d4Dx7PSu472HCK77WZCzLxGL',6,8,5,0,0.027840,'Drywall','none'),
(4752,'entry','DWsNr9cJzDBFyDQasbvQfWgHbBxk8FkEdRnK6w5u5bkz',6,8,4,8,0.079380,'Ledger Green','none'),
(4753,'entry','GcNWbN7xUyvHoLjDjQzwcxGfyjwBqVXR8akM2pTqG6GM',1,0,0,4,0.048140,'Ledger Green','none'),
(4754,'entry','Ln9G16iP2gtPnywU8R6obWKekAHzxf5b8L2H5KCX1Rzu',3,5,0,6,0.053460,'Manila','none'),
(4755,'entry','dYgp35ezqXKZaSis6YkQqmiZEEbfZrUBrqicKWQBycXp',2,5,6,6,0.034320,'Ledger Green','none'),
(4756,'entry','dM9cmcBx3fYDXRQypHuLtPfdZKKKgKm25Sp2fjwaQd1s',6,7,5,0,0.069580,'Cubicle Slate','none'),
(4757,'entry','9HNMYQXmdSCe1UfVcJy8YGFxUNamiVHgxh4iAhVmLxVL',4,7,3,5,0.061640,'Breakroom Sage','none'),
(4758,'entry','MaWM6fAjPRuwqHCm1LsJP26SrLweFnrY3BqDwpr8U3SV',4,6,3,0,0.042680,'Manila','none'),
(4759,'entry','5tNooaYvGFKej3zB9QvLpAfmxhFRZRvjZkYDgFsqkZXy',6,4,1,0,0.033800,'Drywall','none'),
(4760,'entry','Ri72eUxwYrjwpJBCdjg6AWPD2W8UZ5hdPo6cADE9CXr1',4,9,2,8,0.028160,'Ledger Green','none'),
(4761,'entry','8EjM7UYrvZXv8stBpLYpY3x14EU6bNiXnQzA9R5D5UMp',1,2,3,5,0.051660,'Ledger Green','none'),
(4762,'entry','vNR851XKTq2hjgfgzMeWcwTq85jVj6JodNBdaFTPp54s',3,1,0,0,0.038400,'Cubicle Slate','none'),
(4763,'entry','sYfK3bNWCsTxUeud6GoPn5g6M6hHhucdgkB7qGoat3vH',5,6,4,4,0.060750,'Ledger Green','none'),
(4764,'entry','sJWADUyVHZm9pqEG7y4Us2Gj9smKnkVenBLEHC2vFhkF',7,7,0,3,0.021760,'Toner Dust','none'),
(4765,'entry','JnCF5ZE5rNYWtff2f7v26aNkYc3j8sJZnomYrna9J69b',3,5,2,3,0.040560,'Toner Dust','none'),
(4766,'entry','yLasy4sSwqqnXC2MkNu3GziBfoVhkgj1NfhiuUhFdv7o',0,6,4,6,0.052540,'Manila','none'),
(4767,'entry','27XzwmJoDEqq3GkG9P5TEuEkrCizoEFdDHovPiRZCzJh',1,2,4,6,0.036080,'Manila','none'),
(4768,'entry','6zXTzzZzjqjCUekUtQ3NGRkvkRjZBcsZGoCDgcgpXuYY',1,5,1,2,0.046080,'Manila','none'),
(4769,'entry','5SwCZWjLamJbRZouCMR6LfLoEuPcF3VAYKbBxGSw6AdF',4,7,5,8,0.065610,'Cubicle Slate','none'),
(4770,'entry','Lv8r8VqnqirpyeBJgJCVmb8Qm39p6Y5CxYTyVprEsVrY',5,3,0,9,0.027840,'Breakroom Sage','none'),
(4771,'entry','fBf2j3dBd4bqnSWVkV5VzDuFFmpdqZk5hcomEpzNfw4d',1,5,3,7,0.045820,'Toner Dust','none'),
(4772,'entry','w6fWbLiaMFuHvmQq4BoH2JazPWsyB3Mr3Z3N2fCTifXZ',5,0,7,9,0.026000,'Manila','none'),
(4773,'entry','ZHRV56DSXgxHqUTj4nSSk1SKX3Bk5e2VJvzP3JDnok3c',0,4,2,0,0.032000,'Manila','none'),
(4774,'entry','joTyxiX5kyFdR3T2uCPTWwXrzv5AYtbfxRUMuMrAk5kx',4,2,7,0,0.070290,'Ledger Green','none'),
(4775,'entry','3VVoND4SVBTBYxKRhDyxB9krM2bweEhfeaG9onu4yp4k',5,9,4,7,0.051480,'Cubicle Slate','none'),
(4776,'entry','tKK7boJF7UR2Z4cBprURnzfwEyE46CPt1G6kwcpsHPw6',3,7,0,5,0.032400,'Toner Dust','none'),
(4777,'entry','YnNhKdW6oxcQaNYe1PkBpmpkSEwt8P6x4yEuSBcKRAKR',0,0,3,3,0.124740,'Breakroom Sage','none'),
(4778,'entry','7xU8DQW6t6rgmA19mZGGDunqY9oMLUugrfTbFHrCEa4z',2,9,0,9,0.051480,'Drywall','none'),
(4779,'entry','16bznNHfzf952TLv6CqNaYp3p4RU4Dutdd8vbgAQHoJG',1,0,1,6,0.049400,'Drywall','none'),
(4780,'entry','jz8dLFQdZ7GTEaPWEhgt6wkTZ5Ja1ZaKX4wGD3c87kmS',6,4,4,7,0.031680,'Toner Dust','none'),
(4781,'entry','9Rqco5tueXepwo5Wj2DrLSRhGqTNTaNWtfNSoYQhZWmY',7,9,4,7,0.037920,'Ledger Green','none'),
(4782,'entry','2wnginpKbS3aoQgA4qjhg3tfCoXVKzZK6vp5onbA8mnz',4,0,5,3,0.080640,'Ledger Green','none'),
(4783,'entry','pYgeq6nKT6hM7dPQFrnmzpJtrtXCgiDQuyShMvY9Az2s',4,0,3,0,0.046560,'Ledger Green','none'),
(4784,'entry','Y9xkyCL3f719yQwruYHxG2ZzzEQu9HbwwGakcM359y4p',7,2,4,4,0.030720,'Breakroom Sage','none'),
(4785,'entry','epHNeNTEXrba9ju8GNFM62V81qHeuqd5jY59wgphCtnH',3,6,5,5,0.023360,'Toner Dust','none'),
(4786,'entry','noGYcfTJmsXvKsj3wtkkkpr3XrrnJF5EMf3bHQCq8yH8',7,2,7,7,0.025200,'Breakroom Sage','none'),
(4787,'entry','nYiZq2Uj9YoMUzxSCnyCw9W85wpSxt7JMPG26Uzj1hjm',1,6,7,2,0.037260,'Cubicle Slate','none'),
(4788,'entry','Qq6uJNGkRHwYXTuwP6A9GWtGaiyeqfKL7YroVoaLVyiu',0,4,4,4,0.028980,'Cubicle Slate','none'),
(4789,'entry','TNnxAxnuADQHNAuwdU68rzsHLkpEEcBebRpu3cnNU4pU',0,9,3,4,0.061420,'Toner Dust','none'),
(4790,'entry','tnzEPYsNsKP7qTojtzk6wrvFCchYMGaCPit6xgv6BLbF',7,4,0,2,0.037960,'Drywall','none'),
(4791,'entry','wU6YqrBd5kkVMHg3unf9nHS818DMiTmPr29dZJG1aben',3,8,3,0,0.035380,'Breakroom Sage','none'),
(4792,'entry','PhnJf5Hk6nJHiY39zxURAPdyMhNHBM5A6EvWsje2HWdS',5,2,2,5,0.071000,'Ledger Green','none'),
(4793,'entry','sS2oVPgaGmRs3DQwLBi7wjZ2soeKddGJkzwQqH2p22R1',0,7,7,0,0.056070,'Ledger Green','none'),
(4794,'entry','2s3JbmGNwiqqPTGTpu44H8DqvMM5oNhE5t935s4QsPso',5,2,0,4,0.038350,'Ledger Green','none'),
(4795,'entry','9Jr6mw27qU5Dp9yFAGLK9fCvUoSp3D2fuH65N9dBzoDD',2,0,6,0,0.024000,'Filing Grey','none'),
(4796,'entry','WMc3A2mAKnK3L3kmGWw6ZLznxkRE7s29myW4SKjAjnBV',4,3,3,8,0.046020,'Breakroom Sage','none'),
(4797,'entry','pRxJwmDzc9szVjgPi19N4E9zVaP54b3tJwDAg2ngNBWc',1,8,3,2,0.022080,'Breakroom Sage','none'),
(4798,'entry','pCWXABLWQYpJKv1phHucNhWYxpk5p7fY9jkZfcLqjn4D',3,9,0,0,0.045140,'Manila','none'),
(4799,'entry','iRPW7YYrGfzdquTY6XQKrCDc9vZ8Z7p3XnWy4VceZFeB',2,8,2,6,0.048100,'Breakroom Sage','none'),
(4800,'entry','48iRgzFBtboTvXT4goFbBo1C9LMm6Nj8TiCrfogeiaFL',6,0,1,7,0.091080,'Manila','none'),
(4801,'entry','xpn7P6zhVhfAkpDW2fhnSWsXZNmckcsJxpfV6zoKArjH',1,5,6,5,0.027200,'Manila','none'),
(4802,'entry','iJsbXH1BCmG8Fe9UBUKYqjmhe8qRh6NTfwLcpfU55Suh',7,2,4,3,0.068080,'Cubicle Slate','none'),
(4803,'entry','nrPE1GAoYUAkc5UrEx4EsFefEHZLuQQ3TH3DNLDDKSWZ',4,3,4,2,0.050460,'Filing Grey','none'),
(4804,'entry','GstYGFGSkj9RvqUuhDyin5EsWSB7jkUYcnUXw8fWxMBx',5,7,6,3,0.044840,'Breakroom Sage','none'),
(4805,'entry','yzwfiHk7K6UTr9ecebdHWULZ1BuqyTQ69gA1YbvhjEcw',0,2,6,6,0.028000,'Drywall','none'),
(4806,'entry','6JBa3M93p2UyGAJtrmtBhNWgDt31SquBoAJD9UpiBCwm',0,1,3,7,0.026400,'Drywall','none'),
(4807,'entry','FxUzJLvox36XgdKa2YNCVdBqohDAoyptctUsL6Lt49kV',5,8,4,5,0.064610,'Breakroom Sage','none'),
(4808,'entry','Cuinzd7mCX5SCZ5YkhFuUH3RmnWNEW3UXQxZ6xhymfiP',2,2,2,8,0.058320,'Filing Grey','none'),
(4809,'entry','pPibffZbWQQJNnxwtXhZanW7XMk7JQDDZtwxvfKFjdVG',6,4,1,9,0.055100,'Toner Dust','none'),
(4810,'entry','PRqHCpyw3x4js6bn8s5VzC7Hko8WiRSJu3vPC6nB9ZYg',2,0,6,5,0.041600,'Drywall','none'),
(4811,'entry','AiC8y1snFKGhb1vdd1ncCcM9kNC6W7xc7VSf8wC2xL67',6,4,7,7,0.054520,'Ledger Green','none'),
(4812,'entry','mcNqyBLpuQ1toTHUzDAiQd8wXFNPtoJtipoGQJ7t4fau',3,1,6,0,0.042680,'Ledger Green','none'),
(4813,'entry','khsWMBPNjdEKATqhBQGWMsBBHNEfcsnXPHq1BHhaTrKN',5,5,3,2,0.064380,'Breakroom Sage','none'),
(4814,'entry','qhsPj9cAj3n8RrC2M23pxwwMaHr1ADvyeGpF1fZzQxPo',3,0,5,0,0.046080,'Manila','none'),
(4815,'entry','wxt9vgbF1334fFanynwriyaZz3G5ED2b1rcmE4WtuouY',7,7,1,5,0.033120,'Breakroom Sage','none'),
(4816,'entry','7jEyjJovSnToz48R1poQVGXmnL2VNmkGB26JnAccYV8c',3,8,7,4,0.054280,'Toner Dust','none'),
(4817,'entry','wEnyJYbcHgCCSj2DvcLVhnBXjXBdqHiU6QtFz5FVtEwT',1,7,2,8,0.065860,'Ledger Green','none'),
(4818,'entry','pcW4999TT8XmZba1uCoSm2aJtJz2r5HBxaxiGGY3Wk3a',1,5,4,8,0.052930,'Manila','none'),
(4819,'entry','mtmg11LBWDC28c67iuct5mJB69q6caSig8CdhoEGVKRm',4,2,7,5,0.059130,'Filing Grey','none'),
(4820,'entry','anz4LKneVWpiQo7BvwDbRbkDboCEXHnnbqK9Jpdet6cV',1,0,3,9,0.079380,'Drywall','none'),
(4821,'entry','7BuimNBGW9Was9DRLy3oBfRKC1ggAGRcqjBcotWBwHSg',1,5,1,9,0.039160,'Breakroom Sage','none'),
(4822,'entry','t9GJuepywLBRxfRVFEoLbg4KhwFmbChT3qtPcdUWnRfK',3,4,3,7,0.026800,'Filing Grey','none'),
(4823,'entry','ERiG8D66XSKNziQyMdH7UPDFMt1MAyoVau23EL2nQe6s',5,3,7,4,0.034400,'Manila','none'),
(4824,'entry','gdg1hD7sxwHBigBz7Wg5QQy6KEYnARrnDzhv7sstkv88',1,4,0,3,0.038860,'Manila','none'),
(4825,'entry','64anZ7UXWvC7gnqCV5VuQXqVV1HoUzeebj8CSxhW3PLt',2,3,2,9,0.077760,'Filing Grey','none'),
(4826,'entry','zZH4vdUsmjqhQya83aj6TDzb8tnzzRiE7JRtru5Gtv4o',6,1,0,7,0.061420,'Ledger Green','none'),
(4827,'entry','W7d7kTUfPZn1DAnNM8bGJSQi5TypgFpM71LQQCa9dhsW',5,5,5,3,0.048000,'Ledger Green','none'),
(4828,'entry','svLgEHAvBPNCwduCHQfRFLAb4QwqEq74puCyG7JjTJmZ',6,7,6,2,0.063990,'Filing Grey','none'),
(4829,'entry','3AaddJey8w4Bh6ybF5Ce97vEE89h9R9LNJd48WRBB2SU',5,0,2,5,0.052290,'Filing Grey','none'),
(4830,'entry','iMLNpeUxzJr9nu1QHpCDVz8bt6k1mYkQbSBUcQhUg7Te',1,3,6,0,0.056120,'Toner Dust','none'),
(4831,'entry','pWrQbgPctTj2VJc2Fgv2s2hz3Mbp8QxgmKSXMhy4XERS',1,4,5,2,0.025600,'Filing Grey','none'),
(4832,'entry','2bQ3utEca82AgtgfWhJLFUVVSsaSCEAXCEqnhUHSJsiQ',1,1,7,9,0.041890,'Filing Grey','none'),
(4833,'entry','ukSpArUSsJuXYWhMUvAj1Rh156RtiZiDkDfvFhv91Goy',6,5,4,0,0.046620,'Manila','none'),
(4834,'entry','joUJwtPbravDxh6ZZcD1jncsS9YiyJGq83oniCVsiT4q',7,8,4,5,0.051620,'Ledger Green','none'),
(4835,'entry','3UUNBDutPTABAQbHnocYWBDQkKijxjYUCtAndGzwy9Vv',4,8,6,9,0.071040,'Ledger Green','none'),
(4836,'entry','8ZRSSXW3yM738EsVy2wCSUurK4PpXnzf6Mfa7RwuDYhj',4,0,5,0,0.067230,'Manila','none'),
(4837,'entry','4oPKzmsBW36zB8En7VTJrqiEdkdae4eE8RkWNnMfGBz4',7,4,6,3,0.060350,'Manila','none'),
(4838,'entry','qLeNzYfsR1PsW5hRBxwEWpbGj9M8SoUtuJswhk7MetUx',2,9,2,8,0.044620,'Ledger Green','none'),
(4839,'entry','Wu25dqYZjfKkQDJKsJ6ake3A3HiyjnFfLMERpo91DgfC',7,8,4,5,0.056260,'Filing Grey','none'),
(4840,'entry','m2xVCGac3H9doFJGTVBsF5sa1WPqypao4nqbqYFbU8zn',0,3,7,7,0.051120,'Cubicle Slate','none'),
(4841,'entry','GYsMyMX2WzUpgEKYoc1rCYSr392CigLHVrZWchDtVVZE',5,0,0,8,0.038400,'Cubicle Slate','none'),
(4842,'entry','m4Gxi54zMoNBNXQc8S2Y3MUcnBFjXTxySWRk4JZrH8hR',5,3,7,8,0.029200,'Breakroom Sage','none'),
(4843,'entry','hcaF1C9Cwjih9KLx8ZNtp2WQKY8pX89mo7ZbA2TsKgbF',5,7,7,2,0.064800,'Filing Grey','none'),
(4844,'entry','Wyvjc7Kaq13sp2Zi76ZjCwRxzJ9t8JC8xQQtn51zu3gB',0,3,2,3,0.066240,'Manila','none'),
(4845,'entry','1BX112JAznDHyJCqXNNECm98zYtwE6BXf8EmpkJjBvfZ',3,3,6,8,0.112140,'Drywall','none'),
(4846,'entry','8m3D7qykho9MNFtTjhZkguNJCRFLsAFpGihhGQb7sjms',2,9,5,8,0.070840,'Drywall','none'),
(4847,'entry','W6V54PrCwpNR8Sz395eVdoD9Z7Pzok4nup8CvavboSNx',3,2,4,6,0.031740,'Filing Grey','none'),
(4848,'entry','Qmm1dgCVvdPsLkvfM5qSdvn5xhsZeyDKwyxKx1iHZdqx',7,3,7,2,0.040000,'Filing Grey','none'),
(4849,'entry','kbSUMbHD24BfxmKY2ts76xrmZfUgymMy3UWJt4v8CpQ8',0,8,5,4,0.040870,'Drywall','none'),
(4850,'entry','6PZjqvk6dbFY3kiGgnwzQSffrfWZVjLwUKgEMPhXrDvo',1,0,7,0,0.038860,'Drywall','none'),
(4851,'entry','UCEgUUEEm6Y49ETKHmztj9tuSUDJMmmiuVtgRNrexnX7',5,5,6,7,0.036520,'Filing Grey','none'),
(4852,'entry','NwUzTgrzudwmXiys6iuzyPJFLpwzWMcYKXYLa5G2Lnu4',2,4,2,7,0.054810,'Toner Dust','none'),
(4853,'entry','fpHAk7Jn264mYex6XRLHuSKyjTkvxcqd8PyfVuU6DX2c',0,5,2,0,0.060350,'Breakroom Sage','none'),
(4854,'entry','N347tNRuU4vkcYhH97hBXKJmNQJop5JwpkiGMqM6fCRT',3,1,1,0,0.028980,'Ledger Green','none'),
(4855,'entry','WoiugFPnDZcbSM5HyJniDT8wcsrfUPBawFKPEbq8fkhL',7,7,2,8,0.034760,'Cubicle Slate','none'),
(4856,'entry','mmWrKqtx1Xgav6KGxNk9rzgqeSH23T3tNq28KH1kJru3',3,1,5,9,0.024960,'Ledger Green','none'),
(4857,'entry','y4kkK9azRNU1Jzp3twcFUvAgk1SecXdzKG2j4AEtTPiF',7,3,0,0,0.056980,'Ledger Green','none'),
(4858,'entry','K3ZfPbydLmUAnwL2cRYnB1P98fZ2RF6sedvwdAegs696',2,1,5,7,0.100110,'Manila','none'),
(4859,'entry','jJqk1aRhGWR7dqoyCgvRRwsKrcJZyAgf5comCoritoAx',3,7,0,8,0.044200,'Ledger Green','none'),
(4860,'entry','pgXLfKtxmZDk9TePohqGGdWXdpytCJZFoC3WoRWufWY6',4,1,2,6,0.051660,'Drywall','none'),
(4861,'entry','FWkJ4WSSiqr3SFU16tHH5MuEwsMpzXEUQyfNY7PQ3QwG',1,1,4,3,0.040320,'Filing Grey','none'),
(4862,'entry','dov4Bf6WwSrdbGjXEFEDkjUWdTpR9QKXfihtNavCBkb4',4,2,2,0,0.050150,'Toner Dust','none'),
(4863,'entry','iDbKsEg59j2MwUXVmdMQXbVCEoJGApKQQLSPCAYwqfCq',2,4,5,0,0.036000,'Manila','none'),
(4864,'entry','24KR7LPxKj5hV6hhjVUHPWbdNfLa1GRm3zDZ5X93Ef6p',7,3,6,8,0.067000,'Manila','none'),
(4865,'entry','8aV4KjmpKMnVsWqvPE8SVTJwYFmN2uqpN9fDiPh441XK',3,8,6,3,0.032200,'Manila','none'),
(4866,'entry','z5LPsuRKRbtnZMcKwTKoKisG4YDCyyJT2UVduJuXpNvC',5,4,3,8,0.049560,'Filing Grey','none'),
(4867,'entry','TGX5XnjXB8wU9YV3pb1Xp164Bhzkup6r8bmsGCuh1UcW',2,5,5,5,0.049700,'Cubicle Slate','none'),
(4868,'entry','gu5qr8Crs1RkEzHm8BMf4w5C7cNtvbj8M6u1DhMZcWQa',6,6,6,2,0.049400,'Drywall','none'),
(4869,'entry','JrAurjba6ciM5hjpyfs9waaL1Xq3vv4HjjAhiLxp5yLg',7,6,7,6,0.056120,'Manila','none'),
(4870,'entry','85zGCEjnzUZgKKEmi1Haq9uRRPWGDFU5EcsEtrwKy7Jo',7,0,5,3,0.061560,'Filing Grey','none'),
(4871,'entry','aEQ4RQYE7BSrMAS9WKFbRimdPPu3TVRKYcDTXWwdj8gi',6,2,4,4,0.041800,'Drywall','none'),
(4872,'entry','XBGt8BkFhHLudbs9JYHypyHpeZxYpn9nGHJsQXFM6VVm',5,3,6,8,0.036480,'Ledger Green','none'),
(4873,'entry','Fy2Nw1arqewNKovZMQwHafmBJbvMfcY45gzYidrTF4FL',0,0,1,0,0.067450,'Toner Dust','none'),
(4874,'entry','tWxzFQ5mJVtHbez5hmLwAvbTVUzupktQdeeXahHXCHey',4,7,2,0,0.095880,'Drywall','none'),
(4875,'entry','TtHcRe84kjQawPSdcS1RAjoadqu4shzysyKDdEp8nc9o',2,8,2,4,0.026400,'Toner Dust','none'),
(4876,'entry','ubaXJHbRmisP65wKqSQBWFsEtGdAUcgGv1zffGPfBJoG',4,4,7,0,0.029760,'Ledger Green','none'),
(4877,'entry','cuoBdSESEZTC8XUA9TwUJ4pu2akzCZn36C96ZjwNfnoF',2,1,4,6,0.030800,'Drywall','none'),
(4878,'entry','AMX6fcAqJvQdpiwxJMjsusLdtPpBbTV2JrAe5zXu5ytG',2,1,5,6,0.046620,'Manila','none'),
(4879,'entry','Lv6zBmk4U6cVQoy7QRQMj6cFq4VCwNXQDa6Q1QfQC646',3,9,6,9,0.113400,'Drywall','none'),
(4880,'entry','uk7naQX6bHxBpWNfcx9HhaUzfChrvVoqfQxXZfviDcHK',0,1,1,6,0.064380,'Ledger Green','none'),
(4881,'entry','jLK78L6CjDrHecT2a8t7scW82fsPhUDmA43RgmnzEkEz',1,2,7,5,0.063000,'Breakroom Sage','none'),
(4882,'entry','yNLJKNw4aB5gPJR6fetrNhDkq8yAjB4V5aBNRcUGX965',3,6,6,6,0.035200,'Drywall','none'),
(4883,'entry','AZCMt2o3RmVZ1VmU1AZw6RZHqwgRL9scxCNAncGru8uW',3,8,0,9,0.076140,'Filing Grey','none'),
(4884,'entry','JGMb1C9w7cvM1AvX3pmtBfZ1Lt1WqKVe3ZxsWrHMpRo3',2,3,3,4,0.042240,'Cubicle Slate','none'),
(4885,'entry','79GDBwfXb7Ngib37vUzS9uV2mBcagLUnQzXwkRjNymJW',0,1,0,7,0.081000,'Manila','none'),
(4886,'entry','2Ve3bSHB8Lm77ifcHgT4qUKKT5VCePNvLECxS7SetbzY',1,2,0,6,0.055380,'Ledger Green','none'),
(4887,'entry','TTfuxVE2oA26L1kiSCzEaX7nWn1q7B44ErDBWTvkNPcd',6,5,6,5,0.031280,'Manila','none'),
(4888,'entry','zfbN8jb272ktb2aMnMskvKnEsVyj63sPexGNQqtJW6Qp',4,0,0,5,0.039200,'Cubicle Slate','none'),
(4889,'entry','BXxsCLuNNNy6L6HRFupNvLFbMFEaPsuJJUNyQiUa6LMg',3,9,5,7,0.057960,'Cubicle Slate','none'),
(4890,'entry','RxT7okzquGZfubHmaQhYpubW5Ec6EW1DL3MPJCZgRN8T',6,4,1,9,0.051830,'Ledger Green','none'),
(4891,'entry','XPPDW4pG1JxswQ1M9bq5gcBHSNmaeQPftvVcSunWhCFv',1,3,5,4,0.041600,'Cubicle Slate','none'),
(4892,'entry','CWawKbXHCsfhWWy62xafszCLQHbzVYL3Gx9ZeTSDmsS9',5,5,6,9,0.033600,'Cubicle Slate','none'),
(4893,'entry','Bx8XPScK8kZem92MfYUWAPraxuKvRoFCL85jZS1ieRT1',6,7,1,4,0.042720,'Toner Dust','none'),
(4894,'entry','kvz18Qh9d3t2GbYEsn4jdb8irM8Y74swUAoveDZJG9H7',6,3,5,4,0.028400,'Filing Grey','none'),
(4895,'entry','VPPieuSV7h4xS31EXVUMPtKGPsBZPBxNDh5QHUsoqpgD',0,4,7,6,0.020480,'Toner Dust','none'),
(4896,'entry','AtNmPR4QuDo5CmYmm6SouJKxqTvTu88M1iVDf1oAwQcx',4,1,1,3,0.046280,'Breakroom Sage','none'),
(4897,'entry','RJ7rh8aWTnuXbDe3XDcaeE3uejAX9JnXx242uyEfg4NQ',5,7,5,3,0.038640,'Filing Grey','none'),
(4898,'entry','YPx5pd1pAWTm4oRrKJ86bFa6UJzkkH6tezctV4t5hNxa',1,5,3,0,0.045560,'Cubicle Slate','none'),
(4899,'entry','YxRni98xuHdfyiPCw88hwBP8H9qnLcb3wMMRGK6uBLoM',3,5,0,7,0.029920,'Filing Grey','none'),
(4900,'entry','mpWTFrwCS4yHGFqhFrN4RFdL6ykhicyk7pCuvWR51Mm5',3,8,1,0,0.089240,'Breakroom Sage','none'),
(4901,'entry','Xo2AhYatXwDe7CSunRinTygcVC2e4ivkP7c6Ezje9RcR',4,4,2,0,0.036960,'Cubicle Slate','none'),
(4902,'entry','DhiQUYezN9jZR8VaiWa3up215iC3unkJGftvcEmiZsfY',2,4,1,0,0.052000,'Breakroom Sage','none'),
(4903,'entry','BkhDwHBLZmNZwyAqNUAaqLqjib9dWxc3b5jD2HbtxMxu',4,7,1,8,0.059640,'Toner Dust','none'),
(4904,'entry','yc1gg2tCtYK4J3EYMx6H7siJg6154vtAGHJ38tPAyqkJ',6,0,2,8,0.059130,'Breakroom Sage','none'),
(4905,'entry','kfSDCkM7WWnvJPdHonUizwcyQVUTidsLzCn6qrKbSkbh',3,6,4,0,0.072090,'Ledger Green','none'),
(4906,'entry','wwtnNLBtXse1g9gRvx691v1BgWxRWSuAVjzQnFr4V5HE',0,3,4,3,0.051660,'Drywall','none'),
(4907,'entry','RRBhEmA1a2s7TRD9G2FBo5WM2Ao3StBDgG8X9QC3NCaN',4,5,4,4,0.040120,'Breakroom Sage','none'),
(4908,'entry','ohv2dt9HiqELDiRB2FxSr5Gasq2Q7TJwJEkTANrVvy2v',2,3,7,0,0.027720,'Breakroom Sage','none'),
(4909,'entry','QamH7kLNEmhUEPCnJrdPm1fuSH1Hrn3HmZKxE974g846',5,4,0,0,0.043070,'Ledger Green','none'),
(4910,'entry','xeNEzRXsWCV8xH8NaAkZDuLRZhmNTMS7vzi1A9tTA1VN',4,1,6,6,0.069660,'Ledger Green','none'),
(4911,'entry','1G6hjxLPErWjaELooVdfPBy1jDcsKnjwLv2BMo9GJELC',0,4,4,0,0.048720,'Ledger Green','none'),
(4912,'entry','f4NBcSqEoNbceSimQn3dFVsVRuTa9thVBmvKafdSfzrd',3,1,2,0,0.037960,'Manila','none'),
(4913,'entry','1ttNgoEcWzZ9Zi1mYvnZf6kZFrLH96uhkFhjkn3MPwi1',0,1,5,8,0.059630,'Drywall','none'),
(4914,'entry','DzR77WrHkKWaj5iqwWuhSxuBMciUAttd9mrXEYtqTKEE',4,1,5,3,0.053460,'Manila','none'),
(4915,'entry','NkEkL3ogCvpaNgZSCkPCNStZgRRpy6uDyu18eKNVFLDS',0,0,3,6,0.033880,'Ledger Green','none'),
(4916,'entry','xQtSoRbr9jhrG5xHoahsrfGnZAPcqpShyJDpvnAyiwrn',6,0,1,6,0.056980,'Ledger Green','none'),
(4917,'entry','nRAfP1ym1WPmBjunGCZkDyFrKSuBiTQDuXt7rxAZmipq',7,9,1,0,0.088200,'Breakroom Sage','none'),
(4918,'entry','EVgngS4s3xhdeA4MkB2aT1xNUwBaRU4UQm15j7BTWoy8',4,4,5,8,0.064380,'Manila','none'),
(4919,'entry','d8Th1mxpnRdmKm2ddi9tVPRKw45gmbQnZ7uDpEDBnmkb',3,9,3,8,0.042240,'Cubicle Slate','none'),
(4920,'entry','GXAqDkh3HAyrqEHNPRz1F43eLacxjgzQ3rquS5615er2',3,2,4,3,0.028600,'Toner Dust','none'),
(4921,'entry','98TTXY6dgtFfCWo6NRNZwr8tMUqbEPyDw3eq9z9A68ZD',1,0,0,4,0.022400,'Filing Grey','none'),
(4922,'entry','vMvzHu8DCB8FmewBrvYxMtWcmyZ6AFGe2sC3jKeesfyd',1,8,1,2,0.031680,'Drywall','none'),
(4923,'entry','UdmPc9r3MYgAW2AV9Mj49bCAK2rpYJyNGzzEmLzBLZgQ',5,3,5,3,0.032120,'Toner Dust','none'),
(4924,'entry','Xtb8NPnzcDPiYAY65c46PinZf95pibAQHZNtEvdSJsG3',1,0,4,0,0.034080,'Toner Dust','none'),
(4925,'entry','SRRRmwXBcRswt6oVNH8ohs4qqyMVNG1e7M5WZXnDbWEB',4,7,5,9,0.047880,'Filing Grey','none'),
(4926,'entry','AzrR9bmQ3WaDog3Dtt13RV2ZqN36XYyk9t46PHoPh15r',3,0,1,0,0.042680,'Manila','none'),
(4927,'entry','HARzVsbNs5e5BTfYqcZsR4wj8KzRi5X14XM3bEf4Hchx',6,2,5,5,0.039200,'Manila','none'),
(4928,'entry','5nQXvzvEMWAiTxPWJdkqV1mrbpK34zH3xhWDonrXHXXd',6,5,6,9,0.049920,'Ledger Green','none'),
(4929,'entry','PVMbn2mmYsXWCp1iPiqziBUR3ddVZGk2UdDPcrK4rqyD',1,8,1,2,0.043200,'Toner Dust','none'),
(4930,'entry','bJBzwsTTGer8eJYYkonA6AB2qrWRsAaqRfiBr2NUzNs2',4,9,5,8,0.044660,'Filing Grey','none'),
(4931,'entry','xNLJBC97fpBDuxLHQRqvfbi2TMoJH3e4e26qsPC32UBj',7,7,6,4,0.054280,'Ledger Green','none'),
(4932,'entry','zu9H9F46exfpKKG45ZtNvWVw68SB91TDAnDXPRAkmDHw',5,7,7,0,0.051830,'Filing Grey','none'),
(4933,'entry','ea7L5y1v9m8EoCgbv1MKxPRx5dUNQ5yLCubMur78K2HP',7,6,3,2,0.024000,'Drywall','none'),
(4934,'entry','8HwLmJnGTkUzRdWMZRsj9BqzF3G9yLpziSFbAF3rKF9A',4,1,4,9,0.069580,'Manila','none'),
(4935,'entry','9qthXYo1xgdpm1tsPjJkRLkxiToC13xwmCEvmRaMoVQ5',5,3,3,0,0.074000,'Drywall','none'),
(4936,'entry','JsRDWzyM3DNonDrvAmx6PGX3z32E25xW6vM8NcV4UyHQ',6,0,3,6,0.043700,'Ledger Green','none'),
(4937,'entry','KQZmTHSn6tn7giomi7MerQTijSoWLX7agvScaWe45qfS',2,1,0,3,0.035600,'Ledger Green','none'),
(4938,'entry','8HHisf2pLenAiK474YJJiWATdTsw4egUqQv7tqegAp4E',1,7,7,7,0.058000,'Manila','none'),
(4939,'entry','fMgs5RxtYsqoXRWMaQPW2pZopHFeKEAwjhWY73c2ofSP',1,8,6,5,0.039440,'Cubicle Slate','none'),
(4940,'entry','ZeCWVuuJCVqB8KtjL5EXxw45HWtbYFqps9FpwTzuuuJH',5,4,2,7,0.067450,'Filing Grey','none'),
(4941,'entry','VWQYj5CXr19eXLveLKXEXP3S9MfFiXdWexSGywYxLGH9',3,1,7,2,0.065120,'Filing Grey','none'),
(4942,'entry','GbhTvEaKQbb7AnQmQX8FUdAR3nFkQbo3bduD92tsbxEj',4,2,2,3,0.045240,'Filing Grey','none'),
(4943,'entry','dapvr2D1ipKuduy3No3pN9UU8T658uADeGcaAB9wuU3Y',5,0,0,5,0.032240,'Toner Dust','none'),
(4944,'entry','Z5gC8KgH66qRmxDRGSRA5oKFDP4iLtNQmwVuEZ5jZiuL',5,7,5,3,0.034400,'Filing Grey','none'),
(4945,'entry','fqqq2KjZyYqdGwkCnkWRNb8iKJcs6233ptnacg6z5Xqm',3,1,0,3,0.023040,'Toner Dust','none'),
(4946,'entry','1UqPT1qNVrQN3zFKAbjyii8yMhENq39J54cUrheXbwwe',1,1,7,9,0.074520,'Toner Dust','none'),
(4947,'entry','jfT64V5iS4FtheX9epGH7u1Me2rPg3MNVS1pznMFGc5b',5,1,4,4,0.062900,'Filing Grey','none'),
(4948,'entry','DfEZR2JVd7A5Q7CKqeRPsTe7FLZG7ECg5T9snzkGmMp9',4,2,2,7,0.061060,'Cubicle Slate','none'),
(4949,'entry','snzKRCx9nsZFvWxjzyebY7GaTPJpo6yzy41SzFHzfn7a',0,2,7,0,0.031600,'Manila','none'),
(4950,'entry','2j2GPCz9KaLPAQWZpFvmSXnu26xfW4tFBi2D87qa2vCH',4,5,0,9,0.054870,'Drywall','none'),
(4951,'entry','GuruGMjpQJ8YL7n9XcK1xQnxiec8Ei8NX8NiKd8i9mwe',6,3,5,9,0.033600,'Cubicle Slate','none'),
(4952,'entry','x7bBZucFF5TpjsasQrAHPPsHUskSJHMPMo3SXLPLwPaG',0,0,5,8,0.036960,'Drywall','none'),
(4953,'entry','gKnW5B56m9bxRgZC1sxw3QQcyd4WTRZykAUACLxYV89A',4,8,5,4,0.033120,'Breakroom Sage','none'),
(4954,'entry','LdSos9Bj1DjV8bLC3zi7kCY1dxquGaWcwKrjysJySKXX',1,6,7,0,0.028160,'Manila','none'),
(4955,'entry','CP4Kh4zW9eChcjCSrvq65nMP41nvPfrbva4pjVRtcB2j',1,5,0,0,0.050410,'Toner Dust','none'),
(4956,'entry','wk7u7XYHD6FTJYDCjyxvtLDg1vASxfuhDEifAG3brjz1',6,0,7,0,0.123480,'Cubicle Slate','none'),
(4957,'entry','63uvXbfkQKqqnsXLsUGE4WrLujzEBa4JbKcBWwjfQjWp',1,1,5,0,0.108360,'Breakroom Sage','none'),
(4958,'entry','gaRfakUYZNofcvFt8PhQyFnGrgy1fHJKavBNCZY2nuj3',7,1,5,0,0.054280,'Filing Grey','none'),
(4959,'entry','iYfxWMoFSf4iJw9gFYB897NPKwZVgmADpsPTwrucvQPs',0,2,5,4,0.025600,'Toner Dust','none'),
(4960,'entry','JBceNpSX8bynATX4cpcKq7MAhTPsoJ4UdZP2YgbphaBv',2,2,6,8,0.033440,'Toner Dust','none'),
(4961,'entry','6L5ReMA9vMyQXan5hE7ZMaJjYeMMozDAnGYky5Qiv9gK',3,6,5,0,0.040040,'Ledger Green','none'),
(4962,'entry','y5bcxktjFKrce98pQ97v1JiucvFKL6pzAABxVx1zAGFc',5,4,0,9,0.043120,'Cubicle Slate','none'),
(4963,'entry','8dpkcibUq4d2EEeTYfBanyBbvpXYZrnHnQ2jRnx4w8Ty',4,7,0,7,0.037600,'Filing Grey','none'),
(4964,'entry','qr3vsEjNWdg5zNpq41ZRHhiKtnME2yruWLJwnF9tNHcM',4,8,2,2,0.026880,'Cubicle Slate','none'),
(4965,'entry','7oPxr1PGZP16Aqzkty7RWQaj6sEGgJge83RawSTCCjAR',2,4,2,0,0.021760,'Ledger Green','none'),
(4966,'entry','Ra5pHv89WRbRY9rXVFcNxV4aWr4HeLjzZeqg2utCHNCZ',7,6,2,2,0.051830,'Ledger Green','none'),
(4967,'entry','Au9ZZ1fd3E4SWMn7ix2mCMv3aW6UnK1bKV6Cph75BWqq',7,6,1,3,0.052540,'Manila','none'),
(4968,'entry','TQLxb62eKWiKhr9cxJwGAei3KonM4a1wKQe2BcoQftsz',3,9,0,2,0.051620,'Cubicle Slate','none'),
(4969,'entry','YNuDKgSwE3xG6B4AK8EeH698sr7wBBXJ9TTu8kLXBH18',5,7,3,6,0.035640,'Manila','none'),
(4970,'entry','CyeFMd3NaoMxGs4aWSWeHD3R3yMBfYSRnZwDPwe6THnn',3,2,5,2,0.041080,'Drywall','none'),
(4971,'entry','YUaHF5AFmVGrpRoEJ6HCnESWUuaWSBZiKa4Vo76eRNa5',3,6,1,0,0.039840,'Toner Dust','none'),
(4972,'entry','eWC75RwU2ujQuL4C23yhVMB6QgdDP8bVCDNCkmsHzWER',5,5,7,0,0.060680,'Drywall','none'),
(4973,'entry','j53gFZbfYGVLKnkMm1mRn3t4V1KV2Ymovi8UvxsZC9fP',4,4,5,0,0.054280,'Manila','none'),
(4974,'entry','kT5ADveV8YdrDVyo2528VbtZ6rjq2NFx5Qc65mrVz63F',3,5,6,9,0.055500,'Drywall','none'),
(4975,'entry','CK9V2ai1nAMdT6kj1LSdREEHKArisxc7sQgGsnzw7hNR',0,9,5,2,0.036080,'Ledger Green','none'),
(4976,'entry','Bn8xQuiYAy6T9YMeyB2T1zAcgJCpZFXq9YWsJvLBM8vt',7,6,3,4,0.048910,'Toner Dust','none'),
(4977,'entry','f117BP7v9nkrYRqdfUNMZSC3PQaWiTGKRjKTs1Z3P3ea',7,3,7,9,0.054940,'Drywall','none'),
(4978,'entry','PtS7MATRhvdA7vRDs8iDLU2U5zyHad5F81feoDmNP2Fs',6,0,5,3,0.044160,'Filing Grey','none'),
(4979,'entry','SJkvuRRekv4JJirwhU7PrZvsvzxfNWe2eFX9c7emjwss',5,6,5,6,0.049770,'Breakroom Sage','none'),
(4980,'entry','nFyLDgN1FhTz54vm4DkXnvwnwy2WgeEpeVLZ7eS85Jbk',3,9,1,8,0.033200,'Toner Dust','none'),
(4981,'entry','xdwaqtd9C8FDh1PuMMVFj9ZnmJVp4pcS2YmNP8wuRKFK',7,7,7,3,0.049920,'Ledger Green','none'),
(4982,'entry','qEQKcftuTHdjeaBXdZJQ4ttoSMFsDpNxrk39VcdzsoA2',1,6,3,0,0.030400,'Cubicle Slate','none'),
(4983,'entry','xPVXW4SbjXA9DFQ7jRm5NL4MmJRqCci9nVEy424BMpEa',0,1,6,2,0.044160,'Cubicle Slate','none'),
(4984,'entry','JxgqeKQEaRDyncjNfQ1JVwqh568wUUodZ2QzJNfSbPzN',7,4,4,2,0.032200,'Manila','none'),
(4985,'entry','v3Lghn2TDKrYzAnsKCfwBjWgMma9oKwwNNCPEGygT3yW',7,6,6,8,0.053550,'Toner Dust','none'),
(4986,'entry','yRnq4Ean53nD7LGtbHpCvX1kGP5EdDFQLgqXGJbARXA1',6,7,1,9,0.104340,'Cubicle Slate','none'),
(4987,'entry','NnWFABy3bV2RJw34omkzMWf6v2nvJCe2rrmbXzKM8kmv',3,8,4,3,0.043470,'Filing Grey','none'),
(4988,'entry','wAwT84AxvUTNruengbG6LkxF4DWgCVN7S4Q4drLDUvkw',7,2,2,0,0.049140,'Drywall','none'),
(4989,'entry','Wwdbx9QgEyf88JNBWSe46zFQUdK9SiT5ibPKNqPDZtKk',7,2,2,2,0.056260,'Cubicle Slate','none'),
(4990,'entry','insgRJVVNgfWSJxJEwYMZ9BucGhhKU86xN7Pb99rBE5f',2,6,0,6,0.047360,'Manila','none'),
(4991,'entry','9ssVWPQCYaNVtYJbHBswYFGXBD2K6tVZ77jrjoX24bgv',4,2,4,5,0.040320,'Breakroom Sage','none'),
(4992,'entry','gUA8M9ygzCbGqabCMTdY9ASXAnzjvdenqs29hnWqs8sV',4,0,2,4,0.024000,'Filing Grey','none'),
(4993,'entry','3LP2gyYMSrNz1r5W8fGGF3EAkyYcTKxEsAc4dUUo3cXU',1,3,4,2,0.044100,'Manila','none'),
(4994,'entry','1x3YZMAM8m2gxAUs7PRcz46UkLDKXyn3cRdpfYjG7EHt',6,9,4,0,0.088320,'Filing Grey','none'),
(4995,'entry','U47z7XwVDcXfoAvaX4QyxTsmXbiPXGgd6sJw7Coy6nmJ',2,6,4,5,0.061060,'Manila','none'),
(4996,'entry','W5YvLR42BYtrFWGU1P7zPRymwfxbFVB33VWMDar4S7KU',0,5,4,7,0.053960,'Cubicle Slate','none'),
(4997,'entry','izyj9AXSxmMPHRt8TNqrCE4GC6hdAj4MEXB3SiqRrgJu',6,0,7,6,0.061770,'Drywall','none'),
(4998,'entry','8SEFFMTdMq5ETw52iNuMDx7beXY8XboouxaRShctSer4',0,3,2,0,0.059630,'Drywall','none'),
(4999,'entry','ZGeZGSn5tC46ahZoUGMkaCLm6vwjXMGPXvfSm59ugT9S',6,6,7,7,0.036400,'Cubicle Slate','none');

-- Backfill the jsonb the existing client contract reads.
--
-- `xployees.traits` predates this migration and `src/lib/supabase.ts` maps it
-- through unchanged, so it has to keep holding the shape the browser's `Traits`
-- interface expects. It is derived here from the indices and the vocabulary
-- rather than emitted alongside them: one source of truth for a trait's spelling,
-- and 5,000 fewer repetitions of the word "Coverall" in a migration file.
update public.xployees x
   set traits = jsonb_build_object(
         'uniform',   (select label from public.trait_values where slot = 'uniform'   and idx = x.uniform_idx),
         'head',      (select label from public.trait_values where slot = 'head'      and idx = x.head_idx),
         'face',      (select label from public.trait_values where slot = 'face'      and idx = x.face_idx),
         'accessory', (select label from public.trait_values where slot = 'accessory' and idx = x.accessory_idx)
       );

-- Everything the seed asserted in TypeScript, asserted again against what
-- actually landed. A generator that ran correctly and a COPY that truncated
-- halfway are indistinguishable until something counts the rows.
do $$
declare
  v_rows integer;
  v_max  integer := public.max_supply();
  v_bad  integer;
begin
  select count(*) into v_rows from public.xployees;
  if v_rows <> v_max then
    raise exception 'seeded % xployees, expected %', v_rows, v_max;
  end if;

  select count(*) into v_bad from public.xployees where art_seed is null or length(art_seed) <> 44;
  if v_bad > 0 then
    raise exception '% xployees have no usable art seed', v_bad;
  end if;

  -- An art seed is an identity. Two workers sharing one would render as the same
  -- character with the same background, which reads as a duplicate rather than as
  -- a coincidence.
  select count(*) into v_bad from (
    select art_seed from public.xployees group by art_seed having count(*) > 1
  ) d;
  if v_bad > 0 then
    raise exception '% art seeds are shared by more than one xployee', v_bad;
  end if;

  select count(*) into v_bad from public.xployees
   where traits is null
      or traits->>'uniform' is null or traits->>'head' is null
      or traits->>'face' is null    or traits->>'accessory' is null;
  if v_bad > 0 then
    raise exception '% xployees have incomplete traits', v_bad;
  end if;

  -- The tier bands, counted rather than reasoned about. These are the four
  -- numbers the token page publishes as the supply table.
  if (select count(*) from public.xployees where tier = 'xrated') <> 150 then
    raise exception 'X-RATED supply is not 150';
  end if;
  if (select count(*) from public.xployees where tier = 'expert') <> 600 then
    raise exception 'EPIC supply is not 600';
  end if;
  if (select count(*) from public.xployees where tier = 'mid') <> 1250 then
    raise exception 'RARE supply is not 1250';
  end if;
  if (select count(*) from public.xployees where tier = 'entry') <> 3000 then
    raise exception 'UNCOMMON supply is not 3000';
  end if;

  -- Nothing is owned yet. The genesis crew gets its owners in 20260806090500 and
  -- everything else waits for a burn.
  if exists (select 1 from public.xployees where owner is not null) then
    raise exception 'an xployee is already owned before any mint or genesis assignment';
  end if;
end;
$$;


-- =========================================================================
-- SECTION 9 of 16 — 20260806090400_seed_xployee_skills.sql
-- =========================================================================

-- xNFTs index — seed: which desks each xployee works.
--
-- 7,900 rows: 3,000 UNCOMMON x 1 + 1,250 RARE x 2 + 600 EPIC x 3 + 150 X-RATED
-- x 4. Emitted from the same `buildXployee` call that produced 20260806090300,
-- so the skill draw and the apy in that file came out of one roll rather than
-- two.
--
-- Columns: (xployee_id, slot, skill_id, proficiency_pct). `slot` is the draw
-- order — `pickDistinct` returns skills in the order it chose them and the
-- xployee sheet lists them that way, so the order is data rather than
-- presentation.

insert into public.xployee_skills (xployee_id, slot, skill_id, proficiency_pct) values
(0,0,'bills',100),
(0,1,'ledger',71),
(0,2,'vault',90),
(0,3,'brand',87),
(1,0,'brand',75),
(1,1,'rails',92),
(1,2,'ballast',69),
(1,3,'teller',70),
(2,0,'ballast',79),
(2,1,'claims',91),
(2,2,'bills',78),
(2,3,'crude',86),
(3,0,'degen',92),
(3,1,'bills',61),
(3,2,'claims',89),
(3,3,'crude',60),
(4,0,'grid',87),
(4,1,'claims',78),
(4,2,'vault',61),
(4,3,'crude',60),
(5,0,'silicon',72),
(5,1,'rails',91),
(5,2,'bills',75),
(5,3,'shelf',91),
(6,0,'shelf',72),
(6,1,'bills',68),
(6,2,'cloud',88),
(6,3,'trial',98),
(7,0,'shelf',73),
(7,1,'claims',80),
(7,2,'ledger',65),
(7,3,'grid',80),
(8,0,'teller',70),
(8,1,'bills',80),
(8,2,'trial',82),
(8,3,'claims',98),
(9,0,'grid',69),
(9,1,'ballast',64),
(9,2,'bills',63),
(9,3,'vault',61),
(10,0,'brand',65),
(10,1,'claims',87),
(10,2,'vault',64),
(10,3,'bills',99),
(11,0,'claims',70),
(11,1,'degen',83),
(11,2,'trial',97),
(11,3,'vault',66),
(12,0,'shelf',61),
(12,1,'brand',63),
(12,2,'silicon',73),
(12,3,'claims',61),
(13,0,'crude',77),
(13,1,'bills',67),
(13,2,'brand',75),
(13,3,'shelf',72),
(14,0,'crude',72),
(14,1,'teller',76),
(14,2,'shelf',89),
(14,3,'brand',69),
(15,0,'brand',70),
(15,1,'platform',72),
(15,2,'ballast',79),
(15,3,'crude',74),
(16,0,'brand',92),
(16,1,'ballast',82),
(16,2,'grid',76),
(16,3,'shelf',74),
(17,0,'shelf',78),
(17,1,'grid',100),
(17,2,'vault',90),
(17,3,'ledger',88),
(18,0,'brand',85),
(18,1,'vault',100),
(18,2,'bills',97),
(18,3,'cloud',89),
(19,0,'crude',65),
(19,1,'trial',77),
(19,2,'platform',79),
(19,3,'grid',61),
(20,0,'platform',62),
(20,1,'claims',99),
(20,2,'ballast',94),
(20,3,'brand',89),
(21,0,'crude',82),
(21,1,'rails',91),
(21,2,'ledger',85),
(21,3,'grid',99),
(22,0,'grid',84),
(22,1,'brand',99),
(22,2,'teller',61),
(22,3,'platform',68),
(23,0,'claims',100),
(23,1,'shelf',72),
(23,2,'vault',68),
(23,3,'grid',71),
(24,0,'shelf',95),
(24,1,'cloud',71),
(24,2,'platform',85),
(24,3,'grid',90),
(25,0,'rails',81),
(25,1,'brand',66),
(25,2,'crude',65),
(25,3,'ballast',65),
(26,0,'bills',73),
(26,1,'silicon',89),
(26,2,'grid',66),
(26,3,'shelf',64),
(27,0,'vault',79),
(27,1,'bills',80),
(27,2,'brand',64),
(27,3,'rails',80),
(28,0,'rails',83),
(28,1,'claims',92),
(28,2,'shelf',64),
(28,3,'platform',69),
(29,0,'bills',88),
(29,1,'degen',87),
(29,2,'ballast',80),
(29,3,'platform',92),
(30,0,'trial',71),
(30,1,'crude',83),
(30,2,'grid',94),
(30,3,'ledger',77),
(31,0,'platform',69),
(31,1,'rails',71),
(31,2,'shelf',100),
(31,3,'grid',99),
(32,0,'ballast',75),
(32,1,'rails',96),
(32,2,'bills',98),
(32,3,'silicon',84),
(33,0,'trial',100),
(33,1,'platform',70),
(33,2,'rails',98),
(33,3,'grid',79),
(34,0,'ballast',89),
(34,1,'bills',63),
(34,2,'trial',93),
(34,3,'platform',83),
(35,0,'rails',96),
(35,1,'teller',99),
(35,2,'silicon',60),
(35,3,'bills',62),
(36,0,'vault',92),
(36,1,'platform',84),
(36,2,'trial',84),
(36,3,'grid',95),
(37,0,'crude',78),
(37,1,'platform',65),
(37,2,'bills',85),
(37,3,'shelf',64),
(38,0,'vault',82),
(38,1,'grid',92),
(38,2,'claims',90),
(38,3,'ballast',86),
(39,0,'ledger',88),
(39,1,'grid',69),
(39,2,'trial',79),
(39,3,'bills',99),
(40,0,'brand',74),
(40,1,'bills',69),
(40,2,'grid',60),
(40,3,'trial',68),
(41,0,'trial',88),
(41,1,'rails',98),
(41,2,'bills',73),
(41,3,'claims',68),
(42,0,'brand',79),
(42,1,'bills',77),
(42,2,'vault',70),
(42,3,'ballast',93),
(43,0,'grid',77),
(43,1,'platform',89),
(43,2,'crude',60),
(43,3,'shelf',66),
(44,0,'rails',63),
(44,1,'vault',61),
(44,2,'ledger',92),
(44,3,'shelf',94),
(45,0,'silicon',94),
(45,1,'ledger',83),
(45,2,'ballast',79),
(45,3,'degen',97),
(46,0,'rails',63),
(46,1,'claims',77),
(46,2,'bills',98),
(46,3,'crude',60),
(47,0,'ballast',89),
(47,1,'platform',72),
(47,2,'vault',62),
(47,3,'brand',67),
(48,0,'platform',76),
(48,1,'rails',66),
(48,2,'grid',62),
(48,3,'trial',88),
(49,0,'ledger',77),
(49,1,'trial',88),
(49,2,'claims',93),
(49,3,'grid',84),
(50,0,'ballast',76),
(50,1,'grid',66),
(50,2,'crude',77),
(50,3,'platform',65),
(51,0,'bills',66),
(51,1,'silicon',90),
(51,2,'cloud',61),
(51,3,'crude',85),
(52,0,'shelf',98),
(52,1,'grid',93),
(52,2,'rails',71),
(52,3,'claims',78),
(53,0,'bills',60),
(53,1,'platform',94),
(53,2,'ledger',65),
(53,3,'trial',75),
(54,0,'brand',91),
(54,1,'shelf',88),
(54,2,'rails',78),
(54,3,'claims',92),
(55,0,'vault',87),
(55,1,'bills',92),
(55,2,'rails',62),
(55,3,'shelf',69),
(56,0,'vault',95),
(56,1,'brand',75),
(56,2,'bills',81),
(56,3,'rails',85),
(57,0,'brand',82),
(57,1,'grid',86),
(57,2,'ballast',61),
(57,3,'degen',95),
(58,0,'silicon',84),
(58,1,'claims',77),
(58,2,'platform',90),
(58,3,'brand',72),
(59,0,'bills',86),
(59,1,'brand',89),
(59,2,'rails',64),
(59,3,'vault',69),
(60,0,'trial',61),
(60,1,'claims',96),
(60,2,'grid',93),
(60,3,'bills',72),
(61,0,'claims',95),
(61,1,'ledger',73),
(61,2,'ballast',75),
(61,3,'trial',86),
(62,0,'ballast',75),
(62,1,'ledger',100),
(62,2,'degen',74),
(62,3,'vault',77),
(63,0,'platform',79),
(63,1,'grid',79),
(63,2,'rails',79),
(63,3,'cloud',60),
(64,0,'grid',79),
(64,1,'brand',65),
(64,2,'ledger',86),
(64,3,'vault',80),
(65,0,'vault',84),
(65,1,'platform',96),
(65,2,'trial',76),
(65,3,'rails',60),
(66,0,'claims',96),
(66,1,'vault',64),
(66,2,'ledger',68),
(66,3,'ballast',84),
(67,0,'ballast',60),
(67,1,'brand',95),
(67,2,'bills',80),
(67,3,'grid',96),
(68,0,'claims',91),
(68,1,'teller',96),
(68,2,'shelf',96),
(68,3,'vault',77),
(69,0,'cloud',84),
(69,1,'claims',76),
(69,2,'vault',75),
(69,3,'shelf',77),
(70,0,'degen',76),
(70,1,'vault',62),
(70,2,'rails',97),
(70,3,'bills',84),
(71,0,'grid',89),
(71,1,'brand',82),
(71,2,'shelf',83),
(71,3,'ledger',92),
(72,0,'brand',94),
(72,1,'trial',85),
(72,2,'teller',65),
(72,3,'rails',76),
(73,0,'grid',88),
(73,1,'shelf',85),
(73,2,'trial',86),
(73,3,'platform',86),
(74,0,'ledger',81),
(74,1,'bills',66),
(74,2,'shelf',65),
(74,3,'vault',60),
(75,0,'vault',70),
(75,1,'ballast',97),
(75,2,'ledger',90),
(75,3,'teller',98),
(76,0,'ballast',82),
(76,1,'bills',72),
(76,2,'claims',60),
(76,3,'silicon',73),
(77,0,'bills',69),
(77,1,'claims',89),
(77,2,'crude',79),
(77,3,'vault',89),
(78,0,'shelf',69),
(78,1,'ballast',86),
(78,2,'rails',81),
(78,3,'claims',61),
(79,0,'trial',63),
(79,1,'vault',99),
(79,2,'rails',64),
(79,3,'platform',68),
(80,0,'brand',81),
(80,1,'silicon',98),
(80,2,'platform',95),
(80,3,'trial',85),
(81,0,'brand',66),
(81,1,'ballast',80),
(81,2,'shelf',98),
(81,3,'platform',72),
(82,0,'vault',81),
(82,1,'cloud',75),
(82,2,'shelf',71),
(82,3,'degen',80),
(83,0,'grid',85),
(83,1,'ballast',71),
(83,2,'rails',87),
(83,3,'crude',72),
(84,0,'platform',67),
(84,1,'teller',85),
(84,2,'vault',60),
(84,3,'trial',79),
(85,0,'vault',89),
(85,1,'rails',94),
(85,2,'cloud',70),
(85,3,'brand',63),
(86,0,'bills',79),
(86,1,'ballast',82),
(86,2,'grid',94),
(86,3,'ledger',88),
(87,0,'shelf',67),
(87,1,'trial',84),
(87,2,'bills',80),
(87,3,'platform',76),
(88,0,'shelf',99),
(88,1,'ballast',66),
(88,2,'bills',74),
(88,3,'grid',85),
(89,0,'claims',74),
(89,1,'ledger',68),
(89,2,'trial',83),
(89,3,'shelf',94),
(90,0,'vault',84),
(90,1,'grid',72),
(90,2,'shelf',75),
(90,3,'ballast',85),
(91,0,'crude',74),
(91,1,'brand',85),
(91,2,'cloud',90),
(91,3,'teller',94),
(92,0,'crude',77),
(92,1,'rails',90),
(92,2,'cloud',96),
(92,3,'trial',67),
(93,0,'silicon',66),
(93,1,'cloud',65),
(93,2,'ballast',98),
(93,3,'crude',63),
(94,0,'claims',90),
(94,1,'cloud',67),
(94,2,'degen',72),
(94,3,'rails',100),
(95,0,'ballast',67),
(95,1,'cloud',90),
(95,2,'trial',80),
(95,3,'claims',78),
(96,0,'degen',65),
(96,1,'silicon',69),
(96,2,'brand',100),
(96,3,'ledger',72),
(97,0,'ballast',84),
(97,1,'bills',68),
(97,2,'trial',86),
(97,3,'grid',62),
(98,0,'ballast',76),
(98,1,'ledger',87),
(98,2,'cloud',74),
(98,3,'claims',81),
(99,0,'grid',98),
(99,1,'trial',63),
(99,2,'rails',86),
(99,3,'shelf',91),
(100,0,'claims',79),
(100,1,'grid',67),
(100,2,'crude',79),
(100,3,'rails',90),
(101,0,'platform',91),
(101,1,'crude',79),
(101,2,'teller',79),
(101,3,'ballast',77),
(102,0,'cloud',96),
(102,1,'brand',64),
(102,2,'rails',67),
(102,3,'ballast',77),
(103,0,'brand',66),
(103,1,'crude',84),
(103,2,'cloud',99),
(103,3,'vault',75),
(104,0,'teller',87),
(104,1,'grid',94),
(104,2,'rails',65),
(104,3,'crude',78),
(105,0,'claims',79),
(105,1,'shelf',98),
(105,2,'platform',74),
(105,3,'grid',70),
(106,0,'cloud',65),
(106,1,'rails',83),
(106,2,'bills',86),
(106,3,'platform',73),
(107,0,'degen',78),
(107,1,'rails',86),
(107,2,'crude',72),
(107,3,'bills',94),
(108,0,'trial',63),
(108,1,'platform',73),
(108,2,'crude',74),
(108,3,'teller',68),
(109,0,'bills',66),
(109,1,'ledger',100),
(109,2,'grid',91),
(109,3,'rails',71),
(110,0,'grid',62),
(110,1,'degen',71),
(110,2,'claims',97),
(110,3,'ballast',77),
(111,0,'rails',68),
(111,1,'ledger',96),
(111,2,'shelf',95),
(111,3,'trial',81),
(112,0,'bills',83),
(112,1,'crude',87),
(112,2,'shelf',64),
(112,3,'ballast',89),
(113,0,'shelf',60),
(113,1,'ledger',60),
(113,2,'cloud',72),
(113,3,'ballast',64),
(114,0,'crude',86),
(114,1,'ballast',77),
(114,2,'shelf',62),
(114,3,'ledger',81),
(115,0,'shelf',96),
(115,1,'trial',84),
(115,2,'degen',87),
(115,3,'teller',98),
(116,0,'ballast',83),
(116,1,'bills',80),
(116,2,'silicon',75),
(116,3,'ledger',67),
(117,0,'crude',94),
(117,1,'brand',75),
(117,2,'shelf',62),
(117,3,'claims',99),
(118,0,'ledger',66),
(118,1,'platform',67),
(118,2,'claims',81),
(118,3,'teller',91),
(119,0,'bills',92),
(119,1,'crude',72),
(119,2,'ballast',63),
(119,3,'grid',70),
(120,0,'cloud',86),
(120,1,'shelf',70),
(120,2,'grid',96),
(120,3,'rails',85),
(121,0,'vault',67),
(121,1,'grid',72),
(121,2,'platform',85),
(121,3,'ballast',60),
(122,0,'shelf',86),
(122,1,'rails',99),
(122,2,'cloud',82),
(122,3,'degen',89),
(123,0,'cloud',69),
(123,1,'bills',76),
(123,2,'rails',77),
(123,3,'brand',75),
(124,0,'ballast',98),
(124,1,'bills',65),
(124,2,'claims',92),
(124,3,'vault',98),
(125,0,'cloud',80),
(125,1,'teller',62),
(125,2,'crude',80),
(125,3,'brand',80),
(126,0,'trial',82),
(126,1,'brand',73),
(126,2,'ballast',89),
(126,3,'grid',61),
(127,0,'claims',71),
(127,1,'shelf',87),
(127,2,'trial',61),
(127,3,'brand',66),
(128,0,'trial',77),
(128,1,'rails',75),
(128,2,'ballast',76),
(128,3,'shelf',76),
(129,0,'claims',67),
(129,1,'shelf',91),
(129,2,'bills',82),
(129,3,'trial',90),
(130,0,'shelf',84),
(130,1,'grid',69),
(130,2,'rails',73),
(130,3,'brand',99),
(131,0,'brand',65),
(131,1,'grid',61),
(131,2,'bills',75),
(131,3,'crude',64),
(132,0,'rails',95),
(132,1,'teller',84),
(132,2,'vault',67),
(132,3,'silicon',94),
(133,0,'ballast',76),
(133,1,'shelf',73),
(133,2,'trial',65),
(133,3,'brand',94),
(134,0,'brand',61),
(134,1,'silicon',91),
(134,2,'crude',87),
(134,3,'ballast',77),
(135,0,'crude',67),
(135,1,'bills',98),
(135,2,'ballast',76),
(135,3,'trial',65),
(136,0,'bills',82),
(136,1,'brand',85),
(136,2,'shelf',79),
(136,3,'vault',82),
(137,0,'ballast',77),
(137,1,'rails',75),
(137,2,'brand',80),
(137,3,'ledger',98),
(138,0,'ballast',61),
(138,1,'claims',77),
(138,2,'grid',78),
(138,3,'trial',90),
(139,0,'brand',85),
(139,1,'ballast',81),
(139,2,'ledger',77),
(139,3,'trial',84),
(140,0,'shelf',85),
(140,1,'cloud',73),
(140,2,'claims',69),
(140,3,'ballast',70),
(141,0,'ballast',89),
(141,1,'rails',98),
(141,2,'degen',85),
(141,3,'crude',87),
(142,0,'ballast',61),
(142,1,'crude',65),
(142,2,'trial',88),
(142,3,'silicon',71),
(143,0,'claims',97),
(143,1,'rails',90),
(143,2,'silicon',96),
(143,3,'grid',100),
(144,0,'grid',99),
(144,1,'bills',95),
(144,2,'platform',87),
(144,3,'rails',63),
(145,0,'bills',99),
(145,1,'grid',97),
(145,2,'rails',62),
(145,3,'trial',84),
(146,0,'brand',62),
(146,1,'ledger',93),
(146,2,'bills',69),
(146,3,'shelf',89),
(147,0,'claims',76),
(147,1,'trial',79),
(147,2,'vault',84),
(147,3,'grid',71),
(148,0,'cloud',93),
(148,1,'ballast',61),
(148,2,'ledger',70),
(148,3,'crude',86),
(149,0,'silicon',71),
(149,1,'vault',98),
(149,2,'rails',77),
(149,3,'bills',69),
(150,0,'ledger',97),
(150,1,'grid',99),
(150,2,'ballast',74),
(151,0,'crude',76),
(151,1,'cloud',79),
(151,2,'bills',79),
(152,0,'shelf',68),
(152,1,'ballast',84),
(152,2,'teller',79),
(153,0,'shelf',93),
(153,1,'platform',97),
(153,2,'trial',77),
(154,0,'claims',90),
(154,1,'shelf',70),
(154,2,'ballast',63),
(155,0,'trial',60),
(155,1,'bills',80),
(155,2,'vault',88),
(156,0,'rails',82),
(156,1,'claims',84),
(156,2,'vault',63),
(157,0,'trial',61),
(157,1,'bills',81),
(157,2,'grid',79),
(158,0,'bills',100),
(158,1,'claims',90),
(158,2,'vault',64),
(159,0,'rails',90),
(159,1,'ledger',80),
(159,2,'vault',66),
(160,0,'bills',70),
(160,1,'ballast',78),
(160,2,'cloud',70),
(161,0,'vault',91),
(161,1,'grid',72),
(161,2,'brand',73),
(162,0,'ledger',62),
(162,1,'shelf',93),
(162,2,'teller',97),
(163,0,'vault',68),
(163,1,'cloud',98),
(163,2,'bills',77),
(164,0,'brand',94),
(164,1,'grid',75),
(164,2,'cloud',79),
(165,0,'rails',60),
(165,1,'crude',82),
(165,2,'silicon',74),
(166,0,'bills',65),
(166,1,'crude',79),
(166,2,'claims',64),
(167,0,'platform',86),
(167,1,'bills',84),
(167,2,'trial',89),
(168,0,'claims',74),
(168,1,'ballast',63),
(168,2,'grid',99),
(169,0,'claims',61),
(169,1,'grid',90),
(169,2,'ballast',77),
(170,0,'ballast',99),
(170,1,'platform',60),
(170,2,'shelf',63),
(171,0,'brand',70),
(171,1,'bills',89),
(171,2,'claims',77),
(172,0,'brand',72),
(172,1,'shelf',97),
(172,2,'ballast',99),
(173,0,'trial',92),
(173,1,'shelf',87),
(173,2,'bills',88),
(174,0,'brand',87),
(174,1,'teller',74),
(174,2,'trial',69),
(175,0,'brand',84),
(175,1,'grid',79),
(175,2,'shelf',84),
(176,0,'cloud',98),
(176,1,'rails',85),
(176,2,'bills',77),
(177,0,'ledger',62),
(177,1,'platform',61),
(177,2,'bills',86),
(178,0,'ballast',60),
(178,1,'rails',75),
(178,2,'grid',74),
(179,0,'claims',99),
(179,1,'trial',62),
(179,2,'grid',85),
(180,0,'silicon',91),
(180,1,'trial',96),
(180,2,'vault',88),
(181,0,'brand',62),
(181,1,'bills',93),
(181,2,'claims',83),
(182,0,'shelf',63),
(182,1,'vault',84),
(182,2,'trial',93),
(183,0,'crude',87),
(183,1,'rails',88),
(183,2,'cloud',78),
(184,0,'degen',98),
(184,1,'rails',83),
(184,2,'ledger',67),
(185,0,'ledger',79),
(185,1,'bills',80),
(185,2,'ballast',61),
(186,0,'claims',74),
(186,1,'grid',87),
(186,2,'bills',90),
(187,0,'ledger',88),
(187,1,'vault',79),
(187,2,'grid',99),
(188,0,'cloud',64),
(188,1,'vault',69),
(188,2,'brand',71),
(189,0,'vault',66),
(189,1,'ballast',82),
(189,2,'brand',77),
(190,0,'claims',90),
(190,1,'degen',75),
(190,2,'rails',64),
(191,0,'rails',79),
(191,1,'degen',100),
(191,2,'claims',75),
(192,0,'bills',94),
(192,1,'grid',60),
(192,2,'ballast',61),
(193,0,'ballast',97),
(193,1,'shelf',97),
(193,2,'ledger',87),
(194,0,'shelf',100),
(194,1,'platform',71),
(194,2,'claims',100),
(195,0,'shelf',66),
(195,1,'grid',82),
(195,2,'bills',60),
(196,0,'grid',83),
(196,1,'vault',69),
(196,2,'trial',63),
(197,0,'claims',87),
(197,1,'ballast',85),
(197,2,'bills',60),
(198,0,'claims',84),
(198,1,'bills',71),
(198,2,'rails',70),
(199,0,'shelf',60),
(199,1,'bills',67),
(199,2,'rails',95),
(200,0,'shelf',81),
(200,1,'degen',86),
(200,2,'bills',78),
(201,0,'grid',97),
(201,1,'rails',62),
(201,2,'brand',89),
(202,0,'brand',81),
(202,1,'ballast',62),
(202,2,'degen',77),
(203,0,'rails',65),
(203,1,'brand',95),
(203,2,'silicon',88),
(204,0,'platform',75),
(204,1,'brand',83),
(204,2,'rails',83),
(205,0,'crude',83),
(205,1,'trial',69),
(205,2,'bills',91),
(206,0,'trial',68),
(206,1,'grid',71),
(206,2,'vault',95),
(207,0,'platform',98),
(207,1,'rails',85),
(207,2,'vault',84),
(208,0,'brand',81),
(208,1,'bills',74),
(208,2,'cloud',76),
(209,0,'degen',76),
(209,1,'rails',86),
(209,2,'shelf',100),
(210,0,'claims',96),
(210,1,'bills',61),
(210,2,'rails',77),
(211,0,'ballast',65),
(211,1,'grid',90),
(211,2,'trial',98),
(212,0,'brand',97),
(212,1,'bills',86),
(212,2,'platform',80),
(213,0,'platform',73),
(213,1,'grid',90),
(213,2,'ballast',82),
(214,0,'trial',90),
(214,1,'vault',92),
(214,2,'brand',91),
(215,0,'claims',93),
(215,1,'ballast',72),
(215,2,'bills',77),
(216,0,'shelf',93),
(216,1,'bills',100),
(216,2,'vault',100),
(217,0,'crude',68),
(217,1,'cloud',89),
(217,2,'brand',84),
(218,0,'shelf',95),
(218,1,'trial',87),
(218,2,'brand',71),
(219,0,'rails',96),
(219,1,'silicon',61),
(219,2,'cloud',69),
(220,0,'platform',66),
(220,1,'trial',87),
(220,2,'grid',69),
(221,0,'ballast',60),
(221,1,'teller',90),
(221,2,'cloud',86),
(222,0,'trial',68),
(222,1,'cloud',84),
(222,2,'ledger',74),
(223,0,'bills',69),
(223,1,'platform',61),
(223,2,'silicon',98),
(224,0,'ballast',98),
(224,1,'brand',96),
(224,2,'platform',87),
(225,0,'grid',70),
(225,1,'rails',70),
(225,2,'claims',97),
(226,0,'platform',90),
(226,1,'grid',75),
(226,2,'ballast',74),
(227,0,'vault',88),
(227,1,'teller',84),
(227,2,'rails',68),
(228,0,'claims',72),
(228,1,'rails',92),
(228,2,'silicon',62),
(229,0,'vault',98),
(229,1,'brand',84),
(229,2,'platform',89),
(230,0,'ballast',74),
(230,1,'claims',100),
(230,2,'rails',77),
(231,0,'brand',84),
(231,1,'ledger',92),
(231,2,'shelf',79),
(232,0,'silicon',77),
(232,1,'bills',61),
(232,2,'cloud',80),
(233,0,'shelf',72),
(233,1,'ballast',70),
(233,2,'bills',91),
(234,0,'teller',63),
(234,1,'vault',95),
(234,2,'grid',60),
(235,0,'bills',73),
(235,1,'rails',79),
(235,2,'claims',78),
(236,0,'shelf',88),
(236,1,'ballast',83),
(236,2,'grid',71),
(237,0,'ballast',85),
(237,1,'claims',99),
(237,2,'platform',93),
(238,0,'brand',67),
(238,1,'bills',85),
(238,2,'ballast',77),
(239,0,'cloud',67),
(239,1,'brand',83),
(239,2,'shelf',80),
(240,0,'platform',71),
(240,1,'bills',100),
(240,2,'crude',74),
(241,0,'bills',82),
(241,1,'claims',74),
(241,2,'shelf',75),
(242,0,'silicon',72),
(242,1,'bills',84),
(242,2,'ballast',80),
(243,0,'ledger',94),
(243,1,'ballast',69),
(243,2,'trial',72),
(244,0,'brand',96),
(244,1,'shelf',85),
(244,2,'crude',86),
(245,0,'shelf',79),
(245,1,'ballast',92),
(245,2,'vault',78),
(246,0,'brand',87),
(246,1,'platform',86),
(246,2,'ledger',88),
(247,0,'crude',91),
(247,1,'ballast',60),
(247,2,'claims',76),
(248,0,'claims',60),
(248,1,'vault',86),
(248,2,'bills',75),
(249,0,'platform',75),
(249,1,'grid',75),
(249,2,'cloud',68),
(250,0,'rails',63),
(250,1,'platform',77),
(250,2,'trial',79),
(251,0,'vault',97),
(251,1,'crude',62),
(251,2,'ballast',82),
(252,0,'claims',64),
(252,1,'vault',84),
(252,2,'ballast',96),
(253,0,'ballast',63),
(253,1,'vault',89),
(253,2,'ledger',71),
(254,0,'claims',96),
(254,1,'rails',88),
(254,2,'bills',85),
(255,0,'ballast',84),
(255,1,'grid',64),
(255,2,'crude',81),
(256,0,'ballast',98),
(256,1,'cloud',83),
(256,2,'rails',88),
(257,0,'trial',67),
(257,1,'claims',80),
(257,2,'silicon',93),
(258,0,'vault',75),
(258,1,'trial',99),
(258,2,'cloud',74),
(259,0,'bills',85),
(259,1,'ballast',63),
(259,2,'degen',70),
(260,0,'vault',98),
(260,1,'ballast',96),
(260,2,'cloud',69),
(261,0,'platform',64),
(261,1,'bills',92),
(261,2,'rails',87),
(262,0,'ledger',63),
(262,1,'ballast',92),
(262,2,'brand',84),
(263,0,'ledger',76),
(263,1,'brand',67),
(263,2,'ballast',87),
(264,0,'ballast',63),
(264,1,'brand',98),
(264,2,'cloud',60),
(265,0,'ballast',68),
(265,1,'trial',67),
(265,2,'cloud',86),
(266,0,'vault',88),
(266,1,'brand',63),
(266,2,'grid',72),
(267,0,'crude',65),
(267,1,'platform',96),
(267,2,'silicon',70),
(268,0,'claims',65),
(268,1,'ballast',78),
(268,2,'platform',91),
(269,0,'shelf',83),
(269,1,'brand',69),
(269,2,'bills',79),
(270,0,'brand',80),
(270,1,'crude',91),
(270,2,'trial',76),
(271,0,'ballast',79),
(271,1,'crude',75),
(271,2,'teller',64),
(272,0,'ballast',63),
(272,1,'brand',76),
(272,2,'crude',78),
(273,0,'platform',97),
(273,1,'silicon',68),
(273,2,'cloud',86),
(274,0,'bills',88),
(274,1,'ballast',85),
(274,2,'shelf',82),
(275,0,'degen',87),
(275,1,'grid',93),
(275,2,'ledger',74),
(276,0,'claims',98),
(276,1,'grid',63),
(276,2,'shelf',66),
(277,0,'bills',66),
(277,1,'brand',75),
(277,2,'shelf',76),
(278,0,'shelf',61),
(278,1,'cloud',82),
(278,2,'brand',90),
(279,0,'platform',78),
(279,1,'teller',64),
(279,2,'silicon',91),
(280,0,'claims',97),
(280,1,'silicon',67),
(280,2,'shelf',92),
(281,0,'rails',79),
(281,1,'trial',85),
(281,2,'cloud',87),
(282,0,'ledger',77),
(282,1,'bills',87),
(282,2,'grid',92),
(283,0,'degen',80),
(283,1,'shelf',67),
(283,2,'vault',67),
(284,0,'claims',78),
(284,1,'crude',75),
(284,2,'bills',95),
(285,0,'vault',94),
(285,1,'shelf',87),
(285,2,'ledger',61),
(286,0,'rails',84),
(286,1,'brand',63),
(286,2,'grid',98),
(287,0,'rails',99),
(287,1,'ballast',65),
(287,2,'teller',73),
(288,0,'crude',85),
(288,1,'ledger',79),
(288,2,'ballast',68),
(289,0,'bills',71),
(289,1,'ballast',98),
(289,2,'vault',94),
(290,0,'ballast',97),
(290,1,'bills',100),
(290,2,'crude',76),
(291,0,'shelf',86),
(291,1,'claims',93),
(291,2,'vault',81),
(292,0,'silicon',79),
(292,1,'ballast',92),
(292,2,'shelf',97),
(293,0,'brand',72),
(293,1,'claims',80),
(293,2,'crude',100),
(294,0,'silicon',77),
(294,1,'brand',82),
(294,2,'ballast',63),
(295,0,'rails',83),
(295,1,'trial',62),
(295,2,'grid',60),
(296,0,'brand',71),
(296,1,'platform',89),
(296,2,'shelf',60),
(297,0,'platform',74),
(297,1,'ballast',96),
(297,2,'crude',97),
(298,0,'trial',61),
(298,1,'vault',86),
(298,2,'shelf',94),
(299,0,'bills',81),
(299,1,'claims',85),
(299,2,'ledger',75),
(300,0,'ledger',75),
(300,1,'bills',63),
(300,2,'brand',77),
(301,0,'vault',63),
(301,1,'trial',89),
(301,2,'shelf',84),
(302,0,'crude',93),
(302,1,'shelf',67),
(302,2,'brand',60),
(303,0,'platform',76),
(303,1,'teller',72),
(303,2,'claims',89),
(304,0,'grid',93),
(304,1,'trial',75),
(304,2,'brand',89),
(305,0,'ledger',78),
(305,1,'brand',99),
(305,2,'shelf',65),
(306,0,'bills',78),
(306,1,'platform',68),
(306,2,'ballast',79),
(307,0,'ledger',69),
(307,1,'platform',88),
(307,2,'rails',66),
(308,0,'brand',79),
(308,1,'ballast',95),
(308,2,'grid',77),
(309,0,'platform',73),
(309,1,'ballast',69),
(309,2,'rails',81),
(310,0,'claims',87),
(310,1,'brand',91),
(310,2,'bills',74),
(311,0,'rails',72),
(311,1,'vault',83),
(311,2,'silicon',63),
(312,0,'crude',67),
(312,1,'brand',63),
(312,2,'bills',100),
(313,0,'shelf',100),
(313,1,'cloud',77),
(313,2,'brand',97),
(314,0,'ledger',97),
(314,1,'shelf',70),
(314,2,'vault',66),
(315,0,'platform',100),
(315,1,'crude',91),
(315,2,'brand',62),
(316,0,'crude',63),
(316,1,'vault',96),
(316,2,'brand',81),
(317,0,'brand',97),
(317,1,'crude',81),
(317,2,'grid',68),
(318,0,'trial',99),
(318,1,'vault',63),
(318,2,'crude',60),
(319,0,'brand',89),
(319,1,'ledger',88),
(319,2,'cloud',72),
(320,0,'shelf',70),
(320,1,'degen',81),
(320,2,'bills',81),
(321,0,'rails',95),
(321,1,'platform',68),
(321,2,'brand',87),
(322,0,'claims',94),
(322,1,'vault',96),
(322,2,'platform',72),
(323,0,'ballast',77),
(323,1,'trial',79),
(323,2,'brand',66),
(324,0,'rails',74),
(324,1,'bills',82),
(324,2,'brand',80),
(325,0,'platform',84),
(325,1,'shelf',73),
(325,2,'cloud',92),
(326,0,'ledger',75),
(326,1,'degen',78),
(326,2,'bills',71),
(327,0,'shelf',88),
(327,1,'crude',96),
(327,2,'vault',74),
(328,0,'shelf',89),
(328,1,'platform',67),
(328,2,'vault',84),
(329,0,'bills',74),
(329,1,'crude',67),
(329,2,'shelf',66),
(330,0,'shelf',66),
(330,1,'ballast',85),
(330,2,'bills',67),
(331,0,'vault',86),
(331,1,'ballast',100),
(331,2,'claims',72),
(332,0,'claims',99),
(332,1,'brand',89),
(332,2,'grid',70),
(333,0,'brand',86),
(333,1,'shelf',88),
(333,2,'ballast',68),
(334,0,'vault',90),
(334,1,'ledger',99),
(334,2,'rails',76),
(335,0,'trial',74),
(335,1,'platform',93),
(335,2,'shelf',76),
(336,0,'platform',76),
(336,1,'crude',81),
(336,2,'bills',70),
(337,0,'cloud',81),
(337,1,'trial',69),
(337,2,'ledger',98),
(338,0,'brand',80),
(338,1,'grid',80),
(338,2,'shelf',87),
(339,0,'rails',94),
(339,1,'bills',100),
(339,2,'platform',98),
(340,0,'grid',73),
(340,1,'cloud',79),
(340,2,'shelf',93),
(341,0,'cloud',62),
(341,1,'platform',95),
(341,2,'degen',100),
(342,0,'shelf',68),
(342,1,'vault',75),
(342,2,'ballast',85),
(343,0,'degen',71),
(343,1,'ledger',62),
(343,2,'shelf',92),
(344,0,'grid',86),
(344,1,'shelf',89),
(344,2,'ballast',69),
(345,0,'claims',62),
(345,1,'brand',69),
(345,2,'rails',68),
(346,0,'degen',92),
(346,1,'claims',70),
(346,2,'ledger',61),
(347,0,'brand',67),
(347,1,'platform',62),
(347,2,'rails',67),
(348,0,'trial',87),
(348,1,'vault',73),
(348,2,'crude',78),
(349,0,'grid',100),
(349,1,'platform',91),
(349,2,'degen',71),
(350,0,'silicon',72),
(350,1,'ballast',67),
(350,2,'vault',74),
(351,0,'bills',97),
(351,1,'shelf',61),
(351,2,'cloud',64),
(352,0,'ledger',64),
(352,1,'rails',80),
(352,2,'crude',66),
(353,0,'crude',96),
(353,1,'claims',73),
(353,2,'ballast',95),
(354,0,'teller',77),
(354,1,'shelf',87),
(354,2,'bills',73),
(355,0,'rails',100),
(355,1,'vault',73),
(355,2,'crude',79),
(356,0,'bills',77),
(356,1,'grid',82),
(356,2,'teller',81),
(357,0,'shelf',67),
(357,1,'cloud',99),
(357,2,'claims',64),
(358,0,'vault',63),
(358,1,'brand',65),
(358,2,'silicon',73),
(359,0,'bills',94),
(359,1,'shelf',85),
(359,2,'crude',73),
(360,0,'bills',92),
(360,1,'silicon',64),
(360,2,'claims',97),
(361,0,'ballast',75),
(361,1,'rails',63),
(361,2,'grid',85),
(362,0,'grid',91),
(362,1,'cloud',62),
(362,2,'claims',82),
(363,0,'rails',74),
(363,1,'ledger',94),
(363,2,'trial',74),
(364,0,'rails',84),
(364,1,'bills',75),
(364,2,'grid',62),
(365,0,'platform',91),
(365,1,'trial',92),
(365,2,'bills',86),
(366,0,'ledger',79),
(366,1,'rails',68),
(366,2,'shelf',83),
(367,0,'grid',86),
(367,1,'shelf',66),
(367,2,'silicon',86),
(368,0,'ballast',93),
(368,1,'bills',76),
(368,2,'brand',97),
(369,0,'trial',65),
(369,1,'grid',64),
(369,2,'vault',98),
(370,0,'ledger',77),
(370,1,'vault',79),
(370,2,'ballast',63),
(371,0,'platform',82),
(371,1,'cloud',78),
(371,2,'vault',75),
(372,0,'grid',73),
(372,1,'rails',93),
(372,2,'bills',88),
(373,0,'ballast',95),
(373,1,'vault',84),
(373,2,'bills',93),
(374,0,'brand',72),
(374,1,'platform',92),
(374,2,'crude',99),
(375,0,'ballast',86),
(375,1,'claims',99),
(375,2,'silicon',88),
(376,0,'bills',93),
(376,1,'grid',62),
(376,2,'ballast',68),
(377,0,'bills',79),
(377,1,'shelf',71),
(377,2,'cloud',76),
(378,0,'shelf',67),
(378,1,'brand',80),
(378,2,'ballast',89),
(379,0,'cloud',81),
(379,1,'shelf',99),
(379,2,'rails',68),
(380,0,'bills',96),
(380,1,'cloud',61),
(380,2,'ledger',75),
(381,0,'degen',79),
(381,1,'bills',90),
(381,2,'ledger',62),
(382,0,'shelf',92),
(382,1,'vault',74),
(382,2,'platform',86),
(383,0,'claims',89),
(383,1,'brand',95),
(383,2,'ballast',82),
(384,0,'ledger',76),
(384,1,'ballast',62),
(384,2,'claims',79),
(385,0,'ballast',61),
(385,1,'ledger',65),
(385,2,'bills',92),
(386,0,'brand',68),
(386,1,'grid',92),
(386,2,'ledger',92),
(387,0,'shelf',66),
(387,1,'bills',70),
(387,2,'crude',96),
(388,0,'ballast',75),
(388,1,'brand',71),
(388,2,'claims',90),
(389,0,'ballast',81),
(389,1,'crude',98),
(389,2,'rails',99),
(390,0,'rails',65),
(390,1,'claims',68),
(390,2,'bills',87),
(391,0,'rails',94),
(391,1,'ballast',97),
(391,2,'grid',75),
(392,0,'bills',69),
(392,1,'brand',62),
(392,2,'crude',85),
(393,0,'ledger',89),
(393,1,'ballast',99),
(393,2,'claims',85),
(394,0,'vault',97),
(394,1,'ballast',88),
(394,2,'bills',73),
(395,0,'vault',94),
(395,1,'brand',80),
(395,2,'bills',66),
(396,0,'ledger',97),
(396,1,'crude',69),
(396,2,'claims',88),
(397,0,'ledger',96),
(397,1,'vault',98),
(397,2,'rails',91),
(398,0,'shelf',63),
(398,1,'brand',82),
(398,2,'rails',94),
(399,0,'platform',81),
(399,1,'rails',97),
(399,2,'brand',91),
(400,0,'bills',85),
(400,1,'shelf',66),
(400,2,'teller',64),
(401,0,'claims',88),
(401,1,'platform',92),
(401,2,'grid',69),
(402,0,'vault',100),
(402,1,'claims',99),
(402,2,'grid',66),
(403,0,'ledger',83),
(403,1,'ballast',98),
(403,2,'cloud',73),
(404,0,'ledger',60),
(404,1,'bills',94),
(404,2,'vault',83),
(405,0,'claims',62),
(405,1,'grid',63),
(405,2,'trial',60),
(406,0,'shelf',76),
(406,1,'cloud',68),
(406,2,'vault',95),
(407,0,'crude',64),
(407,1,'brand',86),
(407,2,'bills',97),
(408,0,'ledger',81),
(408,1,'brand',86),
(408,2,'platform',98),
(409,0,'ledger',74),
(409,1,'brand',69),
(409,2,'ballast',67),
(410,0,'ballast',69),
(410,1,'brand',80),
(410,2,'cloud',64),
(411,0,'bills',86),
(411,1,'ballast',73),
(411,2,'brand',83),
(412,0,'shelf',78),
(412,1,'vault',78),
(412,2,'brand',81),
(413,0,'grid',86),
(413,1,'cloud',91),
(413,2,'ledger',87),
(414,0,'bills',65),
(414,1,'platform',90),
(414,2,'shelf',92),
(415,0,'vault',80),
(415,1,'shelf',97),
(415,2,'platform',65),
(416,0,'cloud',67),
(416,1,'brand',99),
(416,2,'bills',96),
(417,0,'brand',68),
(417,1,'trial',96),
(417,2,'claims',88),
(418,0,'bills',61),
(418,1,'crude',91),
(418,2,'rails',93),
(419,0,'rails',68),
(419,1,'silicon',79),
(419,2,'shelf',100),
(420,0,'bills',91),
(420,1,'rails',90),
(420,2,'brand',77),
(421,0,'ledger',86),
(421,1,'brand',61),
(421,2,'grid',100),
(422,0,'ballast',87),
(422,1,'rails',100),
(422,2,'claims',87),
(423,0,'trial',96),
(423,1,'platform',99),
(423,2,'brand',92),
(424,0,'teller',76),
(424,1,'platform',89),
(424,2,'ballast',95),
(425,0,'ballast',78),
(425,1,'grid',77),
(425,2,'silicon',62),
(426,0,'bills',90),
(426,1,'trial',75),
(426,2,'shelf',94),
(427,0,'platform',84),
(427,1,'ballast',61),
(427,2,'cloud',71),
(428,0,'grid',82),
(428,1,'bills',60),
(428,2,'vault',69),
(429,0,'bills',69),
(429,1,'ballast',82),
(429,2,'grid',79),
(430,0,'rails',60),
(430,1,'ballast',62),
(430,2,'cloud',95),
(431,0,'silicon',87),
(431,1,'platform',99),
(431,2,'claims',95),
(432,0,'shelf',96),
(432,1,'platform',74),
(432,2,'trial',79),
(433,0,'shelf',88),
(433,1,'trial',92),
(433,2,'grid',64),
(434,0,'cloud',76),
(434,1,'vault',82),
(434,2,'platform',77),
(435,0,'degen',98),
(435,1,'claims',76),
(435,2,'grid',64),
(436,0,'degen',75),
(436,1,'silicon',70),
(436,2,'cloud',60),
(437,0,'trial',91),
(437,1,'grid',100),
(437,2,'ledger',61),
(438,0,'ledger',76),
(438,1,'grid',63),
(438,2,'bills',62),
(439,0,'ballast',92),
(439,1,'vault',71),
(439,2,'cloud',63),
(440,0,'shelf',73),
(440,1,'claims',78),
(440,2,'vault',81),
(441,0,'ballast',87),
(441,1,'silicon',83),
(441,2,'ledger',77),
(442,0,'claims',89),
(442,1,'shelf',89),
(442,2,'ledger',71),
(443,0,'claims',71),
(443,1,'vault',68),
(443,2,'platform',97),
(444,0,'silicon',84),
(444,1,'platform',61),
(444,2,'shelf',72),
(445,0,'bills',100),
(445,1,'ledger',76),
(445,2,'brand',83),
(446,0,'claims',72),
(446,1,'shelf',78),
(446,2,'ballast',79),
(447,0,'ballast',81),
(447,1,'rails',83),
(447,2,'brand',95),
(448,0,'silicon',85),
(448,1,'grid',78),
(448,2,'trial',86),
(449,0,'claims',85),
(449,1,'shelf',86),
(449,2,'vault',76),
(450,0,'grid',78),
(450,1,'ledger',76),
(450,2,'shelf',79),
(451,0,'brand',70),
(451,1,'claims',100),
(451,2,'ballast',67),
(452,0,'silicon',69),
(452,1,'ballast',80),
(452,2,'rails',87),
(453,0,'ballast',72),
(453,1,'shelf',60),
(453,2,'grid',97),
(454,0,'trial',89),
(454,1,'brand',60),
(454,2,'ballast',86),
(455,0,'grid',73),
(455,1,'brand',75),
(455,2,'shelf',84),
(456,0,'rails',85),
(456,1,'bills',73),
(456,2,'ballast',73),
(457,0,'trial',61),
(457,1,'grid',78),
(457,2,'shelf',86),
(458,0,'claims',95),
(458,1,'bills',63),
(458,2,'vault',85),
(459,0,'brand',93),
(459,1,'trial',91),
(459,2,'cloud',99),
(460,0,'shelf',70),
(460,1,'vault',79),
(460,2,'ledger',77),
(461,0,'shelf',89),
(461,1,'ledger',85),
(461,2,'bills',67),
(462,0,'ballast',77),
(462,1,'trial',97),
(462,2,'bills',97),
(463,0,'ballast',93),
(463,1,'bills',80),
(463,2,'claims',82),
(464,0,'crude',71),
(464,1,'ballast',64),
(464,2,'vault',71),
(465,0,'ledger',66),
(465,1,'brand',77),
(465,2,'ballast',67),
(466,0,'ledger',79),
(466,1,'claims',82),
(466,2,'bills',97),
(467,0,'ledger',65),
(467,1,'degen',92),
(467,2,'shelf',90),
(468,0,'grid',86),
(468,1,'bills',100),
(468,2,'cloud',91),
(469,0,'ledger',82),
(469,1,'bills',94),
(469,2,'rails',76),
(470,0,'silicon',82),
(470,1,'rails',71),
(470,2,'brand',78),
(471,0,'teller',75),
(471,1,'bills',99),
(471,2,'silicon',67),
(472,0,'ledger',83),
(472,1,'shelf',96),
(472,2,'ballast',97),
(473,0,'brand',82),
(473,1,'ballast',99),
(473,2,'bills',97),
(474,0,'crude',97),
(474,1,'bills',85),
(474,2,'trial',68),
(475,0,'crude',98),
(475,1,'trial',69),
(475,2,'ledger',61),
(476,0,'vault',89),
(476,1,'grid',100),
(476,2,'brand',97),
(477,0,'ballast',75),
(477,1,'shelf',74),
(477,2,'trial',86),
(478,0,'ballast',76),
(478,1,'grid',63),
(478,2,'crude',86),
(479,0,'rails',60),
(479,1,'silicon',72),
(479,2,'shelf',88),
(480,0,'vault',98),
(480,1,'rails',81),
(480,2,'shelf',97),
(481,0,'ledger',99),
(481,1,'trial',82),
(481,2,'shelf',100),
(482,0,'cloud',61),
(482,1,'bills',62),
(482,2,'trial',63),
(483,0,'vault',78),
(483,1,'platform',95),
(483,2,'crude',71),
(484,0,'vault',70),
(484,1,'trial',63),
(484,2,'bills',66),
(485,0,'shelf',75),
(485,1,'rails',87),
(485,2,'platform',91),
(486,0,'vault',73),
(486,1,'shelf',61),
(486,2,'cloud',77),
(487,0,'brand',85),
(487,1,'trial',62),
(487,2,'shelf',79),
(488,0,'ballast',80),
(488,1,'cloud',83),
(488,2,'brand',66),
(489,0,'ballast',95),
(489,1,'bills',78),
(489,2,'vault',98),
(490,0,'crude',63),
(490,1,'ballast',77),
(490,2,'grid',74),
(491,0,'claims',81),
(491,1,'cloud',60),
(491,2,'ledger',85),
(492,0,'ballast',95),
(492,1,'trial',72),
(492,2,'platform',65),
(493,0,'shelf',90),
(493,1,'trial',69),
(493,2,'ledger',70),
(494,0,'brand',80),
(494,1,'ballast',76),
(494,2,'trial',68),
(495,0,'rails',95),
(495,1,'claims',99),
(495,2,'shelf',85),
(496,0,'claims',100),
(496,1,'bills',87),
(496,2,'trial',100),
(497,0,'platform',96),
(497,1,'grid',63),
(497,2,'vault',64),
(498,0,'rails',90),
(498,1,'bills',73),
(498,2,'claims',78),
(499,0,'rails',70),
(499,1,'grid',72),
(499,2,'silicon',86),
(500,0,'crude',64),
(500,1,'brand',95),
(500,2,'trial',63),
(501,0,'brand',85),
(501,1,'grid',82),
(501,2,'claims',61),
(502,0,'trial',67),
(502,1,'bills',76),
(502,2,'vault',70),
(503,0,'ledger',66),
(503,1,'trial',63),
(503,2,'silicon',80),
(504,0,'ballast',71),
(504,1,'teller',73),
(504,2,'trial',98),
(505,0,'vault',83),
(505,1,'platform',74),
(505,2,'grid',85),
(506,0,'shelf',85),
(506,1,'vault',97),
(506,2,'rails',85),
(507,0,'crude',72),
(507,1,'vault',79),
(507,2,'rails',93),
(508,0,'claims',72),
(508,1,'ledger',61),
(508,2,'vault',64),
(509,0,'grid',92),
(509,1,'shelf',99),
(509,2,'ledger',94),
(510,0,'ledger',71),
(510,1,'shelf',88),
(510,2,'ballast',75),
(511,0,'trial',74),
(511,1,'bills',62),
(511,2,'silicon',72),
(512,0,'ballast',99),
(512,1,'brand',81),
(512,2,'platform',98),
(513,0,'bills',81),
(513,1,'claims',91),
(513,2,'grid',74),
(514,0,'shelf',99),
(514,1,'rails',80),
(514,2,'ledger',91),
(515,0,'trial',82),
(515,1,'bills',78),
(515,2,'claims',86),
(516,0,'crude',92),
(516,1,'vault',61),
(516,2,'bills',82),
(517,0,'ballast',79),
(517,1,'ledger',73),
(517,2,'cloud',99),
(518,0,'bills',98),
(518,1,'shelf',83),
(518,2,'vault',78),
(519,0,'crude',100),
(519,1,'claims',84),
(519,2,'silicon',77),
(520,0,'cloud',70),
(520,1,'claims',79),
(520,2,'platform',61),
(521,0,'shelf',73),
(521,1,'platform',63),
(521,2,'cloud',79),
(522,0,'teller',97),
(522,1,'bills',70),
(522,2,'shelf',78),
(523,0,'bills',71),
(523,1,'trial',100),
(523,2,'vault',73),
(524,0,'ballast',89),
(524,1,'claims',60),
(524,2,'brand',68),
(525,0,'cloud',72),
(525,1,'grid',62),
(525,2,'bills',89),
(526,0,'claims',60),
(526,1,'ballast',61),
(526,2,'teller',63),
(527,0,'claims',95),
(527,1,'shelf',93),
(527,2,'platform',95),
(528,0,'shelf',64),
(528,1,'ledger',89),
(528,2,'cloud',76),
(529,0,'ledger',80),
(529,1,'ballast',65),
(529,2,'grid',65),
(530,0,'rails',79),
(530,1,'brand',88),
(530,2,'bills',70),
(531,0,'ballast',63),
(531,1,'trial',71),
(531,2,'bills',100),
(532,0,'platform',61),
(532,1,'brand',65),
(532,2,'teller',100),
(533,0,'bills',98),
(533,1,'claims',64),
(533,2,'ballast',99),
(534,0,'brand',68),
(534,1,'crude',76),
(534,2,'silicon',86),
(535,0,'grid',74),
(535,1,'trial',82),
(535,2,'brand',64),
(536,0,'brand',87),
(536,1,'silicon',95),
(536,2,'cloud',61),
(537,0,'bills',100),
(537,1,'grid',89),
(537,2,'brand',94),
(538,0,'rails',72),
(538,1,'silicon',69),
(538,2,'claims',92),
(539,0,'vault',74),
(539,1,'crude',85),
(539,2,'ledger',66),
(540,0,'rails',96),
(540,1,'shelf',75),
(540,2,'crude',61),
(541,0,'ledger',71),
(541,1,'cloud',78),
(541,2,'shelf',61),
(542,0,'rails',61),
(542,1,'bills',66),
(542,2,'ballast',94),
(543,0,'bills',70),
(543,1,'shelf',93),
(543,2,'vault',69),
(544,0,'cloud',61),
(544,1,'ledger',87),
(544,2,'teller',88),
(545,0,'brand',70),
(545,1,'shelf',93),
(545,2,'claims',86),
(546,0,'cloud',84),
(546,1,'trial',68),
(546,2,'crude',76),
(547,0,'crude',65),
(547,1,'bills',88),
(547,2,'platform',83),
(548,0,'claims',89),
(548,1,'bills',94),
(548,2,'trial',82),
(549,0,'platform',63),
(549,1,'cloud',89),
(549,2,'crude',94),
(550,0,'bills',87),
(550,1,'platform',83),
(550,2,'grid',62),
(551,0,'rails',85),
(551,1,'silicon',91),
(551,2,'teller',69),
(552,0,'brand',88),
(552,1,'rails',80),
(552,2,'vault',86),
(553,0,'shelf',96),
(553,1,'crude',94),
(553,2,'claims',65),
(554,0,'brand',79),
(554,1,'claims',86),
(554,2,'ballast',67),
(555,0,'brand',76),
(555,1,'vault',85),
(555,2,'crude',71),
(556,0,'silicon',87),
(556,1,'cloud',84),
(556,2,'shelf',75),
(557,0,'trial',84),
(557,1,'bills',73),
(557,2,'brand',76),
(558,0,'grid',97),
(558,1,'rails',86),
(558,2,'ballast',65),
(559,0,'cloud',100),
(559,1,'vault',67),
(559,2,'brand',80),
(560,0,'brand',75),
(560,1,'ledger',71),
(560,2,'shelf',81),
(561,0,'ballast',81),
(561,1,'ledger',71),
(561,2,'vault',64),
(562,0,'shelf',62),
(562,1,'teller',63),
(562,2,'claims',62),
(563,0,'brand',85),
(563,1,'bills',91),
(563,2,'vault',73),
(564,0,'ledger',60),
(564,1,'trial',81),
(564,2,'cloud',91),
(565,0,'brand',90),
(565,1,'crude',94),
(565,2,'degen',80),
(566,0,'brand',94),
(566,1,'claims',81),
(566,2,'platform',95),
(567,0,'ledger',65),
(567,1,'trial',65),
(567,2,'crude',77),
(568,0,'trial',90),
(568,1,'cloud',87),
(568,2,'grid',66),
(569,0,'ballast',71),
(569,1,'vault',75),
(569,2,'rails',77),
(570,0,'shelf',60),
(570,1,'grid',84),
(570,2,'rails',89),
(571,0,'brand',66),
(571,1,'shelf',69),
(571,2,'crude',63),
(572,0,'rails',97),
(572,1,'brand',65),
(572,2,'shelf',68),
(573,0,'vault',76),
(573,1,'grid',82),
(573,2,'ballast',61),
(574,0,'cloud',80),
(574,1,'ledger',64),
(574,2,'crude',80),
(575,0,'bills',63),
(575,1,'teller',79),
(575,2,'ballast',97),
(576,0,'bills',78),
(576,1,'claims',88),
(576,2,'shelf',95),
(577,0,'shelf',86),
(577,1,'brand',92),
(577,2,'cloud',83),
(578,0,'crude',63),
(578,1,'brand',80),
(578,2,'shelf',99),
(579,0,'vault',74),
(579,1,'teller',80),
(579,2,'grid',90),
(580,0,'vault',65),
(580,1,'shelf',79),
(580,2,'claims',69),
(581,0,'vault',77),
(581,1,'claims',92),
(581,2,'brand',78),
(582,0,'vault',91),
(582,1,'silicon',90),
(582,2,'bills',68),
(583,0,'rails',61),
(583,1,'shelf',92),
(583,2,'crude',75),
(584,0,'bills',65),
(584,1,'ledger',62),
(584,2,'vault',62),
(585,0,'vault',64),
(585,1,'brand',61),
(585,2,'shelf',61),
(586,0,'grid',81),
(586,1,'silicon',87),
(586,2,'shelf',84),
(587,0,'shelf',63),
(587,1,'cloud',86),
(587,2,'platform',99),
(588,0,'brand',66),
(588,1,'trial',75),
(588,2,'ballast',60),
(589,0,'bills',86),
(589,1,'grid',86),
(589,2,'rails',78),
(590,0,'cloud',73),
(590,1,'ledger',62),
(590,2,'ballast',82),
(591,0,'trial',70),
(591,1,'shelf',76),
(591,2,'brand',60),
(592,0,'brand',66),
(592,1,'shelf',85),
(592,2,'ledger',60),
(593,0,'brand',65),
(593,1,'ballast',92),
(593,2,'crude',79),
(594,0,'ledger',78),
(594,1,'ballast',65),
(594,2,'bills',87),
(595,0,'bills',95),
(595,1,'trial',79),
(595,2,'vault',85),
(596,0,'ballast',100),
(596,1,'crude',79),
(596,2,'teller',99),
(597,0,'ballast',92),
(597,1,'rails',72),
(597,2,'vault',93),
(598,0,'ledger',96),
(598,1,'brand',91),
(598,2,'bills',78),
(599,0,'grid',100),
(599,1,'trial',100),
(599,2,'brand',64),
(600,0,'shelf',80),
(600,1,'rails',67),
(600,2,'bills',99),
(601,0,'rails',66),
(601,1,'cloud',91),
(601,2,'shelf',81),
(602,0,'platform',86),
(602,1,'shelf',73),
(602,2,'ledger',65),
(603,0,'brand',62),
(603,1,'claims',61),
(603,2,'trial',73),
(604,0,'ballast',61),
(604,1,'claims',95),
(604,2,'grid',83),
(605,0,'grid',86),
(605,1,'rails',62),
(605,2,'claims',94),
(606,0,'cloud',84),
(606,1,'vault',77),
(606,2,'platform',75),
(607,0,'grid',75),
(607,1,'ledger',62),
(607,2,'bills',86),
(608,0,'grid',77),
(608,1,'rails',86),
(608,2,'ballast',71),
(609,0,'silicon',70),
(609,1,'platform',63),
(609,2,'cloud',77),
(610,0,'shelf',78),
(610,1,'ballast',78),
(610,2,'claims',78),
(611,0,'grid',98),
(611,1,'trial',95),
(611,2,'silicon',60),
(612,0,'bills',97),
(612,1,'cloud',87),
(612,2,'vault',86),
(613,0,'ballast',61),
(613,1,'rails',95),
(613,2,'vault',88),
(614,0,'bills',85),
(614,1,'claims',92),
(614,2,'ballast',91),
(615,0,'vault',96),
(615,1,'platform',87),
(615,2,'cloud',75),
(616,0,'claims',78),
(616,1,'ballast',71),
(616,2,'grid',84),
(617,0,'teller',66),
(617,1,'vault',62),
(617,2,'grid',85),
(618,0,'vault',70),
(618,1,'trial',65),
(618,2,'degen',93),
(619,0,'trial',63),
(619,1,'ledger',68),
(619,2,'rails',84),
(620,0,'teller',78),
(620,1,'rails',60),
(620,2,'shelf',91),
(621,0,'vault',76),
(621,1,'ledger',83),
(621,2,'cloud',67),
(622,0,'crude',98),
(622,1,'claims',71),
(622,2,'trial',74),
(623,0,'ledger',65),
(623,1,'bills',64),
(623,2,'grid',62),
(624,0,'vault',88),
(624,1,'grid',86),
(624,2,'crude',90),
(625,0,'brand',91),
(625,1,'shelf',100),
(625,2,'rails',98),
(626,0,'shelf',61),
(626,1,'bills',91),
(626,2,'ballast',99),
(627,0,'cloud',94),
(627,1,'rails',71),
(627,2,'trial',79),
(628,0,'shelf',68),
(628,1,'ballast',76),
(628,2,'platform',75),
(629,0,'trial',72),
(629,1,'platform',99),
(629,2,'shelf',60),
(630,0,'cloud',77),
(630,1,'silicon',76),
(630,2,'brand',79),
(631,0,'rails',61),
(631,1,'vault',85),
(631,2,'brand',89),
(632,0,'grid',95),
(632,1,'ballast',87),
(632,2,'trial',62),
(633,0,'brand',88),
(633,1,'bills',96),
(633,2,'vault',66),
(634,0,'brand',70),
(634,1,'trial',95),
(634,2,'ballast',71),
(635,0,'bills',80),
(635,1,'vault',96),
(635,2,'grid',77),
(636,0,'bills',82),
(636,1,'ledger',95),
(636,2,'rails',93),
(637,0,'claims',90),
(637,1,'bills',73),
(637,2,'ledger',96),
(638,0,'ballast',89),
(638,1,'vault',99),
(638,2,'crude',76),
(639,0,'rails',87),
(639,1,'ballast',64),
(639,2,'ledger',76),
(640,0,'platform',72),
(640,1,'cloud',81),
(640,2,'bills',69),
(641,0,'brand',67),
(641,1,'shelf',65),
(641,2,'ballast',69),
(642,0,'ballast',73),
(642,1,'bills',74),
(642,2,'vault',98),
(643,0,'crude',85),
(643,1,'rails',64),
(643,2,'vault',91),
(644,0,'brand',64),
(644,1,'platform',69),
(644,2,'bills',92),
(645,0,'bills',94),
(645,1,'rails',79),
(645,2,'vault',76),
(646,0,'rails',97),
(646,1,'vault',65),
(646,2,'brand',77),
(647,0,'ballast',73),
(647,1,'brand',91),
(647,2,'shelf',99),
(648,0,'shelf',67),
(648,1,'ledger',65),
(648,2,'vault',68),
(649,0,'crude',86),
(649,1,'vault',100),
(649,2,'grid',86),
(650,0,'vault',77),
(650,1,'bills',61),
(650,2,'cloud',65),
(651,0,'ballast',98),
(651,1,'shelf',80),
(651,2,'bills',61),
(652,0,'claims',99),
(652,1,'ledger',71),
(652,2,'shelf',99),
(653,0,'trial',100),
(653,1,'claims',63),
(653,2,'ledger',72),
(654,0,'silicon',64),
(654,1,'brand',70),
(654,2,'claims',64),
(655,0,'vault',74),
(655,1,'degen',75),
(655,2,'rails',84),
(656,0,'bills',77),
(656,1,'claims',86),
(656,2,'rails',81),
(657,0,'trial',63),
(657,1,'grid',76),
(657,2,'ballast',94),
(658,0,'brand',84),
(658,1,'grid',84),
(658,2,'cloud',89),
(659,0,'ballast',96),
(659,1,'silicon',71),
(659,2,'ledger',97),
(660,0,'grid',73),
(660,1,'brand',66),
(660,2,'ballast',62),
(661,0,'teller',74),
(661,1,'trial',74),
(661,2,'vault',67),
(662,0,'bills',95),
(662,1,'brand',74),
(662,2,'shelf',69),
(663,0,'cloud',69),
(663,1,'platform',66),
(663,2,'claims',77),
(664,0,'trial',77),
(664,1,'ballast',90),
(664,2,'vault',99),
(665,0,'trial',67),
(665,1,'vault',79),
(665,2,'shelf',63),
(666,0,'ballast',92),
(666,1,'degen',97),
(666,2,'vault',83),
(667,0,'bills',100),
(667,1,'claims',95),
(667,2,'platform',92),
(668,0,'crude',92),
(668,1,'bills',83),
(668,2,'cloud',60),
(669,0,'grid',73),
(669,1,'silicon',83),
(669,2,'shelf',89),
(670,0,'cloud',95),
(670,1,'vault',70),
(670,2,'ballast',84),
(671,0,'ledger',60),
(671,1,'shelf',83),
(671,2,'trial',70),
(672,0,'brand',62),
(672,1,'rails',97),
(672,2,'trial',75),
(673,0,'grid',96),
(673,1,'ballast',75),
(673,2,'bills',77),
(674,0,'grid',64),
(674,1,'vault',96),
(674,2,'platform',77),
(675,0,'brand',67),
(675,1,'vault',92),
(675,2,'claims',66),
(676,0,'vault',77),
(676,1,'ballast',69),
(676,2,'ledger',67),
(677,0,'bills',64),
(677,1,'ballast',95),
(677,2,'brand',67),
(678,0,'ledger',72),
(678,1,'brand',65),
(678,2,'ballast',77),
(679,0,'vault',82),
(679,1,'crude',88),
(679,2,'ledger',83),
(680,0,'ledger',69),
(680,1,'silicon',68),
(680,2,'ballast',63),
(681,0,'degen',84),
(681,1,'crude',66),
(681,2,'cloud',98),
(682,0,'brand',81),
(682,1,'vault',71),
(682,2,'shelf',79),
(683,0,'shelf',85),
(683,1,'cloud',88),
(683,2,'vault',72),
(684,0,'silicon',62),
(684,1,'crude',65),
(684,2,'rails',64),
(685,0,'grid',97),
(685,1,'cloud',72),
(685,2,'bills',65),
(686,0,'trial',86),
(686,1,'ledger',98),
(686,2,'crude',83),
(687,0,'grid',77),
(687,1,'trial',80),
(687,2,'shelf',98),
(688,0,'ledger',65),
(688,1,'teller',93),
(688,2,'silicon',69),
(689,0,'shelf',78),
(689,1,'ledger',64),
(689,2,'rails',62),
(690,0,'vault',91),
(690,1,'brand',85),
(690,2,'crude',78),
(691,0,'cloud',64),
(691,1,'trial',97),
(691,2,'rails',87),
(692,0,'shelf',89),
(692,1,'grid',89),
(692,2,'ballast',95),
(693,0,'shelf',82),
(693,1,'grid',95),
(693,2,'brand',66),
(694,0,'brand',60),
(694,1,'bills',98),
(694,2,'vault',77),
(695,0,'brand',68),
(695,1,'bills',86),
(695,2,'rails',68),
(696,0,'ballast',60),
(696,1,'brand',75),
(696,2,'grid',73),
(697,0,'silicon',62),
(697,1,'brand',89),
(697,2,'trial',82),
(698,0,'rails',84),
(698,1,'ballast',80),
(698,2,'crude',82),
(699,0,'ballast',67),
(699,1,'brand',64),
(699,2,'trial',60),
(700,0,'cloud',67),
(700,1,'rails',68),
(700,2,'platform',77),
(701,0,'claims',94),
(701,1,'platform',85),
(701,2,'rails',72),
(702,0,'bills',90),
(702,1,'claims',84),
(702,2,'shelf',97),
(703,0,'platform',75),
(703,1,'cloud',68),
(703,2,'claims',68),
(704,0,'platform',99),
(704,1,'shelf',82),
(704,2,'vault',96),
(705,0,'rails',74),
(705,1,'silicon',95),
(705,2,'ledger',73),
(706,0,'trial',100),
(706,1,'vault',77),
(706,2,'grid',71),
(707,0,'ballast',87),
(707,1,'silicon',91),
(707,2,'ledger',88),
(708,0,'vault',79),
(708,1,'claims',67),
(708,2,'shelf',93),
(709,0,'crude',80),
(709,1,'bills',78),
(709,2,'ballast',72),
(710,0,'vault',99),
(710,1,'shelf',80),
(710,2,'teller',64),
(711,0,'trial',63),
(711,1,'grid',73),
(711,2,'brand',81),
(712,0,'grid',91),
(712,1,'teller',98),
(712,2,'rails',65),
(713,0,'brand',76),
(713,1,'crude',79),
(713,2,'silicon',72),
(714,0,'ballast',76),
(714,1,'bills',70),
(714,2,'trial',67),
(715,0,'trial',86),
(715,1,'platform',89),
(715,2,'ballast',95),
(716,0,'cloud',81),
(716,1,'claims',82),
(716,2,'grid',60),
(717,0,'bills',87),
(717,1,'crude',64),
(717,2,'cloud',92),
(718,0,'brand',84),
(718,1,'ballast',79),
(718,2,'bills',80),
(719,0,'vault',67),
(719,1,'brand',63),
(719,2,'ballast',97),
(720,0,'claims',75),
(720,1,'bills',96),
(720,2,'platform',96),
(721,0,'platform',94),
(721,1,'silicon',97),
(721,2,'rails',91),
(722,0,'degen',82),
(722,1,'ledger',73),
(722,2,'rails',88),
(723,0,'ledger',65),
(723,1,'cloud',87),
(723,2,'ballast',70),
(724,0,'trial',80),
(724,1,'vault',80),
(724,2,'cloud',73),
(725,0,'grid',69),
(725,1,'bills',62),
(725,2,'vault',96),
(726,0,'trial',77),
(726,1,'vault',84),
(726,2,'ledger',88),
(727,0,'grid',85),
(727,1,'ballast',91),
(727,2,'ledger',97),
(728,0,'platform',80),
(728,1,'cloud',75),
(728,2,'brand',98),
(729,0,'silicon',83),
(729,1,'vault',91),
(729,2,'ballast',90),
(730,0,'brand',75),
(730,1,'trial',90),
(730,2,'ledger',70),
(731,0,'brand',85),
(731,1,'bills',98),
(731,2,'trial',75),
(732,0,'claims',92),
(732,1,'brand',98),
(732,2,'ledger',90),
(733,0,'brand',78),
(733,1,'ballast',100),
(733,2,'bills',62),
(734,0,'bills',65),
(734,1,'claims',74),
(734,2,'trial',81),
(735,0,'claims',72),
(735,1,'vault',99),
(735,2,'brand',78),
(736,0,'cloud',81),
(736,1,'silicon',78),
(736,2,'brand',67),
(737,0,'ballast',75),
(737,1,'bills',72),
(737,2,'vault',93),
(738,0,'grid',99),
(738,1,'rails',61),
(738,2,'vault',90),
(739,0,'grid',94),
(739,1,'platform',86),
(739,2,'ledger',97),
(740,0,'trial',93),
(740,1,'bills',82),
(740,2,'platform',88),
(741,0,'vault',99),
(741,1,'silicon',85),
(741,2,'grid',78),
(742,0,'bills',88),
(742,1,'trial',75),
(742,2,'platform',96),
(743,0,'shelf',95),
(743,1,'claims',99),
(743,2,'cloud',81),
(744,0,'teller',63),
(744,1,'ballast',72),
(744,2,'brand',80),
(745,0,'ledger',64),
(745,1,'grid',71),
(745,2,'silicon',95),
(746,0,'rails',96),
(746,1,'brand',88),
(746,2,'shelf',72),
(747,0,'cloud',80),
(747,1,'shelf',65),
(747,2,'rails',89),
(748,0,'silicon',83),
(748,1,'vault',80),
(748,2,'crude',95),
(749,0,'bills',99),
(749,1,'cloud',88),
(749,2,'shelf',71),
(750,0,'brand',65),
(750,1,'ballast',70),
(751,0,'trial',96),
(751,1,'ballast',97),
(752,0,'shelf',98),
(752,1,'bills',80),
(753,0,'trial',81),
(753,1,'vault',90),
(754,0,'ballast',61),
(754,1,'bills',89),
(755,0,'ledger',83),
(755,1,'ballast',68),
(756,0,'claims',69),
(756,1,'teller',61),
(757,0,'vault',93),
(757,1,'claims',63),
(758,0,'trial',91),
(758,1,'rails',74),
(759,0,'shelf',81),
(759,1,'crude',76),
(760,0,'claims',71),
(760,1,'bills',98),
(761,0,'crude',77),
(761,1,'shelf',68),
(762,0,'grid',80),
(762,1,'ledger',93),
(763,0,'crude',82),
(763,1,'bills',94),
(764,0,'shelf',89),
(764,1,'rails',61),
(765,0,'cloud',60),
(765,1,'crude',70),
(766,0,'bills',90),
(766,1,'brand',70),
(767,0,'brand',90),
(767,1,'claims',84),
(768,0,'claims',80),
(768,1,'rails',64),
(769,0,'platform',76),
(769,1,'rails',99),
(770,0,'claims',90),
(770,1,'vault',80),
(771,0,'ballast',97),
(771,1,'trial',87),
(772,0,'vault',99),
(772,1,'ballast',92),
(773,0,'trial',64),
(773,1,'teller',90),
(774,0,'grid',84),
(774,1,'cloud',95),
(775,0,'cloud',67),
(775,1,'ballast',80),
(776,0,'claims',97),
(776,1,'cloud',83),
(777,0,'claims',67),
(777,1,'platform',99),
(778,0,'shelf',61),
(778,1,'ballast',97),
(779,0,'cloud',89),
(779,1,'shelf',94),
(780,0,'bills',89),
(780,1,'degen',94),
(781,0,'bills',72),
(781,1,'grid',99),
(782,0,'trial',61),
(782,1,'rails',70),
(783,0,'platform',88),
(783,1,'brand',60),
(784,0,'ledger',81),
(784,1,'platform',79),
(785,0,'claims',80),
(785,1,'ledger',60),
(786,0,'platform',77),
(786,1,'silicon',70),
(787,0,'cloud',93),
(787,1,'degen',93),
(788,0,'cloud',90),
(788,1,'claims',76),
(789,0,'shelf',94),
(789,1,'degen',61),
(790,0,'brand',92),
(790,1,'trial',85),
(791,0,'rails',67),
(791,1,'bills',92),
(792,0,'rails',77),
(792,1,'brand',100),
(793,0,'grid',89),
(793,1,'ledger',82),
(794,0,'trial',72),
(794,1,'rails',70),
(795,0,'rails',74),
(795,1,'teller',64),
(796,0,'ballast',65),
(796,1,'bills',60),
(797,0,'shelf',69),
(797,1,'grid',65),
(798,0,'teller',67),
(798,1,'cloud',85),
(799,0,'shelf',73),
(799,1,'silicon',60),
(800,0,'platform',95),
(800,1,'grid',72),
(801,0,'grid',80),
(801,1,'cloud',87),
(802,0,'ledger',98),
(802,1,'brand',95),
(803,0,'silicon',91),
(803,1,'vault',67),
(804,0,'vault',88),
(804,1,'grid',100),
(805,0,'brand',64),
(805,1,'cloud',73),
(806,0,'grid',93),
(806,1,'trial',84),
(807,0,'shelf',82),
(807,1,'bills',73),
(808,0,'brand',95),
(808,1,'bills',74),
(809,0,'bills',62),
(809,1,'claims',96),
(810,0,'rails',66),
(810,1,'bills',100),
(811,0,'brand',74),
(811,1,'trial',92),
(812,0,'shelf',86),
(812,1,'ledger',99),
(813,0,'ballast',79),
(813,1,'cloud',100),
(814,0,'ledger',62),
(814,1,'trial',80),
(815,0,'bills',86),
(815,1,'ballast',62),
(816,0,'claims',60),
(816,1,'ledger',96),
(817,0,'crude',77),
(817,1,'silicon',68),
(818,0,'cloud',60),
(818,1,'ballast',84),
(819,0,'cloud',94),
(819,1,'grid',75),
(820,0,'ledger',98),
(820,1,'brand',81),
(821,0,'shelf',98),
(821,1,'ledger',75),
(822,0,'claims',65),
(822,1,'trial',61),
(823,0,'rails',85),
(823,1,'shelf',89),
(824,0,'brand',75),
(824,1,'vault',60),
(825,0,'bills',93),
(825,1,'cloud',62),
(826,0,'platform',86),
(826,1,'brand',75),
(827,0,'cloud',82),
(827,1,'bills',100),
(828,0,'rails',100),
(828,1,'grid',65),
(829,0,'cloud',95),
(829,1,'vault',64),
(830,0,'vault',80),
(830,1,'ballast',97),
(831,0,'bills',97),
(831,1,'grid',76),
(832,0,'brand',96),
(832,1,'bills',77),
(833,0,'grid',64),
(833,1,'silicon',71),
(834,0,'rails',87),
(834,1,'vault',80),
(835,0,'trial',64),
(835,1,'platform',74),
(836,0,'bills',64),
(836,1,'ballast',81),
(837,0,'rails',85),
(837,1,'ledger',98),
(838,0,'rails',78),
(838,1,'degen',98),
(839,0,'brand',89),
(839,1,'vault',98),
(840,0,'ledger',96),
(840,1,'shelf',61),
(841,0,'ledger',64),
(841,1,'vault',73),
(842,0,'shelf',68),
(842,1,'cloud',81),
(843,0,'rails',95),
(843,1,'crude',71),
(844,0,'grid',67),
(844,1,'platform',97),
(845,0,'rails',100),
(845,1,'bills',93),
(846,0,'ledger',82),
(846,1,'rails',66),
(847,0,'ballast',61),
(847,1,'shelf',76),
(848,0,'ledger',85),
(848,1,'grid',78),
(849,0,'silicon',80),
(849,1,'teller',62),
(850,0,'ballast',75),
(850,1,'platform',88),
(851,0,'brand',88),
(851,1,'rails',84),
(852,0,'claims',80),
(852,1,'vault',89),
(853,0,'rails',63),
(853,1,'trial',76),
(854,0,'trial',62),
(854,1,'shelf',94),
(855,0,'vault',91),
(855,1,'ballast',62),
(856,0,'claims',64),
(856,1,'rails',80),
(857,0,'trial',73),
(857,1,'ballast',84),
(858,0,'trial',98),
(858,1,'cloud',85),
(859,0,'claims',78),
(859,1,'ledger',87),
(860,0,'shelf',93),
(860,1,'ballast',98),
(861,0,'crude',81),
(861,1,'claims',64),
(862,0,'bills',96),
(862,1,'platform',66),
(863,0,'rails',100),
(863,1,'claims',71),
(864,0,'cloud',93),
(864,1,'ballast',98),
(865,0,'grid',96),
(865,1,'brand',68),
(866,0,'ledger',94),
(866,1,'vault',84),
(867,0,'shelf',72),
(867,1,'crude',65),
(868,0,'claims',70),
(868,1,'trial',68),
(869,0,'ballast',73),
(869,1,'ledger',97),
(870,0,'claims',79),
(870,1,'grid',66),
(871,0,'shelf',72),
(871,1,'grid',93),
(872,0,'platform',83),
(872,1,'grid',69),
(873,0,'bills',89),
(873,1,'shelf',93),
(874,0,'brand',72),
(874,1,'ballast',77),
(875,0,'ledger',79),
(875,1,'rails',93),
(876,0,'cloud',71),
(876,1,'shelf',85),
(877,0,'platform',74),
(877,1,'bills',78),
(878,0,'teller',98),
(878,1,'vault',63),
(879,0,'grid',62),
(879,1,'vault',63),
(880,0,'trial',62),
(880,1,'ballast',96),
(881,0,'crude',83),
(881,1,'cloud',97),
(882,0,'bills',75),
(882,1,'brand',95),
(883,0,'degen',74),
(883,1,'ballast',73),
(884,0,'brand',89),
(884,1,'bills',66),
(885,0,'platform',75),
(885,1,'grid',100),
(886,0,'ballast',90),
(886,1,'brand',77),
(887,0,'grid',91),
(887,1,'claims',99),
(888,0,'shelf',99),
(888,1,'cloud',83),
(889,0,'shelf',66),
(889,1,'crude',72),
(890,0,'bills',84),
(890,1,'ballast',66),
(891,0,'teller',78),
(891,1,'shelf',99),
(892,0,'grid',62),
(892,1,'ledger',78),
(893,0,'bills',100),
(893,1,'ballast',81),
(894,0,'trial',64),
(894,1,'bills',85),
(895,0,'brand',73),
(895,1,'silicon',83),
(896,0,'shelf',81),
(896,1,'silicon',97),
(897,0,'brand',90),
(897,1,'rails',78),
(898,0,'trial',87),
(898,1,'ballast',100),
(899,0,'platform',97),
(899,1,'vault',69),
(900,0,'grid',100),
(900,1,'trial',64),
(901,0,'brand',60),
(901,1,'shelf',84),
(902,0,'vault',66),
(902,1,'claims',94),
(903,0,'degen',84),
(903,1,'ballast',74),
(904,0,'crude',89),
(904,1,'ledger',88),
(905,0,'ballast',67),
(905,1,'shelf',62),
(906,0,'rails',90),
(906,1,'bills',62),
(907,0,'shelf',99),
(907,1,'claims',93),
(908,0,'shelf',75),
(908,1,'vault',93),
(909,0,'bills',93),
(909,1,'shelf',99),
(910,0,'brand',84),
(910,1,'ballast',65),
(911,0,'shelf',79),
(911,1,'rails',85),
(912,0,'brand',91),
(912,1,'ledger',100),
(913,0,'ledger',88),
(913,1,'platform',83),
(914,0,'bills',61),
(914,1,'grid',97),
(915,0,'bills',60),
(915,1,'ledger',96),
(916,0,'claims',70),
(916,1,'brand',91),
(917,0,'ledger',68),
(917,1,'claims',62),
(918,0,'vault',87),
(918,1,'grid',91),
(919,0,'shelf',97),
(919,1,'silicon',85),
(920,0,'shelf',74),
(920,1,'grid',93),
(921,0,'shelf',76),
(921,1,'grid',63),
(922,0,'ballast',92),
(922,1,'vault',90),
(923,0,'claims',69),
(923,1,'brand',96),
(924,0,'claims',82),
(924,1,'shelf',82),
(925,0,'grid',94),
(925,1,'rails',91),
(926,0,'shelf',94),
(926,1,'trial',61),
(927,0,'grid',89),
(927,1,'claims',76),
(928,0,'shelf',91),
(928,1,'bills',63),
(929,0,'degen',84),
(929,1,'crude',96),
(930,0,'bills',78),
(930,1,'grid',92),
(931,0,'silicon',90),
(931,1,'ledger',96),
(932,0,'cloud',96),
(932,1,'crude',82),
(933,0,'platform',95),
(933,1,'rails',63),
(934,0,'claims',85),
(934,1,'platform',88),
(935,0,'ledger',82),
(935,1,'shelf',92),
(936,0,'ballast',62),
(936,1,'cloud',90),
(937,0,'degen',83),
(937,1,'brand',87),
(938,0,'claims',88),
(938,1,'brand',67),
(939,0,'teller',90),
(939,1,'trial',82),
(940,0,'platform',69),
(940,1,'brand',71),
(941,0,'platform',87),
(941,1,'ballast',61),
(942,0,'vault',67),
(942,1,'bills',87),
(943,0,'brand',89),
(943,1,'trial',92),
(944,0,'shelf',100),
(944,1,'vault',72),
(945,0,'crude',89),
(945,1,'vault',62),
(946,0,'bills',76),
(946,1,'teller',80),
(947,0,'platform',89),
(947,1,'cloud',63),
(948,0,'crude',77),
(948,1,'ballast',91),
(949,0,'brand',88),
(949,1,'bills',91),
(950,0,'cloud',62),
(950,1,'grid',62),
(951,0,'ledger',71),
(951,1,'claims',85),
(952,0,'platform',83),
(952,1,'bills',78),
(953,0,'bills',77),
(953,1,'shelf',84),
(954,0,'ballast',90),
(954,1,'ledger',90),
(955,0,'claims',99),
(955,1,'trial',79),
(956,0,'ledger',72),
(956,1,'claims',68),
(957,0,'bills',95),
(957,1,'cloud',95),
(958,0,'grid',70),
(958,1,'crude',72),
(959,0,'trial',72),
(959,1,'shelf',93),
(960,0,'bills',67),
(960,1,'grid',100),
(961,0,'grid',68),
(961,1,'ballast',76),
(962,0,'grid',84),
(962,1,'ballast',89),
(963,0,'degen',99),
(963,1,'bills',65),
(964,0,'shelf',62),
(964,1,'ballast',84),
(965,0,'cloud',86),
(965,1,'claims',62),
(966,0,'ballast',93),
(966,1,'teller',61),
(967,0,'claims',82),
(967,1,'platform',64),
(968,0,'trial',81),
(968,1,'brand',83),
(969,0,'claims',66),
(969,1,'crude',79),
(970,0,'vault',72),
(970,1,'trial',67),
(971,0,'platform',87),
(971,1,'ballast',66),
(972,0,'shelf',90),
(972,1,'rails',64),
(973,0,'platform',99),
(973,1,'shelf',61),
(974,0,'brand',68),
(974,1,'shelf',98),
(975,0,'grid',76),
(975,1,'shelf',82),
(976,0,'bills',82),
(976,1,'crude',98),
(977,0,'vault',95),
(977,1,'bills',84),
(978,0,'cloud',78),
(978,1,'platform',64),
(979,0,'shelf',65),
(979,1,'ledger',96),
(980,0,'vault',94),
(980,1,'bills',72),
(981,0,'claims',74),
(981,1,'grid',88),
(982,0,'shelf',86),
(982,1,'grid',97),
(983,0,'vault',93),
(983,1,'ballast',81),
(984,0,'bills',75),
(984,1,'brand',68),
(985,0,'grid',82),
(985,1,'vault',78),
(986,0,'platform',91),
(986,1,'shelf',76),
(987,0,'vault',100),
(987,1,'bills',94),
(988,0,'vault',71),
(988,1,'ballast',72),
(989,0,'teller',66),
(989,1,'rails',84),
(990,0,'ballast',97),
(990,1,'cloud',91),
(991,0,'ballast',83),
(991,1,'ledger',95),
(992,0,'claims',61),
(992,1,'grid',63),
(993,0,'teller',65),
(993,1,'grid',92),
(994,0,'vault',61),
(994,1,'bills',69),
(995,0,'rails',74),
(995,1,'silicon',89),
(996,0,'bills',68),
(996,1,'platform',86),
(997,0,'brand',81),
(997,1,'silicon',83),
(998,0,'brand',83),
(998,1,'trial',95),
(999,0,'grid',99),
(999,1,'bills',99),
(1000,0,'grid',75),
(1000,1,'platform',80),
(1001,0,'cloud',71),
(1001,1,'trial',91),
(1002,0,'trial',89),
(1002,1,'bills',95),
(1003,0,'ledger',95),
(1003,1,'shelf',71),
(1004,0,'cloud',86),
(1004,1,'vault',92),
(1005,0,'shelf',83),
(1005,1,'bills',94),
(1006,0,'rails',80),
(1006,1,'claims',82),
(1007,0,'ballast',89),
(1007,1,'bills',94),
(1008,0,'shelf',72),
(1008,1,'brand',75),
(1009,0,'silicon',68),
(1009,1,'shelf',79),
(1010,0,'bills',84),
(1010,1,'shelf',85),
(1011,0,'bills',87),
(1011,1,'rails',78),
(1012,0,'ballast',97),
(1012,1,'brand',76),
(1013,0,'ledger',64),
(1013,1,'bills',68),
(1014,0,'vault',84),
(1014,1,'shelf',96),
(1015,0,'teller',81),
(1015,1,'ballast',87),
(1016,0,'claims',85),
(1016,1,'brand',82),
(1017,0,'rails',70),
(1017,1,'vault',86),
(1018,0,'brand',90),
(1018,1,'cloud',60),
(1019,0,'trial',100),
(1019,1,'cloud',100),
(1020,0,'crude',66),
(1020,1,'ledger',91),
(1021,0,'rails',78),
(1021,1,'crude',66),
(1022,0,'ledger',87),
(1022,1,'rails',94),
(1023,0,'bills',94),
(1023,1,'shelf',98),
(1024,0,'crude',79),
(1024,1,'rails',63),
(1025,0,'ballast',67),
(1025,1,'silicon',62),
(1026,0,'crude',83),
(1026,1,'rails',70),
(1027,0,'trial',60),
(1027,1,'teller',90),
(1028,0,'shelf',69),
(1028,1,'ledger',63),
(1029,0,'bills',96),
(1029,1,'trial',74),
(1030,0,'cloud',88),
(1030,1,'rails',96),
(1031,0,'brand',99),
(1031,1,'bills',60),
(1032,0,'silicon',61),
(1032,1,'ballast',98),
(1033,0,'vault',80),
(1033,1,'grid',72),
(1034,0,'trial',96),
(1034,1,'ledger',98),
(1035,0,'vault',85),
(1035,1,'trial',90),
(1036,0,'cloud',85),
(1036,1,'ledger',72),
(1037,0,'crude',100),
(1037,1,'teller',72),
(1038,0,'brand',88),
(1038,1,'cloud',78),
(1039,0,'brand',77),
(1039,1,'ballast',83),
(1040,0,'shelf',61),
(1040,1,'cloud',74),
(1041,0,'platform',87),
(1041,1,'rails',92),
(1042,0,'claims',69),
(1042,1,'brand',99),
(1043,0,'grid',89),
(1043,1,'crude',89),
(1044,0,'claims',83),
(1044,1,'cloud',89),
(1045,0,'platform',96),
(1045,1,'rails',65),
(1046,0,'ballast',73),
(1046,1,'cloud',80),
(1047,0,'trial',89),
(1047,1,'rails',99),
(1048,0,'cloud',95),
(1048,1,'vault',89),
(1049,0,'grid',86),
(1049,1,'crude',67),
(1050,0,'brand',73),
(1050,1,'platform',60),
(1051,0,'ledger',89),
(1051,1,'platform',69),
(1052,0,'brand',72),
(1052,1,'claims',64),
(1053,0,'rails',92),
(1053,1,'crude',83),
(1054,0,'grid',78),
(1054,1,'brand',61),
(1055,0,'platform',89),
(1055,1,'rails',77),
(1056,0,'rails',78),
(1056,1,'ballast',73),
(1057,0,'grid',64),
(1057,1,'bills',79),
(1058,0,'vault',74),
(1058,1,'claims',90),
(1059,0,'vault',76),
(1059,1,'rails',67),
(1060,0,'vault',87),
(1060,1,'brand',79),
(1061,0,'brand',77),
(1061,1,'rails',93),
(1062,0,'rails',81),
(1062,1,'vault',86),
(1063,0,'ledger',92),
(1063,1,'rails',98),
(1064,0,'platform',71),
(1064,1,'ballast',94),
(1065,0,'bills',77),
(1065,1,'claims',76),
(1066,0,'cloud',93),
(1066,1,'ballast',90),
(1067,0,'grid',66),
(1067,1,'rails',98),
(1068,0,'crude',76),
(1068,1,'trial',95),
(1069,0,'brand',96),
(1069,1,'trial',73),
(1070,0,'silicon',82),
(1070,1,'cloud',98),
(1071,0,'bills',86),
(1071,1,'ledger',73),
(1072,0,'rails',77),
(1072,1,'ledger',77),
(1073,0,'bills',89),
(1073,1,'shelf',65),
(1074,0,'claims',64),
(1074,1,'platform',98),
(1075,0,'cloud',89),
(1075,1,'ballast',100),
(1076,0,'claims',70),
(1076,1,'bills',73),
(1077,0,'ledger',96),
(1077,1,'claims',93),
(1078,0,'vault',100),
(1078,1,'claims',92),
(1079,0,'shelf',70),
(1079,1,'brand',72),
(1080,0,'brand',86),
(1080,1,'bills',63),
(1081,0,'vault',61),
(1081,1,'shelf',79),
(1082,0,'grid',97),
(1082,1,'cloud',76),
(1083,0,'crude',86),
(1083,1,'rails',74),
(1084,0,'claims',85),
(1084,1,'grid',100),
(1085,0,'crude',91),
(1085,1,'shelf',62),
(1086,0,'brand',74),
(1086,1,'cloud',100),
(1087,0,'grid',93),
(1087,1,'degen',69),
(1088,0,'bills',82),
(1088,1,'brand',79),
(1089,0,'brand',61),
(1089,1,'vault',93),
(1090,0,'silicon',100),
(1090,1,'rails',70),
(1091,0,'ballast',60),
(1091,1,'grid',90),
(1092,0,'brand',64),
(1092,1,'cloud',77),
(1093,0,'crude',87),
(1093,1,'claims',95),
(1094,0,'grid',74),
(1094,1,'claims',90),
(1095,0,'vault',68),
(1095,1,'bills',74),
(1096,0,'grid',60),
(1096,1,'ballast',63),
(1097,0,'silicon',79),
(1097,1,'rails',88),
(1098,0,'rails',89),
(1098,1,'brand',98),
(1099,0,'teller',77),
(1099,1,'grid',63),
(1100,0,'brand',91),
(1100,1,'bills',98),
(1101,0,'ledger',88),
(1101,1,'bills',82),
(1102,0,'brand',87),
(1102,1,'claims',64),
(1103,0,'brand',63),
(1103,1,'bills',95),
(1104,0,'ballast',82),
(1104,1,'shelf',97),
(1105,0,'shelf',68),
(1105,1,'ledger',66),
(1106,0,'teller',97),
(1106,1,'claims',89),
(1107,0,'shelf',64),
(1107,1,'platform',68),
(1108,0,'crude',84),
(1108,1,'ledger',71),
(1109,0,'trial',82),
(1109,1,'bills',84),
(1110,0,'brand',89),
(1110,1,'cloud',97),
(1111,0,'vault',71),
(1111,1,'ballast',64),
(1112,0,'vault',68),
(1112,1,'cloud',70),
(1113,0,'ballast',88),
(1113,1,'shelf',70),
(1114,0,'trial',96),
(1114,1,'grid',79),
(1115,0,'ledger',66),
(1115,1,'grid',100),
(1116,0,'brand',65),
(1116,1,'silicon',73),
(1117,0,'bills',78),
(1117,1,'vault',80),
(1118,0,'cloud',68),
(1118,1,'shelf',65),
(1119,0,'shelf',63),
(1119,1,'grid',64),
(1120,0,'ledger',75),
(1120,1,'vault',99),
(1121,0,'brand',88),
(1121,1,'claims',62),
(1122,0,'rails',89),
(1122,1,'ledger',74),
(1123,0,'brand',62),
(1123,1,'vault',96),
(1124,0,'vault',81),
(1124,1,'crude',76),
(1125,0,'brand',78),
(1125,1,'shelf',60),
(1126,0,'brand',61),
(1126,1,'ledger',68),
(1127,0,'grid',99),
(1127,1,'silicon',72),
(1128,0,'ballast',62),
(1128,1,'rails',78),
(1129,0,'ballast',69),
(1129,1,'grid',95),
(1130,0,'bills',68),
(1130,1,'ballast',79),
(1131,0,'vault',69),
(1131,1,'grid',79),
(1132,0,'brand',91),
(1132,1,'grid',76),
(1133,0,'grid',63),
(1133,1,'ballast',81),
(1134,0,'ledger',79),
(1134,1,'brand',80),
(1135,0,'bills',70),
(1135,1,'ledger',78),
(1136,0,'rails',91),
(1136,1,'ledger',97),
(1137,0,'claims',85),
(1137,1,'grid',89),
(1138,0,'vault',90),
(1138,1,'bills',96),
(1139,0,'crude',72),
(1139,1,'ballast',69),
(1140,0,'ledger',78),
(1140,1,'shelf',94),
(1141,0,'shelf',100),
(1141,1,'rails',67),
(1142,0,'claims',72),
(1142,1,'brand',87),
(1143,0,'brand',96),
(1143,1,'degen',60),
(1144,0,'grid',61),
(1144,1,'rails',99),
(1145,0,'bills',94),
(1145,1,'brand',97),
(1146,0,'brand',100),
(1146,1,'rails',73),
(1147,0,'crude',76),
(1147,1,'bills',69),
(1148,0,'ballast',65),
(1148,1,'ledger',74),
(1149,0,'ballast',82),
(1149,1,'vault',78),
(1150,0,'trial',100),
(1150,1,'claims',69),
(1151,0,'ledger',97),
(1151,1,'crude',61),
(1152,0,'grid',95),
(1152,1,'trial',80),
(1153,0,'trial',71),
(1153,1,'ledger',63),
(1154,0,'shelf',93),
(1154,1,'degen',73),
(1155,0,'ballast',70),
(1155,1,'shelf',95),
(1156,0,'ballast',66),
(1156,1,'rails',79),
(1157,0,'brand',84),
(1157,1,'silicon',75),
(1158,0,'degen',84),
(1158,1,'bills',84),
(1159,0,'rails',91),
(1159,1,'trial',75),
(1160,0,'platform',64),
(1160,1,'vault',83),
(1161,0,'grid',86),
(1161,1,'ballast',93),
(1162,0,'vault',83),
(1162,1,'brand',79),
(1163,0,'ledger',98),
(1163,1,'cloud',69),
(1164,0,'cloud',87),
(1164,1,'crude',81),
(1165,0,'ballast',95),
(1165,1,'trial',82),
(1166,0,'ballast',98),
(1166,1,'shelf',100),
(1167,0,'trial',96),
(1167,1,'rails',78),
(1168,0,'cloud',92),
(1168,1,'rails',97),
(1169,0,'crude',93),
(1169,1,'claims',63),
(1170,0,'crude',97),
(1170,1,'trial',82),
(1171,0,'bills',65),
(1171,1,'claims',63),
(1172,0,'brand',96),
(1172,1,'ledger',77),
(1173,0,'grid',81),
(1173,1,'ledger',98),
(1174,0,'ledger',76),
(1174,1,'platform',92),
(1175,0,'brand',68),
(1175,1,'silicon',90),
(1176,0,'brand',92),
(1176,1,'claims',68),
(1177,0,'brand',65),
(1177,1,'cloud',87),
(1178,0,'grid',94),
(1178,1,'claims',66),
(1179,0,'bills',64),
(1179,1,'claims',90),
(1180,0,'cloud',99),
(1180,1,'shelf',86),
(1181,0,'vault',76),
(1181,1,'ballast',82),
(1182,0,'vault',67),
(1182,1,'shelf',90),
(1183,0,'teller',98),
(1183,1,'shelf',66),
(1184,0,'cloud',66),
(1184,1,'ledger',72),
(1185,0,'claims',60),
(1185,1,'bills',73),
(1186,0,'vault',94),
(1186,1,'crude',69),
(1187,0,'grid',74),
(1187,1,'ballast',83),
(1188,0,'brand',93),
(1188,1,'shelf',73),
(1189,0,'rails',89),
(1189,1,'bills',91),
(1190,0,'trial',78),
(1190,1,'teller',64),
(1191,0,'cloud',97),
(1191,1,'ballast',91),
(1192,0,'vault',73),
(1192,1,'brand',78),
(1193,0,'rails',68),
(1193,1,'brand',97),
(1194,0,'bills',82),
(1194,1,'shelf',63),
(1195,0,'silicon',89),
(1195,1,'grid',79),
(1196,0,'ballast',95),
(1196,1,'trial',65),
(1197,0,'ledger',63),
(1197,1,'rails',80),
(1198,0,'vault',94),
(1198,1,'ballast',70),
(1199,0,'grid',84),
(1199,1,'trial',89),
(1200,0,'shelf',71),
(1200,1,'claims',76),
(1201,0,'platform',96),
(1201,1,'ballast',98),
(1202,0,'trial',79),
(1202,1,'rails',68),
(1203,0,'brand',99),
(1203,1,'claims',99),
(1204,0,'ledger',66),
(1204,1,'trial',83),
(1205,0,'claims',92),
(1205,1,'ledger',94),
(1206,0,'vault',61),
(1206,1,'brand',80),
(1207,0,'bills',78),
(1207,1,'crude',89),
(1208,0,'ledger',69),
(1208,1,'claims',90),
(1209,0,'ballast',88),
(1209,1,'rails',86),
(1210,0,'vault',93),
(1210,1,'brand',99),
(1211,0,'cloud',73),
(1211,1,'rails',85),
(1212,0,'brand',83),
(1212,1,'claims',60),
(1213,0,'platform',62),
(1213,1,'bills',61),
(1214,0,'ballast',88),
(1214,1,'brand',76),
(1215,0,'bills',87),
(1215,1,'crude',89),
(1216,0,'platform',90),
(1216,1,'claims',88),
(1217,0,'bills',87),
(1217,1,'claims',67),
(1218,0,'degen',71),
(1218,1,'ballast',89),
(1219,0,'ballast',85),
(1219,1,'platform',83),
(1220,0,'vault',91),
(1220,1,'platform',65),
(1221,0,'claims',64),
(1221,1,'brand',64),
(1222,0,'rails',65),
(1222,1,'shelf',78),
(1223,0,'claims',93),
(1223,1,'rails',73),
(1224,0,'grid',87),
(1224,1,'platform',66),
(1225,0,'cloud',93),
(1225,1,'bills',76),
(1226,0,'brand',88),
(1226,1,'platform',80),
(1227,0,'ledger',72),
(1227,1,'rails',84),
(1228,0,'claims',82),
(1228,1,'shelf',72),
(1229,0,'rails',75),
(1229,1,'brand',69),
(1230,0,'bills',63),
(1230,1,'rails',64),
(1231,0,'trial',67),
(1231,1,'cloud',66),
(1232,0,'grid',92),
(1232,1,'trial',86),
(1233,0,'brand',99),
(1233,1,'bills',81),
(1234,0,'claims',74),
(1234,1,'ledger',75),
(1235,0,'vault',99),
(1235,1,'trial',72),
(1236,0,'brand',62),
(1236,1,'cloud',64),
(1237,0,'cloud',69),
(1237,1,'bills',72),
(1238,0,'vault',72),
(1238,1,'rails',75),
(1239,0,'trial',64),
(1239,1,'bills',72),
(1240,0,'bills',87),
(1240,1,'rails',60),
(1241,0,'ledger',88),
(1241,1,'grid',87),
(1242,0,'trial',73),
(1242,1,'bills',86),
(1243,0,'ledger',63),
(1243,1,'brand',94),
(1244,0,'shelf',66),
(1244,1,'cloud',81),
(1245,0,'ledger',76),
(1245,1,'claims',100),
(1246,0,'silicon',85),
(1246,1,'brand',77),
(1247,0,'ledger',95),
(1247,1,'vault',64),
(1248,0,'bills',66),
(1248,1,'claims',66),
(1249,0,'shelf',60),
(1249,1,'platform',70),
(1250,0,'shelf',65),
(1250,1,'grid',83),
(1251,0,'silicon',79),
(1251,1,'trial',83),
(1252,0,'shelf',71),
(1252,1,'claims',80),
(1253,0,'shelf',69),
(1253,1,'vault',75),
(1254,0,'crude',79),
(1254,1,'shelf',82),
(1255,0,'claims',84),
(1255,1,'platform',80),
(1256,0,'brand',97),
(1256,1,'degen',63),
(1257,0,'teller',75),
(1257,1,'platform',80),
(1258,0,'shelf',98),
(1258,1,'vault',90),
(1259,0,'vault',97),
(1259,1,'trial',74),
(1260,0,'vault',71),
(1260,1,'grid',62),
(1261,0,'brand',89),
(1261,1,'shelf',86),
(1262,0,'ballast',89),
(1262,1,'crude',76),
(1263,0,'claims',90),
(1263,1,'brand',91),
(1264,0,'rails',90),
(1264,1,'platform',87),
(1265,0,'cloud',61),
(1265,1,'grid',96),
(1266,0,'cloud',95),
(1266,1,'ballast',64),
(1267,0,'claims',96),
(1267,1,'ballast',61),
(1268,0,'ballast',72),
(1268,1,'silicon',90),
(1269,0,'silicon',98),
(1269,1,'teller',69),
(1270,0,'bills',81),
(1270,1,'silicon',89),
(1271,0,'rails',96),
(1271,1,'grid',71),
(1272,0,'grid',79),
(1272,1,'claims',91),
(1273,0,'vault',67),
(1273,1,'ballast',89),
(1274,0,'ballast',78),
(1274,1,'trial',93),
(1275,0,'ballast',82),
(1275,1,'ledger',91),
(1276,0,'cloud',98),
(1276,1,'ballast',60),
(1277,0,'degen',64),
(1277,1,'vault',92),
(1278,0,'ledger',88),
(1278,1,'silicon',81),
(1279,0,'shelf',81),
(1279,1,'ballast',97),
(1280,0,'brand',79),
(1280,1,'bills',84),
(1281,0,'cloud',97),
(1281,1,'vault',92),
(1282,0,'ballast',70),
(1282,1,'rails',79),
(1283,0,'bills',92),
(1283,1,'crude',68),
(1284,0,'rails',65),
(1284,1,'cloud',70),
(1285,0,'teller',68),
(1285,1,'ballast',74),
(1286,0,'cloud',60),
(1286,1,'rails',98),
(1287,0,'ballast',92),
(1287,1,'ledger',85),
(1288,0,'brand',69),
(1288,1,'ballast',63),
(1289,0,'cloud',64),
(1289,1,'claims',77),
(1290,0,'cloud',61),
(1290,1,'claims',64),
(1291,0,'bills',91),
(1291,1,'cloud',75),
(1292,0,'shelf',86),
(1292,1,'rails',81),
(1293,0,'shelf',79),
(1293,1,'bills',74),
(1294,0,'ballast',90),
(1294,1,'claims',74),
(1295,0,'platform',83),
(1295,1,'silicon',70),
(1296,0,'ballast',78),
(1296,1,'grid',82),
(1297,0,'ballast',69),
(1297,1,'trial',61),
(1298,0,'brand',66),
(1298,1,'shelf',66),
(1299,0,'degen',91),
(1299,1,'cloud',75),
(1300,0,'trial',94),
(1300,1,'platform',73),
(1301,0,'grid',85),
(1301,1,'vault',71),
(1302,0,'trial',96),
(1302,1,'brand',77),
(1303,0,'ballast',97),
(1303,1,'grid',84),
(1304,0,'grid',74),
(1304,1,'ballast',79),
(1305,0,'grid',65),
(1305,1,'ledger',98),
(1306,0,'grid',80),
(1306,1,'rails',85),
(1307,0,'crude',67),
(1307,1,'trial',100),
(1308,0,'grid',70),
(1308,1,'claims',81),
(1309,0,'cloud',75),
(1309,1,'ballast',87),
(1310,0,'silicon',91),
(1310,1,'cloud',75),
(1311,0,'ballast',87),
(1311,1,'vault',61),
(1312,0,'bills',72),
(1312,1,'shelf',100),
(1313,0,'vault',90),
(1313,1,'bills',78),
(1314,0,'grid',65),
(1314,1,'vault',65),
(1315,0,'ledger',96),
(1315,1,'silicon',80),
(1316,0,'shelf',60),
(1316,1,'claims',83),
(1317,0,'crude',73),
(1317,1,'platform',99),
(1318,0,'vault',72),
(1318,1,'crude',74),
(1319,0,'trial',88),
(1319,1,'ballast',62),
(1320,0,'vault',62),
(1320,1,'ledger',100),
(1321,0,'shelf',93),
(1321,1,'ballast',83),
(1322,0,'shelf',90),
(1322,1,'grid',83),
(1323,0,'claims',96),
(1323,1,'cloud',94),
(1324,0,'brand',95),
(1324,1,'shelf',71),
(1325,0,'crude',99),
(1325,1,'shelf',62),
(1326,0,'trial',97),
(1326,1,'degen',77),
(1327,0,'teller',62),
(1327,1,'claims',97),
(1328,0,'shelf',96),
(1328,1,'brand',100),
(1329,0,'platform',89),
(1329,1,'ledger',92),
(1330,0,'grid',64),
(1330,1,'rails',64),
(1331,0,'ballast',72),
(1331,1,'grid',86),
(1332,0,'vault',99),
(1332,1,'crude',93),
(1333,0,'shelf',74),
(1333,1,'ballast',62),
(1334,0,'shelf',99),
(1334,1,'rails',90),
(1335,0,'rails',74),
(1335,1,'bills',71),
(1336,0,'ballast',85),
(1336,1,'grid',72),
(1337,0,'rails',76),
(1337,1,'silicon',80),
(1338,0,'shelf',80),
(1338,1,'trial',73),
(1339,0,'bills',61),
(1339,1,'grid',93),
(1340,0,'grid',81),
(1340,1,'bills',66),
(1341,0,'rails',67),
(1341,1,'vault',84),
(1342,0,'ballast',100),
(1342,1,'platform',90),
(1343,0,'rails',94),
(1343,1,'grid',80),
(1344,0,'bills',75),
(1344,1,'vault',73),
(1345,0,'crude',80),
(1345,1,'ledger',92),
(1346,0,'shelf',65),
(1346,1,'vault',78),
(1347,0,'brand',91),
(1347,1,'rails',66),
(1348,0,'platform',66),
(1348,1,'degen',98),
(1349,0,'brand',72),
(1349,1,'shelf',63),
(1350,0,'ballast',70),
(1350,1,'rails',79),
(1351,0,'teller',63),
(1351,1,'cloud',70),
(1352,0,'claims',65),
(1352,1,'silicon',94),
(1353,0,'vault',89),
(1353,1,'claims',82),
(1354,0,'shelf',91),
(1354,1,'cloud',84),
(1355,0,'claims',95),
(1355,1,'rails',81),
(1356,0,'bills',65),
(1356,1,'platform',98),
(1357,0,'ledger',82),
(1357,1,'ballast',82),
(1358,0,'brand',89),
(1358,1,'claims',65),
(1359,0,'trial',93),
(1359,1,'platform',82),
(1360,0,'platform',91),
(1360,1,'shelf',84),
(1361,0,'ledger',64),
(1361,1,'teller',70),
(1362,0,'bills',94),
(1362,1,'ledger',85),
(1363,0,'grid',70),
(1363,1,'crude',96),
(1364,0,'ballast',64),
(1364,1,'ledger',93),
(1365,0,'claims',65),
(1365,1,'cloud',85),
(1366,0,'brand',73),
(1366,1,'crude',99),
(1367,0,'cloud',94),
(1367,1,'silicon',99),
(1368,0,'rails',66),
(1368,1,'shelf',69),
(1369,0,'crude',87),
(1369,1,'brand',93),
(1370,0,'rails',72),
(1370,1,'shelf',70),
(1371,0,'silicon',64),
(1371,1,'vault',88),
(1372,0,'brand',66),
(1372,1,'platform',98),
(1373,0,'degen',86),
(1373,1,'crude',96),
(1374,0,'brand',85),
(1374,1,'ledger',91),
(1375,0,'grid',87),
(1375,1,'shelf',69),
(1376,0,'platform',68),
(1376,1,'bills',89),
(1377,0,'ballast',86),
(1377,1,'claims',83),
(1378,0,'grid',97),
(1378,1,'vault',63),
(1379,0,'brand',88),
(1379,1,'bills',71),
(1380,0,'brand',76),
(1380,1,'grid',100),
(1381,0,'claims',68),
(1381,1,'vault',80),
(1382,0,'platform',79),
(1382,1,'ballast',68),
(1383,0,'grid',94),
(1383,1,'silicon',68),
(1384,0,'brand',69),
(1384,1,'trial',91),
(1385,0,'rails',60),
(1385,1,'claims',99),
(1386,0,'trial',90),
(1386,1,'platform',61),
(1387,0,'grid',80),
(1387,1,'trial',74),
(1388,0,'ballast',75),
(1388,1,'silicon',70),
(1389,0,'vault',75),
(1389,1,'teller',83),
(1390,0,'silicon',73),
(1390,1,'claims',97),
(1391,0,'platform',71),
(1391,1,'bills',67),
(1392,0,'claims',86),
(1392,1,'silicon',93),
(1393,0,'bills',69),
(1393,1,'crude',87),
(1394,0,'trial',70),
(1394,1,'ballast',60),
(1395,0,'claims',95),
(1395,1,'ledger',83),
(1396,0,'brand',62),
(1396,1,'trial',70),
(1397,0,'shelf',68),
(1397,1,'vault',88),
(1398,0,'ballast',92),
(1398,1,'shelf',92),
(1399,0,'brand',94),
(1399,1,'ballast',83),
(1400,0,'rails',77),
(1400,1,'trial',100),
(1401,0,'shelf',86),
(1401,1,'grid',69),
(1402,0,'ballast',77),
(1402,1,'brand',81),
(1403,0,'rails',100),
(1403,1,'grid',60),
(1404,0,'ballast',75),
(1404,1,'ledger',73),
(1405,0,'trial',90),
(1405,1,'rails',62),
(1406,0,'ledger',88),
(1406,1,'trial',82),
(1407,0,'shelf',74),
(1407,1,'bills',67),
(1408,0,'rails',73),
(1408,1,'teller',64),
(1409,0,'platform',91),
(1409,1,'bills',60),
(1410,0,'vault',94),
(1410,1,'ballast',71),
(1411,0,'brand',98),
(1411,1,'vault',90),
(1412,0,'degen',83),
(1412,1,'platform',60),
(1413,0,'grid',93),
(1413,1,'rails',68),
(1414,0,'bills',83),
(1414,1,'ledger',61),
(1415,0,'shelf',68),
(1415,1,'vault',64),
(1416,0,'grid',85),
(1416,1,'bills',83),
(1417,0,'silicon',71),
(1417,1,'ballast',65),
(1418,0,'shelf',64),
(1418,1,'cloud',86),
(1419,0,'shelf',65),
(1419,1,'brand',90),
(1420,0,'platform',84),
(1420,1,'ledger',77),
(1421,0,'crude',94),
(1421,1,'shelf',98),
(1422,0,'ballast',89),
(1422,1,'claims',64),
(1423,0,'shelf',76),
(1423,1,'bills',79),
(1424,0,'trial',100),
(1424,1,'brand',67),
(1425,0,'rails',72),
(1425,1,'ballast',82),
(1426,0,'grid',98),
(1426,1,'teller',74),
(1427,0,'bills',92),
(1427,1,'shelf',91),
(1428,0,'vault',97),
(1428,1,'platform',97),
(1429,0,'bills',66),
(1429,1,'shelf',98),
(1430,0,'shelf',63),
(1430,1,'bills',62),
(1431,0,'grid',94),
(1431,1,'shelf',71),
(1432,0,'bills',78),
(1432,1,'brand',67),
(1433,0,'platform',74),
(1433,1,'brand',71),
(1434,0,'ledger',76),
(1434,1,'grid',67),
(1435,0,'claims',88),
(1435,1,'ballast',68),
(1436,0,'vault',79),
(1436,1,'shelf',75),
(1437,0,'cloud',100),
(1437,1,'teller',85),
(1438,0,'ledger',96),
(1438,1,'shelf',79),
(1439,0,'cloud',89),
(1439,1,'shelf',89),
(1440,0,'platform',86),
(1440,1,'grid',72),
(1441,0,'silicon',99),
(1441,1,'ledger',97),
(1442,0,'ledger',93),
(1442,1,'bills',70),
(1443,0,'rails',85),
(1443,1,'trial',85),
(1444,0,'ballast',71),
(1444,1,'silicon',95),
(1445,0,'rails',79),
(1445,1,'cloud',91),
(1446,0,'bills',71),
(1446,1,'brand',82),
(1447,0,'trial',94),
(1447,1,'shelf',83),
(1448,0,'grid',65),
(1448,1,'bills',69),
(1449,0,'vault',63),
(1449,1,'trial',74),
(1450,0,'platform',85),
(1450,1,'bills',89),
(1451,0,'grid',80),
(1451,1,'brand',60),
(1452,0,'claims',60),
(1452,1,'brand',60),
(1453,0,'shelf',88),
(1453,1,'grid',66),
(1454,0,'ballast',73),
(1454,1,'silicon',91),
(1455,0,'rails',90),
(1455,1,'brand',90),
(1456,0,'vault',93),
(1456,1,'cloud',95),
(1457,0,'brand',71),
(1457,1,'cloud',70),
(1458,0,'trial',64),
(1458,1,'bills',78),
(1459,0,'shelf',88),
(1459,1,'rails',70),
(1460,0,'degen',83),
(1460,1,'claims',64),
(1461,0,'claims',79),
(1461,1,'ledger',67),
(1462,0,'trial',90),
(1462,1,'ledger',78),
(1463,0,'shelf',90),
(1463,1,'platform',67),
(1464,0,'shelf',88),
(1464,1,'rails',95),
(1465,0,'ballast',60),
(1465,1,'ledger',69),
(1466,0,'ledger',70),
(1466,1,'silicon',79),
(1467,0,'shelf',85),
(1467,1,'cloud',72),
(1468,0,'shelf',94),
(1468,1,'claims',64),
(1469,0,'shelf',70),
(1469,1,'rails',72),
(1470,0,'vault',87),
(1470,1,'ballast',63),
(1471,0,'brand',100),
(1471,1,'rails',96),
(1472,0,'ballast',82),
(1472,1,'claims',100),
(1473,0,'rails',86),
(1473,1,'claims',70),
(1474,0,'trial',99),
(1474,1,'rails',86),
(1475,0,'vault',90),
(1475,1,'rails',93),
(1476,0,'trial',85),
(1476,1,'crude',74),
(1477,0,'cloud',67),
(1477,1,'ledger',97),
(1478,0,'platform',79),
(1478,1,'brand',95),
(1479,0,'claims',90),
(1479,1,'brand',78),
(1480,0,'vault',75),
(1480,1,'bills',82),
(1481,0,'shelf',68),
(1481,1,'silicon',77),
(1482,0,'claims',63),
(1482,1,'shelf',71),
(1483,0,'crude',99),
(1483,1,'shelf',77),
(1484,0,'shelf',87),
(1484,1,'claims',95),
(1485,0,'vault',66),
(1485,1,'bills',80),
(1486,0,'cloud',78),
(1486,1,'ledger',86),
(1487,0,'bills',80),
(1487,1,'platform',97),
(1488,0,'grid',76),
(1488,1,'brand',90),
(1489,0,'rails',81),
(1489,1,'ledger',60),
(1490,0,'ballast',71),
(1490,1,'cloud',80),
(1491,0,'cloud',77),
(1491,1,'shelf',76),
(1492,0,'rails',66),
(1492,1,'brand',97),
(1493,0,'shelf',91),
(1493,1,'ledger',62),
(1494,0,'ballast',81),
(1494,1,'claims',66),
(1495,0,'bills',88),
(1495,1,'shelf',76),
(1496,0,'grid',85),
(1496,1,'cloud',79),
(1497,0,'bills',93),
(1497,1,'cloud',84),
(1498,0,'brand',84),
(1498,1,'ledger',83),
(1499,0,'rails',82),
(1499,1,'shelf',77),
(1500,0,'shelf',86),
(1500,1,'ballast',70),
(1501,0,'grid',77),
(1501,1,'claims',68),
(1502,0,'crude',83),
(1502,1,'vault',96),
(1503,0,'claims',72),
(1503,1,'ballast',96),
(1504,0,'shelf',98),
(1504,1,'trial',65),
(1505,0,'crude',74),
(1505,1,'vault',96),
(1506,0,'cloud',96),
(1506,1,'claims',84),
(1507,0,'ballast',74),
(1507,1,'brand',73),
(1508,0,'ballast',74),
(1508,1,'ledger',65),
(1509,0,'ballast',64),
(1509,1,'platform',99),
(1510,0,'platform',72),
(1510,1,'brand',92),
(1511,0,'bills',99),
(1511,1,'vault',83),
(1512,0,'vault',76),
(1512,1,'cloud',75),
(1513,0,'cloud',88),
(1513,1,'ledger',74),
(1514,0,'grid',77),
(1514,1,'shelf',78),
(1515,0,'brand',62),
(1515,1,'ballast',62),
(1516,0,'cloud',82),
(1516,1,'brand',95),
(1517,0,'grid',69),
(1517,1,'vault',97),
(1518,0,'platform',100),
(1518,1,'degen',60),
(1519,0,'ledger',97),
(1519,1,'degen',87),
(1520,0,'ledger',66),
(1520,1,'rails',89),
(1521,0,'silicon',62),
(1521,1,'ledger',86),
(1522,0,'vault',80),
(1522,1,'ledger',66),
(1523,0,'ballast',90),
(1523,1,'cloud',82),
(1524,0,'rails',68),
(1524,1,'shelf',70),
(1525,0,'trial',76),
(1525,1,'grid',73),
(1526,0,'ballast',97),
(1526,1,'claims',100),
(1527,0,'grid',99),
(1527,1,'trial',89),
(1528,0,'rails',68),
(1528,1,'grid',88),
(1529,0,'vault',77),
(1529,1,'ledger',72),
(1530,0,'ledger',67),
(1530,1,'brand',97),
(1531,0,'cloud',76),
(1531,1,'platform',96),
(1532,0,'vault',89),
(1532,1,'grid',83),
(1533,0,'claims',94),
(1533,1,'ballast',78),
(1534,0,'claims',99),
(1534,1,'grid',91),
(1535,0,'ledger',97),
(1535,1,'ballast',77),
(1536,0,'cloud',75),
(1536,1,'bills',84),
(1537,0,'ballast',73),
(1537,1,'claims',66),
(1538,0,'rails',78),
(1538,1,'bills',60),
(1539,0,'grid',90),
(1539,1,'claims',87),
(1540,0,'platform',97),
(1540,1,'bills',63),
(1541,0,'cloud',62),
(1541,1,'rails',81),
(1542,0,'platform',87),
(1542,1,'ledger',97),
(1543,0,'grid',62),
(1543,1,'rails',100),
(1544,0,'vault',62),
(1544,1,'ballast',84),
(1545,0,'rails',67),
(1545,1,'degen',98),
(1546,0,'bills',70),
(1546,1,'ledger',94),
(1547,0,'shelf',62),
(1547,1,'ledger',88),
(1548,0,'rails',67),
(1548,1,'grid',76),
(1549,0,'ballast',88),
(1549,1,'trial',76),
(1550,0,'ledger',70),
(1550,1,'brand',89),
(1551,0,'crude',73),
(1551,1,'bills',74),
(1552,0,'ledger',95),
(1552,1,'bills',92),
(1553,0,'silicon',96),
(1553,1,'grid',90),
(1554,0,'claims',66),
(1554,1,'vault',64),
(1555,0,'ledger',61),
(1555,1,'platform',60),
(1556,0,'grid',73),
(1556,1,'brand',61),
(1557,0,'brand',70),
(1557,1,'cloud',75),
(1558,0,'bills',81),
(1558,1,'shelf',90),
(1559,0,'vault',76),
(1559,1,'teller',60),
(1560,0,'ledger',68),
(1560,1,'rails',81),
(1561,0,'ballast',72),
(1561,1,'vault',79),
(1562,0,'platform',94),
(1562,1,'ballast',68),
(1563,0,'brand',70),
(1563,1,'shelf',81),
(1564,0,'silicon',95),
(1564,1,'rails',71),
(1565,0,'bills',92),
(1565,1,'shelf',77),
(1566,0,'rails',72),
(1566,1,'shelf',85),
(1567,0,'silicon',95),
(1567,1,'ledger',69),
(1568,0,'silicon',91),
(1568,1,'vault',100),
(1569,0,'platform',78),
(1569,1,'brand',78),
(1570,0,'rails',66),
(1570,1,'brand',95),
(1571,0,'ledger',64),
(1571,1,'degen',96),
(1572,0,'rails',83),
(1572,1,'brand',86),
(1573,0,'ballast',98),
(1573,1,'ledger',72),
(1574,0,'brand',81),
(1574,1,'cloud',75),
(1575,0,'brand',91),
(1575,1,'crude',89),
(1576,0,'brand',60),
(1576,1,'vault',93),
(1577,0,'bills',77),
(1577,1,'brand',80),
(1578,0,'trial',71),
(1578,1,'platform',64),
(1579,0,'rails',88),
(1579,1,'trial',67),
(1580,0,'shelf',94),
(1580,1,'ballast',75),
(1581,0,'cloud',61),
(1581,1,'vault',72),
(1582,0,'bills',76),
(1582,1,'degen',93),
(1583,0,'silicon',71),
(1583,1,'trial',93),
(1584,0,'shelf',61),
(1584,1,'grid',75),
(1585,0,'shelf',79),
(1585,1,'rails',77),
(1586,0,'bills',81),
(1586,1,'grid',91),
(1587,0,'platform',62),
(1587,1,'crude',76),
(1588,0,'trial',83),
(1588,1,'vault',91),
(1589,0,'silicon',74),
(1589,1,'grid',84),
(1590,0,'bills',91),
(1590,1,'rails',78),
(1591,0,'grid',96),
(1591,1,'brand',66),
(1592,0,'ballast',79),
(1592,1,'vault',70),
(1593,0,'ledger',98),
(1593,1,'vault',98),
(1594,0,'grid',64),
(1594,1,'ledger',84),
(1595,0,'grid',100),
(1595,1,'ledger',87),
(1596,0,'claims',63),
(1596,1,'teller',61),
(1597,0,'ballast',98),
(1597,1,'shelf',82),
(1598,0,'claims',65),
(1598,1,'trial',60),
(1599,0,'bills',98),
(1599,1,'vault',65),
(1600,0,'shelf',95),
(1600,1,'ledger',75),
(1601,0,'crude',79),
(1601,1,'degen',76),
(1602,0,'crude',65),
(1602,1,'claims',95),
(1603,0,'claims',75),
(1603,1,'silicon',62),
(1604,0,'grid',71),
(1604,1,'trial',95),
(1605,0,'grid',80),
(1605,1,'platform',84),
(1606,0,'ledger',81),
(1606,1,'bills',84),
(1607,0,'silicon',92),
(1607,1,'crude',83),
(1608,0,'claims',81),
(1608,1,'vault',65),
(1609,0,'grid',75),
(1609,1,'cloud',94),
(1610,0,'silicon',89),
(1610,1,'platform',85),
(1611,0,'teller',73),
(1611,1,'rails',87),
(1612,0,'ballast',68),
(1612,1,'trial',98),
(1613,0,'claims',62),
(1613,1,'platform',98),
(1614,0,'silicon',72),
(1614,1,'trial',84),
(1615,0,'shelf',73),
(1615,1,'platform',91),
(1616,0,'claims',61),
(1616,1,'ledger',100),
(1617,0,'shelf',70),
(1617,1,'teller',82),
(1618,0,'vault',93),
(1618,1,'cloud',87),
(1619,0,'grid',77),
(1619,1,'ballast',69),
(1620,0,'rails',91),
(1620,1,'silicon',92),
(1621,0,'brand',76),
(1621,1,'shelf',93),
(1622,0,'platform',78),
(1622,1,'shelf',72),
(1623,0,'rails',99),
(1623,1,'ledger',61),
(1624,0,'silicon',65),
(1624,1,'shelf',94),
(1625,0,'silicon',61),
(1625,1,'bills',67),
(1626,0,'cloud',65),
(1626,1,'crude',70),
(1627,0,'shelf',90),
(1627,1,'brand',75),
(1628,0,'ballast',79),
(1628,1,'shelf',66),
(1629,0,'bills',73),
(1629,1,'vault',77),
(1630,0,'trial',92),
(1630,1,'teller',88),
(1631,0,'silicon',89),
(1631,1,'rails',93),
(1632,0,'trial',76),
(1632,1,'platform',91),
(1633,0,'shelf',83),
(1633,1,'cloud',97),
(1634,0,'shelf',92),
(1634,1,'ballast',74),
(1635,0,'claims',100),
(1635,1,'bills',75),
(1636,0,'ballast',68),
(1636,1,'degen',98),
(1637,0,'claims',91),
(1637,1,'vault',72),
(1638,0,'shelf',84),
(1638,1,'ballast',79),
(1639,0,'ledger',66),
(1639,1,'rails',61),
(1640,0,'vault',81),
(1640,1,'shelf',66),
(1641,0,'claims',87),
(1641,1,'platform',80),
(1642,0,'rails',66),
(1642,1,'ballast',99),
(1643,0,'bills',86),
(1643,1,'brand',83),
(1644,0,'ballast',75),
(1644,1,'claims',65),
(1645,0,'grid',99),
(1645,1,'ledger',68),
(1646,0,'rails',81),
(1646,1,'grid',82),
(1647,0,'trial',66),
(1647,1,'platform',82),
(1648,0,'claims',71),
(1648,1,'trial',79),
(1649,0,'shelf',70),
(1649,1,'rails',83),
(1650,0,'bills',67),
(1650,1,'silicon',69),
(1651,0,'degen',74),
(1651,1,'cloud',93),
(1652,0,'rails',71),
(1652,1,'platform',63),
(1653,0,'shelf',62),
(1653,1,'vault',87),
(1654,0,'claims',78),
(1654,1,'cloud',67),
(1655,0,'trial',68),
(1655,1,'brand',90),
(1656,0,'rails',75),
(1656,1,'grid',97),
(1657,0,'platform',79),
(1657,1,'brand',85),
(1658,0,'rails',85),
(1658,1,'grid',71),
(1659,0,'shelf',96),
(1659,1,'vault',61),
(1660,0,'trial',68),
(1660,1,'silicon',66),
(1661,0,'platform',97),
(1661,1,'shelf',83),
(1662,0,'trial',62),
(1662,1,'ledger',87),
(1663,0,'cloud',70),
(1663,1,'platform',95),
(1664,0,'ballast',76),
(1664,1,'shelf',74),
(1665,0,'cloud',97),
(1665,1,'rails',88),
(1666,0,'rails',67),
(1666,1,'vault',85),
(1667,0,'platform',80),
(1667,1,'ballast',71),
(1668,0,'bills',84),
(1668,1,'brand',79),
(1669,0,'silicon',98),
(1669,1,'brand',97),
(1670,0,'rails',85),
(1670,1,'degen',99),
(1671,0,'vault',99),
(1671,1,'ledger',81),
(1672,0,'bills',76),
(1672,1,'silicon',75),
(1673,0,'silicon',65),
(1673,1,'bills',86),
(1674,0,'ballast',77),
(1674,1,'teller',62),
(1675,0,'claims',83),
(1675,1,'brand',75),
(1676,0,'claims',98),
(1676,1,'teller',66),
(1677,0,'brand',65),
(1677,1,'grid',80),
(1678,0,'vault',77),
(1678,1,'brand',64),
(1679,0,'ballast',96),
(1679,1,'brand',74),
(1680,0,'bills',99),
(1680,1,'platform',69),
(1681,0,'bills',92),
(1681,1,'crude',90),
(1682,0,'shelf',85),
(1682,1,'rails',75),
(1683,0,'brand',71),
(1683,1,'platform',78),
(1684,0,'grid',83),
(1684,1,'platform',94),
(1685,0,'claims',66),
(1685,1,'grid',91),
(1686,0,'brand',72),
(1686,1,'ballast',85),
(1687,0,'rails',83),
(1687,1,'grid',92),
(1688,0,'bills',98),
(1688,1,'platform',97),
(1689,0,'crude',89),
(1689,1,'cloud',97),
(1690,0,'ledger',99),
(1690,1,'platform',87),
(1691,0,'vault',67),
(1691,1,'claims',94),
(1692,0,'cloud',75),
(1692,1,'ledger',98),
(1693,0,'vault',94),
(1693,1,'trial',99),
(1694,0,'bills',61),
(1694,1,'brand',62),
(1695,0,'bills',94),
(1695,1,'ballast',70),
(1696,0,'brand',81),
(1696,1,'claims',62),
(1697,0,'rails',85),
(1697,1,'grid',82),
(1698,0,'ledger',87),
(1698,1,'ballast',94),
(1699,0,'vault',70),
(1699,1,'claims',71),
(1700,0,'trial',89),
(1700,1,'grid',73),
(1701,0,'shelf',60),
(1701,1,'platform',79),
(1702,0,'rails',61),
(1702,1,'cloud',91),
(1703,0,'vault',100),
(1703,1,'bills',70),
(1704,0,'trial',78),
(1704,1,'platform',61),
(1705,0,'rails',91),
(1705,1,'trial',82),
(1706,0,'ledger',84),
(1706,1,'claims',85),
(1707,0,'bills',98),
(1707,1,'brand',70),
(1708,0,'ballast',65),
(1708,1,'rails',85),
(1709,0,'claims',95),
(1709,1,'brand',89),
(1710,0,'platform',97),
(1710,1,'bills',61),
(1711,0,'brand',62),
(1711,1,'crude',97),
(1712,0,'ledger',68),
(1712,1,'ballast',86),
(1713,0,'bills',78),
(1713,1,'claims',85),
(1714,0,'grid',90),
(1714,1,'ledger',96),
(1715,0,'crude',77),
(1715,1,'vault',81),
(1716,0,'platform',95),
(1716,1,'grid',75),
(1717,0,'claims',85),
(1717,1,'ballast',99),
(1718,0,'cloud',63),
(1718,1,'grid',98),
(1719,0,'brand',71),
(1719,1,'shelf',62),
(1720,0,'silicon',75),
(1720,1,'ballast',71),
(1721,0,'claims',79),
(1721,1,'ballast',98),
(1722,0,'shelf',69),
(1722,1,'bills',89),
(1723,0,'vault',61),
(1723,1,'degen',60),
(1724,0,'bills',60),
(1724,1,'cloud',90),
(1725,0,'brand',86),
(1725,1,'shelf',62),
(1726,0,'bills',83),
(1726,1,'shelf',72),
(1727,0,'claims',72),
(1727,1,'brand',72),
(1728,0,'platform',93),
(1728,1,'ledger',75),
(1729,0,'shelf',63),
(1729,1,'grid',86),
(1730,0,'claims',72),
(1730,1,'trial',84),
(1731,0,'brand',74),
(1731,1,'rails',66),
(1732,0,'grid',64),
(1732,1,'claims',91),
(1733,0,'brand',96),
(1733,1,'platform',100),
(1734,0,'bills',78),
(1734,1,'rails',65),
(1735,0,'rails',68),
(1735,1,'brand',60),
(1736,0,'ledger',77),
(1736,1,'shelf',89),
(1737,0,'trial',78),
(1737,1,'rails',80),
(1738,0,'cloud',67),
(1738,1,'ledger',97),
(1739,0,'ballast',60),
(1739,1,'claims',66),
(1740,0,'ballast',88),
(1740,1,'platform',87),
(1741,0,'ledger',64),
(1741,1,'ballast',70),
(1742,0,'grid',77),
(1742,1,'bills',61),
(1743,0,'ballast',85),
(1743,1,'platform',66),
(1744,0,'platform',92),
(1744,1,'bills',86),
(1745,0,'ballast',89),
(1745,1,'cloud',95),
(1746,0,'brand',97),
(1746,1,'platform',63),
(1747,0,'shelf',66),
(1747,1,'grid',91),
(1748,0,'trial',85),
(1748,1,'brand',97),
(1749,0,'crude',90),
(1749,1,'claims',89),
(1750,0,'ballast',97),
(1750,1,'grid',98),
(1751,0,'rails',97),
(1751,1,'grid',71),
(1752,0,'shelf',84),
(1752,1,'claims',73),
(1753,0,'ledger',70),
(1753,1,'platform',81),
(1754,0,'shelf',83),
(1754,1,'cloud',63),
(1755,0,'brand',77),
(1755,1,'grid',92),
(1756,0,'shelf',100),
(1756,1,'vault',86),
(1757,0,'ledger',72),
(1757,1,'shelf',65),
(1758,0,'claims',97),
(1758,1,'teller',60),
(1759,0,'shelf',98),
(1759,1,'trial',68),
(1760,0,'ballast',72),
(1760,1,'brand',91),
(1761,0,'grid',60),
(1761,1,'brand',97),
(1762,0,'rails',80),
(1762,1,'platform',61),
(1763,0,'ballast',76),
(1763,1,'grid',87),
(1764,0,'vault',73),
(1764,1,'claims',63),
(1765,0,'ledger',84),
(1765,1,'platform',77),
(1766,0,'brand',72),
(1766,1,'cloud',92),
(1767,0,'grid',88),
(1767,1,'bills',78),
(1768,0,'grid',63),
(1768,1,'rails',70),
(1769,0,'platform',87),
(1769,1,'trial',74),
(1770,0,'ballast',90),
(1770,1,'shelf',72),
(1771,0,'grid',75),
(1771,1,'claims',65),
(1772,0,'bills',64),
(1772,1,'vault',60),
(1773,0,'cloud',94),
(1773,1,'ballast',69),
(1774,0,'trial',63),
(1774,1,'rails',83),
(1775,0,'cloud',61),
(1775,1,'bills',96),
(1776,0,'vault',68),
(1776,1,'grid',93),
(1777,0,'platform',99),
(1777,1,'rails',89),
(1778,0,'claims',99),
(1778,1,'ballast',76),
(1779,0,'platform',84),
(1779,1,'bills',60),
(1780,0,'silicon',68),
(1780,1,'bills',88),
(1781,0,'claims',97),
(1781,1,'platform',77),
(1782,0,'degen',88),
(1782,1,'bills',79),
(1783,0,'degen',65),
(1783,1,'platform',86),
(1784,0,'trial',70),
(1784,1,'degen',98),
(1785,0,'platform',66),
(1785,1,'grid',92),
(1786,0,'ledger',70),
(1786,1,'trial',74),
(1787,0,'cloud',77),
(1787,1,'vault',88),
(1788,0,'trial',99),
(1788,1,'brand',90),
(1789,0,'ballast',93),
(1789,1,'cloud',92),
(1790,0,'shelf',81),
(1790,1,'vault',87),
(1791,0,'bills',73),
(1791,1,'grid',88),
(1792,0,'grid',62),
(1792,1,'rails',65),
(1793,0,'claims',75),
(1793,1,'trial',93),
(1794,0,'brand',64),
(1794,1,'rails',100),
(1795,0,'platform',97),
(1795,1,'bills',88),
(1796,0,'platform',86),
(1796,1,'grid',78),
(1797,0,'shelf',90),
(1797,1,'platform',89),
(1798,0,'shelf',67),
(1798,1,'vault',69),
(1799,0,'ballast',99),
(1799,1,'shelf',94),
(1800,0,'platform',86),
(1800,1,'bills',94),
(1801,0,'grid',83),
(1801,1,'platform',71),
(1802,0,'crude',90),
(1802,1,'ledger',86),
(1803,0,'vault',85),
(1803,1,'claims',67),
(1804,0,'claims',84),
(1804,1,'shelf',68),
(1805,0,'rails',67),
(1805,1,'brand',77),
(1806,0,'platform',77),
(1806,1,'brand',79),
(1807,0,'silicon',90),
(1807,1,'crude',78),
(1808,0,'ballast',91),
(1808,1,'brand',87),
(1809,0,'shelf',97),
(1809,1,'vault',77),
(1810,0,'silicon',81),
(1810,1,'vault',60),
(1811,0,'ledger',93),
(1811,1,'brand',85),
(1812,0,'teller',73),
(1812,1,'bills',71),
(1813,0,'brand',79),
(1813,1,'ballast',91),
(1814,0,'platform',87),
(1814,1,'trial',97),
(1815,0,'rails',89),
(1815,1,'cloud',89),
(1816,0,'trial',71),
(1816,1,'cloud',60),
(1817,0,'claims',98),
(1817,1,'grid',65),
(1818,0,'bills',66),
(1818,1,'crude',87),
(1819,0,'grid',91),
(1819,1,'platform',77),
(1820,0,'cloud',66),
(1820,1,'grid',66),
(1821,0,'claims',97),
(1821,1,'silicon',64),
(1822,0,'grid',95),
(1822,1,'ballast',87),
(1823,0,'bills',71),
(1823,1,'ballast',70),
(1824,0,'bills',79),
(1824,1,'grid',99),
(1825,0,'shelf',92),
(1825,1,'vault',90),
(1826,0,'rails',78),
(1826,1,'platform',94),
(1827,0,'claims',60),
(1827,1,'brand',76),
(1828,0,'vault',63),
(1828,1,'platform',94),
(1829,0,'ballast',65),
(1829,1,'trial',91),
(1830,0,'brand',90),
(1830,1,'shelf',99),
(1831,0,'crude',68),
(1831,1,'brand',73),
(1832,0,'ballast',91),
(1832,1,'silicon',83),
(1833,0,'ballast',75),
(1833,1,'claims',66),
(1834,0,'degen',61),
(1834,1,'ballast',68),
(1835,0,'ballast',86),
(1835,1,'platform',67),
(1836,0,'grid',83),
(1836,1,'crude',85),
(1837,0,'brand',67),
(1837,1,'ballast',90),
(1838,0,'shelf',60),
(1838,1,'platform',65),
(1839,0,'shelf',62),
(1839,1,'ledger',91),
(1840,0,'cloud',69),
(1840,1,'crude',86),
(1841,0,'cloud',64),
(1841,1,'brand',85),
(1842,0,'cloud',93),
(1842,1,'grid',83),
(1843,0,'crude',84),
(1843,1,'vault',84),
(1844,0,'brand',81),
(1844,1,'vault',64),
(1845,0,'crude',98),
(1845,1,'rails',99),
(1846,0,'rails',80),
(1846,1,'grid',61),
(1847,0,'bills',92),
(1847,1,'brand',70),
(1848,0,'grid',71),
(1848,1,'shelf',92),
(1849,0,'cloud',84),
(1849,1,'grid',68),
(1850,0,'ballast',67),
(1850,1,'silicon',76),
(1851,0,'brand',90),
(1851,1,'rails',87),
(1852,0,'trial',100),
(1852,1,'brand',96),
(1853,0,'ballast',60),
(1853,1,'crude',63),
(1854,0,'vault',68),
(1854,1,'teller',64),
(1855,0,'claims',74),
(1855,1,'trial',85),
(1856,0,'ballast',66),
(1856,1,'shelf',64),
(1857,0,'shelf',73),
(1857,1,'bills',61),
(1858,0,'brand',84),
(1858,1,'shelf',62),
(1859,0,'teller',72),
(1859,1,'claims',94),
(1860,0,'bills',61),
(1860,1,'platform',84),
(1861,0,'shelf',96),
(1861,1,'teller',90),
(1862,0,'grid',84),
(1862,1,'vault',76),
(1863,0,'shelf',95),
(1863,1,'ballast',91),
(1864,0,'vault',100),
(1864,1,'ledger',92),
(1865,0,'brand',65),
(1865,1,'ballast',87),
(1866,0,'brand',69),
(1866,1,'rails',71),
(1867,0,'bills',82),
(1867,1,'claims',71),
(1868,0,'brand',84),
(1868,1,'grid',67),
(1869,0,'teller',75),
(1869,1,'ballast',60),
(1870,0,'vault',71),
(1870,1,'brand',95),
(1871,0,'cloud',98),
(1871,1,'crude',89),
(1872,0,'ledger',74),
(1872,1,'brand',88),
(1873,0,'ballast',98),
(1873,1,'shelf',75),
(1874,0,'silicon',69),
(1874,1,'rails',87),
(1875,0,'ledger',68),
(1875,1,'claims',61),
(1876,0,'trial',75),
(1876,1,'bills',91),
(1877,0,'crude',69),
(1877,1,'cloud',83),
(1878,0,'trial',80),
(1878,1,'vault',64),
(1879,0,'ledger',78),
(1879,1,'vault',71),
(1880,0,'shelf',90),
(1880,1,'cloud',61),
(1881,0,'bills',75),
(1881,1,'trial',89),
(1882,0,'trial',90),
(1882,1,'shelf',100),
(1883,0,'brand',82),
(1883,1,'shelf',92),
(1884,0,'bills',87),
(1884,1,'ballast',93),
(1885,0,'crude',61),
(1885,1,'ledger',89),
(1886,0,'platform',76),
(1886,1,'vault',68),
(1887,0,'shelf',72),
(1887,1,'brand',96),
(1888,0,'platform',100),
(1888,1,'grid',93),
(1889,0,'ballast',74),
(1889,1,'bills',72),
(1890,0,'cloud',90),
(1890,1,'grid',78),
(1891,0,'ballast',73),
(1891,1,'grid',81),
(1892,0,'bills',92),
(1892,1,'cloud',70),
(1893,0,'crude',70),
(1893,1,'ballast',81),
(1894,0,'ledger',75),
(1894,1,'silicon',89),
(1895,0,'platform',76),
(1895,1,'trial',84),
(1896,0,'crude',72),
(1896,1,'grid',88),
(1897,0,'trial',71),
(1897,1,'silicon',92),
(1898,0,'silicon',69),
(1898,1,'vault',68),
(1899,0,'silicon',62),
(1899,1,'brand',82),
(1900,0,'silicon',94),
(1900,1,'brand',71),
(1901,0,'grid',80),
(1901,1,'claims',61),
(1902,0,'vault',62),
(1902,1,'brand',74),
(1903,0,'shelf',80),
(1903,1,'bills',86),
(1904,0,'brand',82),
(1904,1,'ballast',60),
(1905,0,'ledger',66),
(1905,1,'cloud',93),
(1906,0,'brand',81),
(1906,1,'cloud',90),
(1907,0,'ledger',99),
(1907,1,'rails',66),
(1908,0,'grid',97),
(1908,1,'trial',99),
(1909,0,'claims',67),
(1909,1,'brand',100),
(1910,0,'shelf',82),
(1910,1,'ledger',89),
(1911,0,'bills',71),
(1911,1,'brand',76),
(1912,0,'crude',74),
(1912,1,'bills',66),
(1913,0,'ballast',86),
(1913,1,'rails',84),
(1914,0,'trial',95),
(1914,1,'ledger',81),
(1915,0,'ledger',85),
(1915,1,'crude',89),
(1916,0,'vault',97),
(1916,1,'brand',67),
(1917,0,'trial',72),
(1917,1,'shelf',81),
(1918,0,'ballast',97),
(1918,1,'trial',93),
(1919,0,'claims',72),
(1919,1,'trial',91),
(1920,0,'shelf',92),
(1920,1,'ballast',65),
(1921,0,'trial',63),
(1921,1,'rails',60),
(1922,0,'rails',96),
(1922,1,'bills',90),
(1923,0,'vault',60),
(1923,1,'degen',65),
(1924,0,'claims',62),
(1924,1,'shelf',67),
(1925,0,'ballast',89),
(1925,1,'cloud',79),
(1926,0,'rails',84),
(1926,1,'platform',93),
(1927,0,'trial',83),
(1927,1,'claims',79),
(1928,0,'bills',88),
(1928,1,'trial',80),
(1929,0,'brand',93),
(1929,1,'ledger',67),
(1930,0,'platform',61),
(1930,1,'cloud',87),
(1931,0,'teller',96),
(1931,1,'platform',84),
(1932,0,'silicon',62),
(1932,1,'ledger',98),
(1933,0,'claims',75),
(1933,1,'grid',67),
(1934,0,'cloud',96),
(1934,1,'bills',63),
(1935,0,'silicon',64),
(1935,1,'shelf',68),
(1936,0,'platform',83),
(1936,1,'vault',87),
(1937,0,'brand',96),
(1937,1,'vault',85),
(1938,0,'trial',87),
(1938,1,'silicon',73),
(1939,0,'degen',92),
(1939,1,'brand',79),
(1940,0,'grid',80),
(1940,1,'vault',66),
(1941,0,'brand',93),
(1941,1,'silicon',81),
(1942,0,'claims',84),
(1942,1,'vault',98),
(1943,0,'claims',61),
(1943,1,'shelf',76),
(1944,0,'shelf',67),
(1944,1,'bills',77),
(1945,0,'teller',66),
(1945,1,'platform',73),
(1946,0,'vault',95),
(1946,1,'trial',86),
(1947,0,'bills',82),
(1947,1,'brand',74),
(1948,0,'rails',91),
(1948,1,'crude',72),
(1949,0,'grid',93),
(1949,1,'silicon',65),
(1950,0,'brand',62),
(1950,1,'bills',74),
(1951,0,'bills',65),
(1951,1,'brand',98),
(1952,0,'platform',66),
(1952,1,'grid',91),
(1953,0,'shelf',84),
(1953,1,'degen',82),
(1954,0,'bills',67),
(1954,1,'ledger',71),
(1955,0,'shelf',66),
(1955,1,'bills',65),
(1956,0,'platform',72),
(1956,1,'ledger',97),
(1957,0,'vault',79),
(1957,1,'cloud',98),
(1958,0,'ballast',76),
(1958,1,'ledger',62),
(1959,0,'claims',95),
(1959,1,'platform',97),
(1960,0,'platform',68),
(1960,1,'trial',69),
(1961,0,'shelf',67),
(1961,1,'claims',86),
(1962,0,'ledger',95),
(1962,1,'rails',78),
(1963,0,'teller',87),
(1963,1,'shelf',60),
(1964,0,'cloud',90),
(1964,1,'shelf',60),
(1965,0,'shelf',68),
(1965,1,'trial',70),
(1966,0,'bills',62),
(1966,1,'shelf',69),
(1967,0,'shelf',68),
(1967,1,'crude',69),
(1968,0,'ledger',87),
(1968,1,'bills',68),
(1969,0,'ballast',60),
(1969,1,'grid',82),
(1970,0,'silicon',81),
(1970,1,'cloud',63),
(1971,0,'grid',67),
(1971,1,'ballast',99),
(1972,0,'claims',91),
(1972,1,'silicon',84),
(1973,0,'shelf',62),
(1973,1,'claims',68),
(1974,0,'degen',95),
(1974,1,'shelf',67),
(1975,0,'ballast',81),
(1975,1,'ledger',99),
(1976,0,'platform',75),
(1976,1,'cloud',82),
(1977,0,'cloud',96),
(1977,1,'platform',100),
(1978,0,'ledger',61),
(1978,1,'rails',99),
(1979,0,'ledger',77),
(1979,1,'claims',84),
(1980,0,'ballast',84),
(1980,1,'shelf',91),
(1981,0,'trial',92),
(1981,1,'cloud',72),
(1982,0,'ledger',92),
(1982,1,'brand',71),
(1983,0,'brand',81),
(1983,1,'claims',72),
(1984,0,'rails',99),
(1984,1,'shelf',71),
(1985,0,'brand',89),
(1985,1,'ballast',89),
(1986,0,'silicon',88),
(1986,1,'claims',76),
(1987,0,'cloud',74),
(1987,1,'trial',78),
(1988,0,'vault',85),
(1988,1,'shelf',76),
(1989,0,'vault',87),
(1989,1,'platform',85),
(1990,0,'silicon',77),
(1990,1,'vault',63),
(1991,0,'ledger',99),
(1991,1,'bills',66),
(1992,0,'trial',66),
(1992,1,'claims',95),
(1993,0,'crude',79),
(1993,1,'bills',66),
(1994,0,'bills',92),
(1994,1,'grid',69),
(1995,0,'trial',60),
(1995,1,'ledger',79),
(1996,0,'degen',100),
(1996,1,'bills',66),
(1997,0,'shelf',88),
(1997,1,'rails',97),
(1998,0,'ledger',79),
(1998,1,'shelf',77),
(1999,0,'cloud',61),
(1999,1,'shelf',96),
(2000,0,'shelf',77),
(2001,0,'brand',99),
(2002,0,'trial',83),
(2003,0,'ballast',94),
(2004,0,'claims',72),
(2005,0,'ballast',90),
(2006,0,'ballast',91),
(2007,0,'grid',96),
(2008,0,'cloud',71),
(2009,0,'platform',83),
(2010,0,'shelf',89),
(2011,0,'rails',79),
(2012,0,'rails',97),
(2013,0,'shelf',77),
(2014,0,'rails',88),
(2015,0,'vault',78),
(2016,0,'crude',98),
(2017,0,'bills',60),
(2018,0,'shelf',67),
(2019,0,'bills',82),
(2020,0,'brand',90),
(2021,0,'rails',83),
(2022,0,'brand',77),
(2023,0,'bills',76),
(2024,0,'rails',84),
(2025,0,'bills',91),
(2026,0,'grid',76),
(2027,0,'vault',93),
(2028,0,'bills',69),
(2029,0,'claims',89),
(2030,0,'rails',70),
(2031,0,'bills',63),
(2032,0,'bills',73),
(2033,0,'ledger',75),
(2034,0,'trial',100),
(2035,0,'claims',96),
(2036,0,'brand',92),
(2037,0,'rails',78),
(2038,0,'degen',74),
(2039,0,'ledger',69),
(2040,0,'brand',76),
(2041,0,'shelf',91),
(2042,0,'ballast',95),
(2043,0,'ledger',100),
(2044,0,'shelf',81),
(2045,0,'shelf',99),
(2046,0,'trial',84),
(2047,0,'trial',71),
(2048,0,'bills',97),
(2049,0,'cloud',63),
(2050,0,'brand',87),
(2051,0,'ballast',78),
(2052,0,'platform',60),
(2053,0,'vault',95),
(2054,0,'ballast',88),
(2055,0,'grid',63),
(2056,0,'trial',83),
(2057,0,'claims',74),
(2058,0,'bills',100),
(2059,0,'rails',76),
(2060,0,'ballast',96),
(2061,0,'platform',94),
(2062,0,'trial',90),
(2063,0,'grid',96),
(2064,0,'claims',76),
(2065,0,'bills',80),
(2066,0,'ledger',85),
(2067,0,'bills',61),
(2068,0,'brand',95),
(2069,0,'claims',85),
(2070,0,'platform',95),
(2071,0,'brand',87),
(2072,0,'crude',76),
(2073,0,'claims',75),
(2074,0,'rails',84),
(2075,0,'brand',68),
(2076,0,'crude',79),
(2077,0,'bills',68),
(2078,0,'platform',81),
(2079,0,'brand',83),
(2080,0,'grid',93),
(2081,0,'ballast',80),
(2082,0,'rails',61),
(2083,0,'ledger',70),
(2084,0,'trial',98),
(2085,0,'silicon',83),
(2086,0,'claims',72),
(2087,0,'bills',84),
(2088,0,'degen',77),
(2089,0,'rails',70),
(2090,0,'brand',96),
(2091,0,'vault',92),
(2092,0,'grid',67),
(2093,0,'crude',83),
(2094,0,'ballast',72),
(2095,0,'ballast',66),
(2096,0,'teller',86),
(2097,0,'platform',66),
(2098,0,'bills',73),
(2099,0,'brand',84),
(2100,0,'ballast',86),
(2101,0,'vault',77),
(2102,0,'grid',72),
(2103,0,'cloud',92),
(2104,0,'rails',70),
(2105,0,'teller',99),
(2106,0,'trial',92),
(2107,0,'rails',68),
(2108,0,'silicon',67),
(2109,0,'trial',91),
(2110,0,'brand',61),
(2111,0,'ballast',85),
(2112,0,'ballast',71),
(2113,0,'trial',76),
(2114,0,'trial',68),
(2115,0,'degen',71),
(2116,0,'cloud',98),
(2117,0,'brand',96),
(2118,0,'cloud',75),
(2119,0,'ballast',81),
(2120,0,'shelf',62),
(2121,0,'trial',61),
(2122,0,'brand',76),
(2123,0,'vault',68),
(2124,0,'crude',76),
(2125,0,'shelf',97),
(2126,0,'platform',98),
(2127,0,'claims',70),
(2128,0,'shelf',69),
(2129,0,'brand',82),
(2130,0,'shelf',89),
(2131,0,'ledger',60),
(2132,0,'shelf',84),
(2133,0,'shelf',93),
(2134,0,'cloud',91),
(2135,0,'vault',76),
(2136,0,'vault',62),
(2137,0,'rails',67),
(2138,0,'brand',63),
(2139,0,'vault',99),
(2140,0,'rails',74),
(2141,0,'brand',60),
(2142,0,'bills',74),
(2143,0,'trial',87),
(2144,0,'vault',97),
(2145,0,'rails',80),
(2146,0,'brand',76),
(2147,0,'shelf',88),
(2148,0,'degen',66),
(2149,0,'vault',63),
(2150,0,'rails',66),
(2151,0,'ballast',97),
(2152,0,'shelf',72),
(2153,0,'cloud',98),
(2154,0,'ballast',83),
(2155,0,'ballast',73),
(2156,0,'ledger',62),
(2157,0,'ledger',90),
(2158,0,'ledger',82),
(2159,0,'shelf',94),
(2160,0,'ballast',67),
(2161,0,'brand',95),
(2162,0,'trial',74),
(2163,0,'trial',62),
(2164,0,'cloud',86),
(2165,0,'claims',70),
(2166,0,'crude',62),
(2167,0,'bills',94),
(2168,0,'trial',97),
(2169,0,'ledger',60),
(2170,0,'cloud',89),
(2171,0,'silicon',82),
(2172,0,'ballast',83),
(2173,0,'bills',65),
(2174,0,'brand',74),
(2175,0,'claims',96),
(2176,0,'vault',80),
(2177,0,'shelf',87),
(2178,0,'platform',86),
(2179,0,'claims',82),
(2180,0,'ballast',81),
(2181,0,'ballast',81),
(2182,0,'vault',82),
(2183,0,'platform',77),
(2184,0,'brand',80),
(2185,0,'grid',81),
(2186,0,'vault',94),
(2187,0,'vault',74),
(2188,0,'ballast',65),
(2189,0,'grid',62),
(2190,0,'grid',62),
(2191,0,'vault',78),
(2192,0,'teller',87),
(2193,0,'ballast',71),
(2194,0,'trial',74),
(2195,0,'trial',79),
(2196,0,'bills',66),
(2197,0,'crude',99),
(2198,0,'brand',89),
(2199,0,'claims',60),
(2200,0,'vault',80),
(2201,0,'brand',73),
(2202,0,'cloud',97),
(2203,0,'cloud',77),
(2204,0,'trial',87),
(2205,0,'claims',65),
(2206,0,'shelf',86),
(2207,0,'claims',81),
(2208,0,'shelf',90),
(2209,0,'trial',100),
(2210,0,'ledger',99),
(2211,0,'silicon',78),
(2212,0,'rails',84),
(2213,0,'ledger',81),
(2214,0,'ballast',89),
(2215,0,'platform',60),
(2216,0,'ballast',76),
(2217,0,'brand',70),
(2218,0,'platform',82),
(2219,0,'ledger',60),
(2220,0,'crude',67),
(2221,0,'brand',72),
(2222,0,'claims',91),
(2223,0,'ledger',70),
(2224,0,'cloud',63),
(2225,0,'ledger',81),
(2226,0,'bills',100),
(2227,0,'teller',94),
(2228,0,'brand',69),
(2229,0,'crude',84),
(2230,0,'shelf',72),
(2231,0,'rails',93),
(2232,0,'brand',83),
(2233,0,'vault',75),
(2234,0,'trial',64),
(2235,0,'brand',69),
(2236,0,'bills',61),
(2237,0,'grid',90),
(2238,0,'ledger',94),
(2239,0,'grid',80),
(2240,0,'shelf',83),
(2241,0,'rails',80),
(2242,0,'crude',67),
(2243,0,'trial',87),
(2244,0,'shelf',79),
(2245,0,'ballast',87),
(2246,0,'grid',65),
(2247,0,'claims',64),
(2248,0,'vault',81),
(2249,0,'cloud',60),
(2250,0,'rails',61),
(2251,0,'platform',60),
(2252,0,'rails',92),
(2253,0,'trial',64),
(2254,0,'shelf',70),
(2255,0,'vault',77),
(2256,0,'bills',82),
(2257,0,'ballast',71),
(2258,0,'shelf',66),
(2259,0,'trial',80),
(2260,0,'degen',96),
(2261,0,'platform',84),
(2262,0,'grid',98),
(2263,0,'platform',72),
(2264,0,'ballast',93),
(2265,0,'cloud',93),
(2266,0,'ballast',62),
(2267,0,'brand',89),
(2268,0,'cloud',73),
(2269,0,'brand',76),
(2270,0,'rails',91),
(2271,0,'shelf',94),
(2272,0,'platform',87),
(2273,0,'silicon',93),
(2274,0,'trial',85),
(2275,0,'shelf',76),
(2276,0,'ledger',85),
(2277,0,'ballast',63),
(2278,0,'silicon',100),
(2279,0,'shelf',89),
(2280,0,'grid',77),
(2281,0,'shelf',80),
(2282,0,'rails',82),
(2283,0,'shelf',85),
(2284,0,'bills',66),
(2285,0,'platform',75),
(2286,0,'grid',69),
(2287,0,'vault',61),
(2288,0,'crude',78),
(2289,0,'shelf',66),
(2290,0,'shelf',66),
(2291,0,'platform',73),
(2292,0,'shelf',88),
(2293,0,'vault',73),
(2294,0,'shelf',71),
(2295,0,'ledger',82),
(2296,0,'rails',83),
(2297,0,'ballast',92),
(2298,0,'platform',91),
(2299,0,'vault',89),
(2300,0,'cloud',77),
(2301,0,'vault',78),
(2302,0,'trial',90),
(2303,0,'ledger',97),
(2304,0,'grid',98),
(2305,0,'shelf',68),
(2306,0,'ledger',67),
(2307,0,'trial',85),
(2308,0,'cloud',82),
(2309,0,'ledger',95),
(2310,0,'crude',82),
(2311,0,'trial',100),
(2312,0,'ballast',72),
(2313,0,'vault',94),
(2314,0,'claims',93),
(2315,0,'ballast',77),
(2316,0,'grid',62),
(2317,0,'brand',77),
(2318,0,'rails',79),
(2319,0,'rails',64),
(2320,0,'degen',67),
(2321,0,'ballast',80),
(2322,0,'claims',63),
(2323,0,'shelf',94),
(2324,0,'vault',90),
(2325,0,'cloud',61),
(2326,0,'claims',84),
(2327,0,'platform',92),
(2328,0,'platform',81),
(2329,0,'crude',82),
(2330,0,'platform',76),
(2331,0,'brand',63),
(2332,0,'claims',71),
(2333,0,'crude',94),
(2334,0,'platform',85),
(2335,0,'shelf',86),
(2336,0,'crude',86),
(2337,0,'ballast',85),
(2338,0,'platform',63),
(2339,0,'claims',64),
(2340,0,'shelf',96),
(2341,0,'bills',94),
(2342,0,'crude',76),
(2343,0,'bills',98),
(2344,0,'platform',70),
(2345,0,'brand',65),
(2346,0,'ballast',84),
(2347,0,'bills',96),
(2348,0,'platform',70),
(2349,0,'platform',84),
(2350,0,'shelf',60),
(2351,0,'claims',73),
(2352,0,'ballast',72),
(2353,0,'teller',66),
(2354,0,'ballast',96),
(2355,0,'shelf',94),
(2356,0,'shelf',87),
(2357,0,'ballast',77),
(2358,0,'ledger',64),
(2359,0,'trial',89),
(2360,0,'ledger',74),
(2361,0,'shelf',69),
(2362,0,'ballast',86),
(2363,0,'claims',89),
(2364,0,'ledger',92),
(2365,0,'rails',71),
(2366,0,'bills',67),
(2367,0,'brand',65),
(2368,0,'vault',83),
(2369,0,'cloud',97),
(2370,0,'rails',71),
(2371,0,'vault',76),
(2372,0,'ballast',92),
(2373,0,'ballast',73),
(2374,0,'brand',91),
(2375,0,'trial',87),
(2376,0,'platform',84),
(2377,0,'bills',78),
(2378,0,'trial',94),
(2379,0,'trial',74),
(2380,0,'crude',95),
(2381,0,'claims',73),
(2382,0,'shelf',85),
(2383,0,'brand',73),
(2384,0,'bills',71),
(2385,0,'vault',65),
(2386,0,'vault',88),
(2387,0,'bills',93),
(2388,0,'vault',96),
(2389,0,'platform',72),
(2390,0,'grid',88),
(2391,0,'trial',73),
(2392,0,'rails',74),
(2393,0,'shelf',73),
(2394,0,'teller',81),
(2395,0,'silicon',82),
(2396,0,'teller',82),
(2397,0,'rails',74),
(2398,0,'bills',67),
(2399,0,'claims',64),
(2400,0,'brand',77),
(2401,0,'ballast',92),
(2402,0,'brand',96),
(2403,0,'shelf',65),
(2404,0,'cloud',62),
(2405,0,'shelf',95),
(2406,0,'claims',84),
(2407,0,'shelf',72),
(2408,0,'shelf',72),
(2409,0,'ledger',60),
(2410,0,'brand',61),
(2411,0,'shelf',70),
(2412,0,'shelf',78),
(2413,0,'vault',92),
(2414,0,'teller',65),
(2415,0,'platform',66),
(2416,0,'platform',75),
(2417,0,'teller',64),
(2418,0,'silicon',61),
(2419,0,'grid',81),
(2420,0,'vault',83),
(2421,0,'ballast',88),
(2422,0,'vault',99),
(2423,0,'trial',69),
(2424,0,'brand',63),
(2425,0,'silicon',82),
(2426,0,'shelf',60),
(2427,0,'rails',81),
(2428,0,'brand',82),
(2429,0,'platform',78),
(2430,0,'bills',90),
(2431,0,'ballast',83),
(2432,0,'trial',60),
(2433,0,'vault',91),
(2434,0,'cloud',81),
(2435,0,'grid',72),
(2436,0,'ledger',62),
(2437,0,'claims',65),
(2438,0,'shelf',66),
(2439,0,'platform',74),
(2440,0,'ledger',84),
(2441,0,'ledger',68),
(2442,0,'brand',81),
(2443,0,'vault',68),
(2444,0,'bills',70),
(2445,0,'claims',67),
(2446,0,'vault',89),
(2447,0,'vault',87),
(2448,0,'ballast',94),
(2449,0,'claims',73),
(2450,0,'brand',92),
(2451,0,'bills',71),
(2452,0,'claims',87),
(2453,0,'grid',69),
(2454,0,'grid',96),
(2455,0,'cloud',100),
(2456,0,'trial',78),
(2457,0,'cloud',60),
(2458,0,'brand',95),
(2459,0,'shelf',84),
(2460,0,'shelf',89),
(2461,0,'trial',84),
(2462,0,'ballast',83),
(2463,0,'bills',70),
(2464,0,'grid',85),
(2465,0,'bills',68),
(2466,0,'claims',98),
(2467,0,'teller',96),
(2468,0,'rails',70),
(2469,0,'trial',65),
(2470,0,'trial',71),
(2471,0,'platform',100),
(2472,0,'bills',98),
(2473,0,'rails',63),
(2474,0,'ballast',64),
(2475,0,'brand',65),
(2476,0,'claims',66),
(2477,0,'ledger',95),
(2478,0,'ledger',73),
(2479,0,'bills',86),
(2480,0,'ballast',94),
(2481,0,'shelf',67),
(2482,0,'degen',61),
(2483,0,'ballast',94),
(2484,0,'bills',79),
(2485,0,'trial',88),
(2486,0,'claims',94),
(2487,0,'grid',86),
(2488,0,'bills',89),
(2489,0,'cloud',74),
(2490,0,'bills',96),
(2491,0,'silicon',74),
(2492,0,'brand',85),
(2493,0,'claims',60),
(2494,0,'cloud',66),
(2495,0,'bills',70),
(2496,0,'rails',87),
(2497,0,'rails',83),
(2498,0,'claims',94),
(2499,0,'shelf',74),
(2500,0,'cloud',96),
(2501,0,'teller',72),
(2502,0,'ledger',62),
(2503,0,'claims',80),
(2504,0,'brand',95),
(2505,0,'ballast',77),
(2506,0,'crude',91),
(2507,0,'silicon',78),
(2508,0,'platform',75),
(2509,0,'vault',76),
(2510,0,'claims',84),
(2511,0,'bills',86),
(2512,0,'silicon',83),
(2513,0,'ballast',66),
(2514,0,'platform',94),
(2515,0,'bills',83),
(2516,0,'platform',77),
(2517,0,'bills',67),
(2518,0,'silicon',61),
(2519,0,'platform',84),
(2520,0,'trial',91),
(2521,0,'bills',77),
(2522,0,'ledger',91),
(2523,0,'rails',92),
(2524,0,'brand',96),
(2525,0,'brand',96),
(2526,0,'ledger',62),
(2527,0,'grid',74),
(2528,0,'bills',97),
(2529,0,'rails',71),
(2530,0,'claims',71),
(2531,0,'platform',83),
(2532,0,'vault',96),
(2533,0,'rails',60),
(2534,0,'trial',90),
(2535,0,'bills',98),
(2536,0,'brand',85),
(2537,0,'grid',80),
(2538,0,'platform',98),
(2539,0,'cloud',85),
(2540,0,'ledger',61),
(2541,0,'platform',95),
(2542,0,'shelf',97),
(2543,0,'silicon',81),
(2544,0,'platform',67),
(2545,0,'bills',84),
(2546,0,'silicon',97),
(2547,0,'silicon',78),
(2548,0,'claims',85),
(2549,0,'cloud',71),
(2550,0,'shelf',72),
(2551,0,'claims',93),
(2552,0,'ballast',90),
(2553,0,'ballast',62),
(2554,0,'rails',63),
(2555,0,'bills',65),
(2556,0,'vault',69),
(2557,0,'shelf',92),
(2558,0,'ledger',63),
(2559,0,'trial',61),
(2560,0,'ledger',72),
(2561,0,'trial',98),
(2562,0,'trial',86),
(2563,0,'silicon',86),
(2564,0,'rails',89),
(2565,0,'trial',99),
(2566,0,'vault',71),
(2567,0,'vault',81),
(2568,0,'ballast',64),
(2569,0,'trial',88),
(2570,0,'bills',85),
(2571,0,'rails',79),
(2572,0,'grid',100),
(2573,0,'rails',89),
(2574,0,'crude',67),
(2575,0,'crude',83),
(2576,0,'ledger',97),
(2577,0,'ballast',64),
(2578,0,'vault',79),
(2579,0,'bills',97),
(2580,0,'bills',65),
(2581,0,'bills',75),
(2582,0,'degen',100),
(2583,0,'grid',75),
(2584,0,'shelf',61),
(2585,0,'crude',99),
(2586,0,'cloud',75),
(2587,0,'crude',96),
(2588,0,'shelf',67),
(2589,0,'bills',68),
(2590,0,'bills',70),
(2591,0,'shelf',61),
(2592,0,'ledger',100),
(2593,0,'shelf',91),
(2594,0,'shelf',91),
(2595,0,'vault',63),
(2596,0,'claims',63),
(2597,0,'vault',75),
(2598,0,'ballast',75),
(2599,0,'ballast',79),
(2600,0,'ballast',78),
(2601,0,'cloud',73),
(2602,0,'ledger',87),
(2603,0,'bills',80),
(2604,0,'platform',62),
(2605,0,'silicon',83),
(2606,0,'grid',65),
(2607,0,'ballast',81),
(2608,0,'ledger',65),
(2609,0,'brand',73),
(2610,0,'bills',99),
(2611,0,'grid',61),
(2612,0,'platform',99),
(2613,0,'grid',84),
(2614,0,'rails',63),
(2615,0,'cloud',87),
(2616,0,'rails',60),
(2617,0,'ledger',88),
(2618,0,'ledger',87),
(2619,0,'bills',89),
(2620,0,'claims',87),
(2621,0,'shelf',83),
(2622,0,'brand',78),
(2623,0,'crude',82),
(2624,0,'teller',87),
(2625,0,'vault',92),
(2626,0,'vault',63),
(2627,0,'trial',60),
(2628,0,'bills',70),
(2629,0,'crude',87),
(2630,0,'ballast',69),
(2631,0,'brand',89),
(2632,0,'ballast',68),
(2633,0,'silicon',78),
(2634,0,'bills',75),
(2635,0,'brand',71),
(2636,0,'ballast',74),
(2637,0,'ballast',82),
(2638,0,'ballast',63),
(2639,0,'ledger',100),
(2640,0,'cloud',70),
(2641,0,'brand',74),
(2642,0,'teller',70),
(2643,0,'bills',96),
(2644,0,'platform',83),
(2645,0,'rails',64),
(2646,0,'crude',94),
(2647,0,'cloud',90),
(2648,0,'bills',63),
(2649,0,'brand',98),
(2650,0,'shelf',73),
(2651,0,'vault',88),
(2652,0,'grid',93),
(2653,0,'bills',79),
(2654,0,'bills',61),
(2655,0,'vault',66),
(2656,0,'bills',84),
(2657,0,'trial',72),
(2658,0,'cloud',93),
(2659,0,'platform',90),
(2660,0,'grid',70),
(2661,0,'brand',89),
(2662,0,'ballast',87),
(2663,0,'brand',91),
(2664,0,'claims',92),
(2665,0,'brand',60),
(2666,0,'silicon',86),
(2667,0,'brand',90),
(2668,0,'brand',65),
(2669,0,'rails',87),
(2670,0,'brand',92),
(2671,0,'bills',84),
(2672,0,'bills',60),
(2673,0,'trial',80),
(2674,0,'claims',62),
(2675,0,'shelf',96),
(2676,0,'ledger',64),
(2677,0,'ballast',98),
(2678,0,'ballast',82),
(2679,0,'rails',65),
(2680,0,'ballast',100),
(2681,0,'vault',61),
(2682,0,'vault',86),
(2683,0,'rails',99),
(2684,0,'grid',87),
(2685,0,'shelf',94),
(2686,0,'ledger',73),
(2687,0,'claims',88),
(2688,0,'claims',69),
(2689,0,'ledger',85),
(2690,0,'rails',81),
(2691,0,'shelf',78),
(2692,0,'bills',82),
(2693,0,'cloud',84),
(2694,0,'shelf',74),
(2695,0,'claims',84),
(2696,0,'ballast',71),
(2697,0,'shelf',93),
(2698,0,'trial',75),
(2699,0,'crude',80),
(2700,0,'cloud',76),
(2701,0,'rails',94),
(2702,0,'vault',77),
(2703,0,'bills',85),
(2704,0,'trial',90),
(2705,0,'bills',85),
(2706,0,'grid',64),
(2707,0,'trial',62),
(2708,0,'brand',97),
(2709,0,'ballast',91),
(2710,0,'crude',89),
(2711,0,'cloud',62),
(2712,0,'bills',81),
(2713,0,'platform',82),
(2714,0,'brand',93),
(2715,0,'rails',71),
(2716,0,'ballast',88),
(2717,0,'ballast',60),
(2718,0,'cloud',95),
(2719,0,'ledger',95),
(2720,0,'rails',99),
(2721,0,'ballast',88),
(2722,0,'silicon',79),
(2723,0,'trial',82),
(2724,0,'ballast',75),
(2725,0,'bills',69),
(2726,0,'grid',65),
(2727,0,'bills',70),
(2728,0,'bills',86),
(2729,0,'grid',84),
(2730,0,'grid',90),
(2731,0,'brand',62),
(2732,0,'brand',85),
(2733,0,'claims',89),
(2734,0,'vault',82),
(2735,0,'rails',98),
(2736,0,'ledger',79),
(2737,0,'crude',99),
(2738,0,'grid',97),
(2739,0,'platform',75),
(2740,0,'vault',84),
(2741,0,'trial',99),
(2742,0,'degen',74),
(2743,0,'bills',97),
(2744,0,'ledger',90),
(2745,0,'silicon',76),
(2746,0,'trial',64),
(2747,0,'vault',100),
(2748,0,'ballast',96),
(2749,0,'vault',67),
(2750,0,'vault',93),
(2751,0,'bills',86),
(2752,0,'ballast',88),
(2753,0,'ledger',64),
(2754,0,'vault',65),
(2755,0,'ballast',85),
(2756,0,'bills',81),
(2757,0,'grid',65),
(2758,0,'bills',79),
(2759,0,'cloud',100),
(2760,0,'bills',78),
(2761,0,'ballast',75),
(2762,0,'bills',94),
(2763,0,'grid',62),
(2764,0,'trial',97),
(2765,0,'ballast',62),
(2766,0,'ledger',94),
(2767,0,'vault',62),
(2768,0,'shelf',91),
(2769,0,'ballast',67),
(2770,0,'brand',88),
(2771,0,'brand',90),
(2772,0,'crude',92),
(2773,0,'claims',85),
(2774,0,'shelf',72),
(2775,0,'rails',74),
(2776,0,'shelf',100),
(2777,0,'crude',78),
(2778,0,'rails',86),
(2779,0,'ballast',100),
(2780,0,'rails',97),
(2781,0,'vault',71),
(2782,0,'shelf',90),
(2783,0,'claims',67),
(2784,0,'shelf',63),
(2785,0,'grid',60),
(2786,0,'cloud',94),
(2787,0,'shelf',72),
(2788,0,'rails',97),
(2789,0,'bills',85),
(2790,0,'platform',62),
(2791,0,'shelf',87),
(2792,0,'bills',65),
(2793,0,'ledger',79),
(2794,0,'shelf',72),
(2795,0,'rails',73),
(2796,0,'ballast',81),
(2797,0,'silicon',98),
(2798,0,'shelf',71),
(2799,0,'shelf',83),
(2800,0,'shelf',97),
(2801,0,'platform',89),
(2802,0,'vault',94),
(2803,0,'silicon',85),
(2804,0,'shelf',93),
(2805,0,'cloud',69),
(2806,0,'bills',79),
(2807,0,'grid',66),
(2808,0,'cloud',80),
(2809,0,'grid',92),
(2810,0,'ledger',76),
(2811,0,'teller',82),
(2812,0,'platform',92),
(2813,0,'ballast',94),
(2814,0,'grid',91),
(2815,0,'shelf',97),
(2816,0,'claims',80),
(2817,0,'bills',88),
(2818,0,'bills',98),
(2819,0,'crude',92),
(2820,0,'silicon',97),
(2821,0,'shelf',87),
(2822,0,'grid',100),
(2823,0,'silicon',95),
(2824,0,'shelf',62),
(2825,0,'rails',72),
(2826,0,'brand',67),
(2827,0,'rails',91),
(2828,0,'bills',70),
(2829,0,'platform',79),
(2830,0,'bills',62),
(2831,0,'cloud',77),
(2832,0,'rails',62),
(2833,0,'rails',82),
(2834,0,'ledger',99),
(2835,0,'shelf',80),
(2836,0,'grid',61),
(2837,0,'claims',80),
(2838,0,'cloud',68),
(2839,0,'bills',100),
(2840,0,'claims',86),
(2841,0,'cloud',75),
(2842,0,'shelf',99),
(2843,0,'grid',76),
(2844,0,'rails',68),
(2845,0,'grid',82),
(2846,0,'bills',63),
(2847,0,'cloud',77),
(2848,0,'shelf',97),
(2849,0,'ballast',64),
(2850,0,'rails',67),
(2851,0,'shelf',90),
(2852,0,'claims',61),
(2853,0,'silicon',95),
(2854,0,'bills',78),
(2855,0,'platform',92),
(2856,0,'crude',84),
(2857,0,'vault',60),
(2858,0,'teller',100),
(2859,0,'claims',80),
(2860,0,'vault',74),
(2861,0,'ledger',73),
(2862,0,'platform',87),
(2863,0,'shelf',72),
(2864,0,'ballast',100),
(2865,0,'ledger',86),
(2866,0,'cloud',69),
(2867,0,'degen',79),
(2868,0,'ballast',96),
(2869,0,'bills',61),
(2870,0,'shelf',84),
(2871,0,'brand',82),
(2872,0,'cloud',62),
(2873,0,'ballast',73),
(2874,0,'shelf',83),
(2875,0,'ledger',65),
(2876,0,'grid',98),
(2877,0,'ledger',80),
(2878,0,'teller',89),
(2879,0,'vault',73),
(2880,0,'claims',66),
(2881,0,'platform',78),
(2882,0,'cloud',65),
(2883,0,'bills',86),
(2884,0,'rails',96),
(2885,0,'ballast',64),
(2886,0,'rails',75),
(2887,0,'claims',81),
(2888,0,'claims',86),
(2889,0,'rails',81),
(2890,0,'brand',82),
(2891,0,'crude',74),
(2892,0,'degen',84),
(2893,0,'degen',72),
(2894,0,'ballast',66),
(2895,0,'bills',71),
(2896,0,'ledger',71),
(2897,0,'vault',93),
(2898,0,'claims',82),
(2899,0,'ledger',87),
(2900,0,'shelf',72),
(2901,0,'bills',87),
(2902,0,'trial',60),
(2903,0,'silicon',84),
(2904,0,'bills',82),
(2905,0,'ballast',77),
(2906,0,'crude',75),
(2907,0,'cloud',81),
(2908,0,'shelf',86),
(2909,0,'teller',93),
(2910,0,'ledger',84),
(2911,0,'claims',75),
(2912,0,'grid',72),
(2913,0,'shelf',96),
(2914,0,'vault',69),
(2915,0,'rails',63),
(2916,0,'ledger',63),
(2917,0,'shelf',61),
(2918,0,'grid',87),
(2919,0,'brand',82),
(2920,0,'degen',68),
(2921,0,'cloud',90),
(2922,0,'platform',75),
(2923,0,'teller',98),
(2924,0,'bills',87),
(2925,0,'cloud',90),
(2926,0,'bills',73),
(2927,0,'grid',74),
(2928,0,'ballast',91),
(2929,0,'claims',86),
(2930,0,'ballast',92),
(2931,0,'ballast',99),
(2932,0,'trial',76),
(2933,0,'rails',85),
(2934,0,'vault',73),
(2935,0,'silicon',85),
(2936,0,'claims',77),
(2937,0,'bills',96),
(2938,0,'grid',96),
(2939,0,'ledger',91),
(2940,0,'ballast',79),
(2941,0,'grid',94),
(2942,0,'bills',100),
(2943,0,'trial',82),
(2944,0,'rails',95),
(2945,0,'platform',67),
(2946,0,'silicon',98),
(2947,0,'grid',69),
(2948,0,'platform',78),
(2949,0,'crude',79),
(2950,0,'claims',68),
(2951,0,'ledger',62),
(2952,0,'brand',76),
(2953,0,'crude',72),
(2954,0,'ledger',91),
(2955,0,'shelf',64),
(2956,0,'teller',65),
(2957,0,'brand',94),
(2958,0,'trial',97),
(2959,0,'crude',65),
(2960,0,'brand',62),
(2961,0,'trial',90),
(2962,0,'crude',82),
(2963,0,'platform',87),
(2964,0,'trial',71),
(2965,0,'trial',94),
(2966,0,'ballast',76),
(2967,0,'grid',99),
(2968,0,'grid',96),
(2969,0,'cloud',96),
(2970,0,'rails',88),
(2971,0,'platform',63),
(2972,0,'claims',85),
(2973,0,'grid',82),
(2974,0,'ballast',76),
(2975,0,'shelf',66),
(2976,0,'grid',97),
(2977,0,'vault',67),
(2978,0,'ledger',75),
(2979,0,'bills',76),
(2980,0,'shelf',99),
(2981,0,'degen',80),
(2982,0,'ballast',81),
(2983,0,'cloud',92),
(2984,0,'bills',89),
(2985,0,'silicon',89),
(2986,0,'trial',80),
(2987,0,'cloud',88),
(2988,0,'brand',76),
(2989,0,'platform',84),
(2990,0,'shelf',64),
(2991,0,'ledger',97),
(2992,0,'claims',68),
(2993,0,'ballast',67),
(2994,0,'rails',80),
(2995,0,'ballast',90),
(2996,0,'shelf',95),
(2997,0,'rails',64),
(2998,0,'silicon',81),
(2999,0,'rails',87),
(3000,0,'grid',98),
(3001,0,'crude',68),
(3002,0,'cloud',73),
(3003,0,'vault',85),
(3004,0,'ballast',87),
(3005,0,'ballast',62),
(3006,0,'ballast',82),
(3007,0,'claims',80),
(3008,0,'shelf',62),
(3009,0,'ballast',60),
(3010,0,'vault',95),
(3011,0,'trial',66),
(3012,0,'crude',71),
(3013,0,'ballast',79),
(3014,0,'claims',89),
(3015,0,'ballast',64),
(3016,0,'shelf',72),
(3017,0,'silicon',74),
(3018,0,'claims',94),
(3019,0,'grid',97),
(3020,0,'brand',86),
(3021,0,'claims',73),
(3022,0,'ballast',87),
(3023,0,'platform',76),
(3024,0,'trial',100),
(3025,0,'silicon',95),
(3026,0,'ballast',99),
(3027,0,'claims',83),
(3028,0,'teller',74),
(3029,0,'vault',78),
(3030,0,'ballast',90),
(3031,0,'rails',96),
(3032,0,'claims',93),
(3033,0,'cloud',82),
(3034,0,'ballast',62),
(3035,0,'platform',100),
(3036,0,'platform',79),
(3037,0,'silicon',75),
(3038,0,'platform',98),
(3039,0,'trial',82),
(3040,0,'platform',83),
(3041,0,'platform',75),
(3042,0,'trial',96),
(3043,0,'ledger',85),
(3044,0,'ballast',93),
(3045,0,'trial',82),
(3046,0,'platform',86),
(3047,0,'silicon',87),
(3048,0,'silicon',91),
(3049,0,'shelf',74),
(3050,0,'brand',83),
(3051,0,'degen',88),
(3052,0,'teller',91),
(3053,0,'bills',78),
(3054,0,'grid',79),
(3055,0,'platform',96),
(3056,0,'silicon',74),
(3057,0,'shelf',77),
(3058,0,'bills',62),
(3059,0,'claims',93),
(3060,0,'brand',90),
(3061,0,'rails',71),
(3062,0,'ballast',74),
(3063,0,'ballast',70),
(3064,0,'brand',98),
(3065,0,'shelf',95),
(3066,0,'shelf',74),
(3067,0,'ledger',87),
(3068,0,'ballast',96),
(3069,0,'ballast',60),
(3070,0,'shelf',71),
(3071,0,'platform',62),
(3072,0,'grid',60),
(3073,0,'vault',100),
(3074,0,'crude',77),
(3075,0,'ballast',63),
(3076,0,'rails',79),
(3077,0,'brand',69),
(3078,0,'platform',61),
(3079,0,'brand',94),
(3080,0,'platform',65),
(3081,0,'grid',65),
(3082,0,'silicon',74),
(3083,0,'cloud',91),
(3084,0,'shelf',60),
(3085,0,'ledger',96),
(3086,0,'brand',78),
(3087,0,'bills',70),
(3088,0,'brand',69),
(3089,0,'ledger',66),
(3090,0,'bills',83),
(3091,0,'bills',70),
(3092,0,'bills',74),
(3093,0,'shelf',79),
(3094,0,'claims',61),
(3095,0,'grid',70),
(3096,0,'ballast',84),
(3097,0,'bills',67),
(3098,0,'ledger',81),
(3099,0,'platform',76),
(3100,0,'grid',72),
(3101,0,'bills',60),
(3102,0,'ledger',89),
(3103,0,'ledger',89),
(3104,0,'rails',72),
(3105,0,'silicon',81),
(3106,0,'vault',93),
(3107,0,'bills',90),
(3108,0,'crude',77),
(3109,0,'vault',72),
(3110,0,'ballast',97),
(3111,0,'brand',89),
(3112,0,'claims',80),
(3113,0,'grid',95),
(3114,0,'silicon',82),
(3115,0,'crude',89),
(3116,0,'ledger',69),
(3117,0,'platform',65),
(3118,0,'ballast',100),
(3119,0,'shelf',75),
(3120,0,'grid',85),
(3121,0,'silicon',72),
(3122,0,'trial',73),
(3123,0,'claims',86),
(3124,0,'ballast',72),
(3125,0,'ballast',76),
(3126,0,'brand',73),
(3127,0,'ballast',89),
(3128,0,'grid',73),
(3129,0,'rails',94),
(3130,0,'cloud',77),
(3131,0,'platform',62),
(3132,0,'brand',63),
(3133,0,'ledger',92),
(3134,0,'ledger',65),
(3135,0,'trial',91),
(3136,0,'claims',67),
(3137,0,'ballast',69),
(3138,0,'shelf',67),
(3139,0,'ballast',94),
(3140,0,'brand',78),
(3141,0,'shelf',63),
(3142,0,'trial',96),
(3143,0,'trial',87),
(3144,0,'ballast',86),
(3145,0,'vault',95),
(3146,0,'cloud',71),
(3147,0,'bills',73),
(3148,0,'rails',81),
(3149,0,'brand',79),
(3150,0,'silicon',94),
(3151,0,'rails',70),
(3152,0,'shelf',87),
(3153,0,'teller',79),
(3154,0,'brand',98),
(3155,0,'grid',68),
(3156,0,'brand',63),
(3157,0,'shelf',71),
(3158,0,'shelf',67),
(3159,0,'silicon',70),
(3160,0,'ledger',71),
(3161,0,'ballast',88),
(3162,0,'trial',87),
(3163,0,'grid',85),
(3164,0,'bills',93),
(3165,0,'ballast',92),
(3166,0,'platform',82),
(3167,0,'claims',82),
(3168,0,'brand',73),
(3169,0,'degen',72),
(3170,0,'claims',68),
(3171,0,'trial',71),
(3172,0,'degen',91),
(3173,0,'cloud',87),
(3174,0,'platform',99),
(3175,0,'brand',70),
(3176,0,'platform',73),
(3177,0,'shelf',100),
(3178,0,'brand',76),
(3179,0,'grid',96),
(3180,0,'ballast',84),
(3181,0,'cloud',60),
(3182,0,'platform',75),
(3183,0,'ledger',73),
(3184,0,'brand',84),
(3185,0,'ledger',87),
(3186,0,'vault',80),
(3187,0,'vault',91),
(3188,0,'rails',74),
(3189,0,'vault',70),
(3190,0,'rails',81),
(3191,0,'vault',63),
(3192,0,'brand',70),
(3193,0,'ballast',90),
(3194,0,'bills',88),
(3195,0,'ballast',83),
(3196,0,'ballast',79),
(3197,0,'teller',85),
(3198,0,'silicon',75),
(3199,0,'bills',91),
(3200,0,'brand',85),
(3201,0,'ballast',96),
(3202,0,'shelf',64),
(3203,0,'brand',96),
(3204,0,'bills',84),
(3205,0,'grid',82),
(3206,0,'ledger',68),
(3207,0,'ledger',70),
(3208,0,'crude',78),
(3209,0,'grid',77),
(3210,0,'ballast',93),
(3211,0,'shelf',63),
(3212,0,'trial',66),
(3213,0,'shelf',90),
(3214,0,'grid',86),
(3215,0,'platform',83),
(3216,0,'shelf',76),
(3217,0,'trial',67),
(3218,0,'silicon',93),
(3219,0,'grid',88),
(3220,0,'bills',64),
(3221,0,'brand',84),
(3222,0,'ledger',69),
(3223,0,'brand',96),
(3224,0,'trial',88),
(3225,0,'platform',60),
(3226,0,'vault',71),
(3227,0,'ballast',79),
(3228,0,'ballast',67),
(3229,0,'claims',84),
(3230,0,'ballast',99),
(3231,0,'trial',79),
(3232,0,'bills',67),
(3233,0,'vault',98),
(3234,0,'brand',60),
(3235,0,'ballast',64),
(3236,0,'shelf',71),
(3237,0,'ledger',69),
(3238,0,'cloud',100),
(3239,0,'brand',89),
(3240,0,'claims',90),
(3241,0,'ballast',90),
(3242,0,'trial',83),
(3243,0,'ledger',96),
(3244,0,'cloud',95),
(3245,0,'claims',87),
(3246,0,'shelf',79),
(3247,0,'vault',97),
(3248,0,'trial',90),
(3249,0,'platform',60),
(3250,0,'silicon',92),
(3251,0,'bills',79),
(3252,0,'ballast',88),
(3253,0,'trial',70),
(3254,0,'ballast',86),
(3255,0,'ballast',61),
(3256,0,'ballast',78),
(3257,0,'cloud',66),
(3258,0,'claims',90),
(3259,0,'ballast',95),
(3260,0,'shelf',76),
(3261,0,'cloud',87),
(3262,0,'ledger',71),
(3263,0,'claims',84),
(3264,0,'brand',100),
(3265,0,'brand',90),
(3266,0,'brand',80),
(3267,0,'bills',63),
(3268,0,'ledger',78),
(3269,0,'ballast',96),
(3270,0,'bills',86),
(3271,0,'trial',82),
(3272,0,'rails',100),
(3273,0,'trial',77),
(3274,0,'vault',84),
(3275,0,'vault',97),
(3276,0,'crude',80),
(3277,0,'brand',97),
(3278,0,'cloud',66),
(3279,0,'grid',80),
(3280,0,'ledger',67),
(3281,0,'ledger',93),
(3282,0,'platform',62),
(3283,0,'bills',65),
(3284,0,'ballast',72),
(3285,0,'shelf',74),
(3286,0,'rails',76),
(3287,0,'brand',65),
(3288,0,'claims',97),
(3289,0,'grid',96),
(3290,0,'cloud',88),
(3291,0,'shelf',72),
(3292,0,'ledger',64),
(3293,0,'ballast',65),
(3294,0,'claims',76),
(3295,0,'cloud',98),
(3296,0,'ledger',62),
(3297,0,'shelf',73),
(3298,0,'grid',98),
(3299,0,'shelf',83),
(3300,0,'cloud',92),
(3301,0,'teller',74),
(3302,0,'shelf',75),
(3303,0,'vault',78),
(3304,0,'bills',100),
(3305,0,'crude',80),
(3306,0,'vault',95),
(3307,0,'crude',66),
(3308,0,'brand',90),
(3309,0,'brand',63),
(3310,0,'platform',93),
(3311,0,'vault',98),
(3312,0,'rails',97),
(3313,0,'silicon',89),
(3314,0,'brand',91),
(3315,0,'rails',93),
(3316,0,'ledger',79),
(3317,0,'crude',74),
(3318,0,'shelf',96),
(3319,0,'trial',92),
(3320,0,'ballast',68),
(3321,0,'ballast',75),
(3322,0,'cloud',65),
(3323,0,'ballast',70),
(3324,0,'ballast',72),
(3325,0,'platform',81),
(3326,0,'teller',71),
(3327,0,'grid',78),
(3328,0,'grid',72),
(3329,0,'rails',80),
(3330,0,'claims',96),
(3331,0,'vault',95),
(3332,0,'crude',96),
(3333,0,'claims',100),
(3334,0,'silicon',62),
(3335,0,'brand',68),
(3336,0,'grid',69),
(3337,0,'vault',69),
(3338,0,'ballast',70),
(3339,0,'ballast',86),
(3340,0,'brand',61),
(3341,0,'claims',79),
(3342,0,'cloud',80),
(3343,0,'cloud',66),
(3344,0,'ballast',63),
(3345,0,'bills',94),
(3346,0,'ledger',89),
(3347,0,'shelf',63),
(3348,0,'vault',78),
(3349,0,'ballast',89),
(3350,0,'cloud',91),
(3351,0,'trial',89),
(3352,0,'claims',79),
(3353,0,'vault',64),
(3354,0,'silicon',78),
(3355,0,'crude',94),
(3356,0,'rails',61),
(3357,0,'bills',96),
(3358,0,'ledger',68),
(3359,0,'vault',97),
(3360,0,'platform',90),
(3361,0,'crude',68),
(3362,0,'shelf',68),
(3363,0,'silicon',95),
(3364,0,'grid',69),
(3365,0,'claims',86),
(3366,0,'ledger',95),
(3367,0,'teller',70),
(3368,0,'claims',87),
(3369,0,'cloud',66),
(3370,0,'grid',98),
(3371,0,'shelf',99),
(3372,0,'shelf',73),
(3373,0,'rails',97),
(3374,0,'cloud',91),
(3375,0,'vault',61),
(3376,0,'degen',63),
(3377,0,'bills',67),
(3378,0,'ballast',66),
(3379,0,'crude',69),
(3380,0,'bills',85),
(3381,0,'ballast',99),
(3382,0,'platform',98),
(3383,0,'crude',88),
(3384,0,'vault',66),
(3385,0,'claims',79),
(3386,0,'ledger',98),
(3387,0,'claims',89),
(3388,0,'rails',76),
(3389,0,'crude',83),
(3390,0,'ledger',86),
(3391,0,'rails',65),
(3392,0,'bills',71),
(3393,0,'cloud',79),
(3394,0,'bills',80),
(3395,0,'ballast',75),
(3396,0,'brand',67),
(3397,0,'grid',99),
(3398,0,'bills',69),
(3399,0,'trial',93),
(3400,0,'vault',75),
(3401,0,'brand',99),
(3402,0,'ballast',92),
(3403,0,'ballast',78),
(3404,0,'crude',89),
(3405,0,'platform',68),
(3406,0,'vault',79),
(3407,0,'crude',92),
(3408,0,'shelf',62),
(3409,0,'vault',81),
(3410,0,'brand',61),
(3411,0,'teller',92),
(3412,0,'shelf',90),
(3413,0,'ledger',82),
(3414,0,'platform',64),
(3415,0,'vault',83),
(3416,0,'ledger',79),
(3417,0,'grid',62),
(3418,0,'silicon',81),
(3419,0,'ballast',86),
(3420,0,'degen',98),
(3421,0,'brand',72),
(3422,0,'silicon',77),
(3423,0,'claims',89),
(3424,0,'cloud',88),
(3425,0,'brand',95),
(3426,0,'trial',62),
(3427,0,'bills',97),
(3428,0,'claims',98),
(3429,0,'bills',96),
(3430,0,'shelf',94),
(3431,0,'silicon',80),
(3432,0,'rails',71),
(3433,0,'bills',83),
(3434,0,'shelf',60),
(3435,0,'rails',76),
(3436,0,'trial',77),
(3437,0,'vault',65),
(3438,0,'degen',69),
(3439,0,'bills',86),
(3440,0,'cloud',79),
(3441,0,'ledger',99),
(3442,0,'grid',96),
(3443,0,'shelf',89),
(3444,0,'trial',77),
(3445,0,'ledger',87),
(3446,0,'ledger',60),
(3447,0,'grid',91),
(3448,0,'trial',69),
(3449,0,'grid',88),
(3450,0,'rails',79),
(3451,0,'platform',90),
(3452,0,'cloud',68),
(3453,0,'ledger',66),
(3454,0,'shelf',70),
(3455,0,'ballast',60),
(3456,0,'ledger',88),
(3457,0,'grid',83),
(3458,0,'bills',75),
(3459,0,'ballast',66),
(3460,0,'rails',66),
(3461,0,'brand',86),
(3462,0,'silicon',91),
(3463,0,'vault',100),
(3464,0,'cloud',63),
(3465,0,'brand',62),
(3466,0,'bills',64),
(3467,0,'bills',84),
(3468,0,'rails',76),
(3469,0,'bills',89),
(3470,0,'cloud',92),
(3471,0,'ballast',97),
(3472,0,'brand',69),
(3473,0,'silicon',62),
(3474,0,'grid',84),
(3475,0,'crude',64),
(3476,0,'grid',87),
(3477,0,'brand',90),
(3478,0,'platform',98),
(3479,0,'silicon',86),
(3480,0,'rails',76),
(3481,0,'grid',61),
(3482,0,'bills',97),
(3483,0,'platform',75),
(3484,0,'bills',83),
(3485,0,'bills',64),
(3486,0,'grid',88),
(3487,0,'platform',75),
(3488,0,'platform',65),
(3489,0,'ballast',94),
(3490,0,'vault',84),
(3491,0,'ledger',60),
(3492,0,'ballast',85),
(3493,0,'brand',62),
(3494,0,'crude',64),
(3495,0,'shelf',92),
(3496,0,'vault',78),
(3497,0,'trial',78),
(3498,0,'vault',88),
(3499,0,'grid',85),
(3500,0,'brand',96),
(3501,0,'bills',97),
(3502,0,'vault',72),
(3503,0,'vault',87),
(3504,0,'trial',86),
(3505,0,'bills',66),
(3506,0,'ledger',60),
(3507,0,'rails',95),
(3508,0,'shelf',71),
(3509,0,'rails',93),
(3510,0,'claims',81),
(3511,0,'grid',82),
(3512,0,'shelf',73),
(3513,0,'crude',71),
(3514,0,'brand',88),
(3515,0,'teller',64),
(3516,0,'trial',87),
(3517,0,'teller',76),
(3518,0,'bills',94),
(3519,0,'shelf',62),
(3520,0,'grid',63),
(3521,0,'claims',75),
(3522,0,'shelf',78),
(3523,0,'trial',66),
(3524,0,'brand',69),
(3525,0,'ledger',80),
(3526,0,'cloud',72),
(3527,0,'ledger',66),
(3528,0,'silicon',98),
(3529,0,'platform',74),
(3530,0,'claims',78),
(3531,0,'ledger',75),
(3532,0,'silicon',92),
(3533,0,'ledger',80),
(3534,0,'brand',77),
(3535,0,'claims',70),
(3536,0,'bills',83),
(3537,0,'rails',71),
(3538,0,'shelf',83),
(3539,0,'cloud',76),
(3540,0,'vault',98),
(3541,0,'shelf',62),
(3542,0,'teller',60),
(3543,0,'silicon',65),
(3544,0,'vault',98),
(3545,0,'vault',67),
(3546,0,'platform',72),
(3547,0,'brand',73),
(3548,0,'grid',94),
(3549,0,'rails',87),
(3550,0,'shelf',86),
(3551,0,'claims',82),
(3552,0,'ballast',63),
(3553,0,'shelf',82),
(3554,0,'brand',66),
(3555,0,'vault',64),
(3556,0,'crude',68),
(3557,0,'trial',63),
(3558,0,'shelf',60),
(3559,0,'crude',66),
(3560,0,'platform',65),
(3561,0,'brand',65),
(3562,0,'platform',75),
(3563,0,'shelf',83),
(3564,0,'degen',63),
(3565,0,'ledger',61),
(3566,0,'grid',100),
(3567,0,'grid',94),
(3568,0,'crude',93),
(3569,0,'brand',65),
(3570,0,'cloud',79),
(3571,0,'crude',89),
(3572,0,'platform',99),
(3573,0,'ledger',81),
(3574,0,'brand',98),
(3575,0,'shelf',80),
(3576,0,'teller',90),
(3577,0,'trial',60),
(3578,0,'teller',63),
(3579,0,'shelf',68),
(3580,0,'ledger',61),
(3581,0,'shelf',87),
(3582,0,'brand',88),
(3583,0,'bills',70),
(3584,0,'ballast',80),
(3585,0,'silicon',60),
(3586,0,'shelf',76),
(3587,0,'crude',82),
(3588,0,'claims',62),
(3589,0,'trial',87),
(3590,0,'brand',70),
(3591,0,'rails',60),
(3592,0,'shelf',86),
(3593,0,'ballast',67),
(3594,0,'silicon',64),
(3595,0,'shelf',95),
(3596,0,'rails',89),
(3597,0,'crude',71),
(3598,0,'silicon',78),
(3599,0,'grid',83),
(3600,0,'bills',79),
(3601,0,'rails',67),
(3602,0,'shelf',95),
(3603,0,'brand',92),
(3604,0,'rails',60),
(3605,0,'ballast',77),
(3606,0,'rails',64),
(3607,0,'claims',92),
(3608,0,'ballast',86),
(3609,0,'bills',91),
(3610,0,'platform',70),
(3611,0,'ledger',95),
(3612,0,'shelf',62),
(3613,0,'ballast',60),
(3614,0,'shelf',75),
(3615,0,'ledger',88),
(3616,0,'rails',91),
(3617,0,'degen',95),
(3618,0,'ballast',71),
(3619,0,'shelf',80),
(3620,0,'silicon',80),
(3621,0,'platform',61),
(3622,0,'trial',92),
(3623,0,'trial',98),
(3624,0,'claims',87),
(3625,0,'platform',86),
(3626,0,'rails',64),
(3627,0,'cloud',66),
(3628,0,'grid',82),
(3629,0,'vault',90),
(3630,0,'crude',61),
(3631,0,'brand',82),
(3632,0,'grid',73),
(3633,0,'rails',73),
(3634,0,'rails',95),
(3635,0,'claims',81),
(3636,0,'silicon',99),
(3637,0,'platform',96),
(3638,0,'claims',97),
(3639,0,'claims',64),
(3640,0,'ballast',95),
(3641,0,'brand',80),
(3642,0,'crude',97),
(3643,0,'claims',68),
(3644,0,'silicon',99),
(3645,0,'trial',62),
(3646,0,'rails',70),
(3647,0,'claims',64),
(3648,0,'ballast',98),
(3649,0,'silicon',81),
(3650,0,'vault',85),
(3651,0,'claims',64),
(3652,0,'shelf',82),
(3653,0,'platform',82),
(3654,0,'silicon',85),
(3655,0,'vault',94),
(3656,0,'grid',76),
(3657,0,'cloud',96),
(3658,0,'vault',72),
(3659,0,'ballast',95),
(3660,0,'trial',89),
(3661,0,'rails',61),
(3662,0,'trial',68),
(3663,0,'teller',89),
(3664,0,'trial',95),
(3665,0,'ballast',68),
(3666,0,'ledger',78),
(3667,0,'ballast',92),
(3668,0,'claims',81),
(3669,0,'crude',68),
(3670,0,'brand',80),
(3671,0,'cloud',99),
(3672,0,'platform',65),
(3673,0,'ballast',83),
(3674,0,'ballast',92),
(3675,0,'shelf',70),
(3676,0,'grid',89),
(3677,0,'bills',71),
(3678,0,'ballast',61),
(3679,0,'brand',87),
(3680,0,'ballast',90),
(3681,0,'grid',97),
(3682,0,'grid',99),
(3683,0,'vault',87),
(3684,0,'platform',66),
(3685,0,'brand',94),
(3686,0,'rails',69),
(3687,0,'grid',68),
(3688,0,'brand',79),
(3689,0,'ballast',91),
(3690,0,'ledger',79),
(3691,0,'cloud',60),
(3692,0,'claims',95),
(3693,0,'silicon',60),
(3694,0,'ledger',80),
(3695,0,'bills',94),
(3696,0,'cloud',76),
(3697,0,'ballast',73),
(3698,0,'claims',75),
(3699,0,'silicon',92),
(3700,0,'cloud',97),
(3701,0,'platform',65),
(3702,0,'grid',91),
(3703,0,'rails',93),
(3704,0,'ledger',86),
(3705,0,'crude',68),
(3706,0,'brand',81),
(3707,0,'trial',88),
(3708,0,'trial',60),
(3709,0,'platform',91),
(3710,0,'shelf',98),
(3711,0,'ballast',82),
(3712,0,'platform',72),
(3713,0,'crude',75),
(3714,0,'silicon',67),
(3715,0,'grid',94),
(3716,0,'shelf',60),
(3717,0,'silicon',80),
(3718,0,'shelf',97),
(3719,0,'shelf',62),
(3720,0,'brand',60),
(3721,0,'ledger',69),
(3722,0,'rails',77),
(3723,0,'shelf',62),
(3724,0,'bills',69),
(3725,0,'claims',72),
(3726,0,'brand',93),
(3727,0,'platform',83),
(3728,0,'ledger',81),
(3729,0,'grid',91),
(3730,0,'trial',75),
(3731,0,'teller',67),
(3732,0,'brand',62),
(3733,0,'brand',77),
(3734,0,'grid',63),
(3735,0,'bills',71),
(3736,0,'brand',60),
(3737,0,'ledger',95),
(3738,0,'vault',94),
(3739,0,'shelf',99),
(3740,0,'grid',91),
(3741,0,'trial',80),
(3742,0,'ledger',94),
(3743,0,'claims',66),
(3744,0,'ballast',76),
(3745,0,'ballast',64),
(3746,0,'claims',89),
(3747,0,'rails',71),
(3748,0,'bills',78),
(3749,0,'bills',75),
(3750,0,'rails',64),
(3751,0,'platform',93),
(3752,0,'grid',68),
(3753,0,'rails',92),
(3754,0,'grid',92),
(3755,0,'silicon',92),
(3756,0,'platform',71),
(3757,0,'brand',81),
(3758,0,'grid',70),
(3759,0,'silicon',66),
(3760,0,'vault',82),
(3761,0,'claims',91),
(3762,0,'cloud',81),
(3763,0,'bills',70),
(3764,0,'trial',74),
(3765,0,'claims',90),
(3766,0,'ledger',77),
(3767,0,'claims',62),
(3768,0,'claims',75),
(3769,0,'grid',97),
(3770,0,'silicon',61),
(3771,0,'vault',81),
(3772,0,'vault',89),
(3773,0,'rails',93),
(3774,0,'brand',81),
(3775,0,'ledger',76),
(3776,0,'claims',66),
(3777,0,'claims',97),
(3778,0,'trial',99),
(3779,0,'claims',90),
(3780,0,'ledger',86),
(3781,0,'trial',88),
(3782,0,'brand',71),
(3783,0,'rails',72),
(3784,0,'grid',62),
(3785,0,'vault',96),
(3786,0,'claims',66),
(3787,0,'trial',87),
(3788,0,'shelf',85),
(3789,0,'ballast',70),
(3790,0,'claims',61),
(3791,0,'vault',77),
(3792,0,'rails',74),
(3793,0,'ballast',84),
(3794,0,'claims',83),
(3795,0,'silicon',70),
(3796,0,'teller',76),
(3797,0,'platform',66),
(3798,0,'teller',63),
(3799,0,'ledger',74),
(3800,0,'bills',90),
(3801,0,'platform',97),
(3802,0,'rails',88),
(3803,0,'degen',90),
(3804,0,'teller',77),
(3805,0,'ledger',99),
(3806,0,'shelf',60),
(3807,0,'claims',67),
(3808,0,'claims',82),
(3809,0,'bills',71),
(3810,0,'trial',86),
(3811,0,'shelf',97),
(3812,0,'grid',79),
(3813,0,'bills',81),
(3814,0,'trial',95),
(3815,0,'bills',72),
(3816,0,'bills',65),
(3817,0,'shelf',83),
(3818,0,'ballast',73),
(3819,0,'ballast',65),
(3820,0,'brand',94),
(3821,0,'shelf',79),
(3822,0,'shelf',60),
(3823,0,'vault',84),
(3824,0,'ballast',63),
(3825,0,'rails',70),
(3826,0,'trial',68),
(3827,0,'platform',94),
(3828,0,'crude',90),
(3829,0,'grid',67),
(3830,0,'claims',61),
(3831,0,'ballast',85),
(3832,0,'shelf',95),
(3833,0,'ballast',68),
(3834,0,'rails',98),
(3835,0,'degen',75),
(3836,0,'trial',64),
(3837,0,'rails',92),
(3838,0,'cloud',60),
(3839,0,'brand',89),
(3840,0,'ledger',88),
(3841,0,'brand',88),
(3842,0,'bills',62),
(3843,0,'platform',64),
(3844,0,'bills',69),
(3845,0,'rails',99),
(3846,0,'bills',83),
(3847,0,'trial',71),
(3848,0,'ledger',81),
(3849,0,'bills',90),
(3850,0,'ballast',63),
(3851,0,'rails',94),
(3852,0,'claims',62),
(3853,0,'bills',100),
(3854,0,'rails',79),
(3855,0,'silicon',79),
(3856,0,'vault',68),
(3857,0,'ballast',94),
(3858,0,'grid',82),
(3859,0,'vault',70),
(3860,0,'bills',75),
(3861,0,'grid',82),
(3862,0,'trial',93),
(3863,0,'ledger',89),
(3864,0,'bills',94),
(3865,0,'ledger',95),
(3866,0,'grid',96),
(3867,0,'cloud',65),
(3868,0,'shelf',62),
(3869,0,'platform',96),
(3870,0,'bills',86),
(3871,0,'claims',89),
(3872,0,'degen',98),
(3873,0,'bills',92),
(3874,0,'trial',68),
(3875,0,'trial',71),
(3876,0,'silicon',62),
(3877,0,'brand',97),
(3878,0,'rails',92),
(3879,0,'crude',97),
(3880,0,'brand',89),
(3881,0,'cloud',69),
(3882,0,'ballast',62),
(3883,0,'trial',96),
(3884,0,'brand',64),
(3885,0,'trial',69),
(3886,0,'bills',87),
(3887,0,'brand',92),
(3888,0,'ballast',87),
(3889,0,'vault',81),
(3890,0,'platform',77),
(3891,0,'platform',82),
(3892,0,'claims',61),
(3893,0,'shelf',62),
(3894,0,'grid',85),
(3895,0,'trial',89),
(3896,0,'rails',65),
(3897,0,'ledger',77),
(3898,0,'shelf',64),
(3899,0,'bills',84),
(3900,0,'crude',71),
(3901,0,'trial',62),
(3902,0,'ledger',85),
(3903,0,'rails',99),
(3904,0,'bills',72),
(3905,0,'teller',74),
(3906,0,'ledger',82),
(3907,0,'claims',75),
(3908,0,'ledger',87),
(3909,0,'ballast',83),
(3910,0,'brand',77),
(3911,0,'ledger',61),
(3912,0,'grid',92),
(3913,0,'platform',100),
(3914,0,'ledger',82),
(3915,0,'trial',64),
(3916,0,'claims',89),
(3917,0,'silicon',69),
(3918,0,'ballast',68),
(3919,0,'claims',61),
(3920,0,'claims',74),
(3921,0,'claims',85),
(3922,0,'degen',85),
(3923,0,'grid',92),
(3924,0,'crude',88),
(3925,0,'shelf',84),
(3926,0,'shelf',66),
(3927,0,'grid',95),
(3928,0,'ledger',74),
(3929,0,'ballast',96),
(3930,0,'shelf',67),
(3931,0,'rails',68),
(3932,0,'trial',93),
(3933,0,'rails',91),
(3934,0,'brand',62),
(3935,0,'vault',83),
(3936,0,'grid',62),
(3937,0,'cloud',84),
(3938,0,'ballast',97),
(3939,0,'brand',88),
(3940,0,'trial',62),
(3941,0,'cloud',86),
(3942,0,'grid',86),
(3943,0,'rails',72),
(3944,0,'grid',72),
(3945,0,'crude',98),
(3946,0,'cloud',95),
(3947,0,'shelf',60),
(3948,0,'bills',82),
(3949,0,'degen',93),
(3950,0,'crude',92),
(3951,0,'rails',81),
(3952,0,'grid',86),
(3953,0,'platform',81),
(3954,0,'rails',91),
(3955,0,'bills',66),
(3956,0,'silicon',67),
(3957,0,'claims',68),
(3958,0,'ballast',61),
(3959,0,'platform',96),
(3960,0,'bills',84),
(3961,0,'shelf',62),
(3962,0,'claims',88),
(3963,0,'bills',98),
(3964,0,'vault',94),
(3965,0,'vault',77),
(3966,0,'platform',72),
(3967,0,'rails',73),
(3968,0,'vault',66),
(3969,0,'claims',89),
(3970,0,'grid',94),
(3971,0,'claims',89),
(3972,0,'shelf',68),
(3973,0,'crude',64),
(3974,0,'platform',78),
(3975,0,'bills',63),
(3976,0,'vault',66),
(3977,0,'teller',89),
(3978,0,'ballast',83),
(3979,0,'bills',90),
(3980,0,'platform',100),
(3981,0,'rails',78),
(3982,0,'platform',88),
(3983,0,'silicon',68),
(3984,0,'rails',100),
(3985,0,'brand',87),
(3986,0,'cloud',86),
(3987,0,'claims',96),
(3988,0,'vault',64),
(3989,0,'trial',68),
(3990,0,'brand',75),
(3991,0,'bills',70),
(3992,0,'rails',100),
(3993,0,'shelf',76),
(3994,0,'shelf',84),
(3995,0,'crude',79),
(3996,0,'bills',64),
(3997,0,'shelf',66),
(3998,0,'bills',72),
(3999,0,'claims',66),
(4000,0,'vault',79),
(4001,0,'shelf',62),
(4002,0,'vault',68),
(4003,0,'vault',99),
(4004,0,'brand',70),
(4005,0,'vault',74),
(4006,0,'grid',70),
(4007,0,'platform',60),
(4008,0,'shelf',78),
(4009,0,'brand',78),
(4010,0,'rails',76),
(4011,0,'shelf',69),
(4012,0,'claims',89),
(4013,0,'rails',88),
(4014,0,'vault',92),
(4015,0,'silicon',77),
(4016,0,'ballast',87),
(4017,0,'shelf',68),
(4018,0,'rails',97),
(4019,0,'grid',94),
(4020,0,'bills',93),
(4021,0,'vault',96),
(4022,0,'vault',100),
(4023,0,'bills',64),
(4024,0,'grid',60),
(4025,0,'brand',90),
(4026,0,'bills',65),
(4027,0,'ledger',62),
(4028,0,'rails',67),
(4029,0,'vault',65),
(4030,0,'silicon',90),
(4031,0,'brand',98),
(4032,0,'rails',95),
(4033,0,'platform',97),
(4034,0,'rails',79),
(4035,0,'rails',84),
(4036,0,'cloud',83),
(4037,0,'rails',63),
(4038,0,'trial',80),
(4039,0,'shelf',92),
(4040,0,'ledger',67),
(4041,0,'trial',92),
(4042,0,'brand',78),
(4043,0,'claims',93),
(4044,0,'platform',90),
(4045,0,'ballast',88),
(4046,0,'vault',88),
(4047,0,'shelf',70),
(4048,0,'platform',83),
(4049,0,'ballast',61),
(4050,0,'claims',81),
(4051,0,'bills',93),
(4052,0,'brand',71),
(4053,0,'grid',82),
(4054,0,'shelf',62),
(4055,0,'grid',84),
(4056,0,'silicon',65),
(4057,0,'claims',98),
(4058,0,'crude',100),
(4059,0,'shelf',81),
(4060,0,'brand',62),
(4061,0,'vault',65),
(4062,0,'bills',68),
(4063,0,'grid',85),
(4064,0,'cloud',64),
(4065,0,'grid',77),
(4066,0,'trial',72),
(4067,0,'trial',74),
(4068,0,'brand',98),
(4069,0,'shelf',82),
(4070,0,'rails',74),
(4071,0,'platform',97),
(4072,0,'vault',78),
(4073,0,'grid',93),
(4074,0,'ledger',90),
(4075,0,'bills',98),
(4076,0,'bills',88),
(4077,0,'rails',79),
(4078,0,'shelf',61),
(4079,0,'grid',73),
(4080,0,'teller',83),
(4081,0,'brand',100),
(4082,0,'ledger',99),
(4083,0,'bills',64),
(4084,0,'brand',92),
(4085,0,'bills',94),
(4086,0,'bills',71),
(4087,0,'bills',81),
(4088,0,'teller',71),
(4089,0,'brand',62),
(4090,0,'brand',97),
(4091,0,'brand',97),
(4092,0,'crude',64),
(4093,0,'platform',98),
(4094,0,'ballast',61),
(4095,0,'brand',80),
(4096,0,'silicon',98),
(4097,0,'silicon',61),
(4098,0,'vault',95),
(4099,0,'cloud',85),
(4100,0,'trial',76),
(4101,0,'vault',89),
(4102,0,'teller',98),
(4103,0,'grid',69),
(4104,0,'ballast',69),
(4105,0,'degen',77),
(4106,0,'bills',78),
(4107,0,'ballast',66),
(4108,0,'shelf',78),
(4109,0,'cloud',74),
(4110,0,'brand',99),
(4111,0,'brand',83),
(4112,0,'ballast',76),
(4113,0,'shelf',87),
(4114,0,'shelf',73),
(4115,0,'grid',83),
(4116,0,'platform',62),
(4117,0,'brand',92),
(4118,0,'shelf',70),
(4119,0,'trial',95),
(4120,0,'bills',75),
(4121,0,'claims',84),
(4122,0,'rails',96),
(4123,0,'platform',64),
(4124,0,'teller',94),
(4125,0,'claims',88),
(4126,0,'brand',98),
(4127,0,'trial',75),
(4128,0,'platform',88),
(4129,0,'rails',66),
(4130,0,'crude',79),
(4131,0,'ballast',91),
(4132,0,'rails',87),
(4133,0,'ledger',74),
(4134,0,'bills',85),
(4135,0,'shelf',94),
(4136,0,'ledger',85),
(4137,0,'bills',83),
(4138,0,'grid',87),
(4139,0,'ledger',92),
(4140,0,'cloud',64),
(4141,0,'cloud',68),
(4142,0,'cloud',76),
(4143,0,'ledger',89),
(4144,0,'crude',63),
(4145,0,'brand',65),
(4146,0,'bills',96),
(4147,0,'ballast',70),
(4148,0,'claims',77),
(4149,0,'bills',65),
(4150,0,'trial',85),
(4151,0,'ledger',70),
(4152,0,'platform',89),
(4153,0,'degen',87),
(4154,0,'grid',66),
(4155,0,'platform',77),
(4156,0,'trial',63),
(4157,0,'brand',64),
(4158,0,'bills',65),
(4159,0,'claims',75),
(4160,0,'claims',64),
(4161,0,'shelf',76),
(4162,0,'cloud',65),
(4163,0,'shelf',72),
(4164,0,'crude',60),
(4165,0,'silicon',67),
(4166,0,'ledger',87),
(4167,0,'vault',88),
(4168,0,'platform',80),
(4169,0,'claims',84),
(4170,0,'crude',89),
(4171,0,'shelf',99),
(4172,0,'grid',93),
(4173,0,'brand',92),
(4174,0,'degen',62),
(4175,0,'brand',99),
(4176,0,'platform',61),
(4177,0,'grid',95),
(4178,0,'rails',94),
(4179,0,'silicon',61),
(4180,0,'rails',66),
(4181,0,'bills',68),
(4182,0,'brand',99),
(4183,0,'crude',81),
(4184,0,'claims',73),
(4185,0,'bills',68),
(4186,0,'cloud',87),
(4187,0,'ballast',86),
(4188,0,'trial',62),
(4189,0,'shelf',60),
(4190,0,'silicon',67),
(4191,0,'claims',61),
(4192,0,'cloud',86),
(4193,0,'grid',78),
(4194,0,'bills',86),
(4195,0,'shelf',72),
(4196,0,'brand',100),
(4197,0,'shelf',97),
(4198,0,'bills',97),
(4199,0,'brand',67),
(4200,0,'vault',82),
(4201,0,'trial',77),
(4202,0,'ledger',87),
(4203,0,'brand',88),
(4204,0,'brand',94),
(4205,0,'brand',84),
(4206,0,'silicon',90),
(4207,0,'vault',64),
(4208,0,'crude',77),
(4209,0,'degen',72),
(4210,0,'platform',72),
(4211,0,'brand',73),
(4212,0,'shelf',63),
(4213,0,'crude',78),
(4214,0,'claims',88),
(4215,0,'cloud',70),
(4216,0,'bills',96),
(4217,0,'grid',93),
(4218,0,'cloud',68),
(4219,0,'trial',80),
(4220,0,'ledger',83),
(4221,0,'shelf',89),
(4222,0,'cloud',67),
(4223,0,'vault',90),
(4224,0,'platform',66),
(4225,0,'silicon',74),
(4226,0,'shelf',69),
(4227,0,'trial',64),
(4228,0,'shelf',68),
(4229,0,'bills',67),
(4230,0,'ledger',89),
(4231,0,'teller',88),
(4232,0,'bills',93),
(4233,0,'claims',67),
(4234,0,'claims',79),
(4235,0,'grid',80),
(4236,0,'shelf',74),
(4237,0,'brand',92),
(4238,0,'shelf',84),
(4239,0,'platform',100),
(4240,0,'platform',67),
(4241,0,'grid',83),
(4242,0,'brand',79),
(4243,0,'ballast',90),
(4244,0,'shelf',96),
(4245,0,'grid',84),
(4246,0,'rails',92),
(4247,0,'cloud',67),
(4248,0,'ballast',68),
(4249,0,'shelf',63),
(4250,0,'ballast',68),
(4251,0,'grid',74),
(4252,0,'crude',79),
(4253,0,'claims',91),
(4254,0,'crude',95),
(4255,0,'claims',94),
(4256,0,'bills',70),
(4257,0,'brand',63),
(4258,0,'silicon',90),
(4259,0,'brand',76),
(4260,0,'grid',73),
(4261,0,'brand',88),
(4262,0,'vault',96),
(4263,0,'ballast',88),
(4264,0,'crude',95),
(4265,0,'claims',72),
(4266,0,'ballast',60),
(4267,0,'cloud',77),
(4268,0,'ballast',94),
(4269,0,'trial',65),
(4270,0,'trial',80),
(4271,0,'claims',86),
(4272,0,'silicon',88),
(4273,0,'crude',70),
(4274,0,'rails',84),
(4275,0,'brand',93),
(4276,0,'brand',61),
(4277,0,'ballast',82),
(4278,0,'cloud',100),
(4279,0,'bills',94),
(4280,0,'platform',92),
(4281,0,'rails',69),
(4282,0,'cloud',79),
(4283,0,'degen',69),
(4284,0,'trial',78),
(4285,0,'platform',76),
(4286,0,'cloud',67),
(4287,0,'cloud',70),
(4288,0,'shelf',65),
(4289,0,'brand',64),
(4290,0,'ledger',69),
(4291,0,'trial',70),
(4292,0,'ballast',75),
(4293,0,'vault',94),
(4294,0,'teller',81),
(4295,0,'shelf',83),
(4296,0,'vault',100),
(4297,0,'bills',77),
(4298,0,'vault',75),
(4299,0,'grid',86),
(4300,0,'rails',76),
(4301,0,'silicon',75),
(4302,0,'bills',93),
(4303,0,'brand',75),
(4304,0,'grid',78),
(4305,0,'teller',77),
(4306,0,'shelf',89),
(4307,0,'rails',94),
(4308,0,'rails',62),
(4309,0,'ledger',89),
(4310,0,'brand',80),
(4311,0,'vault',88),
(4312,0,'silicon',96),
(4313,0,'shelf',69),
(4314,0,'ballast',81),
(4315,0,'bills',96),
(4316,0,'vault',96),
(4317,0,'vault',100),
(4318,0,'silicon',99),
(4319,0,'shelf',89),
(4320,0,'platform',97),
(4321,0,'crude',90),
(4322,0,'shelf',78),
(4323,0,'rails',92),
(4324,0,'claims',64),
(4325,0,'ledger',85),
(4326,0,'claims',61),
(4327,0,'ballast',91),
(4328,0,'bills',84),
(4329,0,'grid',93),
(4330,0,'ballast',94),
(4331,0,'ballast',62),
(4332,0,'bills',61),
(4333,0,'bills',66),
(4334,0,'degen',85),
(4335,0,'bills',75),
(4336,0,'ballast',84),
(4337,0,'ledger',69),
(4338,0,'bills',93),
(4339,0,'ledger',73),
(4340,0,'ledger',72),
(4341,0,'bills',68),
(4342,0,'teller',94),
(4343,0,'ledger',97),
(4344,0,'shelf',75),
(4345,0,'trial',64),
(4346,0,'brand',75),
(4347,0,'bills',75),
(4348,0,'brand',86),
(4349,0,'bills',60),
(4350,0,'ballast',60),
(4351,0,'vault',70),
(4352,0,'shelf',65),
(4353,0,'ledger',73),
(4354,0,'shelf',64),
(4355,0,'bills',80),
(4356,0,'claims',83),
(4357,0,'ledger',74),
(4358,0,'shelf',86),
(4359,0,'shelf',71),
(4360,0,'vault',87),
(4361,0,'brand',77),
(4362,0,'vault',61),
(4363,0,'ledger',68),
(4364,0,'rails',73),
(4365,0,'vault',60),
(4366,0,'vault',99),
(4367,0,'ledger',65),
(4368,0,'brand',73),
(4369,0,'rails',89),
(4370,0,'grid',78),
(4371,0,'rails',88),
(4372,0,'ballast',92),
(4373,0,'claims',79),
(4374,0,'crude',65),
(4375,0,'vault',89),
(4376,0,'claims',63),
(4377,0,'bills',85),
(4378,0,'brand',89),
(4379,0,'bills',63),
(4380,0,'teller',90),
(4381,0,'shelf',89),
(4382,0,'trial',96),
(4383,0,'cloud',87),
(4384,0,'brand',98),
(4385,0,'ledger',67),
(4386,0,'platform',65),
(4387,0,'claims',85),
(4388,0,'vault',99),
(4389,0,'crude',95),
(4390,0,'silicon',62),
(4391,0,'brand',99),
(4392,0,'vault',96),
(4393,0,'vault',91),
(4394,0,'rails',84),
(4395,0,'brand',97),
(4396,0,'vault',97),
(4397,0,'platform',76),
(4398,0,'ballast',65),
(4399,0,'shelf',63),
(4400,0,'vault',91),
(4401,0,'bills',98),
(4402,0,'cloud',83),
(4403,0,'ledger',63),
(4404,0,'rails',89),
(4405,0,'ballast',89),
(4406,0,'bills',92),
(4407,0,'cloud',92),
(4408,0,'vault',88),
(4409,0,'platform',95),
(4410,0,'ballast',73),
(4411,0,'shelf',63),
(4412,0,'silicon',89),
(4413,0,'grid',82),
(4414,0,'trial',63),
(4415,0,'ballast',92),
(4416,0,'vault',89),
(4417,0,'crude',99),
(4418,0,'ledger',72),
(4419,0,'claims',83),
(4420,0,'trial',71),
(4421,0,'grid',80),
(4422,0,'bills',61),
(4423,0,'shelf',67),
(4424,0,'rails',64),
(4425,0,'trial',62),
(4426,0,'ballast',81),
(4427,0,'shelf',88),
(4428,0,'bills',62),
(4429,0,'crude',80),
(4430,0,'brand',62),
(4431,0,'shelf',63),
(4432,0,'silicon',90),
(4433,0,'claims',91),
(4434,0,'rails',96),
(4435,0,'vault',94),
(4436,0,'cloud',97),
(4437,0,'rails',67),
(4438,0,'platform',65),
(4439,0,'cloud',80),
(4440,0,'ballast',76),
(4441,0,'bills',88),
(4442,0,'rails',90),
(4443,0,'shelf',84),
(4444,0,'claims',94),
(4445,0,'grid',80),
(4446,0,'bills',68),
(4447,0,'brand',96),
(4448,0,'vault',79),
(4449,0,'vault',74),
(4450,0,'ballast',96),
(4451,0,'teller',67),
(4452,0,'cloud',65),
(4453,0,'claims',72),
(4454,0,'claims',68),
(4455,0,'bills',82),
(4456,0,'rails',72),
(4457,0,'vault',74),
(4458,0,'shelf',64),
(4459,0,'crude',67),
(4460,0,'crude',71),
(4461,0,'rails',87),
(4462,0,'ballast',70),
(4463,0,'rails',82),
(4464,0,'bills',79),
(4465,0,'platform',87),
(4466,0,'platform',94),
(4467,0,'ballast',60),
(4468,0,'bills',82),
(4469,0,'claims',80),
(4470,0,'degen',98),
(4471,0,'platform',75),
(4472,0,'claims',77),
(4473,0,'platform',94),
(4474,0,'ballast',74),
(4475,0,'trial',77),
(4476,0,'ledger',78),
(4477,0,'silicon',68),
(4478,0,'brand',99),
(4479,0,'crude',60),
(4480,0,'cloud',92),
(4481,0,'ballast',82),
(4482,0,'rails',81),
(4483,0,'ledger',85),
(4484,0,'ledger',67),
(4485,0,'vault',99),
(4486,0,'cloud',99),
(4487,0,'platform',61),
(4488,0,'trial',100),
(4489,0,'ballast',92),
(4490,0,'bills',92),
(4491,0,'bills',73),
(4492,0,'rails',75),
(4493,0,'platform',90),
(4494,0,'cloud',100),
(4495,0,'silicon',60),
(4496,0,'shelf',96),
(4497,0,'ledger',79),
(4498,0,'shelf',92),
(4499,0,'shelf',70),
(4500,0,'bills',78),
(4501,0,'crude',89),
(4502,0,'trial',68),
(4503,0,'bills',84),
(4504,0,'grid',83),
(4505,0,'claims',90),
(4506,0,'ledger',79),
(4507,0,'cloud',87),
(4508,0,'vault',80),
(4509,0,'grid',88),
(4510,0,'ballast',74),
(4511,0,'bills',76),
(4512,0,'brand',68),
(4513,0,'grid',72),
(4514,0,'vault',76),
(4515,0,'brand',74),
(4516,0,'vault',94),
(4517,0,'claims',91),
(4518,0,'ballast',84),
(4519,0,'ballast',85),
(4520,0,'cloud',92),
(4521,0,'bills',83),
(4522,0,'claims',91),
(4523,0,'claims',77),
(4524,0,'grid',96),
(4525,0,'trial',80),
(4526,0,'brand',95),
(4527,0,'claims',97),
(4528,0,'grid',72),
(4529,0,'platform',68),
(4530,0,'ballast',83),
(4531,0,'grid',95),
(4532,0,'rails',100),
(4533,0,'silicon',89),
(4534,0,'crude',62),
(4535,0,'brand',77),
(4536,0,'shelf',88),
(4537,0,'shelf',70),
(4538,0,'shelf',69),
(4539,0,'shelf',79),
(4540,0,'shelf',72),
(4541,0,'ballast',95),
(4542,0,'claims',68),
(4543,0,'rails',100),
(4544,0,'grid',78),
(4545,0,'claims',75),
(4546,0,'crude',92),
(4547,0,'brand',82),
(4548,0,'shelf',71),
(4549,0,'vault',73),
(4550,0,'shelf',77),
(4551,0,'vault',91),
(4552,0,'cloud',81),
(4553,0,'grid',68),
(4554,0,'ledger',88),
(4555,0,'ledger',87),
(4556,0,'grid',63),
(4557,0,'bills',97),
(4558,0,'silicon',74),
(4559,0,'cloud',81),
(4560,0,'claims',96),
(4561,0,'ledger',77),
(4562,0,'trial',74),
(4563,0,'trial',89),
(4564,0,'rails',61),
(4565,0,'brand',84),
(4566,0,'shelf',96),
(4567,0,'trial',70),
(4568,0,'bills',92),
(4569,0,'trial',72),
(4570,0,'brand',67),
(4571,0,'platform',74),
(4572,0,'ledger',71),
(4573,0,'bills',62),
(4574,0,'vault',97),
(4575,0,'brand',83),
(4576,0,'grid',79),
(4577,0,'vault',90),
(4578,0,'vault',78),
(4579,0,'ballast',80),
(4580,0,'bills',88),
(4581,0,'ballast',92),
(4582,0,'crude',78),
(4583,0,'silicon',90),
(4584,0,'vault',63),
(4585,0,'bills',64),
(4586,0,'brand',68),
(4587,0,'cloud',82),
(4588,0,'platform',66),
(4589,0,'silicon',69),
(4590,0,'vault',93),
(4591,0,'bills',66),
(4592,0,'ballast',68),
(4593,0,'ledger',82),
(4594,0,'vault',99),
(4595,0,'ledger',90),
(4596,0,'grid',92),
(4597,0,'trial',92),
(4598,0,'cloud',70),
(4599,0,'trial',90),
(4600,0,'platform',81),
(4601,0,'grid',85),
(4602,0,'shelf',66),
(4603,0,'bills',79),
(4604,0,'grid',92),
(4605,0,'bills',63),
(4606,0,'shelf',67),
(4607,0,'platform',75),
(4608,0,'vault',100),
(4609,0,'trial',94),
(4610,0,'platform',73),
(4611,0,'ballast',71),
(4612,0,'bills',87),
(4613,0,'shelf',82),
(4614,0,'claims',96),
(4615,0,'trial',75),
(4616,0,'silicon',62),
(4617,0,'vault',61),
(4618,0,'brand',77),
(4619,0,'brand',86),
(4620,0,'silicon',66),
(4621,0,'brand',97),
(4622,0,'cloud',80),
(4623,0,'trial',75),
(4624,0,'grid',87),
(4625,0,'shelf',72),
(4626,0,'rails',89),
(4627,0,'rails',87),
(4628,0,'bills',87),
(4629,0,'platform',70),
(4630,0,'platform',93),
(4631,0,'bills',65),
(4632,0,'brand',69),
(4633,0,'shelf',87),
(4634,0,'vault',61),
(4635,0,'silicon',69),
(4636,0,'ballast',68),
(4637,0,'shelf',78),
(4638,0,'bills',91),
(4639,0,'ballast',96),
(4640,0,'platform',90),
(4641,0,'ballast',63),
(4642,0,'ledger',99),
(4643,0,'ballast',92),
(4644,0,'rails',88),
(4645,0,'cloud',98),
(4646,0,'trial',77),
(4647,0,'bills',91),
(4648,0,'trial',85),
(4649,0,'trial',77),
(4650,0,'rails',84),
(4651,0,'silicon',88),
(4652,0,'vault',80),
(4653,0,'shelf',69),
(4654,0,'platform',98),
(4655,0,'vault',77),
(4656,0,'shelf',96),
(4657,0,'grid',73),
(4658,0,'rails',72),
(4659,0,'cloud',97),
(4660,0,'grid',82),
(4661,0,'cloud',93),
(4662,0,'brand',92),
(4663,0,'rails',77),
(4664,0,'ledger',82),
(4665,0,'vault',69),
(4666,0,'vault',83),
(4667,0,'ballast',98),
(4668,0,'bills',62),
(4669,0,'ballast',67),
(4670,0,'silicon',77),
(4671,0,'ballast',94),
(4672,0,'rails',76),
(4673,0,'degen',71),
(4674,0,'platform',91),
(4675,0,'cloud',60),
(4676,0,'ballast',96),
(4677,0,'ballast',71),
(4678,0,'trial',61),
(4679,0,'ledger',95),
(4680,0,'rails',67),
(4681,0,'rails',73),
(4682,0,'vault',99),
(4683,0,'crude',95),
(4684,0,'platform',67),
(4685,0,'crude',67),
(4686,0,'crude',87),
(4687,0,'crude',72),
(4688,0,'shelf',66),
(4689,0,'platform',95),
(4690,0,'shelf',78),
(4691,0,'claims',62),
(4692,0,'bills',78),
(4693,0,'bills',92),
(4694,0,'vault',81),
(4695,0,'vault',79),
(4696,0,'vault',99),
(4697,0,'brand',92),
(4698,0,'bills',61),
(4699,0,'trial',86),
(4700,0,'ballast',92),
(4701,0,'bills',79),
(4702,0,'bills',98),
(4703,0,'brand',75),
(4704,0,'bills',84),
(4705,0,'ballast',87),
(4706,0,'ballast',62),
(4707,0,'vault',67),
(4708,0,'ledger',79),
(4709,0,'ballast',83),
(4710,0,'ledger',95),
(4711,0,'ledger',88),
(4712,0,'trial',98),
(4713,0,'crude',90),
(4714,0,'rails',97),
(4715,0,'ballast',80),
(4716,0,'brand',91),
(4717,0,'vault',96),
(4718,0,'brand',74),
(4719,0,'crude',72),
(4720,0,'bills',83),
(4721,0,'ballast',67),
(4722,0,'brand',84),
(4723,0,'trial',62),
(4724,0,'shelf',63),
(4725,0,'crude',65),
(4726,0,'trial',84),
(4727,0,'brand',62),
(4728,0,'ballast',60),
(4729,0,'claims',68),
(4730,0,'shelf',78),
(4731,0,'brand',83),
(4732,0,'shelf',92),
(4733,0,'grid',92),
(4734,0,'ballast',89),
(4735,0,'bills',80),
(4736,0,'shelf',89),
(4737,0,'ballast',64),
(4738,0,'ballast',71),
(4739,0,'ledger',95),
(4740,0,'bills',66),
(4741,0,'grid',72),
(4742,0,'shelf',71),
(4743,0,'bills',74),
(4744,0,'ballast',98),
(4745,0,'shelf',79),
(4746,0,'vault',70),
(4747,0,'claims',74),
(4748,0,'vault',80),
(4749,0,'ledger',82),
(4750,0,'ballast',61),
(4751,0,'vault',87),
(4752,0,'crude',98),
(4753,0,'rails',83),
(4754,0,'crude',66),
(4755,0,'grid',66),
(4756,0,'cloud',98),
(4757,0,'trial',92),
(4758,0,'shelf',97),
(4759,0,'grid',65),
(4760,0,'shelf',64),
(4761,0,'ledger',82),
(4762,0,'ballast',96),
(4763,0,'crude',75),
(4764,0,'vault',68),
(4765,0,'grid',78),
(4766,0,'cloud',74),
(4767,0,'shelf',82),
(4768,0,'bills',96),
(4769,0,'crude',81),
(4770,0,'vault',87),
(4771,0,'rails',79),
(4772,0,'ballast',65),
(4773,0,'vault',100),
(4774,0,'cloud',99),
(4775,0,'grid',99),
(4776,0,'ballast',81),
(4777,0,'teller',99),
(4778,0,'grid',99),
(4779,0,'grid',95),
(4780,0,'vault',99),
(4781,0,'bills',79),
(4782,0,'teller',64),
(4783,0,'bills',97),
(4784,0,'bills',64),
(4785,0,'vault',73),
(4786,0,'ballast',63),
(4787,0,'brand',81),
(4788,0,'brand',63),
(4789,0,'platform',83),
(4790,0,'grid',73),
(4791,0,'rails',61),
(4792,0,'cloud',100),
(4793,0,'ledger',89),
(4794,0,'claims',65),
(4795,0,'vault',75),
(4796,0,'claims',78),
(4797,0,'vault',69),
(4798,0,'platform',61),
(4799,0,'platform',65),
(4800,0,'silicon',99),
(4801,0,'ballast',68),
(4802,0,'silicon',74),
(4803,0,'rails',87),
(4804,0,'claims',76),
(4805,0,'ballast',70),
(4806,0,'ballast',66),
(4807,0,'cloud',91),
(4808,0,'crude',72),
(4809,0,'rails',95),
(4810,0,'grid',80),
(4811,0,'rails',94),
(4812,0,'shelf',97),
(4813,0,'platform',87),
(4814,0,'bills',96),
(4815,0,'bills',69),
(4816,0,'claims',92),
(4817,0,'platform',89),
(4818,0,'trial',79),
(4819,0,'crude',73),
(4820,0,'teller',63),
(4821,0,'shelf',89),
(4822,0,'ballast',67),
(4823,0,'ballast',86),
(4824,0,'rails',67),
(4825,0,'crude',96),
(4826,0,'platform',83),
(4827,0,'bills',100),
(4828,0,'crude',79),
(4829,0,'ledger',83),
(4830,0,'silicon',61),
(4831,0,'ballast',64),
(4832,0,'claims',71),
(4833,0,'ledger',74),
(4834,0,'rails',89),
(4835,0,'platform',96),
(4836,0,'crude',83),
(4837,0,'cloud',85),
(4838,0,'brand',97),
(4839,0,'rails',97),
(4840,0,'cloud',72),
(4841,0,'ballast',96),
(4842,0,'ballast',73),
(4843,0,'crude',80),
(4844,0,'silicon',72),
(4845,0,'teller',89),
(4846,0,'silicon',77),
(4847,0,'brand',69),
(4848,0,'ballast',100),
(4849,0,'trial',61),
(4850,0,'rails',67),
(4851,0,'shelf',83),
(4852,0,'ledger',87),
(4853,0,'cloud',85),
(4854,0,'brand',63),
(4855,0,'shelf',79),
(4856,0,'vault',78),
(4857,0,'platform',77),
(4858,0,'degen',71),
(4859,0,'grid',85),
(4860,0,'ledger',82),
(4861,0,'bills',84),
(4862,0,'claims',85),
(4863,0,'ballast',90),
(4864,0,'trial',100),
(4865,0,'brand',70),
(4866,0,'claims',84),
(4867,0,'cloud',70),
(4868,0,'grid',95),
(4869,0,'silicon',61),
(4870,0,'crude',76),
(4871,0,'shelf',95),
(4872,0,'bills',76),
(4873,0,'cloud',95),
(4874,0,'degen',68),
(4875,0,'shelf',60),
(4876,0,'vault',93),
(4877,0,'shelf',70),
(4878,0,'platform',63),
(4879,0,'teller',90),
(4880,0,'platform',87),
(4881,0,'ledger',100),
(4882,0,'ballast',88),
(4883,0,'crude',94),
(4884,0,'shelf',96),
(4885,0,'crude',100),
(4886,0,'cloud',78),
(4887,0,'brand',68),
(4888,0,'ballast',98),
(4889,0,'silicon',63),
(4890,0,'cloud',73),
(4891,0,'grid',80),
(4892,0,'ballast',84),
(4893,0,'bills',89),
(4894,0,'ballast',71),
(4895,0,'vault',64),
(4896,0,'grid',89),
(4897,0,'brand',84),
(4898,0,'trial',68),
(4899,0,'shelf',68),
(4900,0,'silicon',97),
(4901,0,'bills',77),
(4902,0,'grid',100),
(4903,0,'cloud',84),
(4904,0,'crude',73),
(4905,0,'crude',89),
(4906,0,'ledger',82),
(4907,0,'claims',68),
(4908,0,'shelf',63),
(4909,0,'claims',73),
(4910,0,'crude',86),
(4911,0,'rails',84),
(4912,0,'grid',73),
(4913,0,'trial',89),
(4914,0,'crude',66),
(4915,0,'shelf',77),
(4916,0,'platform',77),
(4917,0,'teller',70),
(4918,0,'platform',87),
(4919,0,'shelf',96),
(4920,0,'shelf',65),
(4921,0,'vault',70),
(4922,0,'bills',66),
(4923,0,'shelf',73),
(4924,0,'bills',71),
(4925,0,'ledger',76),
(4926,0,'shelf',97),
(4927,0,'ballast',98),
(4928,0,'grid',96),
(4929,0,'bills',90),
(4930,0,'rails',77),
(4931,0,'claims',92),
(4932,0,'cloud',73),
(4933,0,'ballast',60),
(4934,0,'cloud',98),
(4935,0,'platform',100),
(4936,0,'brand',95),
(4937,0,'ballast',89),
(4938,0,'rails',100),
(4939,0,'rails',68),
(4940,0,'cloud',95),
(4941,0,'platform',88),
(4942,0,'rails',78),
(4943,0,'grid',62),
(4944,0,'ballast',86),
(4945,0,'vault',72),
(4946,0,'silicon',81),
(4947,0,'platform',85),
(4948,0,'cloud',86),
(4949,0,'ballast',79),
(4950,0,'claims',93),
(4951,0,'ballast',84),
(4952,0,'shelf',84),
(4953,0,'bills',69),
(4954,0,'shelf',64),
(4955,0,'cloud',71),
(4956,0,'teller',98),
(4957,0,'teller',86),
(4958,0,'claims',92),
(4959,0,'ballast',64),
(4960,0,'shelf',76),
(4961,0,'shelf',91),
(4962,0,'shelf',98),
(4963,0,'ballast',94),
(4964,0,'vault',84),
(4965,0,'vault',68),
(4966,0,'cloud',73),
(4967,0,'platform',71),
(4968,0,'rails',89),
(4969,0,'shelf',81),
(4970,0,'grid',79),
(4971,0,'bills',83),
(4972,0,'platform',82),
(4973,0,'claims',92),
(4974,0,'platform',75),
(4975,0,'shelf',82),
(4976,0,'trial',73),
(4977,0,'trial',82),
(4978,0,'brand',96),
(4979,0,'ledger',79),
(4980,0,'ballast',83),
(4981,0,'grid',96),
(4982,0,'vault',95),
(4983,0,'brand',96),
(4984,0,'brand',70),
(4985,0,'ledger',85),
(4986,0,'degen',74),
(4987,0,'ledger',69),
(4988,0,'ledger',78),
(4989,0,'rails',97),
(4990,0,'platform',64),
(4991,0,'ledger',64),
(4992,0,'vault',75),
(4993,0,'ledger',70),
(4994,0,'silicon',96),
(4995,0,'cloud',86),
(4996,0,'cloud',76),
(4997,0,'cloud',87),
(4998,0,'trial',89),
(4999,0,'ballast',91);

-- ---------------------------------------------------------------------------
-- THE APY RECONCILIATION
-- ---------------------------------------------------------------------------
--
-- `blendedApy` is the MEAN of a worker's effective rates — deliberately a mean
-- and not a sum, because more skills means more desks and more diversification
-- rather than a flat multiple of the yield. This block recomputes that mean in
-- exact decimal arithmetic from the rows above plus public.skills, and compares
-- it to the apy the generator wrote in 20260806090300.
--
-- It is the most valuable assertion in the seed, because it is the only one that
-- cross-checks two independently emitted files against a third table. A skill
-- assigned to the wrong serial shifts a blended rate by whole percentage points;
-- a truncated skills file leaves a worker short a desk and drops its mean. Both
-- are invisible to a row count and neither survives this.
--
-- The tolerance is one unit in the last stored place. `apy` is numeric(8,6) and
-- the generator rounds a float64 mean into it, so the two can differ by up to
-- half of 1e-6 by construction — the generator measures that drift and refuses to
-- emit if it ever exceeds it. Anything larger than 1e-6 is not rounding.
do $$
declare
  v_rows integer;
  v_bad  integer;
  v_rec  record;
begin
  select count(*) into v_rows from public.xployee_skills;
  if v_rows <> 7900 then
    raise exception 'seeded % skill rows, expected 7900', v_rows;
  end if;

  -- Every worker holds exactly as many skills as its tier says. The primary key
  -- stops a slot being written twice and the unique constraint stops a skill
  -- being held twice; neither can see a worker that is simply short one row.
  select count(*) into v_bad from (
    select x.id
      from public.xployees x
      left join public.xployee_skills xs on xs.xployee_id = x.id
     group by x.id, x.skills
    having count(xs.slot) <> x.skills
  ) d;
  if v_bad > 0 then
    raise exception '% xployees hold the wrong number of skills for their tier', v_bad;
  end if;

  -- Slots are 0..n-1 with no gaps, so "the third skill" means the same thing to
  -- the database and to the sheet that renders it.
  select count(*) into v_bad from (
    select xs.xployee_id
      from public.xployee_skills xs
     group by xs.xployee_id
    having min(xs.slot) <> 0 or max(xs.slot) <> count(*) - 1
  ) d;
  if v_bad > 0 then
    raise exception '% xployees have gaps in their skill slots', v_bad;
  end if;

  for v_rec in
    select x.id,
           x.apy as stored,
           avg(s.base_apy * xs.proficiency_pct / 100) as computed
      from public.xployees x
      join public.xployee_skills xs on xs.xployee_id = x.id
      join public.skills s          on s.id = xs.skill_id
     group by x.id, x.apy
    having abs(x.apy - avg(s.base_apy * xs.proficiency_pct / 100)) > 0.000001
     limit 5
  loop
    raise exception 'xployee % stores apy % but its desks blend to %',
      public.serial_label(v_rec.id), v_rec.stored, round(v_rec.computed, 8);
  end loop;
end;
$$;

-- Now that every worker has its desks, the apy column can stop being nullable.
-- Left open until this point on purpose: a NOT NULL declared before the seed
-- would have to be satisfied by whichever file happened to load first, and the
-- apy is only meaningful once the rows it is the mean of exist.
alter table public.xployees alter column apy set not null;
alter table public.xployees alter column tier set not null;
alter table public.xployees alter column skills set not null;
alter table public.xployees alter column principal set not null;
alter table public.xployees alter column art_seed set not null;

-- A note for anyone reading the migrations in order rather than as one push:
-- `art_seed` becoming NOT NULL breaks the INSERT branch of the ORIGINAL
-- `record_simulated_sale` from 20260805120100, which upserts (id, owner) and
-- supplies no art seed. That branch is unreachable — every serial exists from
-- 20260806090300, so the upsert always takes its UPDATE path — and the function
-- is rewritten in 20260806090800 into an update-only writer that raises on an
-- unknown serial. It also has no caller: nothing in this backend invokes it, by
-- design, because an unauthenticated endpoint that inserts sale rows would let
-- anyone reassign any xployee. The window between these two migrations is inside
-- a single `db push`.

comment on column public.xployees.apy is
  'Blended annual rate: the MEAN of this worker''s effective desk rates. Reconciled against public.xployee_desks at seed time to one unit in the last stored place.';


-- =========================================================================
-- SECTION 10 of 16 — 20260806090500_seed_xnet_genesis.sql
-- =========================================================================

-- xNFTs index — seed: the genesis holding.
--
-- 1 xployee: #0000 X-RATED, held by the project wallet.
--
-- GENERATED — do not edit by hand. Run:
--   npx vite-node scripts/gen-genesis-seed.ts
--
-- This is the whole shipped state of the index. Everything else a visitor sees
-- — listings, other wallets, activity, earnings history — is absent because it
-- has not happened yet. Two earlier versions of this file seeded 512 xployees
-- over 97 invented wallets and then 35 over one; both claimed a history the
-- protocol did not have, and none of those addresses existed.
--
-- Rarity is positional, so serial 0 is the first X-RATED in the supply. The
-- hire timestamp is protocol genesis, so this worker opens with zero accrued
-- yield and earns from day one like every xployee minted after it.
--
-- Ownership is a placeholder until an operator runs assign_genesis_crew().

create table if not exists public.genesis_crew (
  serial integer primary key references public.xployees (id),
  owner text not null,
  hired_at bigint not null
);

alter table public.genesis_crew enable row level security;

drop policy if exists genesis_crew_read on public.genesis_crew;
create policy genesis_crew_read
  on public.genesis_crew for select to anon, authenticated using (true);

-- The policy alone is not enough. It decides which ROWS a role may see; the
-- GRANT decides whether the role may touch the table at all, and Postgres
-- checks the grant first. Without this, a read comes back as
--   401  42501  permission denied for table genesis_crew
-- which looks like an auth failure and is a missing privilege.
grant select on public.genesis_crew to anon, authenticated;

-- Denied twice, at two layers, and both are needed. The revoke is grant-level;
-- the restrictive policies are the RLS-level denial, and they AND together with
-- everything else so `false` is final. Every other table in the schema carries
-- this trio, and 20260806091100_rls_policies.sql ends with an assertion that
-- walks every table in `public` and raises if one is missing it — so a table
-- with only the revoke aborts that migration with
--   P0001: table public.genesis_crew is missing a restrictive write denial
revoke insert, update, delete on public.genesis_crew from anon, authenticated;

create policy "genesis_crew accepts no client insert" on public.genesis_crew
  as restrictive for insert to anon, authenticated with check (false);
create policy "genesis_crew accepts no client update" on public.genesis_crew
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "genesis_crew accepts no client delete" on public.genesis_crew
  as restrictive for delete to anon, authenticated using (false);

insert into public.genesis_crew (serial, owner, hired_at) values
  (0, 'GENESIS-UNASSIGNED', 1786060800000)
on conflict (serial) do nothing;

-- ---------------------------------------------------------------------------
-- Claiming the crew
-- ---------------------------------------------------------------------------
--
-- Run once, after setting dev_wallet in protocol_config:
--
--   select public.assign_genesis_crew();
--
-- Reads the wallet from config rather than taking it as an argument, so there is
-- no way to assign the crew to an address that is not the configured one.
create or replace function public.assign_genesis_crew()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target text;
  moved integer;
begin
  select dev_wallet into target from public.protocol_config where id = 1;

  if target is null or length(trim(target)) = 0 then
    raise exception 'dev_wallet is not set in protocol_config — set it first';
  end if;

  update public.genesis_crew set owner = target where owner <> target;
  get diagnostics moved = row_count;
  return moved;
end;
$$;

revoke all on function public.assign_genesis_crew() from anon, authenticated;


-- =========================================================================
-- SECTION 11 of 16 — 20260806090600_mint_control.sql
-- =========================================================================

-- xNFTs index — minting: the rate limit, the reservation, and the serial dealer.
--
-- ===========================================================================
-- THE THREAT
-- ===========================================================================
-- Rarity is positional and the supply is 5,000. At a low market cap, 10,000
-- $xNFT is cheap, so the attack is not clever: buy a pile of supply, mint in a
-- tight loop, and take the low serials before anybody else can get to them.
-- X-RATED is 150 units. A script that can mint once a second empties the rare
-- half of the reveal order in under an hour, and every honest buyer afterwards is
-- drawing from a pool somebody else has already picked over.
--
-- ===========================================================================
-- WHY THE LIMIT LIVES HERE AND NOWHERE ELSE
-- ===========================================================================
-- A client-side limit is not a limit. The mint transaction is a plain SPL
-- transfer that any wallet can build without this application's help, and the
-- Edge Function is reachable with a public anon key. The only party that sees
-- every request is Postgres, so the only place a limit can be enforced is
-- Postgres.
--
-- ===========================================================================
-- THE RULE THAT MAKES IT REAL, AND IT IS NOT THE OBVIOUS ONE
-- ===========================================================================
-- The limit is consumed when a serial is RESERVED, not when a burn is indexed.
--
-- That ordering is the whole design. A limit checked at ingest time is checked
-- after the tokens are already gone, so it cannot prevent anything — it can only
-- decide whether to hand over an xployee for a burn that already happened, which
-- is a refund problem rather than a rate limit. Worse, an attacker who does not
-- care about a pleasant experience simply skips the reservation and burns fifty
-- times in a row.
--
-- So both doors are closed, and they are closed with the same policy:
--
--   1. `reserve_mint` takes the rate limit and deals the serial BEFORE the buyer
--      burns anything. This is the limit. It is atomic, it is enforced by
--      constraints as well as by locks, and a refusal costs the caller nothing.
--   2. `record_mint` verifies the burn on chain and redeems that reservation. A
--      burn arriving with NO live reservation is dealt a serial only if the
--      policy would have allowed a reservation at that instant. Otherwise the
--      mint is still recorded — the tokens are gone and the chain says so, and a
--      backend that silently forgot a real burn would be stealing — but it is
--      recorded as `held`, with no serial, for the operator to resolve.
--
-- "Burn first, ask later" therefore buys an attacker nothing except burnt tokens
-- and a support ticket.
--
-- ===========================================================================
-- WHAT IS ACTUALLY ATOMIC, AND WHY EACH LAYER IS THERE
-- ===========================================================================
-- Not one check-then-insert anywhere. Five independent mechanisms, so that a bug
-- in any one of them still leaves the invariant standing:
--
--   1. `pg_advisory_xact_lock(MINT_GATE)` — one mint transaction at a time,
--      cluster-wide. Held to commit by the transaction that took it, so every
--      window count below is exact rather than a snapshot two callers can both
--      read as 99. The cost is that mints serialise; at a total supply of 5,000
--      that is not a cost worth optimising away for correctness.
--   2. `mint_reservations_one_live_per_wallet` — a partial UNIQUE index. Even
--      with the lock removed entirely, one wallet cannot hold two live
--      reservations. This is the constraint the brief asks for: not a check
--      somebody performs, a shape the data cannot take.
--   3. `mint_reservations_one_holder_per_position` / `_per_serial` — a serial can
--      be held by at most one reservation that still counts. Released positions
--      return to the pool and may legitimately appear again in a later row, which
--      is exactly why these are partial rather than plain uniques.
--   4. `for update skip locked` on the reveal pool — two concurrent dealers take
--      two different positions instead of racing for one. Redundant while the
--      gate lock is held; deliberately kept, because the day someone decides the
--      gate is too coarse, this is what stops the removal being a disaster.
--   5. `reveal_order.serial UNIQUE` — the permutation itself cannot contain a
--      duplicate, so "two mints received the same serial" is unrepresentable at
--      the storage layer no matter what every function above does.
--
-- ===========================================================================
-- CONFIGURABLE WITHOUT A CODE CHANGE
-- ===========================================================================
-- Every threshold is a column on `public.mint_policy`, a one-row table. An
-- operator changes a limit with an UPDATE from the dashboard; no deploy, no
-- migration, no function body edited. `paused` stops minting outright, which is
-- the control you want at 3am when something is going wrong and you do not yet
-- know what.
--
-- ===========================================================================
-- WHAT THIS DOES NOT DO
-- ===========================================================================
-- It does not stop a Sybil. Wallets are free, so a per-wallet cap is a cost
-- multiplier rather than a wall, and anyone claiming otherwise about a system
-- with no identity layer is selling something. What the GLOBAL cap does is bound
-- the RATE at which the collection can drain regardless of how many wallets are
-- involved — which converts "the rare serials were gone before anyone noticed"
-- into "the rare serials are draining and the operator has hours to respond".
-- That is the honest claim, and it is the one the numbers below are chosen for.

-- ---------------------------------------------------------------------------
-- The gate key
-- ---------------------------------------------------------------------------

-- An arbitrary but fixed advisory-lock key. A literal rather than
-- `hashtext('...')` so the value cannot change with a Postgres version or a
-- collation: every session must compute the same number or the mutex is not one.
create or replace function public.mint_gate_key()
returns bigint
language sql
immutable
parallel safe
set search_path = ''
as $$ select 7745110001::bigint $$;

comment on function public.mint_gate_key() is
  'Advisory lock key serialising the mint path. Any session taking it must use pg_advisory_xact_lock so it is released at commit or rollback — never pg_advisory_lock, which would survive a failed transaction and wedge minting until the connection died.';

-- ---------------------------------------------------------------------------
-- mint_policy — one row, every threshold
-- ---------------------------------------------------------------------------

create table public.mint_policy (
  -- Singleton by construction: a boolean primary key that must be true admits
  -- exactly one row, so there is no "which policy is in force" question to get
  -- wrong and no `where id = 1` to forget.
  id boolean primary key default true check (id),

  -- The kill switch. Checked first, before any counting, so it is also the
  -- fastest path through this file.
  paused       boolean not null default false,
  pause_reason text,

  -- Per wallet: the shortest gap between two reservations. Blunt, and blunt is
  -- the point — it turns a tight loop into a queue whatever else is true.
  wallet_cooldown_seconds integer not null default 90
    check (wallet_cooldown_seconds >= 0 and wallet_cooldown_seconds <= 86400),

  -- Per wallet: a rolling window and how many reservations fit in it. The window
  -- restarts from the first reservation in it rather than sliding continuously —
  -- cheaper, and the difference only ever favours the wallet.
  wallet_window_seconds integer not null default 86400 check (wallet_window_seconds > 0),
  wallet_window_limit   integer not null default 10    check (wallet_window_limit > 0),

  -- Across ALL wallets. This is the one that bounds the drain rate, and it is a
  -- true sliding window: every reservation created in the last
  -- `global_window_seconds` counts, whoever made it and whether or not they went
  -- on to burn. Abandoning a reservation therefore does not refund its budget,
  -- which is what stops reserve-and-drop being free.
  global_window_seconds integer not null default 3600 check (global_window_seconds > 0),
  global_window_limit   integer not null default 120  check (global_window_limit > 0),

  -- How long a reservation holds its serial before the position returns to the
  -- pool. Long enough to sign, send and confirm a Solana transaction several
  -- times over; short enough that an abandoned reservation is not a serial
  -- withdrawn from circulation for the afternoon.
  reservation_ttl_seconds integer not null default 900
    check (reservation_ttl_seconds >= 60 and reservation_ttl_seconds <= 3600),

  updated_at timestamptz not null default now(),
  -- Free text. Who changed it and why, for the operator's own benefit — nothing
  -- reads this.
  updated_note text
);

comment on table public.mint_policy is
  'Every mint threshold, in one row, changeable with an UPDATE. The defaults bound the drain rate at 120 serials/hour across the whole protocol and 10/day per wallet, with a 90-second floor between two reservations from one wallet.';
comment on column public.mint_policy.global_window_limit is
  'The number that actually protects the low serials. 120/hour against a 5,000 supply means the rarest 150 cannot be swept before an operator has had time to notice and pause.';
comment on column public.mint_policy.paused is
  'Refuses every new reservation immediately. Does NOT refuse an already-reserved burn — a buyer who has paid still gets their xployee, because pausing the mint must never become a way to take somebody''s tokens.';

insert into public.mint_policy (id) values (true);

-- ---------------------------------------------------------------------------
-- mint_rate_limits — the per-wallet counters
-- ---------------------------------------------------------------------------

create table public.mint_rate_limits (
  wallet public.base58_address primary key,

  -- The cooldown anchor. Set when a reservation is granted, not when a burn is
  -- indexed: the reservation is the scarce thing.
  last_reserved_at timestamptz,
  last_minted_at   timestamptz,

  -- The rolling window, as a start plus a count. Reset lazily on the next
  -- reservation rather than by a sweep, so there is no scheduled job whose
  -- failure quietly lifts the limit.
  window_started_at timestamptz not null default now(),
  window_count      integer not null default 0 check (window_count >= 0),

  lifetime_reservations integer not null default 0 check (lifetime_reservations >= 0),
  lifetime_mints        integer not null default 0 check (lifetime_mints >= 0),
  -- How often this wallet has been turned away. Not used by any decision; it is
  -- what tells an operator the difference between a busy day and somebody
  -- hammering the endpoint.
  refusals              integer not null default 0 check (refusals >= 0),

  first_seen_at timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.mint_rate_limits is
  'Per-wallet mint budget. Read and written only under the advisory gate lock plus a FOR UPDATE row lock, so two simultaneous reservations from one wallet cannot both see the same count.';

-- ---------------------------------------------------------------------------
-- mint_reservations — a held serial
-- ---------------------------------------------------------------------------

create table public.mint_reservations (
  id            uuid primary key default gen_random_uuid(),
  wallet        public.base58_address not null,
  draw_position integer not null references public.reveal_order (draw_position) on delete restrict,
  serial        integer not null,

  --   live     — holding its serial, waiting for a burn.
  --   redeemed — a verified burn arrived and the serial was assigned.
  --   expired  — the TTL passed with no burn; the position went back to the pool.
  --   released — given up deliberately (an operator, or a client that cancelled).
  status text not null default 'live'
    check (status in ('live', 'redeemed', 'expired', 'released')),

  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  redeemed_at timestamptz,
  -- The signature of the burn that redeemed it. Unique, so one transaction cannot
  -- redeem two reservations.
  mint_signature public.tx_signature unique,

  constraint mint_reservations_expiry_after_creation check (expires_at > created_at),
  -- A redeemed reservation names the transaction that redeemed it; anything else
  -- names none. Without this, `status` and `mint_signature` could disagree and a
  -- reader would have to guess which one meant it.
  constraint mint_reservations_redeemed_has_evidence check (
    (status = 'redeemed' and mint_signature is not null and redeemed_at is not null)
    or (status <> 'redeemed' and mint_signature is null and redeemed_at is null)
  )
);

-- LAYER 2. One live reservation per wallet, enforced by the index rather than by
-- the function that maintains it. This is what makes "two simultaneous mints
-- cannot both pass" true independently of the lock.
create unique index mint_reservations_one_live_per_wallet
  on public.mint_reservations (wallet) where status = 'live';

-- LAYER 3. A position, and its serial, may be held by at most one reservation
-- that still counts. Partial rather than plain: an expired or released
-- reservation returns its position to the pool, and the next buyer taking that
-- same position is correct behaviour, not a duplicate.
create unique index mint_reservations_one_holder_per_position
  on public.mint_reservations (draw_position) where status in ('live', 'redeemed');
create unique index mint_reservations_one_holder_per_serial
  on public.mint_reservations (serial) where status in ('live', 'redeemed');

create index mint_reservations_window_idx on public.mint_reservations (created_at desc);
create index mint_reservations_wallet_idx on public.mint_reservations (wallet, created_at desc);
create index mint_reservations_expiry_idx on public.mint_reservations (expires_at) where status = 'live';

comment on table public.mint_reservations is
  'A serial held for a wallet that has not burned yet. Creating one is what consumes the rate limit; redeeming one is what a verified burn does. Every reservation ever created counts against the global window whatever became of it, so reserve-and-abandon costs budget rather than refunding it.';

-- ---------------------------------------------------------------------------
-- mints — the columns an assignment needs
-- ---------------------------------------------------------------------------

alter table public.mints
  add column if not exists reservation_id uuid references public.mint_reservations (id) on delete set null,
  -- 'assigned' — a serial was dealt and public.xployees.owner now names the buyer.
  -- 'held'     — the burn is verified and recorded, and no serial was dealt. The
  --              tokens are gone; this row is the buyer's receipt and the
  --              operator's queue.
  add column if not exists assignment_status text not null default 'assigned',
  add column if not exists held_reason text;

alter table public.mints
  add constraint mints_assignment_status_known
    check (assignment_status in ('assigned', 'held'));

-- The two states have to be legible from the row alone. An 'assigned' row with no
-- xployee is a mint that quietly gave nothing; a 'held' row WITH one is a mint
-- that gave something the ledger says it did not.
alter table public.mints
  add constraint mints_assignment_matches_serial check (
    (assignment_status = 'assigned' and xployee_id is not null)
    or (assignment_status = 'held' and xployee_id is null and held_reason is not null)
  );

-- A serial is minted once, ever. The reveal order already guarantees a position
-- is dealt once; this says the same thing from the ledger's side, so the two
-- would have to be broken together to produce a double-mint.
create unique index if not exists mints_serial_minted_once
  on public.mints (xployee_id) where xployee_id is not null;

comment on column public.mints.xployee_id is
  'The serial this burn bought. No longer null in practice: the buyer reserves a serial before burning and record_mint redeems that reservation, so the assignment is a database fact rather than something the transaction had to carry. Null only on a ''held'' row.';
comment on column public.mints.assignment_status is
  'assigned = a serial was dealt. held = the burn is real and recorded but the policy would not deal a serial for it; the operator resolves these by hand. A held row is never silently discarded — the tokens are already burned.';

-- ---------------------------------------------------------------------------
-- release_expired_reservations
-- ---------------------------------------------------------------------------

-- Returns held serials to the pool. Called at the top of every reservation, so
-- the pool is correct at the moment it matters without depending on a scheduled
-- job — a cron that stops running would otherwise leak the collection one
-- abandoned reservation at a time, invisibly.
--
-- Scheduling it as well is still worth doing (see supabase/README.md): it keeps
-- the pool honest during a quiet period, so `reveal_order` read by the mint page
-- does not show serials that are only notionally held.
create or replace function public.release_expired_reservations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_freed integer := 0;
begin
  with dead as (
    update public.mint_reservations r
       set status = 'expired'
     where r.status = 'live'
       and r.expires_at <= now()
    returning r.draw_position
  )
  update public.reveal_order o
     set claimed_by = null,
         claimed_at = null,
         claim_kind = null
    from dead
   where o.draw_position = dead.draw_position
     -- Only a position still held BY a reservation goes back. A position that has
     -- since been minted is not a reservation's to release, and the guard means a
     -- late sweep cannot un-assign a serial somebody already owns.
     and o.claim_kind = 'reserved';

  get diagnostics v_freed = row_count;
  return v_freed;
end;
$$;

-- ---------------------------------------------------------------------------
-- reserve_mint — THE RATE LIMIT
-- ---------------------------------------------------------------------------

-- Returns jsonb rather than raising, because a refusal is an ordinary outcome
-- that the UI has to render as a sentence: "you can mint again in four minutes"
-- is information, not an error. Raising would also roll back the very counter
-- updates a refusal ought to record.
--
--   { ok: true,  reservation: { id, serial, draw_position, expires_at }, pool_remaining }
--   { ok: false, code, message, retry_after_seconds }
--
-- Codes: 'mint-paused', 'cooldown', 'wallet-window', 'global-window', 'sold-out'.
create or replace function public.reserve_mint(p_wallet text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_policy   public.mint_policy;
  v_limits   public.mint_rate_limits;
  v_existing public.mint_reservations;
  v_res      public.mint_reservations;
  v_position integer;
  v_serial   integer;
  v_global   integer;
  v_oldest   timestamptz;
  v_retry    integer;
  v_pool     integer;
begin
  if p_wallet is null or p_wallet !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$' then
    return jsonb_build_object(
      'ok', false, 'code', 'bad-wallet',
      'message', 'That is not a base58 Solana address. Nothing was reserved.'
    );
  end if;

  -- LAYER 1. Everything from here to commit is serialised. Taken before the
  -- policy is read so a concurrent operator UPDATE cannot land between the read
  -- and the decision it informs.
  perform pg_advisory_xact_lock(public.mint_gate_key());

  select * into v_policy from public.mint_policy where id;

  -- Abandoned reservations first: a caller who is about to be told the pool is
  -- empty deserves to be told that about the real pool.
  perform public.release_expired_reservations();

  if v_policy.paused then
    return jsonb_build_object(
      'ok', false, 'code', 'mint-paused',
      'message', coalesce(v_policy.pause_reason, 'Minting is paused. Nothing was reserved and nothing was charged.')
    );
  end if;

  -- An existing live reservation is RETURNED, not refused. A client that lost the
  -- response, refreshed the page, or retried a timeout must get its own serial
  -- back rather than be told it is rate limited by itself. The partial unique
  -- index would refuse the second insert anyway; answering here turns that from a
  -- constraint violation into the correct answer.
  select * into v_existing
    from public.mint_reservations
   where wallet = p_wallet and status = 'live'
   limit 1;
  if found then
    select count(*) into v_pool from public.reveal_order where claimed_at is null;
    return jsonb_build_object(
      'ok', true,
      'reused', true,
      'reservation', jsonb_build_object(
        'id', v_existing.id,
        'serial', v_existing.serial,
        'serial_label', public.serial_label(v_existing.serial),
        'tier', public.tier_for_id(v_existing.serial),
        'draw_position', v_existing.draw_position,
        'expires_at', v_existing.expires_at
      ),
      'pool_remaining', v_pool
    );
  end if;

  -- The per-wallet row. `insert ... on conflict do nothing` then `select ... for
  -- update` rather than a bare select: a wallet minting for the first time has no
  -- row, and two of its requests arriving together would otherwise both find
  -- nothing and both insert.
  insert into public.mint_rate_limits (wallet) values (p_wallet) on conflict (wallet) do nothing;
  select * into v_limits from public.mint_rate_limits where wallet = p_wallet for update;

  -- Cooldown.
  if v_limits.last_reserved_at is not null
     and v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) > now() then
    v_retry := ceil(extract(epoch from (
      v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) - now()
    )))::integer;
    update public.mint_rate_limits set refusals = refusals + 1, updated_at = now() where wallet = p_wallet;
    return jsonb_build_object(
      'ok', false, 'code', 'cooldown',
      'message', format('This wallet reserved a serial less than %s seconds ago. Nothing was reserved.',
                        v_policy.wallet_cooldown_seconds),
      'retry_after_seconds', v_retry
    );
  end if;

  -- Roll the window over if it has aged out. Lazily, so nothing depends on a
  -- sweep having run.
  if v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) <= now() then
    update public.mint_rate_limits
       set window_started_at = now(), window_count = 0, updated_at = now()
     where wallet = p_wallet
    returning * into v_limits;
  end if;

  if v_limits.window_count >= v_policy.wallet_window_limit then
    v_retry := ceil(extract(epoch from (
      v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) - now()
    )))::integer;
    update public.mint_rate_limits set refusals = refusals + 1, updated_at = now() where wallet = p_wallet;
    return jsonb_build_object(
      'ok', false, 'code', 'wallet-window',
      'message', format('This wallet has reserved %s serials in the last %s seconds, which is its limit. Nothing was reserved.',
                        v_limits.window_count, v_policy.wallet_window_seconds),
      'retry_after_seconds', greatest(v_retry, 1)
    );
  end if;

  -- The global window. A true sliding count over every reservation created in it,
  -- whatever became of that reservation — see the table comment for why an
  -- abandoned one still costs budget.
  select count(*), min(created_at) into v_global, v_oldest
    from public.mint_reservations
   where created_at > now() - make_interval(secs => v_policy.global_window_seconds);

  if v_global >= v_policy.global_window_limit then
    v_retry := greatest(1, ceil(extract(epoch from (
      v_oldest + make_interval(secs => v_policy.global_window_seconds) - now()
    )))::integer);
    update public.mint_rate_limits set refusals = refusals + 1, updated_at = now() where wallet = p_wallet;
    return jsonb_build_object(
      'ok', false, 'code', 'global-window',
      'message', format('The protocol has issued %s serials in the last %s seconds, which is the ceiling across all wallets. Nothing was reserved.',
                        v_global, v_policy.global_window_seconds),
      'retry_after_seconds', v_retry
    );
  end if;

  -- LAYER 4. Deal the lowest position still in the pool. `for update skip locked`
  -- inside the subquery so two dealers take two rows; `claimed_at is null` in the
  -- outer predicate as well, so a row that was claimed between the pick and the
  -- write updates nothing rather than overwriting somebody's claim.
  update public.reveal_order o
     set claimed_by = p_wallet,
         claimed_at = now(),
         claim_kind = 'reserved'
   where o.draw_position = (
     select i.draw_position
       from public.reveal_order i
      where i.claimed_at is null
      order by i.draw_position
      limit 1
      for update skip locked
   )
     and o.claimed_at is null
  returning o.draw_position, o.serial into v_position, v_serial;

  if v_position is null then
    return jsonb_build_object(
      'ok', false, 'code', 'sold-out',
      'message', 'Every serial in the collection has been dealt. Nothing was reserved.'
    );
  end if;

  insert into public.mint_reservations (wallet, draw_position, serial, expires_at)
  values (p_wallet, v_position, v_serial, now() + make_interval(secs => v_policy.reservation_ttl_seconds))
  returning * into v_res;

  update public.mint_rate_limits
     set last_reserved_at      = now(),
         window_count          = window_count + 1,
         lifetime_reservations = lifetime_reservations + 1,
         updated_at            = now()
   where wallet = p_wallet;

  select count(*) into v_pool from public.reveal_order where claimed_at is null;

  return jsonb_build_object(
    'ok', true,
    'reused', false,
    'reservation', jsonb_build_object(
      'id', v_res.id,
      'serial', v_res.serial,
      'serial_label', public.serial_label(v_res.serial),
      'tier', public.tier_for_id(v_res.serial),
      'draw_position', v_res.draw_position,
      'expires_at', v_res.expires_at
    ),
    'pool_remaining', v_pool
  );
end;
$$;

comment on function public.reserve_mint(text) is
  'THE rate limit. Takes the wallet''s budget and deals a serial before any burn happens. Returns jsonb — a refusal is an outcome the UI renders, not an exception.';

-- ---------------------------------------------------------------------------
-- release_mint_reservation
-- ---------------------------------------------------------------------------

-- A wallet giving up its own hold. Returns the position to the pool immediately
-- instead of waiting out the TTL — but deliberately does NOT refund the rate
-- limit, because a refund would make reserve/cancel/reserve a free way to reroll
-- a serial until a rare one came up. The reveal order is a lottery, and a lottery
-- you can redraw is not one.
create or replace function public.release_mint_reservation(p_wallet text, p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_position integer;
begin
  perform pg_advisory_xact_lock(public.mint_gate_key());

  update public.mint_reservations r
     set status = 'released'
   where r.id = p_reservation_id
     and r.wallet = p_wallet
     and r.status = 'live'
  returning r.draw_position into v_position;

  if v_position is null then
    return jsonb_build_object(
      'ok', false, 'code', 'not-found',
      'message', 'No live reservation of that id belongs to this wallet. Nothing was changed.'
    );
  end if;

  update public.reveal_order
     set claimed_by = null, claimed_at = null, claim_kind = null
   where draw_position = v_position and claim_kind = 'reserved';

  return jsonb_build_object('ok', true, 'released', v_position);
end;
$$;

-- ---------------------------------------------------------------------------
-- record_mint — the chain-verified write
-- ---------------------------------------------------------------------------

-- Called by `ingest-signature` and by nothing else. Every argument was read out
-- of a transaction that function fetched from RPC itself; none of them came from
-- a browser.
--
-- No `p_fee`. A mint is one transfer to the incinerator and pays nobody — see
-- 20260806090000, which nails `mints.fee` to zero so the absence is enforced
-- rather than assumed.
--
-- THE ORDER OF THE BRANCHES IS THE POLICY:
--
--   1. Already indexed? Return what was decided last time. Idempotent per
--      (signature, event_index) at the primary key, so a replay cannot deal a
--      second serial and cannot flip a held row to assigned.
--   2. A live reservation for this buyer? Redeem it. This is the honest path and
--      the only one that should ever run in practice.
--   3. No reservation, but the policy would allow one right now? Deal a serial
--      and charge the budget for it. Covers the buyer whose reservation expired
--      while their transaction was confirming.
--   4. Otherwise: record the burn as `held`. The tokens are gone and the chain
--      says so — refusing to write the row would be the backend forgetting real
--      money — but no serial is dealt, so "burn first, ask later" cannot outrun
--      the limit.
create or replace function public.record_mint(
  p_signature   text,
  p_event_index integer,
  p_slot        bigint,
  p_block_time  timestamptz,
  p_buyer       text,
  p_burned      text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing  public.mints;
  v_res       public.mint_reservations;
  v_policy    public.mint_policy;
  v_limits    public.mint_rate_limits;
  v_global    integer;
  v_position  integer;
  v_serial    integer;
  v_hired     timestamptz := coalesce(p_block_time, now());
  v_held      text;
begin
  perform pg_advisory_xact_lock(public.mint_gate_key());

  -- 1. Replay.
  select * into v_existing
    from public.mints
   where signature = p_signature and event_index = p_event_index;
  if found then
    return jsonb_build_object(
      'ok', true, 'outcome', 'duplicate',
      'assignment_status', v_existing.assignment_status,
      'xployee_id', v_existing.xployee_id,
      'serial_label', case when v_existing.xployee_id is null then null
                           else public.serial_label(v_existing.xployee_id) end
    );
  end if;

  select * into v_policy from public.mint_policy where id;
  perform public.release_expired_reservations();

  -- 2. Redeem the buyer's own hold. Ordered by expiry so the one closest to
  -- lapsing is settled first; there can only be one live row per wallet, so the
  -- ordering is belt and braces rather than a real choice.
  select * into v_res
    from public.mint_reservations
   where wallet = p_buyer and status = 'live'
   order by expires_at
   limit 1;

  if found then
    v_position := v_res.draw_position;
    v_serial   := v_res.serial;
    update public.mint_reservations
       set status = 'redeemed', redeemed_at = now(), mint_signature = p_signature
     where id = v_res.id;
  else
    -- 3. No hold. Would the policy have granted one at this instant?
    if v_policy.paused then
      v_held := 'Minting was paused when this burn was indexed, and no serial was held for this wallet.';
    else
      insert into public.mint_rate_limits (wallet) values (p_buyer) on conflict (wallet) do nothing;
      select * into v_limits from public.mint_rate_limits where wallet = p_buyer for update;

      if v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) <= now() then
        update public.mint_rate_limits
           set window_started_at = now(), window_count = 0, updated_at = now()
         where wallet = p_buyer
        returning * into v_limits;
      end if;

      select count(*) into v_global
        from public.mint_reservations
       where created_at > now() - make_interval(secs => v_policy.global_window_seconds);

      -- The cooldown is NOT applied here. It exists to stop a loop from forming,
      -- and a burn that has already landed is not a loop that can be stopped —
      -- charging a buyer for being 80 seconds early would take their tokens over
      -- a timing rule that has nothing left to protect. The two window caps ARE
      -- applied, because those are the ceilings that bound the drain.
      if v_limits.window_count >= v_policy.wallet_window_limit then
        v_held := format('This wallet has already taken %s of its %s serials for the current window.',
                         v_limits.window_count, v_policy.wallet_window_limit);
      elsif v_global >= v_policy.global_window_limit then
        v_held := format('The protocol issued %s serials in the last %s seconds, which is the ceiling across all wallets.',
                         v_global, v_policy.global_window_seconds);
      else
        update public.reveal_order o
           set claimed_by = p_buyer, claimed_at = now(), claim_kind = 'reserved'
         where o.draw_position = (
           select i.draw_position from public.reveal_order i
            where i.claimed_at is null
            order by i.draw_position
            limit 1
            for update skip locked
         )
           and o.claimed_at is null
        returning o.draw_position, o.serial into v_position, v_serial;

        if v_position is null then
          v_held := 'Every serial in the collection had been dealt when this burn was indexed.';
        else
          -- Recorded as a reservation redeemed in the same breath, so the audit
          -- trail is the same shape whichever branch produced it and the global
          -- window sees this serial the way it sees every other.
          insert into public.mint_reservations
            (wallet, draw_position, serial, expires_at, status, redeemed_at, mint_signature)
          values
            (p_buyer, v_position, v_serial,
             now() + make_interval(secs => v_policy.reservation_ttl_seconds),
             'redeemed', now(), p_signature)
          returning * into v_res;

          update public.mint_rate_limits
             set last_reserved_at      = now(),
                 window_count          = window_count + 1,
                 lifetime_reservations = lifetime_reservations + 1,
                 updated_at            = now()
           where wallet = p_buyer;
        end if;
      end if;
    end if;
  end if;

  -- 4. Write the mint, whichever way it went.
  if v_serial is null then
    insert into public.mints (
      signature, event_index, buyer, burned, slot, block_time,
      assignment_status, held_reason
    ) values (
      p_signature, p_event_index, p_buyer, p_burned, p_slot, p_block_time,
      'held', coalesce(v_held, 'No serial could be assigned to this burn.')
    );

    insert into public.mint_rate_limits (wallet) values (p_buyer) on conflict (wallet) do nothing;
    update public.mint_rate_limits
       set refusals = refusals + 1, updated_at = now()
     where wallet = p_buyer;

    return jsonb_build_object(
      'ok', true, 'outcome', 'inserted',
      'assignment_status', 'held',
      'held_reason', coalesce(v_held, 'No serial could be assigned to this burn.'),
      'xployee_id', null
    );
  end if;

  update public.reveal_order
     set claim_kind = 'minted', claimed_by = p_buyer
   where draw_position = v_position;

  update public.xployees
     set owner          = p_buyer,
         hired_at       = v_hired,
         mint_signature = p_signature
   where id = v_serial;

  insert into public.mints (
    signature, event_index, buyer, burned, xployee_id, slot, block_time,
    reservation_id, assignment_status
  ) values (
    p_signature, p_event_index, p_buyer, p_burned, v_serial, p_slot, p_block_time,
    v_res.id, 'assigned'
  );

  update public.mint_rate_limits
     set last_minted_at = now(),
         lifetime_mints = lifetime_mints + 1,
         updated_at     = now()
   where wallet = p_buyer;

  return jsonb_build_object(
    'ok', true, 'outcome', 'inserted',
    'assignment_status', 'assigned',
    'xployee_id', v_serial,
    'serial_label', public.serial_label(v_serial),
    'tier', public.tier_for_id(v_serial)
  );
end;
$$;

comment on function public.record_mint(text, integer, bigint, timestamptz, text, text) is
  'The chain-verified mint writer. Every argument comes from a transaction ingest-signature fetched itself. Idempotent per (signature, event_index); never discards a real burn, and never deals a serial the policy would have refused.';

-- ---------------------------------------------------------------------------
-- mint_availability — what the mint page needs to say
-- ---------------------------------------------------------------------------

-- Read-only. Answers "can this wallet mint, and if not, when?" without taking
-- any budget, so a page can poll it.
create or replace function public.mint_availability(p_wallet text default null)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_policy public.mint_policy;
  v_limits public.mint_rate_limits;
  v_res    public.mint_reservations;
  v_pool   integer;
  v_global integer;
  v_wait   integer := 0;
  v_code   text := 'ready';
begin
  select * into v_policy from public.mint_policy where id;
  select count(*) into v_pool from public.reveal_order where claimed_at is null;
  select count(*) into v_global
    from public.mint_reservations
   where created_at > now() - make_interval(secs => v_policy.global_window_seconds);

  if v_policy.paused then
    v_code := 'mint-paused';
  elsif v_pool = 0 then
    v_code := 'sold-out';
  elsif v_global >= v_policy.global_window_limit then
    v_code := 'global-window';
  end if;

  if p_wallet is not null then
    select * into v_limits from public.mint_rate_limits where wallet = p_wallet;
    select * into v_res
      from public.mint_reservations
     where wallet = p_wallet and status = 'live' and expires_at > now()
     limit 1;

    if v_code = 'ready' and v_limits.wallet is not null then
      if v_limits.last_reserved_at is not null
         and v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) > now() then
        v_code := 'cooldown';
        v_wait := ceil(extract(epoch from (
          v_limits.last_reserved_at + make_interval(secs => v_policy.wallet_cooldown_seconds) - now())))::integer;
      elsif v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) > now()
        and v_limits.window_count >= v_policy.wallet_window_limit then
        v_code := 'wallet-window';
        v_wait := ceil(extract(epoch from (
          v_limits.window_started_at + make_interval(secs => v_policy.wallet_window_seconds) - now())))::integer;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'code', v_code,
    'paused', v_policy.paused,
    'pool_remaining', v_pool,
    'supply', public.max_supply(),
    'retry_after_seconds', greatest(v_wait, 0),
    'global_window_seconds', v_policy.global_window_seconds,
    'global_window_limit', v_policy.global_window_limit,
    'global_window_used', v_global,
    'wallet_window_seconds', v_policy.wallet_window_seconds,
    'wallet_window_limit', v_policy.wallet_window_limit,
    'wallet_window_used', coalesce(v_limits.window_count, 0),
    'wallet_cooldown_seconds', v_policy.wallet_cooldown_seconds,
    'reservation', case when v_res.id is null then null else jsonb_build_object(
      'id', v_res.id,
      'serial', v_res.serial,
      'serial_label', public.serial_label(v_res.serial),
      'tier', public.tier_for_id(v_res.serial),
      'expires_at', v_res.expires_at
    ) end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

-- Same rule as 20260805120100: PostgREST resolves /rpc/<fn> through the caller's
-- role, so revoking EXECUTE from anon is what stops the public key calling a
-- writer directly. `mint_availability` is read-only and would be harmless in anon
-- hands — it is still closed, because "harmless today" is how a read function
-- acquires a write branch six months later, and the Edge Function that needs it
-- already has the service role.
revoke all on function public.mint_gate_key() from public, anon, authenticated;
revoke all on function public.release_expired_reservations() from public, anon, authenticated;
revoke all on function public.reserve_mint(text) from public, anon, authenticated;
revoke all on function public.release_mint_reservation(text, uuid) from public, anon, authenticated;
revoke all on function public.record_mint(text, integer, bigint, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.mint_availability(text) from public, anon, authenticated;

-- `stamp_xployee_identity` is deliberately NOT revoked. It is a trigger function
-- and nothing can call it directly — a trigger has no argument list to invoke —
-- while revoking EXECUTE from PUBLIC on a trigger function is a known way to
-- produce "permission denied for function" from an ordinary write. Closing a door
-- that does not exist at the cost of one that does is a bad trade.

grant execute on function public.release_expired_reservations() to service_role;
grant execute on function public.reserve_mint(text) to service_role;
grant execute on function public.release_mint_reservation(text, uuid) to service_role;
grant execute on function public.record_mint(text, integer, bigint, timestamptz, text, text) to service_role;
grant execute on function public.mint_availability(text) to service_role;

-- The pure helpers stay callable by everyone: they read nothing, write nothing,
-- and a policy or a generated column that calls them has to be able to.
grant execute on function public.max_supply() to public;
grant execute on function public.tier_for_id(bigint) to public;
grant execute on function public.skills_for_tier(text) to public;
grant execute on function public.serial_label(bigint) to public;


-- =========================================================================
-- SECTION 12 of 16 — 20260806090700_identity.sql
-- =========================================================================

-- xNFTs index — identity: profiles, verified X handles, and wallet linking.
--
-- ===========================================================================
-- THE ONE RULE
-- ===========================================================================
-- An X handle is stored ONLY when it came out of a verified OAuth identity.
-- There is no code path that accepts a typed one, and that is enforced three
-- ways rather than asserted once:
--
--   1. `set_profile` — the writer a user's own edits go through — HAS NO
--      TWITTER PARAMETER. Not an ignored one, not a validated one: the argument
--      list does not contain a place to put a handle. A caller that wants to set
--      one has nothing to send it in, and a future contributor who adds one has
--      to change a function signature, which is a visible act.
--   2. `link_twitter_identity` takes an `auth.users` id and reads the handle out
--      of `auth.identities` itself. The handle is a value GoTrue wrote after
--      completing the OAuth exchange with X; nothing the browser sends reaches
--      that column.
--   3. `profiles_twitter_is_verified` — a check constraint making a handle
--      without a provider id, a verification timestamp AND an auth user
--      unrepresentable. Even a service-role INSERT cannot write a bare handle.
--
-- ===========================================================================
-- LINKING PROVES BOTH SIDES
-- ===========================================================================
-- A link is a claim about two things at once — "this X account and this Solana
-- wallet are the same person" — so one proof is not enough. Proving only the X
-- side lets anyone attach a stranger's wallet to their own account and inherit
-- its collection on every leaderboard. Proving only the wallet side lets anyone
-- attach a stranger's X handle to their own wallet and impersonate them.
--
--   X side      — a Supabase Auth session carrying a `twitter` identity. GoTrue
--                 completed the OAuth exchange; the browser cannot fabricate it.
--   Wallet side — an ed25519 signature, made by the wallet's own key, over a
--                 nonce THIS SERVER issued. Not a nonce the client chose: a
--                 client-chosen nonce is a signature an attacker can have
--                 collected somewhere else and replayed.
--
-- Both are consumed in one call. `complete_wallet_link` is reachable only by the
-- service role, and it is called only after `link-wallet` has verified the
-- signature — the same trust shape as `record_mint`, which the database also
-- takes on faith from a function that did the checking. The database's job is to
-- make the *result* unforgeable and unrepeatable; the Edge Function's job is to
-- do the cryptography. Neither can cover for the other.
--
-- ===========================================================================
-- WHY IDENTITY IS NEEDED AT ALL
-- ===========================================================================
-- Every social and marketplace writer after this migration has to answer "who is
-- acting?" without believing a request body. `public.actor_wallet(uid)` is that
-- answer: it resolves a session to the wallet that PROVED it owns that session,
-- so no writer ever takes a wallet address as a parameter from a caller. That is
-- the same discipline as "destinations read from configuration, never caller
-- parameters", applied to identity instead of to money.

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table public.profiles (
  wallet public.base58_address primary key,

  -- Display name. User-typed and deliberately so — it is a nickname, not a claim
  -- about anything outside this application. Same shape as USERNAME_RE in
  -- src/lib/profile.ts.
  handle text check (handle is null or handle ~ '^[A-Za-z0-9_]{3,20}$'),
  bio    text check (bio is null or length(bio) <= 160),

  -- One of the owner's own xployees, rendered as their avatar. Not a foreign key
  -- with a cascade: an xployee is never deleted, and a sold one should leave a
  -- stale avatar to be corrected rather than a profile that vanished.
  avatar_xployee_id bigint references public.xployees (id) on delete set null,

  -- ---- the verified half ----
  --
  -- All four move together or not at all. `twitter_user_id` is X's numeric id,
  -- which is what actually identifies an account — a handle can be released and
  -- taken by somebody else, and a link keyed on the handle would silently follow
  -- it to the new owner.
  twitter_user_id     text unique,
  twitter_handle      text check (twitter_handle is null or twitter_handle ~ '^[A-Za-z0-9_]{1,15}$'),
  twitter_verified_at timestamptz,
  auth_user_id        uuid unique references auth.users (id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- THE CONSTRAINT THAT MAKES "VERIFIED ONLY" STRUCTURAL. A handle exists if and
  -- only if the provider id, the verification timestamp and the auth user all
  -- exist alongside it. There is no arrangement of columns that spells "handle
  -- somebody typed".
  constraint profiles_twitter_is_verified check (
    (twitter_handle is null and twitter_user_id is null and twitter_verified_at is null)
    or (twitter_handle is not null and twitter_user_id is not null
        and twitter_verified_at is not null and auth_user_id is not null)
  )
);

-- Handles are compared the way people read them. A unique index on lower() rather
-- than a unique column, so 'Deskrunner' cannot be registered next to 'deskrunner'
-- and used to impersonate it.
create unique index profiles_handle_ci_idx on public.profiles (lower(handle)) where handle is not null;
create index profiles_twitter_idx on public.profiles (lower(twitter_handle)) where twitter_handle is not null;

comment on table public.profiles is
  'Per-wallet profile. handle and bio are user-typed; twitter_handle is copied out of a verified OAuth identity by link_twitter_identity and can be written no other way — see profiles_twitter_is_verified.';
comment on column public.profiles.twitter_handle is
  'VERIFIED ONLY. Copied from auth.identities.identity_data after GoTrue completed the OAuth exchange with X. No writer in this schema accepts a handle as an argument.';
comment on column public.profiles.twitter_user_id is
  'X''s numeric account id. The link is keyed on this rather than on the handle, because a handle can be released and re-registered by somebody else and a handle-keyed link would follow it.';

-- ---------------------------------------------------------------------------
-- wallet_identities — the proof, kept
-- ---------------------------------------------------------------------------

-- The evidence behind a link, separate from the profile that displays it. Kept
-- because a link is a security assertion and an assertion with no record of what
-- justified it cannot be audited or revoked with confidence.
create table public.wallet_identities (
  wallet          public.base58_address primary key,
  auth_user_id    uuid not null unique references auth.users (id) on delete cascade,
  provider        text not null default 'twitter' check (provider = 'twitter'),
  twitter_user_id text not null unique,
  twitter_handle  text not null,
  -- The exact nonce that was signed, and the signature over it. Kept so a
  -- disputed link can be re-verified offline from this row alone.
  proof_nonce     text not null unique,
  proof_signature text not null,
  linked_at       timestamptz not null default now()
);

comment on table public.wallet_identities is
  'One wallet to one X account, unique in both directions. Holds the nonce and signature that proved the wallet side, so a link can be re-verified from the row rather than taken on trust.';

-- ---------------------------------------------------------------------------
-- wallet_link_challenges — the nonce
-- ---------------------------------------------------------------------------

-- A nonce is a secret until it is used, so this is the one table in the schema
-- that anon cannot read at all (see 20260806091100). Publishing the statement a
-- wallet is about to sign would not break the scheme by itself — the signature
-- is what matters — but a readable challenge table hands an attacker every
-- in-flight link attempt and the wallet each one is for.
create table public.wallet_link_challenges (
  nonce        text primary key check (length(nonce) between 32 and 128),
  wallet       public.base58_address not null,
  auth_user_id uuid not null references auth.users (id) on delete cascade,
  -- The exact text the wallet signs. Stored rather than recomputed so
  -- verification compares against the bytes that were actually issued — a
  -- statement rebuilt at verification time from a template is a statement that
  -- can be rebuilt differently.
  statement    text not null,
  issued_at    timestamptz not null default now(),
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  constraint wallet_link_challenges_expiry check (expires_at > issued_at)
);

create index wallet_link_challenges_user_idx on public.wallet_link_challenges (auth_user_id, issued_at desc);
create index wallet_link_challenges_sweep_idx on public.wallet_link_challenges (expires_at) where consumed_at is null;

comment on table public.wallet_link_challenges is
  'Server-issued nonces for wallet proof-of-ownership. Single use: consumed_at is set inside the same transaction that writes the link, so a replayed signature finds a spent challenge.';

-- ---------------------------------------------------------------------------
-- wallets.twitter — closed
-- ---------------------------------------------------------------------------

-- `public.wallets` predates this migration and carries a free-text `twitter`
-- column that any writer could once have filled in with anything. It is now a
-- mirror of the verified handle and nothing else, enforced by a trigger because a
-- check constraint cannot look at another table.
--
-- The column is kept rather than dropped for the same reason `mints.fee` was:
-- `src/lib/supabase.ts` maps it, and a dropped column changes the shape
-- PostgREST returns. What changes is that it can no longer hold a claim.
create or replace function public.guard_wallet_twitter()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.twitter is not null and not exists (
    select 1 from public.profiles p
     where p.wallet = new.address
       and p.twitter_handle = new.twitter
       and p.twitter_verified_at is not null
  ) then
    raise exception 'wallets.twitter mirrors a verified X handle from public.profiles; it cannot be set to a value nobody proved';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger wallets_twitter_must_be_verified
  before insert or update on public.wallets
  for each row execute function public.guard_wallet_twitter();

comment on column public.wallets.twitter is
  'A MIRROR of profiles.twitter_handle, maintained by link_twitter_identity. The wallets_twitter_must_be_verified trigger refuses any value that is not a verified handle already on the matching profile.';

-- ---------------------------------------------------------------------------
-- actor_wallet — who is acting
-- ---------------------------------------------------------------------------

-- The single answer to "which wallet is this session?" Every writer in the
-- migrations after this one calls it and none of them takes a wallet address as
-- a parameter, so there is no writer a caller can point at somebody else's
-- holdings.
--
-- Returns null rather than raising when the session has no linked wallet: an
-- unlinked user is an ordinary state (they signed in with X and have not proved a
-- wallet yet), and the callers turn it into a typed refusal with a sentence
-- attached.
create or replace function public.actor_wallet(p_user_id uuid)
returns text
language sql
security definer
stable
set search_path = ''
as $$
  select wallet from public.wallet_identities where auth_user_id = p_user_id
$$;

comment on function public.actor_wallet(uuid) is
  'Resolves an auth session to the wallet that proved it owns that session. The only sanctioned way for a writer to learn who is acting — never take a wallet from a request body.';

-- ---------------------------------------------------------------------------
-- set_profile — the user-typed half
-- ---------------------------------------------------------------------------

-- NOTE THE ARGUMENT LIST. There is no twitter parameter and there must never be
-- one. Adding it is the single change that would break the guarantee at the top
-- of this file, so it is called out here where anyone editing the signature will
-- read it.
--
-- The wallet is resolved from the session, not passed. An avatar has to be an
-- xployee the wallet actually owns, checked here rather than in the client,
-- because "show me as somebody else's X-RATED" is exactly the kind of harmless
-- little lie that a leaderboard makes not harmless.
create or replace function public.set_profile(
  p_user_id uuid,
  p_handle  text,
  p_bio     text,
  p_avatar_xployee_id bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
  v_handle text := nullif(btrim(coalesce(p_handle, '')), '');
  v_bio    text := nullif(btrim(coalesce(p_bio, '')), '');
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object(
      'ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Prove the wallet first; nothing was saved.'
    );
  end if;

  if v_handle is not null and v_handle !~ '^[A-Za-z0-9_]{3,20}$' then
    return jsonb_build_object(
      'ok', false, 'code', 'bad-handle',
      'message', 'A handle is 3–20 characters: letters, numbers or underscore. Nothing was saved.'
    );
  end if;
  if v_bio is not null and length(v_bio) > 160 then
    return jsonb_build_object(
      'ok', false, 'code', 'bad-bio',
      'message', 'A bio is 160 characters or fewer. Nothing was saved.'
    );
  end if;

  if p_avatar_xployee_id is not null and not exists (
    select 1 from public.xployees x where x.id = p_avatar_xployee_id and x.owner = v_wallet
  ) then
    return jsonb_build_object(
      'ok', false, 'code', 'avatar-not-owned',
      'message', 'An avatar has to be an xployee this wallet owns. Nothing was saved.'
    );
  end if;

  if v_handle is not null and exists (
    select 1 from public.profiles p
     where lower(p.handle) = lower(v_handle) and p.wallet <> v_wallet
  ) then
    return jsonb_build_object(
      'ok', false, 'code', 'handle-taken',
      'message', 'That handle belongs to another wallet. Nothing was saved.'
    );
  end if;

  insert into public.profiles (wallet, handle, bio, avatar_xployee_id)
  values (v_wallet, v_handle, v_bio, p_avatar_xployee_id)
  on conflict (wallet) do update
     set handle            = excluded.handle,
         bio               = excluded.bio,
         avatar_xployee_id = excluded.avatar_xployee_id,
         updated_at        = now();

  -- Mirror into public.wallets, which is what src/lib/supabase.ts reads today.
  -- One transaction, so the two cannot end up describing different people.
  insert into public.wallets (address, handle, bio)
  values (v_wallet, v_handle, v_bio)
  on conflict (address) do update
     set handle = excluded.handle,
         bio    = excluded.bio;

  return jsonb_build_object('ok', true, 'wallet', v_wallet, 'handle', v_handle);
end;
$$;

-- ---------------------------------------------------------------------------
-- Wallet linking
-- ---------------------------------------------------------------------------

-- Step one: issue the nonce.
--
-- The nonce comes from the Edge Function's CSPRNG rather than from
-- `gen_random_uuid()` here, so that the value the wallet signs and the value the
-- verifier compares against travel together through one piece of code. The TTL is
-- short — a challenge is a thing you answer in the next minute, and a long-lived
-- one is a signature an attacker has longer to obtain by other means.
create or replace function public.issue_wallet_link_challenge(
  p_user_id     uuid,
  p_wallet      text,
  p_nonce       text,
  p_statement   text,
  p_ttl_seconds integer default 300
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_wallet is null or p_wallet !~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$' then
    return jsonb_build_object('ok', false, 'code', 'bad-wallet',
      'message', 'That is not a base58 Solana address. No challenge was issued.');
  end if;

  -- A wallet already linked to somebody else is refused before a challenge is
  -- even issued, so the failure is a sentence rather than a signature the user
  -- made for nothing.
  if exists (
    select 1 from public.wallet_identities w
     where w.wallet = p_wallet and w.auth_user_id <> p_user_id
  ) then
    return jsonb_build_object('ok', false, 'code', 'wallet-linked',
      'message', 'That wallet is already linked to a different X account. No challenge was issued.');
  end if;

  -- Older open challenges for this session are burned. A user who started a link
  -- twice should not leave a spare valid nonce lying around behind them.
  update public.wallet_link_challenges
     set consumed_at = now()
   where auth_user_id = p_user_id and consumed_at is null;

  insert into public.wallet_link_challenges (nonce, wallet, auth_user_id, statement, expires_at)
  values (p_nonce, p_wallet, p_user_id, p_statement,
          now() + make_interval(secs => greatest(60, least(p_ttl_seconds, 900))));

  return jsonb_build_object('ok', true, 'nonce', p_nonce, 'statement', p_statement);
end;
$$;

-- The handle GoTrue recorded for this session, read from `auth.identities`.
--
-- Exists so that the statement a wallet is asked to sign names the SAME handle
-- the link will record. `link-wallet` could read the handle out of its own copy
-- of the session instead, and the two would agree almost always — "almost" being
-- the problem: a user who changed their X handle between signing in and linking
-- would sign a statement naming one handle and have another written down, and the
-- stored proof would no longer match the text it was made over.
create or replace function public.twitter_handle_for_user(p_user_id uuid)
returns text
language sql
security definer
stable
set search_path = ''
as $$
  select i.identity_data->>'user_name'
    from auth.identities i
   where i.user_id = p_user_id and i.provider = 'twitter'
   limit 1
$$;

-- The exact bytes that were issued, for a challenge that is still answerable.
--
-- Returns null for a challenge that does not exist, belongs to another session,
-- has expired, or has been spent — one answer for all four, because telling a
-- caller WHICH of those is telling them how far off they were.
--
-- Read-only. It does not consume the challenge; `complete_wallet_link` does that
-- in the same transaction as the write, which is what makes a replay impossible
-- rather than merely unlikely.
create or replace function public.wallet_link_challenge_statement(p_user_id uuid, p_nonce text)
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
  select jsonb_build_object('statement', c.statement, 'wallet', c.wallet, 'expires_at', c.expires_at)
    from public.wallet_link_challenges c
   where c.nonce = p_nonce
     and c.auth_user_id = p_user_id
     and c.consumed_at is null
     and c.expires_at > now()
$$;

-- Step two: record the link.
--
-- Called ONLY after `link-wallet` has verified the ed25519 signature against the
-- wallet's own public key. This function does not and cannot check the
-- cryptography — Postgres has no ed25519 primitive here — and pretending
-- otherwise would be worse than saying so. What it does guarantee, and what the
-- Edge Function cannot:
--
--   * the challenge existed, was issued to THIS user for THIS wallet, and has not
--     expired or been used;
--   * it is consumed in the same transaction as the link, so a replayed signature
--     finds it spent;
--   * the X handle is read from `auth.identities`, never from an argument;
--   * one wallet to one account in both directions, by unique constraints.
create or replace function public.complete_wallet_link(
  p_user_id   uuid,
  p_wallet    text,
  p_nonce     text,
  p_signature text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_challenge public.wallet_link_challenges;
  v_handle    text;
  v_provider  text;
begin
  select * into v_challenge
    from public.wallet_link_challenges
   where nonce = p_nonce
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'no-challenge',
      'message', 'That challenge does not exist. Nothing was linked.');
  end if;
  if v_challenge.consumed_at is not null then
    return jsonb_build_object('ok', false, 'code', 'challenge-spent',
      'message', 'That challenge has already been used. Ask for a new one; nothing was linked.');
  end if;
  if v_challenge.expires_at <= now() then
    return jsonb_build_object('ok', false, 'code', 'challenge-expired',
      'message', 'That challenge expired. Ask for a new one; nothing was linked.');
  end if;
  -- The challenge names the user and the wallet. A signature is only proof of the
  -- pair it was issued for.
  if v_challenge.auth_user_id <> p_user_id or v_challenge.wallet <> p_wallet then
    return jsonb_build_object('ok', false, 'code', 'challenge-mismatch',
      'message', 'That challenge was issued for a different session or a different wallet. Nothing was linked.');
  end if;

  -- The X side, read from GoTrue's own record of the OAuth exchange. `user_name`
  -- is where the Twitter provider puts the handle; `sub` is the numeric account
  -- id, which is the stable half — a handle can be released and re-registered by
  -- somebody else, and a link keyed on it would follow it to the new owner.
  --
  -- Read out of `identity_data` rather than off the `provider_id` COLUMN, and the
  -- difference is availability rather than preference: `auth.identities.provider_id`
  -- was added to GoTrue partway through its life, so a query naming it fails at
  -- PARSE time on an older project — which would make this whole migration
  -- unpushable rather than making one link fail. `identity_data->>'sub'` has been
  -- populated by every version, and a jsonb key that is absent is a null this
  -- function already handles.
  select i.identity_data->>'user_name',
         coalesce(i.identity_data->>'sub', i.identity_data->>'provider_id')
    into v_handle, v_provider
    from auth.identities i
   where i.user_id = p_user_id and i.provider = 'twitter'
   limit 1;

  if v_handle is null or v_provider is null then
    return jsonb_build_object('ok', false, 'code', 'no-twitter-identity',
      'message', 'This session has no verified X identity, so there is no handle to link. Nothing was written.');
  end if;

  update public.wallet_link_challenges set consumed_at = now() where nonce = p_nonce;

  insert into public.wallet_identities
    (wallet, auth_user_id, twitter_user_id, twitter_handle, proof_nonce, proof_signature)
  values
    (p_wallet, p_user_id, v_provider, v_handle, p_nonce, p_signature)
  on conflict (wallet) do update
     set auth_user_id    = excluded.auth_user_id,
         twitter_user_id = excluded.twitter_user_id,
         twitter_handle  = excluded.twitter_handle,
         proof_nonce     = excluded.proof_nonce,
         proof_signature = excluded.proof_signature,
         linked_at       = now();

  insert into public.profiles (wallet, twitter_user_id, twitter_handle, twitter_verified_at, auth_user_id)
  values (p_wallet, v_provider, v_handle, now(), p_user_id)
  on conflict (wallet) do update
     set twitter_user_id     = excluded.twitter_user_id,
         twitter_handle      = excluded.twitter_handle,
         twitter_verified_at = excluded.twitter_verified_at,
         auth_user_id        = excluded.auth_user_id,
         updated_at          = now();

  -- The mirror. Its trigger re-reads public.profiles, so this only succeeds
  -- because the row above was written first — the guard is checking the write
  -- that just happened rather than the argument that asked for it.
  insert into public.wallets (address, twitter) values (p_wallet, v_handle)
  on conflict (address) do update set twitter = excluded.twitter;

  return jsonb_build_object('ok', true, 'wallet', p_wallet, 'twitter_handle', v_handle);
end;
$$;

-- Unlinking. Drops the proof and the verified columns together — a profile
-- keeping a handle whose proof has been withdrawn is exactly the unverified claim
-- this file exists to make unrepresentable.
create or replace function public.unlink_wallet(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  delete from public.wallet_identities where auth_user_id = p_user_id;

  update public.profiles
     set twitter_user_id = null, twitter_handle = null, twitter_verified_at = null,
         auth_user_id = null, updated_at = now()
   where wallet = v_wallet;

  update public.wallets set twitter = null where address = v_wallet;

  return jsonb_build_object('ok', true, 'wallet', v_wallet);
end;
$$;

-- Housekeeping for the nonce table. Nothing depends on it having run — an expired
-- challenge is refused by `complete_wallet_link` whether or not it has been swept
-- — so this is disk hygiene rather than a security control, and it is written to
-- say so.
create or replace function public.purge_wallet_link_challenges()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gone integer;
begin
  delete from public.wallet_link_challenges
   where expires_at < now() - interval '7 days';
  get diagnostics v_gone = row_count;
  return v_gone;
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.actor_wallet(uuid) from public, anon, authenticated;
revoke all on function public.set_profile(uuid, text, text, bigint) from public, anon, authenticated;
revoke all on function public.issue_wallet_link_challenge(uuid, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.complete_wallet_link(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.unlink_wallet(uuid) from public, anon, authenticated;
revoke all on function public.purge_wallet_link_challenges() from public, anon, authenticated;
revoke all on function public.twitter_handle_for_user(uuid) from public, anon, authenticated;
revoke all on function public.wallet_link_challenge_statement(uuid, text) from public, anon, authenticated;
-- `guard_wallet_twitter` is deliberately NOT revoked, for the reason given in
-- 20260806090600 about `stamp_xployee_identity`: it is a trigger function with no
-- argument list to invoke, and revoking EXECUTE from PUBLIC on one is a known way
-- to turn an ordinary write into "permission denied for function".

grant execute on function public.twitter_handle_for_user(uuid) to service_role;
grant execute on function public.wallet_link_challenge_statement(uuid, text) to service_role;
grant execute on function public.actor_wallet(uuid) to service_role;
grant execute on function public.set_profile(uuid, text, text, bigint) to service_role;
grant execute on function public.issue_wallet_link_challenge(uuid, text, text, text, integer) to service_role;
grant execute on function public.complete_wallet_link(uuid, text, text, text) to service_role;
grant execute on function public.unlink_wallet(uuid) to service_role;
grant execute on function public.purge_wallet_link_challenges() to service_role;


-- =========================================================================
-- SECTION 13 of 16 — 20260806090800_market_and_epochs.sql
-- =========================================================================

-- xNFTs index — the simulated marketplace and the epoch ledger.
--
-- ===========================================================================
-- EVERYTHING IN THIS FILE IS SIMULATED, AND IT IS STILL ENFORCED
-- ===========================================================================
-- Sales and rentals move no tokens. There is no escrow program, so an atomic
-- swap would need both parties to co-sign one transaction and nothing arranges
-- that — a sale is a row in `public.trades` and a rental is a row in
-- `public.rentals`, exactly as 20260805120000 says.
--
-- Simulated does NOT mean unchecked, and the distinction is the whole point of
-- this migration. A simulated ledger has no chain reading to contradict it, so a
-- wrong row here is wrong forever and there is nothing to reconcile it against.
-- That makes the invariants MORE important than on the chain-backed tables, not
-- less:
--
--   * a seller must own what they list, at the moment they list it;
--   * a buyer cannot buy their own listing, and cannot buy one that has already
--     closed — checked under a row lock, so two simultaneous buyers cannot both
--     win;
--   * ownership moves in the same transaction as the trade row, so a sale that
--     records money without moving the asset is unreachable;
--   * a rented xployee cannot be re-rented until its contract ends.
--
-- ===========================================================================
-- THE FEE LEDGERS ARE SEPARATE, DELIBERATELY
-- ===========================================================================
-- `public.fee_ledger` is reconciled against a treasury token account anyone can
-- read on chain, and 20260806090000 narrowed it further so that only rentals
-- with a real transfer behind them can enter it. A simulated marketplace fee has
-- no deposit behind it, so it goes to `public.sim_fee_ledger` instead. Two
-- tables rather than one table with a flag, because the flag is exactly the
-- thing a `sum(amount)` written in a hurry forgets — and the resulting number
-- would be a treasury balance overstated by every sale the theatre ever staged.
--
-- ===========================================================================
-- WHO IS ACTING
-- ===========================================================================
-- Every writer takes an `auth.users` id and resolves the wallet through
-- `public.actor_wallet`. None of them takes a wallet address, so there is no
-- writer that can be pointed at somebody else's holdings.

-- ---------------------------------------------------------------------------
-- Rates
-- ---------------------------------------------------------------------------

-- Mirrors SIM_SALE_FEE_BPS and SIM_RENT_FEE_BPS in src/lib/fees.ts. Named SIM_
-- there and `sim_` here for the same reason: the mint has no fee at all, and a
-- constant that merely reads as "the protocol fee" is how a retired charge gets
-- threaded back into the one action that is real.
--
-- Floor division, matching `feeOn()` exactly: both operands are non-negative, so
-- truncation toward zero IS floor, and the payer is never overcharged by a unit.
create or replace function public.sim_sale_fee_bps() returns integer
language sql immutable parallel safe set search_path = '' as $$ select 500 $$;

create or replace function public.sim_rent_fee_bps() returns integer
language sql immutable parallel safe set search_path = '' as $$ select 1000 $$;

create or replace function public.sim_fee_on(p_gross numeric, p_bps integer)
returns numeric
language sql
immutable
parallel safe
strict
set search_path = ''
as $$ select trunc(p_gross * p_bps / 10000) $$;

comment on function public.sim_fee_on(numeric, integer) is
  'The simulated marketplace fee on a gross amount in raw units, floored. Matches feeOn() in src/lib/fees.ts — same division, same direction, so a quote on screen and the row written here cannot disagree about a rounding unit.';

-- ---------------------------------------------------------------------------
-- listings — the write path 20260805120000 said did not exist yet
-- ---------------------------------------------------------------------------

alter table public.listings
  -- The rate in force when the listing was made. Snapshotted rather than read at
  -- settlement, so changing the marketplace rate cannot silently reprice an
  -- advertisement somebody is already looking at.
  add column if not exists fee_bps integer,
  add column if not exists cancelled_at timestamptz,
  add column if not exists closed_by public.base58_address;

alter table public.listings
  add constraint listings_fee_bps_sane check (fee_bps is null or (fee_bps >= 0 and fee_bps <= 2000));

comment on column public.listings.nft_mint is
  'The xployee''s art_seed — what src/lib/xployee.ts calls `Xployee.mint` and src/lib/market.ts keys a listing by. A deterministic pseudo-address, NOT a token mint: there is no NFT on Solana, and nothing may derive an account from this.';
comment on column public.listings.fee_bps is
  'The simulated fee rate this listing was made under. Snapshotted so a rate change cannot reprice a live advertisement.';

create index if not exists listings_active_idx on public.listings (kind, updated_at desc) where status = 'active';

-- ---------------------------------------------------------------------------
-- rentals — the table the chain could not fill
-- ---------------------------------------------------------------------------

-- 20260805120000 declined to create this, and its reasoning was right for the
-- case it was about: a chain-verified rental is two token transfers, and two
-- transfers cannot say for how many epochs, so a `rentals` table written from
-- ingestion would need a `term_epochs` column nothing could fill.
--
-- A SIMULATED rental is a different object. The term is not recovered from
-- anywhere — it is stated by the contract the renter accepted, which is a row in
-- `public.listings` this database wrote itself. There is nothing to reconstruct
-- and nothing to guess.
--
-- The chain-backed path is unchanged: `record_rent` still writes a fee row and
-- still declines to invent a term. If a rental is ever settled on chain it lands
-- in `fee_ledger` with `origin = 'chain'`, and these rows stay what they say they
-- are.
create table public.rentals (
  id           uuid primary key default gen_random_uuid(),
  xployee_id   bigint not null references public.xployees (id) on delete restrict,
  owner        public.base58_address not null,
  renter       public.base58_address not null,

  -- Money in raw units as digit strings, for the reason the u64_text domain
  -- exists: PostgREST serialises numeric as a JSON number and a raw u64 loses its
  -- low digits on the way to a browser.
  fee_per_epoch public.u64_text not null,
  term_epochs   integer not null check (term_epochs > 0 and term_epochs <= 365),
  gross         public.u64_text not null,
  fee           public.u64_text not null,
  total         public.u64_text not null,
  fee_bps       integer not null check (fee_bps >= 0 and fee_bps <= 2000),

  -- Protocol epochs, from public.protocol_epoch(). Half-open: the contract covers
  -- [start_epoch, end_epoch).
  start_epoch integer not null check (start_epoch >= 0),
  end_epoch   integer not null check (end_epoch > start_epoch),

  status text not null default 'active' check (status in ('active', 'completed', 'cancelled')),
  origin public.row_origin not null default 'simulated',

  created_at   timestamptz not null default now(),
  ended_at     timestamptz,

  constraint rentals_term_matches_epochs check (end_epoch - start_epoch = term_epochs),
  -- The renter is not the owner. A self-rental would move no value and would
  -- redirect the epoch yield to the wallet that was already receiving it.
  constraint rentals_parties_differ check (renter <> owner),
  constraint rentals_settled_has_timestamp check (
    (status = 'active' and ended_at is null) or (status <> 'active' and ended_at is not null)
  ),
  -- Simulated rows carry no signature, and a row claiming 'chain' would have to
  -- have come from somewhere this writer cannot reach.
  constraint rentals_are_simulated check (origin = 'simulated')
);

-- One live contract per xployee. A constraint, not a check the writer performs:
-- two renters holding one worker would both be credited its epoch yield, and the
-- ledger would pay out twice for one desk.
create unique index rentals_one_active_per_xployee
  on public.rentals (xployee_id) where status = 'active';

create index rentals_renter_idx on public.rentals (renter, created_at desc);
create index rentals_owner_idx  on public.rentals (owner, created_at desc);
create index rentals_window_idx on public.rentals (start_epoch, end_epoch) where status = 'active';

comment on table public.rentals is
  'SIMULATED rental contracts. The xployee never moves; what moves is who is credited its epoch yield for the term. The term is stated by the listing this database wrote, not recovered from a transaction — which is why this table can exist for simulated rentals and could not for chain-verified ones.';

-- ---------------------------------------------------------------------------
-- sim_fee_ledger — the theatre's own revenue line
-- ---------------------------------------------------------------------------

create table public.sim_fee_ledger (
  id        uuid primary key default gen_random_uuid(),
  source    text not null check (source in ('sale', 'rent')),
  -- What the fee was charged against, so a row can be traced to the thing that
  -- produced it. Exactly one is set.
  trade_id  uuid references public.trades (id) on delete cascade,
  rental_id uuid references public.rentals (id) on delete cascade,
  payer     public.base58_address not null,
  amount    public.u64_text not null,
  fee_bps   integer not null check (fee_bps >= 0 and fee_bps <= 2000),
  origin    public.row_origin not null default 'simulated' check (origin = 'simulated'),
  charged_at timestamptz not null default now(),
  constraint sim_fee_ledger_has_one_source check (
    (source = 'sale' and trade_id is not null and rental_id is null)
    or (source = 'rent' and rental_id is not null and trade_id is null)
  )
);

create index sim_fee_ledger_charged_idx on public.sim_fee_ledger (charged_at desc);
create index sim_fee_ledger_source_idx  on public.sim_fee_ledger (source, charged_at desc);

comment on table public.sim_fee_ledger is
  'SIMULATED marketplace fees. Never summed with public.fee_ledger: that one is reconciled against a treasury token account, and every row here describes money that did not move. Two tables rather than one with a flag, because the flag is what a hurried sum() forgets.';

-- ---------------------------------------------------------------------------
-- Epochs
-- ---------------------------------------------------------------------------

-- Genesis and epoch length, matching src/lib/accrual.ts: GENESIS is
-- Date.UTC(2026, 0, 6) and an epoch is 24 hours. Fixed so epoch numbering is the
-- same on every machine and in the database.
create or replace function public.protocol_genesis()
returns timestamptz
language sql immutable parallel safe set search_path = ''
as $$ select timestamptz '2026-01-06 00:00:00+00' $$;

create or replace function public.protocol_epoch(p_at timestamptz default now())
returns integer
language sql
stable
parallel safe
set search_path = ''
as $$
  select greatest(0, floor(extract(epoch from (p_at - public.protocol_genesis())) / 86400))::integer
$$;

create or replace function public.epoch_start(p_epoch integer)
returns timestamptz
language sql immutable parallel safe strict set search_path = ''
as $$ select public.protocol_genesis() + make_interval(days => p_epoch) $$;

comment on function public.protocol_epoch(timestamptz) is
  'The protocol epoch containing a timestamp. Mirrors epochAt() in src/lib/accrual.ts: 24-hour epochs from 2026-01-06T00:00:00Z, floored at 0.';

-- Per-epoch aggregates. Written by settle_epoch, one row per epoch, never
-- rewritten: a settled epoch is history, and history that can be recomputed under
-- you is not a ledger.
create table public.epochs (
  epoch      integer primary key check (epoch >= 0),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  -- How many workers were on the books when this epoch settled.
  workers            integer not null default 0 check (workers >= 0),
  principal_usd      numeric(20, 2) not null default 0 check (principal_usd >= 0),
  yield_usd          numeric(20, 6) not null default 0 check (yield_usd >= 0),
  settled_at timestamptz not null default now(),
  constraint epochs_span check (ends_at = starts_at + interval '1 day')
);

comment on table public.epochs is
  'One row per settled epoch. Append-only: settle_epoch refuses to rewrite an epoch it has already closed, because a book value that can be recomputed retroactively is not a book value.';

-- The per-worker line items behind each epoch row.
--
-- `credited_to` is the renter while a contract is live and the owner otherwise —
-- that redirection IS what renting an xployee buys, and recording it per epoch is
-- what makes a contract auditable after it ends. The owner is kept alongside so a
-- reader can see the redirection rather than infer it.
create table public.epoch_yields (
  epoch       integer not null references public.epochs (epoch) on delete cascade,
  xployee_id  bigint  not null references public.xployees (id) on delete cascade,
  owner       public.base58_address not null,
  credited_to public.base58_address not null,
  rental_id   uuid references public.rentals (id) on delete set null,
  yield_usd   numeric(20, 6) not null check (yield_usd >= 0),
  primary key (epoch, xployee_id)
);

create index epoch_yields_credited_idx on public.epoch_yields (credited_to, epoch desc);
create index epoch_yields_owner_idx on public.epoch_yields (owner, epoch desc);

comment on table public.epoch_yields is
  'Per-worker, per-epoch accrual. credited_to is the renter during a live contract and the owner otherwise — the redirection is the whole product of a rental, so it is recorded rather than derived later from a contract that may have ended.';

-- ---------------------------------------------------------------------------
-- settle_epoch
-- ---------------------------------------------------------------------------

-- Closes one epoch. Idempotent by the primary key on public.epochs: re-running it
-- returns 'already-settled' and changes nothing, so a cron that fires twice, or a
-- backfill overlapping a live schedule, cannot double-credit a wallet.
--
-- Refuses to settle an epoch that has not finished. A partial epoch settled early
-- would be a full epoch's credit for part of one, and the correction would have
-- to rewrite a row this table does not allow to be rewritten.
--
-- Yield is `principal x apy / 365`, matching yieldPerEpoch() in src/lib/accrual.ts,
-- in exact decimal arithmetic. No float touches it.
create or replace function public.settle_epoch(p_epoch integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_rows  integer;
begin
  if p_epoch is null or p_epoch < 0 then
    return jsonb_build_object('ok', false, 'code', 'bad-epoch', 'message', 'Epochs start at 0.');
  end if;

  v_start := public.epoch_start(p_epoch);
  if v_start + interval '1 day' > now() then
    return jsonb_build_object(
      'ok', false, 'code', 'epoch-open',
      'message', format('Epoch %s has not finished. Nothing was settled.', p_epoch)
    );
  end if;

  if exists (select 1 from public.epochs where epoch = p_epoch) then
    return jsonb_build_object('ok', true, 'outcome', 'already-settled', 'epoch', p_epoch);
  end if;

  insert into public.epochs (epoch, starts_at, ends_at)
  values (p_epoch, v_start, v_start + interval '1 day');

  -- Only workers that were already hired when the epoch STARTED accrue for it. A
  -- worker hired midway through would otherwise be credited a full epoch for a
  -- few hours, which is the one direction this ledger must not err in.
  insert into public.epoch_yields (epoch, xployee_id, owner, credited_to, rental_id, yield_usd)
  select
    p_epoch,
    x.id,
    x.owner,
    coalesce(r.renter, x.owner),
    r.id,
    round(x.principal * x.apy / 365, 6)
  from public.xployees x
  left join public.rentals r
    on r.xployee_id = x.id
   and r.status = 'active'
   and p_epoch >= r.start_epoch
   and p_epoch <  r.end_epoch
  where x.owner is not null
    and x.hired_at is not null
    and x.hired_at <= v_start;

  get diagnostics v_rows = row_count;

  update public.epochs e
     set workers       = agg.workers,
         principal_usd = agg.principal,
         yield_usd     = agg.yield
    from (
      select count(*)                as workers,
             coalesce(sum(x.principal), 0) as principal,
             coalesce(sum(y.yield_usd), 0) as yield
        from public.epoch_yields y
        join public.xployees x on x.id = y.xployee_id
       where y.epoch = p_epoch
    ) agg
   where e.epoch = p_epoch;

  -- Contracts that ran out during this epoch are closed here rather than by a
  -- separate sweep, so "the term ended" and "the yield stopped being redirected"
  -- are the same event.
  update public.rentals
     set status = 'completed', ended_at = now()
   where status = 'active' and end_epoch <= p_epoch + 1;

  return jsonb_build_object('ok', true, 'outcome', 'settled', 'epoch', p_epoch, 'workers', v_rows);
end;
$$;

-- Settles every finished epoch that has not been closed yet, oldest first, up to
-- a bound. The bound exists because a project that has been idle for a month
-- would otherwise try to settle thirty epochs x five thousand workers in one
-- statement timeout.
create or replace function public.settle_due_epochs(p_max integer default 7)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current integer := public.protocol_epoch();
  v_done    integer := 0;
  v_epoch   integer;
  v_last    integer;
begin
  select coalesce(max(epoch), -1) into v_last from public.epochs;
  v_epoch := v_last + 1;

  while v_epoch < v_current and v_done < greatest(1, least(p_max, 60)) loop
    perform public.settle_epoch(v_epoch);
    v_done  := v_done + 1;
    v_epoch := v_epoch + 1;
  end loop;

  return jsonb_build_object('ok', true, 'settled', v_done, 'through_epoch', v_epoch - 1, 'current_epoch', v_current);
end;
$$;

-- ---------------------------------------------------------------------------
-- record_simulated_sale — repaired
-- ---------------------------------------------------------------------------

-- 20260805120100 defined this with an UPSERT on public.xployees, so a sale of a
-- serial the index had never seen created it, owned by the buyer. That was the
-- right call when the index was a sparse read model that might not have heard of
-- an xployee yet.
--
-- It is the wrong call now, and the seed is why: all 5,000 exist from
-- 20260806090300, so an id the upsert does not find is not a gap to fill — it is
-- an id outside the collection, and creating it would mint a 5,001st xployee
-- through the sales endpoint. `xployees_within_supply` would refuse the insert,
-- but as an exception from a constraint rather than as a sentence about a sale.
--
-- Two things change. The upsert becomes an UPDATE that raises when it matches
-- nothing, and the seller has to actually own the thing they are selling —
-- because a simulated sale has no chain reading to contradict it, so "seller"
-- being unchecked meant any caller could move any xployee to anyone.
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
  v_owner    text;
  v_trade    uuid;
begin
  if p_buyer = p_seller then
    raise exception 'record_simulated_sale: buyer and seller are the same wallet';
  end if;

  -- The row is locked before it is checked, so a second concurrent sale of the
  -- same xployee waits here and then finds the owner has changed.
  select owner into v_owner from public.xployees where id = p_xployee_id for update;
  if not found then
    raise exception 'record_simulated_sale: xployee % is not in the collection', p_xployee_id;
  end if;
  if v_owner is null or v_owner <> p_seller then
    raise exception 'record_simulated_sale: % does not own xployee %', p_seller, p_xployee_id;
  end if;

  insert into public.trades (sale_ref, xployee_id, nft_mint, buyer, seller, gross, fee, net_to_seller, origin)
  values (p_sale_ref, p_xployee_id, p_nft_mint, p_buyer, p_seller, p_gross, p_fee, p_net_to_seller, 'simulated')
  on conflict (sale_ref) do nothing
  returning id into v_trade;
  v_inserted := found;

  -- Only on a first sighting. Replaying a sale must not move ownership again,
  -- because by then a later sale may have moved it on.
  if v_inserted then
    update public.xployees set owner = p_buyer, updated_at = now() where id = p_xployee_id;

    update public.listings l
       set status = 'sold', updated_at = now(), closed_by = p_buyer
     where l.xployee_id = p_xployee_id and l.status = 'active';

    -- The fee is notional and goes to the SIMULATED ledger. It has never entered
    -- public.fee_ledger and 20260806090000 now makes that structural rather than
    -- conventional.
    if p_fee is not null and p_fee <> '0' then
      insert into public.sim_fee_ledger (source, trade_id, payer, amount, fee_bps)
      values ('sale', v_trade, p_buyer, p_fee, public.sim_sale_fee_bps());
    end if;
  end if;

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Listing writers
-- ---------------------------------------------------------------------------

create or replace function public.create_listing(
  p_user_id       uuid,
  p_xployee_id    bigint,
  p_kind          text,
  p_price         text default null,
  p_fee_per_epoch text default null,
  p_term_epochs   integer default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
  v_mint   text;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was listed.');
  end if;
  if p_kind not in ('sale', 'rent') then
    return jsonb_build_object('ok', false, 'code', 'bad-kind',
      'message', 'A listing is a sale or a rent. Nothing was listed.');
  end if;

  -- Read, not `for update`. `buy_listing` locks the listing and then the xployee;
  -- taking them in the other order here would be a deadlock waiting for two
  -- unlucky requests. Listing is an advertisement — a race between listing and
  -- selling the same worker resolves at the sale, where the lock that matters is.
  select x.art_seed into v_mint
    from public.xployees x
   where x.id = p_xployee_id and x.owner = v_wallet;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not-owned',
      'message', 'This wallet does not own that xployee. Nothing was listed.');
  end if;

  if exists (select 1 from public.listings where xployee_id = p_xployee_id and status = 'active') then
    return jsonb_build_object('ok', false, 'code', 'already-listed',
      'message', 'That xployee is already on the market. Cancel the existing listing first.');
  end if;
  -- A worker under contract is not the seller's to hand over: the renter is
  -- collecting its yield until the term ends.
  if exists (select 1 from public.rentals where xployee_id = p_xployee_id and status = 'active') then
    return jsonb_build_object('ok', false, 'code', 'under-contract',
      'message', 'That xployee is out on a rental contract. It can be listed when the term ends.');
  end if;

  -- The listings table's own listings_priced_by_kind constraint would refuse a
  -- sale with no price, but as an exception rather than as an explanation.
  if p_kind = 'sale' and (p_price is null or p_price !~ '^(0|[1-9][0-9]{0,19})$' or p_price = '0') then
    return jsonb_build_object('ok', false, 'code', 'bad-price',
      'message', 'A sale listing needs a price in raw units, as a decimal string above zero. Nothing was listed.');
  end if;
  if p_kind = 'rent' and (
       p_fee_per_epoch is null or p_fee_per_epoch !~ '^(0|[1-9][0-9]{0,19})$' or p_fee_per_epoch = '0'
       or p_term_epochs is null or p_term_epochs <= 0 or p_term_epochs > 365) then
    return jsonb_build_object('ok', false, 'code', 'bad-terms',
      'message', 'A rent listing needs a per-epoch fee in raw units and a term of 1–365 epochs. Nothing was listed.');
  end if;

  -- The old row for this xployee is replaced rather than accumulated: nft_mint is
  -- the primary key and a previous cancelled listing would collide with it. The
  -- history of a listing is the trade or rental it produced, not a pile of
  -- closed advertisements.
  delete from public.listings where xployee_id = p_xployee_id;

  insert into public.listings (
    nft_mint, xployee_id, seller, kind, price, fee_per_epoch, term_epochs, status, fee_bps
  ) values (
    v_mint, p_xployee_id, v_wallet, p_kind,
    case when p_kind = 'sale' then p_price end,
    case when p_kind = 'rent' then p_fee_per_epoch end,
    case when p_kind = 'rent' then p_term_epochs end,
    'active',
    case when p_kind = 'sale' then public.sim_sale_fee_bps() else public.sim_rent_fee_bps() end
  );

  return jsonb_build_object('ok', true, 'xployee_id', p_xployee_id, 'kind', p_kind, 'nft_mint', v_mint);
end;
$$;

create or replace function public.cancel_listing(p_user_id uuid, p_xployee_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
  v_hit    integer;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  update public.listings
     set status = 'cancelled', cancelled_at = now(), updated_at = now(), closed_by = v_wallet
   where xployee_id = p_xployee_id and seller = v_wallet and status = 'active';
  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'code', 'not-found',
      'message', 'This wallet has no active listing for that xployee. Nothing was changed.');
  end if;
  return jsonb_build_object('ok', true, 'xployee_id', p_xployee_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- buy_listing — the simulated sale, end to end
-- ---------------------------------------------------------------------------

-- The listing row is taken `for update` before anything is decided, so two buyers
-- arriving together serialise: the first closes it, the second finds it closed
-- and is told so. Nothing about that depends on the order PostgREST happened to
-- process the two requests in.
--
-- The price is read off the LISTING, never from the caller. A buyer who could
-- send their own price would be writing the seller's proceeds.
create or replace function public.buy_listing(p_user_id uuid, p_xployee_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_buyer  text;
  v_listing public.listings;
  v_gross  numeric;
  v_fee    numeric;
  v_net    numeric;
  v_ref    text;
begin
  v_buyer := public.actor_wallet(p_user_id);
  if v_buyer is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was bought.');
  end if;

  select * into v_listing
    from public.listings
   where xployee_id = p_xployee_id and kind = 'sale'
   for update;

  if not found or v_listing.status <> 'active' then
    return jsonb_build_object('ok', false, 'code', 'not-listed',
      'message', 'That xployee is not for sale. Nothing was bought.');
  end if;
  if v_listing.seller = v_buyer then
    return jsonb_build_object('ok', false, 'code', 'own-listing',
      'message', 'That is this wallet''s own listing. Nothing was bought.');
  end if;

  -- The seller must still own it.
  --
  -- `record_simulated_sale` checks this too and RAISES if it fails, which is the
  -- right behaviour for a low-level writer and the wrong response for a buyer: an
  -- exception escapes as a 500 with a Postgres string in it, and "the seller sold
  -- it to somebody else a second ago" is an ordinary outcome that deserves a
  -- sentence. Checked here so the common case reads properly; the raise below
  -- stays as the last line of defence, because this check and the ownership
  -- update are not in the same statement.
  if not exists (
    select 1 from public.xployees x where x.id = p_xployee_id and x.owner = v_listing.seller
  ) then
    return jsonb_build_object('ok', false, 'code', 'stale-listing',
      'message', 'That listing was posted by a wallet that no longer owns the xployee. Nothing was bought.');
  end if;

  v_gross := v_listing.price::numeric;
  v_fee   := public.sim_fee_on(v_gross, coalesce(v_listing.fee_bps, public.sim_sale_fee_bps()));
  -- The fee rides ON TOP of the ask, exactly as saleMath() in src/lib/market.ts
  -- quotes it: the seller receives the ask and the buyer is debited ask + fee. So
  -- the seller's net IS the gross, and `net_to_seller` records that rather than
  -- silently deducting a fee the quote never showed.
  v_net   := v_gross;

  -- A deterministic idempotency key. `record_simulated_sale` keys replay
  -- protection on `sale_ref`, and a uuid generated here would make every retry a
  -- second sale; keyed on the listing and the buyer, a retry lands on the row the
  -- first attempt wrote.
  v_ref := 'sale:' || p_xployee_id::text || ':' || v_listing.updated_at::text || ':' || v_buyer;

  perform public.record_simulated_sale(
    v_ref,
    p_xployee_id,
    v_listing.nft_mint,
    v_buyer,
    v_listing.seller,
    trunc(v_gross)::text,
    trunc(v_fee)::text,
    trunc(v_net)::text
  );

  return jsonb_build_object(
    'ok', true,
    'xployee_id', p_xployee_id,
    'seller', v_listing.seller,
    'gross', trunc(v_gross)::text,
    'fee', trunc(v_fee)::text,
    'total', trunc(v_gross + v_fee)::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- rent_listing — the simulated contract
-- ---------------------------------------------------------------------------

create or replace function public.rent_listing(p_user_id uuid, p_xployee_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_renter  text;
  v_listing public.listings;
  v_gross   numeric;
  v_fee     numeric;
  v_start   integer := public.protocol_epoch();
  v_rental  uuid;
begin
  v_renter := public.actor_wallet(p_user_id);
  if v_renter is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was rented.');
  end if;

  select * into v_listing
    from public.listings
   where xployee_id = p_xployee_id and kind = 'rent'
   for update;

  if not found or v_listing.status <> 'active' then
    return jsonb_build_object('ok', false, 'code', 'not-listed',
      'message', 'That xployee is not offered on contract. Nothing was rented.');
  end if;
  if v_listing.seller = v_renter then
    return jsonb_build_object('ok', false, 'code', 'own-listing',
      'message', 'That is this wallet''s own contract. Nothing was rented.');
  end if;
  -- The listing's seller must still be the owner. A stale advertisement left
  -- behind by a previous owner would otherwise let a renter pay the wrong wallet.
  if not exists (
    select 1 from public.xployees x where x.id = p_xployee_id and x.owner = v_listing.seller
  ) then
    return jsonb_build_object('ok', false, 'code', 'stale-listing',
      'message', 'That contract was posted by a wallet that no longer owns the xployee. Nothing was rented.');
  end if;

  v_gross := v_listing.fee_per_epoch::numeric * v_listing.term_epochs;
  v_fee   := public.sim_fee_on(v_gross, coalesce(v_listing.fee_bps, public.sim_rent_fee_bps()));

  insert into public.rentals (
    xployee_id, owner, renter, fee_per_epoch, term_epochs,
    gross, fee, total, fee_bps, start_epoch, end_epoch
  ) values (
    p_xployee_id, v_listing.seller, v_renter, v_listing.fee_per_epoch, v_listing.term_epochs,
    trunc(v_gross)::text, trunc(v_fee)::text, trunc(v_gross + v_fee)::text,
    coalesce(v_listing.fee_bps, public.sim_rent_fee_bps()),
    v_start, v_start + v_listing.term_epochs
  )
  returning id into v_rental;

  insert into public.sim_fee_ledger (source, rental_id, payer, amount, fee_bps)
  values ('rent', v_rental, v_renter, trunc(v_fee)::text, coalesce(v_listing.fee_bps, public.sim_rent_fee_bps()));

  update public.listings
     set status = 'rented', updated_at = now(), closed_by = v_renter
   where xployee_id = p_xployee_id;

  return jsonb_build_object(
    'ok', true,
    'rental_id', v_rental,
    'xployee_id', p_xployee_id,
    'owner', v_listing.seller,
    'term_epochs', v_listing.term_epochs,
    'start_epoch', v_start,
    'end_epoch', v_start + v_listing.term_epochs,
    'gross', trunc(v_gross)::text,
    'fee', trunc(v_fee)::text,
    'total', trunc(v_gross + v_fee)::text
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.settle_epoch(integer) from public, anon, authenticated;
revoke all on function public.settle_due_epochs(integer) from public, anon, authenticated;
revoke all on function public.create_listing(uuid, bigint, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.cancel_listing(uuid, bigint) from public, anon, authenticated;
revoke all on function public.buy_listing(uuid, bigint) from public, anon, authenticated;
revoke all on function public.rent_listing(uuid, bigint) from public, anon, authenticated;
revoke all on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) from public, anon, authenticated;

grant execute on function public.settle_epoch(integer) to service_role;
grant execute on function public.settle_due_epochs(integer) to service_role;
grant execute on function public.create_listing(uuid, bigint, text, text, text, integer) to service_role;
grant execute on function public.cancel_listing(uuid, bigint) to service_role;
grant execute on function public.buy_listing(uuid, bigint) to service_role;
grant execute on function public.rent_listing(uuid, bigint) to service_role;
grant execute on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) to service_role;

-- Pure, read-only, and called by generated columns and by the app alike.
grant execute on function public.protocol_genesis() to public;
grant execute on function public.protocol_epoch(timestamptz) to public;
grant execute on function public.epoch_start(integer) to public;
grant execute on function public.sim_sale_fee_bps() to public;
grant execute on function public.sim_rent_fee_bps() to public;
grant execute on function public.sim_fee_on(numeric, integer) to public;


-- =========================================================================
-- SECTION 14 of 16 — 20260806090900_social.sql
-- =========================================================================

-- xNFTs index — the social layer: friends, threads, messages, trade offers.
--
-- ===========================================================================
-- WHAT THIS REPLACES
-- ===========================================================================
-- `src/lib/social.ts` keeps the whole inbox in one localStorage blob per wallet,
-- with the other half of every conversation simulated from network.ts. That was
-- the right shape for a frontend with no backend, and it has one property this
-- schema has to preserve and one it has to fix.
--
--   Preserve: nothing here throws at the reader. A corrupt row, a missing
--             counterparty, a message from a wallet that no longer exists — all
--             of it degrades to a shorter list, never to a blank page.
--   Fix:      a conversation is between two people. A store only one of them can
--             write is not a conversation, it is a diary. Every table below is
--             two-sided and symmetric by construction.
--
-- ===========================================================================
-- SYMMETRY IS STRUCTURAL, NOT MAINTAINED
-- ===========================================================================
-- `friendships` and `threads` both key on an ORDERED PAIR — `wallet_a < wallet_b`
-- as a check constraint — so there is exactly one row per relationship and A
-- lists B precisely when B lists A. The alternative, two mirrored rows kept in
-- step by a writer, is a pair that drifts the first time one insert fails: one
-- wallet sees a friend, the other sees a stranger, and nothing ever notices.
--
-- `src/lib/social.ts` reaches the same property a different way, by seeding its
-- pair roll on the unordered pair. Same reasoning, and it is worth being explicit
-- that the one-way friendship is a bug both designs were built to make
-- unrepresentable rather than unlikely.
--
-- ===========================================================================
-- A TRADE OFFER MOVES NOTHING
-- ===========================================================================
-- Accepting one records a decision. There is no custody here and no escrow
-- anywhere in this protocol, so an accepted offer does NOT reassign an xployee —
-- and `accept_trade_offer` deliberately does not touch `public.xployees`. Making
-- it move assets would be inventing a settlement layer inside a messaging table,
-- with none of the ownership checks `buy_listing` performs and no way to make the
-- two legs atomic against a counterparty who sold in the meantime.
--
-- The offer legs still name real xployees and are still validated against real
-- ownership at send time, because an offer for units the sender does not hold is
-- a lie whether or not anything settles it.

-- ---------------------------------------------------------------------------
-- friend_requests
-- ---------------------------------------------------------------------------

create table public.friend_requests (
  id           uuid primary key default gen_random_uuid(),
  requester    public.base58_address not null,
  addressee    public.base58_address not null,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  message      text check (message is null or length(message) <= 200),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  constraint friend_requests_two_parties check (requester <> addressee),
  constraint friend_requests_resolved_has_timestamp check (
    (status = 'pending' and responded_at is null) or (status <> 'pending' and responded_at is not null)
  )
);

-- At most one OPEN request per unordered pair, in either direction. `least` and
-- `greatest` collapse the direction, so B cannot answer A's pending request by
-- sending their own and ending up with two rows that disagree about who asked.
create unique index friend_requests_one_open_per_pair
  on public.friend_requests (least(requester, addressee), greatest(requester, addressee))
  where status = 'pending';

create index friend_requests_inbox_idx  on public.friend_requests (addressee, status, created_at desc);
create index friend_requests_outbox_idx on public.friend_requests (requester, status, created_at desc);

comment on table public.friend_requests is
  'Both directions and every status — the audit trail behind public.friendships. A resolved request is history and stays; only pending rows are inbox items.';

-- ---------------------------------------------------------------------------
-- friendships
-- ---------------------------------------------------------------------------

create table public.friendships (
  -- Canonically ordered, so the pair is the key and the relationship has exactly
  -- one row. This is what makes the graph undirected at the storage layer instead
  -- of by convention.
  wallet_a   public.base58_address not null,
  wallet_b   public.base58_address not null,
  since      timestamptz not null default now(),
  -- The request that produced it, when there was one. Null for a friendship
  -- created some other way; a foreign key rather than a copy so the history
  -- cannot say something the request row does not.
  request_id uuid references public.friend_requests (id) on delete set null,
  primary key (wallet_a, wallet_b),
  constraint friendships_are_ordered check (wallet_a < wallet_b)
);

create index friendships_b_idx on public.friendships (wallet_b);

comment on table public.friendships is
  'Undirected. wallet_a < wallet_b is enforced, so one relationship is one row and a one-way friendship — the classic bug where clicking through to the other profile shows a stranger — cannot be written.';

-- Both halves of the graph as one directed view, because every query the app
-- actually writes is "who are MY friends" and expressing that against an ordered
-- pair at each call site is how a `wallet_b` gets forgotten.
create view public.friend_edges with (security_invoker = true) as
  select wallet_a as wallet, wallet_b as friend, since from public.friendships
  union all
  select wallet_b as wallet, wallet_a as friend, since from public.friendships;

comment on view public.friend_edges is
  'public.friendships seen from both sides. Query this rather than remembering to check wallet_a and wallet_b separately.';

-- ---------------------------------------------------------------------------
-- threads and messages
-- ---------------------------------------------------------------------------

create table public.threads (
  id              uuid primary key default gen_random_uuid(),
  participant_a   public.base58_address not null,
  participant_b   public.base58_address not null,
  created_at      timestamptz not null default now(),
  -- Denormalised so an inbox sorts without touching the messages table. Kept
  -- current by the trigger below rather than by every writer.
  last_message_at timestamptz,
  message_count   integer not null default 0 check (message_count >= 0),
  constraint threads_are_ordered check (participant_a < participant_b),
  unique (participant_a, participant_b)
);

create index threads_a_idx on public.threads (participant_a, last_message_at desc nulls last);
create index threads_b_idx on public.threads (participant_b, last_message_at desc nulls last);

comment on table public.threads is
  'Strictly two-party, canonically ordered. One conversation is one row whichever side opened it, so there is no "your copy" and "their copy" to fall out of step.';

create table public.messages (
  id        uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.threads (id) on delete cascade,
  sender    public.base58_address not null,
  -- MESSAGE_MAX in src/lib/social.ts. Long enough for a real pitch, short enough
  -- that one wallet cannot fill the table.
  body      text not null check (length(body) between 1 and 500),
  sent_at   timestamptz not null default now(),
  -- Set when the RECIPIENT reads it. A sender's own message is never unread to
  -- them, so there is no second column and no way for the two to disagree.
  read_at   timestamptz
);

create index messages_thread_idx on public.messages (thread_id, sent_at desc);
create index messages_unread_idx on public.messages (thread_id, sender) where read_at is null;

comment on column public.messages.read_at is
  'When the recipient read it. A thread has exactly two participants and a sender never reads their own message, so one nullable timestamp says everything a per-participant read table would.';

-- The sender has to be in the thread. A cross-table condition, so a trigger
-- rather than a check — and worth having, because the failure it prevents is
-- somebody else's mail appearing inside a conversation.
create or replace function public.guard_message_sender()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_a text;
  v_b text;
begin
  select participant_a, participant_b into v_a, v_b from public.threads where id = new.thread_id;
  if v_a is null then
    raise exception 'message %: no such thread', new.id;
  end if;
  if new.sender <> v_a and new.sender <> v_b then
    raise exception 'message %: sender is not a participant in that thread', new.id;
  end if;
  return new;
end;
$$;

create trigger messages_sender_must_be_a_participant
  before insert on public.messages
  for each row execute function public.guard_message_sender();

-- Keeps the thread's summary honest. In a trigger rather than in `send_message`,
-- so a row inserted by any route — a backfill, a repair, a second writer added
-- later — cannot leave the inbox sorting by a stale timestamp.
create or replace function public.touch_thread()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.threads
     set last_message_at = greatest(coalesce(last_message_at, new.sent_at), new.sent_at),
         message_count   = message_count + 1
   where id = new.thread_id;
  return new;
end;
$$;

create trigger messages_touch_thread
  after insert on public.messages
  for each row execute function public.touch_thread();

-- ---------------------------------------------------------------------------
-- trade_offers and their legs
-- ---------------------------------------------------------------------------

create table public.trade_offers (
  id        uuid primary key default gen_random_uuid(),
  sender    public.base58_address not null,
  recipient public.base58_address not null,
  note      text check (note is null or length(note) <= 500),
  status    text not null default 'pending'
              check (status in ('pending', 'accepted', 'declined', 'withdrawn', 'expired')),

  -- The $xNFT sweetener, in raw units, as TWO non-negative columns rather than
  -- one signed one.
  --
  -- `src/lib/social.ts` carries it as a signed number where negative means "the
  -- sender wants $xNFT back". That is compact and it is exactly the shape that
  -- produces an off-by-a-sign bug in a UI, because the sign has to be read
  -- correctly at every render and every comparison. Two columns make the
  -- direction a fact about which column is populated, and the check makes "both
  -- at once" — which would be two payments cancelling out — unrepresentable.
  sweetener_from_sender    public.u64_text not null default '0',
  sweetener_from_recipient public.u64_text not null default '0',

  created_at   timestamptz not null default now(),
  expires_at   timestamptz,
  responded_at timestamptz,

  constraint trade_offers_two_parties check (sender <> recipient),
  constraint trade_offers_one_direction_of_cash check (
    sweetener_from_sender = '0' or sweetener_from_recipient = '0'
  ),
  constraint trade_offers_resolved_has_timestamp check (
    (status = 'pending' and responded_at is null) or (status <> 'pending' and responded_at is not null)
  )
);

create index trade_offers_inbox_idx  on public.trade_offers (recipient, status, created_at desc);
create index trade_offers_outbox_idx on public.trade_offers (sender, status, created_at desc);
create index trade_offers_open_idx   on public.trade_offers (expires_at) where status = 'pending';

comment on table public.trade_offers is
  'A proposal, not a settlement. Accepting records a decision and moves nothing — there is no escrow anywhere in this protocol, so an offer that reassigned xployees would be a settlement layer hidden inside a messaging table.';

create table public.trade_offer_legs (
  offer_id   uuid   not null references public.trade_offers (id) on delete cascade,
  xployee_id bigint not null references public.xployees (id) on delete cascade,
  -- 'offered'   — the sender is putting this up.
  -- 'requested' — the sender wants it back.
  side       text   not null check (side in ('offered', 'requested')),
  -- (offer, xployee) as the key rather than (offer, side, xployee): the same unit
  -- cannot be on both sides of one trade, and this is what makes that impossible
  -- rather than merely checked by the writer that happens to insert the legs.
  primary key (offer_id, xployee_id)
);

create index trade_offer_legs_xployee_idx on public.trade_offer_legs (xployee_id);

comment on table public.trade_offer_legs is
  'The units on each side of an offer. The primary key is (offer, xployee), so the same worker cannot appear as both offered and requested in one trade.';

-- ---------------------------------------------------------------------------
-- Writers
-- ---------------------------------------------------------------------------

-- Every one resolves the actor through public.actor_wallet and none takes a
-- wallet address, so there is no writer that can be pointed at somebody else's
-- inbox. Each returns jsonb: a refusal here is an ordinary outcome the UI renders
-- as a sentence, not an exception.

-- The canonical pair, so ordering logic is written once.
create or replace function public.pair_key(p_x text, p_y text)
returns text[]
language sql immutable parallel safe strict set search_path = ''
as $$ select case when p_x < p_y then array[p_x, p_y] else array[p_y, p_x] end $$;

create or replace function public.send_friend_request(p_user_id uuid, p_to text, p_message text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from text;
  v_pair text[];
  v_id   uuid;
begin
  v_from := public.actor_wallet(p_user_id);
  if v_from is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was sent.');
  end if;
  if p_to is null or p_to = v_from then
    return jsonb_build_object('ok', false, 'code', 'bad-target',
      'message', 'A friend request needs somebody else to send it to. Nothing was sent.');
  end if;

  v_pair := public.pair_key(v_from, p_to);
  if exists (select 1 from public.friendships where wallet_a = v_pair[1] and wallet_b = v_pair[2]) then
    return jsonb_build_object('ok', false, 'code', 'already-friends',
      'message', 'These wallets are already connected. Nothing was sent.');
  end if;

  -- A pending request in EITHER direction is already an open question, and the
  -- partial unique index would refuse the insert anyway. Answering here turns a
  -- constraint violation into the correct sentence.
  if exists (
    select 1 from public.friend_requests
     where status = 'pending'
       and least(requester, addressee) = v_pair[1]
       and greatest(requester, addressee) = v_pair[2]
  ) then
    return jsonb_build_object('ok', false, 'code', 'already-open',
      'message', 'There is already an open request between these wallets. Nothing was sent.');
  end if;

  insert into public.friend_requests (requester, addressee, message)
  values (v_from, p_to, nullif(btrim(coalesce(p_message, '')), ''))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'request_id', v_id);
end;
$$;

create or replace function public.respond_to_friend_request(
  p_user_id uuid,
  p_request_id uuid,
  p_accept boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   text;
  v_req  public.friend_requests;
  v_pair text[];
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  -- Locked before it is read, so two clicks cannot both accept and produce two
  -- friendship inserts racing on the same primary key.
  select * into v_req from public.friend_requests where id = p_request_id for update;
  if not found or v_req.addressee <> v_me or v_req.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'not-answerable',
      'message', 'That request is not open, or it was not addressed to this wallet. Nothing was changed.');
  end if;

  update public.friend_requests
     set status = case when p_accept then 'accepted' else 'declined' end,
         responded_at = now()
   where id = p_request_id;

  if p_accept then
    v_pair := public.pair_key(v_req.requester, v_req.addressee);
    insert into public.friendships (wallet_a, wallet_b, request_id)
    values (v_pair[1], v_pair[2], p_request_id)
    on conflict (wallet_a, wallet_b) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'accepted', p_accept);
end;
$$;

-- Removing a friend leaves the accepted request behind as history, matching
-- `removeFriend` in src/lib/social.ts — and for the same reason: a later re-add
-- would otherwise be refused as a duplicate of a relationship that no longer
-- exists.
create or replace function public.remove_friend(p_user_id uuid, p_other text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   text;
  v_pair text[];
  v_hit  integer;
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  v_pair := public.pair_key(v_me, p_other);
  delete from public.friendships where wallet_a = v_pair[1] and wallet_b = v_pair[2];
  get diagnostics v_hit = row_count;

  return jsonb_build_object('ok', v_hit > 0, 'removed', v_hit > 0);
end;
$$;

-- Opens the thread if it does not exist yet, then writes the message. One
-- function, because "create a conversation" is not a thing a user does — sending
-- the first message is.
create or replace function public.send_message(p_user_id uuid, p_to text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from   text;
  v_pair   text[];
  v_thread uuid;
  v_body   text := btrim(coalesce(p_body, ''));
  v_id     uuid;
begin
  v_from := public.actor_wallet(p_user_id);
  if v_from is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was sent.');
  end if;
  if p_to is null or p_to = v_from then
    return jsonb_build_object('ok', false, 'code', 'bad-target',
      'message', 'A message needs somebody else to send it to. Nothing was sent.');
  end if;
  if length(v_body) = 0 or length(v_body) > 500 then
    return jsonb_build_object('ok', false, 'code', 'bad-body',
      'message', 'A message is 1–500 characters. Nothing was sent.');
  end if;

  v_pair := public.pair_key(v_from, p_to);

  -- `on conflict do nothing` then select, rather than select then insert: two
  -- first messages arriving together would otherwise both find no thread and both
  -- try to create one.
  insert into public.threads (participant_a, participant_b)
  values (v_pair[1], v_pair[2])
  on conflict (participant_a, participant_b) do nothing;

  select id into v_thread from public.threads
   where participant_a = v_pair[1] and participant_b = v_pair[2];

  insert into public.messages (thread_id, sender, body)
  values (v_thread, v_from, v_body)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'thread_id', v_thread, 'message_id', v_id);
end;
$$;

create or replace function public.mark_thread_read(p_user_id uuid, p_thread_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me  text;
  v_hit integer;
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  -- `sender <> v_me` is what stops a caller marking their OWN messages read,
  -- which would clear the counterparty's unread badge from the wrong side.
  update public.messages m
     set read_at = now()
    from public.threads t
   where m.thread_id = p_thread_id
     and t.id = m.thread_id
     and (t.participant_a = v_me or t.participant_b = v_me)
     and m.sender <> v_me
     and m.read_at is null;
  get diagnostics v_hit = row_count;

  return jsonb_build_object('ok', true, 'marked', v_hit);
end;
$$;

-- ---------------------------------------------------------------------------
-- Trade offers
-- ---------------------------------------------------------------------------

-- The legs are validated against real ownership at send time. An offer for units
-- the sender does not hold, or a request for units the recipient does not hold,
-- is a lie — and it stays a lie whether or not anything ever settles it, so it is
-- refused here rather than left for a UI to notice.
create or replace function public.send_trade_offer(
  p_user_id    uuid,
  p_to         text,
  p_offering   bigint[],
  p_requesting bigint[],
  p_sweetener_from_sender    text default '0',
  p_sweetener_from_recipient text default '0',
  p_note       text default null,
  p_ttl_hours  integer default 168
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from      text;
  v_offer     uuid;
  v_offering  bigint[] := coalesce(p_offering, '{}');
  v_request   bigint[] := coalesce(p_requesting, '{}');
  v_from_cash text := coalesce(nullif(p_sweetener_from_sender, ''), '0');
  v_to_cash   text := coalesce(nullif(p_sweetener_from_recipient, ''), '0');
  v_bad       bigint;
begin
  v_from := public.actor_wallet(p_user_id);
  if v_from is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was offered.');
  end if;
  if p_to is null or p_to = v_from then
    return jsonb_build_object('ok', false, 'code', 'bad-target',
      'message', 'An offer needs a counterparty. Nothing was offered.');
  end if;
  if v_from_cash !~ '^(0|[1-9][0-9]{0,19})$' or v_to_cash !~ '^(0|[1-9][0-9]{0,19})$' then
    return jsonb_build_object('ok', false, 'code', 'bad-sweetener',
      'message', 'A sweetener is raw units as a decimal string. Nothing was offered.');
  end if;
  if v_from_cash <> '0' and v_to_cash <> '0' then
    return jsonb_build_object('ok', false, 'code', 'two-way-cash',
      'message', '$xNFT moves one way in a trade. Set one side to zero; nothing was offered.');
  end if;
  -- An offer that moves nothing in either direction is not an offer.
  if array_length(v_offering, 1) is null and array_length(v_request, 1) is null
     and v_from_cash = '0' and v_to_cash = '0' then
    return jsonb_build_object('ok', false, 'code', 'empty-offer',
      'message', 'That offer moves nothing in either direction. Nothing was offered.');
  end if;
  if coalesce(array_length(v_offering, 1), 0) + coalesce(array_length(v_request, 1), 0) > 20 then
    return jsonb_build_object('ok', false, 'code', 'too-many-legs',
      'message', 'An offer carries at most 20 xployees across both sides. Nothing was offered.');
  end if;

  -- The same unit cannot be on both sides. The legs table's primary key would
  -- refuse the second insert; saying so here is the difference between an
  -- explanation and a constraint violation.
  if exists (select 1 from unnest(v_offering) as t(o) where t.o = any (v_request)) then
    return jsonb_build_object('ok', false, 'code', 'same-unit-both-sides',
      'message', 'An xployee cannot be both offered and requested. Nothing was offered.');
  end if;

  select t.o into v_bad
    from unnest(v_offering) as t(o)
   where not exists (select 1 from public.xployees x where x.id = t.o and x.owner = v_from)
   limit 1;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'code', 'not-owned',
      'message', format('This wallet does not own %s. Nothing was offered.', public.serial_label(v_bad)));
  end if;

  select t.r into v_bad
    from unnest(v_request) as t(r)
   where not exists (select 1 from public.xployees x where x.id = t.r and x.owner = p_to)
   limit 1;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'code', 'not-held-by-counterparty',
      'message', format('That offer asks for %s, which the counterparty does not hold. Nothing was offered.', public.serial_label(v_bad)));
  end if;

  insert into public.trade_offers (
    sender, recipient, note, sweetener_from_sender, sweetener_from_recipient, expires_at
  ) values (
    v_from, p_to, nullif(btrim(coalesce(p_note, '')), ''), v_from_cash, v_to_cash,
    now() + make_interval(hours => greatest(1, least(coalesce(p_ttl_hours, 168), 720)))
  )
  returning id into v_offer;

  insert into public.trade_offer_legs (offer_id, xployee_id, side)
  select v_offer, t.o, 'offered' from unnest(v_offering) as t(o)
  union all
  select v_offer, t.r, 'requested' from unnest(v_request) as t(r);

  return jsonb_build_object('ok', true, 'offer_id', v_offer);
end;
$$;

-- Resolve an offer.
--
-- Accepting RECORDS A DECISION. It moves nothing — see the header. The status is
-- the whole effect, and the two parties settle between themselves through the
-- marketplace, where `buy_listing` does the ownership checks and the locking that
-- a real transfer needs.
create or replace function public.respond_to_trade_offer(
  p_user_id  uuid,
  p_offer_id uuid,
  p_status   text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me    text;
  v_offer public.trade_offers;
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;
  if p_status not in ('accepted', 'declined', 'withdrawn') then
    return jsonb_build_object('ok', false, 'code', 'bad-status',
      'message', 'An offer is accepted, declined or withdrawn. Nothing was changed.');
  end if;

  select * into v_offer from public.trade_offers where id = p_offer_id for update;
  if not found or v_offer.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'not-open',
      'message', 'That offer is not open. Nothing was changed.');
  end if;

  -- You withdraw your own offers and you accept or decline everyone else's.
  -- Getting this backwards would let a sender "accept" their own proposal.
  if p_status = 'withdrawn' then
    if v_offer.sender <> v_me then
      return jsonb_build_object('ok', false, 'code', 'not-yours',
        'message', 'Only the sender can withdraw an offer. Nothing was changed.');
    end if;
  elsif v_offer.recipient <> v_me then
    return jsonb_build_object('ok', false, 'code', 'not-yours',
      'message', 'That offer was not addressed to this wallet. Nothing was changed.');
  end if;

  update public.trade_offers set status = p_status, responded_at = now() where id = p_offer_id;

  return jsonb_build_object(
    'ok', true,
    'status', p_status,
    -- Said in the response so no caller can render an acceptance as a settlement.
    'settled', false,
    'note', 'Accepting records the decision. Nothing changed hands — there is no escrow, so the two wallets settle through the marketplace.'
  );
end;
$$;

-- Offers that ran out. Idempotent and safe to schedule; nothing depends on it
-- having run, because a caller reading a pending offer past its expiry can see
-- the timestamp for itself.
create or replace function public.expire_trade_offers()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gone integer;
begin
  update public.trade_offers
     set status = 'expired', responded_at = now()
   where status = 'pending' and expires_at is not null and expires_at <= now();
  get diagnostics v_gone = row_count;
  return v_gone;
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.send_friend_request(uuid, text, text) from public, anon, authenticated;
revoke all on function public.respond_to_friend_request(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.remove_friend(uuid, text) from public, anon, authenticated;
revoke all on function public.send_message(uuid, text, text) from public, anon, authenticated;
revoke all on function public.mark_thread_read(uuid, uuid) from public, anon, authenticated;
revoke all on function public.send_trade_offer(uuid, text, bigint[], bigint[], text, text, text, integer) from public, anon, authenticated;
revoke all on function public.respond_to_trade_offer(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.expire_trade_offers() from public, anon, authenticated;

grant execute on function public.send_friend_request(uuid, text, text) to service_role;
grant execute on function public.respond_to_friend_request(uuid, uuid, boolean) to service_role;
grant execute on function public.remove_friend(uuid, text) to service_role;
grant execute on function public.send_message(uuid, text, text) to service_role;
grant execute on function public.mark_thread_read(uuid, uuid) to service_role;
grant execute on function public.send_trade_offer(uuid, text, bigint[], bigint[], text, text, text, integer) to service_role;
grant execute on function public.respond_to_trade_offer(uuid, uuid, text) to service_role;
grant execute on function public.expire_trade_offers() to service_role;

grant execute on function public.pair_key(text, text) to public;


-- =========================================================================
-- SECTION 15 of 16 — 20260806091000_payout_requests.sql
-- =========================================================================

-- xNFTs index — payout_requests: the SOL claim queue the admin desk works.
--
-- ===========================================================================
-- THIS IS NOT public.payouts. READ THIS BEFORE USING EITHER.
-- ===========================================================================
-- Two queues exist and they are about different money moving in different
-- directions. Confusing them would let a holder's claim be settled by a
-- transaction that paid the dev wallet, so they are separate tables with
-- separate writers and no shared status vocabulary.
--
--   public.payouts          — the OPERATOR sweeping $xNFT fees out of the
--                             treasury to the dev wallet. One signer, one
--                             destination read from configuration, settled by
--                             `confirm-payout` re-reading the chain. Money
--                             leaving the protocol.
--   public.payout_requests  — a HOLDER asking to be paid their accrued yield, in
--                             SOL, out of pump.fun creator fees. Money arriving
--                             at a user. There is no automated settlement and
--                             there is not going to be one: an operator sends the
--                             SOL by hand from a wallet this backend does not
--                             hold a key for, and then records the signature.
--
-- ===========================================================================
-- WHAT A REQUEST IS AND IS NOT
-- ===========================================================================
-- It is a ticket. `src/lib/earnings.ts` computes the claimable figure from
-- accrual — a pure function of hire time and skills — and mints a human-readable
-- claim id (`XN-A3K7M-9PQR2`, Crockford base32 with I/L/O/U removed so it
-- survives being read down a phone line). The row here is that ticket.
--
-- It is NOT an instruction to a machine. Nothing in this schema can move SOL, no
-- function here signs anything, and `status = 'paid'` is a statement an operator
-- makes about a transfer they performed — recorded with its signature so anybody
-- can go and check it, which is the only kind of verification available when the
-- paying key never comes near this system.
--
-- ===========================================================================
-- THE AMOUNT
-- ===========================================================================
-- Two figures, and the distinction is the same one `public.payouts` draws.
--
--   `amount_usd`      — the USD the requester was shown when they clicked. A
--                       display notional in exact decimal; it gates nothing.
--   `amount_lamports` — the SOL figure, in raw units as a digit string. This is
--                       the money column, and it is a u64_text for the reason the
--                       domain exists: PostgREST serialises numeric as a JSON
--                       number and a lamport figure that has been through a
--                       double is a lamport figure that is wrong.
--   `paid_lamports`   — what actually went out, filled in with the signature.
--                       NULL until then, so "requested" and "paid" can never be
--                       read as the same number.

create table public.payout_requests (
  -- The claim id IS the primary key. It is what a support ticket is resolved by
  -- and what a user reads out loud, so giving the row a uuid alongside it would
  -- create a second identity for the same thing and an opportunity for the two to
  -- be quoted at each other.
  --
  -- The pattern is CLAIM_ID_RE from src/lib/earnings.ts, restated here rather
  -- than assumed: an id generated by some other client still has to look like one
  -- of ours or it cannot enter the queue.
  claim_id text primary key check (claim_id ~ '^XN-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$'),

  wallet public.base58_address not null,

  amount_usd      numeric(20, 2)   not null check (amount_usd > 0),
  amount_lamports public.u64_text  not null,
  -- The rate the quote was made at, so a settled ticket can be read back years
  -- later without wondering what SOL was worth that afternoon. Display only.
  sol_usd_at_request numeric(20, 6) not null check (sol_usd_at_request > 0),

  --   pending   — in the queue, nobody has looked at it.
  --   approved  — an operator has accepted it and intends to pay. Not money yet.
  --   paid      — SOL was sent; the signature is on the row.
  --   rejected  — an operator declined it, with a reason.
  --   cancelled — the requester withdrew it before it was settled.
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'paid', 'rejected', 'cancelled')),

  -- The SOL transfer. Not a foreign key to anything and not verified by this
  -- backend — it is a Solana signature on a transaction sent from a wallet whose
  -- key lives with the operator. Unique, so one transfer cannot be used to settle
  -- two tickets.
  signature     public.tx_signature unique,
  paid_lamports public.u64_text,

  -- Free text from whoever worked the ticket. Visible to the requester, so it is
  -- an explanation rather than an internal note — a rejection with no sentence
  -- attached is how a support queue turns into a grievance.
  operator_note text check (operator_note is null or length(operator_note) <= 500),

  requested_at timestamptz not null default now(),
  reviewed_at  timestamptz,
  paid_at      timestamptz,
  updated_at   timestamptz not null default now(),

  -- 'paid' is reachable only with the evidence. Three columns move together or
  -- the row is refused, which makes "we only mark it paid once it is paid" a
  -- property of the table rather than of the endpoint that writes it.
  constraint payout_requests_paid_has_evidence check (
    (status = 'paid' and signature is not null and paid_lamports is not null and paid_at is not null)
    or (status <> 'paid' and signature is null and paid_lamports is null and paid_at is null)
  ),
  -- A rejection carries its reason. Without this, a declined ticket can sit in
  -- somebody's history with no explanation and no way to get one.
  constraint payout_requests_rejection_has_reason check (
    status <> 'rejected' or operator_note is not null
  ),
  -- Anything an operator has touched says when.
  constraint payout_requests_reviewed_has_timestamp check (
    status in ('pending', 'cancelled') or reviewed_at is not null
  )
);

-- ONE OPEN REQUEST PER WALLET, as a constraint rather than as a check somebody
-- performs. This is the same shape as the mint reservation index and it is doing
-- the same job: two clicks arriving together cannot both open a ticket, so a
-- wallet cannot get its accrued yield queued twice and paid twice by an operator
-- working down a list.
create unique index payout_requests_one_open_per_wallet
  on public.payout_requests (wallet) where status in ('pending', 'approved');

create index payout_requests_queue_idx  on public.payout_requests (status, requested_at asc);
create index payout_requests_wallet_idx on public.payout_requests (wallet, requested_at desc);

comment on table public.payout_requests is
  'Holders asking to be paid their accrued yield in SOL from pump.fun creator fees. A ticket, not an instruction: nothing here can move SOL, and ''paid'' is an operator recording a transfer they made by hand, with its signature.';
comment on column public.payout_requests.claim_id is
  'The id a human reads out. Crockford base32 with I, L, O and U removed so 1/I and 0/O are never both drawable — see CLAIM_ID_RE in src/lib/earnings.ts.';
comment on column public.payout_requests.signature is
  'The SOL transfer an operator sent. This backend does NOT verify it — the paying key never touches this system — so it is published for anyone to check rather than presented as something the server confirmed.';
comment on column public.payout_requests.amount_lamports is
  'The money column, in raw units. amount_usd beside it is a display notional and gates nothing.';

-- ---------------------------------------------------------------------------
-- Operator identity
-- ---------------------------------------------------------------------------

-- Who may work the queue. A table rather than a hard-coded address, so adding or
-- removing an operator is an INSERT and not a deploy — and so the answer to "who
-- could have marked this paid" is a query rather than an archaeology exercise
-- through old builds.
--
-- Seeded EMPTY on purpose, which is the same discipline as every deployment
-- constant in src/lib/spl.ts: with no rows, every operator action refuses. An
-- operator is added deliberately, once, by somebody with database access.
create table public.operators (
  wallet     public.base58_address primary key,
  label      text,
  can_pay    boolean not null default true,
  added_at   timestamptz not null default now(),
  removed_at timestamptz
);

comment on table public.operators is
  'Wallets allowed to work the payout queue. Ships EMPTY, so every operator path refuses until somebody with database access adds a row — the same "unset means disabled" rule the deployment constants follow.';

create or replace function public.is_operator(p_wallet text)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.operators
     where wallet = p_wallet and removed_at is null and can_pay
  )
$$;

-- ---------------------------------------------------------------------------
-- request_payout — the holder's side
-- ---------------------------------------------------------------------------

-- The wallet comes from the session, never from the caller. The claim id and the
-- amount DO come from the client, and that is worth being honest about rather
-- than dressing up: accrual is computed in the browser from a deterministic
-- function of hire time and skills, so the figure a request carries is the
-- browser's arithmetic.
--
-- What the database enforces around it:
--
--   * the requester owns at least one xployee — you cannot claim yield from an
--     empty wallet;
--   * the amount does not exceed what this wallet's holdings could possibly have
--     accrued, recomputed HERE from `principal x apy x tenure` and net of
--     everything already requested. This is the check that matters: it does not
--     trust the client's number, it bounds it;
--   * one open ticket per wallet, by unique index.
--
-- The bound is generous by construction — it ignores rentals redirecting yield,
-- so it can only ever be too permissive rather than too strict, and a holder is
-- never refused money they are owed because of a rounding difference between two
-- languages. An operator still reviews every ticket. That is the actual control,
-- and this function's job is to stop the queue filling with impossible numbers.
create or replace function public.request_payout(
  p_user_id     uuid,
  p_claim_id    text,
  p_amount_usd  numeric,
  p_sol_usd     numeric
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet    text;
  v_accrued   numeric;
  v_requested numeric;
  v_lamports  numeric;
  v_crew      integer;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was requested.');
  end if;
  if p_claim_id is null or p_claim_id !~ '^XN-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$' then
    return jsonb_build_object('ok', false, 'code', 'bad-claim-id',
      'message', 'That is not a claim id. Nothing was requested.');
  end if;
  if p_amount_usd is null or p_amount_usd <= 0 then
    return jsonb_build_object('ok', false, 'code', 'bad-amount',
      'message', 'A request has to be for a positive amount. Nothing was requested.');
  end if;
  if p_sol_usd is null or p_sol_usd <= 0 then
    return jsonb_build_object('ok', false, 'code', 'bad-rate',
      'message', 'A request has to carry the SOL price it was quoted at. Nothing was requested.');
  end if;

  -- Idempotent on the claim id: a retried post finds its own ticket rather than
  -- opening a second one, and the partial unique index would refuse the second
  -- anyway.
  if exists (select 1 from public.payout_requests where claim_id = p_claim_id) then
    return jsonb_build_object('ok', true, 'outcome', 'duplicate', 'claim_id', p_claim_id);
  end if;

  select count(*),
         coalesce(sum(
           x.principal * x.apy
             * greatest(0, extract(epoch from (now() - x.hired_at))) / (86400 * 365)
         ), 0)
    into v_crew, v_accrued
    from public.xployees x
   where x.owner = v_wallet and x.hired_at is not null;

  if v_crew = 0 then
    return jsonb_build_object('ok', false, 'code', 'no-crew',
      'message', 'This wallet holds no xployees, so nothing has accrued to it. Nothing was requested.');
  end if;

  -- Everything already spoken for. A rejected ticket releases its amount back;
  -- anything else — pending, approved or paid — is money this wallet has already
  -- asked for, matching requestedUsd() in src/lib/earnings.ts.
  select coalesce(sum(amount_usd), 0) into v_requested
    from public.payout_requests
   where wallet = v_wallet and status <> 'rejected' and status <> 'cancelled';

  if p_amount_usd > greatest(0, v_accrued - v_requested) + 0.01 then
    return jsonb_build_object(
      'ok', false, 'code', 'over-accrual',
      'message', format(
        'This wallet''s crew has accrued about $%s and $%s of that is already spoken for, so $%s cannot be claimed. Nothing was requested.',
        round(v_accrued, 2), round(v_requested, 2), round(p_amount_usd, 2))
    );
  end if;

  if exists (select 1 from public.payout_requests where wallet = v_wallet and status in ('pending', 'approved')) then
    return jsonb_build_object('ok', false, 'code', 'already-open',
      'message', 'This wallet already has a request in the queue. It has to be settled before another can be opened.');
  end if;

  -- USD to lamports at the quoted rate, floored. Flooring is the deliberate
  -- direction here as everywhere else in this codebase: a request never asks for
  -- a lamport more than the quote supports.
  v_lamports := trunc(p_amount_usd / p_sol_usd * 1000000000);

  insert into public.payout_requests (claim_id, wallet, amount_usd, amount_lamports, sol_usd_at_request)
  values (p_claim_id, v_wallet, round(p_amount_usd, 2), v_lamports::text, p_sol_usd);

  return jsonb_build_object(
    'ok', true, 'outcome', 'queued',
    'claim_id', p_claim_id,
    'amount_usd', round(p_amount_usd, 2),
    'amount_lamports', v_lamports::text
  );
end;
$$;

-- The requester withdrawing their own ticket. Only while it is still open — once
-- an operator has paid it there is a transfer on a ledger somewhere, and a row
-- that says 'cancelled' next to a signature would be a lie about money that moved.
create or replace function public.cancel_payout_request(p_user_id uuid, p_claim_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet text;
  v_hit    integer;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  update public.payout_requests
     set status = 'cancelled', updated_at = now()
   where claim_id = p_claim_id and wallet = v_wallet and status = 'pending';
  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'code', 'not-cancellable',
      'message', 'That claim is not this wallet''s, or it is no longer pending. Nothing was changed.');
  end if;
  return jsonb_build_object('ok', true, 'claim_id', p_claim_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_payout_request — the operator's side
-- ---------------------------------------------------------------------------

-- Approve, reject, or record a payment. The operator is resolved from the session
-- and checked against `public.operators`, so authority is a row in a table rather
-- than a comparison against a constant compiled into a bundle.
--
-- Marking a ticket paid REQUIRES the signature and the lamport figure. Not
-- because this backend can verify them — it cannot, the paying key is not here —
-- but because a settled row without them is unauditable, and an unauditable
-- payout record is worse than none: it is a claim of payment that nobody can
-- check and nobody can disprove.
create or replace function public.resolve_payout_request(
  p_user_id   uuid,
  p_claim_id  text,
  p_status    text,
  p_note      text default null,
  p_signature text default null,
  p_lamports  text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operator text;
  v_row      public.payout_requests;
begin
  v_operator := public.actor_wallet(p_user_id);
  if v_operator is null or not public.is_operator(v_operator) then
    -- One sentence for "not signed in" and "not an operator" alike. Telling an
    -- unauthorised caller which of the two they failed is telling them how to
    -- fix it.
    return jsonb_build_object('ok', false, 'code', 'not-operator',
      'message', 'This session is not an operator of the payout queue. Nothing was changed.');
  end if;
  if p_status not in ('approved', 'rejected', 'paid') then
    return jsonb_build_object('ok', false, 'code', 'bad-status',
      'message', 'An operator approves, rejects or records payment. Nothing was changed.');
  end if;

  select * into v_row from public.payout_requests where claim_id = p_claim_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not-found',
      'message', 'No claim with that id. Nothing was changed.');
  end if;
  -- Settlement is one-way. A paid ticket cannot be re-opened, re-approved or
  -- rejected after the fact — the transfer already happened.
  if v_row.status not in ('pending', 'approved') then
    return jsonb_build_object('ok', false, 'code', 'already-settled',
      'message', format('That claim is already %s. Nothing was changed.', v_row.status));
  end if;

  if p_status = 'rejected' and nullif(btrim(coalesce(p_note, '')), '') is null then
    return jsonb_build_object('ok', false, 'code', 'reason-required',
      'message', 'A rejection needs a reason the requester can read. Nothing was changed.');
  end if;

  if p_status = 'paid' then
    if p_signature is null or p_signature !~ '^[1-9A-HJ-NP-Za-km-z]{64,88}$' then
      return jsonb_build_object('ok', false, 'code', 'signature-required',
        'message', 'Recording a payment needs the signature of the SOL transfer. Nothing was changed.');
    end if;
    if p_lamports is null or p_lamports !~ '^(0|[1-9][0-9]{0,19})$' or p_lamports = '0' then
      return jsonb_build_object('ok', false, 'code', 'amount-required',
        'message', 'Recording a payment needs the lamports actually sent. Nothing was changed.');
    end if;
    if exists (select 1 from public.payout_requests where signature = p_signature and claim_id <> p_claim_id) then
      return jsonb_build_object('ok', false, 'code', 'signature-reused',
        'message', 'That signature already settles another claim. One transfer settles one ticket. Nothing was changed.');
    end if;

    update public.payout_requests
       set status = 'paid',
           signature = p_signature,
           paid_lamports = p_lamports,
           paid_at = now(),
           reviewed_at = coalesce(reviewed_at, now()),
           operator_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), operator_note),
           updated_at = now()
     where claim_id = p_claim_id;
  else
    update public.payout_requests
       set status = p_status,
           reviewed_at = now(),
           operator_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), operator_note),
           updated_at = now()
     where claim_id = p_claim_id;
  end if;

  return jsonb_build_object('ok', true, 'claim_id', p_claim_id, 'status', p_status, 'operator', v_operator);
end;
$$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

-- The admin desk subscribes to this queue, so a ticket opened while the operator
-- is looking at the page appears without a refresh.
--
-- `replica identity full` so an UPDATE payload carries the PREVIOUS row as well
-- as the new one. Without it Postgres publishes only the primary key for the old
-- tuple, and a desk watching for "pending became paid" would have to re-query to
-- find out what a row changed FROM — which is a round trip per event and a race
-- with the next update.
--
-- Note that realtime respects RLS for the anon key: an unauthenticated browser
-- receives these events only because the read policy in 20260806091100 publishes
-- the queue, and every column it can see is one it could already have selected.
alter table public.payout_requests replica identity full;
alter table public.payouts         replica identity full;

do $$
begin
  -- The publication exists on every Supabase project, but this migration should
  -- not fail on a bare Postgres that has never had Realtime enabled.
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.payout_requests;
    alter publication supabase_realtime add table public.payouts;
    alter publication supabase_realtime add table public.mints;
  else
    raise notice 'publication supabase_realtime does not exist; realtime was not configured';
  end if;
exception
  when duplicate_object then
    raise notice 'tables are already in the supabase_realtime publication';
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.is_operator(text) from public, anon, authenticated;
revoke all on function public.request_payout(uuid, text, numeric, numeric) from public, anon, authenticated;
revoke all on function public.cancel_payout_request(uuid, text) from public, anon, authenticated;
revoke all on function public.resolve_payout_request(uuid, text, text, text, text, text) from public, anon, authenticated;

grant execute on function public.is_operator(text) to service_role;
grant execute on function public.request_payout(uuid, text, numeric, numeric) to service_role;
grant execute on function public.cancel_payout_request(uuid, text) to service_role;
grant execute on function public.resolve_payout_request(uuid, text, text, text, text, text) to service_role;


-- =========================================================================
-- SECTION 16 of 16 — 20260806091100_rls_policies.sql
-- =========================================================================

-- xNFTs index — row level security for everything added since 20260805120200.
--
-- The rule from that file is unchanged and this one extends it rather than
-- reopening it:
--
--   THE ANON KEY CAN SELECT PUBLIC DATA AND CAN INSERT, UPDATE OR DELETE
--   NOTHING, ANYWHERE, EVER.
--
-- Three independent layers, exactly as before. GRANT (anon holds SELECT and
-- nothing else, so a client INSERT is refused before RLS is consulted),
-- RESTRICTIVE deny-write policies on every verb of every table (which survive
-- someone later adding a well-meaning permissive one), and writers that are
-- SECURITY DEFINER functions granted only to service_role.
--
-- ===========================================================================
-- WHAT IS NEW: THERE IS NOW A SESSION, SO SOME THINGS CAN BE PRIVATE
-- ===========================================================================
-- 20260805120200 argued — correctly, for what existed then — that a policy
-- depending on a JWT claim this app could not mint was theatre, and made
-- everything public. Supabase Auth with the X provider changes the premise:
-- `authenticated` is now a role a real visitor can actually hold, and
-- `public.current_wallet()` resolves it to the wallet that PROVED it owns that
-- session.
--
-- So the tables that hold correspondence between two people are no longer
-- published to the world. Direct messages, open friend requests and trade offers
-- are readable by their participants and by nobody else. That is not theatre:
-- the lock has a wall beside it, because the only other route to those rows is
-- an Edge Function that resolves the same identity server-side.
--
-- ===========================================================================
-- WHAT STAYS PUBLIC, AND WHY EACH ONE
-- ===========================================================================
--   the collection, the tiers, the skills, the trait vocabulary
--                       — this is the artwork's metadata. Hiding an NFT
--                         collection's attributes would be strange.
--   the reveal order    — it is ALREADY public and nothing here changes that:
--                         `mintOrder()` is a fixed-seed shuffle compiled into the
--                         browser bundle, so anyone can derive the whole
--                         permutation offline. See the note below, because the
--                         consequence deserves stating plainly rather than
--                         hiding behind a policy that would not hide anything.
--   the mint policy     — published limits. A rate limit whose numbers are secret
--                         is a rate limit users experience as random failure.
--   listings, trades, rentals, the simulated fee ledger, the epoch ledger
--                       — the marketplace. All of it is meant to be read.
--   friendships         — profiles render friend lists; the graph is the product.
--   profiles            — a public profile, minus the columns that identify a
--                         session (see the column grants).
--   paid payout requests — a paid one names a SOL transfer that is on a public
--                         ledger, which is the same argument 20260805120200 made
--                         for publishing `payouts`. Pending and rejected ones are
--                         not on any ledger and stay private.
--
-- ===========================================================================
-- A CONSEQUENCE OF THE PUBLIC REVEAL ORDER, SAID OUT LOUD
-- ===========================================================================
-- Because the permutation is derivable in a browser and serials are dealt from
-- the head of the pool in order, a determined buyer can compute which draw
-- position yields an X-RATED and mint precisely when the pool head reaches it.
-- Publishing `reveal_order` does not create that exposure and restricting it
-- would not remove it.
--
-- What actually bounds it is `mint_policy`: a sniper cannot choose a position,
-- only wait for one, and while they wait the cooldown and the global window mean
-- they are queueing against everybody else on equal terms. Closing it properly
-- needs a commit–reveal with a seed the client does not hold, which is a
-- different design and is recorded as a known gap in supabase/README.md rather
-- than papered over here.

-- ---------------------------------------------------------------------------
-- Session helpers
-- ---------------------------------------------------------------------------

-- The wallet behind the current session, or null.
--
-- ZERO ARGUMENTS, deliberately. `actor_wallet(uuid)` stays closed to clients
-- because a caller who can pass a user id can enumerate the mapping from auth
-- users to wallets. This one reads `auth.uid()` itself, so the only question it
-- can answer is "who am I".
create or replace function public.current_wallet()
returns text
language sql
security definer
stable
set search_path = ''
as $$
  select w.wallet from public.wallet_identities w where w.auth_user_id = auth.uid()
$$;

create or replace function public.is_current_operator()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1
      from public.wallet_identities w
      join public.operators o on o.wallet = w.wallet
     where w.auth_user_id = auth.uid()
       and o.removed_at is null
       and o.can_pay
  )
$$;

comment on function public.current_wallet() is
  'The wallet that proved it owns the current session, or null. Takes no argument on purpose: a parameterised version would let any signed-in user enumerate the auth-user-to-wallet mapping.';

grant execute on function public.current_wallet() to anon, authenticated;
grant execute on function public.is_current_operator() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------------
--
-- Not FORCED, for the reason 20260805120200 gives: FORCE ROW LEVEL SECURITY
-- would subject the table owner to these policies too, and the owner is exactly
-- who the SECURITY DEFINER writers run as. Forcing it locks out the only
-- legitimate writer.

alter table public.tiers                   enable row level security;
alter table public.skills                  enable row level security;
alter table public.trait_values            enable row level security;
alter table public.xployee_skills          enable row level security;
alter table public.reveal_order            enable row level security;
alter table public.mint_policy             enable row level security;
alter table public.mint_rate_limits        enable row level security;
alter table public.mint_reservations       enable row level security;
alter table public.profiles                enable row level security;
alter table public.wallet_identities       enable row level security;
alter table public.wallet_link_challenges  enable row level security;
alter table public.rentals                 enable row level security;
alter table public.sim_fee_ledger          enable row level security;
alter table public.epochs                  enable row level security;
alter table public.epoch_yields            enable row level security;
alter table public.friend_requests         enable row level security;
alter table public.friendships             enable row level security;
alter table public.threads                 enable row level security;
alter table public.messages                enable row level security;
alter table public.trade_offers            enable row level security;
alter table public.trade_offer_legs        enable row level security;
alter table public.payout_requests         enable row level security;
alter table public.operators               enable row level security;

-- ---------------------------------------------------------------------------
-- Layer 1 — table privileges
-- ---------------------------------------------------------------------------

-- Everything closed first, so a table added to the list below without a matching
-- grant is unreadable rather than accidentally writable.
revoke all on public.tiers                  from anon, authenticated;
revoke all on public.skills                 from anon, authenticated;
revoke all on public.trait_values           from anon, authenticated;
revoke all on public.xployee_skills         from anon, authenticated;
revoke all on public.reveal_order           from anon, authenticated;
revoke all on public.mint_policy            from anon, authenticated;
revoke all on public.mint_rate_limits       from anon, authenticated;
revoke all on public.mint_reservations      from anon, authenticated;
revoke all on public.profiles               from anon, authenticated;
revoke all on public.wallet_identities      from anon, authenticated;
revoke all on public.wallet_link_challenges from anon, authenticated;
revoke all on public.rentals                from anon, authenticated;
revoke all on public.sim_fee_ledger         from anon, authenticated;
revoke all on public.epochs                 from anon, authenticated;
revoke all on public.epoch_yields           from anon, authenticated;
revoke all on public.friend_requests        from anon, authenticated;
revoke all on public.friendships            from anon, authenticated;
revoke all on public.threads                from anon, authenticated;
revoke all on public.messages               from anon, authenticated;
revoke all on public.trade_offers           from anon, authenticated;
revoke all on public.trade_offer_legs       from anon, authenticated;
revoke all on public.payout_requests        from anon, authenticated;
revoke all on public.operators              from anon, authenticated;

grant select on public.tiers             to anon, authenticated;
grant select on public.skills            to anon, authenticated;
grant select on public.trait_values      to anon, authenticated;
grant select on public.xployee_skills    to anon, authenticated;
grant select on public.reveal_order      to anon, authenticated;
grant select on public.mint_policy       to anon, authenticated;
grant select on public.mint_reservations to anon, authenticated;
grant select on public.rentals           to anon, authenticated;
grant select on public.sim_fee_ledger    to anon, authenticated;
grant select on public.epochs            to anon, authenticated;
grant select on public.epoch_yields      to anon, authenticated;
grant select on public.friendships       to anon, authenticated;
grant select on public.payout_requests   to anon, authenticated;

-- Correspondence: readable only by a session, and then only its own rows. The
-- policies below do the filtering; the grant is what makes the query legal at all.
grant select on public.friend_requests   to authenticated;
grant select on public.threads           to authenticated;
grant select on public.messages          to authenticated;
grant select on public.trade_offers      to authenticated;
grant select on public.trade_offer_legs  to authenticated;

-- COLUMN-LEVEL GRANT. `profiles.auth_user_id` is the join between a public wallet
-- and a private GoTrue user, and nothing outside this schema has any business
-- reading it — publishing it would let anyone build the mapping the zero-argument
-- `current_wallet()` above exists to avoid handing out. A column grant is the
-- right tool: it is enforced by the planner rather than by remembering to write
-- `select=...` correctly at every call site, and `select *` from anon simply
-- returns the columns it is allowed.
grant select (
  wallet, handle, bio, avatar_xployee_id,
  twitter_handle, twitter_verified_at,
  created_at, updated_at
) on public.profiles to anon, authenticated;

-- Deliberately NO grant at all:
--   wallet_identities      — holds auth_user_id and the signature that proved a
--                            link. The public projection of it is profiles.
--   wallet_link_challenges — a nonce is a secret until it is spent.
--   mint_rate_limits       — the live state of a security control. Publishing
--                            when a window resets is publishing when to attack.
--   operators              — an authority list is a target list, and nothing in
--                            the UI needs it: an operator's own session already
--                            knows, through is_current_operator().

-- Views inherit nothing; they need their own grant. Both are security_invoker,
-- so the underlying policies still apply to whoever queries them.
grant select on public.xployee_desks to anon, authenticated;
grant select on public.friend_edges  to anon, authenticated;

-- Sequences and default privileges were closed in 20260805120200 and are
-- restated here so this file can be read on its own.
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Layer 2 — read policies
-- ---------------------------------------------------------------------------

-- ---- The collection ----

create policy "tiers are public" on public.tiers
  for select to anon, authenticated using (true);
create policy "skills are public" on public.skills
  for select to anon, authenticated using (true);
create policy "trait vocabulary is public" on public.trait_values
  for select to anon, authenticated using (true);
create policy "xployee skills are public" on public.xployee_skills
  for select to anon, authenticated using (true);

-- Public because it already is — see the note at the top of this file. A policy
-- restricting a permutation that every visitor can recompute from the bundle
-- would protect nothing and would invite somebody to reason that it did.
create policy "the reveal order is public" on public.reveal_order
  for select to anon, authenticated using (true);

-- ---- The mint ----

create policy "the mint policy is published" on public.mint_policy
  for select to anon, authenticated using (true);

-- Reservations are supply information: which serials are spoken for right now.
-- The buyer already knows their own, and everyone benefits from the mint page
-- being able to say how much of the collection is genuinely still available
-- rather than counting a pool that includes held positions.
create policy "reservations are public" on public.mint_reservations
  for select to anon, authenticated using (true);

-- ---- The marketplace ----

create policy "rentals are public" on public.rentals
  for select to anon, authenticated using (true);
create policy "simulated fees are public" on public.sim_fee_ledger
  for select to anon, authenticated using (true);
create policy "the epoch ledger is public" on public.epochs
  for select to anon, authenticated using (true);
create policy "epoch yields are public" on public.epoch_yields
  for select to anon, authenticated using (true);

-- ---- Identity ----

-- The public half of a profile. The private half is excluded by the column
-- grant above rather than by this predicate, because a row-level policy cannot
-- hide a column and pretending otherwise is how `select auth_user_id` starts
-- working one day.
create policy "profiles are public" on public.profiles
  for select to anon, authenticated using (true);

-- ---- The social graph ----

-- Friendships are public: profiles render friend lists, and the connection graph
-- is a feature rather than a confidence.
create policy "friendships are public" on public.friendships
  for select to anon, authenticated using (true);

-- Requests are not. An open request is a thing one person has said to another and
-- nobody else, and a public request table would publish every rejection.
--
-- `(select public.current_wallet())` rather than a bare call: wrapping it in a
-- scalar subquery makes Postgres evaluate it once per statement as an InitPlan
-- instead of once per row.
create policy "a party reads its own friend requests" on public.friend_requests
  for select to authenticated
  using (
    requester = (select public.current_wallet())
    or addressee = (select public.current_wallet())
  );

create policy "a participant reads their own threads" on public.threads
  for select to authenticated
  using (
    participant_a = (select public.current_wallet())
    or participant_b = (select public.current_wallet())
  );

-- Messages are filtered through their thread rather than by a sender/recipient
-- column, so a message can only be read by someone who can read the conversation
-- it is in. One predicate, one place for it to be wrong.
create policy "a participant reads their own messages" on public.messages
  for select to authenticated
  using (
    exists (
      select 1 from public.threads t
       where t.id = messages.thread_id
         and (t.participant_a = (select public.current_wallet())
              or t.participant_b = (select public.current_wallet()))
    )
  );

create policy "a party reads its own offers" on public.trade_offers
  for select to authenticated
  using (
    sender = (select public.current_wallet())
    or recipient = (select public.current_wallet())
  );

create policy "a party reads its own offer legs" on public.trade_offer_legs
  for select to authenticated
  using (
    exists (
      select 1 from public.trade_offers o
       where o.id = trade_offer_legs.offer_id
         and (o.sender = (select public.current_wallet())
              or o.recipient = (select public.current_wallet()))
    )
  );

-- ---- The payout queue ----

-- Split on the same reasoning 20260805120200 used to publish `payouts`: a PAID
-- request names a SOL transfer that is already on a public ledger, so gating it
-- here would be theatre. A pending or rejected one is on no ledger at all — it is
-- a support ticket, and publishing everybody's declined claims would be a
-- disclosure with nothing behind it.
create policy "settled payout requests are public" on public.payout_requests
  for select to anon, authenticated using (status = 'paid');

create policy "a requester reads its own claims" on public.payout_requests
  for select to authenticated
  using (wallet = (select public.current_wallet()));

-- The admin desk. This is also what makes the realtime subscription work for an
-- operator and not for anybody else: Realtime evaluates these policies per
-- subscriber, so an unauthenticated socket receives only the 'paid' rows the
-- first policy publishes.
create policy "an operator reads the whole queue" on public.payout_requests
  for select to authenticated
  using ((select public.is_current_operator()));

-- ---------------------------------------------------------------------------
-- Layer 3 — explicit write denial
-- ---------------------------------------------------------------------------

-- Restrictive policies AND together with everything else, so `false` is final: no
-- permissive policy added later can grant a client write, and the denial shows up
-- in \d output instead of being an absence a reviewer has to notice.
--
-- Generated in a loop rather than written out twenty-three times four. Three
-- hand-written blocks of ninety near-identical statements is how one table ends
-- up with two of the three verbs closed and nobody spots the third.
do $$
declare
  t text;
  tables text[] := array[
    'tiers', 'skills', 'trait_values', 'xployee_skills', 'reveal_order',
    'mint_policy', 'mint_rate_limits', 'mint_reservations',
    'profiles', 'wallet_identities', 'wallet_link_challenges',
    'rentals', 'sim_fee_ledger', 'epochs', 'epoch_yields',
    'friend_requests', 'friendships', 'threads', 'messages',
    'trade_offers', 'trade_offer_legs', 'payout_requests', 'operators'
  ];
begin
  foreach t in array tables loop
    execute format(
      'create policy %I on public.%I as restrictive for insert to anon, authenticated with check (false)',
      t || ' accepts no client insert', t);
    execute format(
      'create policy %I on public.%I as restrictive for update to anon, authenticated using (false) with check (false)',
      t || ' accepts no client update', t);
    execute format(
      'create policy %I on public.%I as restrictive for delete to anon, authenticated using (false)',
      t || ' accepts no client delete', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- The check that the loop above actually covered everything
-- ---------------------------------------------------------------------------

-- Every table in `public` must have RLS enabled and must carry a restrictive
-- denial on all three write verbs. A table added by a later migration that
-- forgets its policies fails this block on the next push, which is the only way a
-- list like the one above stays complete.
do $$
declare
  v_rec record;
begin
  for v_rec in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and not c.relrowsecurity
  loop
    raise exception 'table public.% has no row level security', v_rec.relname;
  end loop;

  for v_rec in
    select c.relname,
           count(*) filter (where p.polpermissive = false and p.polcmd = 'a') as ins,
           count(*) filter (where p.polpermissive = false and p.polcmd = 'w') as upd,
           count(*) filter (where p.polpermissive = false and p.polcmd = 'd') as del
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      left join pg_policy p on p.polrelid = c.oid
     where n.nspname = 'public' and c.relkind = 'r'
     group by c.relname
    having count(*) filter (where p.polpermissive = false and p.polcmd = 'a') = 0
        or count(*) filter (where p.polpermissive = false and p.polcmd = 'w') = 0
        or count(*) filter (where p.polpermissive = false and p.polcmd = 'd') = 0
  loop
    raise exception
      'table public.% is missing a restrictive write denial (insert=%, update=%, delete=%)',
      v_rec.relname, v_rec.ins, v_rec.upd, v_rec.del;
  end loop;
end;
$$;


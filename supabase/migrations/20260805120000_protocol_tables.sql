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

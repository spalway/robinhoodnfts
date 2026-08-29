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

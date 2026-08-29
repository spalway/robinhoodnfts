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

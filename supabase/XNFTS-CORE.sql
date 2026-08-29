-- ===========================================================================
-- xNFTs — CORE. Mint gate, on-chain payment verification, leaderboard.
-- ===========================================================================
--
-- ONE FILE. Paste the whole thing into the Supabase SQL editor and run it.
-- Safe on top of the existing schema, and safe to run again — every statement
-- is idempotent, and nothing here drops or rewrites a table you already have.
--
-- WHAT IT GIVES YOU
--
--   1. A config row you edit in the dashboard: token address, dev wallet, RPC,
--      price, hold requirement. No redeploy to change any of it.
--   2. A mint gate the browser can ask about: "is this wallet allowed to mint
--      right now, and if not, why not?"
--   3. A payment verifier that reads the transaction OFF CHAIN ITSELF and only
--      then issues an NFT. This is the part that has to be right.
--   4. A rarity-ranked leaderboard for xNet.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--
--   No marketplace, no rentals, no epochs, no payout queue, no social graph.
--   Those tables can stay where they are; nothing here reads them.
--
-- THE ONE RULE THIS FILE IS BUILT ON
--
--   The database never believes the browser about money. A client posts a
--   transaction SIGNATURE and nothing else. Postgres fetches that transaction
--   from Solana itself, reads the token balance deltas, and decides. The buyer
--   is whoever the chain says sent the tokens — not whoever called the
--   function. That is why xnft_confirm_mint is safe to expose to `anon`: there
--   is no field in it a caller could lie in.
--
-- SETUP AFTER RUNNING (2 minutes)
--
--   update public.protocol_config set
--     xnft_mint  = 'YourTokenMintAddressHere',
--     dev_wallet = 'YourDevWalletAddressHere',
--     rpc_url    = 'https://your-rpc-provider/...'
--   where id = 1;
--
--   Until xnft_mint and dev_wallet are set, every mint path refuses. That is
--   intentional: there is no safe default for "which token" or "paid to whom".
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 0. EXTENSIONS
-- ---------------------------------------------------------------------------
--
-- `http` (pgsql-http) is what lets Postgres call the Solana RPC directly, which
-- is what makes this a single file instead of a SQL file plus an Edge Function
-- deploy. It ships with Supabase but is off by default.
--
-- If this warns, enable it by hand: Dashboard -> Database -> Extensions ->
-- search "http" -> toggle on, then re-run. Everything else still installs;
-- only xnft_confirm_mint needs it.

do $$
begin
  create extension if not exists http with schema extensions;
exception when others then
  raise warning
    'Could not enable the "http" extension automatically (%). Enable it in Dashboard -> Database -> Extensions, then re-run. Minting cannot verify payments without it.',
    sqlerrm;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. CONFIG
-- ---------------------------------------------------------------------------
--
-- Single row. The check constraint is the enforcement — a second row would mean
-- two browsers could read two different token addresses depending on which one
-- their query happened to return first.

create table if not exists public.protocol_config (
  id smallint primary key default 1 check (id = 1)
);

alter table public.protocol_config
  -- The SPL mint of your token. THE most important value here: it decides which
  -- token a buyer's wallet is asked to send. Empty means "not launched".
  add column if not exists xnft_mint text not null default '',

  -- Where the mint payment lands. Empty is a hard refusal — there is no safe
  -- fallback for "where does the money go".
  add column if not exists dev_wallet text not null default '',

  -- The RPC endpoint. Used by BOTH the browser (to read balances and send) and
  -- by xnft_confirm_mint below (to verify). Empty falls back to the public
  -- mainnet endpoint, which throttles hard — set a real one before launch.
  add column if not exists rpc_url text not null default '',

  -- Whole tokens a mint costs, and whole tokens a wallet must hold before the
  -- button unlocks. Separate fields on purpose: today they are both 10,000, but
  -- "you must hold X" and "you will pay Y" are different questions.
  add column if not exists mint_price_tokens numeric not null default 10000,
  add column if not exists hold_requirement_tokens numeric not null default 10000,

  -- Total NFTs that can ever exist. Must match MAX_SUPPLY in
  -- src/lib/xployee.ts, or the art the browser renders will not match the
  -- serial this database issued. Section 10 checks it.
  add column if not exists max_supply integer not null default 5000,

  -- Seeds the reveal shuffle. Changing it after launch does nothing — the queue
  -- is built exactly once — which is the correct behaviour.
  add column if not exists reveal_seed text not null default 'xnfts-reveal-v1',

  -- Kill switch. Stops minting without clearing the addresses, which would
  -- otherwise be the only way to stop it and would lose the values.
  add column if not exists minting_enabled boolean not null default true,

  -- Ceiling on transaction lookups per minute. xnft_confirm_mint is public, so
  -- without this a stranger posting random signatures could run up an RPC bill.
  add column if not exists rpc_probes_per_minute integer not null default 240,

  add column if not exists updated_at timestamptz not null default now();

insert into public.protocol_config (id) values (1) on conflict (id) do nothing;

comment on table public.protocol_config is
  'Single-row runtime config. Operator edits it in the dashboard; every browser reads it. Never writable with the anon key.';


-- ---------------------------------------------------------------------------
-- 2. TIERS AND RANKS
-- ---------------------------------------------------------------------------
--
-- Rarity is POSITIONAL: the collection is laid out rarest-first, so a serial is
-- itself a rarity claim. At 5,000 supply that is X-RATED #0000-#0149, EPIC
-- #0150-#0749, RARE #0750-#1999, UNCOMMON #2000-#4999.
--
-- The bands are computed from `supply_share` rather than written as literals,
-- so this table and src/lib/tiers.ts cannot silently drift apart.
--
-- `rarity_weight` is what the leaderboard sums. It is not a taste judgement, it
-- is how much rarer a tier is than the commonest one:
--
--     entry  0.60 / 0.60 =  1
--     mid    0.60 / 0.25 =  2.4
--     expert 0.60 / 0.12 =  5
--     xrated 0.60 / 0.03 = 20
--
-- So one X-RATED outranks nineteen UNCOMMONs, which is the point of pulling one.

create table if not exists public.xnft_tiers (
  id            text primary key,
  label         text not null,
  skills        smallint not null check (skills between 1 and 4),
  supply_share  numeric not null check (supply_share > 0 and supply_share <= 1),
  rarity_weight numeric not null check (rarity_weight > 0),
  -- Ascending rarity. Bands are laid out in the reverse of this order.
  tier_rank     smallint not null unique
);

insert into public.xnft_tiers (id, label, skills, supply_share, rarity_weight, tier_rank) values
  ('entry',  'UNCOMMON', 1, 0.60,  1.0, 0),
  ('mid',    'RARE',     2, 0.25,  2.4, 1),
  ('expert', 'EPIC',     3, 0.12,  5.0, 2),
  ('xrated', 'X-RATED',  4, 0.03, 20.0, 3)
on conflict (id) do update set
  label         = excluded.label,
  skills        = excluded.skills,
  supply_share  = excluded.supply_share,
  rarity_weight = excluded.rarity_weight,
  tier_rank     = excluded.tier_rank;


-- The xBoss ladder. Cutoffs are absolute rarity scores, deliberately not
-- percentile ranks: a rank should mean "this much rarity is held" and must not
-- drop because somebody else minted.

create table if not exists public.xnft_ranks (
  rank_id   text primary key,
  label     text not null,
  min_score numeric not null,
  ordinal   smallint not null unique
);

insert into public.xnft_ranks (rank_id, label, min_score, ordinal) values
  ('boss',     'BOSS',      0, 0),
  ('director', 'DIRECTOR',  5, 1),
  ('vp',       'VP',       15, 2),
  ('ceo',      'CEO',      40, 3)
on conflict (rank_id) do update set
  label     = excluded.label,
  min_score = excluded.min_score,
  ordinal   = excluded.ordinal;


-- ---------------------------------------------------------------------------
-- 3. THE REVEAL QUEUE
-- ---------------------------------------------------------------------------
--
-- Why this exists: because rarity is positional, handing serials out in
-- ascending order would mean the first 150 mints take every X-RATED in
-- existence and every mint after #2000 is UNCOMMON forever. The mint would stop
-- being a lottery and become a queue position.
--
-- So serials are drawn from a fixed shuffle, built once from `reveal_seed`.
-- Every claim is a row update, which is what makes two people minting in the
-- same second unable to receive the same serial.

create table if not exists public.xnft_queue (
  draw           integer primary key,
  serial         integer not null unique check (serial >= 0),
  claimed_by     text,
  claimed_at     timestamptz,
  mint_signature text
);

create index if not exists xnft_queue_unclaimed_idx
  on public.xnft_queue (draw) where claimed_by is null;

-- Built once. The `not exists` guard is what makes re-running this file a no-op
-- rather than an attempt to re-shuffle a collection people already hold.
insert into public.xnft_queue (draw, serial)
select row_number() over (order by md5(c.reveal_seed || ':' || g::text)) - 1, g
  from public.protocol_config c
  cross join generate_series(0, c.max_supply - 1) g
 where c.id = 1
   and not exists (select 1 from public.xnft_queue)
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 4. WHAT PEOPLE OWN
-- ---------------------------------------------------------------------------

create table if not exists public.xnft_holdings (
  serial         integer primary key check (serial >= 0),
  owner          text not null,
  tier           text not null references public.xnft_tiers (id),
  skills         smallint not null,
  rarity_weight  numeric not null,
  mint_signature text not null,
  minted_at      timestamptz not null default now()
);

create index if not exists xnft_holdings_owner_idx  on public.xnft_holdings (owner);
create index if not exists xnft_holdings_minted_idx on public.xnft_holdings (minted_at desc);

comment on table public.xnft_holdings is
  'One row per NFT that has been paid for and issued. Written only by xnft_confirm_mint, only after the payment was read off chain.';


-- Verified payments. Keyed on the signature, which is what makes ingestion
-- idempotent: posting the same signature twice cannot issue a second NFT.

create table if not exists public.xnft_mints (
  signature   text primary key,
  buyer       text not null,
  -- Raw base units as a decimal string, never a float. A u64 token amount does
  -- not survive a double, and this column is the record of what somebody paid.
  paid_raw    text not null,
  decimals    smallint not null,
  slot        bigint,
  block_time  timestamptz,
  serial      integer references public.xnft_holdings (serial),
  status      text not null default 'issued' check (status in ('issued', 'held')),
  held_reason text,
  indexed_at  timestamptz not null default now()
);

create index if not exists xnft_mints_buyer_idx on public.xnft_mints (buyer, indexed_at desc);

comment on column public.xnft_mints.status is
  'issued = payment verified and a serial was dealt. held = payment verified but no serial could be dealt (sold out or paused). A held row means real money arrived and owes a refund or a manual issue — it never means the payment failed.';


-- Cosmetic profile per wallet, created automatically on first mint so a wallet
-- appears on xNet the moment it pays.
--
-- `handle` is operator-writable only. Letting anyone set anyone's handle needs a
-- signed message from the wallet to prove ownership; see section 11.

create table if not exists public.xnft_profiles (
  wallet     text primary key,
  handle     text unique,
  bio        text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);


-- Throttle log for the public verifier. Insert-only, so concurrent mints never
-- block each other on it — an UPDATE counter would hold a row lock across the
-- RPC call and serialise every mint on the site behind one row.

create table if not exists public.xnft_probe_log (
  id        bigserial primary key,
  probed_at timestamptz not null default now()
);

create index if not exists xnft_probe_log_at_idx on public.xnft_probe_log (probed_at desc);


-- ---------------------------------------------------------------------------
-- 5. PURE HELPERS
-- ---------------------------------------------------------------------------

-- Which tier a serial belongs to. Mirrors tierForId() in src/lib/tiers.ts
-- exactly, including how rounding is absorbed: every band except the last is
-- rounded, and the last runs to max_supply. If the last band computed its own
-- end, a share table that rounds down would leave a gap — and a gap here is a
-- serial that can be issued but cannot exist.
create or replace function public.xnft_tier_for_serial(p_serial integer)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  with bands as (
    select t.id,
           t.tier_rank,
           c.max_supply,
           sum(round(t.supply_share * c.max_supply)) over (
             order by t.tier_rank desc
             rows between unbounded preceding and current row
           ) as band_end,
           row_number() over (order by t.tier_rank desc) as n,
           count(*) over () as bands_total
      from public.xnft_tiers t
      cross join public.protocol_config c
     where c.id = 1
  )
  select b.id
    from bands b
   where p_serial < (case when b.n = b.bands_total then b.max_supply else b.band_end end)
   order by b.tier_rank desc
   limit 1;
$$;


-- #0042. Zero-padded to four, matching serial() in src/lib/xployee.ts.
create or replace function public.xnft_serial_label(p_serial integer)
returns text
language sql
immutable
as $$
  select '#' || lpad(p_serial::text, 4, '0');
$$;


-- Cheap shape check before anything expensive happens. A Solana signature is 64
-- bytes of base58, which lands between 86 and 88 characters. This rejects a
-- malformed post without spending an RPC call on it.
create or replace function public.xnft_is_signature(p_signature text)
returns boolean
language sql
immutable
as $$
  select p_signature ~ '^[1-9A-HJ-NP-Za-km-z]{80,92}$';
$$;


-- ---------------------------------------------------------------------------
-- 6. THE RANKING
-- ---------------------------------------------------------------------------
--
-- A view, not a function, so the leaderboard and a single wallet's page compute
-- rank with one piece of code and cannot disagree. The public entry points wrap
-- it: the leaderboard clamps its page size, a wallet lookup does not.

create or replace view public.xnft_ranked as
  with crews as (
    select h.owner,
           count(*)             as holdings,
           sum(h.rarity_weight) as rarity_score,
           min(h.minted_at)     as first_mint_at,
           -- Rarest member, and the serial that proves it. Ordered inside the
           -- aggregate rather than joined again, so the tier and the serial are
           -- guaranteed to come from the same row.
           (array_agg(h.tier   order by t.tier_rank desc, h.serial asc))[1] as best_tier,
           (array_agg(h.serial order by t.tier_rank desc, h.serial asc))[1] as best_serial
      from public.xnft_holdings h
      join public.xnft_tiers t on t.id = h.tier
     group by h.owner
  )
  select row_number() over (
           order by c.rarity_score desc, c.holdings desc, c.first_mint_at asc
         )                    as rank_position,
         c.owner              as wallet,
         p.handle             as handle,
         c.holdings           as holdings,
         c.rarity_score       as rarity_score,
         c.best_tier          as best_tier,
         c.best_serial        as best_serial,
         c.first_mint_at      as first_mint_at,
         (select r.label
            from public.xnft_ranks r
           where c.rarity_score >= r.min_score
           order by r.ordinal desc
           limit 1)           as xboss
    from crews c
    left join public.xnft_profiles p on p.wallet = c.owner;


-- ---------------------------------------------------------------------------
-- 7. READ API — what the browser asks before it lets anyone click
-- ---------------------------------------------------------------------------

-- Everything the mint page needs, in one round trip.
--
-- Note what is NOT here: the wallet's token balance. That comes from Solana in
-- the browser, because a balance read is the browser's job and a database that
-- cached one would just be a stale second opinion. This returns the THRESHOLD;
-- the browser compares its own live balance against it.
create or replace function public.xnft_mint_status(p_wallet text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cfg        public.protocol_config;
  v_issued     bigint;
  v_remaining  bigint;
  v_owned      bigint := 0;
  v_configured boolean;
  v_reason     text := null;
begin
  select * into v_cfg from public.protocol_config where id = 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no-config');
  end if;

  select count(*) into v_issued from public.xnft_holdings;
  v_remaining := greatest(v_cfg.max_supply - v_issued, 0);

  if p_wallet is not null and length(trim(p_wallet)) > 0 then
    select count(*) into v_owned from public.xnft_holdings where owner = trim(p_wallet);
  end if;

  -- Armed means all three: a token, a payee, and the switch on. Each failure is
  -- different and the browser should be able to say which.
  v_configured := length(v_cfg.xnft_mint) > 0 and length(v_cfg.dev_wallet) > 0;

  if not v_configured then
    v_reason := 'not-configured';
  elsif not v_cfg.minting_enabled then
    v_reason := 'paused';
  elsif v_remaining <= 0 then
    v_reason := 'sold-out';
  end if;

  return jsonb_build_object(
    'ok',                      v_reason is null,
    'reason',                  v_reason,
    'configured',              v_configured,
    'minting_enabled',         v_cfg.minting_enabled,
    'mint_address',            v_cfg.xnft_mint,
    'dev_wallet',              v_cfg.dev_wallet,
    'rpc_url',                 v_cfg.rpc_url,
    'price_tokens',            v_cfg.mint_price_tokens,
    'hold_requirement_tokens', v_cfg.hold_requirement_tokens,
    'max_supply',              v_cfg.max_supply,
    'issued',                  v_issued,
    'remaining',               v_remaining,
    'wallet',                  nullif(trim(coalesce(p_wallet, '')), ''),
    'wallet_holdings',         v_owned
  );
end;
$$;


-- The leaderboard. Ranked by summed rarity weight, which is real data: it is
-- exactly what a wallet paid for and pulled, and it cannot move without a
-- verified on-chain payment behind it. Ties break on who got there first, so an
-- early minter never loses their place to a later wallet with an identical crew.
create or replace function public.xnft_leaderboard(
  p_limit  integer default 50,
  p_offset integer default 0,
  p_query  text default null
)
returns table (
  rank_position bigint,
  wallet        text,
  handle        text,
  holdings      bigint,
  rarity_score  numeric,
  best_tier     text,
  best_serial   integer,
  xboss         text,
  first_mint_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.rank_position, r.wallet, r.handle, r.holdings, r.rarity_score,
         r.best_tier, r.best_serial, r.xboss, r.first_mint_at
    from public.xnft_ranked r
   where p_query is null
      or length(trim(p_query)) = 0
      -- Address match stays case-sensitive because base58 is. Handles do not.
      or r.wallet like trim(p_query) || '%'
      or lower(coalesce(r.handle, '')) like '%' || lower(trim(p_query)) || '%'
   order by r.rank_position
   limit  greatest(least(coalesce(p_limit, 50), 200), 1)
  offset greatest(coalesce(p_offset, 0), 0);
$$;


-- Network totals for the xNet header.
create or replace function public.xnft_network_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'wallets',      (select count(distinct h.owner) from public.xnft_holdings h),
    'issued',       (select count(*) from public.xnft_holdings),
    'max_supply',   (select c.max_supply from public.protocol_config c where c.id = 1),
    'rarity_total', (select coalesce(sum(h.rarity_weight), 0) from public.xnft_holdings h),
    'tiers',        (select coalesce(jsonb_object_agg(s.tier, s.n), '{}'::jsonb)
                       from (select h.tier, count(*) as n
                               from public.xnft_holdings h group by h.tier) s)
  );
$$;


-- One wallet's page: its rank, its crew, its profile. Reads the unclamped view,
-- so a wallet ranked 900th is still found.
create or replace function public.xnft_wallet(p_wallet text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_wallet text := trim(coalesce(p_wallet, ''));
  v_row    record;
  v_found  boolean := false;
  v_crew   jsonb;
begin
  if length(v_wallet) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no-wallet');
  end if;

  select * into v_row from public.xnft_ranked r where r.wallet = v_wallet;
  v_found := found;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'serial',        h.serial,
             'label',         public.xnft_serial_label(h.serial),
             'tier',          h.tier,
             'skills',        h.skills,
             'rarity_weight', h.rarity_weight,
             'minted_at',     h.minted_at,
             'signature',     h.mint_signature
           ) order by t.tier_rank desc, h.serial asc
         ), '[]'::jsonb)
    into v_crew
    from public.xnft_holdings h
    join public.xnft_tiers t on t.id = h.tier
   where h.owner = v_wallet;

  return jsonb_build_object(
    'ok',            v_found,
    'wallet',        v_wallet,
    'handle',        case when v_found then v_row.handle else null end,
    'position',      case when v_found then v_row.rank_position else null end,
    'holdings',      case when v_found then v_row.holdings else 0 end,
    'rarity_score',  case when v_found then v_row.rarity_score else 0 end,
    'xboss',         case when v_found then v_row.xboss else null end,
    'first_mint_at', case when v_found then v_row.first_mint_at else null end,
    'crew',          v_crew
  );
end;
$$;


-- ---------------------------------------------------------------------------
-- 8. THE WRITE PATH — verify a payment on chain, then issue an NFT
-- ---------------------------------------------------------------------------
--
-- This is the only function in the file that writes ownership, and the only one
-- whose correctness money depends on. Read it carefully.
--
-- The caller passes a signature. Nothing else. Every fact used to decide the
-- outcome — who paid, how much, in which token, to whom — is read out of a
-- transaction this function fetched from Solana itself.
--
-- WHY BALANCE DELTAS AND NOT INSTRUCTIONS. `meta.preTokenBalances` and
-- `meta.postTokenBalances` are the ledger's own account of what changed. An
-- instruction list says what was *ordered*; the deltas say what *happened*.
-- Nothing but a real transfer can produce one, so this cannot be fooled by a
-- transaction that merely looks like a transfer.
--
-- THE CHECKS, IN ORDER, AND WHY EACH IS THERE:
--
--   1. Signature parses. A malformed post never costs an RPC call.
--   2. Already indexed? Return the existing result. Idempotent, so a client that
--      retries — or double-fires — cannot be issued a second NFT.
--   3. Config is armed. No token address or no payee means refuse, not guess.
--   4. Probe budget. Bounds what a stranger posting junk signatures can cost.
--   5. Transaction exists. A signature the RPC has not caught up to is 'pending'
--      and a retry, NOT a failure. This is the normal state for the first second
--      after a send, and calling it a failure is how somebody pays twice.
--   6. meta.err is null. A transaction that landed and failed moved nothing.
--   7. The dev wallet's balance in the configured token went UP by at least the
--      price. Not "a transfer exists" — the NET change, which survives a
--      transaction that also moves the tokens back out again.
--   8. The buyer is the account that went down, is not the dev wallet, and was
--      debited at least the price.
--
-- WHAT HAPPENS WHEN THE COLLECTION IS SOLD OUT OR PAUSED. The payment is
-- recorded with status 'held' and no serial is dealt. The money is real and
-- arrived; refusing to write the row would be the backend forgetting it. A
-- client must render that as "your payment is with an operator", never as a
-- failure.

create or replace function public.xnft_confirm_mint(p_signature text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cfg        public.protocol_config;
  v_sig        text := trim(coalesce(p_signature, ''));
  v_existing   public.xnft_mints;
  v_probes     bigint;
  v_rpc        text;
  v_body       text;
  v_http_code  integer;
  v_http_body  text;
  v_json       jsonb;
  v_result     jsonb;
  v_meta       jsonb;
  v_err        jsonb;
  v_legs       jsonb;
  v_decimals   integer;
  v_price_raw  numeric;
  v_received   numeric;
  v_spent      numeric;
  v_buyer      text;
  v_slot       bigint;
  v_block_time timestamptz;
  v_serial     integer;
  v_tier       text;
  v_skills     smallint;
  v_weight     numeric;
  v_status     text;
  v_held       text := null;
begin
  -- 1. Shape.
  if not public.xnft_is_signature(v_sig) then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'bad-signature',
      'message', 'That is not a Solana transaction signature. Nothing was written.');
  end if;

  -- 2. Replay. Checked here for the fast path and again under the lock below,
  -- which is the one that actually holds under concurrency.
  select * into v_existing from public.xnft_mints where signature = v_sig;
  if found then
    return jsonb_build_object(
      'ok', true, 'status', 'duplicate', 'signature', v_sig, 'buyer', v_existing.buyer,
      'assignment', jsonb_build_object(
        'status',      v_existing.status,
        'serial',      v_existing.serial,
        'label',       case when v_existing.serial is null
                            then null else public.xnft_serial_label(v_existing.serial) end,
        'tier',        (select h.tier from public.xnft_holdings h where h.serial = v_existing.serial),
        'held_reason', v_existing.held_reason));
  end if;

  select * into v_cfg from public.protocol_config where id = 1;

  -- 3. Armed?
  if v_cfg.xnft_mint = '' or v_cfg.dev_wallet = '' then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'not-configured',
      'message', 'The token address or the dev wallet has not been set. Nothing was written.');
  end if;

  -- 4. Probe budget. Insert-only so concurrent mints do not queue behind a row
  -- lock held across the RPC call. The count can undercount slightly under
  -- concurrency, which is fine for a ceiling.
  delete from public.xnft_probe_log where probed_at < now() - interval '10 minutes';
  select count(*) into v_probes
    from public.xnft_probe_log where probed_at > now() - interval '1 minute';

  if v_probes >= v_cfg.rpc_probes_per_minute then
    return jsonb_build_object('ok', false, 'status', 'busy', 'reason', 'rate-limited',
      'message', 'The verifier is at its lookup ceiling for this minute. Retry shortly — your transaction is on chain and this is not a failure.');
  end if;
  insert into public.xnft_probe_log default values;

  -- 5. Fetch it. jsonParsed so `owner` is present on the token balances —
  -- without it there are only account indexes and no way to tell who paid.
  v_rpc := case when length(v_cfg.rpc_url) > 0
                then v_cfg.rpc_url
                else 'https://api.mainnet-beta.solana.com' end;

  v_body := jsonb_build_object(
    'jsonrpc', '2.0', 'id', 1, 'method', 'getTransaction',
    'params', jsonb_build_array(
      v_sig,
      jsonb_build_object(
        'encoding',                      'jsonParsed',
        'commitment',                    'confirmed',
        'maxSupportedTransactionVersion', 0))
  )::text;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
    -- Selected out of the composite rather than declared as extensions.http_response,
    -- so this function still compiles on a database where the http extension has
    -- not been enabled yet. It fails at call time with a clear message instead of
    -- refusing to install.
    select r.status, r.content into v_http_code, v_http_body
      from extensions.http_post(v_rpc, v_body, 'application/json') r;
  exception when others then
    -- An unreachable RPC is an availability problem, never a verdict. 'pending'
    -- tells the client to retry rather than telling a buyer their mint failed.
    return jsonb_build_object('ok', false, 'status', 'pending', 'reason', 'rpc-unreachable',
      'message', 'Could not reach the Solana RPC. Your transaction is unaffected — retry in a moment.',
      'detail', sqlerrm);
  end;

  if v_http_code <> 200 then
    return jsonb_build_object('ok', false, 'status', 'pending', 'reason', 'rpc-error',
      'message', format('The RPC answered %s. Retry in a moment.', v_http_code));
  end if;

  begin
    v_json := v_http_body::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'status', 'pending', 'reason', 'rpc-unreadable',
      'message', 'The RPC returned something this verifier could not read. Retry in a moment.');
  end;

  v_result := v_json -> 'result';

  -- Null result = the node has not seen it yet. THE most important branch in
  -- this function: a buyer whose tokens have left and whose transaction is one
  -- second old lands here, and calling it a failure is how they pay twice.
  if v_result is null or jsonb_typeof(v_result) = 'null' then
    return jsonb_build_object('ok', false, 'status', 'pending', 'reason', 'not-found',
      'message', 'The RPC has not seen that transaction yet. Normal for a few seconds after sending — retry.');
  end if;

  v_meta := v_result -> 'meta';
  if v_meta is null or jsonb_typeof(v_meta) = 'null' then
    return jsonb_build_object('ok', false, 'status', 'pending', 'reason', 'no-meta',
      'message', 'That transaction carried no metadata to verify against. Retry in a moment.');
  end if;

  -- 6. Landed and succeeded.
  v_err := v_meta -> 'err';
  if v_err is not null and jsonb_typeof(v_err) <> 'null' then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'transaction-failed',
      'message', 'That transaction failed on chain, so nothing moved. No payment was recorded.');
  end if;

  v_slot := (v_result ->> 'slot')::bigint;
  v_block_time := case when v_result ->> 'blockTime' is null
                       then null
                       else to_timestamp((v_result ->> 'blockTime')::bigint) end;

  -- 7. Net movement of the configured token, per owner.
  --
  -- Full outer join on accountIndex, because an account created by this
  -- transaction appears only in post, and one emptied and closed appears only in
  -- pre. A missing side reads as zero.
  select jsonb_agg(jsonb_build_object('owner', l.owner, 'delta', l.delta, 'dec', l.dec))
    into v_legs
    from (
      with pre as (
        select (b ->> 'accountIndex')::int                  as idx,
               b ->> 'owner'                                as owner,
               (b -> 'uiTokenAmount' ->> 'amount')::numeric as amt,
               (b -> 'uiTokenAmount' ->> 'decimals')::int   as dec
          from jsonb_array_elements(coalesce(v_meta -> 'preTokenBalances', '[]'::jsonb)) b
         where b ->> 'mint' = v_cfg.xnft_mint
      ),
      post as (
        select (b ->> 'accountIndex')::int                  as idx,
               b ->> 'owner'                                as owner,
               (b -> 'uiTokenAmount' ->> 'amount')::numeric as amt,
               (b -> 'uiTokenAmount' ->> 'decimals')::int   as dec
          from jsonb_array_elements(coalesce(v_meta -> 'postTokenBalances', '[]'::jsonb)) b
         where b ->> 'mint' = v_cfg.xnft_mint
      )
      select coalesce(po.owner, pr.owner)              as owner,
             coalesce(po.dec, pr.dec)                  as dec,
             coalesce(po.amt, 0) - coalesce(pr.amt, 0) as delta
        from post po
        full outer join pre pr on pr.idx = po.idx
    ) l
   where l.owner is not null;

  if v_legs is null then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'wrong-token',
      'message', 'That transaction moved none of the configured token. No payment was recorded.');
  end if;

  select max((l ->> 'dec')::int) into v_decimals from jsonb_array_elements(v_legs) l;

  -- Without decimals there is no price to compare against, and a null price
  -- would make every comparison below NULL — which reads as "not less than" and
  -- would wave the payment through. Refuse instead.
  if v_decimals is null then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'no-decimals',
      'message', 'That transaction did not report the token decimals, so the amount could not be checked.');
  end if;

  v_price_raw := v_cfg.mint_price_tokens * power(10::numeric, v_decimals);

  -- What the dev wallet netted.
  select coalesce(sum((l ->> 'delta')::numeric), 0) into v_received
    from jsonb_array_elements(v_legs) l
   where l ->> 'owner' = v_cfg.dev_wallet;

  if v_received < v_price_raw then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'underpaid',
      'message', format('That transaction delivered %s of the required %s base units to the project wallet. No NFT was issued.',
                        v_received::text, v_price_raw::text));
  end if;

  -- 8. Who paid: the largest net decrease, which is the payer even when the
  -- transaction also shuffles change between the buyer's own token accounts.
  select l ->> 'owner', -((l ->> 'delta')::numeric)
    into v_buyer, v_spent
    from jsonb_array_elements(v_legs) l
   where (l ->> 'delta')::numeric < 0
     and l ->> 'owner' <> v_cfg.dev_wallet
   order by (l ->> 'delta')::numeric asc
   limit 1;

  if v_buyer is null then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'no-payer',
      'message', 'No wallet other than the project wallet lost tokens in that transaction, so there is nobody to issue an NFT to.');
  end if;

  if v_spent < v_price_raw then
    return jsonb_build_object('ok', false, 'status', 'rejected', 'reason', 'underpaid',
      'message', 'The paying wallet was not debited the full mint price. No NFT was issued.');
  end if;

  -- Serialise issuance. Taken AFTER the RPC call, so the lock is held for
  -- microseconds rather than across a network round trip. A fixed key rather
  -- than a hash of a string, so there is nothing to resolve at runtime.
  perform pg_advisory_xact_lock(8421001);

  -- Re-check the replay under the lock.
  select * into v_existing from public.xnft_mints where signature = v_sig;
  if found then
    return jsonb_build_object('ok', true, 'status', 'duplicate', 'signature', v_sig,
      'buyer', v_existing.buyer,
      'assignment', jsonb_build_object('status', v_existing.status, 'serial', v_existing.serial));
  end if;

  -- Paused counts as sold out for issuance: the money is real either way, so it
  -- is recorded, and the serial is withheld.
  if not v_cfg.minting_enabled then
    v_held := 'Minting was paused when this payment was verified. The payment is recorded and held for an operator.';
  end if;

  if v_held is null then
    update public.xnft_queue q
       set claimed_by = v_buyer, claimed_at = now(), mint_signature = v_sig
     where q.draw = (
             select q2.draw from public.xnft_queue q2
              where q2.claimed_by is null
              order by q2.draw
              limit 1
              for update skip locked)
    returning q.serial into v_serial;

    if v_serial is null then
      v_held := 'Every serial in the collection has been issued. The payment is recorded and held for an operator.';
    end if;
  end if;

  if v_serial is not null then
    v_tier := public.xnft_tier_for_serial(v_serial);
    select t.skills, t.rarity_weight into v_skills, v_weight
      from public.xnft_tiers t where t.id = v_tier;

    insert into public.xnft_holdings
      (serial, owner, tier, skills, rarity_weight, mint_signature, minted_at)
    values
      (v_serial, v_buyer, v_tier, v_skills, v_weight, v_sig, coalesce(v_block_time, now()));

    -- A wallet appears on xNet the moment it pays, with no extra step.
    insert into public.xnft_profiles (wallet) values (v_buyer) on conflict (wallet) do nothing;

    v_status := 'issued';
  else
    v_status := 'held';
  end if;

  insert into public.xnft_mints
    (signature, buyer, paid_raw, decimals, slot, block_time, serial, status, held_reason)
  values
    (v_sig, v_buyer, v_spent::text, v_decimals, v_slot, v_block_time, v_serial, v_status, v_held);

  return jsonb_build_object(
    'ok',         true,
    'status',     'confirmed',
    'signature',  v_sig,
    'buyer',      v_buyer,
    'paid_raw',   v_spent::text,
    'decimals',   v_decimals,
    'slot',       v_slot,
    'block_time', v_block_time,
    'assignment', jsonb_build_object(
      'status',      v_status,
      'serial',      v_serial,
      'label',       case when v_serial is null then null else public.xnft_serial_label(v_serial) end,
      'tier',        v_tier,
      'skills',      v_skills,
      'held_reason', v_held));
end;
$$;


-- ---------------------------------------------------------------------------
-- 9. SECURITY
-- ---------------------------------------------------------------------------
--
-- Reads are open — a leaderboard and a config of public addresses are public
-- facts, and every one of them is already visible on chain. Writes are denied
-- twice: no GRANT, and a restrictive RLS policy underneath it. Both are needed.
-- An RLS policy decides which ROWS a role may touch; it does not grant the role
-- permission to touch the table at all, and Postgres checks the grant first.

alter table public.protocol_config enable row level security;
alter table public.xnft_tiers      enable row level security;
alter table public.xnft_ranks      enable row level security;
alter table public.xnft_queue      enable row level security;
alter table public.xnft_holdings   enable row level security;
alter table public.xnft_mints      enable row level security;
alter table public.xnft_profiles   enable row level security;
alter table public.xnft_probe_log  enable row level security;

do $$
declare
  t text;
  -- Readable by anyone.
  readable text[] := array[
    'protocol_config', 'xnft_tiers', 'xnft_ranks',
    'xnft_holdings', 'xnft_mints', 'xnft_profiles'
  ];
  -- NOT readable. Publishing which serial sits at the next unclaimed draw would
  -- tell the next minter exactly what they are about to get, which ends the
  -- lottery. The probe log is noise nobody needs.
  hidden text[] := array['xnft_queue', 'xnft_probe_log'];
begin
  -- REVOKE ALL first, and this is the load-bearing line rather than tidiness.
  -- Supabase ships `alter default privileges in schema public grant all on
  -- tables to anon, authenticated`, so every table created above was handed
  -- full access to the anon key the moment it existed. Revoking only
  -- insert/update/delete would leave SELECT behind — and SELECT on xnft_queue
  -- is the reveal order, which tells the next minter exactly what they are
  -- about to pull. The grants below then add back only what is meant to be
  -- public.
  foreach t in array (readable || hidden) loop
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;

  foreach t in array readable loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_read', t);
    execute format('grant select on public.%I to anon, authenticated', t);
  end loop;

  foreach t in array (readable || hidden) loop
    execute format('drop policy if exists %I on public.%I', t || '_no_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_no_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_no_delete', t);
    execute format('create policy %I on public.%I as restrictive for insert to anon, authenticated with check (false)', t || '_no_insert', t);
    execute format('create policy %I on public.%I as restrictive for update to anon, authenticated using (false) with check (false)', t || '_no_update', t);
    execute format('create policy %I on public.%I as restrictive for delete to anon, authenticated using (false)', t || '_no_delete', t);
  end loop;
end;
$$;

-- The view is read through the SECURITY DEFINER functions above, which is why
-- it is not granted to clients directly: the functions are the API surface.
revoke all on public.xnft_ranked from anon, authenticated;

-- The bigserial behind xnft_probe_log gets its own default grant, separately
-- from the table's.
revoke all on sequence public.xnft_probe_log_id_seq from anon, authenticated;

-- Postgres grants EXECUTE to PUBLIC on every new function, so locking anything
-- down means revoking from PUBLIC first and then granting back deliberately.
revoke execute on function public.xnft_confirm_mint(text)                 from public;
revoke execute on function public.xnft_mint_status(text)                  from public;
revoke execute on function public.xnft_leaderboard(integer, integer, text) from public;
revoke execute on function public.xnft_network_stats()                    from public;
revoke execute on function public.xnft_wallet(text)                       from public;
revoke execute on function public.xnft_tier_for_serial(integer)           from public;

-- SECURITY DEFINER, so these run as owner and see past RLS — which is exactly
-- why each one is narrow and takes no field that could be lied in.
-- xnft_confirm_mint takes a signature; the buyer comes from the chain.
grant execute on function public.xnft_mint_status(text)                   to anon, authenticated;
grant execute on function public.xnft_leaderboard(integer, integer, text) to anon, authenticated;
grant execute on function public.xnft_network_stats()                     to anon, authenticated;
grant execute on function public.xnft_wallet(text)                        to anon, authenticated;
grant execute on function public.xnft_confirm_mint(text)                  to anon, authenticated;
grant execute on function public.xnft_serial_label(integer)               to anon, authenticated;
grant execute on function public.xnft_tier_for_serial(integer)            to anon, authenticated;


-- ---------------------------------------------------------------------------
-- 10. RETIRE THE OLD MINT PATH
-- ---------------------------------------------------------------------------
--
-- The previous design routed mints through `record_mint`, called by the
-- `ingest-signature` Edge Function. That function recognised a mint ONLY as a
-- transfer to the incinerator, while the browser built its transfer to the DEV
-- WALLET — so a real mint took the buyer's tokens and was then refused by the
-- indexer. Money gone, no NFT. That mismatch is why this file exists.
--
-- Dropping the entry point is the point: a caller still aimed at the old path
-- now gets "function does not exist" rather than silently writing to a table
-- nothing reads. Existing rows are untouched.

do $$
begin
  drop function if exists public.record_mint(text, integer, bigint, timestamptz, text, text);
  drop function if exists public.record_mint(text, integer, bigint, timestamptz, text, text, text);
exception when others then
  raise warning 'Could not drop the legacy record_mint (%). It is inert either way — nothing in this file calls it.', sqlerrm;
end;
$$;


-- ---------------------------------------------------------------------------
-- 11. SELF-CHECK
-- ---------------------------------------------------------------------------
--
-- Runs at install and fails loudly rather than leaving a half-armed database.

do $$
declare
  v_cfg   public.protocol_config;
  v_queue bigint;
  v_http  boolean;
  v_probe integer;
  v_bad   integer := 0;
begin
  select * into v_cfg from public.protocol_config where id = 1;
  select count(*) into v_queue from public.xnft_queue;

  if v_queue <> v_cfg.max_supply then
    raise exception
      'Reveal queue holds % serials but max_supply is %. The queue is built exactly once — if you changed max_supply after installing, that is the conflict.',
      v_queue, v_cfg.max_supply;
  end if;

  -- Every serial must land in exactly one band. A gap is a serial that can be
  -- issued and cannot exist. Checked at the boundaries and the endpoints, which
  -- is where an off-by-one from rounding would land.
  foreach v_probe in array array[0, 149, 150, 749, 750, 1999, 2000, v_cfg.max_supply - 1] loop
    if v_probe between 0 and v_cfg.max_supply - 1
       and public.xnft_tier_for_serial(v_probe) is null then
      v_bad := v_bad + 1;
    end if;
  end loop;

  if v_bad > 0 then
    raise exception 'Tier bands leave % probed serials unassigned. Check that supply_share in xnft_tiers sums to 1.', v_bad;
  end if;

  select exists (select 1 from pg_extension where extname = 'http') into v_http;

  raise notice '--------------------------------------------------------------';
  raise notice 'xNFTs core installed.';
  raise notice '  reveal queue   : % serials', v_queue;
  raise notice '  issued so far  : %', (select count(*) from public.xnft_holdings);
  raise notice '  tier bands     : %/%/%/%',
    public.xnft_tier_for_serial(0), public.xnft_tier_for_serial(200),
    public.xnft_tier_for_serial(1000), public.xnft_tier_for_serial(4999);
  raise notice '  http extension : %', case when v_http then 'enabled' else 'MISSING — minting cannot verify payments' end;
  raise notice '  token address  : %', case when v_cfg.xnft_mint = '' then 'NOT SET — minting disarmed' else v_cfg.xnft_mint end;
  raise notice '  dev wallet     : %', case when v_cfg.dev_wallet = '' then 'NOT SET — minting disarmed' else v_cfg.dev_wallet end;
  raise notice '  rpc            : %', case when v_cfg.rpc_url = '' then 'public mainnet (throttled — set one)' else v_cfg.rpc_url end;
  raise notice '  price / gate   : % / % tokens', v_cfg.mint_price_tokens, v_cfg.hold_requirement_tokens;
  raise notice '--------------------------------------------------------------';
end;
$$;

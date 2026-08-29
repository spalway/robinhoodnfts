-- The backend the current frontend actually calls.
--
-- ===========================================================================
-- WHY THIS FILE EXISTS
-- ===========================================================================
-- src/lib/backend.ts posts to five PostgREST functions and reads one table:
--
--   xnft_mint_status, xnft_confirm_mint, xnft_network_stats,
--   xnft_leaderboard, xnft_wallet, and the table xnft_holdings.
--
-- None of them existed. The frontend was rewritten to use them and the SQL was
-- never written, so a database built from every other migration in this folder
-- still could not answer a single request the site makes. Every page would have
-- rendered its error state.
--
-- ===========================================================================
-- WHY IT IS SMALL
-- ===========================================================================
-- The older migrations seed 12,900 rows describing every xployee and every skill
-- it holds. This backend needs none of it, because rarity is POSITIONAL: a
-- serial's tier is a function of the serial (see tierForId in src/lib/tiers.ts),
-- so it is computed here rather than looked up. The only thing that genuinely
-- cannot be derived is which serial the Nth mint receives, and that is one
-- column of integers generated below.
--
-- ===========================================================================
-- WHAT IS DELIBERATELY NOT FINISHED
-- ===========================================================================
-- xnft_confirm_mint decides who receives a serial after real money has moved.
-- It cannot be written correctly until $XAS exists, because the thing it has to
-- do is read a specific transfer of a specific mint off the chain. It therefore
-- REFUSES while the mint address is unset — which is the state today — rather
-- than shipping a verifier that could issue a serial to somebody who paid
-- nothing. See the note above the function.

-- ---------------------------------------------------------------------------
-- Rarity, derived
-- ---------------------------------------------------------------------------

-- The bands are the cumulative tier shares from src/lib/tiers.ts, rarest first:
-- X-RATED 3%, EPIC 12%, RARE 25%, UNCOMMON the remainder. The last band runs to
-- max supply rather than computing its own end, for the same reason tierForId
-- does it: a share table that rounds down must not leave a serial no xployee can
-- occupy.
create or replace function public.xnft_tier_for(p_serial integer, p_max integer default 5000)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_serial is null or p_serial < 0 or p_serial >= p_max then null
    when p_serial <  round(0.03 * p_max)                        then 'xrated'
    when p_serial <  round(0.03 * p_max) + round(0.12 * p_max)  then 'expert'
    when p_serial <  round(0.03 * p_max) + round(0.12 * p_max) + round(0.25 * p_max) then 'mid'
    else 'entry'
  end
$$;

/** Desks worked. Doubles as the rarity weight — more desks is rarer. */
create or replace function public.xnft_tier_skills(p_tier text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_tier
    when 'xrated' then 4
    when 'expert' then 3
    when 'mid'    then 2
    else 1
  end
$$;

create or replace function public.xnft_tier_label(p_tier text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_tier
    when 'xrated' then 'X-RATED'
    when 'expert' then 'EPIC'
    when 'mid'    then 'RARE'
    else 'UNCOMMON'
  end
$$;

-- ---------------------------------------------------------------------------
-- The reveal order
-- ---------------------------------------------------------------------------
--
-- One fixed shuffle of every serial. Serials are dealt from it in order, which
-- is what keeps the mint a lottery: handed out ascending, the first 150 mints
-- would take every X-RATED in existence and everything after #2000 would be
-- uncommon forever.
--
-- Generated here with a fixed seed rather than shipped as 5,000 literals. It
-- does NOT have to match the browser's own permutation, and that is worth
-- stating: nothing client-side decides which serial a mint receives any more —
-- the answer comes back from xnft_confirm_mint. The browser's mintOrder() now
-- only picks which samples to show on the landing page.
create table if not exists public.xnft_reveal_order (
  position integer primary key,
  serial integer not null unique
);

do $$
begin
  if not exists (select 1 from public.xnft_reveal_order) then
    perform setseed(0.42);
    insert into public.xnft_reveal_order (position, serial)
    select row_number() over (order by ord) - 1, serial
      from (select generate_series(0, 4999) as serial, random() as ord) s;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Ownership
-- ---------------------------------------------------------------------------
--
-- The record of who holds what, and the only writable table here. One row per
-- issued serial; the signature is unique, which is what makes issuing idempotent
-- — a replayed confirmation cannot mint twice.
create table if not exists public.xnft_holdings (
  serial integer primary key references public.xnft_reveal_order (serial),
  owner text not null,
  tier text not null,
  minted_at timestamptz not null default now(),
  mint_signature text not null unique
);

create index if not exists xnft_holdings_owner_idx on public.xnft_holdings (owner);

alter table public.xnft_holdings enable row level security;
alter table public.xnft_reveal_order enable row level security;

-- Published to anon: every row corresponds to a public transaction, so hiding
-- it here while it sits on chain would protect nothing and would stop the site
-- from working.
grant select on public.xnft_holdings to anon, authenticated;
grant select on public.xnft_reveal_order to anon, authenticated;

drop policy if exists xnft_holdings_read on public.xnft_holdings;
create policy xnft_holdings_read on public.xnft_holdings
  for select to anon, authenticated using (true);

drop policy if exists xnft_reveal_order_read on public.xnft_reveal_order;
create policy xnft_reveal_order_read on public.xnft_reveal_order
  for select to anon, authenticated using (true);

-- Denied twice, at both layers, the way every other table in this schema is.
-- The revoke is grant-level; the restrictive policies are the RLS-level denial
-- and they AND together with everything else so `false` is final. Only
-- xnft_confirm_mint writes here, and it is security definer.
revoke insert, update, delete on public.xnft_holdings from anon, authenticated;
revoke insert, update, delete on public.xnft_reveal_order from anon, authenticated;

do $$
declare
  t text;
begin
  foreach t in array array['xnft_holdings', 'xnft_reveal_order'] loop
    execute format('drop policy if exists %I on public.%I', t || ' accepts no client insert', t);
    execute format('drop policy if exists %I on public.%I', t || ' accepts no client update', t);
    execute format('drop policy if exists %I on public.%I', t || ' accepts no client delete', t);
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
-- xnft_mint_status
-- ---------------------------------------------------------------------------
--
-- Everything the mint page needs to decide whether to arm its button, in one
-- round trip. `ok` is false unless the mint is configured AND enabled AND has
-- supply left, and `reason` says which of those failed so the UI can explain
-- itself instead of just refusing.
create or replace function public.xnft_mint_status(p_wallet text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cfg     public.protocol_config;
  v_max     integer := 5000;
  v_issued  integer;
  v_held    integer := 0;
  v_conf    boolean;
  v_reason  text := null;
begin
  select * into v_cfg from public.protocol_config where id = 1;
  select count(*) into v_issued from public.xnft_holdings;

  if p_wallet is not null then
    select count(*) into v_held from public.xnft_holdings where owner = p_wallet;
  end if;

  v_conf := v_cfg.xnft_mint is not null
        and length(trim(v_cfg.xnft_mint)) > 0
        and v_cfg.dev_wallet is not null
        and length(trim(v_cfg.dev_wallet)) > 0;

  -- Ordered most-fundamental first, so the reason names the thing to fix.
  if not v_conf then
    v_reason := 'not-configured';
  elsif not coalesce(v_cfg.minting_enabled, false) then
    v_reason := 'disabled';
  elsif v_issued >= v_max then
    v_reason := 'sold-out';
  end if;

  return jsonb_build_object(
    'ok', v_reason is null,
    'reason', v_reason,
    'configured', v_conf,
    'minting_enabled', coalesce(v_cfg.minting_enabled, false),
    'mint_address', coalesce(v_cfg.xnft_mint, ''),
    'dev_wallet', coalesce(v_cfg.dev_wallet, ''),
    'rpc_url', coalesce(v_cfg.rpc_url, ''),
    'price_tokens', 10000,
    'hold_requirement_tokens', 10000,
    'max_supply', v_max,
    'issued', v_issued,
    'remaining', greatest(0, v_max - v_issued),
    'wallet_holdings', v_held
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- xnft_network_stats
-- ---------------------------------------------------------------------------
create or replace function public.xnft_network_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_max integer := 5000;
begin
  return jsonb_build_object(
    'wallets', (select count(distinct owner) from public.xnft_holdings),
    'issued', (select count(*) from public.xnft_holdings),
    'max_supply', v_max,
    'rarity_total', coalesce((
      select sum(public.xnft_tier_skills(tier)) from public.xnft_holdings
    ), 0),
    -- Every tier is present with a zero rather than omitted, so the client
    -- never has to decide whether a missing key means none or means unknown.
    'tiers', (
      select coalesce(jsonb_object_agg(t, n), '{}'::jsonb)
        from (
          select t, (select count(*) from public.xnft_holdings h where h.tier = t) as n
            from unnest(array['entry', 'mid', 'expert', 'xrated']) as t
        ) counts
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The wallet roll-up, shared by the leaderboard and the wallet page
-- ---------------------------------------------------------------------------
--
-- One view so the two surfaces cannot disagree about somebody's rank. xBoss is
-- read off the rarity score — capital of a sort, not headcount — so a wallet
-- holding one X-RATED outranks one holding three uncommons.
create or replace view public.xnft_ranks
with (security_invoker = true) as
  select
    h.owner as wallet,
    count(*)::integer as holdings,
    sum(public.xnft_tier_skills(h.tier))::integer as rarity_score,
    min(h.minted_at) as first_mint_at,
    (array_agg(h.tier order by public.xnft_tier_skills(h.tier) desc, h.serial asc))[1] as best_tier,
    (array_agg(h.serial order by public.xnft_tier_skills(h.tier) desc, h.serial asc))[1] as best_serial,
    case
      when sum(public.xnft_tier_skills(h.tier)) >= 40 then 'CEO'
      when sum(public.xnft_tier_skills(h.tier)) >= 20 then 'VP'
      when sum(public.xnft_tier_skills(h.tier)) >= 8  then 'DIRECTOR'
      else 'BOSS'
    end as xboss
  from public.xnft_holdings h
  group by h.owner;

grant select on public.xnft_ranks to anon, authenticated;

create or replace function public.xnft_leaderboard(
  p_limit integer default 50,
  p_offset integer default 0,
  p_query text default null
)
returns table (
  rank_position integer,
  wallet text,
  handle text,
  holdings integer,
  rarity_score integer,
  best_tier text,
  best_serial integer,
  xboss text,
  first_mint_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  -- Ranked over the WHOLE table before filtering, so searching for one wallet
  -- shows its real position rather than 1.
  with ranked as (
    select r.*,
           row_number() over (order by r.rarity_score desc, r.first_mint_at asc)::integer as pos
      from public.xnft_ranks r
  )
  select ranked.pos, ranked.wallet, null::text, ranked.holdings, ranked.rarity_score,
         ranked.best_tier, ranked.best_serial, ranked.xboss, ranked.first_mint_at
    from ranked
   where p_query is null or ranked.wallet ilike '%' || p_query || '%'
   order by ranked.pos
   limit greatest(1, least(coalesce(p_limit, 50), 200))
  offset greatest(0, coalesce(p_offset, 0));
$$;

create or replace function public.xnft_wallet(p_wallet text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row record;
begin
  select r.*, row_number() over (order by r.rarity_score desc, r.first_mint_at asc)::integer as pos
    into v_row
    from public.xnft_ranks r
   where r.wallet = p_wallet;

  if not found then
    -- A wallet with no mints is a legitimate answer, not an error. The page
    -- renders an empty crew rather than a failure.
    return jsonb_build_object(
      'ok', false, 'wallet', p_wallet, 'handle', null, 'position', null,
      'holdings', 0, 'rarity_score', 0, 'xboss', null,
      'first_mint_at', null, 'crew', '[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'wallet', v_row.wallet,
    'handle', null,
    'position', v_row.pos,
    'holdings', v_row.holdings,
    'rarity_score', v_row.rarity_score,
    'xboss', v_row.xboss,
    'first_mint_at', v_row.first_mint_at,
    'crew', coalesce((
      select jsonb_agg(jsonb_build_object(
               'serial', h.serial,
               'label', public.xnft_tier_label(h.tier),
               'tier', h.tier,
               'skills', public.xnft_tier_skills(h.tier),
               'rarity_weight', public.xnft_tier_skills(h.tier),
               'minted_at', h.minted_at,
               'signature', h.mint_signature
             ) order by public.xnft_tier_skills(h.tier) desc, h.serial asc)
        from public.xnft_holdings h
       where h.owner = p_wallet
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- xnft_confirm_mint — DELIBERATELY REFUSES
-- ---------------------------------------------------------------------------
--
-- This is the function that decides who receives a serial after real money has
-- moved, and it is the only one here that writes.
--
-- Doing its job means reading a specific transfer, of a specific SPL mint, to a
-- specific wallet, out of a specific Solana transaction — and being certain the
-- same signature can never issue twice. None of that can be written honestly
-- while $XAS does not exist: there is no mint address to check against, no
-- transaction to read, and no way to test that the verifier rejects a payment
-- that did not happen.
--
-- So it refuses, and it refuses as 'pending' rather than 'rejected'. That
-- direction is deliberate and is the same rule src/lib/backend.ts applies to an
-- unrecognised status: telling somebody the mint they paid for did not happen is
-- the one wrong answer that costs them money. 'pending' means "not yet", which
-- is exactly true.
--
-- The unique constraint on mint_signature is already in place, so whatever
-- verification body replaces this cannot double-issue on a replayed signature.
create or replace function public.xnft_confirm_mint(p_signature text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg public.protocol_config;
  v_existing public.xnft_holdings;
begin
  -- A signature already recorded is answered from the table, not re-verified.
  -- This is the branch that makes retrying safe, and it works today.
  select * into v_existing from public.xnft_holdings where mint_signature = p_signature;
  if found then
    return jsonb_build_object(
      'ok', true, 'status', 'duplicate', 'reason', null,
      'message', 'That payment has already been credited.',
      'buyer', v_existing.owner,
      'assignment', jsonb_build_object(
        'status', 'issued',
        'serial', v_existing.serial,
        'label', public.xnft_tier_label(v_existing.tier),
        'tier', v_existing.tier,
        'held_reason', null
      )
    );
  end if;

  select * into v_cfg from public.protocol_config where id = 1;

  if v_cfg.xnft_mint is null or length(trim(v_cfg.xnft_mint)) = 0 then
    return jsonb_build_object(
      'ok', false, 'status', 'pending', 'reason', 'not-configured',
      'message', 'The token is not live yet, so no payment can be verified. Nothing was written.',
      'buyer', null, 'assignment', null
    );
  end if;

  -- Configured but unimplemented. Still 'pending', still writes nothing.
  return jsonb_build_object(
    'ok', false, 'status', 'pending', 'reason', 'verifier-not-deployed',
    'message', 'Payment verification is not deployed yet. Your signature is safe — keep it. Nothing was written.',
    'buyer', null, 'assignment', null
  );
end;
$$;

-- Callable by an unauthenticated visitor: the mint page is public and the
-- functions are security definer, which is what lets them read config and
-- holdings without publishing either table's write access.
grant execute on function public.xnft_tier_for(integer, integer) to anon, authenticated;
grant execute on function public.xnft_tier_skills(text) to anon, authenticated;
grant execute on function public.xnft_tier_label(text) to anon, authenticated;
grant execute on function public.xnft_mint_status(text) to anon, authenticated;
grant execute on function public.xnft_network_stats() to anon, authenticated;
grant execute on function public.xnft_leaderboard(integer, integer, text) to anon, authenticated;
grant execute on function public.xnft_wallet(text) to anon, authenticated;
grant execute on function public.xnft_confirm_mint(text) to anon, authenticated;

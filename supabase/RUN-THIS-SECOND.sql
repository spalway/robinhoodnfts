-- =========================================================================
-- xNFTs — complete database setup, part 2 of 2
-- =========================================================================
--
-- Run this AFTER RUN-THIS-FIRST.sql.
--
-- This creates protocol_config: the single row holding your contract address,
-- project wallet, treasury and market links. Nothing on the site arms until
-- that row is filled in.
--
-- After running this, go to Table Editor -> protocol_config and edit the row.
-- Changes take effect on the live site within about 15 seconds. No redeploy.
--
-- Kept separate from part 1 on purpose: this is the file you may want to
-- re-run, and bundling it would mean re-running a megabyte of seed data to
-- change one address.
-- =========================================================================


-- Runtime deployment configuration.
--
-- These values used to be VITE_ variables, which meant they were compiled into
-- the bundle at build time. Changing the mint address therefore required a
-- rebuild and a redeploy — minutes of downtime for a one-field edit, and no way
-- to correct a wrong address in a hurry. That is the wrong shape for the single
-- value that decides where real money goes.
--
-- They live here instead. An operator edits this row in the Supabase table
-- editor and every browser picks it up within one poll interval, with no deploy.
--
-- What did NOT move: the Supabase URL and anon key stay build-time variables,
-- because they are what a browser needs in order to reach this table at all. A
-- config that told you how to find itself would be a circular dependency.

create table if not exists public.protocol_config (
  -- Single-row table. The check constraint is the enforcement: a second row
  -- would give two browsers two different mint addresses depending on which one
  -- their query happened to return first.
  id smallint primary key default 1 check (id = 1),

  -- The $xNFT SPL mint. THE most important value in this database: it decides
  -- which token a buyer's wallet is asked to send. Empty means "not launched",
  -- and every mint path refuses while it is empty rather than guessing.
  xnft_mint text not null default '',

  -- Where a mint's 10,000 $xNFT lands. Also empty-by-default, and also a hard
  -- refusal when unset — there is no safe fallback for "where does the money go".
  dev_wallet text not null default '',

  -- Simulated marketplace fees only. Nothing real touches this yet.
  treasury_wallet text not null default '',

  -- The Solana RPC the BROWSER uses. Empty falls back to the public
  -- mainnet-beta endpoint, which Solana Labs documents as development-only and
  -- which throttles hard — fine for a site nobody is using, not fine on the
  -- confirmation poll of a mint somebody has already signed and paid for.
  --
  -- Here rather than in a build-time variable for the same reason the mint
  -- address is: swapping providers during an outage must not require a redeploy.
  --
  -- NOT a secret. It ships to every browser and anyone can read it out of the
  -- bundle, which is normal for RPC — restrict the key to your domain in the
  -- provider's dashboard. The Edge Functions read their own SOLANA_RPC_URL
  -- secret and that one should be a DIFFERENT key, because it is genuinely
  -- private and is used to build payout transactions.
  rpc_url text not null default '',

  pump_fun_url text not null default '',
  dexscreener_url text not null default '',
  support_handle text not null default 'xnfts_network',

  -- Lets an operator take the mint offline without clearing the address, which
  -- would otherwise be the only way to stop it and would lose the value.
  minting_enabled boolean not null default true,

  updated_at timestamptz not null default now()
);

-- `create table if not exists` above is a no-op on a database that already has
-- this table, so a column added later would never appear on one. This is what
-- actually installs rpc_url for anyone who ran an earlier version of this file.
alter table public.protocol_config add column if not exists rpc_url text not null default '';

insert into public.protocol_config (id) values (1) on conflict (id) do nothing;

alter table public.protocol_config enable row level security;

-- Readable by anyone. These are all public facts: a mint address and a payee
-- wallet are visible in every transaction the site produces, so hiding them here
-- while publishing them on-chain would protect nothing and would only stop the
-- site from working.
drop policy if exists protocol_config_read on public.protocol_config;
create policy protocol_config_read
  on public.protocol_config
  for select
  to anon, authenticated
  using (true);

-- BOTH are required, and this line was missing.
--
-- An RLS policy decides WHICH ROWS a role may see. It does not grant the role
-- permission to touch the table at all — that is a separate GRANT, and without
-- it Postgres refuses before RLS is ever consulted. PostgREST returns
--   401  42501  permission denied for table protocol_config
-- which reads like an auth problem and is not one.
--
-- The seven original tables get this in 20260805120200_rls_policies.sql.
-- protocol_config was added later and did not follow the pattern, so on a fresh
-- database every browser silently fell back to a disarmed config: no mint
-- address, no project wallet, no RPC, no market links.
grant select on public.protocol_config to anon, authenticated;

-- Writes are denied twice, at two different layers, and BOTH are needed.
--
-- The revoke is a grant-level control. The three restrictive policies are the
-- RLS-level one: restrictive policies AND together with everything else, so
-- `false` is final and no permissive policy added later can grant a client
-- write. They also show up in \d output instead of being an absence a reviewer
-- has to notice.
--
-- This table originally had only the revoke. Every other table in the schema
-- carries the restrictive trio — the first seven by hand in
-- 20260805120200_rls_policies.sql, the next twenty-three in a loop in
-- 20260806091100 — and that second file ends with an assertion that walks every
-- table in `public` and raises if one is missing them. protocol_config was
-- written after it, did not follow the pattern, and so aborted the whole final
-- migration with
--   P0001: table public.protocol_config is missing a restrictive write denial
revoke insert, update, delete on public.protocol_config from anon, authenticated;

create policy "protocol_config accepts no client insert" on public.protocol_config
  as restrictive for insert to anon, authenticated with check (false);
create policy "protocol_config accepts no client update" on public.protocol_config
  as restrictive for update to anon, authenticated using (false) with check (false);
create policy "protocol_config accepts no client delete" on public.protocol_config
  as restrictive for delete to anon, authenticated using (false);

comment on table public.protocol_config is
  'Single-row runtime config. Edited by the operator in the dashboard; read by every browser. Never writable with the anon key.';

create or replace function public.touch_protocol_config()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists protocol_config_touch on public.protocol_config;
create trigger protocol_config_touch
  before update on public.protocol_config
  for each row execute function public.touch_protocol_config();

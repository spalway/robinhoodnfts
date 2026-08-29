// Emit the genesis seed from the JS source of truth.
//
// This has shrunk twice. It began as a hand-written 512 xployees across 97
// invented wallets, became 35 held by the project wallet, and is now the one
// holding the protocol actually has on its first day. Importing the same
// `collection()` the browser renders is what keeps the database and the app
// from drifting — regenerate rather than edit.
//
//   npx vite-node scripts/gen-genesis-seed.ts
import { writeFileSync } from 'node:fs'
import { collection, HIRED_COUNT } from '../src/lib/collection'
import { serial } from '../src/lib/xployee'

const OUT =
  'C:/Users/skizp/crypto/new_projects/xnfts/supabase/migrations/20260806090500_seed_xnet_genesis.sql'

/**
 * Placeholder owner.
 *
 * The real owner is the project wallet, whose address lives in
 * `protocol_config` and is not known when this migration is written — it is set
 * by an operator after deploy. Seeding a literal here would bake in whatever
 * address happened to be current, and a stale owner on a money-adjacent table is
 * worse than an obviously-unset one.
 *
 * `assign_genesis_crew()` below resolves it. Until it is run, these rows are
 * owned by a string that is visibly not a wallet, which is the correct reading:
 * ownership has not been claimed yet.
 */
const SENTINEL = 'GENESIS-UNASSIGNED'

const crew = collection()

const rows = crew
  .map((x) => `  (${x.id}, '${SENTINEL}', ${Math.round(x.hiredAt)})`)
  .join(',\n')

const summary = crew.map((x) => `${serial(x.id)} ${x.tier.label}`).join(', ')

const sql = `-- xNFTs index — seed: the genesis holding.
--
-- ${HIRED_COUNT} xployee: ${summary}, held by the project wallet.
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
-- everything else so \`false\` is final. Every other table in the schema carries
-- this trio, and 20260806091100_rls_policies.sql ends with an assertion that
-- walks every table in \`public\` and raises if one is missing it — so a table
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
${rows}
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
`

writeFileSync(OUT, sql)
console.log(`wrote ${crew.length} genesis row(s) -> ${OUT.split('/').pop()}`)
console.log(`serials: ${crew.map((x) => `${serial(x.id)} ${x.tier.label}`).join(', ')}`)

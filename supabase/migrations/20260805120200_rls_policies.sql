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

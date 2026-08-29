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

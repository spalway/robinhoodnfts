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

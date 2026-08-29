-- =========================================================================
-- xNFTs database setup — PART 08 of 08
-- =========================================================================
--
-- Run these IN ORDER, one at a time, in the Supabase SQL Editor.
-- Wait for each to finish before starting the next.
--
-- Split only at statement boundaries, so no statement is cut in half. Safe to
-- re-run: every statement uses "if not exists", "or replace", or
-- "on conflict do nothing".
--
-- After all 08 parts, run RUN-THIS-SECOND.sql (protocol_config).
-- =========================================================================

create or replace function public.send_friend_request(p_user_id uuid, p_to text, p_message text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from text;
  v_pair text[];
  v_id   uuid;
begin
  v_from := public.actor_wallet(p_user_id);
  if v_from is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was sent.');
  end if;
  if p_to is null or p_to = v_from then
    return jsonb_build_object('ok', false, 'code', 'bad-target',
      'message', 'A friend request needs somebody else to send it to. Nothing was sent.');
  end if;

  v_pair := public.pair_key(v_from, p_to);
  if exists (select 1 from public.friendships where wallet_a = v_pair[1] and wallet_b = v_pair[2]) then
    return jsonb_build_object('ok', false, 'code', 'already-friends',
      'message', 'These wallets are already connected. Nothing was sent.');
  end if;

  -- A pending request in EITHER direction is already an open question, and the
  -- partial unique index would refuse the insert anyway. Answering here turns a
  -- constraint violation into the correct sentence.
  if exists (
    select 1 from public.friend_requests
     where status = 'pending'
       and least(requester, addressee) = v_pair[1]
       and greatest(requester, addressee) = v_pair[2]
  ) then
    return jsonb_build_object('ok', false, 'code', 'already-open',
      'message', 'There is already an open request between these wallets. Nothing was sent.');
  end if;

  insert into public.friend_requests (requester, addressee, message)
  values (v_from, p_to, nullif(btrim(coalesce(p_message, '')), ''))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'request_id', v_id);
end;
$$;

create or replace function public.respond_to_friend_request(
  p_user_id uuid,
  p_request_id uuid,
  p_accept boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   text;
  v_req  public.friend_requests;
  v_pair text[];
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  -- Locked before it is read, so two clicks cannot both accept and produce two
  -- friendship inserts racing on the same primary key.
  select * into v_req from public.friend_requests where id = p_request_id for update;
  if not found or v_req.addressee <> v_me or v_req.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'not-answerable',
      'message', 'That request is not open, or it was not addressed to this wallet. Nothing was changed.');
  end if;

  update public.friend_requests
     set status = case when p_accept then 'accepted' else 'declined' end,
         responded_at = now()
   where id = p_request_id;

  if p_accept then
    v_pair := public.pair_key(v_req.requester, v_req.addressee);
    insert into public.friendships (wallet_a, wallet_b, request_id)
    values (v_pair[1], v_pair[2], p_request_id)
    on conflict (wallet_a, wallet_b) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'accepted', p_accept);
end;
$$;

-- Removing a friend leaves the accepted request behind as history, matching
-- `removeFriend` in src/lib/social.ts — and for the same reason: a later re-add
-- would otherwise be refused as a duplicate of a relationship that no longer
-- exists.
create or replace function public.remove_friend(p_user_id uuid, p_other text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me   text;
  v_pair text[];
  v_hit  integer;
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  v_pair := public.pair_key(v_me, p_other);
  delete from public.friendships where wallet_a = v_pair[1] and wallet_b = v_pair[2];
  get diagnostics v_hit = row_count;

  return jsonb_build_object('ok', v_hit > 0, 'removed', v_hit > 0);
end;
$$;

-- Opens the thread if it does not exist yet, then writes the message. One
-- function, because "create a conversation" is not a thing a user does — sending
-- the first message is.
create or replace function public.send_message(p_user_id uuid, p_to text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from   text;
  v_pair   text[];
  v_thread uuid;
  v_body   text := btrim(coalesce(p_body, ''));
  v_id     uuid;
begin
  v_from := public.actor_wallet(p_user_id);
  if v_from is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was sent.');
  end if;
  if p_to is null or p_to = v_from then
    return jsonb_build_object('ok', false, 'code', 'bad-target',
      'message', 'A message needs somebody else to send it to. Nothing was sent.');
  end if;
  if length(v_body) = 0 or length(v_body) > 500 then
    return jsonb_build_object('ok', false, 'code', 'bad-body',
      'message', 'A message is 1–500 characters. Nothing was sent.');
  end if;

  v_pair := public.pair_key(v_from, p_to);

  -- `on conflict do nothing` then select, rather than select then insert: two
  -- first messages arriving together would otherwise both find no thread and both
  -- try to create one.
  insert into public.threads (participant_a, participant_b)
  values (v_pair[1], v_pair[2])
  on conflict (participant_a, participant_b) do nothing;

  select id into v_thread from public.threads
   where participant_a = v_pair[1] and participant_b = v_pair[2];

  insert into public.messages (thread_id, sender, body)
  values (v_thread, v_from, v_body)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'thread_id', v_thread, 'message_id', v_id);
end;
$$;

create or replace function public.mark_thread_read(p_user_id uuid, p_thread_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me  text;
  v_hit integer;
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;

  -- `sender <> v_me` is what stops a caller marking their OWN messages read,
  -- which would clear the counterparty's unread badge from the wrong side.
  update public.messages m
     set read_at = now()
    from public.threads t
   where m.thread_id = p_thread_id
     and t.id = m.thread_id
     and (t.participant_a = v_me or t.participant_b = v_me)
     and m.sender <> v_me
     and m.read_at is null;
  get diagnostics v_hit = row_count;

  return jsonb_build_object('ok', true, 'marked', v_hit);
end;
$$;

-- ---------------------------------------------------------------------------
-- Trade offers
-- ---------------------------------------------------------------------------

-- The legs are validated against real ownership at send time. An offer for units
-- the sender does not hold, or a request for units the recipient does not hold,
-- is a lie — and it stays a lie whether or not anything ever settles it, so it is
-- refused here rather than left for a UI to notice.
create or replace function public.send_trade_offer(
  p_user_id    uuid,
  p_to         text,
  p_offering   bigint[],
  p_requesting bigint[],
  p_sweetener_from_sender    text default '0',
  p_sweetener_from_recipient text default '0',
  p_note       text default null,
  p_ttl_hours  integer default 168
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from      text;
  v_offer     uuid;
  v_offering  bigint[] := coalesce(p_offering, '{}');
  v_request   bigint[] := coalesce(p_requesting, '{}');
  v_from_cash text := coalesce(nullif(p_sweetener_from_sender, ''), '0');
  v_to_cash   text := coalesce(nullif(p_sweetener_from_recipient, ''), '0');
  v_bad       bigint;
begin
  v_from := public.actor_wallet(p_user_id);
  if v_from is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was offered.');
  end if;
  if p_to is null or p_to = v_from then
    return jsonb_build_object('ok', false, 'code', 'bad-target',
      'message', 'An offer needs a counterparty. Nothing was offered.');
  end if;
  if v_from_cash !~ '^(0|[1-9][0-9]{0,19})$' or v_to_cash !~ '^(0|[1-9][0-9]{0,19})$' then
    return jsonb_build_object('ok', false, 'code', 'bad-sweetener',
      'message', 'A sweetener is raw units as a decimal string. Nothing was offered.');
  end if;
  if v_from_cash <> '0' and v_to_cash <> '0' then
    return jsonb_build_object('ok', false, 'code', 'two-way-cash',
      'message', '$xNFT moves one way in a trade. Set one side to zero; nothing was offered.');
  end if;
  -- An offer that moves nothing in either direction is not an offer.
  if array_length(v_offering, 1) is null and array_length(v_request, 1) is null
     and v_from_cash = '0' and v_to_cash = '0' then
    return jsonb_build_object('ok', false, 'code', 'empty-offer',
      'message', 'That offer moves nothing in either direction. Nothing was offered.');
  end if;
  if coalesce(array_length(v_offering, 1), 0) + coalesce(array_length(v_request, 1), 0) > 20 then
    return jsonb_build_object('ok', false, 'code', 'too-many-legs',
      'message', 'An offer carries at most 20 xployees across both sides. Nothing was offered.');
  end if;

  -- The same unit cannot be on both sides. The legs table's primary key would
  -- refuse the second insert; saying so here is the difference between an
  -- explanation and a constraint violation.
  if exists (select 1 from unnest(v_offering) as t(o) where t.o = any (v_request)) then
    return jsonb_build_object('ok', false, 'code', 'same-unit-both-sides',
      'message', 'An xployee cannot be both offered and requested. Nothing was offered.');
  end if;

  select t.o into v_bad
    from unnest(v_offering) as t(o)
   where not exists (select 1 from public.xployees x where x.id = t.o and x.owner = v_from)
   limit 1;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'code', 'not-owned',
      'message', format('This wallet does not own %s. Nothing was offered.', public.serial_label(v_bad)));
  end if;

  select t.r into v_bad
    from unnest(v_request) as t(r)
   where not exists (select 1 from public.xployees x where x.id = t.r and x.owner = p_to)
   limit 1;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'code', 'not-held-by-counterparty',
      'message', format('That offer asks for %s, which the counterparty does not hold. Nothing was offered.', public.serial_label(v_bad)));
  end if;

  insert into public.trade_offers (
    sender, recipient, note, sweetener_from_sender, sweetener_from_recipient, expires_at
  ) values (
    v_from, p_to, nullif(btrim(coalesce(p_note, '')), ''), v_from_cash, v_to_cash,
    now() + make_interval(hours => greatest(1, least(coalesce(p_ttl_hours, 168), 720)))
  )
  returning id into v_offer;

  insert into public.trade_offer_legs (offer_id, xployee_id, side)
  select v_offer, t.o, 'offered' from unnest(v_offering) as t(o)
  union all
  select v_offer, t.r, 'requested' from unnest(v_request) as t(r);

  return jsonb_build_object('ok', true, 'offer_id', v_offer);
end;
$$;

-- Resolve an offer.
--
-- Accepting RECORDS A DECISION. It moves nothing — see the header. The status is
-- the whole effect, and the two parties settle between themselves through the
-- marketplace, where `buy_listing` does the ownership checks and the locking that
-- a real transfer needs.
create or replace function public.respond_to_trade_offer(
  p_user_id  uuid,
  p_offer_id uuid,
  p_status   text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me    text;
  v_offer public.trade_offers;
begin
  v_me := public.actor_wallet(p_user_id);
  if v_me is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was changed.');
  end if;
  if p_status not in ('accepted', 'declined', 'withdrawn') then
    return jsonb_build_object('ok', false, 'code', 'bad-status',
      'message', 'An offer is accepted, declined or withdrawn. Nothing was changed.');
  end if;

  select * into v_offer from public.trade_offers where id = p_offer_id for update;
  if not found or v_offer.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'not-open',
      'message', 'That offer is not open. Nothing was changed.');
  end if;

  -- You withdraw your own offers and you accept or decline everyone else's.
  -- Getting this backwards would let a sender "accept" their own proposal.
  if p_status = 'withdrawn' then
    if v_offer.sender <> v_me then
      return jsonb_build_object('ok', false, 'code', 'not-yours',
        'message', 'Only the sender can withdraw an offer. Nothing was changed.');
    end if;
  elsif v_offer.recipient <> v_me then
    return jsonb_build_object('ok', false, 'code', 'not-yours',
      'message', 'That offer was not addressed to this wallet. Nothing was changed.');
  end if;

  update public.trade_offers set status = p_status, responded_at = now() where id = p_offer_id;

  return jsonb_build_object(
    'ok', true,
    'status', p_status,
    -- Said in the response so no caller can render an acceptance as a settlement.
    'settled', false,
    'note', 'Accepting records the decision. Nothing changed hands — there is no escrow, so the two wallets settle through the marketplace.'
  );
end;
$$;

-- Offers that ran out. Idempotent and safe to schedule; nothing depends on it
-- having run, because a caller reading a pending offer past its expiry can see
-- the timestamp for itself.
create or replace function public.expire_trade_offers()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_gone integer;
begin
  update public.trade_offers
     set status = 'expired', responded_at = now()
   where status = 'pending' and expires_at is not null and expires_at <= now();
  get diagnostics v_gone = row_count;
  return v_gone;
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.send_friend_request(uuid, text, text) from public, anon, authenticated;
revoke all on function public.respond_to_friend_request(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.remove_friend(uuid, text) from public, anon, authenticated;
revoke all on function public.send_message(uuid, text, text) from public, anon, authenticated;
revoke all on function public.mark_thread_read(uuid, uuid) from public, anon, authenticated;
revoke all on function public.send_trade_offer(uuid, text, bigint[], bigint[], text, text, text, integer) from public, anon, authenticated;
revoke all on function public.respond_to_trade_offer(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.expire_trade_offers() from public, anon, authenticated;

grant execute on function public.send_friend_request(uuid, text, text) to service_role;
grant execute on function public.respond_to_friend_request(uuid, uuid, boolean) to service_role;
grant execute on function public.remove_friend(uuid, text) to service_role;
grant execute on function public.send_message(uuid, text, text) to service_role;
grant execute on function public.mark_thread_read(uuid, uuid) to service_role;
grant execute on function public.send_trade_offer(uuid, text, bigint[], bigint[], text, text, text, integer) to service_role;
grant execute on function public.respond_to_trade_offer(uuid, uuid, text) to service_role;
grant execute on function public.expire_trade_offers() to service_role;

grant execute on function public.pair_key(text, text) to public;


-- =========================================================================
-- SECTION 15 of 16 — 20260806091000_payout_requests.sql
-- =========================================================================

-- xNFTs index — payout_requests: the SOL claim queue the admin desk works.
--
-- ===========================================================================
-- THIS IS NOT public.payouts. READ THIS BEFORE USING EITHER.
-- ===========================================================================
-- Two queues exist and they are about different money moving in different
-- directions. Confusing them would let a holder's claim be settled by a
-- transaction that paid the dev wallet, so they are separate tables with
-- separate writers and no shared status vocabulary.
--
--   public.payouts          — the OPERATOR sweeping $xNFT fees out of the
--                             treasury to the dev wallet. One signer, one
--                             destination read from configuration, settled by
--                             `confirm-payout` re-reading the chain. Money
--                             leaving the protocol.
--   public.payout_requests  — a HOLDER asking to be paid their accrued yield, in
--                             SOL, out of pump.fun creator fees. Money arriving
--                             at a user. There is no automated settlement and
--                             there is not going to be one: an operator sends the
--                             SOL by hand from a wallet this backend does not
--                             hold a key for, and then records the signature.
--
-- ===========================================================================
-- WHAT A REQUEST IS AND IS NOT
-- ===========================================================================
-- It is a ticket. `src/lib/earnings.ts` computes the claimable figure from
-- accrual — a pure function of hire time and skills — and mints a human-readable
-- claim id (`XN-A3K7M-9PQR2`, Crockford base32 with I/L/O/U removed so it
-- survives being read down a phone line). The row here is that ticket.
--
-- It is NOT an instruction to a machine. Nothing in this schema can move SOL, no
-- function here signs anything, and `status = 'paid'` is a statement an operator
-- makes about a transfer they performed — recorded with its signature so anybody
-- can go and check it, which is the only kind of verification available when the
-- paying key never comes near this system.
--
-- ===========================================================================
-- THE AMOUNT
-- ===========================================================================
-- Two figures, and the distinction is the same one `public.payouts` draws.
--
--   `amount_usd`      — the USD the requester was shown when they clicked. A
--                       display notional in exact decimal; it gates nothing.
--   `amount_lamports` — the SOL figure, in raw units as a digit string. This is
--                       the money column, and it is a u64_text for the reason the
--                       domain exists: PostgREST serialises numeric as a JSON
--                       number and a lamport figure that has been through a
--                       double is a lamport figure that is wrong.
--   `paid_lamports`   — what actually went out, filled in with the signature.
--                       NULL until then, so "requested" and "paid" can never be
--                       read as the same number.

create table public.payout_requests (
  -- The claim id IS the primary key. It is what a support ticket is resolved by
  -- and what a user reads out loud, so giving the row a uuid alongside it would
  -- create a second identity for the same thing and an opportunity for the two to
  -- be quoted at each other.
  --
  -- The pattern is CLAIM_ID_RE from src/lib/earnings.ts, restated here rather
  -- than assumed: an id generated by some other client still has to look like one
  -- of ours or it cannot enter the queue.
  claim_id text primary key check (claim_id ~ '^XN-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$'),

  wallet public.base58_address not null,

  amount_usd      numeric(20, 2)   not null check (amount_usd > 0),
  amount_lamports public.u64_text  not null,
  -- The rate the quote was made at, so a settled ticket can be read back years
  -- later without wondering what SOL was worth that afternoon. Display only.
  sol_usd_at_request numeric(20, 6) not null check (sol_usd_at_request > 0),

  --   pending   — in the queue, nobody has looked at it.
  --   approved  — an operator has accepted it and intends to pay. Not money yet.
  --   paid      — SOL was sent; the signature is on the row.
  --   rejected  — an operator declined it, with a reason.
  --   cancelled — the requester withdrew it before it was settled.
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'paid', 'rejected', 'cancelled')),

  -- The SOL transfer. Not a foreign key to anything and not verified by this
  -- backend — it is a Solana signature on a transaction sent from a wallet whose
  -- key lives with the operator. Unique, so one transfer cannot be used to settle
  -- two tickets.
  signature     public.tx_signature unique,
  paid_lamports public.u64_text,

  -- Free text from whoever worked the ticket. Visible to the requester, so it is
  -- an explanation rather than an internal note — a rejection with no sentence
  -- attached is how a support queue turns into a grievance.
  operator_note text check (operator_note is null or length(operator_note) <= 500),

  requested_at timestamptz not null default now(),
  reviewed_at  timestamptz,
  paid_at      timestamptz,
  updated_at   timestamptz not null default now(),

  -- 'paid' is reachable only with the evidence. Three columns move together or
  -- the row is refused, which makes "we only mark it paid once it is paid" a
  -- property of the table rather than of the endpoint that writes it.
  constraint payout_requests_paid_has_evidence check (
    (status = 'paid' and signature is not null and paid_lamports is not null and paid_at is not null)
    or (status <> 'paid' and signature is null and paid_lamports is null and paid_at is null)
  ),
  -- A rejection carries its reason. Without this, a declined ticket can sit in
  -- somebody's history with no explanation and no way to get one.
  constraint payout_requests_rejection_has_reason check (
    status <> 'rejected' or operator_note is not null
  ),
  -- Anything an operator has touched says when.
  constraint payout_requests_reviewed_has_timestamp check (
    status in ('pending', 'cancelled') or reviewed_at is not null
  )
);

-- ONE OPEN REQUEST PER WALLET, as a constraint rather than as a check somebody
-- performs. This is the same shape as the mint reservation index and it is doing
-- the same job: two clicks arriving together cannot both open a ticket, so a
-- wallet cannot get its accrued yield queued twice and paid twice by an operator
-- working down a list.
create unique index payout_requests_one_open_per_wallet
  on public.payout_requests (wallet) where status in ('pending', 'approved');

create index payout_requests_queue_idx  on public.payout_requests (status, requested_at asc);
create index payout_requests_wallet_idx on public.payout_requests (wallet, requested_at desc);

comment on table public.payout_requests is
  'Holders asking to be paid their accrued yield in SOL from pump.fun creator fees. A ticket, not an instruction: nothing here can move SOL, and ''paid'' is an operator recording a transfer they made by hand, with its signature.';
comment on column public.payout_requests.claim_id is
  'The id a human reads out. Crockford base32 with I, L, O and U removed so 1/I and 0/O are never both drawable — see CLAIM_ID_RE in src/lib/earnings.ts.';
comment on column public.payout_requests.signature is
  'The SOL transfer an operator sent. This backend does NOT verify it — the paying key never touches this system — so it is published for anyone to check rather than presented as something the server confirmed.';
comment on column public.payout_requests.amount_lamports is
  'The money column, in raw units. amount_usd beside it is a display notional and gates nothing.';

-- ---------------------------------------------------------------------------
-- Operator identity
-- ---------------------------------------------------------------------------

-- Who may work the queue. A table rather than a hard-coded address, so adding or
-- removing an operator is an INSERT and not a deploy — and so the answer to "who
-- could have marked this paid" is a query rather than an archaeology exercise
-- through old builds.
--
-- Seeded EMPTY on purpose, which is the same discipline as every deployment
-- constant in src/lib/spl.ts: with no rows, every operator action refuses. An
-- operator is added deliberately, once, by somebody with database access.
create table public.operators (
  wallet     public.base58_address primary key,
  label      text,
  can_pay    boolean not null default true,
  added_at   timestamptz not null default now(),
  removed_at timestamptz
);

comment on table public.operators is
  'Wallets allowed to work the payout queue. Ships EMPTY, so every operator path refuses until somebody with database access adds a row — the same "unset means disabled" rule the deployment constants follow.';

create or replace function public.is_operator(p_wallet text)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.operators
     where wallet = p_wallet and removed_at is null and can_pay
  )
$$;

-- ---------------------------------------------------------------------------
-- request_payout — the holder's side
-- ---------------------------------------------------------------------------

-- The wallet comes from the session, never from the caller. The claim id and the
-- amount DO come from the client, and that is worth being honest about rather
-- than dressing up: accrual is computed in the browser from a deterministic
-- function of hire time and skills, so the figure a request carries is the
-- browser's arithmetic.
--
-- What the database enforces around it:
--
--   * the requester owns at least one xployee — you cannot claim yield from an
--     empty wallet;
--   * the amount does not exceed what this wallet's holdings could possibly have
--     accrued, recomputed HERE from `principal x apy x tenure` and net of
--     everything already requested. This is the check that matters: it does not
--     trust the client's number, it bounds it;
--   * one open ticket per wallet, by unique index.
--
-- The bound is generous by construction — it ignores rentals redirecting yield,
-- so it can only ever be too permissive rather than too strict, and a holder is
-- never refused money they are owed because of a rounding difference between two
-- languages. An operator still reviews every ticket. That is the actual control,
-- and this function's job is to stop the queue filling with impossible numbers.
create or replace function public.request_payout(
  p_user_id     uuid,
  p_claim_id    text,
  p_amount_usd  numeric,
  p_sol_usd     numeric
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet    text;
  v_accrued   numeric;
  v_requested numeric;
  v_lamports  numeric;
  v_crew      integer;
begin
  v_wallet := public.actor_wallet(p_user_id);
  if v_wallet is null then
    return jsonb_build_object('ok', false, 'code', 'no-wallet',
      'message', 'This session has no linked wallet. Nothing was requested.');
  end if;
  if p_claim_id is null or p_claim_id !~ '^XN-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$' then
    return jsonb_build_object('ok', false, 'code', 'bad-claim-id',
      'message', 'That is not a claim id. Nothing was requested.');
  end if;
  if p_amount_usd is null or p_amount_usd <= 0 then
    return jsonb_build_object('ok', false, 'code', 'bad-amount',
      'message', 'A request has to be for a positive amount. Nothing was requested.');
  end if;
  if p_sol_usd is null or p_sol_usd <= 0 then
    return jsonb_build_object('ok', false, 'code', 'bad-rate',
      'message', 'A request has to carry the SOL price it was quoted at. Nothing was requested.');
  end if;

  -- Idempotent on the claim id: a retried post finds its own ticket rather than
  -- opening a second one, and the partial unique index would refuse the second
  -- anyway.
  if exists (select 1 from public.payout_requests where claim_id = p_claim_id) then
    return jsonb_build_object('ok', true, 'outcome', 'duplicate', 'claim_id', p_claim_id);
  end if;

  select count(*),
         coalesce(sum(
           x.principal * x.apy
             * greatest(0, extract(epoch from (now() - x.hired_at))) / (86400 * 365)
         ), 0)
    into v_crew, v_accrued
    from public.xployees x
   where x.owner = v_wallet and x.hired_at is not null;

  if v_crew = 0 then
    return jsonb_build_object('ok', false, 'code', 'no-crew',
      'message', 'This wallet holds no xployees, so nothing has accrued to it. Nothing was requested.');
  end if;

  -- Everything already spoken for. A rejected ticket releases its amount back;
  -- anything else — pending, approved or paid — is money this wallet has already
  -- asked for, matching requestedUsd() in src/lib/earnings.ts.
  select coalesce(sum(amount_usd), 0) into v_requested
    from public.payout_requests
   where wallet = v_wallet and status <> 'rejected' and status <> 'cancelled';

  if p_amount_usd > greatest(0, v_accrued - v_requested) + 0.01 then
    return jsonb_build_object(
      'ok', false, 'code', 'over-accrual',
      'message', format(
        'This wallet''s crew has accrued about $%s and $%s of that is already spoken for, so $%s cannot be claimed. Nothing was requested.',
        round(v_accrued, 2), round(v_requested, 2), round(p_amount_usd, 2))
    );
  end if;

  if exists (select 1 from public.payout_requests where wallet = v_wallet and status in ('pending', 'approved')) then
    return jsonb_build_object('ok', false, 'code', 'already-open',
      'message', 'This wallet already has a request in the queue. It has to be settled before another can be opened.');
  end if;

  -- USD to lamports at the quoted rate, floored. Flooring is the deliberate
  -- direction here as everywhere else in this codebase: a request never asks for
  -- a lamport more than the quote supports.
  v_lamports := trunc(p_amount_usd / p_sol_usd * 1000000000);

  insert into public.payout_requests (claim_id, wallet, amount_usd, amount_lamports, sol_usd_at_request)
  values (p_claim_id, v_wallet, round(p_amount_usd, 2), v_lamports::text, p_sol_usd);

  return jsonb_build_object(
    'ok', true, 'outcome', 'queued',
    'claim_id', p_claim_id,
    'amount_usd', round(p_amount_usd, 2),
    'amount_lamports', v_lamports::text
  );
end;
$$;

-- The requester withdrawing their own ticket. Only while it is still open — once
-- an operator has paid it there is a transfer on a ledger somewhere, and a row
-- that says 'cancelled' next to a signature would be a lie about money that moved.
create or replace function public.cancel_payout_request(p_user_id uuid, p_claim_id text)
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

  update public.payout_requests
     set status = 'cancelled', updated_at = now()
   where claim_id = p_claim_id and wallet = v_wallet and status = 'pending';
  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'code', 'not-cancellable',
      'message', 'That claim is not this wallet''s, or it is no longer pending. Nothing was changed.');
  end if;
  return jsonb_build_object('ok', true, 'claim_id', p_claim_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_payout_request — the operator's side
-- ---------------------------------------------------------------------------

-- Approve, reject, or record a payment. The operator is resolved from the session
-- and checked against `public.operators`, so authority is a row in a table rather
-- than a comparison against a constant compiled into a bundle.
--
-- Marking a ticket paid REQUIRES the signature and the lamport figure. Not
-- because this backend can verify them — it cannot, the paying key is not here —
-- but because a settled row without them is unauditable, and an unauditable
-- payout record is worse than none: it is a claim of payment that nobody can
-- check and nobody can disprove.
create or replace function public.resolve_payout_request(
  p_user_id   uuid,
  p_claim_id  text,
  p_status    text,
  p_note      text default null,
  p_signature text default null,
  p_lamports  text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operator text;
  v_row      public.payout_requests;
begin
  v_operator := public.actor_wallet(p_user_id);
  if v_operator is null or not public.is_operator(v_operator) then
    -- One sentence for "not signed in" and "not an operator" alike. Telling an
    -- unauthorised caller which of the two they failed is telling them how to
    -- fix it.
    return jsonb_build_object('ok', false, 'code', 'not-operator',
      'message', 'This session is not an operator of the payout queue. Nothing was changed.');
  end if;
  if p_status not in ('approved', 'rejected', 'paid') then
    return jsonb_build_object('ok', false, 'code', 'bad-status',
      'message', 'An operator approves, rejects or records payment. Nothing was changed.');
  end if;

  select * into v_row from public.payout_requests where claim_id = p_claim_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not-found',
      'message', 'No claim with that id. Nothing was changed.');
  end if;
  -- Settlement is one-way. A paid ticket cannot be re-opened, re-approved or
  -- rejected after the fact — the transfer already happened.
  if v_row.status not in ('pending', 'approved') then
    return jsonb_build_object('ok', false, 'code', 'already-settled',
      'message', format('That claim is already %s. Nothing was changed.', v_row.status));
  end if;

  if p_status = 'rejected' and nullif(btrim(coalesce(p_note, '')), '') is null then
    return jsonb_build_object('ok', false, 'code', 'reason-required',
      'message', 'A rejection needs a reason the requester can read. Nothing was changed.');
  end if;

  if p_status = 'paid' then
    if p_signature is null or p_signature !~ '^[1-9A-HJ-NP-Za-km-z]{64,88}$' then
      return jsonb_build_object('ok', false, 'code', 'signature-required',
        'message', 'Recording a payment needs the signature of the SOL transfer. Nothing was changed.');
    end if;
    if p_lamports is null or p_lamports !~ '^(0|[1-9][0-9]{0,19})$' or p_lamports = '0' then
      return jsonb_build_object('ok', false, 'code', 'amount-required',
        'message', 'Recording a payment needs the lamports actually sent. Nothing was changed.');
    end if;
    if exists (select 1 from public.payout_requests where signature = p_signature and claim_id <> p_claim_id) then
      return jsonb_build_object('ok', false, 'code', 'signature-reused',
        'message', 'That signature already settles another claim. One transfer settles one ticket. Nothing was changed.');
    end if;

    update public.payout_requests
       set status = 'paid',
           signature = p_signature,
           paid_lamports = p_lamports,
           paid_at = now(),
           reviewed_at = coalesce(reviewed_at, now()),
           operator_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), operator_note),
           updated_at = now()
     where claim_id = p_claim_id;
  else
    update public.payout_requests
       set status = p_status,
           reviewed_at = now(),
           operator_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), operator_note),
           updated_at = now()
     where claim_id = p_claim_id;
  end if;

  return jsonb_build_object('ok', true, 'claim_id', p_claim_id, 'status', p_status, 'operator', v_operator);
end;
$$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

-- The admin desk subscribes to this queue, so a ticket opened while the operator
-- is looking at the page appears without a refresh.
--
-- `replica identity full` so an UPDATE payload carries the PREVIOUS row as well
-- as the new one. Without it Postgres publishes only the primary key for the old
-- tuple, and a desk watching for "pending became paid" would have to re-query to
-- find out what a row changed FROM — which is a round trip per event and a race
-- with the next update.
--
-- Note that realtime respects RLS for the anon key: an unauthenticated browser
-- receives these events only because the read policy in 20260806091100 publishes
-- the queue, and every column it can see is one it could already have selected.
alter table public.payout_requests replica identity full;
alter table public.payouts         replica identity full;

do $$
begin
  -- The publication exists on every Supabase project, but this migration should
  -- not fail on a bare Postgres that has never had Realtime enabled.
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.payout_requests;
    alter publication supabase_realtime add table public.payouts;
    alter publication supabase_realtime add table public.mints;
  else
    raise notice 'publication supabase_realtime does not exist; realtime was not configured';
  end if;
exception
  when duplicate_object then
    raise notice 'tables are already in the supabase_realtime publication';
end;
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

revoke all on function public.is_operator(text) from public, anon, authenticated;
revoke all on function public.request_payout(uuid, text, numeric, numeric) from public, anon, authenticated;
revoke all on function public.cancel_payout_request(uuid, text) from public, anon, authenticated;
revoke all on function public.resolve_payout_request(uuid, text, text, text, text, text) from public, anon, authenticated;

grant execute on function public.is_operator(text) to service_role;
grant execute on function public.request_payout(uuid, text, numeric, numeric) to service_role;
grant execute on function public.cancel_payout_request(uuid, text) to service_role;
grant execute on function public.resolve_payout_request(uuid, text, text, text, text, text) to service_role;


-- =========================================================================
-- SECTION 16 of 16 — 20260806091100_rls_policies.sql
-- =========================================================================

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
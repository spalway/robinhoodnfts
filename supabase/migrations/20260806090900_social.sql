-- xNFTs index — the social layer: friends, threads, messages, trade offers.
--
-- ===========================================================================
-- WHAT THIS REPLACES
-- ===========================================================================
-- `src/lib/social.ts` keeps the whole inbox in one localStorage blob per wallet,
-- with the other half of every conversation simulated from network.ts. That was
-- the right shape for a frontend with no backend, and it has one property this
-- schema has to preserve and one it has to fix.
--
--   Preserve: nothing here throws at the reader. A corrupt row, a missing
--             counterparty, a message from a wallet that no longer exists — all
--             of it degrades to a shorter list, never to a blank page.
--   Fix:      a conversation is between two people. A store only one of them can
--             write is not a conversation, it is a diary. Every table below is
--             two-sided and symmetric by construction.
--
-- ===========================================================================
-- SYMMETRY IS STRUCTURAL, NOT MAINTAINED
-- ===========================================================================
-- `friendships` and `threads` both key on an ORDERED PAIR — `wallet_a < wallet_b`
-- as a check constraint — so there is exactly one row per relationship and A
-- lists B precisely when B lists A. The alternative, two mirrored rows kept in
-- step by a writer, is a pair that drifts the first time one insert fails: one
-- wallet sees a friend, the other sees a stranger, and nothing ever notices.
--
-- `src/lib/social.ts` reaches the same property a different way, by seeding its
-- pair roll on the unordered pair. Same reasoning, and it is worth being explicit
-- that the one-way friendship is a bug both designs were built to make
-- unrepresentable rather than unlikely.
--
-- ===========================================================================
-- A TRADE OFFER MOVES NOTHING
-- ===========================================================================
-- Accepting one records a decision. There is no custody here and no escrow
-- anywhere in this protocol, so an accepted offer does NOT reassign an xployee —
-- and `accept_trade_offer` deliberately does not touch `public.xployees`. Making
-- it move assets would be inventing a settlement layer inside a messaging table,
-- with none of the ownership checks `buy_listing` performs and no way to make the
-- two legs atomic against a counterparty who sold in the meantime.
--
-- The offer legs still name real xployees and are still validated against real
-- ownership at send time, because an offer for units the sender does not hold is
-- a lie whether or not anything settles it.

-- ---------------------------------------------------------------------------
-- friend_requests
-- ---------------------------------------------------------------------------

create table public.friend_requests (
  id           uuid primary key default gen_random_uuid(),
  requester    public.base58_address not null,
  addressee    public.base58_address not null,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  message      text check (message is null or length(message) <= 200),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  constraint friend_requests_two_parties check (requester <> addressee),
  constraint friend_requests_resolved_has_timestamp check (
    (status = 'pending' and responded_at is null) or (status <> 'pending' and responded_at is not null)
  )
);

-- At most one OPEN request per unordered pair, in either direction. `least` and
-- `greatest` collapse the direction, so B cannot answer A's pending request by
-- sending their own and ending up with two rows that disagree about who asked.
create unique index friend_requests_one_open_per_pair
  on public.friend_requests (least(requester, addressee), greatest(requester, addressee))
  where status = 'pending';

create index friend_requests_inbox_idx  on public.friend_requests (addressee, status, created_at desc);
create index friend_requests_outbox_idx on public.friend_requests (requester, status, created_at desc);

comment on table public.friend_requests is
  'Both directions and every status — the audit trail behind public.friendships. A resolved request is history and stays; only pending rows are inbox items.';

-- ---------------------------------------------------------------------------
-- friendships
-- ---------------------------------------------------------------------------

create table public.friendships (
  -- Canonically ordered, so the pair is the key and the relationship has exactly
  -- one row. This is what makes the graph undirected at the storage layer instead
  -- of by convention.
  wallet_a   public.base58_address not null,
  wallet_b   public.base58_address not null,
  since      timestamptz not null default now(),
  -- The request that produced it, when there was one. Null for a friendship
  -- created some other way; a foreign key rather than a copy so the history
  -- cannot say something the request row does not.
  request_id uuid references public.friend_requests (id) on delete set null,
  primary key (wallet_a, wallet_b),
  constraint friendships_are_ordered check (wallet_a < wallet_b)
);

create index friendships_b_idx on public.friendships (wallet_b);

comment on table public.friendships is
  'Undirected. wallet_a < wallet_b is enforced, so one relationship is one row and a one-way friendship — the classic bug where clicking through to the other profile shows a stranger — cannot be written.';

-- Both halves of the graph as one directed view, because every query the app
-- actually writes is "who are MY friends" and expressing that against an ordered
-- pair at each call site is how a `wallet_b` gets forgotten.
create view public.friend_edges with (security_invoker = true) as
  select wallet_a as wallet, wallet_b as friend, since from public.friendships
  union all
  select wallet_b as wallet, wallet_a as friend, since from public.friendships;

comment on view public.friend_edges is
  'public.friendships seen from both sides. Query this rather than remembering to check wallet_a and wallet_b separately.';

-- ---------------------------------------------------------------------------
-- threads and messages
-- ---------------------------------------------------------------------------

create table public.threads (
  id              uuid primary key default gen_random_uuid(),
  participant_a   public.base58_address not null,
  participant_b   public.base58_address not null,
  created_at      timestamptz not null default now(),
  -- Denormalised so an inbox sorts without touching the messages table. Kept
  -- current by the trigger below rather than by every writer.
  last_message_at timestamptz,
  message_count   integer not null default 0 check (message_count >= 0),
  constraint threads_are_ordered check (participant_a < participant_b),
  unique (participant_a, participant_b)
);

create index threads_a_idx on public.threads (participant_a, last_message_at desc nulls last);
create index threads_b_idx on public.threads (participant_b, last_message_at desc nulls last);

comment on table public.threads is
  'Strictly two-party, canonically ordered. One conversation is one row whichever side opened it, so there is no "your copy" and "their copy" to fall out of step.';

create table public.messages (
  id        uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.threads (id) on delete cascade,
  sender    public.base58_address not null,
  -- MESSAGE_MAX in src/lib/social.ts. Long enough for a real pitch, short enough
  -- that one wallet cannot fill the table.
  body      text not null check (length(body) between 1 and 500),
  sent_at   timestamptz not null default now(),
  -- Set when the RECIPIENT reads it. A sender's own message is never unread to
  -- them, so there is no second column and no way for the two to disagree.
  read_at   timestamptz
);

create index messages_thread_idx on public.messages (thread_id, sent_at desc);
create index messages_unread_idx on public.messages (thread_id, sender) where read_at is null;

comment on column public.messages.read_at is
  'When the recipient read it. A thread has exactly two participants and a sender never reads their own message, so one nullable timestamp says everything a per-participant read table would.';

-- The sender has to be in the thread. A cross-table condition, so a trigger
-- rather than a check — and worth having, because the failure it prevents is
-- somebody else's mail appearing inside a conversation.
create or replace function public.guard_message_sender()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_a text;
  v_b text;
begin
  select participant_a, participant_b into v_a, v_b from public.threads where id = new.thread_id;
  if v_a is null then
    raise exception 'message %: no such thread', new.id;
  end if;
  if new.sender <> v_a and new.sender <> v_b then
    raise exception 'message %: sender is not a participant in that thread', new.id;
  end if;
  return new;
end;
$$;

create trigger messages_sender_must_be_a_participant
  before insert on public.messages
  for each row execute function public.guard_message_sender();

-- Keeps the thread's summary honest. In a trigger rather than in `send_message`,
-- so a row inserted by any route — a backfill, a repair, a second writer added
-- later — cannot leave the inbox sorting by a stale timestamp.
create or replace function public.touch_thread()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.threads
     set last_message_at = greatest(coalesce(last_message_at, new.sent_at), new.sent_at),
         message_count   = message_count + 1
   where id = new.thread_id;
  return new;
end;
$$;

create trigger messages_touch_thread
  after insert on public.messages
  for each row execute function public.touch_thread();

-- ---------------------------------------------------------------------------
-- trade_offers and their legs
-- ---------------------------------------------------------------------------

create table public.trade_offers (
  id        uuid primary key default gen_random_uuid(),
  sender    public.base58_address not null,
  recipient public.base58_address not null,
  note      text check (note is null or length(note) <= 500),
  status    text not null default 'pending'
              check (status in ('pending', 'accepted', 'declined', 'withdrawn', 'expired')),

  -- The $xNFT sweetener, in raw units, as TWO non-negative columns rather than
  -- one signed one.
  --
  -- `src/lib/social.ts` carries it as a signed number where negative means "the
  -- sender wants $xNFT back". That is compact and it is exactly the shape that
  -- produces an off-by-a-sign bug in a UI, because the sign has to be read
  -- correctly at every render and every comparison. Two columns make the
  -- direction a fact about which column is populated, and the check makes "both
  -- at once" — which would be two payments cancelling out — unrepresentable.
  sweetener_from_sender    public.u64_text not null default '0',
  sweetener_from_recipient public.u64_text not null default '0',

  created_at   timestamptz not null default now(),
  expires_at   timestamptz,
  responded_at timestamptz,

  constraint trade_offers_two_parties check (sender <> recipient),
  constraint trade_offers_one_direction_of_cash check (
    sweetener_from_sender = '0' or sweetener_from_recipient = '0'
  ),
  constraint trade_offers_resolved_has_timestamp check (
    (status = 'pending' and responded_at is null) or (status <> 'pending' and responded_at is not null)
  )
);

create index trade_offers_inbox_idx  on public.trade_offers (recipient, status, created_at desc);
create index trade_offers_outbox_idx on public.trade_offers (sender, status, created_at desc);
create index trade_offers_open_idx   on public.trade_offers (expires_at) where status = 'pending';

comment on table public.trade_offers is
  'A proposal, not a settlement. Accepting records a decision and moves nothing — there is no escrow anywhere in this protocol, so an offer that reassigned xployees would be a settlement layer hidden inside a messaging table.';

create table public.trade_offer_legs (
  offer_id   uuid   not null references public.trade_offers (id) on delete cascade,
  xployee_id bigint not null references public.xployees (id) on delete cascade,
  -- 'offered'   — the sender is putting this up.
  -- 'requested' — the sender wants it back.
  side       text   not null check (side in ('offered', 'requested')),
  -- (offer, xployee) as the key rather than (offer, side, xployee): the same unit
  -- cannot be on both sides of one trade, and this is what makes that impossible
  -- rather than merely checked by the writer that happens to insert the legs.
  primary key (offer_id, xployee_id)
);

create index trade_offer_legs_xployee_idx on public.trade_offer_legs (xployee_id);

comment on table public.trade_offer_legs is
  'The units on each side of an offer. The primary key is (offer, xployee), so the same worker cannot appear as both offered and requested in one trade.';

-- ---------------------------------------------------------------------------
-- Writers
-- ---------------------------------------------------------------------------

-- Every one resolves the actor through public.actor_wallet and none takes a
-- wallet address, so there is no writer that can be pointed at somebody else's
-- inbox. Each returns jsonb: a refusal here is an ordinary outcome the UI renders
-- as a sentence, not an exception.

-- The canonical pair, so ordering logic is written once.
create or replace function public.pair_key(p_x text, p_y text)
returns text[]
language sql immutable parallel safe strict set search_path = ''
as $$ select case when p_x < p_y then array[p_x, p_y] else array[p_y, p_x] end $$;

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

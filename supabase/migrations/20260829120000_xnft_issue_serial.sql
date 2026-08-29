-- xnft_issue_serial — deals one serial, after the payment is already proven.
--
-- ===========================================================================
-- WHY THIS FILE EXISTS
-- ===========================================================================
-- It did not. On the previous project this function was typed straight into a
-- SQL console and never committed, so a database rebuilt from this folder came
-- up WITHOUT it — while supabase/functions/confirm-mint/index.ts called it by
-- name on the happy path. The failure that produces is the worst-shaped one in
-- the system: the buyer's tokens have already moved, the Edge Function has
-- already proven it, and the very next statement errors. The money is gone and
-- no serial exists.
--
-- Found by building this project's database from the migrations and looking for
-- the function. Committed here so the next rebuild cannot lose it again.
--
-- ===========================================================================
-- THE SPLIT, AND WHY THE GRANT IS THE WHOLE SECURITY MODEL
-- ===========================================================================
--   confirm-mint (Deno)   reads Robinhood Chain and decides whether a specific
--                         transfer of $XAS to the project wallet really happened
--   this function         takes (hash, buyer) on trust and deals a serial
--
-- This function CANNOT verify anything. It is handed a transaction hash and a
-- buyer address and believes both — which is safe only because the sole role
-- that may call it is service_role, whose key never leaves the Edge Function's
-- server. Every grant is revoked below, deliberately and explicitly. If anon
-- could reach this, anybody could mint the collection out for free by POSTing
-- made-up hashes.
--
-- xnft_confirm_mint, by contrast, IS anon-callable — because it only ever reads.
--
-- ===========================================================================
-- CONCURRENCY: THE LOCK, AND THE DOUBLE CHECK AROUND IT
-- ===========================================================================
-- Two buyers confirming at the same instant must not be dealt the same serial.
-- A transaction-scoped advisory lock serialises the read-then-insert; it is
-- released at commit or rollback, so a failure cannot wedge the mint shut.
--
-- Idempotence is checked TWICE, and the second check is the one that matters.
-- The first is the fast path: a retry of an already-credited hash answers
-- without waiting for the lock at all, and retries are the common case because
-- the client polls. The second runs after the lock is held, and covers the
-- interleaving the first cannot see — two requests carrying the SAME hash that
-- both pass the pre-lock check before either has inserted. Without it the
-- second would be dealt a fresh serial for a payment already credited, and the
-- unique index on mint_signature would abort it — turning a duplicate, which is
-- a success, into an error on a paid mint.

alter table public.xnft_holdings
  add column if not exists paid_raw numeric;

comment on column public.xnft_holdings.paid_raw is
  'Base units of $XAS the verifier observed on the Transfer log. Audit only — the amount was already checked against the price on chain before this row was written.';

create or replace function public.xnft_issue_serial(
  p_signature text,
  p_buyer text,
  p_paid_raw text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.xnft_holdings;
  v_serial integer;
  v_tier text;
begin
  if p_signature is null or length(trim(p_signature)) = 0 then
    return jsonb_build_object(
      'ok', false, 'status', 'rejected', 'reason', 'bad-request',
      'message', 'No transaction hash was supplied.', 'buyer', null, 'assignment', null
    );
  end if;

  if p_buyer is null or length(trim(p_buyer)) = 0 then
    return jsonb_build_object(
      'ok', false, 'status', 'rejected', 'reason', 'bad-request',
      'message', 'No buyer address was supplied.', 'buyer', null, 'assignment', null
    );
  end if;

  -- ---- Fast path: already credited -------------------------------------
  select * into v_existing
    from public.xnft_holdings
   where mint_signature = lower(trim(p_signature));
  if found then
    return jsonb_build_object(
      'ok', true, 'status', 'duplicate', 'reason', null,
      'message', 'That payment has already been credited.',
      'buyer', v_existing.owner,
      'assignment', jsonb_build_object(
        'status', 'issued', 'serial', v_existing.serial,
        'label', public.xnft_tier_label(v_existing.tier),
        'tier', v_existing.tier, 'held_reason', null
      )
    );
  end if;

  -- ---- One dealer at a time --------------------------------------------
  perform pg_advisory_xact_lock(hashtext('xnft_mint_gate'));

  -- Re-check under the lock. See the header: this is what keeps a genuine
  -- duplicate from becoming a unique-violation on a mint that was paid for.
  select * into v_existing
    from public.xnft_holdings
   where mint_signature = lower(trim(p_signature));
  if found then
    return jsonb_build_object(
      'ok', true, 'status', 'duplicate', 'reason', null,
      'message', 'That payment has already been credited.',
      'buyer', v_existing.owner,
      'assignment', jsonb_build_object(
        'status', 'issued', 'serial', v_existing.serial,
        'label', public.xnft_tier_label(v_existing.tier),
        'tier', v_existing.tier, 'held_reason', null
      )
    );
  end if;

  -- ---- Next unissued serial, in the fixed reveal order ------------------
  --
  -- Ordered by POSITION, not by serial: the order was shuffled once, before the
  -- first mint, and that shuffle is the only thing making a low serial rare.
  -- Ordering by serial here would deal 0, 1, 2 ... and hand the whole X-RATED
  -- band to whoever minted first.
  select r.serial into v_serial
    from public.xnft_reveal_order r
    left join public.xnft_holdings h on h.serial = r.serial
   where h.serial is null
   order by r.position
   limit 1;

  if v_serial is null then
    -- Sold out. 'rejected' rather than 'busy': there is nothing to retry, and
    -- telling a buyer to try again would be a lie. The payment still happened,
    -- which is why the message says so plainly rather than pretending nothing did.
    return jsonb_build_object(
      'ok', false, 'status', 'rejected', 'reason', 'sold-out',
      'message', 'Every serial has been issued. Your payment was received and no serial could be dealt — keep this hash.',
      'buyer', p_buyer, 'assignment', null
    );
  end if;

  v_tier := public.xnft_tier_for(v_serial);

  insert into public.xnft_holdings (serial, owner, tier, mint_signature, paid_raw)
  values (
    v_serial,
    p_buyer,
    v_tier,
    lower(trim(p_signature)),
    case when p_paid_raw ~ '^[0-9]+$' then p_paid_raw::numeric else null end
  );

  return jsonb_build_object(
    'ok', true, 'status', 'confirmed', 'reason', null,
    'message', 'Payment verified. Your xployee has been issued.',
    'buyer', p_buyer,
    'assignment', jsonb_build_object(
      'status', 'issued', 'serial', v_serial,
      'label', public.xnft_tier_label(v_tier),
      'tier', v_tier, 'held_reason', null
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The grant IS the security model. See the header.
-- ---------------------------------------------------------------------------
-- `from public` first, because a new function is executable by PUBLIC by
-- default and revoking only from anon and authenticated would leave that
-- default in place for both of them.
revoke execute on function public.xnft_issue_serial(text, text, text) from public;
revoke execute on function public.xnft_issue_serial(text, text, text) from anon, authenticated;
grant  execute on function public.xnft_issue_serial(text, text, text) to service_role;

comment on function public.xnft_issue_serial(text, text, text) is
  'Deals the next serial in reveal order to a buyer whose payment confirm-mint has ALREADY proven on chain. Verifies nothing itself; service_role only.';

-- ---------------------------------------------------------------------------
-- Prove the grant, at migration time rather than at mint time.
-- ---------------------------------------------------------------------------
do $$
begin
  if has_function_privilege('anon', 'public.xnft_issue_serial(text, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.xnft_issue_serial(text, text, text)', 'execute')
  then
    raise exception 'xnft_issue_serial is reachable by anon or authenticated — anybody could mint for free';
  end if;

  if not has_function_privilege('service_role', 'public.xnft_issue_serial(text, text, text)', 'execute') then
    raise exception 'xnft_issue_serial is not callable by service_role — no mint could ever be credited';
  end if;
end;
$$;

-- xNFTs index — the write path.
--
-- Every one of these runs as SECURITY DEFINER with EXECUTE revoked from anon and
-- authenticated, so the only caller that can reach them is a service-role Edge
-- Function. That is deliberate: it means the trust boundary is one hop wide.
-- `ingest-signature` reads a transaction off the chain, reconciles its token
-- balance deltas against its instructions, and calls exactly one of these — and
-- because the whole multi-table effect of a single chain event happens inside one
-- function, it is one transaction. A half-ingested signature (fee recorded, mint
-- missing) cannot exist.
--
-- Each returns 'inserted' or 'duplicate' so the caller can tell a first sighting
-- from a replay without a second round trip.
--
-- search_path is pinned to '' on every function: a SECURITY DEFINER function that
-- resolves object names through the caller's search_path is a privilege-escalation
-- primitive, so every user object below is schema-qualified.
--
-- WHICH WRITERS ARE CHAIN-BACKED AND WHICH ARE NOT:
--
--   record_mint            chain — called only by ingest-signature
--   record_rent            chain — called only by ingest-signature
--   record_payout_pending  chain-adjacent — a signature exists, nothing verified
--   settle_payout          chain — writes only what confirm-payout read
--   record_simulated_sale  SIMULATED — writes trades and moves ownership
--
-- The simulated one is separated by name rather than by a parameter, so no caller
-- can flip a boolean and write a simulated row into a chain-backed table.

-- ---------------------------------------------------------------------------
-- Read helper — lets ingest skip an RPC round trip on a replayed post
-- ---------------------------------------------------------------------------

-- trades is not consulted: it holds no chain-derived rows, so a signature can
-- never be "already indexed" because of one.
create or replace function public.is_signature_indexed(p_signature text)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (select 1 from public.mints where signature = p_signature)
      or exists (select 1 from public.fee_ledger where signature = p_signature);
$$;

-- ---------------------------------------------------------------------------
-- record_mint
-- ---------------------------------------------------------------------------

-- p_burned and p_fee are text, not bigint, because they are u64 raw units.
-- Sending them as JSON numbers would route them through a double on the way here,
-- and this is not the file to start making exceptions to that rule in.
--
-- Note what this function does NOT do: it does not touch public.xployees. The old
-- version did, because the program's MintEvent named the xployee it had just
-- assigned. Two token transfers name nothing, so there is no honest way to say
-- which xployee this mint bought, and inventing one would put a wrong owner into
-- the index under the authority of a verified transaction.
create or replace function public.record_mint(
  p_signature   text,
  p_event_index integer,
  p_slot        bigint,
  p_block_time  timestamptz,
  p_buyer       text,
  p_burned      text,
  p_fee         text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
begin
  insert into public.mints (signature, event_index, buyer, burned, fee, slot, block_time)
  values (p_signature, p_event_index, p_buyer, p_burned, p_fee, p_slot, p_block_time)
  on conflict (signature, event_index) do nothing;
  v_inserted := found;

  insert into public.fee_ledger (signature, source, event_index, payer, amount, slot, block_time)
  values (p_signature, 'mint', p_event_index, p_buyer, p_fee, p_slot, p_block_time)
  on conflict (signature, source, event_index) do nothing;

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- record_rent
-- ---------------------------------------------------------------------------

-- Rentals never move the xployee, so there is nothing to reassign — the only
-- durable consequence a rental has in this schema is the fee.
--
-- The renter, the owner and the total paid are all verified from the chain, and
-- the fee row keeps the payer. The term is not recoverable: two token transfers
-- say how much was paid but not for how many epochs, so tenancy stays an
-- application concept and no rentals table is invented to hold a number the chain
-- did not state. That is flagged in supabase/README.md rather than silently
-- patched with a default.
create or replace function public.record_rent(
  p_signature   text,
  p_event_index integer,
  p_slot        bigint,
  p_block_time  timestamptz,
  p_renter      text,
  p_owner       text,
  p_gross       text,
  p_fee         text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
begin
  insert into public.fee_ledger (signature, source, event_index, payer, amount, slot, block_time)
  values (p_signature, 'rent', p_event_index, p_renter, p_fee, p_slot, p_block_time)
  on conflict (signature, source, event_index) do nothing;
  v_inserted := found;

  -- A rental closes a rent listing only if the owner listing it is the owner who
  -- was actually paid. Without that check any renter could close any listing by
  -- paying anyone; with it, the transaction has to corroborate the row it edits.
  update public.listings l
     set status = 'rented',
         updated_at = now()
   where l.seller = p_owner
     and l.kind = 'rent'
     and l.status = 'active'
     and exists (
       select 1 from public.xployees x
        where x.id = l.xployee_id
          and x.owner = p_owner
     );

  -- p_gross is verified by the caller and deliberately not stored. It is still in
  -- the signature so the drop is visible at the call site rather than being an
  -- absence someone has to notice: storing it would mean a rentals table, and a
  -- rentals table needs a term column that nothing on-chain can fill.

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- record_simulated_sale — THE SIMULATED WRITE PATH
-- ---------------------------------------------------------------------------

-- Writes a sale that did not happen on any chain, and moves ownership because of
-- it. Everything about that sentence is uncomfortable and all of it is honest:
-- sales are simulated, so the only thing that can record one is the application.
--
-- `origin` is hard-coded to 'simulated' and is not a parameter. There is no
-- argument to this function that can produce a row claiming to be chain-backed.
--
-- THIS IS THE FIX FOR THE OWNERSHIP DEFECT. The previous writer reassigned
-- ownership with:
--
--     update public.xployees set owner = p_buyer where nft_mint = p_nft_mint
--
-- while no writer anywhere ever populated `xployees.nft_mint`. The predicate
-- matched zero rows on every sale, so ownership never moved, and it failed
-- silently because an UPDATE that matches nothing is not an error. Two things
-- changed:
--
--   1. The join key is `xployee_id`, which is the key this very function writes
--      into public.trades — so the column the update reads and the column the
--      caller supplies are the same column.
--   2. The xployees row is upserted rather than updated. A sale of an xployee
--      this index has not seen before now creates it owned by the buyer, instead
--      of quietly doing nothing. A no-op is impossible rather than merely
--      unlikely.
--
-- No fee_ledger row is written. A simulated sale accrues no real fee, and the fee
-- ledger is reconciled against a treasury token account anyone can read.
create or replace function public.record_simulated_sale(
  p_sale_ref      text,
  p_xployee_id    bigint,
  p_nft_mint      text,
  p_buyer         text,
  p_seller        text,
  p_gross         text,
  p_fee           text,
  p_net_to_seller text
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted boolean;
begin
  if p_buyer = p_seller then
    raise exception 'record_simulated_sale: buyer and seller are the same wallet';
  end if;

  insert into public.trades (sale_ref, xployee_id, nft_mint, buyer, seller, gross, fee, net_to_seller, origin)
  values (p_sale_ref, p_xployee_id, p_nft_mint, p_buyer, p_seller, p_gross, p_fee, p_net_to_seller, 'simulated')
  on conflict (sale_ref) do nothing;
  v_inserted := found;

  -- Only on a first sighting. Replaying a sale must not move ownership again,
  -- because by then a later sale may have moved it on.
  if v_inserted then
    insert into public.xployees (id, owner, updated_at)
    values (p_xployee_id, p_buyer, now())
    on conflict (id) do update
       set owner      = excluded.owner,
           updated_at = now();

    update public.listings l
       set status = 'sold',
           updated_at = now()
     where l.xployee_id = p_xployee_id
       and l.status = 'active';
  end if;

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- payouts
-- ---------------------------------------------------------------------------

-- Called by request-payout the moment the wallet hands back a signature. The row
-- is written with no verified amount on purpose: the transaction is genuinely in
-- flight, nothing has read it, and `amount` stays null until something does.
-- p_claimed_amount_unverified is the client's assertion and goes into the column
-- whose name says exactly that.
create or replace function public.record_payout_pending(
  p_signature                 text,
  p_claimed_amount_unverified text,
  p_destination               text,
  p_expires_at_block_height   bigint
) returns public.payouts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.payouts;
begin
  insert into public.payouts (
    amount, claimed_amount_unverified, destination, status, signature, expires_at_block_height
  )
  values (
    null, p_claimed_amount_unverified, p_destination, 'pending', p_signature, p_expires_at_block_height
  )
  on conflict (signature) do nothing;

  -- A double-post returns the row that already exists rather than erroring, so a
  -- retried browser request is indistinguishable from the first one. Note that it
  -- returns the ORIGINAL row: a second post cannot revise the expiry height or
  -- the claimed amount of a claim already on record.
  select * into v_row from public.payouts where signature = p_signature;
  return v_row;
end;
$$;

-- The confirm path. Deliberately cannot express "pending" — a caller that wanted
-- to leave a row alone calls touch_payout instead. Splitting them this way means
-- the rule "a timeout must never mark a payout failed" is enforced by which
-- function got called, not by a branch inside one that could be written wrong.
--
-- p_amount and p_destination are what confirm-payout read out of the transaction's
-- own token balance deltas. Writing them is the moment the row stops being a
-- claim about money and starts being a reading of money — which is why a
-- confirmation without an amount is refused here as well as by the table's check
-- constraint. Two locks, because this is the one transition that turns an
-- unverified number into a settled one.
create or replace function public.settle_payout(
  p_signature      text,
  p_status         text,
  p_amount         text default null,
  p_destination    text default null,
  p_failure_reason text default null
) returns public.payouts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.payouts;
begin
  if p_status not in ('confirmed', 'failed') then
    raise exception 'settle_payout accepts only confirmed or failed, got %', p_status;
  end if;
  if p_status = 'confirmed' and p_amount is null then
    raise exception 'settle_payout: a confirmation needs the amount read off the chain';
  end if;
  if p_status = 'failed' and p_amount is not null then
    raise exception 'settle_payout: a failed payout moved nothing and has no amount';
  end if;

  -- `where status = 'pending'` makes settlement one-way. Re-running the scheduled
  -- sweep over an already-settled row is a no-op, and a later contradictory read
  -- (a status query that briefly forgets a signature) cannot flip a confirmed
  -- payout back to failed.
  update public.payouts p
     set status         = p_status,
         amount         = p_amount,
         destination    = coalesce(p_destination, p.destination),
         failure_reason = case when p_status = 'failed' then p_failure_reason else null end,
         confirmed_at   = now(),
         last_checked_at = now()
   where p.signature = p_signature
     and p.status = 'pending'
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.payouts where signature = p_signature;
  end if;

  return v_row;
end;
$$;

-- The unknown-status path. It can move `last_checked_at` and nothing else, so a
-- payout whose fate the chain has not yet decided stays exactly as pending as it
-- really is. Presenting a possibly-landed claim as failed is how you get someone
-- to claim twice, and the second claim is a second withdrawal.
create or replace function public.touch_payout(p_signature text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.payouts
     set last_checked_at = now()
   where signature = p_signature
     and status = 'pending';
$$;

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------

-- PostgREST resolves /rpc/<fn> through the caller's role, so revoking EXECUTE
-- here is what stops the anon key from calling a writer directly. Without this,
-- SECURITY DEFINER would hand anon exactly the privileges it is meant to deny.
revoke all on function public.is_signature_indexed(text) from public, anon, authenticated;
revoke all on function public.record_mint(text, integer, bigint, timestamptz, text, text, text) from public, anon, authenticated;
revoke all on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) from public, anon, authenticated;
revoke all on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.record_payout_pending(text, text, text, bigint) from public, anon, authenticated;
revoke all on function public.settle_payout(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.touch_payout(text) from public, anon, authenticated;

grant execute on function public.is_signature_indexed(text) to service_role;
grant execute on function public.record_mint(text, integer, bigint, timestamptz, text, text, text) to service_role;
grant execute on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) to service_role;
grant execute on function public.record_simulated_sale(text, bigint, text, text, text, text, text, text) to service_role;
grant execute on function public.record_payout_pending(text, text, text, bigint) to service_role;
grant execute on function public.settle_payout(text, text, text, text, text) to service_role;
grant execute on function public.touch_payout(text) to service_role;

-- xNFTs index — a rental closes the listing that was rented, and only that one.
--
-- Additive, as every correction to this schema has to be: 20260805120100 has been
-- written and may have been applied, so it is not edited. `create or replace
-- function` on the same signature is the whole mechanism — it keeps the existing
-- privileges, and the grants at the bottom are restated rather than relied on so
-- this file can be read on its own.
--
-- ---------------------------------------------------------------------------
-- THE DEFECT
-- ---------------------------------------------------------------------------
-- The previous body closed listings like this:
--
--     update public.listings l
--        set status = 'rented'
--      where l.seller = p_owner
--        and l.kind = 'rent'
--        and l.status = 'active'
--        and exists (... x.owner = p_owner ...)
--
-- Every predicate there is about the OWNER. Not one of them is about which
-- listing was actually rented — and nothing anywhere tied the amount that was
-- paid to any listing's price. So an owner advertising three xployees for rent
-- had all three marked 'rented' by a single rental of one of them, and the other
-- two vanished from the marketplace while remaining perfectly available. The
-- damage was silent, because an UPDATE that matches too many rows is no more of
-- an error than one that matches too few.
--
-- ---------------------------------------------------------------------------
-- WHAT REPLACES IT, AND WHAT IT CANNOT DO
-- ---------------------------------------------------------------------------
-- The transaction has to corroborate the row it edits, and the only thing it says
-- beyond who was paid is HOW MUCH. `src/lib/fees.ts` defines a rental contract as
-- `fee_per_epoch × term_epochs` to the owner with the protocol fee riding on top,
-- and `_shared/events.ts` recognises a rental by exactly that relationship — so
-- `p_gross`, which is the owner's leg read off the chain, is the contract total of
-- whichever listing was rented. Matching on it turns "some listing of this
-- owner's" into "the listing whose price the payment actually is".
--
-- Then `limit 1`: at most one listing closes, ever. Two listings of the same
-- owner priced identically are genuinely indistinguishable from the chain — two
-- token transfers carry no listing id — so the oldest is closed and the tie-break
-- is stated (`updated_at asc, nft_mint asc`) rather than left to the planner.
-- Closing one of two identical listings is a defensible guess; closing both is
-- not, and closing all three of an owner's unrelated listings never was.
--
-- No match closes nothing. An owner paid an amount that corresponds to no listing
-- of theirs still gets the fee row — the money moved and the chain proves it — and
-- the marketplace is left alone, because inventing which advertisement that
-- payment settled would be exactly the kind of guess the fee ledger is not
-- allowed to be built on.
--
-- The close is also now inside the first-sighting branch, matching
-- record_simulated_sale. Re-posting a months-old rent signature must not reach
-- into today's marketplace and close a listing that happens to carry the same
-- total; the fee row's `on conflict do nothing` already made the money idempotent,
-- and this makes the side effect idempotent too.

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

  if v_inserted then
    -- The outer `status = 'active'` is not redundant with the subquery's: between
    -- choosing the row and updating it, a concurrent rental may already have
    -- closed it, and re-closing a listing would move its updated_at for an event
    -- that changed nothing.
    update public.listings l
       set status = 'rented',
           updated_at = now()
     where l.status = 'active'
       and l.nft_mint = (
         select m.nft_mint
           from public.listings m
          where m.seller = p_owner
            and m.kind = 'rent'
            and m.status = 'active'
            and m.fee_per_epoch is not null
            and m.term_epochs is not null
            -- The listings_priced_by_kind constraint already guarantees both are
            -- present on a rent listing; the null checks are here so the
            -- arithmetic below cannot quietly become null and match nothing for a
            -- reason nobody would look for.
            --
            -- ::numeric because amounts are stored as digit strings (see the
            -- u64_text domain) — the cast is the price of a column that survives
            -- PostgREST without going through a double, and the comparison is
            -- exact integer arithmetic either way.
            and m.fee_per_epoch::numeric * m.term_epochs::numeric = p_gross::numeric
            -- The seller of a listing is not proof of anything on its own; the
            -- xployee has to be theirs too. Without this a stale listing left
            -- behind by a previous owner could be closed by the new owner's rental.
            and exists (
              select 1
                from public.xployees x
               where x.id = m.xployee_id
                 and x.owner = p_owner
            )
          order by m.updated_at asc, m.nft_mint asc
          limit 1
       );
  end if;

  -- p_gross is now load-bearing rather than merely documented: it is what
  -- identifies the listing. It is still not stored, for the reason the original
  -- writer gave — storing it means a rentals table, and a rentals table needs a
  -- term column that nothing on-chain can fill.

  return case when v_inserted then 'inserted' else 'duplicate' end;
end;
$$;

-- Matches the subquery's predicate: owner, then kind and status. The existing
-- listings_seller_idx covers `seller` alone, which is enough for one owner's
-- listings but makes the planner filter the rest.
create index if not exists listings_rent_match_idx
  on public.listings (seller, kind, status);

-- ---------------------------------------------------------------------------
-- The pending-payout sweep
-- ---------------------------------------------------------------------------
--
-- `confirm-payout` used to sweep pending rows oldest-first. The payouts queue is
-- writable through an endpoint that has no authorisation and cannot have one — the
-- anon key is public and the transaction being recorded has not landed yet — so a
-- strict FIFO meant anyone could park rows at the head of it and a real payout
-- behind them would never be reached within the sweep's bound. It now sweeps
-- least-recently-checked first, which makes the queue round-robin: examining a row
-- moves it to the back, and every pending row is reached within a bounded number
-- of sweeps regardless of how many siblings it has.
--
-- `nulls first` matches the order the function asks PostgREST for, so a row
-- nothing has looked at yet is served before one that has been.
create index if not exists payouts_pending_sweep_idx
  on public.payouts (status, last_checked_at asc nulls first, requested_at asc);

-- ---------------------------------------------------------------------------
-- Execution grants
-- ---------------------------------------------------------------------------
--
-- `create or replace function` preserves the privileges on the existing function,
-- so these are a restatement rather than a repair. They are here because a reader
-- checking that anon cannot call a writer should be able to answer that from the
-- file that last defined it.
revoke all on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) from public, anon, authenticated;
grant execute on function public.record_rent(text, integer, bigint, timestamptz, text, text, text, text) to service_role;

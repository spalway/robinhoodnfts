-- xNFTs index — the mint fee is gone, and the schema stops being able to hold one.
--
-- Additive, like every correction to this schema: 20260805120000 has been written
-- and may have been applied, so it is not edited. What changes here is what the
-- columns are ALLOWED to contain, which is the only kind of change that actually
-- retires an economic parameter. Setting the fee to zero somewhere in application
-- code retires nothing — a zero is a value, and a value can be changed back by
-- anyone who finds the constant.
--
-- ---------------------------------------------------------------------------
-- WHAT A MINT IS NOW
-- ---------------------------------------------------------------------------
-- ONE transferChecked. 10,000 $xNFT from the buyer to
-- `1nc1nerator11111111111111111111111111111111`. No treasury leg, no protocol
-- fee, no second amount to reconcile. Every token the buyer spends is burned.
--
-- This is a strictly stronger claim than the old two-leg mint, and it is worth
-- being precise about why: with a fee leg, "was this a mint?" was a question
-- about a *pair* of transfers that had to agree with each other, and a
-- transaction that burned correctly while underpaying the fee was a partial mint
-- with an irreversible burn already inside it. With one leg there is no pair, no
-- second amount, and no partial state. The burn either happened at the published
-- size or the transaction is not a mint.
--
-- ---------------------------------------------------------------------------
-- WHY `mints.fee` SURVIVES AS A COLUMN
-- ---------------------------------------------------------------------------
-- Dropping it outright would be cleaner in the schema and worse everywhere else:
-- `src/lib/supabase.ts` parses a mint row with `rawUnits(row.fee)` and REFUSES
-- the row when that comes back null. PostgREST omits a dropped column entirely,
-- so `select=*` would hand the browser rows with no `fee` key, every one of them
-- would parse to null, and the Transactions page would render permanently empty
-- against a database that is perfectly correct. That is the same failure the
-- comment block in supabase.ts was written about — a reader stricter than the
-- schema — and it is not worth re-creating from the other side.
--
-- So the column stays and is nailed to zero by a check constraint. Note what that
-- buys, because it is more than a default would: a default is what happens when
-- nobody says otherwise, and a check is what happens no matter who says
-- otherwise. `record_mint` cannot write a fee, a service-role INSERT cannot write
-- a fee, and a future migration that wants one has to delete this constraint by
-- name — which is a thing a reviewer can see, unlike a constant quietly changing
-- from 0 to 500.
--
-- The removal path is stated rather than implied: when `parseMint` in
-- src/lib/supabase.ts stops requiring `fee`, drop the column and this constraint
-- together.

-- ---------------------------------------------------------------------------
-- mints.fee — vestigial, and permanently zero
-- ---------------------------------------------------------------------------

-- The column is NOT NULL with no default, so a writer that stops supplying it
-- would fail its insert. The default is what lets `record_mint` drop the
-- parameter; the check is what stops the default being talked out of.
alter table public.mints
  alter column fee set default '0';

alter table public.mints
  add constraint mints_never_carry_a_fee check (fee = '0');

comment on column public.mints.fee is
  'VESTIGIAL, permanently ''0'', enforced by mints_never_carry_a_fee. A mint is one transfer to the incinerator and pays nobody. '
  'The column is retained only because src/lib/supabase.ts refuses a mint row whose `fee` is absent; drop both together when that parser stops requiring it.';

comment on table public.mints is
  'Chain-backed only. Every row corresponds to a transaction ingest-signature fetched and recognised as exactly one transfer of 10,000 $xNFT to the incinerator, reconciled against the token balance deltas. There is no fee leg and there is no treasury leg.';

-- ---------------------------------------------------------------------------
-- fee_ledger — a mint can no longer accrue anything
-- ---------------------------------------------------------------------------

-- The fee ledger is reconciled against the treasury's real token account. A mint
-- now moves nothing into it, so a `source = 'mint'` row would be an accrual with
-- no deposit behind it — the exact corruption the table's original comment says
-- the missing 'sale' value exists to prevent, arriving through the other door.
--
-- A zero-valued mint row would be no better than a wrong one. It would still
-- appear in `fetchFeeLedger`, still be counted by `sumFees(rows, 'mint')`, and
-- still tell a reader that mints are a revenue source. They are not one.
--
-- The domain check on `source` is left alone — widening it back is not something
-- this migration should make easy — and the exclusion is expressed as its own
-- named constraint so it reads as a decision rather than as an omission.
alter table public.fee_ledger
  add constraint fee_ledger_mints_accrue_nothing check (source <> 'mint');

comment on constraint fee_ledger_mints_accrue_nothing on public.fee_ledger is
  'A mint burns every token it costs and pays no fee, so it produces no treasury revenue. A row here would overstate a balance anyone can go and read on chain.';

comment on table public.fee_ledger is
  'Chain-backed rental fees only. Sum this against the treasury token account balance plus confirmed payouts. Mints accrue nothing (fee_ledger_mints_accrue_nothing) and simulated sales accrue nothing (the source check has no ''sale''), so the two exclusions between them are what keep this table reconcilable.';

-- ---------------------------------------------------------------------------
-- record_mint — the old signature goes
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced in place. The seventh parameter WAS the fee, so a
-- `create or replace` keeping the same argument list would leave a function that
-- still accepts one — and an accepted parameter is an invitation. Removing the
-- signature means a caller that still passes a fee gets "function does not exist"
-- from Postgres instead of silently writing a number nowhere.
--
-- Its replacement is defined in 20260806090500_mint_control.sql, because the new
-- writer does more than record a transfer: it assigns the serial. Defining it
-- here and immediately rewriting it there would be two versions of one function
-- in one push, and the second one is the only one that has ever run.
drop function if exists public.record_mint(text, integer, bigint, timestamptz, text, text, text);

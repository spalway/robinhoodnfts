-- xNFTs index — the collection itself.
--
-- 20260805120000 gave `public.xployees` an id, an owner and a handful of
-- nullable descriptive columns, on the reasoning that identity lived in the
-- browser: `src/lib/xployee.ts` rebuilds a whole worker from its serial, so the
-- database only had to remember who held it.
--
-- That reasoning stops working the moment minting is real. A serial is now
-- ASSIGNED — dealt from a permutation, once, to one buyer — and an assignment
-- that only one party can compute is not an assignment, it is an opinion. The
-- database has to be able to answer "what is #1885, and does that row agree with
-- the rarity its number claims?" without running a TypeScript bundle.
--
-- ---------------------------------------------------------------------------
-- RARITY IS POSITIONAL, AND THAT IS ENFORCED HERE RATHER THAN TRUSTED
-- ---------------------------------------------------------------------------
-- `src/lib/tiers.ts::tierForId` lays the collection out rarest-first, so a serial
-- IS a rarity claim: #0000–#0149 X-RATED, #0150–#0749 EPIC, #0750–#1999 RARE,
-- #2000–#4999 UNCOMMON. Two mechanisms make each row agree with it, and they fail
-- in opposite directions on purpose:
--
--   `public.tier_for_id(id)`   — the same function, in SQL. A check constraint
--                                built on it means a row whose tier contradicts
--                                its serial cannot be written by ANY writer,
--                                including a service-role INSERT and including a
--                                hand-typed statement in the SQL editor.
--   the stamping trigger       — fills tier, skills and principal in from the id
--                                when a writer does not supply them, so the check
--                                is satisfied by construction rather than by
--                                every caller remembering to.
--
-- A trigger alone would be defeated by `alter table ... disable trigger`. A check
-- alone would turn every partial upsert — `record_simulated_sale` writes (id,
-- owner) and nothing else — into a constraint violation. Together, the safe state
-- is also the default one.
--
-- ---------------------------------------------------------------------------
-- LITERALS PLUS AN ASSERTION, NOT A LOOKUP
-- ---------------------------------------------------------------------------
-- Three functions below carry hard-coded numbers that also appear in a table:
-- the tier bands, the skill count per tier, the size of each trait vocabulary.
-- That duplication is deliberate and it is checked. A check constraint may only
-- call an IMMUTABLE function, and a function that reads a table is not immutable
-- however it is declared — marking one immutable and then building a constraint
-- on it is a well-known way to get a constraint that silently disagrees with the
-- data it was supposed to guard. So the constrainable values are literals, and
-- the DO block at the end of this file recomputes every one of them from the
-- registry tables and raises if any has drifted. Editing a supply share without
-- editing the function fails the next `db push` instead of reclassifying a
-- thousand serials in silence.

-- ---------------------------------------------------------------------------
-- Supply
-- ---------------------------------------------------------------------------

-- 5,000, matching MAX_SUPPLY in src/lib/xployee.ts. A function rather than a
-- literal scattered through six constraints: the number appears once, and a
-- reader asking "how big is the collection" has one place to look.
create or replace function public.max_supply()
returns integer
language sql
immutable
parallel safe
set search_path = ''
as $$ select 5000 $$;

comment on function public.max_supply() is
  'Total serials that can ever exist. Matches MAX_SUPPLY in src/lib/xployee.ts. Changing it invalidates the reveal permutation and every tier boundary below.';

-- ---------------------------------------------------------------------------
-- Tier registry
-- ---------------------------------------------------------------------------

create table public.tiers (
  id     text primary key check (id in ('entry', 'mid', 'expert', 'xrated')),
  label  text not null,
  -- Number of skills an xployee of this tier carries. Unique, because the skill
  -- count IS the rarity rank — two tiers carrying three skills each would make
  -- "rarer" meaningless.
  skills smallint not null unique check (skills between 1 and 4),
  -- Share of supply, 0–1. The four must sum to exactly 1; asserted below.
  supply numeric(6, 4) not null check (supply > 0 and supply <= 1),
  color  text not null,
  shade  text not null,
  light  text not null,
  effect text not null check (effect in ('none', 'glow', 'laser'))
);

comment on table public.tiers is
  'Mirrors TIERS in src/lib/tiers.ts. Descriptive: the serial bands are literals in tier_for_id(), and the DO block at the end of this migration asserts they still match these supply shares.';

insert into public.tiers (id, label, skills, supply, color, shade, light, effect) values
('entry','UNCOMMON',1,0.6,'#44AF63','#2f7d46','#7fcb96','none'),
('mid','RARE',2,0.25,'#1D84DE','#145e9e','#63aeeb','none'),
('expert','EPIC',3,0.12,'#D211B0','#8d0b76','#f45ad6','glow'),
('xrated','X-RATED',4,0.03,'#FF1B1B','#830404','#ff7a6b','laser');

-- ---------------------------------------------------------------------------
-- tier_for_id — the positional rarity function
-- ---------------------------------------------------------------------------

-- The bands, and where the numbers come from. `tierForId` walks rarest-first,
-- taking `round(supply x maxSupply)` serials per tier and letting the LAST tier
-- absorb the rounding remainder:
--
--   X-RATED  round(0.03 x 5000) =  150  ->  #0000–#0149
--   EPIC     round(0.12 x 5000) =  600  ->  #0150–#0749
--   RARE     round(0.25 x 5000) = 1250  ->  #0750–#1999
--   UNCOMMON everything left    = 3000  ->  #2000–#4999
--
-- Out of range RAISES rather than returning a tier. A serial outside the supply
-- is not an unusual xployee, it is an impossible one, and the constraint that
-- calls this should fail loudly instead of quietly classifying #7000 as uncommon.
create or replace function public.tier_for_id(p_id bigint)
returns text
language plpgsql
immutable
parallel safe
strict
set search_path = ''
as $$
begin
  if p_id < 0 or p_id >= public.max_supply() then
    raise exception 'tier_for_id: % is outside the collection (0..%)', p_id, public.max_supply() - 1;
  end if;
  if p_id <  150 then return 'xrated'; end if;
  if p_id <  750 then return 'expert'; end if;
  if p_id < 2000 then return 'mid';    end if;
  return 'entry';
end;
$$;

comment on function public.tier_for_id(bigint) is
  'Positional rarity: the tier a serial belongs to. Mirrors tierForId() in src/lib/tiers.ts. IMMUTABLE so check constraints can be built on it.';

-- Skill count per tier, as a constrainable literal. Mirrors the `skills` column
-- of public.tiers, which the assertion below compares it against.
create or replace function public.skills_for_tier(p_tier text)
returns smallint
language sql
immutable
parallel safe
strict
set search_path = ''
as $$
  select case p_tier
    when 'entry'  then 1
    when 'mid'    then 2
    when 'expert' then 3
    when 'xrated' then 4
  end::smallint
$$;

-- Display form: #0042. One implementation, so a serial never appears two ways on
-- one page.
create or replace function public.serial_label(p_id bigint)
returns text
language sql
immutable
parallel safe
strict
set search_path = ''
as $$ select '#' || lpad(p_id::text, 4, '0') $$;

-- ---------------------------------------------------------------------------
-- Skill registry
-- ---------------------------------------------------------------------------

-- Authoritative, unlike the tier boundaries: nothing builds a check constraint on
-- a skill's rate, so it can live in a table and be read by ordinary queries —
-- which is what lets the apy assertion in 20260806090400 recompute a worker's
-- blended rate from its own skill rows instead of taking the stored number on
-- trust.
create table public.skills (
  id       text primary key,
  label    text not null,
  desk     text not null,
  -- The xStock this desk accrues into. Fiction, and consistent fiction.
  ticker   text not null unique,
  -- Base annual yield, 0–1.
  base_apy numeric(8, 6) not null check (base_apy > 0 and base_apy < 1),
  -- Draw weight. High-APY skills are weighted scarce, so a rare pairing stays rare.
  weight   smallint not null check (weight > 0)
);

comment on table public.skills is
  'Mirrors SKILLS in src/lib/skills.ts. The yield engine: an xployee''s apy is the mean of its held skills'' base_apy x proficiency.';

insert into public.skills (id, label, desk, ticker, base_apy, weight) values
('silicon','Silicon Analyst','Semis','NVDAx',0.092000,5),
('platform','Platform Ops','Megacap Tech','AAPLx',0.074000,8),
('cloud','Cloud Architect','Enterprise SW','MSFTx',0.071000,8),
('ledger','Ledger Clerk','Financials','JPMx',0.063000,10),
('rails','Card Rails','Payments','Vx',0.058000,10),
('crude','Crude Desk','Energy','XOMx',0.081000,6),
('grid','Grid Tech','Industrials','HONx',0.052000,11),
('trial','Trial Nurse','Pharma','LLYx',0.067000,9),
('claims','Claims Adjuster','Health Ins.','UNHx',0.059000,10),
('shelf','Shelf Stocker','Staples','KOx',0.044000,13),
('brand','Brand Manager','Consumer','PGx',0.046000,12),
('ballast','Index Ballast','Broad Market','SPYx',0.040000,14),
('bills','Bills Desk','T-Bills','TBLLx',0.048000,12),
('vault','Vault Keeper','Gold','GLDx',0.032000,11),
('teller','Chain Teller','Crypto Equity','COINx',0.126000,3),
('degen','Treasury Degen','Crypto Proxy','MSTRx',0.141000,2);

-- ---------------------------------------------------------------------------
-- Trait vocabulary
-- ---------------------------------------------------------------------------

-- Four independent slots, drawn by index from fixed arrays in
-- src/lib/xployee.ts. Stored by (slot, index) because the index is what the
-- generator actually rolled, and because a lookup table is what a metadata
-- endpoint needs in order to name a trait without hard-coding a word list.
--
-- Note that ACCESSORIES carries 'None' at BOTH index 0 and index 1. That is not a
-- mistake to normalise away: it is how the generator weights a bare xployee at 2
-- in 10, and collapsing the duplicate would change the odds.
create table public.trait_values (
  slot  text     not null check (slot in ('uniform', 'head', 'face', 'accessory')),
  idx   smallint not null check (idx >= 0),
  label text     not null,
  primary key (slot, idx)
);

comment on table public.trait_values is
  'The four trait vocabularies from src/lib/xployee.ts, by draw index. ACCESSORIES repeats ''None'' at 0 and 1 deliberately — that duplication IS the 2-in-10 chance of no accessory.';

insert into public.trait_values (slot, idx, label) values
('uniform',0,'Coverall'),('uniform',1,'Suit'),('uniform',2,'Vest'),('uniform',3,'Polo'),
('uniform',4,'Apron'),('uniform',5,'Lab Coat'),('uniform',6,'Hoodie'),('uniform',7,'Overcoat'),
('head',0,'Crop'),('head',1,'Sweep'),('head',2,'Bald'),('head',3,'Bun'),('head',4,'Mohawk'),
('head',5,'Cap'),('head',6,'Helmet'),('head',7,'Curls'),('head',8,'Bowl'),('head',9,'Tie-back'),
('face',0,'Neutral'),('face',1,'Focused'),('face',2,'Weary'),('face',3,'Smirk'),
('face',4,'Grin'),('face',5,'Scowl'),('face',6,'Blank'),('face',7,'Squint'),
('accessory',0,'None'),('accessory',1,'None'),('accessory',2,'Glasses'),('accessory',3,'Headset'),
('accessory',4,'Visor'),('accessory',5,'Earpiece'),('accessory',6,'Badge'),('accessory',7,'Lanyard'),
('accessory',8,'Cigar'),('accessory',9,'Shades');

-- ---------------------------------------------------------------------------
-- xployees — the columns the browser used to be the only holder of
-- ---------------------------------------------------------------------------

alter table public.xployees
  -- The seed for every generated surface: the pixel bust in src/lib/avatar.ts,
  -- the scenic background in src/lib/backgrounds.ts, the particle layer. It is
  -- `fakeAddress('xployee:' + id)` — a deterministic pseudo-address, NEVER a real
  -- key and never a token mint. Stored rather than recomputed because it is the
  -- image's identity: a renderer, a CDN path or a metadata service needs one
  -- stable string to key art by, and "run this TypeScript" is not one.
  add column if not exists art_seed text,
  add column if not exists uniform_idx   smallint,
  add column if not exists head_idx      smallint,
  add column if not exists face_idx      smallint,
  add column if not exists accessory_idx smallint,
  -- A cache of backgroundFor(x) in src/lib/backgrounds.ts, which is a pure
  -- function of art_seed and tier. Denormalised on purpose: these are the two
  -- fields a collector filters a marketplace by, and re-deriving them would mean
  -- a SQL port of the background generator that could disagree with the renderer.
  -- Regenerating the seed regenerates both, so they cannot drift apart silently.
  add column if not exists background text,
  add column if not exists overlay    text;

-- Where a rendered copy of the art would live. GENERATED rather than stored, so
-- the path and the serial cannot disagree — the failure mode of an `image_url`
-- column that somebody backfilled once and never again.
alter table public.xployees
  add column if not exists image_path text
    generated always as ('xployees/' || lpad(id::text, 4, '0') || '.png') stored;

-- The padded display form. `id` is the number; this is the string every surface
-- prints. Generated for the same reason.
alter table public.xployees
  add column if not exists serial_display text
    generated always as ('#' || lpad(id::text, 4, '0')) stored;

comment on column public.xployees.art_seed is
  'Deterministic art seed — fakeAddress(''xployee:'' + id). Seeds the bust, the background and the particles. Not a key, not a mint address; nothing may derive an on-chain account from it.';
comment on column public.xployees.image_path is
  'Where a rendered PNG would live. Generated from the serial so it cannot disagree with it. Art is generated in the browser today and nothing writes a file at this path yet.';
comment on column public.xployees.overlay is
  'Particle layer from src/lib/backgrounds.ts: none | snow | rain | thunder | sparks | embers | stars.';

-- ---------------------------------------------------------------------------
-- The rarity invariants
-- ---------------------------------------------------------------------------

alter table public.xployees
  add constraint xployees_within_supply
    check (id >= 0 and id < public.max_supply());

-- THE ONE THAT MATTERS. A row whose tier contradicts its serial cannot exist.
--
-- Permissive on null so that a partial upsert is not a constraint violation. The
-- stamping trigger closes that from the other side by filling the tier in before
-- this check ever runs, so null is unreachable in practice; the tolerance exists
-- so a disabled trigger degrades to "incomplete row" rather than to "sales fail".
alter table public.xployees
  add constraint xployees_tier_is_positional
    check (tier is null or tier = public.tier_for_id(id));

comment on constraint xployees_tier_is_positional on public.xployees is
  'Rarity is positional. A row claiming a tier its serial does not carry is refused, whoever writes it — the service role included.';

-- Skill count and principal are both pure functions of the tier, so a row that
-- disagrees with itself is refused too. principal = 1000 x skills, matching
-- principalFor() in src/lib/xployee.ts.
alter table public.xployees
  add constraint xployees_skills_match_tier
    check (skills is null or tier is null or skills = public.skills_for_tier(tier));

alter table public.xployees
  add constraint xployees_principal_matches_skills
    check (principal is null or skills is null or principal = 1000::numeric * skills);

alter table public.xployees
  add constraint xployees_apy_is_a_rate
    check (apy is null or (apy > 0 and apy < 1));

alter table public.xployees
  add constraint xployees_tier_is_known
    check (tier is null or tier in ('entry', 'mid', 'expert', 'xrated'));

-- Trait indices, bounded to the size of each vocabulary. Literals for the reason
-- given at the top of this file — a check may not contain a subquery, so it
-- cannot ask trait_values how long a list is — and the assertion at the bottom
-- proves these four bounds still match the table.
alter table public.xployees
  add constraint xployees_traits_in_vocabulary check (
    (uniform_idx   is null or uniform_idx   between 0 and 7)
    and (head_idx      is null or head_idx      between 0 and 9)
    and (face_idx      is null or face_idx      between 0 and 7)
    and (accessory_idx is null or accessory_idx between 0 and 9)
  );

alter table public.xployees
  add constraint xployees_overlay_is_known check (
    overlay is null or overlay in ('none', 'snow', 'rain', 'thunder', 'sparks', 'embers', 'stars')
  );

-- ---------------------------------------------------------------------------
-- The stamping trigger
-- ---------------------------------------------------------------------------

-- Fills in what the serial already determines, and REFUSES a writer that supplies
-- something else.
--
-- The refusal half is why this is not merely a convenience. A caller passing
-- tier 'xrated' for #4300 is either confused or malicious, and either way the
-- honest answer is an exception naming the disagreement — not a silent overwrite,
-- which would leave the caller believing something the database does not.
create or replace function public.stamp_xployee_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tier   text;
  v_skills smallint;
begin
  v_tier   := public.tier_for_id(new.id);
  v_skills := public.skills_for_tier(v_tier);

  if new.tier is null then
    new.tier := v_tier;
  elsif new.tier <> v_tier then
    raise exception 'xployee %: that serial is % by position, not %',
      public.serial_label(new.id), v_tier, new.tier;
  end if;

  if new.skills is null then
    new.skills := v_skills;
  elsif new.skills <> v_skills then
    raise exception 'xployee %: a % carries % skills, not %',
      public.serial_label(new.id), v_tier, v_skills, new.skills;
  end if;

  if new.principal is null then
    new.principal := 1000::numeric * v_skills;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger xployees_stamp_identity
  before insert or update on public.xployees
  for each row execute function public.stamp_xployee_identity();

comment on function public.stamp_xployee_identity() is
  'Fills tier, skills and principal from the serial and refuses a writer that supplies a different one. Paired with xployees_tier_is_positional: the trigger makes the safe state the default, the check makes it the only one.';

-- ---------------------------------------------------------------------------
-- xployee_skills — which desks a worker actually works
-- ---------------------------------------------------------------------------

-- One row per held skill, with the proficiency roll that scales it.
--
-- `proficiency_pct` is a SMALLINT of whole percent, not a float. rollSkills draws
-- `randInt(rng, 60, 100) / 100`, so the integer is the value the generator
-- actually produced and the division is a presentation step. Storing the quotient
-- as a float would push a representation error into the one input the yield
-- calculation multiplies by, for no gain at all.
create table public.xployee_skills (
  xployee_id      bigint   not null references public.xployees (id) on delete cascade,
  -- Draw order, 0-based: the order the skills were rolled, which is the order the
  -- xployee sheet lists them.
  slot            smallint not null check (slot between 0 and 3),
  skill_id        text     not null references public.skills (id) on delete restrict,
  proficiency_pct smallint not null check (proficiency_pct between 60 and 100),
  primary key (xployee_id, slot),
  -- A worker cannot hold the same skill twice: pickDistinct draws without
  -- replacement, and a duplicate would double-count one desk in the blend.
  unique (xployee_id, skill_id)
);

create index xployee_skills_skill_idx on public.xployee_skills (skill_id);

comment on table public.xployee_skills is
  'The desks one worker works, in draw order. proficiency_pct is whole percent — the integer randInt actually rolled — so the yield input carries no float rounding.';

-- The join the app would otherwise write in four places. `security_invoker` so
-- the caller's RLS applies rather than the view owner's: a view is not a way to
-- read past a policy.
create view public.xployee_desks with (security_invoker = true) as
  select
    xs.xployee_id,
    xs.slot,
    s.id     as skill_id,
    s.label,
    s.desk,
    s.ticker,
    s.base_apy,
    xs.proficiency_pct,
    (xs.proficiency_pct::numeric / 100)              as proficiency,
    round(s.base_apy * xs.proficiency_pct / 100, 6)  as effective_apy
  from public.xployee_skills xs
  join public.skills s on s.id = xs.skill_id;

comment on view public.xployee_desks is
  'xployee_skills joined to the skill registry with the effective rate computed. Read this rather than recomputing base_apy x proficiency at a call site.';

-- ---------------------------------------------------------------------------
-- reveal_order — the mint permutation, materialised
-- ---------------------------------------------------------------------------

-- Why a table and not an algorithm: `mintOrder()` in src/lib/collection.ts is a
-- Fisher–Yates shuffle over mulberry32, seeded from an FNV-1a hash of the string
-- 'mintorder'. Reproducing that in plpgsql means reproducing Math.imul's 32-bit
-- wraparound and the exact float arithmetic of `Math.floor(rng() * (i + 1))`, and
-- a single bit of disagreement anywhere in 5,000 iterations reorders the entire
-- tail of the collection. The permutation is 5,000 integers; it is cheaper and
-- very much safer to write them down than to maintain a second generator that has
-- to agree with the first forever.
--
-- WHAT IT IS FOR. Rarity is positional, so handing serials out in ascending order
-- would give the first 150 mints every X-RATED in existence and make every mint
-- past #2000 uncommon forever — the mint would stop being a lottery and become a
-- queue position. Dealing from a shuffle restores the lottery while keeping the
-- low numbers genuinely rare.
--
-- WHAT MAKES A SERIAL UNREPEATABLE. `serial` is UNIQUE and `draw_position` is the
-- primary key, so the permutation cannot contain a duplicate however it was
-- loaded — that is a constraint, not a convention, and it holds even if every
-- function in this schema is wrong. `claimed_by` moving from null to a wallet is
-- the whole of assignment, and the dealer in 20260806090500 takes its row with
-- `for update skip locked`, so two concurrent mints take two different positions
-- instead of racing for one.
create table public.reveal_order (
  -- 0-based draw position: the Nth mint takes position N.
  draw_position integer primary key check (draw_position >= 0 and draw_position < public.max_supply()),
  serial        integer not null unique check (serial >= 0 and serial < public.max_supply()),
  -- Who holds it, or null while it is still in the pool.
  --
  -- Deliberately NOT a foreign key to public.wallets: a wallet row is an optional
  -- profile that may never be created, and a mint must never fail because the
  -- buyer did not fill one in first.
  claimed_by    public.base58_address,
  claimed_at    timestamptz,
  -- How the position left the pool.
  --
  --   'genesis'  — one of the 512 pre-hired workers the simulated collection
  --                ships with (HIRED_COUNT in src/lib/collection.ts). Reserved at
  --                seed time so a real mint can never be dealt a serial the app
  --                is already rendering as somebody else's.
  --   'reserved' — held by a live mint reservation; not burned for yet.
  --   'minted'   — burned for, verified on chain, assigned.
  claim_kind    text check (claim_kind in ('genesis', 'reserved', 'minted')),
  constraint reveal_order_claim_is_complete check (
    (claimed_by is null and claimed_at is null and claim_kind is null)
    or (claimed_at is not null and claim_kind is not null)
  )
);

-- The dealer's predicate, and the only index it needs: the lowest unclaimed
-- position. Partial, so the scan is over the remaining pool rather than the whole
-- permutation — and it shrinks as the collection sells out.
create index reveal_order_pool_idx on public.reveal_order (draw_position) where claimed_at is null;
create index reveal_order_claimed_by_idx on public.reveal_order (claimed_by) where claimed_by is not null;

comment on table public.reveal_order is
  'The seeded mint permutation from src/lib/collection.ts, written down rather than recomputed. Position N is the serial the Nth mint receives; positions 0..511 are reserved for the genesis crew the app already renders.';

-- ---------------------------------------------------------------------------
-- Agreement check — the literals against the registries
-- ---------------------------------------------------------------------------

-- Recomputes the four serial bands from public.tiers exactly the way
-- src/lib/tiers.ts does (rarest-first, round(supply x maxSupply) each, the last
-- band absorbing the remainder) and raises if tier_for_id disagrees with any of
-- them. Then does the same for the skill counts and the trait vocabulary sizes.
--
-- This is what keeps the duplication honest.
do $$
declare
  v_max    integer := public.max_supply();
  v_start  integer := 0;
  v_end    integer;
  v_tier   text;
  v_order  text[] := array['xrated', 'expert', 'mid', 'entry'];
  v_supply numeric;
  v_total  numeric;
  v_rec    record;
  i        integer;
begin
  select sum(supply) into v_total from public.tiers;
  if v_total <> 1 then
    raise exception 'tier supply shares sum to %, not 1', v_total;
  end if;

  for i in 1 .. array_length(v_order, 1) loop
    v_tier := v_order[i];
    select supply into v_supply from public.tiers where id = v_tier;
    if v_supply is null then
      raise exception 'tier % is missing from public.tiers', v_tier;
    end if;
    -- The final band takes whatever the rounding left over, which is why a share
    -- table that rounds down cannot leave a gap of unassigned serials.
    v_end := case
               when i = array_length(v_order, 1) then v_max
               else v_start + round(v_supply * v_max)::integer
             end;

    if public.tier_for_id(v_start) <> v_tier then
      raise exception 'tier_for_id(%) is %, expected % — the literals in tier_for_id() no longer match public.tiers',
        v_start, public.tier_for_id(v_start), v_tier;
    end if;
    if public.tier_for_id(v_end - 1) <> v_tier then
      raise exception 'tier_for_id(%) is %, expected % — a band end has drifted',
        v_end - 1, public.tier_for_id(v_end - 1), v_tier;
    end if;
    if v_end < v_max and public.tier_for_id(v_end) = v_tier then
      raise exception 'tier % does not end at %, so its band is wider than public.tiers says', v_tier, v_end;
    end if;

    v_start := v_end;
  end loop;

  if v_start <> v_max then
    raise exception 'the tier bands cover % serials, not %', v_start, v_max;
  end if;

  for v_rec in select id, skills from public.tiers loop
    if public.skills_for_tier(v_rec.id) <> v_rec.skills then
      raise exception 'skills_for_tier(%) is %, but public.tiers says %',
        v_rec.id, public.skills_for_tier(v_rec.id), v_rec.skills;
    end if;
  end loop;

  -- The trait bounds in xployees_traits_in_vocabulary, against the vocabulary
  -- itself. The check cannot ask the table, so this asks on its behalf.
  for v_rec in
    select slot, max(idx) as top, count(*) as n from public.trait_values group by slot
  loop
    if v_rec.top <> v_rec.n - 1 then
      raise exception 'trait vocabulary % has gaps: % entries but a top index of %',
        v_rec.slot, v_rec.n, v_rec.top;
    end if;
    if (v_rec.slot = 'uniform'   and v_rec.top <> 7)
    or (v_rec.slot = 'head'      and v_rec.top <> 9)
    or (v_rec.slot = 'face'      and v_rec.top <> 7)
    or (v_rec.slot = 'accessory' and v_rec.top <> 9) then
      raise exception 'trait vocabulary % now tops out at %, which xployees_traits_in_vocabulary does not allow for',
        v_rec.slot, v_rec.top;
    end if;
  end loop;
end;
$$;

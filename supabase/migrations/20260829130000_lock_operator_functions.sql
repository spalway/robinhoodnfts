-- Close two findings the Supabase security linter raised on the first build of
-- this project's database. Neither is exploitable for theft; both are the kind
-- of loose default that stops being harmless the moment something else is wrong.

-- ---------------------------------------------------------------------------
-- 1. assign_genesis_crew was an unauthenticated write endpoint
-- ---------------------------------------------------------------------------
-- It is SECURITY DEFINER and was executable by anon, which means anyone on the
-- internet could POST /rest/v1/rpc/assign_genesis_crew and cause an UPDATE over
-- public.genesis_crew.
--
-- The blast radius is genuinely small — it can only set `owner` to the
-- dev_wallet already in protocol_config, so a caller cannot name a destination
-- and cannot move a row to themselves. What they CAN do is run an operator's
-- maintenance action at a time of their choosing, repeatedly.
--
-- Nothing in src/ or supabase/functions/ calls it. It is a console tool for the
-- operator, so it gets the same treatment as xnft_issue_serial: service_role
-- only. `from public` first, because EXECUTE is granted to PUBLIC by default and
-- revoking from anon alone would leave that default in place.
revoke execute on function public.assign_genesis_crew() from public;
revoke execute on function public.assign_genesis_crew() from anon, authenticated;
grant  execute on function public.assign_genesis_crew() to service_role;

-- ---------------------------------------------------------------------------
-- 2. touch_protocol_config had a mutable search_path
-- ---------------------------------------------------------------------------
-- The standard escalation shape: a function that resolves unqualified names at
-- call time can be pointed at an attacker's schema by anyone able to set
-- search_path, and this one fires as a trigger on the row that configures the
-- protocol. Pinning it to '' forces every reference inside to be schema
-- qualified, which is what every other function in this schema already does.
alter function public.touch_protocol_config() set search_path = '';

-- ---------------------------------------------------------------------------
-- Prove both, rather than trusting that they took
-- ---------------------------------------------------------------------------
do $$
begin
  if has_function_privilege('anon', 'public.assign_genesis_crew()', 'execute')
     or has_function_privilege('authenticated', 'public.assign_genesis_crew()', 'execute')
  then
    raise exception 'assign_genesis_crew is still reachable without service_role';
  end if;

  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'touch_protocol_config'
       and p.proconfig @> array['search_path=']
  ) then
    raise exception 'touch_protocol_config still has a mutable search_path';
  end if;
end;
$$;

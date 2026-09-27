-- Hermes runs at most three model iterations in the Sutra image. Profile token
-- limits are per completion; reserve and reconciliation ceilings cover all 3.
create or replace function public.sutra_snapshot_agent_model_spend_profile()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare profile public.agent_model_spend_profiles%rowtype; expected numeric(14,2);
begin
  select * into profile from public.agent_model_spend_profiles p
    where p.provider=new.provider and p.model=new.model and p.active;
  if not found then raise exception 'no active founder-configured price profile for Hermes route' using errcode='23514'; end if;
  expected := greatest(0.01,ceil((profile.max_input_tokens*3*profile.input_eur_per_million_tokens
    + profile.max_output_tokens*3*profile.output_eur_per_million_tokens)/10000)/100);
  if new.reserved_amount <> expected then
    raise exception 'worker quote differs from database model cost ceiling' using errcode='42501';
  end if;
  new.input_eur_per_million_tokens := profile.input_eur_per_million_tokens;
  new.output_eur_per_million_tokens := profile.output_eur_per_million_tokens;
  new.max_input_tokens := profile.max_input_tokens;
  new.max_output_tokens := profile.max_output_tokens;
  return new;
end $$;

create or replace function public.sutra_validate_agent_model_reconciliation()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare expected numeric(14,2);
begin
  if new.status in ('reconciled','overrun') and old.status is distinct from new.status then
    if new.input_tokens is null or new.output_tokens is null
      or new.input_tokens > old.max_input_tokens*3 or new.output_tokens > old.max_output_tokens*3 then
      raise exception 'reported model usage exceeds the reserved run token ceiling' using errcode='23514';
    end if;
    expected := ceil((new.input_tokens*old.input_eur_per_million_tokens
      + new.output_tokens*old.output_eur_per_million_tokens)/10000)/100;
    if new.actual_amount <> expected then
      raise exception 'worker-reported model cost differs from database reconciliation' using errcode='42501';
    end if;
  end if;
  return new;
end $$;

create or replace function public.sutra_reserve_agent_run_spend_from_profile(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_provider text,p_model text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare profile public.agent_model_spend_profiles%rowtype; reserve_amount numeric(14,2); result jsonb;
begin
  select * into profile from public.agent_model_spend_profiles p
    where p.provider=p_provider and p.model=p_model and p.active;
  if not found then raise exception 'no active founder-configured price profile for Hermes route' using errcode='23514'; end if;
  reserve_amount := greatest(0.01,ceil((profile.max_input_tokens*3*profile.input_eur_per_million_tokens
    + profile.max_output_tokens*3*profile.output_eur_per_million_tokens)/10000)/100);
  result := public.sutra_reserve_agent_run_spend(p_worker_id,p_run_id,p_lease_token,p_provider,p_model,reserve_amount);
  return result || jsonb_build_object('max_input_tokens',profile.max_input_tokens,
    'max_output_tokens',profile.max_output_tokens,'input_eur_per_million_tokens',profile.input_eur_per_million_tokens,
    'output_eur_per_million_tokens',profile.output_eur_per_million_tokens,'max_model_iterations',3);
end $$;

create function public.sutra_reconcile_agent_run_spend_from_usage(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_reservation_id uuid,
  p_provider text,p_model text,p_input_tokens bigint,p_output_tokens bigint,p_usage jsonb,p_usage_known boolean
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare reservation public.agent_run_spend_reservations%rowtype; actual_amount numeric(14,2);
begin
  select * into reservation from public.agent_run_spend_reservations s where s.id=p_reservation_id;
  if not found then raise exception 'agent spend reservation was not found' using errcode='42501'; end if;
  if p_usage_known then
    if p_input_tokens is null or p_input_tokens<0 or p_output_tokens is null or p_output_tokens<0 then
      raise exception 'malformed model token usage' using errcode='22023';
    end if;
    actual_amount := ceil((p_input_tokens*reservation.input_eur_per_million_tokens
      + p_output_tokens*reservation.output_eur_per_million_tokens)/10000)/100;
  end if;
  return public.sutra_reconcile_agent_run_spend(p_worker_id,p_run_id,p_lease_token,p_reservation_id,
    p_provider,p_model,actual_amount,p_input_tokens,p_output_tokens,p_usage,p_usage_known);
end $$;

create function public.sutra_get_agent_model_spend_profile(p_provider text,p_model text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare profile public.agent_model_spend_profiles%rowtype;
begin
  if p_provider is null or p_provider !~ '^[a-z0-9][a-z0-9_-]{0,79}$'
    or p_model is null or length(p_model) not between 1 and 200 or p_model ~ '[[:cntrl:]]' then
    raise exception 'malformed model profile lookup' using errcode='22023';
  end if;
  select * into profile from public.agent_model_spend_profiles p
    where p.provider=p_provider and p.model=p_model and p.active;
  if not found then return jsonb_build_object('configured',false); end if;
  return jsonb_build_object('configured',true,'provider',profile.provider,'model',profile.model,
    'input_eur_per_million_tokens',profile.input_eur_per_million_tokens,
    'output_eur_per_million_tokens',profile.output_eur_per_million_tokens,
    'max_input_tokens',profile.max_input_tokens,'max_output_tokens',profile.max_output_tokens,
    'max_model_iterations',3);
end $$;

revoke all on function public.sutra_reconcile_agent_run_spend_from_usage(text,uuid,uuid,uuid,text,text,bigint,bigint,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.sutra_reconcile_agent_run_spend_from_usage(text,uuid,uuid,uuid,text,text,bigint,bigint,jsonb,boolean) to service_role;
revoke all on function public.sutra_get_agent_model_spend_profile(text,text) from public,anon,authenticated;
grant execute on function public.sutra_get_agent_model_spend_profile(text,text) to service_role;

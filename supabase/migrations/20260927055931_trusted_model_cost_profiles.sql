-- Model prices and token ceilings are company state, not worker-provided quotes.
create table public.agent_model_spend_profiles (
  provider text not null check (provider ~ '^[a-z0-9][a-z0-9_-]{0,79}$'),
  model text not null check (length(model) between 1 and 200 and model !~ '[[:cntrl:]]'),
  input_eur_per_million_tokens numeric(18,8) not null check (input_eur_per_million_tokens >= 0),
  output_eur_per_million_tokens numeric(18,8) not null check (output_eur_per_million_tokens >= 0),
  max_input_tokens integer not null check (max_input_tokens between 1 and 1000000),
  max_output_tokens integer not null check (max_output_tokens between 1 and 32768),
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by text not null,
  primary key (provider,model),
  check (input_eur_per_million_tokens > 0 or output_eur_per_million_tokens > 0)
);
alter table public.agent_model_spend_profiles enable row level security;
revoke all on public.agent_model_spend_profiles from public,anon,authenticated,service_role;
alter table public.agent_run_spend_reservations
  add column input_eur_per_million_tokens numeric(18,8),
  add column output_eur_per_million_tokens numeric(18,8),
  add column max_input_tokens integer,
  add column max_output_tokens integer;

create function public.sutra_snapshot_agent_model_spend_profile()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare profile public.agent_model_spend_profiles%rowtype; expected numeric(14,2);
begin
  select * into profile from public.agent_model_spend_profiles p
    where p.provider=new.provider and p.model=new.model and p.active;
  if not found then raise exception 'no active founder-configured price profile for Hermes route' using errcode='23514'; end if;
  expected := greatest(0.01,ceil((profile.max_input_tokens*profile.input_eur_per_million_tokens
    + profile.max_output_tokens*profile.output_eur_per_million_tokens)/10000)/100);
  if new.reserved_amount <> expected then
    raise exception 'worker quote differs from database model cost ceiling' using errcode='42501';
  end if;
  new.input_eur_per_million_tokens := profile.input_eur_per_million_tokens;
  new.output_eur_per_million_tokens := profile.output_eur_per_million_tokens;
  new.max_input_tokens := profile.max_input_tokens;
  new.max_output_tokens := profile.max_output_tokens;
  return new;
end $$;
create trigger agent_run_spend_snapshot_profile before insert on public.agent_run_spend_reservations
  for each row execute function public.sutra_snapshot_agent_model_spend_profile();

create function public.sutra_validate_agent_model_reconciliation()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare expected numeric(14,2);
begin
  if new.status in ('reconciled','overrun') and old.status is distinct from new.status then
    if new.input_tokens is null or new.output_tokens is null
      or new.input_tokens > old.max_input_tokens or new.output_tokens > old.max_output_tokens then
      raise exception 'reported model usage exceeds the reserved token ceiling' using errcode='23514';
    end if;
    expected := ceil((new.input_tokens*old.input_eur_per_million_tokens
      + new.output_tokens*old.output_eur_per_million_tokens)/10000)/100;
    if new.actual_amount <> expected then
      raise exception 'worker-reported model cost differs from database reconciliation' using errcode='42501';
    end if;
  end if;
  return new;
end $$;
create trigger agent_run_spend_validate_reconciliation before update of status,actual_amount,input_tokens,output_tokens
  on public.agent_run_spend_reservations for each row execute function public.sutra_validate_agent_model_reconciliation();

create function public.sutra_set_agent_model_spend_profile(
  p_founder_telegram_user_id text,p_provider text,p_model text,
  p_input_eur_per_million_tokens numeric,p_output_eur_per_million_tokens numeric,
  p_max_input_tokens integer,p_max_output_tokens integer,p_active boolean default true
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text;
begin
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the founder can configure model spend profiles' using errcode='42501';
  end if;
  if p_provider is null or p_provider !~ '^[a-z0-9][a-z0-9_-]{0,79}$'
    or p_model is null or length(p_model) not between 1 and 200 or p_model ~ '[[:cntrl:]]'
    or p_input_eur_per_million_tokens is null or p_input_eur_per_million_tokens < 0
    or p_input_eur_per_million_tokens > 1000000 or p_output_eur_per_million_tokens is null
    or p_output_eur_per_million_tokens < 0 or p_output_eur_per_million_tokens > 1000000
    or (p_input_eur_per_million_tokens=0 and p_output_eur_per_million_tokens=0)
    or p_max_input_tokens not between 1 and 1000000 or p_max_output_tokens not between 1 and 32768
    or p_active is null then
    raise exception 'invalid model spend profile' using errcode='22023';
  end if;
  insert into public.agent_model_spend_profiles(provider,model,input_eur_per_million_tokens,
      output_eur_per_million_tokens,max_input_tokens,max_output_tokens,active,updated_at,updated_by)
    values(p_provider,p_model,p_input_eur_per_million_tokens,p_output_eur_per_million_tokens,
      p_max_input_tokens,p_max_output_tokens,p_active,now(),founder_id)
    on conflict(provider,model) do update set input_eur_per_million_tokens=excluded.input_eur_per_million_tokens,
      output_eur_per_million_tokens=excluded.output_eur_per_million_tokens,
      max_input_tokens=excluded.max_input_tokens,max_output_tokens=excluded.max_output_tokens,
      active=excluded.active,updated_at=now(),updated_by=founder_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'governance.agent_model_spend_profile_changed','agent_model_spend_profile',p_provider||':'||p_model,
      jsonb_build_object('input_eur_per_million_tokens',p_input_eur_per_million_tokens,
        'output_eur_per_million_tokens',p_output_eur_per_million_tokens,'max_input_tokens',p_max_input_tokens,
        'max_output_tokens',p_max_output_tokens,'active',p_active));
  return jsonb_build_object('updated',true,'provider',p_provider,'model',p_model);
end $$;

revoke all on function public.sutra_snapshot_agent_model_spend_profile() from public,anon,authenticated,service_role;
revoke all on function public.sutra_validate_agent_model_reconciliation() from public,anon,authenticated,service_role;
revoke all on function public.sutra_set_agent_model_spend_profile(text,text,text,numeric,numeric,integer,integer,boolean) from public,anon,authenticated;
grant execute on function public.sutra_set_agent_model_spend_profile(text,text,text,numeric,numeric,integer,integer,boolean) to service_role;

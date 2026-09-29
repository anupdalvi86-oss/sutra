-- A founder can queue one tightly bounded Kimi metering probe. It is a
-- separate operational project with a €0.10 project cap; ordinary role routes
-- remain OpenAI and existing unknown reservations are untouched.

create table public.provider_usage_probes (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id),
  agent_run_id uuid not null unique references public.agent_runs(id),
  requested_by text not null,
  provider text not null check (provider = 'kimi-coding'),
  model text not null check (model = 'kimi-k2.6'),
  maximum_reservation_eur numeric(8,2) not null check (maximum_reservation_eur = 0.10),
  status text not null check (status in ('queued','running','succeeded','failed','blocked')),
  usage_envelope_shape text,
  response_context_shape text,
  failure_code text,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

create unique index provider_usage_probe_one_active_idx on public.provider_usage_probes ((true))
  where status in ('queued','running','blocked');
alter table public.provider_usage_probes enable row level security;
revoke all on public.provider_usage_probes from public,anon,authenticated,service_role;
grant select on public.provider_usage_probes to service_role;

create function public.sutra_founder_queue_kimi_usage_probe(p_founder_telegram_user_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  founder_id text;
  ceo public.agents%rowtype;
  profile public.agent_model_spend_profiles%rowtype;
  project_id uuid := gen_random_uuid();
  run_id uuid := gen_random_uuid();
  probe_id uuid := gen_random_uuid();
  project_slug text;
  calculated_reserve numeric(14,2);
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64 then
    raise exception 'malformed Kimi probe request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can queue a Kimi probe' using errcode='42501';
  end if;
  if exists(select 1 from public.provider_usage_probes where status in ('queued','running','blocked')) then
    raise exception 'a Kimi usage probe is already active' using errcode='23505';
  end if;
  select * into profile from public.agent_model_spend_profiles
    where provider='kimi-coding' and model='kimi-k2.6' and active for share;
  if not found then raise exception 'the exact Kimi price profile is not active' using errcode='23514'; end if;
  calculated_reserve := greatest(0.01,ceil((profile.max_input_tokens*3*profile.input_eur_per_million_tokens
    + profile.max_output_tokens*3*profile.output_eur_per_million_tokens)/10000)/100);
  if calculated_reserve > 0.10 then
    raise exception 'Kimi price profile exceeds the probe''s fixed EUR 0.10 cap' using errcode='23514';
  end if;
  select * into ceo from public.agents where slug='ceo' and active;
  if not found then raise exception 'active CEO agent is unavailable' using errcode='23514'; end if;

  project_slug := 'sutra-kimi-usage-probe-'||substr(replace(project_id::text,'-',''),1,12);
  insert into public.projects(id,slug,name,description,status,owner_agent_id,department_id,
    budget_amount,budget_currency,requested_budget,currency,created_by)
  values(project_id,project_slug,'Sutra Kimi usage verification',
    'Founder-authorized one-shot operational probe. Its only purpose is to verify that the exact Kimi route reports usage that reconciles through Sutra. No ordinary role route, project delivery, external contact, merge, or release is authorized.',
    'approved',ceo.id,ceo.department_id,0.10,'EUR',0.10,'EUR',founder_id);
  insert into public.budgets(scope,scope_key,period,currency,limit_amount,warning_percent,hard_stop,active)
    values('project',project_id::text,'lifetime','EUR',0.10,80,true,true);
  insert into public.decisions(project_id,agent_id,decision_type,summary,rationale,evidence)
    values(project_id,ceo.id,'founder_operational_authorization',
      'Founder authorized one Kimi usage reconciliation probe up to EUR 0.10.',
      'This one-shot internal diagnostic may make one database-reserved provider request using the active Kimi price profile. Existing spend policies and the company monthly hard stop remain in force. It does not enable ordinary Kimi routes or authorize any other project spending or external action.',
      '[]'::jsonb);
  insert into public.agent_runs(id,agent_id,project_id,trigger_type,status,input,output,run_order,attempt_count)
    values(run_id,ceo.id,project_id,'founder_proposal','queued',
      jsonb_build_object('request','Run one internal Kimi usage and spend-reconciliation probe. Do not use tools, browse, or make external claims. Return a short JSON response.',
        'provider_usage_probe','kimi'),
      '{}'::jsonb,1,0);
  insert into public.provider_usage_probes(id,project_id,agent_run_id,requested_by,provider,model,
    maximum_reservation_eur,status)
    values(probe_id,project_id,run_id,founder_id,'kimi-coding','kimi-k2.6',0.10,'queued');
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.kimi_usage_probe_requested','provider_usage_probe',probe_id::text,
      jsonb_build_object('project_id',project_id,'agent_run_id',run_id,'provider','kimi-coding',
        'model','kimi-k2.6','maximum_reservation_eur',0.10,'one_provider_request',true,
        'existing_unknown_reservations_preserved',true,'ordinary_kimi_routes_enabled',false));
  return jsonb_build_object('probe_id',probe_id,'project_id',project_id,'run_id',run_id,
    'status','queued','maximum_reservation_eur',0.10,'ordinary_kimi_routes_enabled',false);
end;
$$;

revoke all on function public.sutra_founder_queue_kimi_usage_probe(text) from public,anon,authenticated;
grant execute on function public.sutra_founder_queue_kimi_usage_probe(text) to service_role;

-- Kimi may be reserved only for the exact founder-created probe run. The
-- database-derived profile still determines the reservation amount and token
-- ceiling, and the normal central expense authorization applies afterward.
create or replace function public.sutra_reserve_agent_run_spend_from_profile(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_provider text,p_model text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  profile public.agent_model_spend_profiles%rowtype;
  run_row public.agent_runs%rowtype;
  probe_row public.provider_usage_probes%rowtype;
  reserve_amount numeric(14,2);
  result jsonb;
begin
  select * into run_row from public.agent_runs r where r.id=p_run_id and r.status='running'
    and r.lease_token=p_lease_token and r.lease_expires_at>=now();
  if not found then raise exception 'agent run lease is invalid or expired' using errcode='42501'; end if;
  if p_provider='kimi-coding' or run_row.input->>'provider_usage_probe'='kimi' then
    select * into probe_row from public.provider_usage_probes p where p.agent_run_id=run_row.id
      and p.project_id=run_row.project_id and p.status='running' for update;
    if not found or run_row.trigger_type<>'founder_proposal' or run_row.run_order<>1
      or run_row.attempt_count<>1 or run_row.input->>'provider_usage_probe'<>'kimi'
      or p_provider<>'kimi-coding' or p_model<>'kimi-k2.6'
      or probe_row.provider<>'kimi-coding' or probe_row.model<>'kimi-k2.6' then
      raise exception 'Kimi route is reserved for one founder-authorized probe attempt' using errcode='42501';
    end if;
  end if;
  select * into profile from public.agent_model_spend_profiles p
    where p.provider=p_provider and p.model=p_model and p.active;
  if not found then raise exception 'no active founder-configured price profile for Hermes route' using errcode='23514'; end if;
  reserve_amount := greatest(0.01,ceil((profile.max_input_tokens*3*profile.input_eur_per_million_tokens
    + profile.max_output_tokens*3*profile.output_eur_per_million_tokens)/10000)/100);
  if p_provider='kimi-coding' and reserve_amount>0.10 then
    raise exception 'Kimi price profile exceeds the probe cap' using errcode='23514';
  end if;
  result := public.sutra_reserve_agent_run_spend(p_worker_id,p_run_id,p_lease_token,p_provider,p_model,reserve_amount);
  return result || jsonb_build_object('max_input_tokens',profile.max_input_tokens,
    'max_output_tokens',profile.max_output_tokens,'input_eur_per_million_tokens',profile.input_eur_per_million_tokens,
    'output_eur_per_million_tokens',profile.output_eur_per_million_tokens,'max_model_iterations',3);
end;
$$;

revoke all on function public.sutra_reserve_agent_run_spend_from_profile(text,uuid,uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.sutra_reserve_agent_run_spend_from_profile(text,uuid,uuid,text,text)
  to service_role;

create function public.sutra_sync_provider_usage_probe_status()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  probe_row public.provider_usage_probes%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype;
begin
  select * into probe_row from public.provider_usage_probes where agent_run_id=new.id for update;
  if not found then return new; end if;

  if new.status='failed' then
    select * into reservation_row from public.agent_run_spend_reservations
      where agent_run_id=new.id and attempt=new.attempt_count and status in ('reserved','started')
      order by created_at desc limit 1 for update;
    if found then
      update public.agent_run_spend_reservations set status='unknown',
        usage=jsonb_build_object('reason','kimi_probe_failed_reservation_preserved'),settled_at=now()
        where id=reservation_row.id;
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system','sutra','agent_run.spend_unknown','agent_run_spend_reservation',reservation_row.id::text,
          jsonb_build_object('run_id',new.id,'reserved_amount',reservation_row.reserved_amount,
            'reason','kimi_probe_failed_reservation_preserved'));
    end if;
  end if;

  update public.provider_usage_probes set
    status=case new.status when 'queued' then 'queued' when 'running' then 'running'
      when 'succeeded' then 'succeeded' when 'blocked' then 'blocked' else 'failed' end,
    usage_envelope_shape=case when new.output->>'usage_envelope_shape' ~ '^[a-z0-9_:=,.-]{1,160}$'
      then new.output->>'usage_envelope_shape' else null end,
    response_context_shape=case when new.output->>'response_context_shape' ~ '^[a-z0-9_:=,.-]{1,160}$'
      then new.output->>'response_context_shape' else null end,
    failure_code=case when new.status in ('failed','blocked') then new.output->>'error_code' else null end,
    finished_at=case when new.status in ('succeeded','failed','blocked') then now() else null end
    where agent_run_id=new.id;
  return new;
end;
$$;

revoke all on function public.sutra_sync_provider_usage_probe_status() from public,anon,authenticated,service_role;
create trigger agent_run_sync_provider_usage_probe
  after update of status,output on public.agent_runs
  for each row execute function public.sutra_sync_provider_usage_probe_status();

create function public.sutra_guard_provider_usage_probe_retry()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='queued' and exists(
    select 1 from public.provider_usage_probes p where p.agent_run_id=old.id
  ) then
    raise exception 'Kimi usage probes are one-shot and cannot be retried' using errcode='42501';
  end if;
  return new;
end;
$$;

revoke all on function public.sutra_guard_provider_usage_probe_retry() from public,anon,authenticated,service_role;
create trigger agent_run_provider_usage_probe_no_retry
  before update of status on public.agent_runs
  for each row execute function public.sutra_guard_provider_usage_probe_retry();

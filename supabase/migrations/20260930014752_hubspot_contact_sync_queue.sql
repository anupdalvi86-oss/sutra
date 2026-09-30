-- Budgeted, task-assigned HubSpot contact export. Only explicitly CRM-consented
-- customer fields may leave Supabase. Request bodies are not copied to this queue.
alter table public.customers
  add column if not exists crm_sync_consent boolean not null default false,
  add column if not exists crm_consent_recorded_at timestamptz,
  add column if not exists crm_consent_source text
    check (crm_consent_source is null or length(crm_consent_source) between 1 and 500),
  add constraint customers_crm_consent_evidence_check
    check (not crm_sync_consent or (crm_consent_recorded_at is not null and crm_consent_source is not null));

create table public.customer_crm_sync_actions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  task_id uuid not null references public.tasks(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  agent_id uuid not null references public.agents(id) on delete restrict,
  initiative_ledger_id uuid not null unique references public.initiative_budget_ledger(id) on delete restrict,
  provider text not null default 'hubspot' check (provider='hubspot'),
  idempotency_key text not null,
  status text not null default 'queued' check (status in ('queued','syncing','synced','failed','unknown','cancelled')),
  attempt_count smallint not null default 0 check (attempt_count between 0 and 1),
  external_contact_id text check (external_contact_id is null or external_contact_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  claim_token uuid,
  lease_expires_at timestamptz,
  last_error_code text check (last_error_code is null or last_error_code in (
    'authorization_revoked','consent_revoked','invalid_contact','provider_rejected','provider_outcome_unknown',
    'provider_response_too_large','malformed_provider_response')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id,idempotency_key),
  check ((status='syncing')=(claim_token is not null and lease_expires_at is not null)),
  check ((status='synced')=(external_contact_id is not null))
);
alter table public.customer_crm_sync_actions enable row level security;
revoke all on public.customer_crm_sync_actions from public,anon,authenticated,service_role;
create index customer_crm_sync_actions_queue_idx
  on public.customer_crm_sync_actions(created_at,id) where status='queued';
create index customer_crm_sync_actions_lease_idx
  on public.customer_crm_sync_actions(lease_expires_at,id) where status='syncing';
create index customer_crm_sync_actions_project_status_idx
  on public.customer_crm_sync_actions(project_id,status,created_at desc);
create index customer_crm_sync_actions_task_idx on public.customer_crm_sync_actions(task_id);
create index customer_crm_sync_actions_customer_idx on public.customer_crm_sync_actions(customer_id);
create index customer_crm_sync_actions_agent_idx on public.customer_crm_sync_actions(agent_id);

create or replace function public.sutra_queue_customer_crm_sync(
  p_agent_id uuid,p_task_id uuid,p_project_id uuid,p_customer_id uuid,
  p_estimated_cost_eur numeric,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  agent_row public.agents%rowtype; task_row public.tasks%rowtype; project_row public.projects%rowtype;
  customer_row public.customers%rowtype; ledger_result jsonb; action_row public.customer_crm_sync_actions%rowtype;
  ledger_key text;
begin
  if p_agent_id is null or p_task_id is null or p_project_id is null or p_customer_id is null
    or p_estimated_cost_eur is null or p_estimated_cost_eur<=0
    or p_estimated_cost_eur::text in ('NaN','Infinity','-Infinity')
    or p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$' then
    raise exception 'malformed customer CRM sync request' using errcode='22023';
  end if;
  select * into agent_row from public.agents where id=p_agent_id and slug='sales' and active;
  if not found then raise exception 'CRM sync requires an active Sales agent' using errcode='42501'; end if;
  select * into task_row from public.tasks where id=p_task_id for update;
  if not found or task_row.project_id<>p_project_id
    or task_row.assigned_agent_id<>p_agent_id or task_row.owner_agent_id<>p_agent_id
    or task_row.status not in ('ready','in_progress','review') then
    raise exception 'CRM sync requires the exact active task assignment' using errcode='42501';
  end if;
  select * into project_row from public.projects where id=p_project_id for update;
  if not found or project_row.status<>'active' or project_row.legal_hold
    or project_row.budget_assessment_status<>'within_cap'
    or project_row.budget_assessment->>'recommended_action'<>'proceed_within_cap'
    or exists(select 1 from public.legal_escalations e where e.project_id=p_project_id and e.status='open') then
    raise exception 'CRM sync is blocked by initiative budget or legal state' using errcode='42501';
  end if;
  select * into customer_row from public.customers where id=p_customer_id for update;
  if not found or customer_row.status not in ('lead','qualified','customer')
    or customer_row.email is null or length(trim(customer_row.email)) not between 3 and 320
    or customer_row.email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or length(trim(customer_row.name)) not between 1 and 160
    or (customer_row.company is not null and length(customer_row.company)>160)
    or customer_row.crm_sync_consent is not true or customer_row.crm_consent_recorded_at is null
    or customer_row.crm_consent_source is null or length(trim(customer_row.crm_consent_source)) not between 1 and 500
    or customer_row.email_unsubscribed_at is not null then
    raise exception 'customer lacks a valid address or CRM data-sharing consent' using errcode='42501';
  end if;
  select * into action_row from public.customer_crm_sync_actions
    where project_id=p_project_id and idempotency_key=p_idempotency_key for update;
  if found then
    if action_row.task_id<>p_task_id or action_row.customer_id<>p_customer_id or action_row.agent_id<>p_agent_id then
      raise exception 'CRM sync idempotency key reused for a different action' using errcode='23505';
    end if;
    return jsonb_build_object('status',action_row.status,'action_id',action_row.id,
      'ledger_id',action_row.initiative_ledger_id,'idempotent',true);
  end if;
  ledger_key:='crm:'||md5(p_project_id::text||':'||p_idempotency_key);
  ledger_result:=public.sutra_authorize_initiative_cost(
    'agent','sales',p_agent_id,p_project_id,'crm','hubspot',
    'Budgeted HubSpot contact upsert',p_estimated_cost_eur,'EUR',ledger_key);
  if ledger_result->>'status' not in ('reserved','already_reserved') then
    raise exception 'CRM sync budget reservation failed' using errcode='23514';
  end if;
  insert into public.customer_crm_sync_actions(project_id,task_id,customer_id,agent_id,
    initiative_ledger_id,idempotency_key)
    values(p_project_id,p_task_id,p_customer_id,p_agent_id,(ledger_result->>'ledger_id')::uuid,p_idempotency_key)
    returning * into action_row;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent','sales','customer.crm_sync_queued','customer_crm_sync_action',action_row.id::text,
      jsonb_build_object('project_id',p_project_id,'task_id',p_task_id,'customer_id',p_customer_id,
        'provider','hubspot','ledger_id',action_row.initiative_ledger_id,
        'estimated_cost_eur',p_estimated_cost_eur));
  return jsonb_build_object('status','queued','action_id',action_row.id,
    'ledger_id',action_row.initiative_ledger_id,'idempotent',false);
end;
$$;
revoke all on function public.sutra_queue_customer_crm_sync(uuid,uuid,uuid,uuid,numeric,text)
  from public,anon,authenticated;
grant execute on function public.sutra_queue_customer_crm_sync(uuid,uuid,uuid,uuid,numeric,text) to service_role;

create or replace function public.sutra_claim_customer_crm_sync_action(p_worker_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare action_row public.customer_crm_sync_actions%rowtype; stale_row record; token uuid;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'CRM sync worker identity is invalid' using errcode='22023';
  end if;
  for stale_row in select a.id,a.initiative_ledger_id from public.customer_crm_sync_actions a
    where a.status='syncing' and a.lease_expires_at<=pg_catalog.clock_timestamp() for update skip locked
  loop
    perform public.sutra_settle_initiative_cost(p_worker_id,stale_row.initiative_ledger_id,null,false);
    update public.customer_crm_sync_actions set status='unknown',claim_token=null,lease_expires_at=null,
      last_error_code='provider_outcome_unknown',updated_at=pg_catalog.now() where id=stale_row.id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',left(p_worker_id,120),'customer.crm_sync_unknown','customer_crm_sync_action',stale_row.id::text,
        pg_catalog.jsonb_build_object('reason','lease_expired','error_code','provider_outcome_unknown'));
  end loop;
  select a.* into action_row from public.customer_crm_sync_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    join public.projects p on p.id=a.project_id join public.tasks t on t.id=a.task_id
    join public.agents g on g.id=a.agent_id join public.customers c on c.id=a.customer_id
    where a.status='queued' and l.status='reserved' and p.status='active'
      and p.budget_assessment_status='within_cap' and p.budget_assessment->>'recommended_action'='proceed_within_cap'
      and not p.legal_hold and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.assigned_agent_id=g.id and t.owner_agent_id=g.id
      and t.status in ('ready','in_progress','review') and g.active and g.slug='sales'
      and c.crm_sync_consent and c.crm_consent_recorded_at is not null and c.crm_consent_source is not null
      and c.email is not null and length(trim(c.email)) between 3 and 320
      and lower(trim(c.email)) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      and length(trim(c.name)) between 1 and 160 and (c.company is null or length(c.company)<=160)
      and c.email_unsubscribed_at is null
    order by a.created_at,a.id limit 1 for update of a skip locked;
  if not found then return null; end if;
  token:=pg_catalog.gen_random_uuid();
  update public.customer_crm_sync_actions set status='syncing',attempt_count=attempt_count+1,
    claim_token=token,lease_expires_at=pg_catalog.clock_timestamp()+interval '2 minutes',
    last_error_code=null,updated_at=pg_catalog.now() where id=action_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_worker_id,120),'customer.crm_sync_claimed','customer_crm_sync_action',action_row.id::text,
      pg_catalog.jsonb_build_object('project_id',action_row.project_id,'task_id',action_row.task_id,
        'ledger_id',action_row.initiative_ledger_id,'attempt',1));
  return pg_catalog.jsonb_build_object('status','claimed','action_id',action_row.id,'claim_token',token,
    'ledger_id',action_row.initiative_ledger_id,'action',pg_catalog.jsonb_build_object(
      'email',pg_catalog.lower(pg_catalog.btrim((select email from public.customers where id=action_row.customer_id))),
      'name',(select name from public.customers where id=action_row.customer_id),
      'company',(select company from public.customers where id=action_row.customer_id)));
end;
$$;
revoke all on function public.sutra_claim_customer_crm_sync_action(text) from public,anon,authenticated;
grant execute on function public.sutra_claim_customer_crm_sync_action(text) to service_role;

create or replace function public.sutra_validate_customer_crm_sync_claim(
  p_worker_id text,p_action_id uuid,p_claim_token uuid
) returns boolean language plpgsql security definer set search_path='' as $$
declare action_row public.customer_crm_sync_actions%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' or p_action_id is null or p_claim_token is null then
    raise exception 'CRM sync claim is malformed' using errcode='22023';
  end if;
  select * into action_row from public.customer_crm_sync_actions a where a.id=p_action_id and a.status='syncing'
    and a.claim_token=p_claim_token and a.lease_expires_at>pg_catalog.clock_timestamp() for update;
  if not found then return false; end if;
  return exists(select 1 from public.initiative_budget_ledger l
    join public.projects p on p.id=action_row.project_id join public.tasks t on t.id=action_row.task_id
    join public.agents g on g.id=action_row.agent_id join public.customers c on c.id=action_row.customer_id
    where l.id=action_row.initiative_ledger_id and l.status='reserved' and p.status='active'
      and p.budget_assessment_status='within_cap' and p.budget_assessment->>'recommended_action'='proceed_within_cap'
      and not p.legal_hold and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.assigned_agent_id=g.id and t.owner_agent_id=g.id
      and t.status in ('ready','in_progress','review') and g.active and g.slug='sales'
      and c.crm_sync_consent and c.crm_consent_recorded_at is not null and c.crm_consent_source is not null
      and c.email is not null and length(trim(c.email)) between 3 and 320
      and lower(trim(c.email)) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      and length(trim(c.name)) between 1 and 160 and (c.company is null or length(c.company)<=160)
      and c.email_unsubscribed_at is null);
end;
$$;
revoke all on function public.sutra_validate_customer_crm_sync_claim(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.sutra_validate_customer_crm_sync_claim(text,uuid,uuid) to service_role;

create or replace function public.sutra_finish_customer_crm_sync_action(
  p_worker_id text,p_action_id uuid,p_claim_token uuid,p_status text,p_external_contact_id text,
  p_error_code text,p_actual_cost_eur numeric,p_cost_known boolean
) returns jsonb language plpgsql security definer set search_path='' as $$
declare action_row public.customer_crm_sync_actions%rowtype; settlement jsonb; audit_action text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' or p_action_id is null or p_claim_token is null
    or p_status is null or p_status not in ('synced','failed','unknown') or p_cost_known is null
    or (p_status='synced' and (p_external_contact_id is null or p_external_contact_id !~ '^[A-Za-z0-9_-]{1,64}$'
      or p_error_code is not null or not p_cost_known or p_actual_cost_eur is distinct from 0::numeric))
    or (p_status='failed' and (p_external_contact_id is not null or p_error_code is null or p_error_code not in (
      'authorization_revoked','invalid_contact','provider_rejected') or not p_cost_known
      or p_actual_cost_eur is distinct from 0::numeric))
    or (p_status='unknown' and (p_external_contact_id is not null or p_error_code is null or p_error_code not in (
      'provider_outcome_unknown','provider_response_too_large','malformed_provider_response')
      or p_cost_known or p_actual_cost_eur is not null))
    or (p_error_code is not null and p_error_code not in ('authorization_revoked','invalid_contact','provider_rejected',
      'provider_outcome_unknown','provider_response_too_large','malformed_provider_response')) then
    raise exception 'CRM sync result is malformed' using errcode='22023';
  end if;
  select * into action_row from public.customer_crm_sync_actions a where a.id=p_action_id and a.status='syncing'
    and a.claim_token=p_claim_token and a.lease_expires_at>pg_catalog.clock_timestamp() for update;
  if not found then raise exception 'CRM sync claim is no longer active' using errcode='42501'; end if;
  settlement:=public.sutra_settle_initiative_cost(p_worker_id,action_row.initiative_ledger_id,p_actual_cost_eur,p_cost_known);
  update public.customer_crm_sync_actions set status=p_status,external_contact_id=p_external_contact_id,
    last_error_code=p_error_code,claim_token=null,lease_expires_at=null,updated_at=pg_catalog.now() where id=p_action_id;
  audit_action:=case p_status when 'synced' then 'customer.crm_sync_succeeded' when 'failed' then 'customer.crm_sync_failed'
    else 'customer.crm_sync_unknown' end;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_worker_id,120),audit_action,'customer_crm_sync_action',p_action_id::text,
      pg_catalog.jsonb_build_object('project_id',action_row.project_id,'task_id',action_row.task_id,
        'ledger_id',action_row.initiative_ledger_id,'error_code',p_error_code,'cost_status',settlement->>'status'));
  return pg_catalog.jsonb_build_object('status',p_status,'action_id',p_action_id,'ledger_status',settlement->>'status');
end;
$$;
revoke all on function public.sutra_finish_customer_crm_sync_action(text,uuid,uuid,text,text,text,numeric,boolean)
  from public,anon,authenticated;
grant execute on function public.sutra_finish_customer_crm_sync_action(text,uuid,uuid,text,text,text,numeric,boolean)
  to service_role;

create or replace function public.sutra_founder_set_customer_crm_consent(
  p_founder_telegram_user_id text,p_customer_id uuid,p_consent boolean,p_evidence_source text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; customer_row public.customers%rowtype; action_row record;
  cancelled_count integer:=0; changed boolean:=false;
begin
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can record CRM sharing consent' using errcode='42501';
  end if;
  if p_customer_id is null or p_consent is null or p_evidence_source is null
      or length(trim(p_evidence_source)) not between 8 and 500 then
    raise exception 'customer CRM consent requires a valid record and evidence source' using errcode='22023';
  end if;
  select * into customer_row from public.customers where id=p_customer_id for update;
  if not found then raise exception 'customer not found' using errcode='P0002'; end if;
  if customer_row.crm_sync_consent is distinct from p_consent
      or (p_consent and customer_row.crm_consent_source is distinct from trim(p_evidence_source)) then
    changed:=true;
    update public.customers set crm_sync_consent=p_consent,
      crm_consent_recorded_at=case when p_consent then now() else null end,
      crm_consent_source=case when p_consent then trim(p_evidence_source) else null end,
      updated_at=now() where id=p_customer_id;
    if not p_consent then
      for action_row in select a.id,a.initiative_ledger_id from public.customer_crm_sync_actions a
        where a.customer_id=p_customer_id and a.status='queued' for update skip locked
      loop
        perform public.sutra_settle_initiative_cost('sutra',action_row.initiative_ledger_id,0,true);
        update public.customer_crm_sync_actions set status='cancelled',last_error_code='consent_revoked',
          updated_at=now() where id=action_row.id and status='queued';
        if found then cancelled_count:=cancelled_count+1; end if;
      end loop;
    end if;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,case when p_consent then 'customer.crm_consent_recorded'
        else 'customer.crm_consent_withdrawn' end,'customer',p_customer_id::text,
        jsonb_build_object('consent',p_consent,'evidence_source',case when p_consent then trim(p_evidence_source) else null end,
          'queued_actions_cancelled',cancelled_count));
  end if;
  return jsonb_build_object('customer_id',p_customer_id,'crm_sync_consent',p_consent,
    'changed',changed,
    'queued_actions_cancelled',cancelled_count);
end;
$$;
revoke all on function public.sutra_founder_set_customer_crm_consent(text,uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.sutra_founder_set_customer_crm_consent(text,uuid,boolean,text)
  to service_role;

-- Keep opt-in and unsubscribe state in company data, not in prompts.
alter table public.customers
  add column if not exists marketing_email_consent boolean not null default false,
  add column if not exists service_email_consent boolean not null default false,
  add column if not exists email_unsubscribed_at timestamptz,
  add column if not exists email_consent_recorded_at timestamptz,
  add column if not exists email_consent_source text
    check (email_consent_source is null or length(email_consent_source) between 1 and 500);

alter table public.projects
  add column if not exists legal_hold boolean not null default false;

create table public.customer_email_actions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  task_id uuid not null references public.tasks(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  agent_id uuid not null references public.agents(id) on delete restrict,
  initiative_ledger_id uuid not null unique references public.initiative_budget_ledger(id) on delete restrict,
  purpose text not null check (purpose in ('sales','marketing','support')),
  recipient_email text not null check (length(recipient_email) between 3 and 320),
  subject text not null check (length(subject) between 1 and 200),
  body_text text not null check (length(body_text) between 1 and 10000),
  status text not null default 'queued' check (status in ('queued','cancelled','sent','failed','unknown')),
  idempotency_key text not null,
  provider_message_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id,idempotency_key)
);
alter table public.customer_email_actions enable row level security;
revoke all on public.customer_email_actions from public,anon,authenticated,service_role;
grant select on public.customer_email_actions to service_role;
create index customer_email_actions_queue_idx
  on public.customer_email_actions(created_at,id) where status='queued';
create index customer_email_actions_project_status_idx
  on public.customer_email_actions(project_id,status,created_at desc);

create or replace function public.sutra_queue_customer_email(
  p_agent_id uuid,p_agent_slug text,p_task_id uuid,p_project_id uuid,p_customer_id uuid,
  p_purpose text,p_subject text,p_body_text text,p_estimated_cost_eur numeric,
  p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  agent_row public.agents%rowtype;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  customer_row public.customers%rowtype;
  ledger_result jsonb;
  action_row public.customer_email_actions%rowtype;
  cost_category text;
  ledger_idempotency_key text;
begin
  if p_agent_id is null or p_agent_slug is null or p_agent_slug not in ('sales','cmo') or p_task_id is null
    or p_project_id is null or p_customer_id is null
    or p_purpose is null or p_purpose not in ('sales','marketing','support')
    or p_subject is null or length(trim(p_subject)) not between 1 and 200
    or p_body_text is null or length(trim(p_body_text)) not between 1 and 10000
    or p_estimated_cost_eur is null or p_estimated_cost_eur<=0
    or p_estimated_cost_eur::text in ('NaN','Infinity','-Infinity')
    or p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$' then
    raise exception 'malformed customer email action' using errcode='22023';
  end if;
  if (p_agent_slug='sales' and p_purpose not in ('sales','support'))
    or (p_agent_slug='cmo' and p_purpose<>'marketing') then
    raise exception 'agent role cannot perform this customer email purpose' using errcode='42501';
  end if;
  select * into agent_row from public.agents where id=p_agent_id and slug=p_agent_slug and active;
  if not found then raise exception 'active agent identity is invalid' using errcode='42501'; end if;
  select * into task_row from public.tasks where id=p_task_id for update;
  if not found or task_row.project_id<>p_project_id
    or task_row.assigned_agent_id<>p_agent_id or task_row.owner_agent_id<>p_agent_id
    or task_row.status not in ('ready','in_progress','review') then
    raise exception 'customer email requires the exact active task assignment' using errcode='42501';
  end if;
  select * into project_row from public.projects where id=p_project_id for update;
  if not found or project_row.status<>'active' or project_row.legal_hold
    or project_row.budget_assessment_status='legal_escalation'
    or exists(select 1 from public.legal_escalations e where e.project_id=p_project_id and e.status='open') then
    raise exception 'customer contact is blocked by inactive initiative or legal hold' using errcode='42501';
  end if;
  select * into customer_row from public.customers where id=p_customer_id for update;
  if not found or customer_row.status not in ('lead','qualified','customer')
    or customer_row.email is null or length(trim(customer_row.email)) not between 3 and 320
    or customer_row.email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or customer_row.email_unsubscribed_at is not null
    or (p_purpose in ('sales','marketing') and (not customer_row.marketing_email_consent
      or customer_row.email_consent_recorded_at is null or customer_row.email_consent_source is null
      or length(trim(customer_row.email_consent_source)) not between 1 and 500))
    or (p_purpose='support' and (not customer_row.service_email_consent
      or customer_row.email_consent_recorded_at is null or customer_row.email_consent_source is null
      or length(trim(customer_row.email_consent_source)) not between 1 and 500)) then
    raise exception 'customer has no valid email or required current consent' using errcode='42501';
  end if;

  select * into action_row from public.customer_email_actions
    where project_id=p_project_id and idempotency_key=p_idempotency_key for update;
  if found then
    if action_row.task_id<>p_task_id or action_row.customer_id<>p_customer_id
      or action_row.agent_id<>p_agent_id or action_row.purpose<>p_purpose
      or action_row.subject<>trim(p_subject) or action_row.body_text<>trim(p_body_text) then
      raise exception 'customer email idempotency key was reused for different content' using errcode='23505';
    end if;
    return jsonb_build_object('status',action_row.status,'action_id',action_row.id,
      'ledger_id',action_row.initiative_ledger_id,'idempotent',true);
  end if;
  cost_category:=case p_purpose when 'sales' then 'sales' when 'marketing' then 'marketing' else 'customer_support' end;
  ledger_idempotency_key:='email:'||md5(p_project_id::text||':'||p_idempotency_key);
  ledger_result:=public.sutra_authorize_initiative_cost(
    'agent',p_agent_slug,p_agent_id,p_project_id,cost_category,'email-provider',
    'Budgeted customer email action',p_estimated_cost_eur,'EUR',ledger_idempotency_key);
  if ledger_result->>'status' not in ('reserved','already_reserved') then
    raise exception 'customer email budget reservation failed' using errcode='23514';
  end if;
  insert into public.customer_email_actions(project_id,task_id,customer_id,agent_id,
    initiative_ledger_id,purpose,recipient_email,subject,body_text,idempotency_key)
    values(p_project_id,p_task_id,p_customer_id,p_agent_id,(ledger_result->>'ledger_id')::uuid,
      p_purpose,lower(trim(customer_row.email)),trim(p_subject),trim(p_body_text),p_idempotency_key)
    returning * into action_row;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',p_agent_slug,'customer.email_queued','customer_email_action',action_row.id::text,
      jsonb_build_object('project_id',p_project_id,'task_id',p_task_id,'customer_id',p_customer_id,
        'purpose',p_purpose,'ledger_id',action_row.initiative_ledger_id,
        'estimated_cost_eur',p_estimated_cost_eur));
  return jsonb_build_object('status','queued','action_id',action_row.id,
    'ledger_id',action_row.initiative_ledger_id,'idempotent',false);
end;
$$;
revoke all on function public.sutra_queue_customer_email(uuid,text,uuid,uuid,uuid,text,text,text,numeric,text)
  from public,anon,authenticated;
grant execute on function public.sutra_queue_customer_email(uuid,text,uuid,uuid,uuid,text,text,text,numeric,text)
  to service_role;

create or replace function public.sutra_founder_set_project_legal_hold(
  p_founder_telegram_user_id text,p_project_id uuid,p_legal_hold boolean,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; project_row public.projects%rowtype;
begin
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can change a project legal hold' using errcode='42501';
  end if;
  if p_project_id is null or p_legal_hold is null or p_reason is null
    or length(trim(p_reason)) not between 8 and 500 then
    raise exception 'malformed project legal hold request' using errcode='22023';
  end if;
  select * into project_row from public.projects where id=p_project_id for update;
  if not found then raise exception 'project not found' using errcode='P0002'; end if;
  if project_row.legal_hold is distinct from p_legal_hold then
    update public.projects set legal_hold=p_legal_hold,updated_at=now() where id=p_project_id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,case when p_legal_hold then 'project.legal_hold_set' else 'project.legal_hold_cleared' end,
        'project',p_project_id::text,jsonb_build_object('reason',left(trim(p_reason),500)));
  end if;
  return jsonb_build_object('project_id',p_project_id,'legal_hold',p_legal_hold,'changed',project_row.legal_hold is distinct from p_legal_hold);
end;
$$;
revoke all on function public.sutra_founder_set_project_legal_hold(text,uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.sutra_founder_set_project_legal_hold(text,uuid,boolean,text) to service_role;

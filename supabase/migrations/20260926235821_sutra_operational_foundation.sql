-- Sutra operational schema. Exposed tables are server-only: RLS is enabled
-- and anon/authenticated receive no table or function privileges.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.agents (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  display_name text not null,
  department_id uuid not null references public.departments(id),
  responsibilities text[] not null default '{}',
  permissions text[] not null default '{}',
  can_delegate_to text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  description text not null,
  status text not null check (status in ('proposed','approved','active','paused','completed','rejected')),
  owner_agent_id uuid references public.agents(id),
  department_id uuid references public.departments(id),
  requested_budget numeric(14,2) not null default 0 check (requested_budget >= 0),
  currency char(3) not null default 'EUR',
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.objectives (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  title text not null,
  description text not null,
  success_metrics jsonb not null default '[]'::jsonb,
  status text not null check (status in ('proposed','active','achieved','cancelled')),
  owner_agent_id uuid references public.agents(id),
  created_at timestamptz not null default now()
);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.projects(id) on delete cascade,
  objective_id uuid references public.objectives(id) on delete cascade,
  parent_task_id uuid references public.tasks(id),
  title text not null,
  description text not null,
  acceptance_criteria jsonb not null default '[]'::jsonb,
  task_type text not null default 'general',
  status text not null default 'backlog' check (status in ('backlog','ready','in_progress','blocked','review','done','cancelled')),
  owner_agent_id uuid references public.agents(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.decisions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.projects(id) on delete cascade,
  agent_id uuid references public.agents(id),
  decision_type text not null,
  summary text not null,
  rationale text not null,
  evidence jsonb not null default '[]'::jsonb,
  decided_at timestamptz not null default now()
);

create table if not exists public.budgets (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('company','project','department','agent','category','vendor')),
  scope_key text not null default '*',
  period text not null check (period in ('transaction','daily','monthly','lifetime')),
  currency char(3) not null default 'EUR',
  limit_amount numeric(14,2) check (limit_amount is null or limit_amount >= 0),
  warning_percent numeric(5,2) not null default 80 check (warning_percent > 0 and warning_percent <= 100),
  hard_stop boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (scope, scope_key, period, currency)
);

create table if not exists public.spending_policies (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  currency char(3) not null default 'EUR',
  min_amount numeric(14,2) not null check (min_amount >= 0),
  max_amount numeric(14,2) check (max_amount is null or max_amount >= min_amount),
  min_inclusive boolean not null default false,
  max_inclusive boolean not null default true,
  required_approvers text[] not null default '{}',
  warning_percent numeric(5,2) not null default 80 check (warning_percent > 0 and warning_percent <= 100),
  hard_stop boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.projects(id),
  department_id uuid references public.departments(id),
  agent_id uuid references public.agents(id),
  category text not null,
  vendor text,
  description text not null,
  amount numeric(14,2) not null check (amount > 0),
  currency char(3) not null default 'EUR',
  status text not null check (status in ('requested','approved','rejected','paid','void')),
  requested_by text not null,
  approved_at timestamptz,
  incurred_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.approvals (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.projects(id),
  expense_id uuid references public.expenses(id),
  approval_type text not null,
  requested_by text not null,
  required_roles text[] not null,
  decisions jsonb not null default '{}'::jsonb,
  amount numeric(14,2),
  currency char(3) not null default 'EUR',
  summary text not null,
  status text not null check (status in ('pending','approved','rejected','cancelled')),
  decided_by text,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.agent_runs (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agents(id),
  project_id uuid references public.projects(id),
  task_id uuid references public.tasks(id),
  trigger_type text not null,
  status text not null check (status in ('queued','running','succeeded','failed','blocked')),
  input jsonb not null default '{}'::jsonb,
  output jsonb not null default '{}'::jsonb,
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_type text not null check (actor_type in ('founder','agent','system')),
  actor_id text not null,
  action text not null,
  resource_type text not null,
  resource_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  company text,
  source text,
  status text not null default 'lead' check (status in ('lead','qualified','customer','inactive')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references public.projects(id),
  name text not null,
  channel text not null,
  status text not null default 'draft' check (status in ('draft','approval_required','approved','active','paused','completed')),
  budget_amount numeric(14,2) not null default 0 check (budget_amount >= 0),
  currency char(3) not null default 'EUR',
  content jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.company_settings (
  key text primary key,
  value jsonb not null,
  governance_sensitive boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);

-- Additive compatibility for the original Supabase schema already in use by
-- the hosted project. Keep its legacy fields and data while adding the richer
-- operational contract used by the policy functions below.
alter table public.projects add column if not exists budget_amount numeric(14,2);
alter table public.projects add column if not exists budget_currency char(3) not null default 'EUR';
alter table public.tasks add column if not exists assigned_agent_id uuid references public.agents(id);
alter table public.tasks add column if not exists priority integer not null default 100;
alter table public.spending_policies add column if not exists scope_type text not null default 'company';
alter table public.spending_policies add column if not exists scope_id text;
alter table public.spending_policies add column if not exists per_transaction_limit numeric(14,2);
alter table public.spending_policies add column if not exists daily_limit numeric(14,2);
alter table public.spending_policies add column if not exists monthly_limit numeric(14,2);
alter table public.spending_policies add column if not exists approval_chain jsonb not null default '[]'::jsonb;
alter table public.spending_policies add column if not exists enabled boolean not null default true;
alter table public.approvals add column if not exists action_type text not null default 'proposal';
alter table public.approvals add column if not exists action_ref text;
alter table public.approvals add column if not exists requested_by_agent_id uuid references public.agents(id);
alter table public.approvals add column if not exists required_role text not null default 'founder';
alter table public.approvals add column if not exists payload jsonb not null default '{}'::jsonb;
alter table public.decisions add column if not exists data jsonb not null default '{}'::jsonb;
alter table public.audit_log add column if not exists data jsonb not null default '{}'::jsonb;
alter table public.company_settings add column if not exists founder_only boolean not null default false;
alter table public.agents add column if not exists name text;
alter table public.agents add column if not exists role text;
alter table public.agents add column if not exists status text not null default 'active';
alter table public.agents add column if not exists authority_level integer not null default 0;
alter table public.agents add column if not exists config jsonb not null default '{}'::jsonb;
alter table public.agents add column if not exists slug text;
alter table public.agents add column if not exists display_name text;
alter table public.agents add column if not exists responsibilities text[] not null default '{}';
alter table public.agents add column if not exists permissions text[] not null default '{}';
alter table public.agents add column if not exists can_delegate_to text[] not null default '{}';
alter table public.agents add column if not exists active boolean not null default true;
update public.agents set
  slug=coalesce(slug,lower(regexp_replace(coalesce(role,name,'agent') || '-' || left(id::text,8),'[^a-zA-Z0-9]+','_','g'))),
  display_name=coalesce(display_name,name,role,'Agent'),
  name=coalesce(name,display_name,role,'Agent'),
  role=coalesce(role,slug,'agent'),
  active=(status='active');
alter table public.agents alter column slug set not null;
alter table public.agents alter column display_name set not null;
create unique index if not exists agents_slug_unique_idx on public.agents(slug);

alter table public.projects add column if not exists slug text;
alter table public.projects add column if not exists department_id uuid references public.departments(id);
alter table public.projects add column if not exists requested_budget numeric(14,2) not null default 0;
alter table public.projects add column if not exists currency char(3) not null default 'EUR';
alter table public.projects add column if not exists created_by text not null default 'legacy';
update public.projects set slug=coalesce(slug,'legacy-' || replace(id::text,'-','')),
  requested_budget=coalesce(requested_budget,budget_amount,0), currency=coalesce(currency,budget_currency,'EUR');
alter table public.projects alter column slug set not null;
create unique index if not exists projects_slug_unique_idx on public.projects(slug);

alter table public.tasks add column if not exists objective_id uuid references public.objectives(id) on delete cascade;
alter table public.tasks add column if not exists owner_agent_id uuid references public.agents(id);
alter table public.tasks add column if not exists task_type text not null default 'general';
alter table public.tasks add column if not exists description text;
alter table public.tasks add column if not exists acceptance_criteria jsonb not null default '[]'::jsonb;
update public.tasks set owner_agent_id=coalesce(owner_agent_id,assigned_agent_id);

alter table public.decisions add column if not exists rationale text;
alter table public.decisions add column if not exists evidence jsonb not null default '[]'::jsonb;
alter table public.decisions add column if not exists decided_at timestamptz not null default now();
alter table public.decisions alter column data set default '{}'::jsonb;

alter table public.spending_policies add column if not exists min_amount numeric(14,2);
alter table public.spending_policies add column if not exists max_amount numeric(14,2);
alter table public.spending_policies add column if not exists min_inclusive boolean not null default false;
alter table public.spending_policies add column if not exists max_inclusive boolean not null default true;
alter table public.spending_policies add column if not exists required_approvers text[] not null default '{}';
alter table public.spending_policies add column if not exists active boolean not null default true;
update public.spending_policies set
  min_amount=coalesce(min_amount,case
    when approval_chain @> '["automatic"]'::jsonb then 0
    when approval_chain @> '["department_head"]'::jsonb then 10
    when approval_chain @> '["cfo"]'::jsonb then 50
    when approval_chain @> '["founder"]'::jsonb then 200 else 0 end),
  max_amount=coalesce(max_amount,case
    when approval_chain @> '["automatic"]'::jsonb then per_transaction_limit
    when approval_chain @> '["department_head"]'::jsonb then per_transaction_limit
    when approval_chain @> '["cfo"]'::jsonb then per_transaction_limit else null end),
  min_inclusive=case when approval_chain @> '["automatic"]'::jsonb or approval_chain @> '["founder"]'::jsonb then true else min_inclusive end,
  max_inclusive=case when approval_chain @> '["cfo"]'::jsonb then false else max_inclusive end,
  required_approvers=case when approval_chain @> '["automatic"]'::jsonb then '{}'::text[] else
    array(select r.role from jsonb_array_elements_text(approval_chain) as r(role) where r.role <> 'automatic') end,
  scope_type=coalesce(scope_type,'company'),
  active=enabled;
create unique index if not exists spending_policies_name_unique_idx on public.spending_policies(name);
alter table public.spending_policies alter column min_amount set not null;

alter table public.expenses add column if not exists requested_by text not null default 'legacy';
alter table public.expenses add column if not exists approved_at timestamptz;
alter table public.expenses add column if not exists incurred_at timestamptz;
alter table public.expenses alter column amount set default 0;
alter table public.expenses alter column currency set default 'EUR';

alter table public.approvals add column if not exists project_id uuid references public.projects(id);
alter table public.approvals add column if not exists expense_id uuid references public.expenses(id);
alter table public.approvals add column if not exists approval_type text not null default 'proposal';
alter table public.approvals add column if not exists requested_by text not null default 'system';
alter table public.approvals add column if not exists required_roles text[] not null default '{founder}';
alter table public.approvals add column if not exists decisions jsonb not null default '{}'::jsonb;
alter table public.approvals add column if not exists amount numeric(14,2);
alter table public.approvals add column if not exists currency char(3) not null default 'EUR';
alter table public.approvals add column if not exists summary text not null default 'Existing approval';
alter table public.approvals alter column action_type set default 'proposal';
alter table public.approvals alter column required_role set default 'founder';
alter table public.approvals alter column payload set default '{}'::jsonb;

alter table public.audit_log add column if not exists details jsonb not null default '{}'::jsonb;
alter table public.audit_log alter column data set default '{}'::jsonb;

alter table public.company_settings add column if not exists governance_sensitive boolean not null default false;
alter table public.company_settings add column if not exists updated_by text not null default 'legacy';

create index if not exists projects_status_created_idx on public.projects(status, created_at desc);
create index if not exists tasks_project_status_idx on public.tasks(project_id, status);
create index if not exists tasks_owner_status_idx on public.tasks(owner_agent_id, status);
create index if not exists decisions_project_decided_idx on public.decisions(project_id, decided_at desc);
create index if not exists expenses_budget_lookup_idx on public.expenses(status, created_at, currency);
create index if not exists expenses_project_idx on public.expenses(project_id, created_at desc);
create index if not exists approvals_pending_idx on public.approvals(status, created_at) where status = 'pending';
create index if not exists agent_runs_project_created_idx on public.agent_runs(project_id, created_at desc);
create index if not exists audit_resource_created_idx on public.audit_log(resource_type, resource_id, created_at desc);
create index if not exists audit_actor_created_idx on public.audit_log(actor_type, actor_id, created_at desc);
create index if not exists customers_status_created_idx on public.customers(status, created_at desc);

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid='public.projects'::regclass and conname='projects_status_allowed_check') then
    alter table public.projects add constraint projects_status_allowed_check
      check (status in ('proposed','approved','active','paused','completed','rejected')) not valid;
    alter table public.projects validate constraint projects_status_allowed_check;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.tasks'::regclass and conname='tasks_status_allowed_check') then
    alter table public.tasks add constraint tasks_status_allowed_check
      check (status in ('backlog','ready','in_progress','blocked','review','done','cancelled')) not valid;
    alter table public.tasks validate constraint tasks_status_allowed_check;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.spending_policies'::regclass and conname='spending_policies_range_valid_check') then
    alter table public.spending_policies add constraint spending_policies_range_valid_check
      check (min_amount >= 0 and (max_amount is null or max_amount >= min_amount)) not valid;
    alter table public.spending_policies validate constraint spending_policies_range_valid_check;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.expenses'::regclass and conname='expenses_amount_positive_check') then
    alter table public.expenses add constraint expenses_amount_positive_check check(amount > 0) not valid;
    alter table public.expenses validate constraint expenses_amount_positive_check;
  end if;
end;
$$;

insert into public.departments (slug, name) values
  ('executive','Executive'), ('product','Product'), ('engineering','Engineering'),
  ('finance','Finance'), ('operations','Operations'), ('marketing','Marketing'),
  ('sales','Sales'), ('governance','Governance'), ('qa','QA'), ('security','Security')
on conflict (slug) do nothing;

insert into public.agents (name,role,status,authority_level,config,slug,display_name,department_id,responsibilities,permissions,can_delegate_to,active)
select seed.display_name,seed.slug,'active',
  case when seed.slug in ('ceo','founder') then 100 when seed.slug in ('cto','cfo','cpo','coo','cmo') then 80 else 50 end,
  jsonb_build_object('responsibilities',seed.responsibilities,'permissions',seed.permissions,'can_delegate_to',seed.can_delegate_to),
  seed.slug, seed.display_name, d.id, seed.responsibilities, seed.permissions, seed.can_delegate_to,true
from (values
  ('ceo','CEO','executive',array['Translate founder objectives into accountable company plans','Coordinate departments and report company status'],array['read_company_state','create_project_proposal','delegate_work'],array['cpo','cto','cfo','coo','cmo','sales','governance_audit']),
  ('cto','CTO','engineering',array['Set technical direction','Assign architecture and engineering work'],array['read_company_state','create_engineering_tasks','request_technical_approval'],array['architect','developer','qa','security','devops']),
  ('cpo','CPO','product',array['Research customer problems','Define product scope and acceptance outcomes'],array['read_product_state','create_product_artifacts'],array['product_manager','sales','marketing']),
  ('cfo','CFO','finance',array['Evaluate budgets and spending requests','Monitor company financial controls'],array['read_financial_state','request_budget_approval'],array['governance_audit']),
  ('coo','COO','operations',array['Coordinate operational readiness and incident response'],array['read_company_state','create_operations_tasks'],array['devops','governance_audit']),
  ('product_manager','Product Manager','product',array['Maintain roadmap, requirements and acceptance criteria'],array['read_product_state','create_product_artifacts'],array['architect','developer','qa']),
  ('architect','Architect','engineering',array['Produce technical designs and interfaces'],array['read_engineering_state','create_design_artifacts'],array['developer','security','devops']),
  ('developer','Developer','engineering',array['Implement approved tasks in GitHub branches and pull requests'],array['read_assigned_tasks','propose_code_changes'],array[]::text[]),
  ('qa','QA','qa',array['Verify acceptance criteria and report reproducible results'],array['read_review_tasks','record_test_results'],array[]::text[]),
  ('security','Security','security',array['Review threat models, dependencies and release risks'],array['read_security_scope','record_security_reviews'],array[]::text[]),
  ('devops','DevOps','engineering',array['Maintain deployment configuration, observability and recovery'],array['read_deployment_state','propose_deployment_changes'],array[]::text[]),
  ('cmo','CMO / Marketing','marketing',array['Prepare positioning and campaign proposals','Never send campaigns before required approvals'],array['read_marketing_state','draft_campaigns'],array['product_manager','sales']),
  ('sales','Sales','sales',array['Qualify leads and prepare sales artifacts','Never send external messages without approved workflow'],array['read_sales_state','draft_lead_artifacts'],array['product_manager','marketing']),
  ('governance_audit','Governance / Audit','governance',array['Audit policy compliance and record independent reviews'],array['read_audit_state','record_audit_findings'],array[]::text[])
) as seed(slug,display_name,department_slug,responsibilities,permissions,can_delegate_to)
join public.departments d on d.slug = seed.department_slug
on conflict (slug) do nothing;

-- €200 and above requires the founder; €50 to below €200 requires both CFO and CEO.
do $$
begin
  if not exists (select 1 from public.spending_policies where active and currency='EUR') then
    insert into public.spending_policies(name,currency,min_amount,max_amount,min_inclusive,max_inclusive,required_approvers,warning_percent,hard_stop,active,scope_type,per_transaction_limit,approval_chain,enabled)
    values
      ('automatic_up_to_10','EUR',0,10,true,true,'{}',80,true,true,'company',10,'["automatic"]'::jsonb,true),
      ('department_head_over_10_to_50','EUR',10,50,false,true,array['department_head'],80,true,true,'company',50,'["department_head"]'::jsonb,true),
      ('cfo_ceo_over_50_under_200','EUR',50,200,false,false,array['cfo','ceo'],80,true,true,'company',200,'["cfo","ceo"]'::jsonb,true),
      ('founder_200_and_over','EUR',200,null,true,false,array['founder'],80,true,true,'company',null,'["founder"]'::jsonb,true);
  end if;
end;
$$;

insert into public.company_settings (key,value,governance_sensitive,founder_only,updated_by) values
  ('currency','"EUR"'::jsonb,false,false,'migration'),
  ('proposal_approval_policy','"database_spending_policies"'::jsonb,true,true,'migration'),
  ('agents_may_increase_own_authority','false'::jsonb,true,true,'migration'),
  ('financial_policy_changes_require_founder','true'::jsonb,true,true,'migration')
on conflict (key) do nothing;

do $$
declare t text;
begin
  foreach t in array array['departments','agents','projects','objectives','tasks','decisions','budgets','spending_policies','expenses','approvals','agent_runs','audit_log','customers','campaigns','company_settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated, service_role', t);
    execute format('grant select on table public.%I to service_role', t);
  end loop;
end;
$$;
revoke create on schema public from public, anon, authenticated, service_role;
revoke insert, update, delete on public.budgets, public.spending_policies, public.company_settings,
  public.audit_log, public.expenses, public.approvals from service_role;
grant select on public.budgets, public.spending_policies, public.company_settings,
  public.audit_log, public.expenses, public.approvals to service_role;
do $$
declare audit_seq text;
begin
  audit_seq := pg_get_serial_sequence('public.audit_log','id');
  if audit_seq is not null then
    execute format('revoke all on sequence %s from anon, authenticated, service_role',audit_seq);
  end if;
end;
$$;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
-- Atomic policy evaluation and expense insertion. Only the trusted server role can
-- execute these RPCs; the service credential is never sent to Hermes or Telegram.
create or replace function public.sutra_authorize_spend(
  p_actor_type text,
  p_actor_id text,
  p_agent_id uuid,
  p_project_id uuid,
  p_department_id uuid,
  p_category text,
  p_vendor text,
  p_description text,
  p_amount numeric,
  p_currency char(3) default 'EUR'
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  policy_row public.spending_policies%rowtype;
  budget_row public.budgets%rowtype;
  used_amount numeric(14,2);
  expense_id uuid;
  approval_id uuid;
  approval_status text;
  actual_department_id uuid;
  warnings text[] := '{}';
begin
  if p_actor_type is null or p_actor_type not in ('founder','agent','system') or p_actor_id is null or length(trim(p_actor_id)) = 0 then
    raise exception 'malformed actor' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 999999999999.99
    or p_amount::text in ('NaN','Infinity','-Infinity')
    or p_currency <> 'EUR' or p_category is null or length(trim(p_category)) = 0 then
    raise exception 'invalid amount, currency, or category' using errcode = '22023';
  end if;
  if p_actor_type = 'agent' and p_actor_id = 'founder' then
    raise exception 'agents cannot impersonate the founder' using errcode = '42501';
  end if;
  if p_actor_type = 'agent' and not exists (select 1 from public.agents a where a.id = p_agent_id and a.slug = p_actor_id and a.active) then
    raise exception 'agent identity is invalid or inactive' using errcode = '42501';
  end if;
  if p_actor_type = 'agent' then
    select a.department_id into actual_department_id from public.agents a where a.id=p_agent_id;
    if p_department_id is not null and p_department_id <> actual_department_id then
      raise exception 'agent cannot claim a different department' using errcode = '42501';
    end if;
    p_department_id := actual_department_id;
  elsif p_project_id is not null then
    select p.department_id into actual_department_id from public.projects p where p.id=p_project_id;
    if p_department_id is not null and actual_department_id is not null and p_department_id <> actual_department_id then
      raise exception 'spend department does not match the project' using errcode = '42501';
    end if;
    p_department_id := coalesce(actual_department_id,p_department_id);
  end if;
  if p_actor_type <> 'agent' and p_agent_id is not null then
    raise exception 'non-agent requests cannot name an agent' using errcode = '42501';
  end if;
  if p_project_id is not null and not exists (
    select 1 from public.projects p where p.id = p_project_id and p.status in ('approved','active')
  ) then
    raise exception 'project spending is blocked until founder approval' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-spending-policy:' || p_currency));
  select * into policy_row from public.spending_policies p
    where p.active and p.currency = p_currency
      and (p_amount > p.min_amount or (p.min_inclusive and p_amount = p.min_amount))
      and (p.max_amount is null or p_amount < p.max_amount or (p.max_inclusive and p_amount = p.max_amount))
    order by p.min_amount desc limit 1;
  if not found then raise exception 'no active spending policy matches this amount' using errcode = '23514'; end if;

  -- Serialize spending checks so concurrent requests cannot overspend a hard cap.
  perform pg_advisory_xact_lock(hashtext('sutra-budget:' || p_currency));
  for budget_row in
    select * from public.budgets b where b.active and b.currency = p_currency
      and ((b.scope = 'company' and b.scope_key = '*') or
        (b.scope = 'project' and (b.scope_key = '*' or b.scope_key = p_project_id::text)) or
        (b.scope = 'department' and (b.scope_key = '*' or b.scope_key = p_department_id::text)) or
        (b.scope = 'agent' and (b.scope_key = '*' or b.scope_key = p_actor_id)) or
        (b.scope = 'category' and (b.scope_key = '*' or lower(b.scope_key) = lower(p_category))) or
        (b.scope = 'vendor' and (b.scope_key = '*' or lower(b.scope_key) = lower(coalesce(p_vendor,'')))))
    order by b.scope, b.scope_key, b.period
    for update
  loop
    if budget_row.limit_amount is null then continue; end if;
    if budget_row.period = 'transaction' then
      used_amount := 0;
    elsif budget_row.period = 'daily' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.status in ('requested','approved','paid') and e.currency = p_currency and e.created_at >= date_trunc('day', now())
          and (budget_row.scope <> 'project' or e.project_id = p_project_id)
          and (budget_row.scope <> 'department' or e.department_id = p_department_id)
          and (budget_row.scope <> 'category' or lower(e.category) = lower(p_category))
          and (budget_row.scope <> 'vendor' or lower(coalesce(e.vendor,'')) = lower(coalesce(p_vendor,'')))
          and (budget_row.scope <> 'agent' or e.agent_id = p_agent_id);
    elsif budget_row.period = 'monthly' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.status in ('requested','approved','paid') and e.currency = p_currency and e.created_at >= date_trunc('month', now())
          and (budget_row.scope <> 'project' or e.project_id = p_project_id)
          and (budget_row.scope <> 'department' or e.department_id = p_department_id)
          and (budget_row.scope <> 'category' or lower(e.category) = lower(p_category))
          and (budget_row.scope <> 'vendor' or lower(coalesce(e.vendor,'')) = lower(coalesce(p_vendor,'')))
          and (budget_row.scope <> 'agent' or e.agent_id = p_agent_id);
    else
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.status in ('requested','approved','paid') and e.currency = p_currency
          and (budget_row.scope <> 'project' or e.project_id = p_project_id)
          and (budget_row.scope <> 'department' or e.department_id = p_department_id)
          and (budget_row.scope <> 'category' or lower(e.category) = lower(p_category))
          and (budget_row.scope <> 'vendor' or lower(coalesce(e.vendor,'')) = lower(coalesce(p_vendor,'')))
          and (budget_row.scope <> 'agent' or e.agent_id = p_agent_id);
    end if;
    if used_amount + p_amount > budget_row.limit_amount and budget_row.hard_stop then
      raise exception 'budget hard stop: % % budget exceeded', budget_row.scope, budget_row.scope_key using errcode = '23514';
    end if;
    if used_amount + p_amount >= budget_row.limit_amount * budget_row.warning_percent / 100 then
      warnings := array_append(warnings, budget_row.scope || ':' || budget_row.scope_key);
    end if;
  end loop;

  approval_status := case when cardinality(policy_row.required_approvers) = 0 then 'approved' else 'requested' end;
  insert into public.expenses(project_id,department_id,agent_id,category,vendor,description,amount,currency,status,requested_by)
    values (p_project_id,p_department_id,p_agent_id,p_category,p_vendor,p_description,p_amount,p_currency,approval_status,p_actor_id)
    returning id into expense_id;
  if approval_status = 'requested' then
    insert into public.approvals(project_id,expense_id,approval_type,requested_by,required_roles,amount,currency,summary,status,
      action_type,action_ref,requested_by_agent_id,required_role,payload)
      values (p_project_id,expense_id,'spend',p_actor_id,policy_row.required_approvers,p_amount,p_currency,p_description,'pending',
        'spend',expense_id::text,p_agent_id,policy_row.required_approvers[1],jsonb_build_object('category',p_category,'vendor',p_vendor))
      returning id into approval_id;
  else
    update public.expenses set status = 'approved', approved_at = now() where id = expense_id;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values (p_actor_type,p_actor_id,'spending.authorization_requested','expense',expense_id::text,
      jsonb_build_object('amount',p_amount,'currency',p_currency,'category',p_category,'approval_status',approval_status,'approval_id',approval_id));
  return jsonb_build_object('expense_id',expense_id,'approval_id',approval_id,'status',approval_status,
    'required_approvers',policy_row.required_approvers,'warning_percent',policy_row.warning_percent,'budget_warnings',warnings);
end;
$$;

create or replace function public.sutra_submit_proposal(
  p_founder_telegram_user_id text,
  p_name text,
  p_description text,
  p_requested_budget numeric,
  p_currency char(3) default 'EUR'
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  founder_id text;
  project_id uuid;
  objective_id uuid;
  approval_id uuid;
  product_department_id uuid;
  ceo_id uuid;
  role_slug text;
  stage text;
begin
  select value #>> '{}' into founder_id from public.company_settings where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the configured founder can submit company proposals' using errcode = '42501';
  end if;
  if p_name is null or length(trim(p_name)) not between 3 and 160 or p_description is null or length(trim(p_description)) < 12 then
    raise exception 'malformed proposal' using errcode = '22023';
  end if;
  if p_requested_budget is null or p_requested_budget <= 0 or p_requested_budget > 999999999999.99
    or p_requested_budget::text in ('NaN','Infinity','-Infinity') or p_currency <> 'EUR' then
    raise exception 'invalid proposal budget' using errcode = '22023';
  end if;
  select id into product_department_id from public.departments where slug = 'product';
  select id into ceo_id from public.agents where slug = 'ceo';
  insert into public.projects(slug,name,description,status,owner_agent_id,department_id,requested_budget,currency,created_by,budget_amount,budget_currency)
    values ('proposal-' || replace(gen_random_uuid()::text,'-',''),trim(p_name),trim(p_description),'proposed',ceo_id,product_department_id,p_requested_budget,p_currency,'founder:' || founder_id,p_requested_budget,p_currency)
    returning id into project_id;
  insert into public.objectives(project_id,title,description,success_metrics,status,owner_agent_id)
    values (project_id,trim(p_name),trim(p_description),'[]'::jsonb,'proposed',ceo_id)
    returning id into objective_id;

  -- Record durable handoffs. The evidence status makes clear that research or
  -- technical conclusions have not been fabricated by the command router.
  for role_slug, stage in select * from (values
    ('ceo','Scope the founder request and coordinate a proposal'),
    ('cpo','Produce product and customer research with cited evidence'),
    ('cto','Assess architecture, delivery sequence and technical risk'),
    ('cfo','Review requested budget against active database policy'),
    ('product_manager','Prepare milestones, acceptance criteria and engineering backlog')
  ) as stages(slug,description)
  loop
    select id into ceo_id from public.agents where slug = role_slug;
    insert into public.agent_runs(agent_id,project_id,trigger_type,status,input,output)
      values(ceo_id,project_id,'founder_proposal','queued',jsonb_build_object('request',p_name),
        jsonb_build_object('handoff',stage,'evidence_status','pending'));
    insert into public.decisions(project_id,agent_id,decision_type,summary,rationale,evidence)
      values(project_id,ceo_id,'workflow_handoff',stage,'Queued for the responsible role; no unsupported research or technical findings are asserted.','[]'::jsonb);
  end loop;
  insert into public.tasks(project_id,objective_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
    values(project_id,objective_id,'Research AI QA product opportunity','Collect competitor, buyer, workflow and pricing evidence before making a product recommendation.',
      '["Cite primary sources","Separate evidence from assumptions","Estimate market and product risks"]'::jsonb,'research','blocked',
      (select id from public.agents where slug='cpo'),(select id from public.agents where slug='cpo'));
  insert into public.budgets(scope,scope_key,period,currency,limit_amount,warning_percent,hard_stop)
    values('project',project_id::text,'lifetime',p_currency,p_requested_budget,80,true)
    on conflict (scope,scope_key,period,currency) do update set limit_amount = excluded.limit_amount;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,amount,currency,summary,status,
    action_type,action_ref,requested_by_agent_id,required_role,payload)
    values(project_id,'project_budget','founder:' || founder_id,array['cfo','founder'],p_requested_budget,p_currency,
      'CFO review followed by founder approval: proposed maximum budget for ' || trim(p_name),'pending',
      'project_budget',project_id::text,null,'cfo',jsonb_build_object('objective_id',objective_id,'requested_budget',p_requested_budget,'currency',p_currency))
    returning id into approval_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'project.proposal_submitted','project',project_id::text,
      jsonb_build_object('objective_id',objective_id,'approval_id',approval_id,'requested_budget',p_requested_budget,'currency',p_currency));
  return jsonb_build_object('project_id',project_id,'objective_id',objective_id,'approval_id',approval_id,'status','pending_founder_approval');
end;
$$;

create or replace function public.sutra_founder_decide_approval(
  p_founder_telegram_user_id text,
  p_approval_id uuid,
  p_decision text,
  p_comment text default ''
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  founder_id text;
  approval_row public.approvals%rowtype;
  project_row public.projects%rowtype;
  objective_id uuid;
  pm_id uuid;
  first_task_id uuid;
  previous_task_id uuid;
  stage record;
begin
  select value #>> '{}' into founder_id from public.company_settings where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the configured founder can decide this approval' using errcode = '42501';
  end if;
  if p_decision not in ('approve','reject') then raise exception 'decision must be approve or reject' using errcode = '22023'; end if;
  select * into approval_row from public.approvals where id = p_approval_id for update;
  if not found or approval_row.status <> 'pending' or not ('founder' = any(approval_row.required_roles)) then
    raise exception 'approval is missing, already resolved, or not founder-authorized' using errcode = '42501';
  end if;
  if p_decision = 'approve' and exists (
    select 1 from unnest(approval_row.required_roles) as r(role)
    where r.role <> 'founder' and coalesce(approval_row.decisions #>> array[r.role,'decision'],'') <> 'approve'
  ) then
    raise exception 'required department approvals are incomplete' using errcode = '42501';
  end if;
  update public.approvals set status = case p_decision when 'approve' then 'approved' else 'rejected' end,
    decided_by = 'founder:' || founder_id, decided_at = now(), decisions = decisions || jsonb_build_object('founder',jsonb_build_object('decision',p_decision,'comment',left(coalesce(p_comment,''),2000)))
    where id = p_approval_id;
  if approval_row.expense_id is not null then
    update public.expenses set status = case p_decision when 'approve' then 'approved' else 'rejected' end,
      approved_at = case p_decision when 'approve' then now() else null end
      where id = approval_row.expense_id;
  end if;
  select * into project_row from public.projects where id = approval_row.project_id for update;
  if project_row.id is not null then
    update public.projects set status = case p_decision when 'approve' then 'approved' else 'rejected' end, updated_at = now() where id = project_row.id;
    if p_decision = 'approve' then
      update public.tasks set status = 'ready' where project_id = project_row.id and status = 'blocked';
      select id into objective_id from public.objectives where project_id = project_row.id and status = 'proposed' order by created_at limit 1;
      update public.objectives set status = 'active' where id = objective_id;
      select id into pm_id from public.agents where slug = 'product_manager';
      insert into public.tasks(project_id,objective_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
        values(project_row.id,objective_id,'Create approved product requirements and implementation plan',
          'Convert the approved proposal into a reviewed specification and engineering backlog.',
          '["Founder-approved budget is preserved","Requirements and acceptance criteria are recorded","Engineering work is split into reviewable tasks"]'::jsonb,'product','ready',pm_id,pm_id)
        returning id into first_task_id;
      previous_task_id := first_task_id;
      for stage in select * from (values
          ('Produce architecture and technical design','Record interfaces, data flow, deployment topology and technical risks.','["Design is recorded and linked to the project","Security assumptions are stated"]'::jsonb,'architect'),
          ('Implement approved product tasks','Create a branch and reviewable pull request for the approved scope.','["Changes map to approved tasks","No secrets are committed","Pull request is reviewable"]'::jsonb,'developer'),
          ('Verify acceptance criteria','Run and record reproducible automated and manual test results.','["Acceptance criteria have evidence","Failures are recorded"]'::jsonb,'qa'),
          ('Review security and dependencies','Record threat, dependency and data-handling findings.','["Security findings have severity and owner","Release blockers are explicit"]'::jsonb,'security'),
          ('Prepare release and rollback','Verify health checks, recovery path and release readiness.','["Deployment is repeatable","Rollback steps are documented"]'::jsonb,'devops'),
          ('Prepare marketing launch proposal','Draft positioning and an approval-ready campaign plan.','["Audience, claims and budget are reviewed","No message is sent externally"]'::jsonb,'cmo'),
          ('Prepare sales handoff','Create internal lead qualification and sales materials.','["Lead criteria and materials are recorded","No external outreach is sent"]'::jsonb,'sales')
      ) as stage(title,description,acceptance_criteria,owner_slug)
      loop
        insert into public.tasks(project_id,objective_id,parent_task_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
          select project_row.id,objective_id,previous_task_id,stage.title,stage.description,
            stage.acceptance_criteria,'engineering','backlog',a.id,a.id
          from public.agents a where a.slug=stage.owner_slug returning id into previous_task_id;
      end loop;
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system','sutra','project.approved_tasks_created','project',project_row.id::text,jsonb_build_object('first_task_id',first_task_id));
    end if;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'approval.' || p_decision,'approval',p_approval_id::text,jsonb_build_object('comment',left(coalesce(p_comment,''),2000)));
  return jsonb_build_object('approval_id',p_approval_id,'status',case p_decision when 'approve' then 'approved' else 'rejected' end,
    'project_id',approval_row.project_id,'first_task_id',first_task_id);
end;
$$;

revoke all on function public.sutra_authorize_spend(text,text,uuid,uuid,uuid,text,text,text,numeric,char) from public, anon, authenticated;
revoke all on function public.sutra_submit_proposal(text,text,text,numeric,char) from public, anon, authenticated;
revoke all on function public.sutra_founder_decide_approval(text,uuid,text,text) from public, anon, authenticated;
grant execute on function public.sutra_authorize_spend(text,text,uuid,uuid,uuid,text,text,text,numeric,char) to service_role;
grant execute on function public.sutra_submit_proposal(text,text,text,numeric,char) to service_role;
grant execute on function public.sutra_founder_decide_approval(text,uuid,text,text) to service_role;
create or replace function public.sutra_register_founder(p_telegram_user_id text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare existing_id text;
begin
  if p_telegram_user_id is null or p_telegram_user_id !~ '^[0-9]{1,32}$' then raise exception 'invalid Telegram founder identity' using errcode = '22023'; end if;
  select value #>> '{}' into existing_id from public.company_settings where key = 'founder_telegram_user_id' for update;
  if existing_id is null then
    insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
      values('founder_telegram_user_id',to_jsonb(p_telegram_user_id),true,true,'bootstrap');
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details) values('system','sutra','founder.identity_bootstrapped','company_setting','founder_telegram_user_id','{}'::jsonb);
    return jsonb_build_object('registered',true);
  end if;
  if existing_id <> p_telegram_user_id then raise exception 'runtime founder identity does not match company settings' using errcode = '42501'; end if;
  return jsonb_build_object('registered',false,'verified',true);
end;
$$;

create or replace function public.sutra_set_spending_policy(
  p_founder_telegram_user_id text,p_name text,p_min_amount numeric,p_max_amount numeric,
  p_min_inclusive boolean,p_max_inclusive boolean,p_required_approvers text[],
  p_warning_percent numeric,p_hard_stop boolean
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare founder_id text; policy_row public.spending_policies%rowtype; candidate numrange;
begin
  select value #>> '{}' into founder_id from public.company_settings where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id <> p_founder_telegram_user_id then raise exception 'only the founder can change spending authority' using errcode = '42501'; end if;
  if p_name is null or p_min_amount is null or p_min_amount < 0 or p_min_amount > 999999999999.99
    or p_min_amount::text in ('NaN','Infinity','-Infinity')
    or (p_max_amount is not null and (p_max_amount <= p_min_amount or p_max_amount > 999999999999.99 or p_max_amount::text in ('NaN','Infinity','-Infinity')))
    or p_min_inclusive is null or p_max_inclusive is null or p_hard_stop is null
    or p_warning_percent is null or p_warning_percent <= 0 or p_warning_percent > 100
    or p_required_approvers is null
    or exists(select 1 from unnest(p_required_approvers) as r(role) where r.role not in ('founder','cfo','ceo','department_head'))
    or cardinality(p_required_approvers) <> (select count(distinct r.role) from unnest(p_required_approvers) as r(role)) then
    raise exception 'invalid spending policy' using errcode = '22023';
  end if;
  select * into policy_row from public.spending_policies where name = p_name and currency = 'EUR' for update;
  if not found then raise exception 'policy name does not exist' using errcode = '22023'; end if;
  candidate := numrange(p_min_amount,p_max_amount,(case when p_min_inclusive then '[' else '(' end) || (case when p_max_inclusive then ']' else ')' end));
  if exists (
    select 1 from public.spending_policies p where p.active and p.id <> policy_row.id and p.currency = policy_row.currency
      and numrange(p.min_amount,p.max_amount,(case when p.min_inclusive then '[' else '(' end) || (case when p.max_inclusive then ']' else ')' end)) && candidate
  ) then raise exception 'spending policy would overlap another active range' using errcode = '23514'; end if;
  update public.spending_policies set min_amount=p_min_amount,max_amount=p_max_amount,min_inclusive=p_min_inclusive,
    max_inclusive=p_max_inclusive,required_approvers=p_required_approvers,warning_percent=p_warning_percent,
    hard_stop=p_hard_stop,per_transaction_limit=p_max_amount,
    approval_chain=case when cardinality(p_required_approvers)=0 then '["automatic"]'::jsonb else to_jsonb(p_required_approvers) end,
    updated_at=now() where id=policy_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'governance.spending_policy_changed','spending_policy',policy_row.id::text,
      jsonb_build_object('name',p_name,'min_amount',p_min_amount,'max_amount',p_max_amount,'required_approvers',p_required_approvers,'warning_percent',p_warning_percent,'hard_stop',p_hard_stop));
  return jsonb_build_object('updated',true,'policy_id',policy_row.id);
end;
$$;

create or replace function public.sutra_set_budget(
  p_founder_telegram_user_id text,p_scope text,p_scope_key text,p_period text,
  p_limit_amount numeric,p_warning_percent numeric default 80,p_hard_stop boolean default true
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare founder_id text; budget_id uuid;
begin
  select value #>> '{}' into founder_id from public.company_settings where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id <> p_founder_telegram_user_id then raise exception 'only the founder can change budgets' using errcode = '42501'; end if;
  if p_scope is null or p_scope not in ('company','project','department','agent','category','vendor')
    or p_period is null or p_period not in ('transaction','daily','monthly','lifetime') or p_scope_key is null or length(trim(p_scope_key)) = 0
    or p_limit_amount is null or p_limit_amount < 0 or p_limit_amount > 999999999999.99
    or p_limit_amount::text in ('NaN','Infinity','-Infinity') or p_warning_percent is null
    or p_warning_percent <= 0 or p_warning_percent > 100 or p_hard_stop is null then
    raise exception 'invalid budget configuration' using errcode = '22023';
  end if;
  insert into public.budgets(scope,scope_key,period,currency,limit_amount,warning_percent,hard_stop)
    values(p_scope,p_scope_key,p_period,'EUR',p_limit_amount,p_warning_percent,p_hard_stop)
    on conflict(scope,scope_key,period,currency) do update set limit_amount=excluded.limit_amount,warning_percent=excluded.warning_percent,hard_stop=excluded.hard_stop
    returning id into budget_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'governance.budget_changed','budget',budget_id::text,
      jsonb_build_object('scope',p_scope,'scope_key',p_scope_key,'period',p_period,'limit_amount',p_limit_amount,'warning_percent',p_warning_percent,'hard_stop',p_hard_stop));
  return jsonb_build_object('updated',true,'budget_id',budget_id);
end;
$$;

create or replace function public.sutra_set_company_setting(p_founder_telegram_user_id text,p_key text,p_value jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare founder_id text;
begin
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id <> p_founder_telegram_user_id then raise exception 'only the founder can change company settings' using errcode = '42501'; end if;
  if p_key is null or length(trim(p_key)) not between 1 and 120 or p_value is null then raise exception 'invalid company setting' using errcode = '22023'; end if;
  insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_at,updated_by)
    values(p_key,p_value,true,true,now(),'founder:' || founder_id)
    on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true,updated_at=now(),updated_by=excluded.updated_by;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'company.setting_changed','company_setting',p_key,jsonb_build_object('value_type',jsonb_typeof(p_value)));
  return jsonb_build_object('updated',true,'key',p_key);
end;
$$;

create or replace function public.sutra_log_auth_denial(p_actor_hash text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if p_actor_hash is null or p_actor_hash !~ '^[0-9a-f]{24}$' then raise exception 'invalid actor hash' using errcode = '22023'; end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system','telegram-auth','founder_interface.unauthorized_identity','telegram_identity',p_actor_hash,'{"result":"denied"}'::jsonb);
end;
$$;

create or replace function public.sutra_decide_role_approval(
  p_approval_id uuid,p_actor_id text,p_actor_role text,p_decision text,p_comment text default ''
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare approval_row public.approvals%rowtype; actor_ok boolean; next_status text; approval_department_id uuid;
begin
  if p_decision not in ('approve','reject') or p_actor_role not in ('ceo','cfo','department_head') then raise exception 'invalid role approval request' using errcode = '22023'; end if;
  select * into approval_row from public.approvals where id=p_approval_id for update;
  if not found or approval_row.status <> 'pending' or not (p_actor_role = any(approval_row.required_roles)) then raise exception 'approval is missing, resolved, or not assigned to this role' using errcode = '42501'; end if;
  if p_actor_role = 'department_head' then
    select coalesce(p.department_id, e.department_id) into approval_department_id
      from public.approvals ap
      left join public.projects p on p.id=ap.project_id
      left join public.expenses e on e.id=ap.expense_id
      where ap.id=p_approval_id;
    select exists(
      select 1 from public.company_settings s
      join public.agents a on a.id::text = s.value #>> '{}'
      where s.key='department_head:' || approval_department_id::text
        and a.id::text=p_actor_id and a.department_id=approval_department_id and a.active
    ) into actor_ok;
  else
    select exists(select 1 from public.agents a where a.id::text=p_actor_id and a.slug=p_actor_role and a.active) into actor_ok;
  end if;
  if not coalesce(actor_ok,false) then raise exception 'agent identity does not match the approving role' using errcode = '42501'; end if;
  if approval_row.decisions ? p_actor_role then raise exception 'role has already decided this approval' using errcode = '23505'; end if;
  approval_row.decisions := approval_row.decisions || jsonb_build_object(p_actor_role,
    jsonb_build_object('decision',p_decision,'actor_id',p_actor_id,'comment',left(coalesce(p_comment,''),2000)));
  if p_decision='reject' then next_status:='rejected';
  elsif not exists(select 1 from unnest(approval_row.required_roles) as r(role)
    where coalesce(approval_row.decisions #>> array[r.role,'decision'],'') <> 'approve' and r.role <> p_actor_role) then next_status:='approved';
  else next_status:='pending'; end if;
  update public.approvals set status=next_status,decisions=approval_row.decisions,
    decided_by=case when next_status in ('approved','rejected') then 'role:' || p_actor_role else null end,
    decided_at=case when next_status in ('approved','rejected') then now() else null end where id=p_approval_id;
  if approval_row.expense_id is not null and next_status in ('approved','rejected') then
    update public.expenses set status=next_status,approved_at=case when next_status='approved' then now() else null end where id=approval_row.expense_id;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',p_actor_id,'approval.' || p_decision,'approval',p_approval_id::text,jsonb_build_object('role',p_actor_role,'status',next_status,'comment',left(coalesce(p_comment,''),2000)));
  return jsonb_build_object('approval_id',p_approval_id,'status',next_status,'decided_role',p_actor_role);
end;
$$;

create or replace function public.sutra_release_child_tasks()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if old.status is distinct from new.status and new.status = 'done' then
    update public.tasks set status='ready',updated_at=now() where parent_task_id=new.id and status='backlog';
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','task.children_released','task',new.id::text,jsonb_build_object('project_id',new.project_id));
  end if;
  return new;
end;
$$;
create trigger tasks_release_children_after_done
  after update of status on public.tasks
  for each row execute function public.sutra_release_child_tasks();

create or replace function public.sutra_update_task(
  p_actor_agent_id uuid,p_task_id uuid,p_status text,p_evidence jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare task_row public.tasks%rowtype; agent_slug text;
begin
  if p_status is null or p_status not in ('in_progress','review','done','blocked','ready')
    or p_evidence is null or jsonb_typeof(p_evidence) <> 'object' or octet_length(p_evidence::text) > 16000 then
    raise exception 'invalid task update' using errcode = '22023';
  end if;
  select * into task_row from public.tasks where id=p_task_id for update;
  select slug into agent_slug from public.agents where id=p_actor_agent_id and active;
  if task_row.id is null or task_row.owner_agent_id is distinct from p_actor_agent_id or agent_slug is null then
    raise exception 'agent may update only its own assigned task' using errcode = '42501';
  end if;
  if not (
    (task_row.status='ready' and p_status in ('in_progress','blocked')) or
    (task_row.status='in_progress' and p_status in ('review','done','blocked')) or
    (task_row.status='review' and p_status in ('done','blocked','in_progress')) or
    (task_row.status='blocked' and p_status='ready')
  ) then raise exception 'task status transition is not allowed' using errcode = '22023'; end if;
  if p_status in ('review','done') and p_evidence='{}'::jsonb then
    raise exception 'review and completion require evidence' using errcode = '22023';
  end if;
  update public.tasks set status=p_status,updated_at=now() where id=p_task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at)
    values(p_actor_agent_id,task_row.project_id,p_task_id,'task_update',
      case p_status when 'done' then 'succeeded' when 'blocked' then 'blocked' else 'running' end,
      jsonb_build_object('previous_status',task_row.status),p_evidence,now(),
      case when p_status in ('done','blocked') then now() else null end);
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',agent_slug,'task.status_changed','task',p_task_id::text,
      jsonb_build_object('from',task_row.status,'to',p_status,'evidence_keys',
        (select coalesce(jsonb_agg(k),'[]'::jsonb) from jsonb_object_keys(p_evidence) as keys(k))));
  return jsonb_build_object('task_id',p_task_id,'status',p_status);
end;
$$;

revoke all on function public.sutra_register_founder(text) from public, anon, authenticated;
revoke all on function public.sutra_set_spending_policy(text,text,numeric,numeric,boolean,boolean,text[],numeric,boolean) from public, anon, authenticated;
revoke all on function public.sutra_set_budget(text,text,text,text,numeric,numeric,boolean) from public, anon, authenticated;
revoke all on function public.sutra_set_company_setting(text,text,jsonb) from public, anon, authenticated;
revoke all on function public.sutra_log_auth_denial(text) from public, anon, authenticated;
revoke all on function public.sutra_decide_role_approval(uuid,text,text,text,text) from public, anon, authenticated;
revoke all on function public.sutra_release_child_tasks() from public, anon, authenticated, service_role;
revoke all on function public.sutra_update_task(uuid,uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.sutra_register_founder(text) to service_role;
grant execute on function public.sutra_set_spending_policy(text,text,numeric,numeric,boolean,boolean,text[],numeric,boolean) to service_role;
grant execute on function public.sutra_set_budget(text,text,text,text,numeric,numeric,boolean) to service_role;
grant execute on function public.sutra_set_company_setting(text,text,jsonb) to service_role;
grant execute on function public.sutra_log_auth_denial(text) to service_role;
grant execute on function public.sutra_decide_role_approval(uuid,text,text,text,text) to service_role;
grant execute on function public.sutra_update_task(uuid,uuid,text,jsonb) to service_role;

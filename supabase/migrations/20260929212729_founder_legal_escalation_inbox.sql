-- Persist CFO legal escalations as a founder-only case queue. A disposition
-- records the founder's decision but never resumes work or authorizes a legal
-- commitment; the project remains paused for an explicit operational decision.
create table public.legal_escalations (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  source_assessed_at timestamptz not null,
  summary text not null check (length(summary) between 1 and 1000),
  status text not null default 'open' check (status in ('open','reviewed')),
  disposition text check (disposition in ('continue_within_budget','stop_initiative','seek_legal_counsel')),
  founder_reason text check (founder_reason is null or length(founder_reason) between 8 and 500),
  recorded_by text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  unique (project_id, source_assessed_at),
  check ((status='open' and disposition is null and founder_reason is null and recorded_by is null and reviewed_at is null)
      or (status='reviewed' and disposition is not null and founder_reason is not null and recorded_by is not null and reviewed_at is not null))
);
alter table public.legal_escalations enable row level security;
revoke all on public.legal_escalations from public,anon,authenticated,service_role;
create index legal_escalations_open_created_idx on public.legal_escalations(created_at desc) where status='open';

create or replace function public.sutra_create_legal_escalation_case()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.budget_assessment_status<>'legal_escalation' or new.budget_assessed_at is null then
    return new;
  end if;
  if tg_op='UPDATE' and old.budget_assessment_status='legal_escalation'
      and old.budget_assessed_at is not distinct from new.budget_assessed_at then
    return new;
  end if;
  insert into public.legal_escalations(project_id,source_assessed_at,summary)
    values(new.id,new.budget_assessed_at,
      'CFO assessment identified a legal question or proposed binding commitment. Founder review is required before work resumes.')
    on conflict(project_id,source_assessed_at) do nothing;
  if found then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','legal.escalation_opened','legal_escalation',
        (select id::text from public.legal_escalations where project_id=new.id and source_assessed_at=new.budget_assessed_at),
        jsonb_build_object('project_id',new.id,'source','initiative_budget_assessment'));
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_create_legal_escalation_case() from public,anon,authenticated,service_role;
create trigger projects_create_legal_escalation_case
  after insert or update of budget_assessment_status,budget_assessed_at on public.projects
  for each row execute function public.sutra_create_legal_escalation_case();

-- Backfill cases for already-persisted CFO legal assessments when this staged
-- migration is later applied. Unknown/other budget states are untouched.
with inserted as (
  insert into public.legal_escalations(project_id,source_assessed_at,summary)
    select id,budget_assessed_at,
      'CFO assessment identified a legal question or proposed binding commitment. Founder review is required before work resumes.'
    from public.projects where budget_assessment_status='legal_escalation' and budget_assessed_at is not null
    on conflict(project_id,source_assessed_at) do nothing
    returning id,project_id
)
insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  select 'system','sutra','legal.escalation_opened','legal_escalation',id::text,
    jsonb_build_object('project_id',project_id,'source','migration_backfill') from inserted;

create or replace function public.sutra_founder_list_legal_escalations(p_founder_telegram_user_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; cases jsonb;
begin
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can read legal escalations' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(q.case_data order by q.created_at desc),'[]'::jsonb) into cases
    from (select e.created_at,jsonb_build_object(
      'id',e.id,'project_id',e.project_id,'project_name',p.name,'project_status',p.status,
      'budget_cap',p.requested_budget,'currency',p.currency,'summary',e.summary,
      'status',e.status,'disposition',e.disposition,'founder_reason',e.founder_reason,
      'created_at',e.created_at,'reviewed_at',e.reviewed_at
    ) as case_data from public.legal_escalations e join public.projects p on p.id=e.project_id
    where e.status='open' order by e.created_at desc limit 50) q;
  return jsonb_build_object('escalations',cases);
end;
$$;
revoke all on function public.sutra_founder_list_legal_escalations(text) from public,anon,authenticated;
grant execute on function public.sutra_founder_list_legal_escalations(text) to service_role;

create or replace function public.sutra_founder_record_legal_disposition(
  p_founder_telegram_user_id text,p_case_id uuid,p_disposition text,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; case_row public.legal_escalations%rowtype;
begin
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can record a legal disposition' using errcode='42501';
  end if;
  if p_disposition is null or p_disposition not in ('continue_within_budget','stop_initiative','seek_legal_counsel')
      or p_reason is null or length(trim(p_reason)) not between 8 and 500 then
    raise exception 'legal disposition or founder reason is invalid' using errcode='22023';
  end if;
  select * into case_row from public.legal_escalations where id=p_case_id and status='open' for update;
  if not found then raise exception 'legal escalation is not open' using errcode='P0002'; end if;
  update public.legal_escalations set status='reviewed',disposition=p_disposition,
    founder_reason=trim(p_reason),recorded_by=founder_id,reviewed_at=now() where id=p_case_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'legal.disposition_recorded','legal_escalation',p_case_id::text,
      jsonb_build_object('disposition',p_disposition,'project_id',case_row.project_id));
  return jsonb_build_object('case_id',p_case_id,'status','reviewed','disposition',p_disposition,
    'project_id',case_row.project_id,'project_status',(select status from public.projects where id=case_row.project_id));
end;
$$;
revoke all on function public.sutra_founder_record_legal_disposition(text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_record_legal_disposition(text,uuid,text,text) to service_role;

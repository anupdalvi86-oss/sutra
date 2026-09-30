-- Route new Zendesk cases only to a founder-selected, already-funded initiative.
-- Task creation itself spends nothing; agent execution still uses the normal
-- metered reservation path. This migration adds no customer-message delivery.
create table public.zendesk_support_task_routes (
  support_case_id uuid primary key references public.support_cases(id) on delete restrict,
  task_id uuid not null unique references public.tasks(id) on delete restrict,
  project_id uuid not null references public.projects(id) on delete restrict,
  routing_state text not null check (routing_state in ('active','waiting','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.zendesk_support_task_routes enable row level security;
revoke all on public.zendesk_support_task_routes from public,anon,authenticated,service_role;
create index zendesk_support_task_routes_project_idx
  on public.zendesk_support_task_routes(project_id,routing_state,updated_at desc);

create function public.sutra_route_zendesk_support_case(p_support_case_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  case_row public.support_cases%rowtype;
  route_row public.zendesk_support_task_routes%rowtype;
  project_row public.projects%rowtype;
  task_row public.tasks%rowtype;
  sales_id uuid;
  configured_project_id uuid;
  route_exists boolean;
  committed numeric(14,2);
  assessment_total numeric;
  reason_code text;
  task_id uuid;
  task_description text;
begin
  select * into case_row from public.support_cases where id=p_support_case_id for update;
  if not found then
    raise exception 'support case does not exist' using errcode='22023';
  end if;
  select * into route_row from public.zendesk_support_task_routes
    where support_case_id=case_row.id for update;
  route_exists:=found;

  -- A ticket waiting on the customer or closed by Zendesk stops automatic work.
  if case_row.status in ('pending','hold','solved','closed') then
    if found then
      select * into task_row from public.tasks where id=route_row.task_id for update;
      if task_row.status in ('ready','in_progress','review') then
        perform public.sutra_update_task(task_row.owner_agent_id,task_row.id,'blocked',
          jsonb_build_object('support_case_state',case_row.status,'reason','Zendesk case is waiting or closed'));
      end if;
      update public.zendesk_support_task_routes set routing_state=
        case when case_row.status in ('solved','closed') then 'closed' else 'waiting' end,updated_at=now()
        where support_case_id=case_row.id;
    end if;
    return jsonb_build_object('routed',false,
      'reason_code',case when case_row.status in ('solved','closed') then 'ticket_closed' else 'ticket_waiting' end,
      'case_id',case_row.id);
  end if;
  if case_row.status not in ('new','open') then
    return jsonb_build_object('routed',false,'reason_code','ticket_not_actionable','case_id',case_row.id);
  end if;

  select nullif(value->>'project_id','')::uuid into configured_project_id
    from public.company_settings where key='zendesk_support_project_id';
  if configured_project_id is null then
    reason_code:='routing_not_configured';
  else
    select * into project_row from public.projects where id=configured_project_id for update;
    if not found or project_row.status not in ('approved','active') then
      reason_code:='initiative_not_active';
    elsif project_row.budget_assessment_status<>'within_cap'
        or project_row.budget_assessment->>'recommended_action'<>'proceed_within_cap'
        or coalesce(project_row.budget_assessment->>'estimated_total_eur','') !~ '^[0-9]+(\.[0-9]{1,2})?$' then
      reason_code:='initiative_budget_not_assessed';
    else
      assessment_total:=(project_row.budget_assessment->>'estimated_total_eur')::numeric;
      if assessment_total>project_row.requested_budget then
        reason_code:='initiative_assessment_exceeds_cap';
      elsif project_row.legal_hold or exists(select 1 from public.legal_escalations e
          where e.project_id=configured_project_id and e.status='open') then
        reason_code:='initiative_legal_hold';
      elsif not exists(select 1 from public.approvals a where a.project_id=configured_project_id
          and a.approval_type='project_budget' and a.status='approved'
          and a.decisions #>> '{cfo,decision}'='approve'
          and a.decisions #>> '{founder,decision}'='approve') then
        reason_code:='initiative_budget_not_founder_approved';
      else
        select coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
          when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end),0)
          into committed from public.initiative_budget_ledger l
          where l.project_id=configured_project_id and l.status in ('reserved','unknown','actual','overrun');
        if project_row.requested_budget-committed<=0 then
          reason_code:='initiative_budget_exhausted';
        else
          select id into sales_id from public.agents where slug='sales' and active limit 1;
          if sales_id is null then reason_code:='sales_agent_unavailable'; end if;
        end if;
      end if;
    end if;
  end if;
  if reason_code is not null then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','support.ticket_task_routing_skipped','support_case',case_row.id::text,
        jsonb_build_object('reason_code',reason_code,'provider_updated_at',case_row.provider_updated_at));
    return jsonb_build_object('routed',false,'reason_code',reason_code,'case_id',case_row.id);
  end if;

  if route_exists and route_row.project_id=configured_project_id then
    select * into task_row from public.tasks where id=route_row.task_id for update;
    if route_row.routing_state='active' and task_row.status in ('ready','in_progress','review') then
      return jsonb_build_object('routed',true,'created',false,'task_id',task_row.id,'case_id',case_row.id);
    end if;
    if task_row.status='blocked' and not exists(select 1 from public.task_agent_artifacts a where a.task_id=task_row.id) then
      perform public.sutra_update_task(task_row.owner_agent_id,task_row.id,'ready',
        jsonb_build_object('support_case_state',case_row.status,'reason','Zendesk case reopened or became actionable'));
      update public.zendesk_support_task_routes set routing_state='active',updated_at=now()
        where support_case_id=case_row.id;
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system','sutra','support.ticket_task_resumed','support_case',case_row.id::text,
          jsonb_build_object('task_id',task_row.id,'project_id',configured_project_id));
      return jsonb_build_object('routed',true,'created',false,'task_id',task_row.id,'case_id',case_row.id);
    end if;
  end if;

  task_description:='Zendesk ticket ID: '||case_row.external_ticket_id||E'\n'
    ||'Classify this open support request and prepare a private unsent reply draft. '
    ||'Use only the authorized task-scoped Zendesk context reader. Do not send a customer message.';
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(configured_project_id,'Triage Zendesk support case',task_description,
      jsonb_build_array('Classify the request and prepare a bounded private unsent reply draft.',
        'Escalate legal questions without drafting a reply.','Do not send a customer message.'),
      'customer_outreach','ready',sales_id,sales_id)
    returning id into task_id;
  insert into public.zendesk_support_task_routes(support_case_id,task_id,project_id,routing_state)
    values(case_row.id,task_id,configured_project_id,'active')
    on conflict(support_case_id) do update set task_id=excluded.task_id,project_id=excluded.project_id,
      routing_state='active',updated_at=now();
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system','sutra','support.ticket_task_routed','support_case',case_row.id::text,
      jsonb_build_object('task_id',task_id,'project_id',configured_project_id));
  return jsonb_build_object('routed',true,'created',true,'task_id',task_id,'case_id',case_row.id);
end;
$$;
revoke all on function public.sutra_route_zendesk_support_case(uuid) from public,anon,authenticated,service_role;

create function public.sutra_founder_get_zendesk_support_routing(p_founder_telegram_user_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; route_setting public.company_settings%rowtype;
begin
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder may inspect support routing' using errcode='42501';
  end if;
  select * into route_setting from public.company_settings where key='zendesk_support_project_id';
  return jsonb_build_object('configured',route_setting.key is not null,
    'project_id',route_setting.value->>'project_id','updated_at',route_setting.updated_at);
end;
$$;

create function public.sutra_founder_set_zendesk_support_routing(
  p_founder_telegram_user_id text,p_project_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  founder_id text;
  old_project_id text;
  project_row public.projects%rowtype;
  committed numeric(14,2);
  estimate numeric;
begin
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder may change support routing' using errcode='42501';
  end if;
  if p_reason is null or length(trim(p_reason)) not between 8 and 500 then
    raise exception 'support routing reason must contain 8 to 500 characters' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-zendesk-support-routing'));
  select value->>'project_id' into old_project_id from public.company_settings
    where key='zendesk_support_project_id' for update;
  if p_project_id is not null then
    select * into project_row from public.projects where id=p_project_id for update;
    if not found or project_row.status not in ('approved','active')
        or project_row.budget_assessment_status<>'within_cap'
        or project_row.budget_assessment->>'recommended_action'<>'proceed_within_cap'
        or coalesce(project_row.budget_assessment->>'estimated_total_eur','') !~ '^[0-9]+(\.[0-9]{1,2})?$'
        or project_row.legal_hold
        or exists(select 1 from public.legal_escalations e where e.project_id=p_project_id and e.status='open')
        or not exists(select 1 from public.approvals a where a.project_id=p_project_id
          and a.approval_type='project_budget' and a.status='approved'
          and a.decisions #>> '{cfo,decision}'='approve'
          and a.decisions #>> '{founder,decision}'='approve') then
      raise exception 'support routing requires a founder-approved, assessed, active, legally clear initiative' using errcode='42501';
    end if;
    estimate:=(project_row.budget_assessment->>'estimated_total_eur')::numeric;
    if estimate>project_row.requested_budget then
      raise exception 'support initiative estimate exceeds its approved all-in budget' using errcode='23514';
    end if;
    select coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
      when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end),0)
      into committed from public.initiative_budget_ledger l
      where l.project_id=p_project_id and l.status in ('reserved','unknown','actual','overrun');
    if project_row.requested_budget-committed<=0 then
      raise exception 'support initiative has no remaining all-in budget' using errcode='23514';
    end if;
    if old_project_id=p_project_id::text then
      return jsonb_build_object('changed',false,'configured',true,'project_id',p_project_id,
        'remaining_budget',project_row.requested_budget-committed);
    end if;
    insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
      values('zendesk_support_project_id',jsonb_build_object('project_id',p_project_id),true,true,founder_id)
      on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true,
        updated_at=now(),updated_by=founder_id;
  else
    if old_project_id is null then
      return jsonb_build_object('changed',false,'configured',false);
    end if;
    delete from public.company_settings where key='zendesk_support_project_id';
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,case when p_project_id is null then 'support.ticket_routing_disabled'
      else 'support.ticket_routing_configured' end,'company_setting','zendesk_support_project_id',
      jsonb_build_object('old_project_id',old_project_id,'new_project_id',p_project_id,'reason',left(trim(p_reason),500)));
  return jsonb_build_object('changed',true,'configured',p_project_id is not null,'project_id',p_project_id,
    'remaining_budget',case when p_project_id is null then null else project_row.requested_budget-committed end);
end;
$$;

revoke all on function public.sutra_founder_get_zendesk_support_routing(text) from public,anon,authenticated;
revoke all on function public.sutra_founder_set_zendesk_support_routing(text,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_get_zendesk_support_routing(text) to service_role;
grant execute on function public.sutra_founder_set_zendesk_support_routing(text,uuid,text) to service_role;

-- Keep the signed webhook's metadata-only contract and add idempotent routing
-- to a durable Sales task whenever the provider reports a material new state.
create or replace function public.sutra_ingest_zendesk_ticket_event(
  p_ticket_id text,p_status text,p_priority text,p_provider_updated_at timestamptz,p_route_tasks boolean
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare existing public.support_cases%rowtype; case_id uuid; changed boolean:=false; route_result jsonb;
begin
  if p_ticket_id is null or p_ticket_id !~ '^[1-9][0-9]{0,18}$'
      or p_status is null or p_status not in ('new','open','pending','hold','solved','closed')
      or (p_priority is not null and p_priority not in ('low','normal','high','urgent'))
      or p_provider_updated_at is null or p_route_tasks is null then
    raise exception 'invalid support event' using errcode='22023';
  end if;
  insert into public.support_cases(provider,external_ticket_id,status,priority,provider_updated_at)
    values('zendesk',p_ticket_id,p_status,p_priority,p_provider_updated_at)
    on conflict(provider,external_ticket_id) do nothing returning id into case_id;
  if case_id is not null then changed:=true;
  else
    select * into existing from public.support_cases
      where provider='zendesk' and external_ticket_id=p_ticket_id for update;
    case_id:=existing.id;
    if p_provider_updated_at>existing.provider_updated_at then
      update public.support_cases set status=p_status,priority=p_priority,
        provider_updated_at=p_provider_updated_at,updated_at=now() where id=case_id;
      changed:=true;
    end if;
  end if;
  if changed then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','support.ticket_state_ingested','support_case',case_id::text,
        jsonb_build_object('status',p_status,'priority',p_priority,'provider_updated_at',p_provider_updated_at));
    if p_route_tasks then
      route_result:=public.sutra_route_zendesk_support_case(case_id);
    end if;
  end if;
  return jsonb_build_object('case_id',case_id,'changed',changed,
    'routed',coalesce(route_result->'routed','false'::jsonb),
    'task_id',route_result->'task_id','routing_reason',route_result->>'reason_code');
end;
$$;
revoke all on function public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamptz,boolean)
  from public,anon,authenticated;
grant execute on function public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamptz,boolean) to service_role;

-- Preserve the metadata-only four-argument RPC for existing internal clients;
-- only an explicitly enabled, fully configured Sutra API may request routing.
create or replace function public.sutra_ingest_zendesk_ticket_event(
  p_ticket_id text,p_status text,p_priority text,p_provider_updated_at timestamptz
) returns jsonb language sql security definer set search_path=pg_catalog,public as $$
  select public.sutra_ingest_zendesk_ticket_event(
    p_ticket_id,p_status,p_priority,p_provider_updated_at,false);
$$;
revoke all on function public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamptz) to service_role;

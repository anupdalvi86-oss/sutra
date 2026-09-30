-- Public replies stay opt-in. A Sales artifact can queue one response only
-- after the founder sets a per-reply ceiling; delivery needs a separately
-- enabled worker, live Zendesk credentials and a fresh authorization check.
alter table public.company_settings
  add constraint company_settings_zendesk_reply_cost_ceiling_check
  check (key <> 'zendesk_reply_max_cost_eur' or
    case when pg_catalog.jsonb_typeof(value)='number' then
      (value #>> '{}')::numeric between 0.01 and 100.00
    else false end);

create table public.zendesk_reply_actions (
  id uuid primary key default gen_random_uuid(),
  artifact_id uuid not null unique references public.task_agent_artifacts(id) on delete restrict,
  project_id uuid not null references public.projects(id) on delete restrict,
  task_id uuid not null references public.tasks(id) on delete restrict,
  support_case_id uuid not null references public.support_cases(id) on delete restrict,
  ticket_id text not null check (ticket_id ~ '^[1-9][0-9]{0,18}$'),
  agent_id uuid not null references public.agents(id) on delete restrict,
  initiative_ledger_id uuid not null unique references public.initiative_budget_ledger(id) on delete restrict,
  status text not null default 'queued'
    check (status in ('queued','sending','sent','failed','unknown')),
  delivery_attempt_count smallint not null default 0 check (delivery_attempt_count between 0 and 2),
  delivery_claim_token uuid,
  delivery_lease_expires_at timestamptz,
  last_delivery_error_code text check (last_delivery_error_code is null or last_delivery_error_code in (
    'authorization_revoked','invalid_action','ticket_read_failed','ticket_not_actionable',
    'provider_rejected','safe_update_conflict','provider_outcome_unknown',
    'malformed_provider_response','provider_response_too_large')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint zendesk_reply_actions_delivery_lease_check
    check ((status='sending')=(delivery_claim_token is not null and delivery_lease_expires_at is not null))
);
alter table public.zendesk_reply_actions enable row level security;
revoke all on public.zendesk_reply_actions from public,anon,authenticated,service_role;
create index zendesk_reply_actions_queue_idx
  on public.zendesk_reply_actions(created_at,id) where status='queued';
create index zendesk_reply_actions_delivery_lease_idx
  on public.zendesk_reply_actions(delivery_lease_expires_at,id) where status='sending';
create index zendesk_reply_actions_project_status_idx
  on public.zendesk_reply_actions(project_id,status,created_at desc);

create function public.sutra_zendesk_reply_cost_ceiling()
returns numeric language sql stable security definer set search_path=pg_catalog,public as $$
  select case when pg_catalog.jsonb_typeof(s.value)='number'
    then (s.value #>> '{}')::numeric else null end
  from public.company_settings s where s.key='zendesk_reply_max_cost_eur'
$$;
revoke all on function public.sutra_zendesk_reply_cost_ceiling() from public,anon,authenticated,service_role;

create function public.sutra_founder_get_zendesk_reply_cost_ceiling(
  p_founder_telegram_user_id text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; ceiling_eur numeric;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64 then
    raise exception 'malformed Zendesk reply ceiling request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can inspect the Zendesk reply ceiling' using errcode='42501';
  end if;
  ceiling_eur:=public.sutra_zendesk_reply_cost_ceiling();
  return pg_catalog.jsonb_build_object('configured',ceiling_eur is not null,
    'max_reply_cost_eur',ceiling_eur,'minimum_eur',0.01,'maximum_eur',100.00);
end;
$$;
revoke all on function public.sutra_founder_get_zendesk_reply_cost_ceiling(text) from public,anon,authenticated;
grant execute on function public.sutra_founder_get_zendesk_reply_cost_ceiling(text) to service_role;

create function public.sutra_founder_set_zendesk_reply_cost_ceiling(
  p_founder_telegram_user_id text,p_max_reply_cost_eur numeric,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; previous_eur numeric;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_max_reply_cost_eur is null or p_max_reply_cost_eur not between 0.01 and 100.00
    or pg_catalog.round(p_max_reply_cost_eur,2)<>p_max_reply_cost_eur
    or p_reason is null or length(pg_catalog.btrim(p_reason)) not between 8 and 500 then
    raise exception 'Zendesk reply ceiling must be EUR 0.01 to 100.00 in cents and include a reason' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.zendesk_reply_cost_ceiling'));
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive for update;
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can change the Zendesk reply ceiling' using errcode='42501';
  end if;
  previous_eur:=public.sutra_zendesk_reply_cost_ceiling();
  if p_max_reply_cost_eur>coalesce(previous_eur,0) and exists(
    select 1 from public.zendesk_reply_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    where a.status='sending' or (a.status='queued' and l.reserved_amount<p_max_reply_cost_eur)) then
    raise exception 'Zendesk reply ceiling cannot rise while a reply is sending or queued reservations are below the new ceiling' using errcode='55000';
  end if;
  insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
    values('zendesk_reply_max_cost_eur',pg_catalog.to_jsonb(p_max_reply_cost_eur),true,true,founder_id)
    on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true,
      updated_at=pg_catalog.now(),updated_by=founder_id;
  if previous_eur is distinct from p_max_reply_cost_eur then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,'founder.zendesk_reply_cost_ceiling_changed','company_setting',
        'zendesk_reply_max_cost_eur',pg_catalog.jsonb_build_object(
          'previous_max_reply_cost_eur',previous_eur,'new_max_reply_cost_eur',p_max_reply_cost_eur,
          'reason',pg_catalog.btrim(p_reason),'no_reply_queued',true));
  end if;
  return pg_catalog.jsonb_build_object('configured',true,'previous_max_reply_cost_eur',previous_eur,
    'max_reply_cost_eur',p_max_reply_cost_eur,'changed',previous_eur is distinct from p_max_reply_cost_eur,
    'no_reply_queued',true);
end;
$$;
revoke all on function public.sutra_founder_set_zendesk_reply_cost_ceiling(text,numeric,text)
  from public,anon,authenticated;
grant execute on function public.sutra_founder_set_zendesk_reply_cost_ceiling(text,numeric,text) to service_role;

create function public.sutra_enqueue_zendesk_reply(p_artifact_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  artifact_row public.task_agent_artifacts%rowtype;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  case_row public.support_cases%rowtype;
  agent_row public.agents%rowtype;
  draft jsonb;
  ceiling_eur numeric;
  ledger_result jsonb;
  action_row public.zendesk_reply_actions%rowtype;
  skip_reason text;
  err_state text;
begin
  if p_artifact_id is null then raise exception 'Zendesk reply artifact is required' using errcode='22023'; end if;
  select * into artifact_row from public.task_agent_artifacts where id=p_artifact_id for update;
  if not found or artifact_row.artifact_type<>'sales_handoff'
      or not (artifact_row.artifact ? 'support_reply_draft') then
    return pg_catalog.jsonb_build_object('status','skipped','reason_code','no_reply_draft');
  end if;
  if exists(select 1 from public.zendesk_reply_actions a where a.artifact_id=artifact_row.id) then
    select * into action_row from public.zendesk_reply_actions a where a.artifact_id=artifact_row.id;
    return pg_catalog.jsonb_build_object('status',action_row.status,'action_id',action_row.id,'idempotent',true);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.zendesk_reply_cost_ceiling'));
  ceiling_eur:=public.sutra_zendesk_reply_cost_ceiling();
  draft:=artifact_row.artifact->'support_reply_draft';
  select * into task_row from public.tasks where id=artifact_row.task_id for update;
  select * into project_row from public.projects where id=task_row.project_id for update;
  select * into agent_row from public.agents where id=artifact_row.agent_id and active and slug='sales';
  select * into case_row from public.support_cases c
    where c.provider='zendesk' and c.external_ticket_id=draft->>'ticket_id' for update;
  if ceiling_eur is null then skip_reason:='reply_cost_ceiling_unconfigured';
  elsif agent_row.id is null or task_row.id is null or artifact_row.agent_id is distinct from task_row.owner_agent_id
      or artifact_row.agent_id is distinct from task_row.assigned_agent_id
      or task_row.status not in ('in_progress','review','completed') then skip_reason:='task_assignment_invalid';
  elsif project_row.id is null or project_row.status<>'active'
      or project_row.budget_assessment_status<>'within_cap'
      or project_row.budget_assessment->>'recommended_action'<>'proceed_within_cap'
      or project_row.legal_hold
      or exists(select 1 from public.legal_escalations e where e.project_id=project_row.id and e.status='open') then
    skip_reason:='initiative_budget_or_legal_block';
  elsif case_row.id is null or case_row.status not in ('new','open') then skip_reason:='ticket_not_actionable';
  elsif not exists(select 1 from public.audit_log l where l.action='support.ticket_context_authorized'
      and l.resource_type='support_case' and l.resource_id=case_row.id::text
      and l.actor_id=agent_row.id::text and l.details->>'task_id'=task_row.id::text) then
    skip_reason:='support_context_not_authorized';
  elsif not exists(select 1 from public.approvals a where a.project_id=project_row.id
      and a.approval_type='project_budget' and a.status='approved'
      and a.decisions #>> '{cfo,decision}'='approve'
      and a.decisions #>> '{founder,decision}'='approve') then skip_reason:='initiative_approval_missing';
  end if;
  if skip_reason is not null then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('agent',artifact_row.agent_id::text,'support.reply_delivery_blocked','task_agent_artifact',artifact_row.id::text,
        pg_catalog.jsonb_build_object('task_id',artifact_row.task_id,'project_id',task_row.project_id,
          'reason_code',skip_reason));
    return pg_catalog.jsonb_build_object('status','blocked','reason_code',skip_reason);
  end if;

  begin
    ledger_result:=public.sutra_authorize_initiative_cost('agent',agent_row.slug,agent_row.id,
      project_row.id,'support_reply','zendesk','Zendesk reply delivery for assigned task '||task_row.id::text,
      ceiling_eur,'EUR','zendesk-reply-action-'||artifact_row.id::text);
    if ledger_result->>'status' not in ('reserved','already_reserved') then
      raise exception 'Zendesk reply reservation failed' using errcode='23514';
    end if;
    insert into public.zendesk_reply_actions(artifact_id,project_id,task_id,support_case_id,
        ticket_id,agent_id,initiative_ledger_id)
      values(artifact_row.id,project_row.id,task_row.id,case_row.id,case_row.external_ticket_id,
        agent_row.id,(ledger_result->>'ledger_id')::uuid)
      returning * into action_row;
  exception when others then
    get stacked diagnostics err_state=returned_sqlstate;
    skip_reason:=case when err_state='23514' then 'budget_or_policy_hard_stop'
      when err_state='42501' then 'authorization_rejected' else 'reservation_unavailable' end;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('agent',artifact_row.agent_id::text,'support.reply_delivery_blocked','task_agent_artifact',artifact_row.id::text,
        pg_catalog.jsonb_build_object('task_id',artifact_row.task_id,'project_id',project_row.id,
          'reason_code',skip_reason));
    return pg_catalog.jsonb_build_object('status','blocked','reason_code',skip_reason);
  end;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('agent',agent_row.slug,'support.reply_delivery_queued','zendesk_reply_action',action_row.id::text,
        pg_catalog.jsonb_build_object('project_id',project_row.id,'task_id',task_row.id,
        'artifact_id',artifact_row.id,'ledger_id',action_row.initiative_ledger_id,
        'reserved_cost_eur',ceiling_eur));
  return pg_catalog.jsonb_build_object('status','queued','action_id',action_row.id,
    'ledger_id',action_row.initiative_ledger_id,'reserved_cost_eur',ceiling_eur,'idempotent',false);
end;
$$;
revoke all on function public.sutra_enqueue_zendesk_reply(uuid) from public,anon,authenticated,service_role;

create function public.sutra_queue_zendesk_reply_after_artifact()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.artifact ? 'support_reply_draft' then
    perform public.sutra_enqueue_zendesk_reply(new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_queue_zendesk_reply_after_artifact() from public,anon,authenticated,service_role;
create trigger task_agent_artifacts_queue_zendesk_reply
  after insert on public.task_agent_artifacts
  for each row execute function public.sutra_queue_zendesk_reply_after_artifact();

create function public.sutra_claim_zendesk_reply_action(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare action_row public.zendesk_reply_actions%rowtype; stale_row record; claim_uuid uuid;
  ceiling_eur numeric; reply_text text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'Zendesk reply worker identity is invalid' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.zendesk_reply_cost_ceiling'));
  for stale_row in select a.id,a.initiative_ledger_id from public.zendesk_reply_actions a
    where a.status='sending' and a.delivery_lease_expires_at<=pg_catalog.clock_timestamp()
    for update skip locked
  loop
    perform public.sutra_settle_initiative_cost(p_worker_id,stale_row.initiative_ledger_id,null,false);
    update public.zendesk_reply_actions set status='unknown',delivery_claim_token=null,
      delivery_lease_expires_at=null,last_delivery_error_code='provider_outcome_unknown',updated_at=pg_catalog.now()
      where id=stale_row.id and status='sending';
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',left(p_worker_id,120),'support.reply_delivery_unknown','zendesk_reply_action',stale_row.id::text,
        pg_catalog.jsonb_build_object('error_code','provider_outcome_unknown','reason','delivery_lease_expired'));
  end loop;
  ceiling_eur:=public.sutra_zendesk_reply_cost_ceiling();
  if ceiling_eur is null then return null; end if;
  select a.* into action_row from public.zendesk_reply_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    join public.projects p on p.id=a.project_id
    join public.tasks t on t.id=a.task_id
    join public.agents g on g.id=a.agent_id
    join public.support_cases c on c.id=a.support_case_id
    join public.task_agent_artifacts artifact on artifact.id=a.artifact_id
    where a.status='queued' and l.status='reserved' and l.reserved_amount>=ceiling_eur
      and p.status='active' and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap' and not p.legal_hold
      and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.owner_agent_id=g.id and t.assigned_agent_id=g.id
      and t.status in ('in_progress','review','completed') and g.active and g.slug='sales'
      and c.provider='zendesk' and c.external_ticket_id=a.ticket_id and c.status in ('new','open')
      and artifact.artifact_type='sales_handoff'
      and artifact.artifact->'support_reply_draft'->>'ticket_id'=a.ticket_id
      and exists(select 1 from public.approvals ap where ap.project_id=p.id
        and ap.approval_type='project_budget' and ap.status='approved'
        and ap.decisions #>> '{cfo,decision}'='approve'
        and ap.decisions #>> '{founder,decision}'='approve')
      and exists(select 1 from public.audit_log al where al.action='support.ticket_context_authorized'
        and al.resource_type='support_case' and al.resource_id=c.id::text
        and al.actor_id=g.id::text and al.details->>'task_id'=t.id::text)
    order by a.created_at,a.id limit 1 for update of a skip locked;
  if not found then return null; end if;
  claim_uuid:=pg_catalog.gen_random_uuid();
  update public.zendesk_reply_actions set status='sending',
    delivery_attempt_count=delivery_attempt_count+1,delivery_claim_token=claim_uuid,
    delivery_lease_expires_at=pg_catalog.clock_timestamp()+interval '2 minutes',
    last_delivery_error_code=null,updated_at=pg_catalog.now() where id=action_row.id;
  select artifact.artifact->'support_reply_draft'->>'reply_text' into reply_text
    from public.task_agent_artifacts artifact where artifact.id=action_row.artifact_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_worker_id,120),'support.reply_delivery_claimed','zendesk_reply_action',action_row.id::text,
      pg_catalog.jsonb_build_object('project_id',action_row.project_id,'task_id',action_row.task_id,
        'ledger_id',action_row.initiative_ledger_id,'attempt',action_row.delivery_attempt_count+1));
  return pg_catalog.jsonb_build_object('status','claimed','action_id',action_row.id,
    'claim_token',claim_uuid,'ledger_id',action_row.initiative_ledger_id,
    'action',pg_catalog.jsonb_build_object('ticket_id',action_row.ticket_id,
      'reply_text',reply_text,
      'idempotency_key','zendesk-reply-action-'||action_row.artifact_id::text));
end;
$$;
revoke all on function public.sutra_claim_zendesk_reply_action(text) from public,anon,authenticated;
grant execute on function public.sutra_claim_zendesk_reply_action(text) to service_role;

create function public.sutra_validate_zendesk_reply_claim(
  p_worker_id text,p_action_id uuid,p_claim_token uuid
) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare action_row public.zendesk_reply_actions%rowtype; ceiling_eur numeric;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_action_id is null or p_claim_token is null then
    raise exception 'Zendesk reply claim is malformed' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.zendesk_reply_cost_ceiling'));
  ceiling_eur:=public.sutra_zendesk_reply_cost_ceiling();
  if ceiling_eur is null then return false; end if;
  select * into action_row from public.zendesk_reply_actions a where a.id=p_action_id
    and a.status='sending' and a.delivery_claim_token=p_claim_token
    and a.delivery_lease_expires_at>pg_catalog.clock_timestamp() for update;
  if not found then return false; end if;
  return exists(
    select 1 from public.initiative_budget_ledger l
    join public.projects p on p.id=action_row.project_id
    join public.tasks t on t.id=action_row.task_id
    join public.agents g on g.id=action_row.agent_id
    join public.support_cases c on c.id=action_row.support_case_id
    join public.task_agent_artifacts artifact on artifact.id=action_row.artifact_id
    where l.id=action_row.initiative_ledger_id and l.status='reserved'
      and l.reserved_amount>=ceiling_eur
      and p.status='active' and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap'
      and not p.legal_hold
      and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.owner_agent_id=g.id and t.assigned_agent_id=g.id
      and t.status in ('in_progress','review','completed') and g.active and g.slug='sales'
      and c.provider='zendesk' and c.external_ticket_id=action_row.ticket_id and c.status in ('new','open')
      and artifact.artifact_type='sales_handoff'
      and artifact.artifact->'support_reply_draft'->>'ticket_id'=action_row.ticket_id
      and exists(select 1 from public.approvals ap where ap.project_id=p.id
        and ap.approval_type='project_budget' and ap.status='approved'
        and ap.decisions #>> '{cfo,decision}'='approve'
        and ap.decisions #>> '{founder,decision}'='approve')
      and exists(select 1 from public.audit_log al where al.action='support.ticket_context_authorized'
        and al.resource_type='support_case' and al.resource_id=c.id::text
        and al.actor_id=g.id::text and al.details->>'task_id'=t.id::text)
  );
end;
$$;
revoke all on function public.sutra_validate_zendesk_reply_claim(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.sutra_validate_zendesk_reply_claim(text,uuid,uuid) to service_role;

create function public.sutra_finish_zendesk_reply_action(
  p_worker_id text,p_action_id uuid,p_claim_token uuid,p_status text,p_error_code text,
  p_actual_cost_eur numeric,p_cost_known boolean
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare action_row public.zendesk_reply_actions%rowtype; settlement jsonb;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_action_id is null or p_claim_token is null
    or p_status is null or p_status not in ('sent','failed','unknown') or p_cost_known is null
    or (p_status='sent' and (p_error_code is not null or p_cost_known or p_actual_cost_eur is not null))
    or (p_status='failed' and (p_error_code is null or not p_cost_known or p_actual_cost_eur is distinct from 0::numeric))
    or (p_status='unknown' and (p_error_code is null or p_cost_known or p_actual_cost_eur is not null))
    or (p_error_code is not null and p_error_code not in (
      'authorization_revoked','invalid_action','ticket_read_failed','ticket_not_actionable',
      'provider_rejected','safe_update_conflict','provider_outcome_unknown',
      'malformed_provider_response','provider_response_too_large')) then
    raise exception 'Zendesk reply result is malformed' using errcode='22023';
  end if;
  select * into action_row from public.zendesk_reply_actions a where a.id=p_action_id
    and a.status='sending' and a.delivery_claim_token=p_claim_token
    and a.delivery_lease_expires_at>pg_catalog.clock_timestamp() for update;
  if not found then raise exception 'Zendesk reply claim is no longer active' using errcode='42501'; end if;
  settlement:=public.sutra_settle_initiative_cost(p_worker_id,action_row.initiative_ledger_id,
    p_actual_cost_eur,p_cost_known);
  update public.zendesk_reply_actions set status=p_status,last_delivery_error_code=p_error_code,
    delivery_claim_token=null,delivery_lease_expires_at=null,updated_at=pg_catalog.now()
    where id=p_action_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_worker_id,120),case p_status when 'sent' then 'support.reply_sent'
      when 'failed' then 'support.reply_failed' else 'support.reply_delivery_unknown' end,
      'zendesk_reply_action',p_action_id::text,
      pg_catalog.jsonb_build_object('project_id',action_row.project_id,'task_id',action_row.task_id,
        'ledger_id',action_row.initiative_ledger_id,'error_code',p_error_code,
        'cost_status',settlement->>'status'));
  return pg_catalog.jsonb_build_object('status',p_status,'action_id',p_action_id,
    'ledger_status',settlement->>'status');
end;
$$;
revoke all on function public.sutra_finish_zendesk_reply_action(text,uuid,uuid,text,text,numeric,boolean)
  from public,anon,authenticated;
grant execute on function public.sutra_finish_zendesk_reply_action(text,uuid,uuid,text,text,numeric,boolean)
  to service_role;

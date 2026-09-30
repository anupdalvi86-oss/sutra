-- Authorize ephemeral ticket-content reads only for the exact assigned Sales
-- task, within an assessed active initiative and with no legal stop.
create function public.sutra_authorize_zendesk_task_context(
  p_agent_id uuid,p_task_id uuid,p_ticket_id text
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  agent_row public.agents%rowtype;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  case_row public.support_cases%rowtype;
  task_text text;
  declared_ticket_count integer;
begin
  if p_agent_id is null or p_task_id is null or p_ticket_id is null
      or p_ticket_id !~ '^[1-9][0-9]{0,18}$' then
    raise exception 'invalid support context request' using errcode='22023';
  end if;
  select * into agent_row from public.agents where id=p_agent_id and slug='sales' and active;
  if not found then
    raise exception 'support context requires an active Sales agent' using errcode='42501';
  end if;
  select * into task_row from public.tasks where id=p_task_id for update;
  if not found or task_row.owner_agent_id is distinct from p_agent_id
      or task_row.assigned_agent_id is distinct from p_agent_id or task_row.status<>'in_progress' then
    raise exception 'support context requires the exact in-progress Sales task' using errcode='42501';
  end if;
  task_text:=concat_ws(' ',task_row.title,task_row.description,task_row.acceptance_criteria::text);
  select count(*)::integer into declared_ticket_count
    from regexp_matches(task_text,'Zendesk ticket ID: [1-9][0-9]{0,18}([^0-9]|$)','g');
  if declared_ticket_count<>1 or task_text !~ ('Zendesk ticket ID: '||p_ticket_id||'([^0-9]|$)') then
    raise exception 'support ticket must be named exactly once in the assigned task' using errcode='42501';
  end if;
  select * into project_row from public.projects where id=task_row.project_id for update;
  if not found or project_row.status<>'active' or project_row.legal_hold
      or project_row.budget_assessment_status<>'within_cap'
      or project_row.budget_assessment->>'recommended_action'<>'proceed_within_cap'
      or exists(select 1 from public.legal_escalations e where e.project_id=project_row.id and e.status='open') then
    raise exception 'support context is blocked by initiative budget or legal state' using errcode='42501';
  end if;
  select * into case_row from public.support_cases
    where provider='zendesk' and external_ticket_id=p_ticket_id for update;
  if not found or case_row.status in ('solved','closed') then
    raise exception 'Zendesk support case is missing or closed' using errcode='42501';
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',p_agent_id::text,'support.ticket_context_authorized','support_case',case_row.id::text,
      jsonb_build_object('task_id',p_task_id,'project_id',project_row.id));
  return jsonb_build_object('ticket_id',case_row.external_ticket_id,'status',case_row.status,
    'priority',case_row.priority,'provider_updated_at',case_row.provider_updated_at);
end;
$$;
revoke all on function public.sutra_authorize_zendesk_task_context(uuid,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.sutra_authorize_zendesk_task_context(uuid,uuid,text) to service_role;

-- Only the task that recorded an authorized, scoped context read can persist a
-- matching private response draft. This does not enqueue or send a reply.
create function public.sutra_validate_zendesk_task_reply_draft()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  draft jsonb;
  task_row public.tasks%rowtype;
  ticket_id text;
  declared_ticket_count integer;
begin
  if not (new.artifact ? 'support_reply_draft') then return new; end if;
  draft:=new.artifact->'support_reply_draft';
  if new.artifact_type<>'sales_handoff' or jsonb_typeof(draft) is distinct from 'object'
      or (select count(*) from jsonb_object_keys(draft))<>4
      or jsonb_typeof(draft->'ticket_id') is distinct from 'string'
      or jsonb_typeof(draft->'category') is distinct from 'string'
      or draft->>'category' not in ('billing','access','bug','how_to','other')
      or jsonb_typeof(draft->'urgency') is distinct from 'string'
      or draft->>'urgency' not in ('low','normal','high','urgent')
      or jsonb_typeof(draft->'reply_text') is distinct from 'string'
      or length(trim(draft->>'reply_text')) not between 8 and 4000 then
    raise exception 'Zendesk reply draft is malformed' using errcode='22023';
  end if;
  ticket_id:=draft->>'ticket_id';
  if ticket_id !~ '^[1-9][0-9]{0,18}$' then
    raise exception 'Zendesk reply draft ticket ID is invalid' using errcode='22023';
  end if;
  select * into task_row from public.tasks where id=new.task_id;
  select count(*)::integer into declared_ticket_count
    from regexp_matches(concat_ws(' ',task_row.title,task_row.description,task_row.acceptance_criteria::text),
      'Zendesk ticket ID: [1-9][0-9]{0,18}([^0-9]|$)','g');
  if task_row.id is null or task_row.owner_agent_id is distinct from new.agent_id
      or task_row.assigned_agent_id is distinct from new.agent_id
      or task_row.status<>'in_progress' or declared_ticket_count<>1
      or not (concat_ws(' ',task_row.title,task_row.description,task_row.acceptance_criteria::text)
        ~ ('Zendesk ticket ID: '||ticket_id||'([^0-9]|$)'))
      or not exists(select 1 from public.agents a where a.id=new.agent_id and a.slug='sales' and a.active)
      or not exists(select 1 from public.projects p where p.id=task_row.project_id
        and p.status='active' and p.budget_assessment_status='within_cap'
        and p.budget_assessment->>'recommended_action'='proceed_within_cap'
        and not p.legal_hold
        and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open'))
      or not exists(select 1 from public.support_cases c where c.provider='zendesk'
        and c.external_ticket_id=ticket_id and c.status not in ('solved','closed'))
      or not exists(select 1 from public.audit_log a join public.support_cases c
        on c.id::text=a.resource_id and c.external_ticket_id=ticket_id
        where a.action='support.ticket_context_authorized' and a.resource_type='support_case'
          and a.actor_id=new.agent_id::text and a.details->>'task_id'=new.task_id::text) then
    raise exception 'Zendesk reply draft requires an authorized task-scoped support context read'
      using errcode='42501';
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_validate_zendesk_task_reply_draft()
  from public,anon,authenticated,service_role;
create trigger task_agent_artifacts_zendesk_reply_draft
  before insert on public.task_agent_artifacts
  for each row execute function public.sutra_validate_zendesk_task_reply_draft();

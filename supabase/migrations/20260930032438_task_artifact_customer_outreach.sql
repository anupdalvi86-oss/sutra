-- Let assigned Sales/Marketing task artifacts request scoped customer actions.
-- The existing email RPC remains the only persistence path, so its consent,
-- shared-budget, legal, per-message and idempotency controls remain authoritative.
create function public.sutra_queue_task_artifact_customer_actions()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  agent_slug text;
  task_row public.tasks%rowtype;
  action jsonb;
  action_result jsonb;
  action_results jsonb:='[]'::jsonb;
  action_index integer:=0;
  customer_id uuid;
  purpose text;
  message_ceiling numeric;
  failure_state text;
  failure_category text;
  legal_reason text;
  legal_case_id uuid;
  legal_source_at timestamptz;
begin
  if not (new.artifact ? 'customer_actions') and not (new.artifact ? 'legal_escalation') then return new; end if;
  if new.artifact_type not in ('campaign_draft','sales_handoff') then
    raise exception 'customer actions and legal escalations require a Sales or Marketing artifact'
      using errcode='22023';
  end if;
  if new.artifact ? 'customer_actions' and jsonb_typeof(new.artifact->'customer_actions') is distinct from 'array' then
    raise exception 'customer actions must be a JSON array' using errcode='22023';
  end if;
  if new.artifact ? 'customer_actions' and jsonb_array_length(new.artifact->'customer_actions')>5 then
    raise exception 'customer actions exceed the five-request limit' using errcode='22023';
  end if;
  select a.slug into agent_slug from public.agents a
    where a.id=new.agent_id and a.active and a.slug in ('sales','cmo');
  if agent_slug is null then
    raise exception 'customer actions require an active Sales or Marketing agent'
      using errcode='42501';
  end if;
  select t.* into task_row from public.tasks t
    where t.id=new.task_id and t.owner_agent_id=new.agent_id
      and t.assigned_agent_id=new.agent_id and t.status='in_progress';
  if not found then
    raise exception 'customer actions require the exact active task assignment'
      using errcode='42501';
  end if;
  if new.artifact ? 'legal_escalation' then
    if jsonb_typeof(new.artifact->'legal_escalation') is distinct from 'string'
      or length(trim(new.artifact->>'legal_escalation')) not between 8 and 1000 then
      raise exception 'legal escalation requires a bounded reason for founder review' using errcode='22023';
    end if;
    legal_reason:=trim(new.artifact->>'legal_escalation');
    legal_source_at:=clock_timestamp();
    insert into public.legal_escalations(project_id,source_assessed_at,summary)
      values(task_row.project_id,legal_source_at,
        'Sales/Marketing task requires founder legal review: '||legal_reason)
      on conflict(project_id,source_assessed_at) do nothing
      returning id into legal_case_id;
    if legal_case_id is null then
      select id into legal_case_id from public.legal_escalations
        where project_id=task_row.project_id and source_assessed_at=legal_source_at;
    end if;
    update public.projects set status='paused',budget_assessment_status='legal_escalation',
      budget_assessed_at=legal_source_at,
      budget_assessment=coalesce(budget_assessment,'{}'::jsonb)||jsonb_build_object(
        'recommended_action','legal_escalation','legal_reason',legal_reason),updated_at=now()
      where id=task_row.project_id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('agent',new.agent_id::text,'legal.escalation_opened','legal_escalation',legal_case_id::text,
        jsonb_build_object('project_id',task_row.project_id,'task_id',new.task_id,
          'source','sales_marketing_task_artifact'));
    action_results:=action_results||jsonb_build_array(jsonb_build_object(
      'status','escalated','legal_case_id',legal_case_id));
  end if;
  message_ceiling:=public.sutra_customer_email_cost_ceiling();

  for action in select entry from jsonb_array_elements(
      coalesce(new.artifact->'customer_actions','[]'::jsonb)) as requests(entry)
  loop
    action_index:=action_index+1;
    if jsonb_typeof(action) is distinct from 'object' then
      raise exception 'customer action must be an object' using errcode='22023';
    end if;
    if (select count(*) from jsonb_object_keys(action))<>4
      or jsonb_typeof(action->'customer_id') is distinct from 'string'
      or action->>'customer_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or jsonb_typeof(action->'purpose') is distinct from 'string'
      or jsonb_typeof(action->'subject') is distinct from 'string'
      or length(trim(action->>'subject')) not between 1 and 200
      or jsonb_typeof(action->'body_text') is distinct from 'string'
      or length(trim(action->>'body_text')) not between 1 and 10000 then
      raise exception 'customer action request is malformed' using errcode='22023';
    end if;
    if (agent_slug='cmo' and action->>'purpose'<>'marketing')
      or (agent_slug='sales' and action->>'purpose' not in ('sales','support')) then
      raise exception 'agent role cannot perform this customer action purpose' using errcode='42501';
    end if;
    customer_id:=(action->>'customer_id')::uuid;
    purpose:=action->>'purpose';

    if legal_case_id is not null then
      action_results:=action_results||jsonb_build_array(jsonb_build_object(
        'status','blocked','reason','legal_review_required'));
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('agent',new.agent_id::text,'customer.action_blocked','task_agent_artifact',new.id::text,
          jsonb_build_object('task_id',new.task_id,'reason','legal_review_required'));
      continue;
    end if;

    -- A task must name each recipient ID itself. The model cannot invent or
    -- select arbitrary company contacts from ambient database access.
    if position(customer_id::text in lower(concat_ws(' ',task_row.title,task_row.description,
        task_row.acceptance_criteria::text)))=0 then
      action_results:=action_results||jsonb_build_array(jsonb_build_object(
        'status','blocked','reason','customer_not_in_task_scope'));
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('agent',new.agent_id::text,'customer.action_blocked','task_agent_artifact',new.id::text,
          jsonb_build_object('task_id',new.task_id,'reason','customer_not_in_task_scope'));
      continue;
    end if;
    if message_ceiling is null or message_ceiling<=0 then
      action_results:=action_results||jsonb_build_array(jsonb_build_object(
        'status','blocked','reason','message_cost_ceiling_unconfigured'));
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('agent',new.agent_id::text,'customer.action_blocked','task_agent_artifact',new.id::text,
          jsonb_build_object('task_id',new.task_id,'reason','message_cost_ceiling_unconfigured'));
      continue;
    end if;
    begin
      action_result:=public.sutra_queue_customer_email(new.agent_id,agent_slug,new.task_id,
        task_row.project_id,customer_id,purpose,action->>'subject',action->>'body_text',message_ceiling,
        'task-artifact:'||new.id::text||':'||action_index::text);
      action_results:=action_results||jsonb_build_array(jsonb_build_object(
        'status',action_result->>'status','action_id',action_result->'action_id'));
    exception when sqlstate '42501' or sqlstate '23514' or sqlstate '22023' or sqlstate '23505' then
      get stacked diagnostics failure_state=returned_sqlstate;
      failure_category:=case failure_state
        when '42501' then 'consent_or_authorization_blocked'
        when '23514' then 'budget_or_policy_blocked'
        when '22023' then 'invalid_action_or_cost_ceiling'
        when '23505' then 'idempotency_conflict'
        else 'queue_unavailable'
      end;
      action_results:=action_results||jsonb_build_array(jsonb_build_object(
        'status','blocked','reason',failure_category));
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('agent',new.agent_id::text,'customer.action_blocked','task_agent_artifact',new.id::text,
          jsonb_build_object('task_id',new.task_id,'reason',failure_category,'sqlstate',failure_state));
    end;
  end loop;
  new.artifact:=new.artifact||jsonb_build_object('customer_action_results',action_results);
  return new;
end;
$$;

revoke all on function public.sutra_queue_task_artifact_customer_actions()
  from public,anon,authenticated,service_role;
create trigger task_artifact_customer_actions
  before insert on public.task_agent_artifacts
  for each row execute function public.sutra_queue_task_artifact_customer_actions();

-- An open legal case suspends all new paid reservations for that initiative.
-- It does not release any prior, unknown, or in-flight reservation.
create function public.sutra_block_expenses_for_open_legal_escalation()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  if new.project_id is not null and exists(select 1 from public.legal_escalations e
      where e.project_id=new.project_id and e.status='open') then
    raise exception 'initiative has an open legal escalation; paid work is paused'
      using errcode='42501';
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_block_expenses_for_open_legal_escalation()
  from public,anon,authenticated,service_role;
create trigger expenses_block_open_legal_escalation
  before insert on public.expenses
  for each row execute function public.sutra_block_expenses_for_open_legal_escalation();

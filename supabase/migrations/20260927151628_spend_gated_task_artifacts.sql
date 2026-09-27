-- Execute internal planning, operations, marketing, sales and governance tasks
-- only through a leased run with an existing database spend reservation.
-- The established spend RPC accepts these runs only for the assigned task in an
-- approved project; all reservation, policy, budget, approval and audit logic is unchanged.
create or replace function public.sutra_reserve_agent_run_spend(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_provider text,p_model text,p_amount numeric
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  run_row public.agent_runs%rowtype;
  agent_row public.agents%rowtype;
  project_row public.projects%rowtype;
  prior_row public.agent_run_spend_reservations%rowtype;
  spend_result jsonb;
  expense_id uuid;
  approval_id uuid;
  spend_status text;
  warnings text[] := '{}';
  budget_row public.budgets%rowtype;
  used_amount numeric(14,2);
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null
    or p_provider is null or p_provider !~ '^[a-z0-9][a-z0-9_-]{0,79}$'
    or p_model is null or length(p_model) not between 1 and 200 or p_model ~ '[[:cntrl:]]'
    or p_amount is null or p_amount <= 0 or p_amount > 999999999999.99
    or p_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'malformed agent run spend reservation' using errcode = '22023';
  end if;
  select * into run_row from public.agent_runs r
    where r.id=p_run_id and r.status='running' and r.lease_token=p_lease_token
      and r.trigger_type in ('founder_proposal','task_artifact') and r.lease_expires_at >= now()
    for update;
  if not found then raise exception 'agent run lease is invalid or expired' using errcode = '42501'; end if;
  select * into agent_row from public.agents a where a.id=run_row.agent_id and a.active;
  select * into project_row from public.projects p where p.id=run_row.project_id;
  if agent_row.id is null or project_row.id is null then
    raise exception 'agent spend requires an active agent and project' using errcode = '42501';
  end if;
  if project_row.status not in ('proposed','approved','active')
    or (run_row.trigger_type='task_artifact' and project_row.status not in ('approved','active')) then
    raise exception 'project is not eligible for agent review spend' using errcode = '42501';
  end if;
  if run_row.trigger_type='task_artifact' and not exists(
    select 1 from public.tasks t where t.id=run_row.task_id and t.project_id=run_row.project_id
      and t.owner_agent_id=run_row.agent_id and t.assigned_agent_id=run_row.agent_id and t.status='in_progress') then
    raise exception 'task artifact run does not own an active assigned task' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));

  -- Approval requeues the blocked run. Reuse its approved reservation rather than
  -- recording a duplicate charge before the first provider request.
  select * into prior_row from public.agent_run_spend_reservations s
    where s.agent_run_id=p_run_id and s.status='reserved'
    order by s.created_at desc limit 1 for update;
  if found then
    if prior_row.provider <> p_provider or prior_row.model <> p_model
      or prior_row.reserved_amount < p_amount then
      raise exception 'approved model reservation does not cover this route or amount' using errcode = '42501';
    end if;
    return jsonb_build_object('status','approved','reservation_id',prior_row.id,
      'expense_id',prior_row.expense_id,'reserved_amount',prior_row.reserved_amount,'reused',true);
  end if;

  -- A worker may have died after the provider accepted a request. Keep its full
  -- expense reserve and mark usage unknown before allowing a later lease attempt.
  with stale as (
    update public.agent_run_spend_reservations set status='unknown',
        usage=jsonb_build_object('reason','worker_retry_after_provider_start'),settled_at=now()
      where agent_run_id=p_run_id and status='started'
      returning id,reserved_amount
  )
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    select 'system',p_worker_id,'agent_run.spend_unknown','agent_run_spend_reservation',stale.id::text,
      jsonb_build_object('run_id',p_run_id,'reserved_amount',stale.reserved_amount,
        'reason','worker_retry_after_provider_start') from stale;

  -- The central spend function is also used for all policy tiers and non-project
  -- budgets. Project budgets need a pre-approval review exception, so validate
  -- those scopes here while holding the same transaction lock, then bind the
  -- resulting expense and approval to this founder-proposed project atomically.
  for budget_row in
    select * from public.budgets b where b.active and b.currency='EUR'
      and b.scope='project' and (b.scope_key='*' or b.scope_key=run_row.project_id::text)
    order by b.scope_key,b.period for update
  loop
    if budget_row.limit_amount is null then continue; end if;
    if budget_row.period='transaction' then
      used_amount := 0;
    elsif budget_row.period='daily' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.project_id=run_row.project_id and e.currency='EUR'
          and e.status in ('requested','approved','paid') and e.created_at >= date_trunc('day',now());
    elsif budget_row.period='monthly' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.project_id=run_row.project_id and e.currency='EUR'
          and e.status in ('requested','approved','paid') and e.created_at >= date_trunc('month',now());
    else
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.project_id=run_row.project_id and e.currency='EUR'
          and e.status in ('requested','approved','paid');
    end if;
    if used_amount+p_amount > budget_row.limit_amount and budget_row.hard_stop then
      raise exception 'budget hard stop: project:% budget exceeded',run_row.project_id using errcode = '23514';
    end if;
    if used_amount+p_amount >= budget_row.limit_amount*budget_row.warning_percent/100 then
      warnings := array_append(warnings,'project:'||budget_row.scope_key||':'||budget_row.period);
    end if;
  end loop;

  spend_result := public.sutra_authorize_spend(
    'agent',agent_row.slug,agent_row.id,null,agent_row.department_id,'ai_inference',
    'hermes:'||p_provider,
    'Bounded Hermes review for '||agent_row.slug||' ('||left(p_model,160)||')',p_amount,'EUR');
  expense_id := (spend_result->>'expense_id')::uuid;
  approval_id := nullif(spend_result->>'approval_id','')::uuid;
  spend_status := spend_result->>'status';
  update public.expenses set project_id=run_row.project_id where id=expense_id;
  if approval_id is not null then update public.approvals set project_id=run_row.project_id where id=approval_id; end if;
  insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,reserved_amount,status)
    values(run_row.id,run_row.attempt_count,expense_id,p_provider,p_model,p_amount,
      case when spend_status='approved' then 'reserved' else 'awaiting_approval' end)
    returning * into prior_row;

  if spend_status <> 'approved' then
    update public.agent_runs set status='blocked',finished_at=now(),lease_token=null,lease_expires_at=null,
      output=jsonb_build_object('blocked_by','model_spend_approval','approval_id',approval_id,
        'reservation_id',prior_row.id,'reserved_amount',p_amount)
      where id=run_row.id;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'agent_run.spend_reserved','agent_run_spend_reservation',prior_row.id::text,
      jsonb_build_object('run_id',run_row.id,'agent',agent_row.slug,'project_id',run_row.project_id,
        'provider',p_provider,'model',p_model,'amount',p_amount,'status',spend_status,
        'approval_id',approval_id,'budget_warnings',warnings));
  return jsonb_build_object('status',spend_status,'reservation_id',prior_row.id,'expense_id',expense_id,
    'approval_id',approval_id,'reserved_amount',p_amount,'required_approvers',spend_result->'required_approvers',
    'budget_warnings',warnings,'reused',false);
end;
$$;


create table public.task_agent_artifacts (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null unique references public.tasks(id) on delete cascade,
  agent_run_id uuid not null unique references public.agent_runs(id) on delete restrict,
  agent_id uuid not null references public.agents(id) on delete restrict,
  artifact_type text not null check (artifact_type in (
    'product_plan','technical_design','operations_plan','release_plan',
    'campaign_draft','sales_handoff','governance_review'
  )),
  artifact jsonb not null check (jsonb_typeof(artifact)='object' and octet_length(artifact::text)<=24000),
  created_at timestamptz not null default now()
);
alter table public.task_agent_artifacts enable row level security;
revoke all on public.task_agent_artifacts from public,anon,authenticated,service_role;

create function public.sutra_task_artifact_type(p_role text)
returns text language sql immutable security invoker set search_path=pg_catalog as $$
  select case p_role
    when 'product_manager' then 'product_plan'
    when 'architect' then 'technical_design'
    when 'coo' then 'operations_plan'
    when 'devops' then 'release_plan'
    when 'cmo' then 'campaign_draft'
    when 'sales' then 'sales_handoff'
    when 'governance_audit' then 'governance_review'
    else null end
$$;

create function public.sutra_validate_task_artifact(p_role text,p_artifact jsonb)
returns boolean language plpgsql immutable security invoker set search_path=pg_catalog as $$
declare field record; item jsonb; expected_fields text[]; value jsonb;
begin
  if p_artifact is null or jsonb_typeof(p_artifact)<>'object' or octet_length(p_artifact::text)>12000 then return false; end if;
  expected_fields:=case p_role
    when 'product_manager' then array['scope','milestones','acceptance_criteria']
    when 'architect' then array['design','components','security_risks']
    when 'coo' then array['operational_dependencies','readiness_checklist','incident_plan']
    when 'devops' then array['deployment_steps','health_checks','rollback_steps']
    when 'cmo' then array['audience','positioning','draft_copy','claims','success_metrics']
    when 'sales' then array['ideal_customer_profile','lead_criteria','qualification_questions','first_contact_draft']
    when 'governance_audit' then array['controls_checked','findings','recommendation']
    else null end;
  if expected_fields is null then return false; end if;
  for field in select key,case when key=any(array['milestones','acceptance_criteria','components','security_risks',
      'operational_dependencies','readiness_checklist','deployment_steps','health_checks','rollback_steps',
      'claims','success_metrics','lead_criteria','qualification_questions','controls_checked','findings'])
      then 'array' else 'string' end as value_type from unnest(expected_fields) as required(key)
  loop
    value:=p_artifact->field.key;
    if value is null or jsonb_typeof(value)<>field.value_type then return false; end if;
    if field.value_type='string' then
      if length(trim(value#>>'{}')) not between 8 and 4000 then return false; end if;
    else
      if jsonb_array_length(value) not between 1 and 20 then return false; end if;
      for item in select element from jsonb_array_elements(value) as entries(element)
      loop
        if jsonb_typeof(item)<>'string' or length(trim(item#>>'{}')) not between 1 and 1000 then return false; end if;
      end loop;
    end if;
  end loop;
  return true;
end
$$;

create index task_agent_artifact_queue_idx on public.tasks(status,created_at)
  where status in ('ready','in_progress');
create index agent_runs_task_artifact_queue_idx on public.agent_runs(status,lease_expires_at,created_at)
  where trigger_type='task_artifact';
create unique index agent_runs_task_artifact_active_unique on public.agent_runs(task_id)
  where trigger_type='task_artifact' and status in ('queued','running');

create function public.sutra_claim_task_agent_run(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; task_row public.tasks%rowtype;
  agent_row public.agents%rowtype; project_row public.projects%rowtype;
  policy_rows jsonb; budget_rows jsonb; artifact_type text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode='22023';
  end if;

  -- Exhausted leases cannot strand a task in progress.
  update public.agent_runs r set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
    output=coalesce(r.output,'{}'::jsonb)||jsonb_build_object('error_code','task_artifact_lease_exhausted')
    where r.trigger_type='task_artifact' and r.status='running' and r.attempt_count>=3 and r.lease_expires_at<now();
  for run_row in select r.* from public.agent_runs r join public.tasks t on t.id=r.task_id
    where r.trigger_type='task_artifact' and r.status='failed' and t.status='in_progress'
    order by r.finished_at for update of r,t skip locked
  loop
    perform public.sutra_update_task(run_row.agent_id,run_row.task_id,'blocked',
      jsonb_build_object('failure','task_artifact_attempts_exhausted','agent_run_id',run_row.id));
  end loop;

  select r.* into run_row from public.agent_runs r join public.tasks t on t.id=r.task_id
    where r.trigger_type='task_artifact' and r.attempt_count<3
      and (r.status='queued' or (r.status='running' and r.lease_expires_at<now()))
      and t.status='in_progress'
    order by r.created_at,r.id limit 1 for update of r,t skip locked;
  if found then
    update public.agent_runs r set status='running',attempt_count=r.attempt_count+1,
      started_at=coalesce(r.started_at,now()),finished_at=null,lease_token=gen_random_uuid(),
      lease_expires_at=now()+interval '10 minutes'
      where r.id=run_row.id returning r.* into run_row;
  else
    select t.* into task_row from public.tasks t join public.agents a on a.id=t.owner_agent_id and a.active
      join public.projects p on p.id=t.project_id and p.status in ('approved','active')
    where t.status='ready' and a.slug in ('product_manager','architect','coo','devops','cmo','sales','governance_audit')
      and not exists(select 1 from public.task_agent_artifacts x where x.task_id=t.id)
      and not exists(select 1 from public.agent_runs r where r.task_id=t.id and r.trigger_type='task_artifact'
        and r.status in ('succeeded','queued','running'))
    order by t.created_at,t.id limit 1 for update of t skip locked;
    if not found then return null; end if;
    select * into agent_row from public.agents a where a.id=task_row.owner_agent_id and a.active;
    insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,lease_token,lease_expires_at,attempt_count)
      values(agent_row.id,task_row.project_id,task_row.id,'task_artifact','running',
        jsonb_build_object('task_id',task_row.id,'role',agent_row.slug),'{}'::jsonb,
        now(),gen_random_uuid(),now()+interval '10 minutes',1) returning * into run_row;
    perform public.sutra_update_task(agent_row.id,task_row.id,'in_progress',
      jsonb_build_object('agent_run_id',run_row.id,'artifact_type',public.sutra_task_artifact_type(agent_row.slug)));
  end if;

  select a.* into agent_row from public.agents a where a.id=run_row.agent_id and a.active;
  select t.* into task_row from public.tasks t where t.id=run_row.task_id;
  select p.* into project_row from public.projects p where p.id=run_row.project_id;
  artifact_type:=public.sutra_task_artifact_type(agent_row.slug);
  if artifact_type is null then raise exception 'unsupported task artifact role' using errcode='23514'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'min_amount',p.min_amount,'max_amount',p.max_amount,
      'min_inclusive',p.min_inclusive,'max_inclusive',p.max_inclusive,'approvers',p.required_approvers,
      'per_transaction_limit',p.per_transaction_limit,'daily_limit',p.daily_limit,'monthly_limit',p.monthly_limit,
      'warning_percent',p.warning_percent,'hard_stop',p.hard_stop) order by p.min_amount),'[]'::jsonb)
    into policy_rows from public.spending_policies p where p.active and p.currency=project_row.currency;
  select coalesce(jsonb_agg(jsonb_build_object('scope',b.scope,'scope_key',b.scope_key,'period',b.period,
      'limit_amount',b.limit_amount,'warning_percent',b.warning_percent,'hard_stop',b.hard_stop) order by b.scope,b.period),'[]'::jsonb)
    into budget_rows from public.budgets b where b.active and b.currency=project_row.currency
      and (b.scope_key='*' or (b.scope='project' and b.scope_key=project_row.id::text));
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'task_artifact.claimed','task',task_row.id::text,
      jsonb_build_object('agent_run_id',run_row.id,'role',agent_row.slug,'attempt',run_row.attempt_count));
  return jsonb_build_object('run_id',run_row.id,'lease_token',run_row.lease_token,'attempt',run_row.attempt_count,
    'agent',jsonb_build_object('id',agent_row.id,'slug',agent_row.slug,'display_name',agent_row.display_name,
      'responsibilities',agent_row.responsibilities,'permissions',agent_row.permissions,'can_delegate_to',agent_row.can_delegate_to),
    'project',jsonb_build_object('id',project_row.id,'name',project_row.name,'description',project_row.description,
      'requested_budget',project_row.requested_budget,'currency',project_row.currency),
    'input',run_row.input,'task_artifact',jsonb_build_object('task_id',task_row.id,'role',agent_row.slug,
      'artifact_type',artifact_type,'title',task_row.title,'description',task_row.description,
      'acceptance_criteria',task_row.acceptance_criteria),
    'prior_results','[]'::jsonb,'spending_policies',policy_rows,'applicable_budgets',budget_rows);
end
$$;

create function public.sutra_submit_task_agent_artifact(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_output jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; task_row public.tasks%rowtype; agent_row public.agents%rowtype;
  artifact_id uuid; artifact_type text; item jsonb;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null or p_output is null
    or jsonb_typeof(p_output)<>'object' or octet_length(p_output::text)>24000 then
    raise exception 'malformed task artifact output' using errcode='22023';
  end if;
  if jsonb_typeof(p_output->'summary') is distinct from 'string'
    or length(trim(p_output->>'summary')) not between 8 and 5000
    or jsonb_typeof(p_output->'recommendation') is distinct from 'string'
    or length(trim(p_output->>'recommendation')) not between 2 and 5000 then
    raise exception 'malformed task artifact output' using errcode='22023';
  end if;
  if jsonb_typeof(p_output->'evidence') is distinct from 'array' then
    raise exception 'task artifact evidence must be an array' using errcode='22023';
  end if;
  if jsonb_array_length(p_output->'evidence')>10 then
    raise exception 'task artifact evidence exceeds limit' using errcode='22023';
  end if;
  for item in select element from jsonb_array_elements(p_output->'evidence') as entries(element)
  loop
    if jsonb_typeof(item)<>'object' or jsonb_typeof(item->'source') is distinct from 'string'
      or length(trim(item->>'source')) not between 1 and 200
      or jsonb_typeof(item->'claim') is distinct from 'string'
      or length(trim(item->>'claim')) not between 1 and 1000
      or jsonb_typeof(item->'url') is distinct from 'string' or length(item->>'url')>2048
      or item->>'url' !~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#][^[:space:]]*)?$' then
      raise exception 'task artifact evidence requires bounded source, claim and HTTPS URL' using errcode='22023';
    end if;
  end loop;
  select * into run_row from public.agent_runs r where r.id=p_run_id and r.trigger_type='task_artifact'
    and r.status='running' and r.lease_token=p_lease_token for update;
  if not found or run_row.lease_expires_at<now() then
    raise exception 'task artifact lease is invalid or expired' using errcode='42501';
  end if;
  if run_row.output->>'spend_status' is distinct from 'reconciled'
    or not exists(select 1 from public.agent_run_spend_reservations s
      where s.agent_run_id=run_row.id and s.attempt=run_row.attempt_count and s.status='reconciled') then
    raise exception 'task artifact requires reconciled model spend for this run attempt' using errcode='42501';
  end if;
  select * into task_row from public.tasks t where t.id=run_row.task_id for update;
  select * into agent_row from public.agents a where a.id=run_row.agent_id and a.active;
  if task_row.id is null or task_row.status<>'in_progress' or task_row.owner_agent_id is distinct from agent_row.id
    or task_row.assigned_agent_id is distinct from agent_row.id then
    raise exception 'task artifact agent does not own an active assigned task' using errcode='42501';
  end if;
  if jsonb_typeof(task_row.acceptance_criteria)<>'array'
    or jsonb_typeof(p_output->'task_acceptance') is distinct from 'array' then
    raise exception 'task acceptance criteria and evidence must be arrays' using errcode='22023';
  end if;
  if jsonb_array_length(p_output->'task_acceptance')<>jsonb_array_length(task_row.acceptance_criteria)
    or exists(select 1 from jsonb_array_elements(p_output->'task_acceptance') as entries(entry)
      where jsonb_typeof(entries.entry)<>'object' or jsonb_typeof(entries.entry->'criterion') is distinct from 'string'
        or jsonb_typeof(entries.entry->'evidence') is distinct from 'string'
        or length(trim(entries.entry->>'evidence')) not between 8 and 1000
        or not exists(select 1 from jsonb_array_elements_text(task_row.acceptance_criteria) expected(value)
          where expected.value=entries.entry->>'criterion'))
    or exists(select entries.entry->>'criterion' from jsonb_array_elements(p_output->'task_acceptance') as entries(entry)
      group by entries.entry->>'criterion' having count(*)>1)
    or exists(select value from jsonb_array_elements_text(task_row.acceptance_criteria) expected(value)
      where not exists(select 1 from jsonb_array_elements(p_output->'task_acceptance') as entries(entry)
        where entries.entry->>'criterion'=expected.value)) then
    raise exception 'task artifact must address every assigned acceptance criterion exactly once' using errcode='22023';
  end if;
  if not public.sutra_validate_task_artifact(agent_row.slug,p_output->'artifact') then
    raise exception 'task artifact does not match its database role contract' using errcode='22023';
  end if;
  artifact_type:=public.sutra_task_artifact_type(agent_row.slug);
  insert into public.task_agent_artifacts(task_id,agent_run_id,agent_id,artifact_type,artifact)
    values(task_row.id,run_row.id,agent_row.id,artifact_type,p_output) returning id into artifact_id;
  update public.agent_runs set status='succeeded',output=p_output,finished_at=now(),lease_token=null,lease_expires_at=null
    where id=run_row.id;
  perform public.sutra_update_task(agent_row.id,task_row.id,'done',
    jsonb_build_object('artifact_id',artifact_id,'artifact_type',artifact_type,'summary',left(p_output->>'summary',500)));
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',agent_row.id::text,'task.artifact_submitted','task',task_row.id::text,
      jsonb_build_object('agent_run_id',run_row.id,'artifact_id',artifact_id,'artifact_type',artifact_type));
  return jsonb_build_object('task_id',task_row.id,'agent_run_id',run_row.id,'artifact_id',artifact_id,
    'artifact_type',artifact_type,'status','succeeded');
end
$$;

revoke all on function public.sutra_task_artifact_type(text) from public,anon,authenticated,service_role;
revoke all on function public.sutra_validate_task_artifact(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.sutra_claim_task_agent_run(text) from public,anon,authenticated;
revoke all on function public.sutra_submit_task_agent_artifact(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_claim_task_agent_run(text) to service_role;
grant execute on function public.sutra_submit_task_agent_artifact(text,uuid,uuid,jsonb) to service_role;

-- Retry one terminal, usage-reconciled artifact failure automatically when
-- the approved initiative remains within its all-in budget. Unknown reservations
-- remain untouched; every retry still passes through the regular spend gate.
-- Give governed role workers only the persisted, relevant project approval and prior assessment artifacts.
create or replace function public.sutra_claim_task_agent_run(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; task_row public.tasks%rowtype;
  agent_row public.agents%rowtype; project_row public.projects%rowtype;
  policy_rows jsonb; budget_rows jsonb; prior_results jsonb; artifact_type text;
  founder_project_budget_approved boolean;
  retry_row record;
  preserved_unknown_count integer;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode='22023';
  end if;

  update public.agent_runs r set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
    output=coalesce(r.output,'{}'::jsonb)||jsonb_build_object('error_code','task_artifact_lease_exhausted')
    where r.trigger_type='task_artifact' and r.status='running' and r.attempt_count>=3 and r.lease_expires_at<now();
  for run_row in select r.* from public.agent_runs r join public.tasks t on t.id=r.task_id
    where r.trigger_type='task_artifact' and r.status='failed' and t.status='in_progress'
      and not exists (select 1 from public.agent_runs retry
        where retry.task_id=r.task_id and retry.trigger_type='task_artifact' and retry.id<>r.id
          and retry.status in ('queued','running')
          and (retry.attempt_count<3 or retry.lease_expires_at>=now()))
    order by r.finished_at for update of r,t skip locked
  loop
    perform public.sutra_update_task(run_row.agent_id,run_row.task_id,'blocked',
      jsonb_build_object('failure','task_artifact_attempts_exhausted','agent_run_id',run_row.id));
  end loop;

  -- Requeue one terminal artifact failure only when the prior provider usage
  -- was reconciled, its project remains founder-approved and within its
  -- assessed all-in cap, and no legal hold is open. The worker will create a
  -- fresh reservation through the existing spend gate before any new request.
  for retry_row in
    select t.id as task_id,t.owner_agent_id,t.project_id,r.id as failed_run_id,
      r.attempt_count,r.output
    from public.tasks t
    join public.projects p on p.id=t.project_id
    join public.agents a on a.id=t.owner_agent_id and a.id=t.assigned_agent_id and a.active
    join lateral (
      select candidate.* from public.agent_runs candidate
      where candidate.task_id=t.id and candidate.trigger_type='task_artifact'
        and candidate.status='failed'
      order by candidate.finished_at desc,candidate.id desc limit 1
    ) r on true
    where t.status='blocked' and a.slug in
        ('cpo','product_manager','architect','coo','devops','cmo','sales','governance_audit')
      and p.status='active' and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap'
      and case when jsonb_typeof(p.budget_assessment->'estimated_total_eur')='number'
        then (p.budget_assessment->>'estimated_total_eur')::numeric<=p.requested_budget
        else false end
      and not p.legal_hold
      and not exists(select 1 from public.legal_escalations e
        where e.project_id=p.id and e.status='open')
      and exists(select 1 from public.approvals ap
        where ap.project_id=p.id and ap.approval_type='project_budget' and ap.status='approved'
          and ap.decisions #>> '{founder,decision}'='approve')
      and r.attempt_count>=3 and r.output->>'error_code'='invalid_agent_output'
      and r.output->>'usage_state'='reconciled'
      and exists(select 1 from public.agent_run_spend_reservations s
        where s.agent_run_id=r.id and s.attempt=r.attempt_count and s.status='reconciled')
      and not exists(select 1 from public.task_agent_artifacts artifact where artifact.task_id=t.id)
      and not exists(select 1 from public.audit_log l
        where l.actor_type='system' and l.action='task.artifact.automatic_retry_queued'
          and l.resource_type='task' and l.resource_id=t.id::text)
    order by r.finished_at,t.id limit 20
    for update of t skip locked
  loop
    select count(*) into preserved_unknown_count
      from public.agent_run_spend_reservations s
      join public.agent_runs prior on prior.id=s.agent_run_id
      where prior.task_id=retry_row.task_id and s.status in ('unknown','overrun');
    perform public.sutra_update_task(retry_row.owner_agent_id,retry_row.task_id,'ready',
      jsonb_build_object('automatic_retry',true,'prior_failed_run_id',retry_row.failed_run_id,
        'prior_usage_reconciled',true,'preserved_unknown_reservations',preserved_unknown_count));
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'task.artifact.automatic_retry_queued','task',retry_row.task_id::text,
        jsonb_build_object('project_id',retry_row.project_id,'prior_failed_run_id',retry_row.failed_run_id,
          'prior_attempt_count',retry_row.attempt_count,'reason','invalid_agent_output_after_reconciled_usage',
          'preserved_unknown_reservations',preserved_unknown_count,
          'fresh_spend_reservation_required',true,'spending_authority_changed',false));
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
    where t.status='ready' and a.slug in ('cpo','product_manager','architect','coo','devops','cmo','sales','governance_audit')
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
  select exists(select 1 from public.approvals a where a.project_id=project_row.id
      and a.approval_type='project_budget' and a.status='approved'
      and a.decisions #>> '{founder,decision}'='approve') into founder_project_budget_approved;

  select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'min_amount',p.min_amount,'max_amount',p.max_amount,
      'min_inclusive',p.min_inclusive,'max_inclusive',p.max_inclusive,'approvers',p.required_approvers,
      'per_transaction_limit',p.per_transaction_limit,'daily_limit',p.daily_limit,'monthly_limit',p.monthly_limit,
      'warning_percent',p.warning_percent,'hard_stop',p.hard_stop) order by p.min_amount),'[]'::jsonb)
    into policy_rows from public.spending_policies p where p.active and p.currency=project_row.currency;
  select coalesce(jsonb_agg(jsonb_build_object('scope',b.scope,'scope_key',b.scope_key,'period',b.period,
      'limit_amount',b.limit_amount,'warning_percent',b.warning_percent,'hard_stop',b.hard_stop) order by b.scope,b.period),'[]'::jsonb)
    into budget_rows from public.budgets b where b.active and b.currency=project_row.currency
      and (b.scope_key='*' or (b.scope='project' and b.scope_key=project_row.id::text));

  select coalesce(jsonb_agg(previous.item order by previous.priority),'[]'::jsonb) into prior_results
  from (
    (select 1 as priority,jsonb_build_object('role','cpo','stage','founder_proposal',
      'summary',left(coalesce(r.output->>'summary',''),1200),
      'recommendation',left(coalesce(r.output->>'recommendation',''),1200),
      'evidence',coalesce((select jsonb_agg(e.value order by e.ordinality)
        from jsonb_array_elements(case when jsonb_typeof(r.output->'evidence')='array'
          then r.output->'evidence' else '[]'::jsonb end) with ordinality as e(value,ordinality)
        where e.ordinality<=2),'[]'::jsonb)) as item
    from public.agent_runs r join public.agents a on a.id=r.agent_id
    where r.project_id=project_row.id and r.trigger_type='founder_proposal' and r.status='succeeded'
      and a.slug='cpo'
    order by r.created_at desc,r.id limit 1)
    union all
    (select 2 as priority,jsonb_build_object('role',a.slug,'stage','task_artifact',
      'summary',left(coalesce(r.output->>'summary',''),1200),
      'recommendation',left(coalesce(r.output->>'recommendation',''),1200),
      'evidence',coalesce((select jsonb_agg(e.value order by e.ordinality)
        from jsonb_array_elements(case when jsonb_typeof(r.output->'evidence')='array'
          then r.output->'evidence' else '[]'::jsonb end) with ordinality as e(value,ordinality)
        where e.ordinality<=2),'[]'::jsonb),
      'artifact',coalesce(r.output->'artifact','{}'::jsonb)) as item
    from public.agent_runs r join public.agents a on a.id=r.agent_id
    where r.project_id=project_row.id and r.task_id is not null
      and r.task_id<>task_row.id and r.trigger_type='task_artifact' and r.status='succeeded'
    order by r.created_at desc,r.id limit 1)
  ) previous;

  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'task_artifact.claimed','task',task_row.id::text,
      jsonb_build_object('agent_run_id',run_row.id,'role',agent_row.slug,'attempt',run_row.attempt_count,
        'prior_artifact_count',jsonb_array_length(prior_results),
        'founder_project_budget_approved',founder_project_budget_approved));
  return jsonb_build_object('run_id',run_row.id,'lease_token',run_row.lease_token,'attempt',run_row.attempt_count,
    'agent',jsonb_build_object('id',agent_row.id,'slug',agent_row.slug,'display_name',agent_row.display_name,
      'responsibilities',agent_row.responsibilities,'permissions',agent_row.permissions,'can_delegate_to',agent_row.can_delegate_to),
    'project',jsonb_build_object('id',project_row.id,'name',project_row.name,'description',project_row.description,
      'status',project_row.status,'founder_project_budget_approved',founder_project_budget_approved,
      'requested_budget',project_row.requested_budget,'currency',project_row.currency),
    'input',run_row.input,'task_artifact',jsonb_build_object('task_id',task_row.id,'role',agent_row.slug,
      'artifact_type',artifact_type,'title',task_row.title,'description',task_row.description,
      'acceptance_criteria',task_row.acceptance_criteria),
    'prior_results',prior_results,'spending_policies',policy_rows,'applicable_budgets',budget_rows);
end
$$;

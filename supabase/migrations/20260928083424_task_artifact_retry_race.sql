-- Keep a failed attempt from blocking a task while a bounded queued/running retry remains.
create or replace function public.sutra_claim_task_agent_run(p_worker_id text)
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
      and not exists (select 1 from public.agent_runs retry
        where retry.task_id=r.task_id and retry.trigger_type='task_artifact' and retry.id<>r.id
          and retry.status in ('queued','running')
          and (retry.attempt_count<3 or retry.lease_expires_at>=now()))
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

-- The race may already have blocked a task that still has a founder-authorized
-- queued retry. Restore only that approved PM task to the worker's claimable
-- state, without creating another run or changing its spending authority.
with recovered as (
  update public.tasks t set status='in_progress',updated_at=now()
  from public.projects p, public.agents a
  where t.project_id=p.id and t.owner_agent_id=a.id and t.assigned_agent_id=a.id
    and a.slug='product_manager' and a.active and p.status in ('approved','active')
    and t.status='blocked'
    and not exists(select 1 from public.task_agent_artifacts x where x.task_id=t.id)
    and exists(select 1 from public.agent_runs r where r.task_id=t.id and r.trigger_type='task_artifact'
      and r.status='queued' and r.attempt_count<3)
  returning t.id
)
insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
select 'system','migration:task_artifact_retry_race','task_artifact.retry_recovered','task',id::text,
  '{"reason":"preserve_founder_authorized_queued_retry","spending_authority_changed":false}'::jsonb
from recovered;

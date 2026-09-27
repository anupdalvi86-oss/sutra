-- Queue only QA/Security tasks whose ancestor Developer work has verified PR+CI evidence.
create index if not exists agent_runs_task_review_queue_idx
  on public.agent_runs(status,lease_expires_at,created_at)
  where trigger_type='task_review';
create unique index if not exists agent_runs_task_review_active_unique
  on public.agent_runs(task_id) where trigger_type='task_review' and status in ('queued','running');

create function public.sutra_claim_task_review_agent_run(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; task_row public.tasks%rowtype;
  agent_row public.agents%rowtype; project_row public.projects%rowtype;
  developer_task_id uuid; developer_sha text; pr_url text; ci_url text;
  task_review_context jsonb; new_run_id uuid; new_lease_token uuid;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode='22023';
  end if;

  -- Close retry-exhausted or unrecoverable runs and block their task explicitly.
  update public.agent_runs set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
    output=coalesce(output,'{}'::jsonb)||jsonb_build_object('failure','review_lease_expired_after_max_attempts')
    where trigger_type='task_review' and status='running' and attempt_count>=3 and lease_expires_at<now();
  for run_row in select r.* from public.agent_runs r
    join public.tasks t on t.id=r.task_id
    where r.trigger_type='task_review' and r.status='failed' and t.status='in_progress'
    order by r.finished_at for update of r,t skip locked
  loop
    perform public.sutra_update_task(run_row.agent_id,run_row.task_id,'blocked',
      jsonb_build_object('failure','review_attempts_exhausted','agent_run_id',run_row.id));
  end loop;

  -- Reclaim a queued retry or an expired lease before claiming new work.
  select r.* into run_row from public.agent_runs r join public.tasks t on t.id=r.task_id
    where r.trigger_type='task_review' and r.attempt_count<3
      and (r.status='queued' or (r.status='running' and r.lease_expires_at<now()))
      and t.status='in_progress'
    order by r.created_at,r.id limit 1 for update of r,t skip locked;
  if found then
    update public.agent_runs r set status='running',attempt_count=r.attempt_count+1,
      started_at=coalesce(r.started_at,now()),finished_at=null,lease_token=gen_random_uuid(),
      lease_expires_at=now()+interval '10 minutes'
      where r.id=run_row.id returning r.* into run_row;
  else
    -- Expand ready tasks into leased, durable review runs in their own transaction.
    with recursive candidate_ancestors(task_id,ancestor_id,depth) as (
      select t.id,t.parent_task_id,1 from public.tasks t join public.agents a on a.id=t.owner_agent_id
        join public.projects p on p.id=t.project_id
        where t.status='ready' and a.active and a.slug in ('qa','security') and p.status in ('approved','active')
      union all
      select c.task_id,parent.parent_task_id,c.depth+1 from candidate_ancestors c
        join public.tasks parent on parent.id=c.ancestor_id
        where parent.parent_task_id is not null and c.depth<8
    ), verified_candidates as (
      select t.id task_id,min(c.depth) developer_depth
      from public.tasks t join candidate_ancestors c on c.task_id=t.id
        join public.tasks developer_task on developer_task.id=c.ancestor_id
        join public.agents developer on developer.id=developer_task.owner_agent_id and developer.slug='developer'
        join public.github_task_dispatches d on d.task_id=developer_task.id
      where developer_task.project_id=t.project_id and developer_task.status='done'
        and d.status='created' and d.pull_request_merged and d.ci_conclusion='success'
        and d.pull_request_head_sha=d.ci_head_sha and d.pull_request_url is not null and d.ci_run_url is not null
        and not exists(select 1 from public.agent_runs r where r.task_id=t.id and r.trigger_type='task_review'
          and r.status in ('queued','running'))
      group by t.id
    )
    select t.* into task_row from verified_candidates v join public.tasks t on t.id=v.task_id
      order by t.created_at,t.id limit 1 for update of t skip locked;
    if not found then return null; end if;

    select a.* into agent_row from public.agents a where a.id=task_row.owner_agent_id and a.active;
    insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,lease_token,lease_expires_at,attempt_count)
      values(agent_row.id,task_row.project_id,task_row.id,'task_review','running',
        jsonb_build_object('task_id',task_row.id,'review_role',agent_row.slug),'{}'::jsonb,
        now(),gen_random_uuid(),now()+interval '10 minutes',1)
      returning * into run_row;
    perform public.sutra_update_task(agent_row.id,task_row.id,'in_progress',
      jsonb_build_object('agent_run_id',run_row.id,'review_role',agent_row.slug));
  end if;

  select * into task_row from public.tasks t where t.id=run_row.task_id;
  select a.* into agent_row from public.agents a where a.id=run_row.agent_id and a.active;
  select p.* into project_row from public.projects p where p.id=run_row.project_id;
  with recursive ancestors(id,parent_task_id,depth) as (
    select t.id,t.parent_task_id,0 from public.tasks t where t.id=task_row.id
    union all select parent.id,parent.parent_task_id,a.depth+1 from ancestors a
      join public.tasks parent on parent.id=a.parent_task_id where a.depth<8
  )
  select developer_task.id,d.pull_request_head_sha,d.pull_request_url,d.ci_run_url
    into developer_task_id,developer_sha,pr_url,ci_url
  from ancestors a join public.tasks developer_task on developer_task.id=a.id
    join public.agents developer on developer.id=developer_task.owner_agent_id and developer.slug='developer'
    join public.github_task_dispatches d on d.task_id=developer_task.id
  where developer_task.status='done' and d.pull_request_merged and d.ci_conclusion='success'
    and d.pull_request_head_sha=d.ci_head_sha order by a.depth limit 1;
  if developer_task_id is null or developer_sha is null then
    raise exception 'review task is missing verified Developer PR and CI evidence' using errcode='23514';
  end if;
  task_review_context:=jsonb_build_object('task_id',task_row.id,'role',agent_row.slug,
    'title',task_row.title,'description',task_row.description,'acceptance_criteria',task_row.acceptance_criteria,
    'developer_task_id',developer_task_id,'tested_commit_sha',developer_sha,
    'pull_request_url',pr_url,'ci_run_url',ci_url);
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'task_review_agent_run.claimed','agent_run',run_row.id::text,
      jsonb_build_object('task_id',task_row.id,'role',agent_row.slug,'attempt',run_row.attempt_count,
        'developer_task_id',developer_task_id,'tested_commit_sha',developer_sha));
  return jsonb_build_object('run_id',run_row.id,'lease_token',run_row.lease_token,'attempt',run_row.attempt_count,
    'agent',jsonb_build_object('id',agent_row.id,'slug',agent_row.slug,'display_name',agent_row.display_name,
      'responsibilities',agent_row.responsibilities),
    'project',jsonb_build_object('id',project_row.id,'name',project_row.name,'description',project_row.description,
      'requested_budget',project_row.requested_budget,'currency',project_row.currency),
    'input',run_row.input,'task_review',task_review_context,'prior_results','[]'::jsonb,
    'spending_policies','[]'::jsonb,'applicable_budgets','[]'::jsonb);
end;
$$;
revoke all on function public.sutra_claim_task_review_agent_run(text) from public,anon,authenticated;
grant execute on function public.sutra_claim_task_review_agent_run(text) to service_role;

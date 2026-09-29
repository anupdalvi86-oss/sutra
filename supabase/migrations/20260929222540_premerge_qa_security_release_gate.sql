-- QA and Security now review the exact open PR head after CI and before merge.
-- GitHub merge authority remains behind a one-time database claim that checks
-- the founder's active repository grant, budget-approved task, CI, QA, Security,
-- and the exact same tested commit.

create or replace function public.sutra_guard_review_task_completion()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare role_slug text; latest_review public.task_review_evidence%rowtype;
begin
  if old.status is distinct from new.status and new.status='done' then
    select a.slug into role_slug from public.agents a where a.id=new.owner_agent_id and a.active;
    if role_slug in ('qa','security') then
      select r.* into latest_review from public.task_review_evidence r
        where r.task_id=new.id and r.reviewer_agent_id=new.owner_agent_id and r.review_role=role_slug
        order by r.created_at desc,r.id desc limit 1;
      if not found or latest_review.result is distinct from 'pass'
        or not exists (
          select 1 from public.github_task_dispatches d
          join public.tasks developer_task on developer_task.id=d.task_id
          where d.task_id=latest_review.developer_task_id and d.status='created'
            and developer_task.status in ('in_progress','done') and d.ci_conclusion='success'
            and d.pull_request_head_sha=latest_review.tested_commit_sha
            and d.ci_head_sha=latest_review.tested_commit_sha
        ) then
        raise exception 'QA/Security completion requires passing review evidence for the current successfully tested Developer commit'
          using errcode='42501';
      end if;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_guard_review_task_completion() from public,anon,authenticated,service_role;

create or replace function public.sutra_submit_task_review(
  p_actor_agent_id uuid,p_task_id uuid,p_evidence jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; role_slug text; developer_task_id uuid;
  dispatch_row public.github_task_dispatches%rowtype; result_value text; review_id uuid;
  criteria_count integer; evidence_criteria_count integer;
begin
  if p_actor_agent_id is null or p_task_id is null or p_evidence is null
    or jsonb_typeof(p_evidence) is distinct from 'object' or octet_length(p_evidence::text)>16000
    or not coalesce(p_evidence->>'result'=any(array['pass','fail']::text[]),false)
    or p_evidence->>'tested_commit_sha' !~ '^[a-fA-F0-9]{40}$'
    or length(trim(coalesce(p_evidence->>'summary',''))) not between 8 and 2000
    or jsonb_typeof(p_evidence->'acceptance_criteria') is distinct from 'array' then
    raise exception 'malformed QA/Security review evidence' using errcode='22023';
  end if;
  select * into task_row from public.tasks t where t.id=p_task_id for update;
  select a.slug into role_slug from public.agents a where a.id=p_actor_agent_id and a.active;
  if task_row.id is null or task_row.status<>'in_progress'
    or task_row.owner_agent_id is distinct from p_actor_agent_id or role_slug is null or role_slug not in ('qa','security') then
    raise exception 'only the active assigned QA or Security agent can review an in-progress task' using errcode='42501';
  end if;

  with recursive parent_chain(id,depth) as (
    select task_row.parent_task_id,1 where task_row.parent_task_id is not null
    union all
    select parent_task.parent_task_id,chain.depth+1
    from public.tasks parent_task join parent_chain chain on parent_task.id=chain.id
    where parent_task.parent_task_id is not null and chain.depth<8
  )
  select t.id into developer_task_id from parent_chain chain
    join public.tasks t on t.id=chain.id and t.project_id=task_row.project_id
    join public.agents a on a.id=t.owner_agent_id and a.slug='developer'
    order by chain.depth limit 1;
  select d.* into dispatch_row from public.github_task_dispatches d
    join public.tasks developer_task on developer_task.id=d.task_id
    where d.task_id=developer_task_id and developer_task.status in ('in_progress','done')
      and d.ci_conclusion='success'
      and d.pull_request_head_sha=d.ci_head_sha and d.pull_request_url is not null and d.ci_run_url is not null;
  if developer_task_id is null or dispatch_row.task_id is null
    or lower(p_evidence->>'tested_commit_sha')<>lower(dispatch_row.pull_request_head_sha) then
    raise exception 'review evidence must reference the current successfully tested Developer PR commit' using errcode='42501';
  end if;

  criteria_count:=jsonb_array_length(task_row.acceptance_criteria);
  evidence_criteria_count:=jsonb_array_length(p_evidence->'acceptance_criteria');
  if evidence_criteria_count not between 1 and 30 or evidence_criteria_count<>criteria_count or exists (
    select 1 from jsonb_array_elements(p_evidence->'acceptance_criteria') entry(value)
    where jsonb_typeof(entry.value) is distinct from 'object'
      or not (task_row.acceptance_criteria @> jsonb_build_array(entry.value->>'criterion'))
      or not coalesce(entry.value->>'result'=any(array['pass','fail']::text[]),false)
      or coalesce(entry.value->>'evidence_url','') !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull/[1-9][0-9]*|actions/runs/[1-9][0-9]*)$'
  ) or (select count(distinct entry.value->>'criterion') from jsonb_array_elements(p_evidence->'acceptance_criteria') entry(value))<>criteria_count then
    raise exception 'each task acceptance criterion needs a distinct, evidenced review result' using errcode='22023';
  end if;

  if role_slug='qa' then
    if jsonb_typeof(p_evidence->'tests') is distinct from 'array' then
      raise exception 'QA evidence requires a test result array' using errcode='22023';
    end if;
    if jsonb_array_length(p_evidence->'tests') not between 1 and 30 then
      raise exception 'QA evidence requires 1 to 30 bounded test results' using errcode='22023';
    end if;
    if exists (select 1 from jsonb_array_elements(p_evidence->'tests') entry(value)
        where jsonb_typeof(entry.value) is distinct from 'object'
          or length(trim(coalesce(entry.value->>'name',''))) not between 1 and 200
          or not coalesce(entry.value->>'result'=any(array['pass','fail','blocked']::text[]),false)
          or coalesce(entry.value->>'evidence_url','') !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull/[1-9][0-9]*|actions/runs/[1-9][0-9]*)$') then
      raise exception 'QA evidence requires bounded named test results and GitHub evidence links' using errcode='22023';
    end if;
    if p_evidence->>'result'='pass' and (
      exists (select 1 from jsonb_array_elements(p_evidence->'tests') entry(value) where entry.value->>'result'<>'pass')
      or exists (select 1 from jsonb_array_elements(p_evidence->'acceptance_criteria') entry(value) where entry.value->>'result'<>'pass')
    ) then raise exception 'QA cannot pass with failed or blocked tests or criteria' using errcode='42501'; end if;
  else
    if jsonb_typeof(p_evidence->'findings') is distinct from 'array'
      or jsonb_typeof(p_evidence->'checks') is distinct from 'array'
      or jsonb_typeof(p_evidence->'release_blockers') is distinct from 'array' then
      raise exception 'Security evidence requires findings, checks, and release blocker arrays' using errcode='22023';
    end if;
    if jsonb_array_length(p_evidence->'findings')>50
      or jsonb_array_length(p_evidence->'checks') not between 1 and 30
      or jsonb_array_length(p_evidence->'release_blockers')>30 then
      raise exception 'Security evidence arrays exceed their bounds' using errcode='22023';
    end if;
    if exists (select 1 from jsonb_array_elements(p_evidence->'checks') entry(value)
        where jsonb_typeof(entry.value) is distinct from 'object'
          or length(trim(coalesce(entry.value->>'name',''))) not between 1 and 200
          or not coalesce(entry.value->>'result'=any(array['pass','fail','blocked']::text[]),false)
          or coalesce(entry.value->>'evidence_url','') !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull/[1-9][0-9]*|actions/runs/[1-9][0-9]*)$')
      or exists (select 1 from jsonb_array_elements(p_evidence->'findings') entry(value)
        where jsonb_typeof(entry.value) is distinct from 'object'
          or not coalesce(entry.value->>'severity'=any(array['critical','high','medium','low','info']::text[]),false)
          or not coalesce(entry.value->>'status'=any(array['open','mitigated','accepted']::text[]),false)
          or length(trim(coalesce(entry.value->>'summary',''))) not between 1 and 1000
          or length(trim(coalesce(entry.value->>'owner',''))) not between 1 and 200
          or length(trim(coalesce(entry.value->>'remediation',''))) not between 1 and 1000) then
      raise exception 'Security evidence requires bounded checks, findings, owners, and remediation' using errcode='22023';
    end if;
    if p_evidence->>'result'='pass' and (
      jsonb_array_length(p_evidence->'release_blockers')>0
      or exists (select 1 from jsonb_array_elements(p_evidence->'checks') entry(value) where entry.value->>'result'<>'pass')
      or exists (select 1 from jsonb_array_elements(p_evidence->'acceptance_criteria') entry(value) where entry.value->>'result'<>'pass')
      or exists (select 1 from jsonb_array_elements(p_evidence->'findings') entry(value)
        where entry.value->>'severity' in ('critical','high') and entry.value->>'status'='open')
    ) then raise exception 'Security cannot pass with release blockers, failed checks, or open critical/high findings' using errcode='42501'; end if;
  end if;

  result_value:=p_evidence->>'result';
  insert into public.task_review_evidence(task_id,reviewer_agent_id,review_role,developer_task_id,
    tested_commit_sha,result,evidence)
    values(p_task_id,p_actor_agent_id,role_slug,developer_task_id,lower(p_evidence->>'tested_commit_sha'),result_value,p_evidence)
    returning id into review_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',role_slug,'task.review_submitted','task',p_task_id::text,
      jsonb_build_object('review_id',review_id,'developer_task_id',developer_task_id,
        'tested_commit_sha',lower(p_evidence->>'tested_commit_sha'),'result',result_value));
  perform public.sutra_update_task(p_actor_agent_id,p_task_id,
    case result_value when 'pass' then 'done' else 'blocked' end,
    jsonb_build_object('review_id',review_id,'review_role',role_slug,'result',result_value,
      'tested_commit_sha',lower(p_evidence->>'tested_commit_sha'),'summary',p_evidence->>'summary'));
  return jsonb_build_object('review_id',review_id,'task_id',p_task_id,'role',role_slug,'result',result_value,
    'status',case result_value when 'pass' then 'done' else 'blocked' end);
end;
$$;
revoke all on function public.sutra_submit_task_review(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_submit_task_review(uuid,uuid,jsonb) to service_role;

create or replace function public.sutra_claim_task_review_agent_run(p_worker_id text)
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
      where developer_task.project_id=t.project_id and developer_task.status in ('in_progress','done')
        and d.status='created' and d.ci_conclusion='success'
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
  where developer_task.status in ('in_progress','done') and d.ci_conclusion='success'
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

-- Any new PR head invalidates old QA/Security/release evidence. A fresh matching
-- successful CI run releases QA; QA then releases Security through the existing
-- parent-task trigger, and Security releases the DevOps plan.
create or replace function public.sutra_prepare_premerge_reviews()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare review_reset boolean:=false; child record;
begin
  if old.pull_request_head_sha is distinct from new.pull_request_head_sha then
    with recursive descendants(id,depth) as (
      select t.id,1 from public.tasks t where t.parent_task_id=new.task_id
      union all select child.id,parent.depth+1 from public.tasks child
        join descendants parent on child.parent_task_id=parent.id where parent.depth<8
    )
    update public.agent_runs r set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
      output=coalesce(r.output,'{}'::jsonb)||jsonb_build_object('failure','developer_commit_changed')
      where r.trigger_type='task_review' and r.status in ('queued','running')
        and r.task_id in (select id from descendants);

  for child in select t.id,a.slug,t.status from public.tasks t
      join public.agents a on a.id=t.owner_agent_id
      where t.parent_task_id=new.task_id and a.slug='qa' and t.status not in ('deferred','cancelled')
      for update of t
    loop
      if child.status is distinct from 'blocked' then
        update public.tasks set status='blocked',updated_at=now() where id=child.id;
        review_reset:=true;
      end if;
      update public.tasks t set status='backlog',updated_at=now()
        from public.agents a where t.owner_agent_id=a.id and t.parent_task_id=child.id
          and a.slug in ('security','devops','cmo','sales')
          and t.status in ('ready','in_progress','done','blocked');
    end loop;
    if review_reset then
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system','sutra','github.review_evidence_invalidated','task',new.task_id::text,
          jsonb_build_object('pull_request_number',new.pull_request_number,
            'new_head_sha',new.pull_request_head_sha,'reason','Developer PR head changed'));
    end if;
  end if;

  if new.status='created' and new.pull_request_number is not null
    and new.pull_request_head_sha is not null and new.ci_head_sha=new.pull_request_head_sha
    and new.ci_conclusion='success' then
    for child in select t.id,t.status from public.tasks t join public.agents a on a.id=t.owner_agent_id
      where t.parent_task_id=new.task_id and a.slug='qa' and t.status in ('backlog','blocked')
      for update of t
    loop
      update public.tasks set status='ready',updated_at=now() where id=child.id;
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system','sutra','github.qa_review_released','task',child.id::text,
          jsonb_build_object('developer_task_id',new.task_id,'pull_request_number',new.pull_request_number,
            'tested_commit_sha',new.pull_request_head_sha,'ci_run_url',new.ci_run_url));
    end loop;
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_prepare_premerge_reviews() from public,anon,authenticated,service_role;
drop trigger if exists github_prepare_premerge_reviews on public.github_task_dispatches;
create trigger github_prepare_premerge_reviews
  after update of pull_request_head_sha,pull_request_merged,ci_conclusion,ci_head_sha on public.github_task_dispatches
  for each row execute function public.sutra_prepare_premerge_reviews();

create table public.code_release_attempts (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  pull_request_number integer not null check (pull_request_number>0),
  head_sha text not null check (head_sha ~ '^[a-f0-9]{40}$'),
  worker_id text not null check (worker_id ~ '^sutra-worker-[a-z0-9]{8,64}$'),
  claim_token uuid not null default gen_random_uuid(),
  status text not null check (status in ('claimed','merged','blocked')),
  attempt_count integer not null default 1 check (attempt_count between 1 and 3),
  lease_expires_at timestamptz not null default now()+interval '10 minutes',
  merge_commit_sha text check (merge_commit_sha is null or merge_commit_sha ~ '^[a-f0-9]{40}$'),
  detail_code text check (detail_code is null or detail_code in ('authorization_revoked','github_merge_conflict','github_permission_denied','github_api_error','github_network_error','github_stale_head','github_closed_unmerged')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(task_id,head_sha),
  check ((status='merged')=(merge_commit_sha is not null))
);
alter table public.code_release_attempts enable row level security;
revoke all on public.code_release_attempts from public,anon,authenticated,service_role;
create index code_release_attempts_claim_idx on public.code_release_attempts(status,lease_expires_at,created_at);

create function public.sutra_claim_ready_code_release(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare dispatch_row public.github_task_dispatches%rowtype; task_row public.tasks%rowtype;
  attempt_row public.code_release_attempts%rowtype; authorization_row public.founder_code_authorizations%rowtype;
  qa_task_id uuid; security_task_id uuid; claim_id uuid; claim_token uuid;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid code release worker identity' using errcode='22023';
  end if;
  select * into authorization_row from public.founder_code_authorizations
    where repository='anupdalvi86-oss/sutra' and active for share;
  if not found or not (authorization_row.capabilities @> array['merge_pull_requests']::text[]) then
    return null;
  end if;

  select d.* into dispatch_row from public.github_task_dispatches d
    join public.tasks t on t.id=d.task_id join public.projects p on p.id=t.project_id
    join public.approvals scope on scope.action_ref=t.id::text and scope.project_id=t.project_id
      and scope.approval_type='developer_scope' and scope.status='approved'
      and scope.decisions #>> '{founder,decision}'='approve'
    where d.status='created' and d.pull_request_number is not null
      and (not d.pull_request_merged or exists(select 1 from public.code_release_attempts recovery
        where recovery.task_id=t.id and recovery.head_sha=d.pull_request_head_sha
          and recovery.status in ('claimed','blocked')))
      and d.pull_request_url is not null and d.ci_conclusion='success'
      and d.pull_request_head_sha=d.ci_head_sha and d.pull_request_head_sha ~ '^[a-f0-9]{40}$'
      and ((not d.pull_request_merged and t.status='in_progress')
        or (d.pull_request_merged and t.status='done'))
      and t.task_type='engineering' and t.owner_agent_id=t.assigned_agent_id
      and p.status in ('approved','active')
      and lower(split_part(d.issue_url,'/',4)||'/'||split_part(d.issue_url,'/',5))=authorization_row.repository
      and exists(select 1 from public.tasks qa join public.agents qa_agent on qa_agent.id=qa.owner_agent_id
        join public.task_review_evidence qae on qae.task_id=qa.id and qae.review_role='qa'
        where qa.parent_task_id=t.id and qa_agent.slug='qa' and qa.status='done'
          and qae.reviewer_agent_id=qa.owner_agent_id and qae.result='pass'
          and qae.developer_task_id=t.id and qae.tested_commit_sha=d.pull_request_head_sha)
      and exists(select 1 from public.tasks qa join public.tasks sec on sec.parent_task_id=qa.id
        join public.agents sec_agent on sec_agent.id=sec.owner_agent_id
        join public.task_review_evidence se on se.task_id=sec.id and se.review_role='security'
        where qa.parent_task_id=t.id and sec_agent.slug='security' and sec.status='done'
          and se.reviewer_agent_id=sec.owner_agent_id and se.result='pass'
          and se.developer_task_id=t.id and se.tested_commit_sha=d.pull_request_head_sha)
      and not exists(select 1 from public.code_release_attempts old
        where old.task_id=t.id and old.head_sha=d.pull_request_head_sha and old.status='merged')
      and not exists(select 1 from public.code_release_attempts active
        where active.task_id=t.id and active.head_sha=d.pull_request_head_sha
          and active.status='claimed' and active.lease_expires_at>=now())
      and not exists(select 1 from public.code_release_attempts exhausted
        where exhausted.task_id=t.id and exhausted.head_sha=d.pull_request_head_sha
          and exhausted.attempt_count>=3 and exhausted.status='blocked')
    order by d.updated_at,t.created_at limit 1 for update of d,t skip locked;
  if not found then return null; end if;

  insert into public.code_release_attempts(task_id,pull_request_number,head_sha,worker_id,status)
    values(dispatch_row.task_id,dispatch_row.pull_request_number,dispatch_row.pull_request_head_sha,
      p_worker_id,'claimed')
    on conflict(task_id,head_sha) do update set worker_id=excluded.worker_id,
      claim_token=gen_random_uuid(),status='claimed',attempt_count=code_release_attempts.attempt_count+1,
      lease_expires_at=now()+interval '10 minutes',detail_code=null,updated_at=now()
      where code_release_attempts.status<>'merged' and code_release_attempts.attempt_count<3
        and (code_release_attempts.status='blocked' or code_release_attempts.lease_expires_at<now())
    returning id,claim_token into claim_id,claim_token;
  if claim_id is null then return null; end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'github.code_release_claimed','task',dispatch_row.task_id::text,
      jsonb_build_object('release_attempt_id',claim_id,'pull_request_number',dispatch_row.pull_request_number,
        'head_sha',dispatch_row.pull_request_head_sha,'attempt',
        (select attempt_count from public.code_release_attempts where id=claim_id)));
  return jsonb_build_object('attempt_id',claim_id,'claim_token',claim_token,'task_id',dispatch_row.task_id,
    'pull_request_number',dispatch_row.pull_request_number,'pull_request_url',dispatch_row.pull_request_url,
    'head_sha',dispatch_row.pull_request_head_sha,'repository',authorization_row.repository);
end;
$$;
revoke all on function public.sutra_claim_ready_code_release(text) from public,anon,authenticated;
grant execute on function public.sutra_claim_ready_code_release(text) to service_role;

create function public.sutra_finish_code_release(
  p_worker_id text,p_attempt_id uuid,p_claim_token uuid,p_status text,
  p_merge_commit_sha text default null,p_detail_code text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare attempt_row public.code_release_attempts%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' or p_attempt_id is null
    or p_claim_token is null or p_status is null or p_status not in ('merged','blocked')
    or (p_status='merged' and (p_merge_commit_sha is null or p_merge_commit_sha !~ '^[a-f0-9]{40}$' or p_detail_code is not null))
    or (p_status='blocked' and (p_detail_code is null or p_detail_code not in ('authorization_revoked','github_merge_conflict','github_permission_denied','github_api_error','github_network_error','github_stale_head','github_closed_unmerged') or p_merge_commit_sha is not null)) then
    raise exception 'malformed code release result' using errcode='22023';
  end if;
  update public.code_release_attempts set status=p_status,merge_commit_sha=p_merge_commit_sha,
    detail_code=p_detail_code,updated_at=now(),lease_expires_at=now()
    where id=p_attempt_id and claim_token=p_claim_token and worker_id=p_worker_id
      and status='claimed' returning * into attempt_row;
  if not found then raise exception 'code release claim is stale or invalid' using errcode='42501'; end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,case when p_status='merged' then 'github.code_release_merged' else 'github.code_release_blocked' end,
      'task',attempt_row.task_id::text,jsonb_build_object('release_attempt_id',attempt_row.id,
        'pull_request_number',attempt_row.pull_request_number,'head_sha',attempt_row.head_sha,
        'merge_commit_sha',attempt_row.merge_commit_sha,'detail_code',attempt_row.detail_code,
        'attempt',attempt_row.attempt_count));
  return jsonb_build_object('attempt_id',attempt_row.id,'status',attempt_row.status,
    'merge_commit_sha',attempt_row.merge_commit_sha,'detail_code',attempt_row.detail_code);
end;
$$;
revoke all on function public.sutra_finish_code_release(text,uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.sutra_finish_code_release(text,uuid,uuid,text,text,text) to service_role;

create function public.sutra_validate_code_release_claim(p_worker_id text,p_attempt_id uuid,p_claim_token uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare attempt_row public.code_release_attempts%rowtype;
begin
  select * into attempt_row from public.code_release_attempts where id=p_attempt_id and claim_token=p_claim_token
    and worker_id=p_worker_id and status='claimed' and lease_expires_at>=now();
  return found and exists(select 1 from public.founder_code_authorizations a
    where a.repository='anupdalvi86-oss/sutra' and a.active
      and a.capabilities @> array['merge_pull_requests']::text[])
    and exists(select 1 from public.code_release_attempts ca
      join public.github_task_dispatches d on d.task_id=ca.task_id
      join public.tasks t on t.id=ca.task_id and t.status in ('in_progress','done')
      join public.projects p on p.id=t.project_id and p.status in ('approved','active')
      join public.approvals scope on scope.action_ref=t.id::text and scope.project_id=t.project_id
        and scope.approval_type='developer_scope' and scope.status='approved'
        and scope.decisions #>> '{founder,decision}'='approve'
      where ca.id=p_attempt_id and ca.claim_token=p_claim_token and ca.worker_id=p_worker_id
        and d.status='created'
        and d.pull_request_number=ca.pull_request_number and d.pull_request_head_sha=ca.head_sha
        and d.ci_conclusion='success' and d.ci_head_sha=ca.head_sha
        and exists(select 1 from public.tasks qa join public.agents qa_agent on qa_agent.id=qa.owner_agent_id
          join public.task_review_evidence qae on qae.task_id=qa.id and qae.review_role='qa'
          where qa.parent_task_id=t.id and qa_agent.slug='qa' and qa.status='done'
            and qae.reviewer_agent_id=qa.owner_agent_id and qae.result='pass'
            and qae.developer_task_id=t.id and qae.tested_commit_sha=ca.head_sha)
        and exists(select 1 from public.tasks qa join public.tasks sec on sec.parent_task_id=qa.id
          join public.agents sec_agent on sec_agent.id=sec.owner_agent_id
          join public.task_review_evidence se on se.task_id=sec.id and se.review_role='security'
          where qa.parent_task_id=t.id and sec_agent.slug='security' and sec.status='done'
            and se.reviewer_agent_id=sec.owner_agent_id and se.result='pass'
            and se.developer_task_id=t.id and se.tested_commit_sha=ca.head_sha));
end;
$$;
revoke all on function public.sutra_validate_code_release_claim(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.sutra_validate_code_release_claim(text,uuid,uuid) to service_role;

create function public.sutra_company_code_release_status()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',release_row.task_id,'task_title',release_row.task_title,
    'pull_request_number',release_row.pull_request_number,'head_sha',release_row.head_sha,
    'status',release_row.status,'attempt_count',release_row.attempt_count,'detail_code',release_row.detail_code,
    'merge_commit_sha',release_row.merge_commit_sha,'updated_at',release_row.updated_at
  ) order by release_row.updated_at desc),'[]'::jsonb)
  from (
    select c.task_id,t.title as task_title,c.pull_request_number,c.head_sha,c.status,
      c.attempt_count,c.detail_code,c.merge_commit_sha,c.updated_at
    from public.code_release_attempts c join public.tasks t on t.id=c.task_id
    order by c.updated_at desc,c.id desc limit 20
  ) release_row
$$;
revoke all on function public.sutra_company_code_release_status() from public,anon,authenticated;
grant execute on function public.sutra_company_code_release_status() to service_role;

-- QA and Security reviews are immutable evidence tied to the verified Developer commit.
create table public.task_review_evidence (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  reviewer_agent_id uuid not null references public.agents(id),
  review_role text not null check (review_role in ('qa','security')),
  developer_task_id uuid not null references public.tasks(id),
  tested_commit_sha text not null check (tested_commit_sha ~ '^[a-f0-9]{40}$'),
  result text not null check (result in ('pass','fail')),
  evidence jsonb not null check (jsonb_typeof(evidence)='object' and octet_length(evidence::text)<=16000),
  created_at timestamptz not null default now()
);
alter table public.task_review_evidence enable row level security;
revoke all on public.task_review_evidence from public,anon,authenticated,service_role;
create index task_review_evidence_latest_idx on public.task_review_evidence(task_id,created_at desc,id desc);

create function public.sutra_guard_review_task_completion()
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
          where d.task_id=latest_review.developer_task_id and d.status='created'
            and d.pull_request_merged and d.ci_conclusion='success'
            and d.pull_request_head_sha=latest_review.tested_commit_sha
            and d.ci_head_sha=latest_review.tested_commit_sha
        ) then
        raise exception 'QA/Security completion requires passing persisted review evidence for the verified Developer commit'
          using errcode='42501';
      end if;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_guard_review_task_completion() from public,anon,authenticated,service_role;
create trigger tasks_require_persisted_review_evidence
  before update of status on public.tasks
  for each row execute function public.sutra_guard_review_task_completion();

create function public.sutra_submit_task_review(
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
    where d.task_id=developer_task_id and developer_task.status='done'
      and d.pull_request_merged and d.ci_conclusion='success'
      and d.pull_request_head_sha=d.ci_head_sha and d.pull_request_url is not null and d.ci_run_url is not null;
  if developer_task_id is null or dispatch_row.task_id is null
    or lower(p_evidence->>'tested_commit_sha')<>lower(dispatch_row.pull_request_head_sha) then
    raise exception 'review evidence must reference the successfully tested, merged Developer commit' using errcode='42501';
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

-- Durable, auditable dispatch of founder-approved Developer tasks to GitHub.
create table public.github_task_dispatches (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null unique references public.tasks(id) on delete cascade,
  status text not null default 'queued' check (status in ('queued','creating','created','failed')),
  attempts integer not null default 0 check (attempts between 0 and 3),
  lease_token uuid,
  lease_expires_at timestamptz,
  issue_number integer,
  issue_url text,
  last_error text check (last_error is null or last_error in (
    'github_api_error','github_network_error','github_rate_limited','malformed_github_response','dispatch_unknown'
  )),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint github_task_dispatch_created_shape check (
    (status = 'created' and issue_number is not null and issue_url is not null
      and lease_token is null and lease_expires_at is null)
    or (status <> 'created' and issue_number is null and issue_url is null)
  ),
  constraint github_task_dispatch_lease_shape check (
    (status='creating' and lease_token is not null and lease_expires_at is not null)
    or (status<>'creating' and lease_token is null and lease_expires_at is null)
  ),
  constraint github_task_dispatch_issue_url check (
    issue_url is null or issue_url ~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$'
  )
);

alter table public.github_task_dispatches enable row level security;
revoke all on public.github_task_dispatches from public, anon, authenticated, service_role;

create index github_task_dispatch_queue_idx on public.github_task_dispatches(status, lease_expires_at, created_at);
create unique index github_task_dispatch_issue_number_unique on public.github_task_dispatches(issue_number)
  where issue_number is not null;

create function public.sutra_claim_github_task(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; dispatch_id uuid; lease uuid; attempts_now integer;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-github-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid GitHub dispatcher identity' using errcode='22023';
  end if;

  with expired as (
    update public.github_task_dispatches set status='failed',lease_token=null,lease_expires_at=null,
      last_error='dispatch_unknown',updated_at=now()
    where status='creating' and lease_expires_at < now() and attempts >= 3
    returning task_id,id,attempts
  )
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  select 'system',p_worker_id,'github.task_dispatch_exhausted','task',e.task_id::text,
    jsonb_build_object('dispatch_id',e.id,'attempt',e.attempts,'error_code','dispatch_unknown') from expired e;

  select t.* into task_row
  from public.tasks t
  join public.agents a on a.id=t.assigned_agent_id and a.active and a.slug='developer'
  join public.projects p on p.id=t.project_id and p.status in ('approved','active')
  left join public.github_task_dispatches d on d.task_id=t.id
  where t.task_type='engineering' and t.status='ready'
    and (d.id is null or d.status='queued' or (d.status='failed' and d.attempts < 3)
      or (d.status='creating' and d.lease_expires_at < now() and d.attempts < 3))
  order by t.created_at,t.id
  limit 1 for update of t skip locked;
  if not found then return null; end if;

  lease := gen_random_uuid();
  insert into public.github_task_dispatches(task_id,status,attempts,lease_token,lease_expires_at,updated_at)
  values(task_row.id,'creating',1,lease,now()+interval '3 minutes',now())
  on conflict(task_id) do update set status='creating',attempts=github_task_dispatches.attempts+1,
    lease_token=excluded.lease_token,lease_expires_at=excluded.lease_expires_at,
    issue_number=null,issue_url=null,last_error=null,updated_at=now()
  returning id,attempts into dispatch_id,attempts_now;

  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  values('system',p_worker_id,'github.task_dispatch_claimed','task',task_row.id::text,
    jsonb_build_object('dispatch_id',dispatch_id,'attempt',attempts_now));

  return jsonb_build_object('dispatch_id',dispatch_id,'task_id',task_row.id,'lease_token',lease,
    'attempt',attempts_now,'title',task_row.title,'description',task_row.description,
    'acceptance_criteria',task_row.acceptance_criteria,'project_id',task_row.project_id,
    'objective_id',task_row.objective_id);
end $$;

create function public.sutra_complete_github_task_dispatch(
  p_worker_id text,p_task_id uuid,p_lease_token uuid,p_issue_number integer,p_issue_url text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare dispatch_row public.github_task_dispatches%rowtype; task_row public.tasks%rowtype;
  project_state text; task_status text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-github-worker-[a-z0-9]{8,64}$'
    or p_task_id is null or p_lease_token is null or p_issue_number is null or p_issue_number < 1
    or p_issue_url is null or p_issue_url !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$'
    or split_part(p_issue_url,'/',7) <> p_issue_number::text then
    raise exception 'malformed GitHub task dispatch completion' using errcode='22023';
  end if;
  select * into dispatch_row from public.github_task_dispatches d
    where d.task_id=p_task_id and d.status='creating' and d.lease_token=p_lease_token for update;
  if not found or dispatch_row.lease_expires_at < now() then
    raise exception 'GitHub task dispatch lease is invalid or expired' using errcode='42501';
  end if;
  select * into task_row from public.tasks t where t.id=p_task_id for update;
  if not found then raise exception 'dispatched task no longer exists' using errcode='42501'; end if;
  select p.status into project_state from public.projects p where p.id=task_row.project_id;
  task_status := case when task_row.status='ready' and project_state in ('approved','active') and exists (
    select 1 from public.agents a where a.id=task_row.assigned_agent_id and a.active and a.slug='developer'
  ) then 'in_progress' else task_row.status end;
  update public.github_task_dispatches set status='created',issue_number=p_issue_number,issue_url=p_issue_url,
    lease_token=null,lease_expires_at=null,last_error=null,updated_at=now() where id=dispatch_row.id;
  update public.tasks set status=task_status,updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  values('system',p_worker_id,case when task_status='in_progress' then 'github.issue_created' else 'github.issue_linked' end,
    'task',p_task_id::text,jsonb_build_object('dispatch_id',dispatch_row.id,'issue_number',p_issue_number,
      'issue_url',p_issue_url,'project_status',project_state));
  return jsonb_build_object('task_id',p_task_id,'status',task_status,'issue_number',p_issue_number,'issue_url',p_issue_url);
end $$;

create function public.sutra_fail_github_task_dispatch(
  p_worker_id text,p_task_id uuid,p_lease_token uuid,p_error_code text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare dispatch_row public.github_task_dispatches%rowtype; next_status text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-github-worker-[a-z0-9]{8,64}$'
    or p_task_id is null or p_lease_token is null
    or p_error_code is null or p_error_code not in ('github_api_error','github_network_error',
      'github_rate_limited','malformed_github_response','dispatch_unknown') then
    raise exception 'malformed GitHub task dispatch failure' using errcode='22023';
  end if;
  select * into dispatch_row from public.github_task_dispatches d
    where d.task_id=p_task_id and d.status='creating' and d.lease_token=p_lease_token for update;
  if not found or dispatch_row.lease_expires_at < now() then
    raise exception 'GitHub task dispatch lease is invalid or expired' using errcode='42501';
  end if;
  next_status := case when dispatch_row.attempts >= 3 then 'failed' else 'queued' end;
  update public.github_task_dispatches set status=next_status,lease_token=null,lease_expires_at=null,
    last_error=p_error_code,updated_at=now() where id=dispatch_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  values('system',p_worker_id,'github.task_dispatch_failed','task',p_task_id::text,
    jsonb_build_object('dispatch_id',dispatch_row.id,'attempt',dispatch_row.attempts,
      'error_code',p_error_code,'retryable',next_status='queued'));
  return jsonb_build_object('task_id',p_task_id,'status',next_status,'error_code',p_error_code);
end $$;

revoke all on function public.sutra_claim_github_task(text) from public,anon,authenticated;
revoke all on function public.sutra_complete_github_task_dispatch(text,uuid,uuid,integer,text) from public,anon,authenticated;
revoke all on function public.sutra_fail_github_task_dispatch(text,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_claim_github_task(text) to service_role;
grant execute on function public.sutra_complete_github_task_dispatch(text,uuid,uuid,integer,text) to service_role;
grant execute on function public.sutra_fail_github_task_dispatch(text,uuid,uuid,text) to service_role;

-- Permit a bounded, explicitly founder-approved retry after GitHub's issue-write
-- permission has been corrected. Every new retry cycle remains auditable.
alter table public.github_task_dispatches
  add column founder_retry_count smallint not null default 0
    check (founder_retry_count between 0 and 3);

create or replace function public.sutra_founder_retry_github_task_dispatch(
  p_founder_telegram_user_id text,
  p_task_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  founder_id text;
  task_row public.tasks%rowtype;
  dispatch_row public.github_task_dispatches%rowtype;
  project_status text;
  retry_number smallint;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
     or p_task_id is null then
    raise exception 'malformed GitHub dispatch retry request' using errcode = '22023';
  end if;

  select value #>> '{}' into founder_id
    from public.company_settings
    where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id = '' or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the configured founder can retry a GitHub dispatch' using errcode = '42501';
  end if;

  -- Keep the same task-before-dispatch lock order used by the dispatcher claim RPC.
  select * into task_row from public.tasks where id = p_task_id for update;
  if not found or task_row.task_type <> 'engineering' or task_row.status <> 'ready'
     or not exists (
       select 1 from public.agents a
       where a.id = task_row.assigned_agent_id and a.active and a.slug = 'developer'
     ) then
    raise exception 'retry requires the same ready Developer task' using errcode = '42501';
  end if;

  select p.status into project_status
    from public.projects p where p.id = task_row.project_id;
  if project_status not in ('approved', 'active')
     or not exists (
       select 1 from public.approvals ap
       where ap.project_id = task_row.project_id
         and ap.approval_type = 'developer_scope'
         and ap.action_ref = task_row.id::text
         and ap.status = 'approved'
     ) then
    raise exception 'retry requires the existing approved project and Developer scope' using errcode = '42501';
  end if;

  select * into dispatch_row
    from public.github_task_dispatches
    where task_id = task_row.id
    for update;
  if not found or dispatch_row.status <> 'failed'
     or dispatch_row.attempts <> 3
     or dispatch_row.last_error <> 'github_permission_denied'
     or dispatch_row.issue_number is not null
     or dispatch_row.pull_request_number is not null then
    raise exception 'retry requires an exhausted permission-denied dispatch with no issue or pull request' using errcode = '42501';
  end if;
  if dispatch_row.founder_retry_count >= 3 then
    raise exception 'founder dispatch retry limit reached' using errcode = '42501';
  end if;

  retry_number := dispatch_row.founder_retry_count + 1;
  update public.github_task_dispatches
    set status = 'queued', attempts = 0, founder_retry_count = retry_number,
        lease_token = null, lease_expires_at = null, last_error = null, updated_at = now()
    where id = dispatch_row.id;

  insert into public.audit_log(actor_type, actor_id, action, resource_type, resource_id, details)
    values ('founder', founder_id, 'founder.github_dispatch_retry_requested', 'task', task_row.id::text,
      jsonb_build_object(
        'dispatch_id', dispatch_row.id,
        'founder_retry_number', retry_number,
        'previous_attempts', dispatch_row.attempts,
        'previous_error_code', dispatch_row.last_error,
        'project_id', task_row.project_id,
        'scope_approval_required', true,
        'spending_authorized', false,
        'merge_or_release_authorized', false
      ));

  return jsonb_build_object(
    'task_id', task_row.id,
    'dispatch_id', dispatch_row.id,
    'status', 'queued',
    'founder_retry_number', retry_number,
    'founder_retries_remaining', 3 - retry_number,
    'spending_authorized', false,
    'merge_or_release_authorized', false
  );
end;
$$;

revoke all on function public.sutra_founder_retry_github_task_dispatch(text, uuid) from public, anon, authenticated;
grant execute on function public.sutra_founder_retry_github_task_dispatch(text, uuid) to service_role;

create or replace function public.sutra_company_github_dispatch_status()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object('dispatches', coalesce(jsonb_agg(
    jsonb_build_object(
      'task_id',recent.task_id,
      'task_title',recent.task_title,
      'status',recent.status,
      'attempts',recent.attempts,
      'founder_retry_count',recent.founder_retry_count,
      'last_error',recent.last_error,
      'issue_number',recent.issue_number,
      'pull_request_number',recent.pull_request_number,
      'ci_conclusion',recent.ci_conclusion,
      'updated_at',recent.updated_at
    ) order by recent.updated_at desc
  ),'[]'::jsonb))
  from (
    select d.task_id,t.title as task_title,d.status,d.attempts,d.founder_retry_count,
      d.last_error,d.issue_number,d.pull_request_number,d.ci_conclusion,d.updated_at
    from public.github_task_dispatches d
    join public.tasks t on t.id=d.task_id
    where d.status in ('creating','failed')
       or (d.pull_request_number is not null and d.ci_conclusion is not null)
    order by d.updated_at desc
    limit 20
  ) recent
$$;

revoke all on function public.sutra_company_github_dispatch_status() from public,anon,authenticated;
grant execute on function public.sutra_company_github_dispatch_status() to service_role;

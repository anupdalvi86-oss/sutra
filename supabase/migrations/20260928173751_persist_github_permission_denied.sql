alter table public.github_task_dispatches
  drop constraint github_task_dispatches_last_error_check;

alter table public.github_task_dispatches
  add constraint github_task_dispatches_last_error_check check (
    last_error is null or last_error in (
      'github_api_error',
      'github_permission_denied',
      'github_network_error',
      'github_rate_limited',
      'malformed_github_response',
      'dispatch_unknown'
    )
  );

create or replace function public.sutra_fail_github_task_dispatch(
  p_worker_id text,p_task_id uuid,p_lease_token uuid,p_error_code text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare dispatch_row public.github_task_dispatches%rowtype; next_status text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-github-worker-[a-z0-9]{8,64}$'
    or p_task_id is null or p_lease_token is null
    or p_error_code is null or p_error_code not in ('github_api_error','github_permission_denied',
      'github_network_error','github_rate_limited','malformed_github_response','dispatch_unknown') then
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

revoke all on function public.sutra_fail_github_task_dispatch(text,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_fail_github_task_dispatch(text,uuid,uuid,text) to service_role;

create or replace function public.sutra_company_github_dispatch_status()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object('dispatches', coalesce(jsonb_agg(
    jsonb_build_object(
      'task_id',recent.task_id,
      'task_title',recent.task_title,
      'status',recent.status,
      'attempts',recent.attempts,
      'last_error',recent.last_error,
      'issue_number',recent.issue_number,
      'pull_request_number',recent.pull_request_number,
      'ci_conclusion',recent.ci_conclusion,
      'updated_at',recent.updated_at
    ) order by recent.updated_at desc
  ),'[]'::jsonb))
  from (
    select d.task_id,t.title as task_title,d.status,d.attempts,d.last_error,d.issue_number,
      d.pull_request_number,d.ci_conclusion,d.updated_at
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

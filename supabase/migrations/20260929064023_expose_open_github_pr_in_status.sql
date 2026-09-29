-- Include linked pull requests even while Sutra is waiting for CI evidence.
-- The service role reads this bounded projection; clients cannot execute it.
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
      'pull_request_url',recent.pull_request_url,
      'pull_request_head_sha',recent.pull_request_head_sha,
      'pull_request_merged',recent.pull_request_merged,
      'ci_conclusion',recent.ci_conclusion,
      'ci_run_url',recent.ci_run_url,
      'ci_head_sha',recent.ci_head_sha,
      'updated_at',recent.updated_at
    ) order by recent.updated_at desc
  ),'[]'::jsonb))
  from (
    select d.task_id,t.title as task_title,d.status,d.attempts,d.founder_retry_count,
      d.last_error,d.issue_number,d.pull_request_number,d.pull_request_url,
      d.pull_request_head_sha,d.pull_request_merged,d.ci_conclusion,d.ci_run_url,
      d.ci_head_sha,d.updated_at
    from public.github_task_dispatches d
    join public.tasks t on t.id=d.task_id
    where d.status in ('creating','failed') or d.pull_request_number is not null
    order by d.updated_at desc
    limit 20
  ) recent
$$;

revoke all on function public.sutra_company_github_dispatch_status() from public,anon,authenticated;
grant execute on function public.sutra_company_github_dispatch_status() to service_role;

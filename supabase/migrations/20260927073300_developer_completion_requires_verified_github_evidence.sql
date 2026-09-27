-- Enforce the PR/CI gate for every task status update path, not just webhooks.
create function public.sutra_guard_developer_task_completion()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if old.status is distinct from new.status and new.status='done'
    and exists (select 1 from public.agents a where a.id=new.owner_agent_id and a.slug='developer')
    and not exists (
      select 1 from public.github_task_dispatches d
      where d.task_id=new.id and d.status='created'
        and d.pull_request_merged and d.ci_conclusion='success'
        and d.pull_request_head_sha is not null
        and d.ci_head_sha=d.pull_request_head_sha
        and d.pull_request_url is not null and d.ci_run_url is not null
    ) then
    raise exception 'Developer completion requires a merged pull request and successful CI on the same commit'
      using errcode='42501';
  end if;
  return new;
end;
$$;

revoke all on function public.sutra_guard_developer_task_completion() from public,anon,authenticated,service_role;
create trigger tasks_require_verified_github_for_developer_completion
  before update of status on public.tasks
  for each row execute function public.sutra_guard_developer_task_completion();

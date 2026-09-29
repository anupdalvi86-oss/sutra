-- Keep a project in sync with a terminal role rejection of its budget request.
-- Founder decisions already synchronize project state; this covers CFO/CEO
-- reviews that reject the request before it reaches the founder gate.
create or replace function public.sutra_sync_rejected_project_budget_status()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if old.status is distinct from new.status
     and new.status = 'rejected'
     and new.approval_type = 'project_budget'
     and new.project_id is not null
     and new.decided_by like 'role:%' then
    update public.projects
       set status = 'rejected', updated_at = now()
     where id = new.project_id and status = 'proposed';

    if found then
      insert into public.audit_log(actor_type, actor_id, action, resource_type, resource_id, details)
      values ('system', 'sutra', 'project.rejected_by_role_review', 'project', new.project_id::text,
        jsonb_build_object('approval_id', new.id, 'decided_by', new.decided_by));

      with cancelled as (
        update public.tasks t set status='cancelled', updated_at=now()
         where t.project_id=new.project_id and t.status in ('backlog','ready','blocked')
           and not exists (select 1 from public.agent_runs r where r.task_id=t.id)
           and not exists (select 1 from public.agent_run_spend_reservations s
                            join public.agent_runs r on r.id=s.agent_run_id where r.task_id=t.id)
        returning t.id
      )
      insert into public.audit_log(actor_type, actor_id, action, resource_type, resource_id, details)
      select 'system','sutra','task.cancelled_with_rejected_project','task',id::text,
             jsonb_build_object('project_id',new.project_id,'approval_id',new.id)
        from cancelled;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.sutra_sync_rejected_project_budget_status() from public, anon, authenticated, service_role;

drop trigger if exists sync_rejected_project_budget_status on public.approvals;
create trigger sync_rejected_project_budget_status
after update of status on public.approvals
for each row execute function public.sutra_sync_rejected_project_budget_status();

-- Repair stale project rows left proposed by role rejections before this trigger
-- existed. Preserve approval decisions and financial records exactly as recorded.
with latest_rejection as (
  select distinct on (a.project_id) a.project_id, a.id as approval_id, a.decided_by
    from public.approvals a
   where a.approval_type = 'project_budget'
     and a.status = 'rejected'
     and a.decided_by like 'role:%'
     and a.project_id is not null
   order by a.project_id, a.decided_at desc nulls last, a.created_at desc
), repaired as (
  update public.projects p
     set status = 'rejected', updated_at = now()
    from latest_rejection r
   where p.id = r.project_id and p.status = 'proposed'
  returning p.id, r.approval_id, r.decided_by
)
insert into public.audit_log(actor_type, actor_id, action, resource_type, resource_id, details)
select 'system', 'sutra', 'project.rejected_by_role_review', 'project', id::text,
       jsonb_build_object('approval_id', approval_id, 'decided_by', decided_by, 'repaired_stale_state', true)
  from repaired;

with rejected_projects as (
  select distinct on (a.project_id) a.project_id, a.id as approval_id
    from public.approvals a
    join public.projects p on p.id=a.project_id
   where a.approval_type='project_budget' and a.status='rejected'
     and a.decided_by like 'role:%' and p.status='rejected'
   order by a.project_id,a.decided_at desc nulls last,a.created_at desc
), cancelled as (
  update public.tasks t set status='cancelled',updated_at=now()
   from rejected_projects p
   where t.project_id=p.project_id and t.status in ('backlog','ready','blocked')
     and not exists (select 1 from public.agent_runs r where r.task_id=t.id)
     and not exists (select 1 from public.agent_run_spend_reservations s
                      join public.agent_runs r on r.id=s.agent_run_id where r.task_id=t.id)
  returning t.id,t.project_id
)
insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
select 'system','sutra','task.cancelled_with_rejected_project','task',c.id::text,
       jsonb_build_object('project_id',c.project_id)
  from cancelled c;

-- Allow one founder-authorized recovery cycle for the existing approved Sales
-- handoff after a terminal schema-validation failure. The worker's ordinary
-- per-run three-attempt limit and all spend gates remain in force.
create or replace function public.sutra_founder_retry_sales_task_artifact(
  p_founder_telegram_user_id text,
  p_task_id uuid
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  founder_id text;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  failed_run public.agent_runs%rowtype;
  reservation_count integer;
  reservations_reconciled boolean;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_task_id is null then
    raise exception 'malformed Sales task retry request' using errcode='22023';
  end if;

  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can retry a Sales task' using errcode='42501';
  end if;

  select * into task_row from public.tasks t where t.id=p_task_id for update;
  if not found or task_row.status<>'blocked' or task_row.project_id is null then
    raise exception 'Sales retry requires an existing blocked project task' using errcode='42501';
  end if;
  if not exists(select 1 from public.agents a where a.id=task_row.owner_agent_id
      and a.id=task_row.assigned_agent_id and a.slug='sales' and a.active) then
    raise exception 'only the assigned Sales task may use this retry' using errcode='42501';
  end if;
  if exists(select 1 from public.task_agent_artifacts x where x.task_id=p_task_id) then
    raise exception 'Sales tasks with an artifact cannot be retried' using errcode='42501';
  end if;
  if exists(select 1 from public.agent_runs r where r.task_id=p_task_id
      and r.trigger_type='task_artifact' and r.status in ('queued','running')) then
    raise exception 'Sales retry cannot replace an active artifact run' using errcode='42501';
  end if;

  select * into project_row from public.projects p where p.id=task_row.project_id for update;
  if project_row.status not in ('approved','active') or not exists(
      select 1 from public.approvals a where a.project_id=task_row.project_id
        and a.approval_type='project_budget' and a.status='approved'
        and a.decisions #>> '{founder,decision}'='approve') then
    raise exception 'Sales retry requires the same founder-approved project' using errcode='42501';
  end if;

  if exists(select 1 from public.audit_log l where l.actor_type='founder'
      and l.action='founder.sales_task_artifact_retry_requested'
      and l.resource_type='task' and l.resource_id=p_task_id::text) then
    raise exception 'the one-time Sales recovery has already been used' using errcode='42501';
  end if;

  select * into failed_run from public.agent_runs r
    where r.task_id=p_task_id and r.trigger_type='task_artifact' and r.status='failed'
      and r.attempt_count=3 and r.lease_token is null and r.lease_expires_at is null
      and r.output->>'error_code'='invalid_agent_output'
      and r.output->>'failure_detail_code'='invalid_artifact_schema'
    order by r.finished_at desc nulls last limit 1 for update;
  if not found then
    raise exception 'Sales retry requires three terminal attempts ending in artifact-schema validation failure' using errcode='42501';
  end if;

  select count(*),coalesce(bool_and(s.status='reconciled'),false)
    into reservation_count,reservations_reconciled
    from public.agent_run_spend_reservations s where s.agent_run_id=failed_run.id;
  if reservation_count<>3 or not reservations_reconciled then
    raise exception 'Sales retry requires all prior attempt reservations reconciled' using errcode='42501';
  end if;

  update public.tasks set status='ready',updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.sales_task_artifact_retry_requested','task',p_task_id::text,
      jsonb_build_object('project_id',task_row.project_id,'failed_run_id',failed_run.id,
        'prior_attempt_count',failed_run.attempt_count,
        'prior_failure_detail_code',failed_run.output->>'failure_detail_code',
        'prior_reservations_reconciled',true,'one_time_recovery',true,
        'project_spending_authorized',false,'merge_authority_granted',false,
        'release_authority_granted',false));
  return jsonb_build_object('task_id',p_task_id,'status','ready','prior_attempt_count',3,
    'preserved_unknown_reservations',true,'project_spending_authorized',false,
    'merge_authority_granted',false,'release_authority_granted',false);
end;
$$;

revoke all on function public.sutra_founder_retry_sales_task_artifact(text,uuid)
  from public,anon,authenticated;
grant execute on function public.sutra_founder_retry_sales_task_artifact(text,uuid)
  to service_role;

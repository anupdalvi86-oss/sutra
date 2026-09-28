-- Permit one founder-audited, capped retry after a terminal unknown-usage result, only when no run remains active.
create or replace function public.sutra_founder_retry_product_task_artifact(
  p_founder_telegram_user_id text,
  p_task_id uuid
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  founder_id text;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  approval_row public.approvals%rowtype;
  failed_run public.agent_runs%rowtype;
  artifact_run_count integer;
  unknown_reservation_count integer;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_task_id is null then
    raise exception 'malformed product task retry request' using errcode = '22023';
  end if;

  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the founder can retry a product task' using errcode = '42501';
  end if;

  select * into task_row from public.tasks t where t.id=p_task_id for update;
  if not found or task_row.project_id is null or task_row.status not in ('blocked','in_progress') then
    raise exception 'product task retry requires an existing recoverable project task' using errcode = '42501';
  end if;
  if exists (select 1 from public.agent_runs r where r.task_id=p_task_id
      and r.trigger_type='task_artifact' and r.status in ('queued','running')) then
    raise exception 'product task retry cannot replace an active artifact run' using errcode = '42501';
  end if;

  select * into project_row from public.projects p where p.id=task_row.project_id for update;
  if project_row.status not in ('approved','active') then
    raise exception 'product task retry requires an approved project' using errcode = '42501';
  end if;

  select * into approval_row from public.approvals a
    where a.project_id=task_row.project_id and a.approval_type='project_budget'
      and a.status='approved' and a.decisions #>> '{founder,decision}'='approve'
    order by a.decided_at desc nulls last limit 1;
  if not found then
    raise exception 'product task retry requires recorded founder project approval' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.agents a where a.id=task_row.owner_agent_id
      and a.id=task_row.assigned_agent_id and a.slug='product_manager' and a.active
  ) then
    raise exception 'only an assigned Product Manager task may use this retry' using errcode = '42501';
  end if;
  if exists (select 1 from public.task_agent_artifacts x where x.task_id=p_task_id) then
    raise exception 'completed product tasks cannot be retried' using errcode = '42501';
  end if;

  select * into failed_run from public.agent_runs r
    where r.task_id=p_task_id and r.trigger_type='task_artifact' and r.status='failed'
      and ((r.output->>'error_code'='unknown_spend' and r.output->>'failure_detail_code' is null)
        or (r.output->>'error_code' in ('unknown_or_overrun_spend','unknown_spend','invalid_agent_output')
          and r.output->>'failure_detail_code' in ('invalid_evidence','invalid_artifact_schema','invalid_agent_output')))
      and r.lease_token is null and r.lease_expires_at is null
    order by r.finished_at desc nulls last limit 1 for update;
  if not found then
    raise exception 'product task retry requires a recognized terminal artifact failure' using errcode = '42501';
  end if;
  if failed_run.output->>'error_code'='unknown_spend' and not exists (
    select 1 from public.agent_run_spend_reservations s
    where s.agent_run_id=failed_run.id and s.status='unknown'
  ) then
    raise exception 'unknown usage must remain reserved before retry' using errcode = '42501';
  end if;

  select count(*) into artifact_run_count from public.agent_runs r
    where r.task_id=p_task_id and r.trigger_type='task_artifact';
  if artifact_run_count >= 3 then
    raise exception 'product task retry limit has been reached' using errcode = '42501';
  end if;
  select count(*) into unknown_reservation_count from public.agent_run_spend_reservations s
    where s.agent_run_id=failed_run.id and s.status in ('unknown','overrun');

  update public.tasks set status='ready',updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.product_task_retry_requested','task',p_task_id::text,
      jsonb_build_object('project_id',task_row.project_id,'failed_run_id',failed_run.id,
        'previous_error_code',failed_run.output->>'error_code',
        'previous_failure_detail_code',failed_run.output->>'failure_detail_code',
        'artifact_runs_before_retry',artifact_run_count,
        'unknown_reservations_preserved',true,
        'unknown_reservation_count',unknown_reservation_count,
        'project_spending_authorized',false,'task_status_before_retry',task_row.status));
  return jsonb_build_object('task_id',p_task_id,'status','ready',
    'attempts_remaining',3-artifact_run_count,
    'preserved_unknown_reservations',unknown_reservation_count,
    'project_spending_authorized',false);
end;
$$;

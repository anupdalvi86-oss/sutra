-- Let the founder retry the same approved CPO research task after its terminal
-- malformed response, while preserving unknown usage and using normal spend gates.
create or replace function public.sutra_founder_retry_cpo_research_task(
  p_founder_telegram_user_id text,
  p_task_id uuid
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  founder_id text;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  failed_run public.agent_runs%rowtype;
  artifact_run_count integer;
  retry_request_count integer;
  preserved_reservation_count integer;
begin
  if p_founder_telegram_user_id is null
    or length(p_founder_telegram_user_id) not between 1 and 64
    or p_task_id is null then
    raise exception 'malformed CPO research retry request' using errcode='22023';
  end if;

  select value #>> '{}' into founder_id
  from public.company_settings where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the founder can retry CPO research' using errcode='42501';
  end if;

  select * into task_row from public.tasks where id=p_task_id for update;
  if not found or task_row.status<>'blocked' or task_row.project_id is null
    or task_row.task_type<>'research' then
    raise exception 'CPO retry requires the same blocked research task' using errcode='42501';
  end if;
  if not exists(select 1 from public.agents a
    where a.id=task_row.owner_agent_id and a.id=task_row.assigned_agent_id
      and a.slug='cpo' and a.active) then
    raise exception 'only an assigned active CPO research task can be retried' using errcode='42501';
  end if;
  if exists(select 1 from public.task_agent_artifacts x where x.task_id=p_task_id) then
    raise exception 'completed CPO research cannot be retried' using errcode='42501';
  end if;
  if exists(select 1 from public.agent_runs r where r.task_id=p_task_id
      and r.trigger_type='task_artifact' and r.status in ('queued','running')) then
    raise exception 'CPO research already has an active artifact run' using errcode='42501';
  end if;

  select * into project_row from public.projects where id=task_row.project_id for update;
  if project_row.status not in ('approved','active') then
    raise exception 'CPO retry requires the already approved project' using errcode='42501';
  end if;
  if not exists(select 1 from public.approvals a where a.project_id=task_row.project_id
      and a.approval_type='project_budget' and a.status='approved'
      and a.decisions #>> '{founder,decision}'='approve') then
    raise exception 'CPO retry requires recorded founder project approval' using errcode='42501';
  end if;
  if not exists(select 1 from public.agent_model_spend_profiles p
      where p.provider='openai' and p.model='gpt-6-luna' and p.active) then
    raise exception 'CPO retry model has no active database spend profile' using errcode='42501';
  end if;

  select * into failed_run from public.agent_runs r
  where r.task_id=p_task_id and r.trigger_type='task_artifact' and r.status='failed'
    and r.output->>'error_code'='unknown_or_overrun_spend'
    and r.output->>'failure_detail_code'='malformed_json'
    and r.finished_at is not null and r.lease_token is null and r.lease_expires_at is null
  order by r.finished_at desc limit 1 for update;
  if not found then
    raise exception 'CPO retry requires the terminal malformed-response failure' using errcode='42501';
  end if;
  if not exists(select 1 from public.agent_run_spend_reservations s
      where s.agent_run_id=failed_run.id and s.status in ('unknown','overrun')) then
    raise exception 'prior unknown usage must remain reserved before retry' using errcode='42501';
  end if;

  select count(*) into artifact_run_count from public.agent_runs r
    where r.task_id=p_task_id and r.trigger_type='task_artifact';
  select count(*) into retry_request_count from public.audit_log l
    where l.actor_type='founder' and l.action='founder.cpo_research_task_retry_requested'
      and l.resource_type='task' and l.resource_id=p_task_id::text;
  if greatest(artifact_run_count,retry_request_count+1)>=3 then
    raise exception 'CPO research retry limit of three total runs has been reached' using errcode='42501';
  end if;

  select count(*) into preserved_reservation_count from public.agent_run_spend_reservations s
    where s.agent_run_id=failed_run.id and s.status in ('unknown','overrun');
  update public.tasks set status='ready',updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.cpo_research_task_retry_requested','task',p_task_id::text,
      jsonb_build_object('project_id',task_row.project_id,'failed_run_id',failed_run.id,
        'previous_error_code',failed_run.output->>'error_code',
        'previous_failure_detail_code',failed_run.output->>'failure_detail_code',
        'artifact_runs_before_retry',artifact_run_count,
        'retry_requests_before_retry',retry_request_count,
        'unknown_reservations_preserved',true,
        'unknown_reservation_count',preserved_reservation_count,
        'provider','openai','model','gpt-6-luna',
        'project_spending_authorized',false,'task_status_before_retry',task_row.status));
  return jsonb_build_object('task_id',p_task_id,'status','ready',
    'attempts_remaining',3-greatest(artifact_run_count,retry_request_count+1),
    'preserved_unknown_reservations',preserved_reservation_count,
    'provider','openai','model','gpt-6-luna',
    'project_spending_authorized',false);
end;
$$;

revoke all on function public.sutra_founder_retry_cpo_research_task(text,uuid)
  from public,anon,authenticated;
grant execute on function public.sutra_founder_retry_cpo_research_task(text,uuid)
  to service_role;

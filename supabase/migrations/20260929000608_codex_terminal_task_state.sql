-- Terminal Codex failures are task blockers. Only the existing founder-approved
-- zero-request retry path can reopen the same task, after a fresh spend reservation.

create or replace function public.sutra_codex_finish_run(
  p_worker_id text,
  p_run_id uuid,
  p_lease_token uuid,
  p_usage_trusted boolean,
  p_process_succeeded boolean,
  p_process_exit_code integer,
  p_failure_detail_code text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  run_row public.agent_runs%rowtype;
  execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype;
  settlement jsonb;
  execution_status text;
  failure_code text;
  changed_task_id uuid;
  allowed_failure_codes text[] := array[
    'codex_process_failed','codex_process_timeout','codex_process_unavailable',
    'provider_auth_rejected','provider_access_denied','provider_rate_limited',
    'provider_quota_exhausted','provider_model_unavailable','provider_request_rejected',
    'provider_server_error','provider_connection_failed','provider_timeout',
    'provider_usage_missing','provider_usage_unverified'
  ];
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null
    or p_usage_trusted is null or p_process_succeeded is null
    or (p_process_exit_code is not null and p_process_exit_code not between -255 and 255)
    or (p_process_succeeded and (not p_usage_trusted or p_process_exit_code is distinct from 0
      or p_failure_detail_code is not null))
    or (not p_process_succeeded and (p_failure_detail_code is null
      or not (p_failure_detail_code=any(allowed_failure_codes)))) then
    raise exception 'malformed Codex run completion' using errcode='22023';
  end if;
  select * into run_row from public.agent_runs r where r.id=p_run_id and r.trigger_type='codex_execution'
    and r.status='running' and r.lease_token=p_lease_token and r.lease_expires_at>=now() for update;
  if not found then raise exception 'Codex run lease is invalid or expired' using errcode='42501'; end if;
  select * into execution_row from public.codex_task_executions e where e.agent_run_id=p_run_id for update;
  if not found or execution_row.reservation_id is null then
    raise exception 'Codex task execution has no spend reservation' using errcode='42501';
  end if;
  select * into reservation_row from public.agent_run_spend_reservations s where s.id=execution_row.reservation_id;
  if p_usage_trusted then
    if execution_row.request_count<1 then
      raise exception 'Codex cannot settle without provider usage evidence' using errcode='42501';
    end if;
    settlement:=public.sutra_reconcile_agent_run_spend_from_usage(p_worker_id,p_run_id,p_lease_token,
      reservation_row.id,execution_row.provider,execution_row.model,execution_row.input_tokens,
      execution_row.output_tokens,jsonb_build_object('requests',execution_row.request_count,
        'input_tokens',execution_row.input_tokens,'output_tokens',execution_row.output_tokens),true);
    if settlement->>'status'='reconciled' and p_process_succeeded then
      execution_status:='reconciled';
      update public.agent_runs set status='succeeded',finished_at=now(),lease_token=null,lease_expires_at=null,
        output=jsonb_build_object('codex_execution_status','reconciled','task_id',execution_row.task_id,
          'input_tokens',execution_row.input_tokens,'output_tokens',execution_row.output_tokens,
          'process_exit_code',p_process_exit_code)
        where id=p_run_id;
    else
      execution_status:='failed';
      failure_code:=case when settlement->>'status'='reconciled' then 'codex_process_failed'
        else 'codex_usage_settlement_failed' end;
      update public.agent_runs set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
        output=jsonb_build_object('codex_execution_status',settlement->>'status','task_id',execution_row.task_id,
          'error_code',failure_code,'failure_detail_code',p_failure_detail_code,
          'process_exit_code',p_process_exit_code,
          'input_tokens',execution_row.input_tokens,'output_tokens',execution_row.output_tokens)
        where id=p_run_id;
    end if;
    update public.codex_task_executions set status=execution_status,updated_at=now() where id=execution_row.id;
  else
    settlement:=public.sutra_reconcile_agent_run_spend_from_usage(p_worker_id,p_run_id,p_lease_token,
      reservation_row.id,execution_row.provider,execution_row.model,null,null,
      jsonb_build_object('reason','Codex execution ended without trusted complete usage'),false);
    update public.codex_task_executions set status='unknown',updated_at=now() where id=execution_row.id;
    update public.agent_runs set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
      output=jsonb_build_object('codex_execution_status','unknown','task_id',execution_row.task_id,
        'error_code','codex_usage_unknown','failure_detail_code',p_failure_detail_code,
        'process_exit_code',p_process_exit_code)
      where id=p_run_id;
    execution_status:='unknown';
  end if;
  if execution_status<>'reconciled' then
    update public.tasks set status='blocked',updated_at=now()
      where id=execution_row.task_id and status='in_progress'
      returning id into changed_task_id;
    if changed_task_id is not null then
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'codex.task_blocked_after_terminal_failure','task',changed_task_id::text,
        jsonb_build_object('execution_id',execution_row.id,'run_id',p_run_id,
          'execution_status',execution_status,'error_code',case when p_usage_trusted then failure_code
            else 'codex_usage_unknown' end));
    end if;
  end if;
  if not p_process_succeeded then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'codex.process_failed','codex_task_execution',execution_row.id::text,
      jsonb_build_object('task_id',execution_row.task_id,'process_exit_code',p_process_exit_code,
        'failure_detail_code',p_failure_detail_code,'usage_trusted',p_usage_trusted,
        'usage_settlement_status',settlement->>'status'));
  end if;
  return settlement||jsonb_build_object('task_id',execution_row.task_id,
    'execution_id',execution_row.id,'process_succeeded',p_process_succeeded,
    'process_exit_code',p_process_exit_code,'failure_detail_code',p_failure_detail_code);
end;
$$;


create or replace function public.sutra_authorize_codex_task(
  p_worker_id text,p_task_id uuid,p_issue_number integer,p_issue_url text,p_provider text,p_model text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; project_row public.projects%rowtype; developer_id uuid;
  run_row public.agent_runs%rowtype; execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype; reserve_result jsonb; run_id uuid; lease uuid;
  v_approval_id uuid;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_task_id is null or p_issue_number is null or p_issue_number<1
    or p_issue_url is null or p_issue_url !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$'
    or split_part(p_issue_url,'/',7)<>p_issue_number::text
    or p_provider is null or p_provider !~ '^[a-z0-9][a-z0-9_-]{0,79}$'
    or p_model is null or length(p_model) not between 1 and 200 or p_model ~ '[[:cntrl:]]' then
    raise exception 'malformed Codex task authorization request' using errcode='22023';
  end if;
  select t.* into task_row from public.tasks t where t.id=p_task_id for update;
  select a.id into developer_id from public.agents a where a.slug='developer' and a.active;
  select p.* into project_row from public.projects p where p.id=task_row.project_id;
  if task_row.id is null or developer_id is null or task_row.task_type<>'engineering'
    or task_row.status not in ('in_progress','blocked') or task_row.owner_agent_id<>developer_id
    or task_row.assigned_agent_id<>developer_id or project_row.id is null
    or project_row.status not in ('approved','active')
    or not exists(select 1 from public.github_task_dispatches d where d.task_id=task_row.id
      and d.status='created' and d.issue_number=p_issue_number and d.issue_url=p_issue_url)
    or not exists(select 1 from public.approvals sa where sa.approval_type='developer_scope'
      and sa.action_ref=task_row.id::text and sa.project_id=task_row.project_id and sa.status='approved'
      and sa.decisions #>> '{founder,decision}'='approve') then
    raise exception 'Codex requires the signed issue for an assigned Developer task in an approved project' using errcode='42501';
  end if;

  select * into execution_row from public.codex_task_executions e where e.task_id=p_task_id for update;
  if found then
    if execution_row.issue_number<>p_issue_number or execution_row.provider<>p_provider or execution_row.model<>p_model then
      raise exception 'Codex task was already bound to another issue or model route' using errcode='42501';
    end if;
    select * into run_row from public.agent_runs r where r.id=execution_row.agent_run_id for update;
    select * into reservation_row from public.agent_run_spend_reservations s
      where s.id=execution_row.reservation_id for update;
    if execution_row.status='awaiting_approval' and reservation_row.status='awaiting_approval'
      and run_row.status='blocked' then
      return jsonb_build_object('status','awaiting_approval','task_id',p_task_id,
        'approval_id',execution_row.approval_id,'reservation_id',reservation_row.id);
    end if;
    if reservation_row.status='rejected' or execution_row.status='rejected' then
      update public.codex_task_executions set status='rejected',updated_at=now() where id=execution_row.id;
      return jsonb_build_object('status','rejected','task_id',p_task_id,'reservation_id',reservation_row.id);
    end if;
    if execution_row.status in ('reconciled','unknown','overrun','failed') then
      return jsonb_build_object('status','terminal','task_id',p_task_id,
        'execution_status',execution_row.status);
    end if;
    if run_row.status='queued' and reservation_row.status='reserved' and run_row.attempt_count<3 then
      lease:=gen_random_uuid();
      update public.agent_runs set status='running',attempt_count=attempt_count+1,
        started_at=coalesce(started_at,now()),finished_at=null,lease_token=lease,
        lease_expires_at=now()+interval '2 hours',output='{"spend_approval":"approved"}'::jsonb
        where id=run_row.id returning * into run_row;
    elsif run_row.status='running' and run_row.lease_expires_at>=now() then
      null;
    else
      raise exception 'Codex execution lease is unavailable or exhausted' using errcode='42501';
    end if;
    if reservation_row.status='reserved' then
      update public.tasks set status='in_progress',updated_at=now()
        where id=execution_row.task_id and status='blocked';
      perform public.sutra_begin_agent_run_spend(p_worker_id,run_row.id,run_row.lease_token,reservation_row.id);
      update public.codex_task_executions set status='running',updated_at=now() where id=execution_row.id;
    end if;
    return jsonb_build_object('status','authorized','task_id',p_task_id,'run_id',run_row.id,
      'lease_token',run_row.lease_token,'reservation_id',reservation_row.id,
      'provider',execution_row.provider,'model',execution_row.model,
      'max_input_tokens',reservation_row.max_input_tokens,'max_output_tokens',reservation_row.max_output_tokens,
      'max_model_iterations',execution_row.max_requests);
  end if;

  if task_row.status<>'in_progress' then
    raise exception 'Codex requires an active Developer task without a prior execution' using errcode='42501';
  end if;
  run_id:=gen_random_uuid(); lease:=gen_random_uuid();
  insert into public.agent_runs(id,agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,lease_token,lease_expires_at,attempt_count)
    values(run_id,developer_id,task_row.project_id,task_row.id,'codex_execution','running',
      jsonb_build_object('task_id',task_row.id,'issue_number',p_issue_number,'provider',p_provider,'model',p_model),
      '{}'::jsonb,now(),lease,now()+interval '2 hours',1);
  insert into public.codex_task_executions(task_id,agent_run_id,issue_number,provider,model,max_requests,status)
    values(task_row.id,run_id,p_issue_number,p_provider,p_model,3,'running') returning * into execution_row;

  reserve_result:=public.sutra_reserve_agent_run_spend_from_profile(p_worker_id,run_id,lease,p_provider,p_model);
  reservation_row.id:=(reserve_result->>'reservation_id')::uuid;
  reservation_row.max_input_tokens:=(reserve_result->>'max_input_tokens')::integer;
  reservation_row.max_output_tokens:=(reserve_result->>'max_output_tokens')::integer;
  v_approval_id:=nullif(reserve_result->>'approval_id','')::uuid;
  update public.codex_task_executions set reservation_id=reservation_row.id,approval_id=v_approval_id,
    status=case when reserve_result->>'status'='approved' then 'running' else 'awaiting_approval' end,
    updated_at=now() where id=execution_row.id;
  if reserve_result->>'status'<>'approved' then
    return jsonb_build_object('status','awaiting_approval','task_id',p_task_id,
      'approval_id',v_approval_id,'reservation_id',reservation_row.id,
      'required_approvers',reserve_result->'required_approvers');
  end if;
  perform public.sutra_begin_agent_run_spend(p_worker_id,run_id,lease,reservation_row.id);
  return jsonb_build_object('status','authorized','task_id',p_task_id,'run_id',run_id,
    'lease_token',lease,'reservation_id',reservation_row.id,'provider',p_provider,'model',p_model,
    'max_input_tokens',reservation_row.max_input_tokens,'max_output_tokens',reservation_row.max_output_tokens,
    'max_model_iterations',reserve_result->'max_model_iterations');
end;
$$;

revoke all on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text)
  from public,anon,authenticated;
grant execute on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text)
  to service_role;


create or replace function public.sutra_founder_retry_codex_task_execution(
  p_founder_telegram_user_id text,
  p_task_id uuid
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  founder_id text;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  execution_row public.codex_task_executions%rowtype;
  failed_run public.agent_runs%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype;
  developer_id uuid;
  approval_id uuid;
  retry_number smallint;
  max_total_attempts smallint;
  new_run_id uuid;
  new_lease uuid;
  reserve_result jsonb;
  new_reservation_id uuid;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_task_id is null then
    raise exception 'malformed Codex retry request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can retry Codex' using errcode='42501';
  end if;
  select (s.value #>> '{}')::smallint into max_total_attempts
    from public.company_settings s where s.key='codex_no_request_retry_limit' for update;
  if max_total_attempts is null or max_total_attempts not between 1 and 3 then
    raise exception 'Codex retry limit is missing or invalid' using errcode='55000';
  end if;

  select * into task_row from public.tasks where id=p_task_id for update;
  if not found or task_row.task_type<>'engineering' or task_row.status not in ('in_progress','blocked') then
    raise exception 'Codex retry requires the existing active or blocked engineering task' using errcode='42501';
  end if;
  select a.id into developer_id from public.agents a where a.slug='developer' and a.active;
  select * into project_row from public.projects p where p.id=task_row.project_id for update;
  if developer_id is null or project_row.id is null or project_row.status not in ('approved','active')
    or task_row.owner_agent_id<>developer_id or task_row.assigned_agent_id<>developer_id then
    raise exception 'Codex retry requires the same assigned Developer and approved project' using errcode='42501';
  end if;
  select id into approval_id from public.approvals a where a.project_id=task_row.project_id
    and a.approval_type='project_budget' and a.status='approved'
    and a.decisions #>> '{founder,decision}'='approve'
  order by a.decided_at desc nulls last limit 1;
  if approval_id is null or not exists (
      select 1 from public.approvals a where a.approval_type='developer_scope'
        and a.action_ref=p_task_id::text and a.project_id=task_row.project_id
        and a.status='approved' and a.decisions #>> '{founder,decision}'='approve') then
    raise exception 'Codex retry requires the existing founder-approved project and Developer scope' using errcode='42501';
  end if;
  if not exists(select 1 from public.github_task_dispatches d where d.task_id=p_task_id
      and d.status='created' and d.pull_request_number is null and d.pull_request_merged=false) then
    raise exception 'Codex retry requires the existing signed GitHub issue with no pull request' using errcode='42501';
  end if;

  select * into execution_row from public.codex_task_executions e where e.task_id=p_task_id for update;
  if not found or execution_row.status<>'unknown' or execution_row.request_count<>0
    or execution_row.input_tokens<>0 or execution_row.output_tokens<>0
    or execution_row.reservation_id is null then
    raise exception 'Codex retry requires a terminal failure with zero provider requests and usage' using errcode='42501';
  end if;
  select * into failed_run from public.agent_runs r where r.id=execution_row.agent_run_id for update;
  select * into reservation_row from public.agent_run_spend_reservations s
    where s.id=execution_row.reservation_id for update;
  retry_number:=coalesce((select max(attempt_number)+1 from public.codex_task_execution_attempts
      where execution_id=execution_row.id),1);
  if failed_run.status<>'failed' or failed_run.trigger_type<>'codex_execution'
    or failed_run.lease_token is not null or failed_run.lease_expires_at is not null
    or failed_run.output->>'codex_execution_status'<>'unknown'
    or reservation_row.status<>'unknown'
    or reservation_row.usage->>'reason'<>'Codex execution ended without trusted complete usage'
    or retry_number>=max_total_attempts then
    raise exception 'Codex retry requires a verified no-request terminal failure and remaining configured attempt capacity' using errcode='42501';
  end if;

  insert into public.codex_task_execution_attempts(execution_id,task_id,attempt_number,agent_run_id,
      reservation_id,status,request_count,input_tokens,output_tokens,retried_by)
    values(execution_row.id,p_task_id,retry_number,execution_row.agent_run_id,
      execution_row.reservation_id,execution_row.status,execution_row.request_count,
      execution_row.input_tokens,execution_row.output_tokens,founder_id);

  new_run_id:=gen_random_uuid();
  new_lease:=gen_random_uuid();
  insert into public.agent_runs(id,agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,lease_token,lease_expires_at,attempt_count)
    values(new_run_id,developer_id,task_row.project_id,task_row.id,'codex_execution','running',
      jsonb_build_object('task_id',task_row.id,'issue_number',execution_row.issue_number,
        'provider',execution_row.provider,'model',execution_row.model,'founder_retry_number',retry_number+1),
      '{}'::jsonb,now(),new_lease,now()+interval '2 hours',1);
  update public.codex_task_executions set agent_run_id=new_run_id,reservation_id=null,
    approval_id=null,request_count=0,input_tokens=0,output_tokens=0,status='running',
    runner_claimed_at=null,updated_at=now() where id=execution_row.id returning * into execution_row;

  -- The central reservation gate accepts only active assigned tasks. This
  -- transition is in the same transaction and is reverted to blocked if
  -- spend approval is required, so no unapproved execution can claim it.
  update public.tasks set status='in_progress',updated_at=now() where id=p_task_id;
  reserve_result:=public.sutra_reserve_agent_run_spend_from_profile(
    'sutra-worker-founderretry1',new_run_id,new_lease,execution_row.provider,execution_row.model);
  new_reservation_id:=(reserve_result->>'reservation_id')::uuid;
  update public.codex_task_executions set reservation_id=new_reservation_id,
    approval_id=nullif(reserve_result->>'approval_id','')::uuid,
    status=case when reserve_result->>'status'='approved' then 'running' else 'awaiting_approval' end,
    updated_at=now() where id=execution_row.id;
  if reserve_result->>'status'<>'approved' then
    update public.tasks set status='blocked',updated_at=now() where id=p_task_id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,'founder.codex_retry_awaiting_spend_approval','task',p_task_id::text,
        jsonb_build_object('execution_id',execution_row.id,'prior_run_id',failed_run.id,
          'new_run_id',new_run_id,'reservation_id',new_reservation_id,
          'retry_number',retry_number,'project_spending_authorized',false));
    return jsonb_build_object('task_id',p_task_id,'status','awaiting_approval',
      'approval_id',reserve_result->>'approval_id','retry_number',retry_number,
      'attempt_number',retry_number+1,'max_total_attempts',max_total_attempts);
  end if;
  update public.tasks set status='in_progress',updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.codex_task_retry_requested','task',p_task_id::text,
      jsonb_build_object('execution_id',execution_row.id,'prior_run_id',failed_run.id,
        'prior_reservation_id',reservation_row.id,'new_run_id',new_run_id,
        'new_reservation_id',new_reservation_id,'retry_number',retry_number,
        'attempt_number',retry_number+1,'max_total_attempts',max_total_attempts,
        'prior_request_count',0,'prior_tokens',0,'unknown_reservation_preserved',true,
        'project_spending_authorized',false,'merge_release_authorized',false));
  return jsonb_build_object('task_id',p_task_id,'status','queued','execution_id',execution_row.id,
    'run_id',new_run_id,'retry_number',retry_number,'attempt_number',retry_number+1,
    'max_total_attempts',max_total_attempts,'old_unknown_reservation_preserved',true,
    'project_spending_authorized',false,'merge_release_authorized',false);
end;
$$;



revoke all on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)
  from public,anon,authenticated,service_role;
grant execute on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)
  to service_role;
revoke all on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text)
  to service_role;
revoke all on function public.sutra_founder_retry_codex_task_execution(text,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.sutra_founder_retry_codex_task_execution(text,uuid)
  to service_role;

-- Correct persisted task states from earlier terminal runs without altering their
-- usage accounting or reservations. The correction itself is recorded.
with terminal_codex as (
  select distinct on (t.id) t.id as task_id,e.id as execution_id,r.id as run_id,
    e.status as execution_status,e.request_count,e.input_tokens,e.output_tokens,
    r.output->>'error_code' as error_code
  from public.tasks t
  join public.codex_task_executions e on e.task_id=t.id
  join public.agent_runs r on r.id=e.agent_run_id
  where t.status='in_progress'
    and e.status in ('unknown','overrun','failed')
    and r.status='failed' and r.finished_at is not null
    and r.lease_token is null and r.lease_expires_at is null
  order by t.id,e.updated_at desc
), blocked as (
  update public.tasks t set status='blocked',updated_at=now()
  from terminal_codex c where t.id=c.task_id and t.status='in_progress'
  returning t.id
)
insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
select 'system','codex-task-lifecycle-migration','codex.task_blocked_after_terminal_failure',
  'task',c.task_id::text,jsonb_build_object('execution_id',c.execution_id,'run_id',c.run_id,
    'execution_status',c.execution_status,'error_code',c.error_code,
    'request_count',c.request_count,'input_tokens',c.input_tokens,'output_tokens',c.output_tokens)
from terminal_codex c join blocked b on b.id=c.task_id;

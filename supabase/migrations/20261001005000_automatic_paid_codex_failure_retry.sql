-- A fully metered Codex process failure may receive a bounded automatic retry
-- when the same approved scope remains active and a fresh reservation fits.
create or replace function public.sutra_queue_automatic_codex_retry(
  p_worker_id text,p_execution_id uuid,p_failure_detail_code text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare execution_row public.codex_task_executions%rowtype; run_row public.agent_runs%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype; task_row public.tasks%rowtype;
  project_row public.projects%rowtype; scope_row public.approvals%rowtype;
  developer_id uuid; retry_number smallint; max_total_attempts smallint;
  retry_id uuid; retry_lease uuid;
  spend_result jsonb; new_reservation_id uuid; reserve_sqlstate text;
  retryable_codes text[]:=array['codex_process_failed','codex_process_timeout',
    'provider_rate_limited','provider_server_error','provider_connection_failed','provider_timeout'];
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_execution_id is null or p_failure_detail_code is null
    or not (p_failure_detail_code=any(retryable_codes)) then
    raise exception 'malformed automatic Codex retry request' using errcode='22023';
  end if;
  select * into execution_row from public.codex_task_executions where id=p_execution_id for update;
  if not found then return jsonb_build_object('status','not_eligible'); end if;
  select * into run_row from public.agent_runs where id=execution_row.agent_run_id for update;
  select * into reservation_row from public.agent_run_spend_reservations
    where id=execution_row.reservation_id for update;
  select * into task_row from public.tasks where id=execution_row.task_id for update;
  select * into project_row from public.projects where id=task_row.project_id for update;
  select id into developer_id from public.agents where slug='developer' and active;
  select * into scope_row from public.approvals where approval_type='developer_scope'
    and action_ref=task_row.id::text and project_id=task_row.project_id and status='approved';
  select (value #>> '{}')::smallint into max_total_attempts
    from public.company_settings where key='codex_no_request_retry_limit';

  if execution_row.status is distinct from 'failed' or execution_row.request_count is null
    or execution_row.request_count<1 or execution_row.input_tokens is null
    or execution_row.output_tokens is null or execution_row.input_tokens+execution_row.output_tokens<1
    or run_row.id is null
    or run_row.status<>'failed' or run_row.trigger_type<>'codex_execution'
    or run_row.output->>'failure_detail_code' is distinct from p_failure_detail_code
    or reservation_row.id is null or reservation_row.status<>'reconciled'
    or task_row.id is null
    or task_row.status<>'blocked' or task_row.task_type<>'engineering'
    or task_row.owner_agent_id is distinct from developer_id
    or task_row.assigned_agent_id is distinct from developer_id
    or project_row.id is null or project_row.status not in ('approved','active')
    or project_row.legal_hold is distinct from false
    or project_row.currency is distinct from 'EUR' or project_row.budget_currency is distinct from 'EUR'
    or project_row.requested_budget is null or project_row.budget_amount is null
    or project_row.requested_budget<>project_row.budget_amount
    or project_row.requested_budget<=0
    or project_row.budget_assessment_status is distinct from 'within_cap'
    or project_row.budget_assessed_at is null
    or project_row.budget_assessment->>'recommended_action' is distinct from 'proceed_within_cap'
    or project_row.budget_assessment->>'estimated_total_eur' is null
    or project_row.budget_assessment->>'estimated_total_eur' !~ '^[0-9]+([.][0-9]{1,2})?$'
    or (project_row.budget_assessment->>'estimated_total_eur')::numeric>project_row.requested_budget
    or scope_row.id is null or scope_row.decisions #>> '{founder,decision}'<>'approve'
    or scope_row.decisions #>> '{standing_authorization,repository}'<>'anupdalvi86-oss/sutra'
    or not public.sutra_has_standing_code_authorization()
    or not exists(select 1 from public.github_task_dispatches d where d.task_id=task_row.id
      and d.status='created' and d.pull_request_number is null and d.pull_request_url is null
      and d.pull_request_merged=false)
    or exists(select 1 from public.legal_escalations where project_id=project_row.id and status='open') then
    return jsonb_build_object('status','not_eligible');
  end if;

  retry_number:=coalesce((select max(attempt_number)+1 from public.codex_task_execution_attempts
    where execution_id=execution_row.id),1);
  insert into public.codex_task_execution_attempts(execution_id,task_id,attempt_number,agent_run_id,
      reservation_id,status,request_count,input_tokens,output_tokens,retried_by)
    values(execution_row.id,task_row.id,retry_number,run_row.id,reservation_row.id,
      execution_row.status,execution_row.request_count,execution_row.input_tokens,
      execution_row.output_tokens,'sutra:auto-retry');
  if max_total_attempts is null or max_total_attempts not between 1 and 3 then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'codex.automatic_retry_stopped_by_retry_limit_policy',
        'task',task_row.id::text,jsonb_build_object('execution_id',execution_row.id,
          'prior_run_id',run_row.id,'attempt_number',retry_number,'max_total_attempts',max_total_attempts,
          'prior_reservation_id',reservation_row.id,'prior_reservation_preserved',true,
          'spending_authority_changed',false));
    return jsonb_build_object('status','retry_limit_unavailable');
  end if;
  if retry_number>=max_total_attempts then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'codex.automatic_retry_exhausted','task',task_row.id::text,
        jsonb_build_object('execution_id',execution_row.id,'prior_run_id',run_row.id,
          'attempt_number',retry_number,'max_total_attempts',max_total_attempts,
          'prior_request_count',execution_row.request_count,'prior_input_tokens',execution_row.input_tokens,
          'prior_output_tokens',execution_row.output_tokens,'prior_reservation_id',reservation_row.id,
          'prior_reservation_preserved',true,'spending_authority_changed',false));
    return jsonb_build_object('status','exhausted','max_total_attempts',max_total_attempts);
  end if;

  -- Isolate reservation errors so a hard stop preserves the completed failure,
  -- prior usage, and history instead of rolling those records back.
  begin
    retry_id:=gen_random_uuid();
    retry_lease:=gen_random_uuid();
    update public.tasks set status='in_progress',updated_at=now() where id=task_row.id;
    insert into public.agent_runs(id,agent_id,project_id,task_id,trigger_type,status,input,output,
        started_at,lease_token,lease_expires_at,attempt_count)
      values(retry_id,developer_id,task_row.project_id,task_row.id,'codex_execution','running',
        jsonb_build_object('task_id',task_row.id,'issue_number',execution_row.issue_number,
          'provider',execution_row.provider,'model',execution_row.model,
          'automatic_retry_number',retry_number+1,'max_total_attempts',max_total_attempts),
        '{}'::jsonb,now(),retry_lease,now()+interval '2 hours',1);
    update public.codex_task_executions set agent_run_id=retry_id,reservation_id=null,approval_id=null,
      request_count=0,input_tokens=0,output_tokens=0,status='running',runner_claimed_at=null,updated_at=now()
      where id=execution_row.id;
    spend_result:=public.sutra_reserve_agent_run_spend_from_profile(
      p_worker_id,retry_id,retry_lease,execution_row.provider,execution_row.model);
    new_reservation_id:=(spend_result->>'reservation_id')::uuid;
    update public.codex_task_executions set reservation_id=new_reservation_id,
      approval_id=nullif(spend_result->>'approval_id','')::uuid,
      status=case when spend_result->>'status'='approved' then 'running'
        else 'awaiting_approval' end,updated_at=now() where id=execution_row.id;
    if spend_result->>'status'<>'approved' then
      update public.tasks set status='blocked',updated_at=now() where id=task_row.id;
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system',p_worker_id,'codex.automatic_retry_awaiting_spend_approval','task',task_row.id::text,
          jsonb_build_object('execution_id',execution_row.id,'prior_run_id',run_row.id,
            'new_run_id',retry_id,'new_reservation_id',new_reservation_id,
            'approval_id',spend_result->>'approval_id','attempt_number',retry_number+1,
            'max_total_attempts',max_total_attempts,
            'prior_request_count',execution_row.request_count,
            'prior_input_tokens',execution_row.input_tokens,'prior_output_tokens',execution_row.output_tokens,
            'prior_reservation_preserved',true,'spending_authority_changed',false));
      return jsonb_build_object('status','awaiting_approval','attempt_number',retry_number+1,
        'max_total_attempts',max_total_attempts,
        'approval_id',spend_result->>'approval_id');
    end if;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'codex.automatic_retry_queued','task',task_row.id::text,
        jsonb_build_object('execution_id',execution_row.id,'prior_run_id',run_row.id,
          'new_run_id',retry_id,'prior_reservation_id',reservation_row.id,
          'new_reservation_id',new_reservation_id,'attempt_number',retry_number+1,
          'max_total_attempts',max_total_attempts,'prior_request_count',execution_row.request_count,
          'prior_input_tokens',execution_row.input_tokens,'prior_output_tokens',execution_row.output_tokens,
          'prior_actual_amount',reservation_row.actual_amount,'prior_reservation_preserved',true,
          'unknown_reservations_preserved',true,'spending_authority_changed',false,
          'merge_release_authority_changed',false));
    return jsonb_build_object('status','queued','attempt_number',retry_number+1,
      'max_total_attempts',max_total_attempts,'run_id',retry_id,'reservation_id',new_reservation_id,
      'prior_reservation_preserved',true,'spending_authority_changed',false);
  exception when others then
    get stacked diagnostics reserve_sqlstate=returned_sqlstate;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'codex.automatic_retry_stopped_by_spend_gate','task',task_row.id::text,
        jsonb_build_object('execution_id',execution_row.id,'prior_run_id',run_row.id,
          'attempt_number',retry_number+1,'max_total_attempts',max_total_attempts,
          'error_class',case when reserve_sqlstate='23514'
            then 'budget_hard_stop' else 'authorization_or_policy_gate' end,
          'prior_request_count',execution_row.request_count,
          'prior_input_tokens',execution_row.input_tokens,'prior_output_tokens',execution_row.output_tokens,
          'prior_reservation_id',reservation_row.id,'prior_reservation_preserved',true,
          'spending_authority_changed',false));
    return jsonb_build_object('status','stopped_by_spend_gate','attempt_number',retry_number+1,
      'max_total_attempts',max_total_attempts,
      'error_class',case when reserve_sqlstate='23514' then 'budget_hard_stop'
        else 'authorization_or_policy_gate' end);
  end;
end;
$$;
revoke all on function public.sutra_queue_automatic_codex_retry(text,uuid,text)
  from public,anon,authenticated;
grant execute on function public.sutra_queue_automatic_codex_retry(text,uuid,text) to service_role;

create or replace function public.sutra_codex_finish_run(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_usage_trusted boolean,
  p_process_succeeded boolean,p_process_exit_code integer,p_failure_detail_code text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype; settlement jsonb;
  execution_status text; failure_code text; changed_task_id uuid; automatic_retry jsonb;
  allowed_failure_codes text[]:=array['codex_process_failed','codex_process_timeout',
    'codex_process_unavailable','provider_auth_rejected','provider_access_denied',
    'provider_rate_limited','provider_quota_exhausted','provider_model_unavailable',
    'provider_request_rejected','provider_server_error','provider_connection_failed',
    'provider_timeout','provider_usage_missing','provider_usage_unverified'];
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null or p_usage_trusted is null or p_process_succeeded is null
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
          'process_exit_code',p_process_exit_code) where id=p_run_id;
    else
      execution_status:='failed';
      failure_code:=case when settlement->>'status'='reconciled' then 'codex_process_failed'
        else 'codex_usage_settlement_failed' end;
      update public.agent_runs set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
        output=jsonb_build_object('codex_execution_status',settlement->>'status','task_id',execution_row.task_id,
          'error_code',failure_code,'failure_detail_code',p_failure_detail_code,
          'process_exit_code',p_process_exit_code,'input_tokens',execution_row.input_tokens,
          'output_tokens',execution_row.output_tokens) where id=p_run_id;
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
        'process_exit_code',p_process_exit_code) where id=p_run_id;
    execution_status:='unknown';
  end if;
  if execution_status<>'reconciled' then
    update public.tasks set status='blocked',updated_at=now()
      where id=execution_row.task_id and status='in_progress' returning id into changed_task_id;
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
  if p_usage_trusted and not p_process_succeeded and settlement->>'status'='reconciled' then
    automatic_retry:=public.sutra_queue_automatic_codex_retry(
      p_worker_id,execution_row.id,p_failure_detail_code);
  end if;
  return settlement||jsonb_build_object('task_id',execution_row.task_id,
    'execution_id',execution_row.id,'process_succeeded',p_process_succeeded,
    'process_exit_code',p_process_exit_code,'failure_detail_code',p_failure_detail_code,
    'automatic_retry',coalesce(automatic_retry,jsonb_build_object('status','not_applicable')));
end;
$$;
revoke all on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)
  from public,anon,authenticated,service_role;
grant execute on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)
  to service_role;

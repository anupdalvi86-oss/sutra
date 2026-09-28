-- Persist only an allowlisted Codex failure category; never persist raw CLI/provider text.
create function public.sutra_codex_finish_run(
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

-- Keep the deployed six-argument runtime compatible until the new runner rolls out.
create or replace function public.sutra_codex_finish_run(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,
  p_usage_trusted boolean,p_process_succeeded boolean,p_process_exit_code integer
) returns jsonb language sql security definer set search_path=pg_catalog,public as $$
  select public.sutra_codex_finish_run(p_worker_id,p_run_id,p_lease_token,p_usage_trusted,
    p_process_succeeded,p_process_exit_code,
    case when p_process_succeeded then null else 'codex_process_failed' end);
$$;

revoke all on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)
  from public,anon,authenticated,service_role;
grant execute on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)
  to service_role;

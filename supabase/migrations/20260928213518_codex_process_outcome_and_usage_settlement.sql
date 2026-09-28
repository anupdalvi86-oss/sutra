-- Track metering trust separately from whether Codex produced a successful result.
-- Keep the old signature fail-closed during rolling deployment so stale runners
-- cannot mark a nonzero process successful using the old conflated flag.
create or replace function public.sutra_codex_finish_run(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_success boolean
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  raise exception 'Codex runner upgrade required for separate process and usage results' using errcode='55000';
end;
$$;

create function public.sutra_codex_finish_run(
  p_worker_id text,
  p_run_id uuid,
  p_lease_token uuid,
  p_usage_trusted boolean,
  p_process_succeeded boolean,
  p_process_exit_code integer
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  run_row public.agent_runs%rowtype;
  execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype;
  settlement jsonb;
  execution_status text;
  failure_code text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null
    or p_usage_trusted is null or p_process_succeeded is null
    or (p_process_exit_code is not null and p_process_exit_code not between -255 and 255)
    or (p_process_succeeded and (not p_usage_trusted or p_process_exit_code is distinct from 0)) then
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
          'error_code',failure_code,'process_exit_code',p_process_exit_code,
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
        'error_code','codex_usage_unknown','process_exit_code',p_process_exit_code)
      where id=p_run_id;
    execution_status:='unknown';
  end if;
  if not p_process_succeeded then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'codex.process_failed','codex_task_execution',execution_row.id::text,
      jsonb_build_object('task_id',execution_row.task_id,'process_exit_code',p_process_exit_code,
        'usage_trusted',p_usage_trusted,'usage_settlement_status',settlement->>'status'));
  end if;
  return settlement||jsonb_build_object('task_id',execution_row.task_id,
    'execution_id',execution_row.id,'process_succeeded',p_process_succeeded,
    'process_exit_code',p_process_exit_code);
end;
$$;

revoke all on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer)
  to service_role;

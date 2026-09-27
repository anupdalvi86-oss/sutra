-- A database lease may be observed by multiple runner replicas or a restarted
-- process. Claim it once in the authoritative database before any Codex call.
alter table public.codex_task_executions
  add column runner_claimed_at timestamptz;

create function public.sutra_claim_codex_execution(
  p_worker_id text, p_run_id uuid, p_lease_token uuid
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare execution_row public.codex_task_executions%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null then
    raise exception 'malformed Codex execution claim' using errcode='22023';
  end if;
  select e.* into execution_row
    from public.codex_task_executions e
    join public.agent_runs r on r.id=e.agent_run_id
    where e.agent_run_id=p_run_id and e.status='running'
      and r.trigger_type='codex_execution' and r.status='running'
      and r.lease_token=p_lease_token and r.lease_expires_at>=now()
    for update of e;
  if not found then
    raise exception 'Codex execution lease is invalid, expired, or terminal' using errcode='42501';
  end if;
  if execution_row.runner_claimed_at is not null then
    return jsonb_build_object('claimed',false,'execution_id',execution_row.id);
  end if;
  update public.codex_task_executions set runner_claimed_at=now(),updated_at=now()
    where id=execution_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'codex.runner_claimed','codex_task_execution',execution_row.id::text,
      jsonb_build_object('task_id',execution_row.task_id,'run_id',p_run_id));
  return jsonb_build_object('claimed',true,'execution_id',execution_row.id,
    'task_id',execution_row.task_id);
end;
$$;

revoke all on function public.sutra_claim_codex_execution(text,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.sutra_claim_codex_execution(text,uuid,uuid) to service_role;

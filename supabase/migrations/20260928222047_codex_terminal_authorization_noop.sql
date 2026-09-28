-- A terminal Codex execution is a normal no-op during polling, not an RPC error.
-- This avoids repeated authorization warnings and guarantees no new run or reservation.
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
    or task_row.status<>'in_progress' or task_row.owner_agent_id<>developer_id
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
      perform public.sutra_begin_agent_run_spend(p_worker_id,run_row.id,run_row.lease_token,reservation_row.id);
      update public.codex_task_executions set status='running',updated_at=now() where id=execution_row.id;
    end if;
    return jsonb_build_object('status','authorized','task_id',p_task_id,'run_id',run_row.id,
      'lease_token',run_row.lease_token,'reservation_id',reservation_row.id,
      'provider',execution_row.provider,'model',execution_row.model,
      'max_input_tokens',reservation_row.max_input_tokens,'max_output_tokens',reservation_row.max_output_tokens,
      'max_model_iterations',execution_row.max_requests);
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

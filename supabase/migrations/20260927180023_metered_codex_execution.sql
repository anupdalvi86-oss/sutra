-- Codex execution is authorized as a Developer task, with the same model-price
-- snapshot, spending policy, hard budget checks, approval and expense ledger used
-- by Hermes. A run cannot get a capability until its spend reserve is approved.

alter table public.agent_run_spend_reservations
  add column max_model_iterations integer not null default 3
    check (max_model_iterations between 1 and 3);

create table public.codex_task_executions (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null unique references public.tasks(id) on delete restrict,
  agent_run_id uuid not null unique references public.agent_runs(id) on delete restrict,
  reservation_id uuid unique references public.agent_run_spend_reservations(id) on delete restrict,
  issue_number integer not null check (issue_number > 0),
  provider text not null check (provider ~ '^[a-z0-9][a-z0-9_-]{0,79}$'),
  model text not null check (length(model) between 1 and 200 and model !~ '[[:cntrl:]]'),
  max_requests integer not null default 3 check (max_requests between 1 and 3),
  request_count integer not null default 0 check (request_count between 0 and 3),
  input_tokens bigint not null default 0 check (input_tokens >= 0),
  output_tokens bigint not null default 0 check (output_tokens >= 0),
  status text not null check (status in ('awaiting_approval','running','reconciled','unknown','overrun','failed','rejected')),
  approval_id uuid references public.approvals(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.codex_task_executions enable row level security;
revoke all on public.codex_task_executions from public,anon,authenticated,service_role;
create index codex_task_executions_status_idx on public.codex_task_executions(status,updated_at);

-- Extend the central reservation path; Codex uses the same authority and budget checks.
create or replace function public.sutra_reserve_agent_run_spend(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_provider text,p_model text,p_amount numeric
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  run_row public.agent_runs%rowtype;
  agent_row public.agents%rowtype;
  project_row public.projects%rowtype;
  prior_row public.agent_run_spend_reservations%rowtype;
  spend_result jsonb;
  expense_id uuid;
  approval_id uuid;
  spend_status text;
  warnings text[] := '{}';
  budget_row public.budgets%rowtype;
  used_amount numeric(14,2);
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null
    or p_provider is null or p_provider !~ '^[a-z0-9][a-z0-9_-]{0,79}$'
    or p_model is null or length(p_model) not between 1 and 200 or p_model ~ '[[:cntrl:]]'
    or p_amount is null or p_amount <= 0 or p_amount > 999999999999.99
    or p_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'malformed agent run spend reservation' using errcode = '22023';
  end if;
  select * into run_row from public.agent_runs r
    where r.id=p_run_id and r.status='running' and r.lease_token=p_lease_token
      and r.trigger_type in ('founder_proposal','task_artifact','codex_execution') and r.lease_expires_at >= now()
    for update;
  if not found then raise exception 'agent run lease is invalid or expired' using errcode = '42501'; end if;
  select * into agent_row from public.agents a where a.id=run_row.agent_id and a.active;
  select * into project_row from public.projects p where p.id=run_row.project_id;
  if agent_row.id is null or project_row.id is null then
    raise exception 'agent spend requires an active agent and project' using errcode = '42501';
  end if;
  if project_row.status not in ('proposed','approved','active')
    or (run_row.trigger_type in ('task_artifact','codex_execution') and project_row.status not in ('approved','active')) then
    raise exception 'project is not eligible for agent review spend' using errcode = '42501';
  end if;
  if run_row.trigger_type='task_artifact' and not exists(
    select 1 from public.tasks t where t.id=run_row.task_id and t.project_id=run_row.project_id
      and t.owner_agent_id=run_row.agent_id and t.assigned_agent_id=run_row.agent_id and t.status='in_progress') then
    raise exception 'task artifact run does not own an active assigned task' using errcode='42501';
  end if;
  if run_row.trigger_type='codex_execution' and not exists(
    select 1 from public.tasks t
      join public.agents developer on developer.id=t.assigned_agent_id and developer.slug='developer' and developer.active
      join public.github_task_dispatches d on d.task_id=t.id and d.status='created'
    where t.id=run_row.task_id and t.project_id=run_row.project_id and t.task_type='engineering'
      and t.status='in_progress' and t.owner_agent_id=run_row.agent_id and t.assigned_agent_id=run_row.agent_id
  ) then
    raise exception 'Codex spend requires the dispatched active Developer task' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));

  -- Approval requeues the blocked run. Reuse its approved reservation rather than
  -- recording a duplicate charge before the first provider request.
  select * into prior_row from public.agent_run_spend_reservations s
    where s.agent_run_id=p_run_id and s.status='reserved'
    order by s.created_at desc limit 1 for update;
  if found then
    if prior_row.provider <> p_provider or prior_row.model <> p_model
      or prior_row.reserved_amount < p_amount then
      raise exception 'approved model reservation does not cover this route or amount' using errcode = '42501';
    end if;
    return jsonb_build_object('status','approved','reservation_id',prior_row.id,
      'expense_id',prior_row.expense_id,'reserved_amount',prior_row.reserved_amount,'reused',true);
  end if;

  -- A worker may have died after the provider accepted a request. Keep its full
  -- expense reserve and mark usage unknown before allowing a later lease attempt.
  with stale as (
    update public.agent_run_spend_reservations set status='unknown',
        usage=jsonb_build_object('reason','worker_retry_after_provider_start'),settled_at=now()
      where agent_run_id=p_run_id and status='started'
      returning id,reserved_amount
  )
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    select 'system',p_worker_id,'agent_run.spend_unknown','agent_run_spend_reservation',stale.id::text,
      jsonb_build_object('run_id',p_run_id,'reserved_amount',stale.reserved_amount,
        'reason','worker_retry_after_provider_start') from stale;

  -- The central spend function is also used for all policy tiers and non-project
  -- budgets. Project budgets need a pre-approval review exception, so validate
  -- those scopes here while holding the same transaction lock, then bind the
  -- resulting expense and approval to this founder-proposed project atomically.
  for budget_row in
    select * from public.budgets b where b.active and b.currency='EUR'
      and b.scope='project' and (b.scope_key='*' or b.scope_key=run_row.project_id::text)
    order by b.scope_key,b.period for update
  loop
    if budget_row.limit_amount is null then continue; end if;
    if budget_row.period='transaction' then
      used_amount := 0;
    elsif budget_row.period='daily' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.project_id=run_row.project_id and e.currency='EUR'
          and e.status in ('requested','approved','paid') and e.created_at >= date_trunc('day',now());
    elsif budget_row.period='monthly' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.project_id=run_row.project_id and e.currency='EUR'
          and e.status in ('requested','approved','paid') and e.created_at >= date_trunc('month',now());
    else
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.project_id=run_row.project_id and e.currency='EUR'
          and e.status in ('requested','approved','paid');
    end if;
    if used_amount+p_amount > budget_row.limit_amount and budget_row.hard_stop then
      raise exception 'budget hard stop: project:% budget exceeded',run_row.project_id using errcode = '23514';
    end if;
    if used_amount+p_amount >= budget_row.limit_amount*budget_row.warning_percent/100 then
      warnings := array_append(warnings,'project:'||budget_row.scope_key||':'||budget_row.period);
    end if;
  end loop;

  spend_result := public.sutra_authorize_spend(
    'agent',agent_row.slug,agent_row.id,null,agent_row.department_id,'ai_inference',
    case when run_row.trigger_type='codex_execution' then 'codex:' else 'hermes:' end||p_provider,
    case when run_row.trigger_type='codex_execution'
      then 'Bounded Codex execution for ' else 'Bounded Hermes review for ' end||agent_row.slug||' ('||left(p_model,160)||')',p_amount,'EUR');
  expense_id := (spend_result->>'expense_id')::uuid;
  approval_id := nullif(spend_result->>'approval_id','')::uuid;
  spend_status := spend_result->>'status';
  update public.expenses set project_id=run_row.project_id where id=expense_id;
  if approval_id is not null then update public.approvals set project_id=run_row.project_id where id=approval_id; end if;
  insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,reserved_amount,status)
    values(run_row.id,run_row.attempt_count,expense_id,p_provider,p_model,p_amount,
      case when spend_status='approved' then 'reserved' else 'awaiting_approval' end)
    returning * into prior_row;

  if spend_status <> 'approved' then
    update public.agent_runs set status='blocked',finished_at=now(),lease_token=null,lease_expires_at=null,
      output=jsonb_build_object('blocked_by','model_spend_approval','approval_id',approval_id,
        'reservation_id',prior_row.id,'reserved_amount',p_amount)
      where id=run_row.id;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'agent_run.spend_reserved','agent_run_spend_reservation',prior_row.id::text,
      jsonb_build_object('run_id',run_row.id,'agent',agent_row.slug,'project_id',run_row.project_id,
        'provider',p_provider,'model',p_model,'amount',p_amount,'status',spend_status,
        'approval_id',approval_id,'budget_warnings',warnings));
  return jsonb_build_object('status',spend_status,'reservation_id',prior_row.id,'expense_id',expense_id,
    'approval_id',approval_id,'reserved_amount',p_amount,'required_approvers',spend_result->'required_approvers',
    'budget_warnings',warnings,'reused',false);
end;
$$;

create function public.sutra_codex_start_request(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_model text,p_output_tokens integer,p_request_bytes integer
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null or p_model is null
    or p_output_tokens is null or p_output_tokens<1 or p_request_bytes is null or p_request_bytes<1 then
    raise exception 'malformed Codex Responses request' using errcode='22023';
  end if;
  select * into run_row from public.agent_runs r where r.id=p_run_id and r.trigger_type='codex_execution'
    and r.status='running' and r.lease_token=p_lease_token and r.lease_expires_at>=now() for update;
  if not found then raise exception 'Codex run lease is invalid or expired' using errcode='42501'; end if;
  select * into execution_row from public.codex_task_executions e where e.agent_run_id=p_run_id for update;
  if not found or execution_row.reservation_id is null then
    raise exception 'Codex task execution has no spend reservation' using errcode='42501';
  end if;
  select * into reservation_row from public.agent_run_spend_reservations s where s.id=execution_row.reservation_id;
  if execution_row.status<>'running' or p_model<>execution_row.model
    or p_output_tokens>reservation_row.max_output_tokens
    or p_request_bytes::bigint>reservation_row.max_input_tokens::bigint*8
    or execution_row.request_count>=execution_row.max_requests then
    raise exception 'Codex request exceeds its reserved route, token, byte, or request limit' using errcode='42501';
  end if;
  update public.codex_task_executions set request_count=request_count+1,updated_at=now() where id=execution_row.id
    returning * into execution_row;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'codex.responses_request_authorized','codex_task_execution',execution_row.id::text,
      jsonb_build_object('task_id',execution_row.task_id,'request_number',execution_row.request_count,
        'model',execution_row.model,'max_output_tokens',reservation_row.max_output_tokens));
  return jsonb_build_object('authorized',true,'request_number',execution_row.request_count,
    'max_requests',execution_row.max_requests,'max_input_tokens',reservation_row.max_input_tokens,
    'max_output_tokens',reservation_row.max_output_tokens);
end;
$$;

create function public.sutra_codex_record_usage(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_input_tokens bigint,p_output_tokens bigint
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null or p_input_tokens is null or p_input_tokens<0
    or p_output_tokens is null or p_output_tokens<0 then
    raise exception 'malformed Codex usage report' using errcode='22023';
  end if;
  select * into run_row from public.agent_runs r where r.id=p_run_id and r.trigger_type='codex_execution'
    and r.status='running' and r.lease_token=p_lease_token and r.lease_expires_at>=now() for update;
  if not found then raise exception 'Codex run lease is invalid or expired' using errcode='42501'; end if;
  select * into execution_row from public.codex_task_executions e where e.agent_run_id=p_run_id for update;
  if not found or execution_row.reservation_id is null then
    raise exception 'Codex task execution has no spend reservation' using errcode='42501';
  end if;
  select * into reservation_row from public.agent_run_spend_reservations s where s.id=execution_row.reservation_id;
  if execution_row.status<>'running' or execution_row.request_count<1
    or p_input_tokens>reservation_row.max_input_tokens or p_output_tokens>reservation_row.max_output_tokens
    or execution_row.input_tokens+p_input_tokens>reservation_row.max_input_tokens*execution_row.max_requests
    or execution_row.output_tokens+p_output_tokens>reservation_row.max_output_tokens*execution_row.max_requests then
    raise exception 'Codex provider usage exceeds the approved reservation' using errcode='23514';
  end if;
  update public.codex_task_executions set input_tokens=input_tokens+p_input_tokens,
    output_tokens=output_tokens+p_output_tokens,updated_at=now() where id=execution_row.id returning * into execution_row;
  update public.agent_run_spend_reservations set usage=usage||jsonb_build_object(
    'codex_requests',execution_row.request_count,'input_tokens',execution_row.input_tokens,
    'output_tokens',execution_row.output_tokens) where id=reservation_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'codex.responses_usage_recorded','codex_task_execution',execution_row.id::text,
      jsonb_build_object('task_id',execution_row.task_id,'request_count',execution_row.request_count,
        'input_tokens',execution_row.input_tokens,'output_tokens',execution_row.output_tokens));
  return jsonb_build_object('recorded',true,'request_count',execution_row.request_count,
    'input_tokens',execution_row.input_tokens,'output_tokens',execution_row.output_tokens);
end;
$$;

create function public.sutra_codex_finish_run(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_success boolean
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare run_row public.agent_runs%rowtype; execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype; settlement jsonb;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null or p_success is null then
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
  if p_success and execution_row.request_count<1 then
    raise exception 'Codex cannot finish without provider usage evidence' using errcode='42501';
  end if;
  if p_success then
    settlement:=public.sutra_reconcile_agent_run_spend_from_usage(p_worker_id,p_run_id,p_lease_token,
      reservation_row.id,execution_row.provider,execution_row.model,execution_row.input_tokens,
      execution_row.output_tokens,jsonb_build_object('requests',execution_row.request_count,
        'input_tokens',execution_row.input_tokens,'output_tokens',execution_row.output_tokens),true);
    update public.codex_task_executions set status=settlement->>'status',updated_at=now() where id=execution_row.id;
    update public.agent_runs set status=case when settlement->>'status'='reconciled' then 'succeeded' else 'failed' end,
      finished_at=now(),lease_token=null,lease_expires_at=null,
      output=jsonb_build_object('codex_execution_status',settlement->>'status','task_id',execution_row.task_id,
        'input_tokens',execution_row.input_tokens,'output_tokens',execution_row.output_tokens)
      where id=p_run_id;
  else
    settlement:=public.sutra_reconcile_agent_run_spend_from_usage(p_worker_id,p_run_id,p_lease_token,
      reservation_row.id,execution_row.provider,execution_row.model,null,null,
      jsonb_build_object('reason','Codex execution ended without trusted complete usage'),false);
    update public.codex_task_executions set status='unknown',updated_at=now() where id=execution_row.id;
    update public.agent_runs set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
      output=jsonb_build_object('codex_execution_status','unknown','task_id',execution_row.task_id)
      where id=p_run_id;
  end if;
  return settlement||jsonb_build_object('task_id',execution_row.task_id,'execution_id',execution_row.id);
end;
$$;


create function public.sutra_authorize_codex_task(
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
      and d.status='created' and d.issue_number=p_issue_number and d.issue_url=p_issue_url) then
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
      raise exception 'Codex task execution is terminal' using errcode='42501';
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

create or replace function public.sutra_validate_agent_model_reconciliation()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare expected numeric(14,2); iteration_limit integer:=1;
begin
  if new.status in ('reconciled','overrun') and old.status is distinct from new.status then
    select case when r.trigger_type='codex_execution' then old.max_model_iterations else 1 end
      into iteration_limit from public.agent_runs r where r.id=new.agent_run_id;
    if new.input_tokens is null or new.output_tokens is null
      or new.input_tokens > old.max_input_tokens*iteration_limit
      or new.output_tokens > old.max_output_tokens*iteration_limit then
      raise exception 'reported model usage exceeds the reserved token ceiling' using errcode='23514';
    end if;
    expected := ceil((new.input_tokens*old.input_eur_per_million_tokens
      + new.output_tokens*old.output_eur_per_million_tokens)/10000)/100;
    if new.actual_amount <> expected then
      raise exception 'worker-reported model cost differs from database reconciliation' using errcode='42501';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.sutra_validate_agent_model_reconciliation() from public,anon,authenticated,service_role;
revoke all on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text) from public,anon,authenticated;
revoke all on function public.sutra_codex_start_request(text,uuid,uuid,text,integer,integer) from public,anon,authenticated;
revoke all on function public.sutra_codex_record_usage(text,uuid,uuid,bigint,bigint) from public,anon,authenticated;
revoke all on function public.sutra_codex_finish_run(text,uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text) to service_role;
grant execute on function public.sutra_codex_start_request(text,uuid,uuid,text,integer,integer) to service_role;
grant execute on function public.sutra_codex_record_usage(text,uuid,uuid,bigint,bigint) to service_role;
grant execute on function public.sutra_codex_finish_run(text,uuid,uuid,boolean) to service_role;

-- Enforce the founder's all-in initiative cap on model reservations as well as
-- non-model costs. The shared advisory lock serializes inference and other spend;
-- reserved/unknown amounts stay fully committed until reconciled.
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
  current_commitment numeric(14,2);
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
  if agent_row.id is null then
    raise exception 'agent spend requires an active agent and project' using errcode = '42501';
  end if;
  -- Serialize with non-model initiative reservations, settlements, and
  -- founder budget changes before reading the current ceiling.
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||run_row.project_id::text));
  select * into project_row from public.projects p where p.id=run_row.project_id for update;
  if project_row.id is null then
    raise exception 'agent spend requires an active agent and project' using errcode = '42501';
  end if;
  if project_row.currency<>'EUR' or project_row.requested_budget is null or project_row.requested_budget<=0 then
    raise exception 'initiative has no explicit positive EUR all-in budget' using errcode='23514';
  end if;
  if run_row.attempt_count=4 and not (
    run_row.trigger_type='founder_proposal' and run_row.run_order=5
    and agent_row.slug='product_manager'
    and run_row.output->>'founder_pm_recovery' is not distinct from 'requested'
  ) then
    raise exception 'fourth model attempt is limited to an audited founder PM schema recovery' using errcode = '42501';
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

  -- Model usage shares the same lifetime initiative ceiling as every other
  -- commitment. Count reserved and unknown amounts in full and reconciled use
  -- at its actual amount while holding the initiative lock to prevent races.
  select coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
      when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end),0)
    into current_commitment
    from public.initiative_budget_ledger l where l.project_id=run_row.project_id
      and l.status in ('reserved','unknown','actual','overrun');
  if current_commitment+p_amount>project_row.requested_budget then
    raise exception 'initiative all-in budget hard stop: model reservation requires founder budget change' using errcode='23514';
  end if;

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
        || case when run_row.attempt_count=4 then jsonb_build_object('founder_pm_recovery','requested') else '{}'::jsonb end
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

create or replace function public.sutra_reconcile_agent_run_spend(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_reservation_id uuid,
  p_provider text,p_model text,p_actual_amount numeric,p_input_tokens bigint,p_output_tokens bigint,
  p_usage jsonb,p_usage_known boolean
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare run_row public.agent_runs%rowtype; reservation_row public.agent_run_spend_reservations%rowtype;
  final_status text; settled_amount numeric(14,2);
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null or p_reservation_id is null
    or p_provider is null or p_model is null or p_usage is null or jsonb_typeof(p_usage)<>'object'
    or octet_length(p_usage::text)>4000 or p_usage_known is null
    or (p_usage_known and (p_actual_amount is null or p_actual_amount<0 or p_actual_amount>999999999999.99
      or p_actual_amount::text in ('NaN','Infinity','-Infinity') or p_input_tokens is null or p_input_tokens<0
      or p_output_tokens is null or p_output_tokens<0)) then
    raise exception 'malformed Hermes usage reconciliation' using errcode = '22023';
  end if;
  select * into run_row from public.agent_runs r where r.id=p_run_id and r.status='running'
    and r.lease_token=p_lease_token and r.lease_expires_at >= now() for update;
  if not found then raise exception 'agent run lease is invalid or expired' using errcode = '42501'; end if;
  select * into reservation_row from public.agent_run_spend_reservations s
    where s.id=p_reservation_id and s.agent_run_id=p_run_id for update;
  if not found or reservation_row.status <> 'started' then
    raise exception 'agent spend reservation is not in progress' using errcode = '42501';
  end if;
  if p_provider <> reservation_row.provider or p_model <> reservation_row.model then
    raise exception 'actual Hermes route differs from its approved reservation' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||run_row.project_id::text));

  if not p_usage_known then
    final_status := 'unknown';
    update public.agent_run_spend_reservations set status='unknown',usage=p_usage,settled_at=now()
      where id=reservation_row.id;
    -- Keep the whole reservation in expenses so budget checks remain conservative.
    update public.agent_runs set output=coalesce(output,'{}'::jsonb)||jsonb_build_object(
      'spend_status','unknown','reservation_id',reservation_row.id) where id=run_row.id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'agent_run.spend_unknown','agent_run_spend_reservation',reservation_row.id::text,
        jsonb_build_object('run_id',p_run_id,'reserved_amount',reservation_row.reserved_amount));
    return jsonb_build_object('status',final_status,'reserved_amount',reservation_row.reserved_amount,
      'actual_amount',null,'reservation_id',reservation_row.id);
  end if;

  settled_amount := p_actual_amount;
  final_status := case when p_actual_amount > reservation_row.reserved_amount then 'overrun' else 'reconciled' end;
  update public.agent_run_spend_reservations set status=final_status,actual_amount=p_actual_amount,
      input_tokens=p_input_tokens,output_tokens=p_output_tokens,usage=p_usage,settled_at=now()
    where id=reservation_row.id;
  update public.expenses set actual_amount=p_actual_amount,
      amount=greatest(p_actual_amount,0.01),
      status=case when p_actual_amount=0 then 'void' else 'approved' end,
      incurred_at=case when p_actual_amount=0 then null else now() end
    where id=reservation_row.expense_id;
  update public.agent_runs set output=coalesce(output,'{}'::jsonb)||jsonb_build_object(
    'spend_status',final_status,'reservation_id',reservation_row.id,'actual_amount',p_actual_amount,
    'input_tokens',p_input_tokens,'output_tokens',p_output_tokens) where id=run_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'agent_run.spend_'||final_status,'agent_run_spend_reservation',reservation_row.id::text,
      jsonb_build_object('run_id',p_run_id,'reserved_amount',reservation_row.reserved_amount,
        'actual_amount',p_actual_amount,'input_tokens',p_input_tokens,'output_tokens',p_output_tokens,
        'provider',p_provider,'model',p_model));
  return jsonb_build_object('status',final_status,'reserved_amount',reservation_row.reserved_amount,
    'actual_amount',p_actual_amount,'reservation_id',reservation_row.id);
end;
$$;

create or replace function public.sutra_settle_initiative_cost(
  p_actor_id text,p_ledger_id uuid,p_actual_amount numeric,p_usage_known boolean
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare entry public.initiative_budget_ledger%rowtype; project_row public.projects%rowtype; new_status text; locked_project_id uuid;
begin
  if p_actor_id is null or p_ledger_id is null or p_usage_known is null
    or (p_usage_known and (p_actual_amount is null or p_actual_amount<0 or p_actual_amount>999999999999.99
      or p_actual_amount::text in ('NaN','Infinity','-Infinity'))) then
    raise exception 'malformed initiative cost settlement' using errcode='22023';
  end if;
  select project_id into locked_project_id from public.initiative_budget_ledger where id=p_ledger_id;
  if not found then raise exception 'initiative reservation was not found' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||locked_project_id::text));
  select * into entry from public.initiative_budget_ledger l where l.id=p_ledger_id for update;
  if not found or entry.status not in ('reserved','unknown') then
    raise exception 'initiative reservation is not open for settlement' using errcode='42501';
  end if;
  select * into project_row from public.projects where id=entry.project_id for update;
  if p_actor_id<>'sutra' and p_actor_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'settlement actor identity is invalid' using errcode='42501';
  end if;
  if not p_usage_known then
    update public.initiative_budget_ledger set status='unknown',updated_at=now() where id=entry.id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',left(p_actor_id,120),'initiative.cost_unknown','initiative_budget_ledger',entry.id::text,
        jsonb_build_object('project_id',entry.project_id,'reserved_amount',entry.reserved_amount));
    return jsonb_build_object('status','unknown','reserved_amount',entry.reserved_amount,'actual_amount',null);
  end if;
  new_status:=case when p_actual_amount>entry.reserved_amount then 'overrun' else 'actual' end;
  update public.initiative_budget_ledger set status=new_status,actual_amount=p_actual_amount,updated_at=now()
    where id=entry.id;
  update public.expenses set actual_amount=p_actual_amount,
    amount=greatest(p_actual_amount,0.01),status=case when p_actual_amount=0 then 'void' else 'paid' end,
    incurred_at=case when p_actual_amount=0 then null else now() end where id=entry.expense_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_actor_id,120),'initiative.cost_'||new_status,'initiative_budget_ledger',entry.id::text,
      jsonb_build_object('project_id',entry.project_id,'reserved_amount',entry.reserved_amount,
        'actual_amount',p_actual_amount,'all_in_budget',project_row.requested_budget));
  if new_status='overrun' then
    update public.projects set status='paused',updated_at=now() where id=entry.project_id;
  end if;
  return jsonb_build_object('status',new_status,'reserved_amount',entry.reserved_amount,'actual_amount',p_actual_amount);
end;
$$;

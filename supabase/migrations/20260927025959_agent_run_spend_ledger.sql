-- Every paid Hermes review must reserve through the existing spend policy
-- before network I/O, then retain or settle that reservation from observed usage.
alter table public.expenses add column actual_amount numeric(14,2)
  check (actual_amount is null or actual_amount >= 0);

create table public.agent_run_spend_reservations (
  id uuid primary key default gen_random_uuid(),
  agent_run_id uuid not null references public.agent_runs(id) on delete cascade,
  attempt integer not null check (attempt between 1 and 3),
  expense_id uuid not null unique references public.expenses(id),
  provider text not null check (provider ~ '^[a-z0-9][a-z0-9_-]{0,79}$'),
  model text not null check (length(model) between 1 and 200 and model !~ '[[:cntrl:]]'),
  reserved_amount numeric(14,2) not null check (reserved_amount > 0),
  actual_amount numeric(14,2) check (actual_amount is null or actual_amount >= 0),
  input_tokens bigint check (input_tokens is null or input_tokens >= 0),
  output_tokens bigint check (output_tokens is null or output_tokens >= 0),
  usage jsonb not null default '{}'::jsonb check (jsonb_typeof(usage) = 'object'),
  status text not null check (status in ('awaiting_approval','reserved','started','reconciled','unknown','overrun','rejected')),
  started_at timestamptz,
  settled_at timestamptz,
  created_at timestamptz not null default now(),
  unique (agent_run_id,attempt)
);
create index agent_run_spend_run_status_idx on public.agent_run_spend_reservations(agent_run_id,status,created_at desc);
create index agent_run_spend_expense_idx on public.agent_run_spend_reservations(expense_id);
alter table public.agent_run_spend_reservations enable row level security;
revoke all on public.agent_run_spend_reservations from public, anon, authenticated, service_role;

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
      and r.trigger_type='founder_proposal' and r.lease_expires_at >= now()
    for update;
  if not found then raise exception 'agent run lease is invalid or expired' using errcode = '42501'; end if;
  select * into agent_row from public.agents a where a.id=run_row.agent_id and a.active;
  select * into project_row from public.projects p where p.id=run_row.project_id;
  if agent_row.id is null or project_row.id is null then
    raise exception 'agent spend requires an active agent and project' using errcode = '42501';
  end if;
  if project_row.status not in ('proposed','approved','active') then
    raise exception 'project is not eligible for agent review spend' using errcode = '42501';
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
    'hermes:'||p_provider,
    'Bounded Hermes review for '||agent_row.slug||' ('||left(p_model,160)||')',p_amount,'EUR');
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

create or replace function public.sutra_begin_agent_run_spend(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_reservation_id uuid
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare run_row public.agent_runs%rowtype; reservation_row public.agent_run_spend_reservations%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null or p_reservation_id is null then
    raise exception 'malformed agent spend start request' using errcode = '22023';
  end if;
  select * into run_row from public.agent_runs r where r.id=p_run_id and r.status='running'
    and r.lease_token=p_lease_token and r.lease_expires_at >= now() for update;
  if not found then raise exception 'agent run lease is invalid or expired' using errcode = '42501'; end if;
  select * into reservation_row from public.agent_run_spend_reservations s
    where s.id=p_reservation_id and s.agent_run_id=p_run_id for update;
  if not found or reservation_row.status <> 'reserved' then
    raise exception 'agent model spend is not approved and reserved' using errcode = '42501';
  end if;
  update public.agent_run_spend_reservations set status='started',started_at=now() where id=reservation_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'agent_run.model_call_started','agent_run_spend_reservation',reservation_row.id::text,
      jsonb_build_object('run_id',p_run_id,'provider',reservation_row.provider,'model',reservation_row.model,
        'reserved_amount',reservation_row.reserved_amount));
  return jsonb_build_object('status','started','reservation_id',reservation_row.id,
    'provider',reservation_row.provider,'model',reservation_row.model,'reserved_amount',reservation_row.reserved_amount);
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

create or replace function public.sutra_release_approved_model_run()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if old.status='requested' and new.status='approved' then
    update public.agent_run_spend_reservations s set status='reserved'
      from public.agent_runs r where s.expense_id=new.id and s.status='awaiting_approval'
        and r.id=s.agent_run_id and r.status='blocked'
        and r.output->>'blocked_by'='model_spend_approval';
    update public.agent_runs r set status='queued',finished_at=null,
      output=jsonb_build_object('spend_approval','approved')
      where r.status='blocked' and r.output->>'blocked_by'='model_spend_approval'
        and exists(select 1 from public.agent_run_spend_reservations s
          where s.agent_run_id=r.id and s.expense_id=new.id and s.status='reserved');
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      select 'system','sutra','agent_run.spend_approval_resumed','agent_run',r.id::text,
        jsonb_build_object('expense_id',new.id,'approval_id',a.id)
      from public.agent_runs r join public.agent_run_spend_reservations s on s.agent_run_id=r.id
      left join public.approvals a on a.expense_id=new.id
      where s.expense_id=new.id and s.status='reserved';
  elsif old.status='requested' and new.status in ('rejected','void') then
    update public.agent_run_spend_reservations set status='rejected',settled_at=now()
      where expense_id=new.id and status='awaiting_approval';
    update public.agent_runs r set status='blocked',finished_at=now(),lease_token=null,lease_expires_at=null,
      output=jsonb_build_object('blocked_by','model_spend_rejected','expense_id',new.id)
      where r.id in (select s.agent_run_id from public.agent_run_spend_reservations s
        where s.expense_id=new.id and s.status='rejected');
  end if;
  return new;
end;
$$;
create trigger expenses_resume_approved_model_run after update of status on public.expenses
  for each row execute function public.sutra_release_approved_model_run();

create or replace function public.sutra_require_reconciled_agent_spend()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.status='succeeded' and old.status is distinct from new.status
    and new.trigger_type='founder_proposal'
    and not exists(select 1 from public.agent_run_spend_reservations s
      where s.agent_run_id=new.id and s.status='reconciled') then
    raise exception 'agent run cannot succeed without reconciled model spend' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger agent_runs_require_reconciled_spend before update of status on public.agent_runs
  for each row execute function public.sutra_require_reconciled_agent_spend();

revoke all on function public.sutra_reserve_agent_run_spend(text,uuid,uuid,text,text,numeric) from public,anon,authenticated;
revoke all on function public.sutra_begin_agent_run_spend(text,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.sutra_reconcile_agent_run_spend(text,uuid,uuid,uuid,text,text,numeric,bigint,bigint,jsonb,boolean) from public,anon,authenticated;
revoke all on function public.sutra_release_approved_model_run() from public,anon,authenticated,service_role;
revoke all on function public.sutra_require_reconciled_agent_spend() from public,anon,authenticated,service_role;
grant execute on function public.sutra_reserve_agent_run_spend(text,uuid,uuid,text,text,numeric) to service_role;
grant execute on function public.sutra_begin_agent_run_spend(text,uuid,uuid,uuid) to service_role;
grant execute on function public.sutra_reconcile_agent_run_spend(text,uuid,uuid,uuid,text,text,numeric,bigint,bigint,jsonb,boolean) to service_role;

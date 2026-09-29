-- Permit one founder-authorized final recovery attempt only for a terminal PM
-- artifact-schema failure. All provider calls still use a fresh spend reservation.
alter table public.agent_runs drop constraint agent_runs_attempt_count_valid_check;
alter table public.agent_runs add constraint agent_runs_attempt_count_valid_check
  check (attempt_count between 0 and 3 or (
    attempt_count = 4 and trigger_type = 'founder_proposal' and run_order = 5
  ));

create or replace function public.sutra_claim_agent_run(p_worker_id text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  run_row public.agent_runs%rowtype;
  agent_row public.agents%rowtype;
  project_row public.projects%rowtype;
  prior_results jsonb;
  policy_rows jsonb;
  budget_rows jsonb;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode = '22023';
  end if;

  with expired as (
    update public.agent_runs r
      set status = 'failed', finished_at = now(), lease_token = null, lease_expires_at = null,
          output = coalesce(r.output, '{}'::jsonb) || jsonb_build_object('failure', 'worker_lease_expired_after_max_attempts')
      where r.trigger_type = 'founder_proposal' and r.status = 'running'
        and r.lease_expires_at < now() and r.attempt_count >= 3
      returning r.id, r.project_id
  )
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    select 'system',p_worker_id,'agent_run.lease_exhausted','agent_run',expired.id::text,
      jsonb_build_object('project_id',expired.project_id)
    from expired;

  select r.* into run_row
  from public.agent_runs r
  join public.agents queued_agent on queued_agent.id = r.agent_id
  where r.trigger_type = 'founder_proposal'
    and (r.attempt_count < 3 or (
      r.attempt_count = 3 and queued_agent.slug = 'product_manager'
      and r.output->>'founder_pm_recovery' = 'requested'
    ))
    and (r.status = 'queued' or (r.status = 'running' and r.lease_expires_at < now()))
    and not exists (
      select 1 from public.agent_runs earlier
      where earlier.project_id = r.project_id
        and earlier.trigger_type = 'founder_proposal'
        and earlier.run_order < r.run_order
        and earlier.status <> 'succeeded'
    )
  order by r.created_at, r.project_id, r.run_order
  limit 1 for update of r skip locked;
  if not found then return null; end if;

  update public.agent_runs r set status = 'running', attempt_count = r.attempt_count + 1,
      started_at = coalesce(r.started_at, now()), finished_at = null,
      lease_token = gen_random_uuid(), lease_expires_at = now() + interval '10 minutes'
    where r.id = run_row.id returning r.* into run_row;
  select * into agent_row from public.agents where id = run_row.agent_id and active;
  select * into project_row from public.projects where id = run_row.project_id;
  if agent_row.id is null or project_row.id is null then
    update public.agent_runs set status = 'failed', finished_at = now(), lease_token = null, lease_expires_at = null,
      output = jsonb_build_object('failure','inactive_agent_or_missing_project') where id = run_row.id;
    raise exception 'queued agent run has no active agent or project' using errcode = '23514';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('role',a.slug,'output',r.output) order by r.run_order),'[]'::jsonb)
    into prior_results
    from public.agent_runs r join public.agents a on a.id=r.agent_id
    where r.project_id=run_row.project_id and r.trigger_type='founder_proposal'
      and r.status='succeeded' and r.run_order < run_row.run_order;
  select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'min_amount',p.min_amount,'max_amount',p.max_amount,
      'min_inclusive',p.min_inclusive,'max_inclusive',p.max_inclusive,'approvers',p.required_approvers,
      'per_transaction_limit',p.per_transaction_limit,'daily_limit',p.daily_limit,'monthly_limit',p.monthly_limit,
      'warning_percent',p.warning_percent,'hard_stop',p.hard_stop) order by p.min_amount),'[]'::jsonb)
    into policy_rows from public.spending_policies p where p.active and p.currency=project_row.currency;
  select coalesce(jsonb_agg(jsonb_build_object('scope',b.scope,'scope_key',b.scope_key,'period',b.period,
      'limit_amount',b.limit_amount,'warning_percent',b.warning_percent,'hard_stop',b.hard_stop) order by b.scope,b.period),'[]'::jsonb)
    into budget_rows from public.budgets b where b.active and b.currency=project_row.currency
      and (b.scope_key='*' or (b.scope='project' and b.scope_key=project_row.id::text));
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',p_worker_id,'agent_run.claimed','agent_run',run_row.id::text,
      jsonb_build_object('project_id',run_row.project_id,'role',agent_row.slug,'attempt',run_row.attempt_count));
  return jsonb_build_object(
    'run_id',run_row.id,'lease_token',run_row.lease_token,'attempt',run_row.attempt_count,
    'sequence',run_row.run_order,'agent',jsonb_build_object('id',agent_row.id,'slug',agent_row.slug,'display_name',agent_row.display_name,'responsibilities',agent_row.responsibilities),
    'project',jsonb_build_object('id',project_row.id,'name',project_row.name,'description',project_row.description,
      'requested_budget',project_row.requested_budget,'currency',project_row.currency),
    'input',run_row.input,'prior_results',prior_results,'spending_policies',policy_rows,'applicable_budgets',budget_rows
  );
end;
$$;

create or replace function public.sutra_founder_retry_pm_review(
  p_founder_telegram_user_id text,
  p_run_id uuid
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  founder_id text;
  run_row public.agent_runs%rowtype;
  approval_row public.approvals%rowtype;
  role_slug text;
  prior_review_count integer;
  unknown_reservation_count integer;
  prior_error text;
  prior_detail text;
  final_recovery boolean;
  project_ref uuid;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_run_id is null then
    raise exception 'malformed PM review retry request' using errcode = '22023';
  end if;

  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the founder can retry a PM review' using errcode = '42501';
  end if;

  select project_id into project_ref from public.agent_runs where id=p_run_id;
  if project_ref is null then
    raise exception 'PM review run does not exist' using errcode = '42501';
  end if;

  select * into approval_row from public.approvals
    where approval_type='project_budget' and status='pending'
      and decisions #>> '{cfo,decision}'='approve'
      and project_id=project_ref
    order by created_at limit 1 for update;
  if not found then
    raise exception 'PM retry requires a pending project approval with CFO review complete' using errcode = '42501';
  end if;

  select * into run_row from public.agent_runs where id=p_run_id for update;
  select a.slug into role_slug from public.agents a where a.id=run_row.agent_id;

  if run_row.trigger_type <> 'founder_proposal' or run_row.run_order <> 5
    or role_slug <> 'product_manager' or run_row.status <> 'failed'
    or run_row.lease_token is not null or run_row.lease_expires_at is not null then
    raise exception 'PM retry is allowed only for a terminal failed PM review' using errcode = '42501';
  end if;

  prior_error := run_row.output->>'error_code';
  prior_detail := run_row.output->>'failure_detail_code';
  final_recovery := run_row.attempt_count = 3
    and prior_error = 'invalid_agent_output'
    and prior_detail = 'invalid_artifact_schema'
    and run_row.output->>'usage_state' = 'reconciled'
    and run_row.output->>'founder_pm_recovery' is distinct from 'requested';

  if not final_recovery and run_row.attempt_count not between 1 and 2 then
    raise exception 'PM retry limit is exhausted; final recovery is limited to one reconciled artifact-schema failure' using errcode = '42501';
  end if;
  if not final_recovery and (prior_error is null or prior_error not in ('unknown_or_overrun_spend','unknown_spend','invalid_agent_output')) then
    raise exception 'PM retry requires a recognized recoverable worker failure' using errcode = '42501';
  end if;

  select count(*) into prior_review_count from public.agent_runs r
    where r.project_id=run_row.project_id and r.trigger_type='founder_proposal'
      and r.run_order between 1 and 4 and r.status='succeeded';
  if prior_review_count <> 4 then
    raise exception 'PM retry requires CEO, Product, CTO, and CFO reviews to remain complete' using errcode = '42501';
  end if;

  select count(*) into unknown_reservation_count from public.agent_run_spend_reservations s
    where s.agent_run_id=run_row.id and s.status='unknown';

  update public.agent_runs set status='queued', finished_at=null, lease_token=null, lease_expires_at=null,
      output=case when final_recovery
        then jsonb_build_object('founder_pm_recovery','requested','prior_error_code',prior_error,
          'prior_failure_detail_code',prior_detail,'unknown_reservations_preserved',true)
        else jsonb_build_object('founder_retry','requested') end
    where id=run_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,
      case when final_recovery then 'founder.pm_review_final_recovery_requested' else 'founder.pm_review_retry_requested' end,
      'agent_run',run_row.id::text,
      jsonb_build_object('project_id',run_row.project_id,'attempt_count',run_row.attempt_count,
        'previous_error_code',prior_error,'previous_failure_detail_code',prior_detail,
        'unknown_reservations_preserved',true,'new_project_spending_authorized',false,
        'final_recovery_attempt',final_recovery));
  return jsonb_build_object('run_id',run_row.id,'status','queued',
    'attempts_remaining',case when final_recovery then 1 else 3-run_row.attempt_count end,
    'final_recovery_attempt',final_recovery,'project_spend_authorized',false,
    'preserved_unknown_reservations',unknown_reservation_count);
end;
$$;

revoke all on function public.sutra_claim_agent_run(text) from public, anon, authenticated;
grant execute on function public.sutra_claim_agent_run(text) to service_role;
revoke all on function public.sutra_founder_retry_pm_review(text,uuid) from public, anon, authenticated;
grant execute on function public.sutra_founder_retry_pm_review(text,uuid) to service_role;

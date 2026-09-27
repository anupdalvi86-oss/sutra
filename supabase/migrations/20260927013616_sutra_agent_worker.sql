-- Durable, leased execution for the founder proposal review pipeline.
alter table public.agent_runs add column if not exists run_order integer;
alter table public.agent_runs add column if not exists lease_token uuid;
alter table public.agent_runs add column if not exists lease_expires_at timestamptz;
alter table public.agent_runs add column if not exists attempt_count integer not null default 0;

with ranked as (
  select id, row_number() over (partition by project_id order by created_at, id)::integer as sequence_no
  from public.agent_runs
  where trigger_type = 'founder_proposal'
)
update public.agent_runs r set run_order = ranked.sequence_no
from ranked where r.id = ranked.id and r.run_order is null;

alter table public.agent_runs add constraint agent_runs_run_order_positive_check
  check (run_order is null or run_order > 0);
alter table public.agent_runs add constraint agent_runs_attempt_count_valid_check
  check (attempt_count between 0 and 3);
create unique index if not exists agent_runs_project_sequence_unique
  on public.agent_runs(project_id, run_order)
  where trigger_type = 'founder_proposal' and run_order is not null;
create index if not exists agent_runs_worker_queue_idx
  on public.agent_runs(status, lease_expires_at, created_at)
  where trigger_type = 'founder_proposal';

create or replace function public.sutra_assign_agent_run_order()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.trigger_type = 'founder_proposal' and new.run_order is null then
    select coalesce(max(r.run_order), 0) + 1 into new.run_order
      from public.agent_runs r where r.project_id = new.project_id and r.trigger_type = 'founder_proposal';
  end if;
  return new;
end;
$$;
create trigger agent_runs_assign_sequence_before_insert
  before insert on public.agent_runs
  for each row execute function public.sutra_assign_agent_run_order();

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

  -- A crashed worker may be retried at most three times. Exhausted leases are
  -- made terminal and audited so they cannot silently block the project queue.
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
  where r.trigger_type = 'founder_proposal'
    and r.attempt_count < 3
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

create or replace function public.sutra_complete_agent_run(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_outcome text,p_output jsonb,p_error_code text default null
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  run_row public.agent_runs%rowtype;
  agent_row public.agents%rowtype;
  final_status text;
  approval_id uuid;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_run_id is null or p_lease_token is null
    or p_outcome is null or p_outcome not in ('succeeded','retry','failed','blocked')
    or p_output is null or jsonb_typeof(p_output) <> 'object' or octet_length(p_output::text) > 24000
    or (p_error_code is not null and p_error_code !~ '^[a-z0-9_]{1,64}$') then
    raise exception 'malformed agent run completion' using errcode = '22023';
  end if;
  select * into run_row from public.agent_runs r
    where r.id=p_run_id and r.status='running' and r.lease_token=p_lease_token for update;
  if not found or run_row.lease_expires_at < now() then
    raise exception 'agent run lease is invalid or expired' using errcode = '42501';
  end if;
  select * into agent_row from public.agents where id=run_row.agent_id and active;
  if agent_row.id is null then raise exception 'agent is no longer active' using errcode = '42501'; end if;

  if p_outcome='succeeded' then
    if jsonb_typeof(p_output->'summary') is distinct from 'string' or length(trim(p_output->>'summary')) not between 8 and 5000
      or jsonb_typeof(p_output->'recommendation') is distinct from 'string' or length(trim(p_output->>'recommendation')) not between 2 and 5000
      or jsonb_typeof(p_output->'evidence') is distinct from 'array'
      or case when jsonb_typeof(p_output->'evidence') = 'array' then jsonb_array_length(p_output->'evidence') > 10 else false end then
      raise exception 'agent output is missing required bounded artifact fields' using errcode = '22023';
    end if;
    if agent_row.slug='cpo' and jsonb_array_length(p_output->'evidence')=0 then
      raise exception 'product research must include at least one evidence item' using errcode = '22023';
    end if;
    if agent_row.slug='cfo' and ((p_output->>'decision' is distinct from 'approve' and p_output->>'decision' is distinct from 'reject')
      or length(coalesce(p_output->>'decision_rationale','')) < 8) then
      raise exception 'CFO review must include an explicit decision and rationale' using errcode = '22023';
    end if;
  end if;

  final_status := case
    when p_outcome='retry' and run_row.attempt_count < 3 then 'queued'
    when p_outcome='retry' then 'failed'
    else p_outcome
  end;
  update public.agent_runs r set status=final_status,
      output=case when p_outcome='succeeded' then p_output
        else p_output || jsonb_build_object('error_code',coalesce(p_error_code,'worker_failure')) end,
      finished_at=case when final_status='queued' then null else now() end,
      lease_token=null,lease_expires_at=null
    where r.id=run_row.id;

  if p_outcome='succeeded' and agent_row.slug='cfo' then
    select ap.id into approval_id from public.approvals ap
      where ap.project_id=run_row.project_id and ap.approval_type='project_budget'
        and ap.status='pending' and 'cfo'=any(ap.required_roles)
      order by ap.created_at limit 1 for update;
    if approval_id is not null then
      perform public.sutra_decide_role_approval(
        approval_id,agent_row.id::text,'cfo',p_output->>'decision',left(p_output->>'decision_rationale',2000)
      );
    end if;
    if p_output->>'decision'='reject' then
      update public.agent_runs r set status='blocked',finished_at=now(),lease_token=null,lease_expires_at=null,
        output=jsonb_build_object('blocked_by','cfo_review_rejected')
        where r.project_id=run_row.project_id and r.trigger_type='founder_proposal'
          and r.run_order > run_row.run_order and r.status='queued';
    end if;
  end if;

  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',agent_row.id::text,'agent_run.'||final_status,'agent_run',run_row.id::text,
      jsonb_build_object('project_id',run_row.project_id,'role',agent_row.slug,'attempt',run_row.attempt_count,
        'artifact_summary',left(coalesce(p_output->>'summary',p_error_code,'worker failed'),500)));
  return jsonb_build_object('run_id',run_row.id,'status',final_status,'attempt',run_row.attempt_count,'approval_id',approval_id);
end;
$$;

create or replace function public.sutra_guard_project_budget_founder_approval()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare cfo_approved boolean; all_reviews_complete boolean;
begin
  if new.status='approved' and old.status is distinct from new.status
    and new.approval_type='project_budget' and new.project_id is not null then
    select coalesce(new.decisions #>> '{cfo,decision}'='approve',false) into cfo_approved;
    select count(*)=5 into all_reviews_complete from public.agent_runs r
      where r.project_id=new.project_id and r.trigger_type='founder_proposal'
        and r.run_order between 1 and 5 and r.status='succeeded';
    if not cfo_approved or not all_reviews_complete then
      raise exception 'founder approval is gated on completed CEO, Product, CTO, CFO, and PM reviews' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger approvals_require_completed_company_reviews
  before update of status on public.approvals
  for each row execute function public.sutra_guard_project_budget_founder_approval();

revoke all on function public.sutra_assign_agent_run_order() from public, anon, authenticated, service_role;
revoke all on function public.sutra_claim_agent_run(text) from public, anon, authenticated;
revoke all on function public.sutra_complete_agent_run(text,uuid,uuid,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.sutra_guard_project_budget_founder_approval() from public, anon, authenticated, service_role;
grant execute on function public.sutra_claim_agent_run(text) to service_role;
grant execute on function public.sutra_complete_agent_run(text,uuid,uuid,text,jsonb,text) to service_role;

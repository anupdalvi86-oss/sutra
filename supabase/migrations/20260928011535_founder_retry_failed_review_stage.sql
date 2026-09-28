create or replace function public.sutra_founder_retry_agent_review(
  p_founder_telegram_user_id text,
  p_run_id uuid
) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  founder_id text;
  run_row public.agent_runs%rowtype;
  approval_row public.approvals%rowtype;
  role_slug text;
  expected_role text;
  run_project_id uuid;
  prior_review_count integer;
  unknown_reservation_count integer;
  prior_error text;
  prior_detail text;
  run_found boolean;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_run_id is null then
    raise exception 'malformed agent review retry request' using errcode = '22023';
  end if;

  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the founder can retry an agent review' using errcode = '42501';
  end if;

  select project_id into run_project_id from public.agent_runs where id=p_run_id;
  if not found or run_project_id is null then
    raise exception 'agent review is not eligible for retry' using errcode = '42501';
  end if;
  -- Match the existing proposal retry lock order and require the approval to remain pending.
  select * into approval_row from public.approvals
    where approval_type='project_budget' and status='pending'
      and project_id=run_project_id
    order by created_at limit 1 for update;
  if not found then
    raise exception 'review retry requires a pending project approval' using errcode = '42501';
  end if;

  select * into run_row from public.agent_runs where id=p_run_id for update;
  run_found := found;
  select a.slug into role_slug from public.agents a where a.id=run_row.agent_id;
  if not run_found or not found then
    raise exception 'agent review is not eligible for retry' using errcode = '42501';
  end if;
  expected_role := case run_row.run_order
    when 1 then 'ceo' when 2 then 'cpo' when 3 then 'cto' when 4 then 'cfo' else null end;
  if run_row.project_id <> run_project_id
    or run_row.trigger_type <> 'founder_proposal'
    or expected_role is null or role_slug <> expected_role
    or run_row.status <> 'failed'
    or run_row.attempt_count not between 1 and 2
    or run_row.finished_at is null
    or run_row.lease_token is not null
    or run_row.lease_expires_at is not null then
    raise exception 'retry requires a failed, bounded CEO/CPO/CTO/CFO review stage' using errcode = '42501';
  end if;

  prior_error := run_row.output->>'error_code';
  prior_detail := run_row.output->>'failure_detail_code';
  if prior_error is null or prior_error not in ('unknown_or_overrun_spend','unknown_spend','invalid_agent_output') then
    raise exception 'retry requires a recognized recoverable worker failure' using errcode = '42501';
  end if;

  select count(*) into prior_review_count from public.agent_runs r
    where r.project_id=run_row.project_id and r.trigger_type='founder_proposal'
      and r.run_order < run_row.run_order and r.status='succeeded';
  if prior_review_count <> run_row.run_order - 1 then
    raise exception 'review retry requires all earlier proposal reviews to remain complete' using errcode = '42501';
  end if;

  select count(*) into unknown_reservation_count from public.agent_run_spend_reservations s
    where s.agent_run_id=run_row.id and s.status='unknown';

  update public.agent_runs set status='queued', finished_at=null, lease_token=null, lease_expires_at=null,
      output=jsonb_build_object('founder_retry','requested')
    where id=run_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.agent_review_retry_requested','agent_run',run_row.id::text,
      jsonb_build_object('project_id',run_row.project_id,'review_role',role_slug,
        'attempt_count',run_row.attempt_count,'previous_error_code',prior_error,
        'previous_failure_detail_code',prior_detail,'unknown_reservations_preserved',true,
        'new_project_spending_authorized',false));
  return jsonb_build_object('run_id',run_row.id,'review_role',role_slug,'status','queued',
    'attempts_remaining',3-run_row.attempt_count,'project_spend_authorized',false,
    'preserved_unknown_reservations',unknown_reservation_count);
end;
$$;

revoke all on function public.sutra_founder_retry_agent_review(text,uuid) from public, anon, authenticated;
grant execute on function public.sutra_founder_retry_agent_review(text,uuid) to service_role;

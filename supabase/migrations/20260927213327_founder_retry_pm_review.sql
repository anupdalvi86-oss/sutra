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

  -- Lock the approval first, matching the founder decision path's lock order.
  select * into approval_row from public.approvals
    where approval_type='project_budget' and status='pending'
      and decisions #>> '{cfo,decision}'='approve'
      and project_id=(select project_id from public.agent_runs where id=p_run_id)
    order by created_at limit 1 for update;
  if not found then
    raise exception 'PM retry requires a pending project approval with CFO review complete' using errcode = '42501';
  end if;

  select r.* into run_row from public.agent_runs r
    where r.id=p_run_id for update;
  select a.slug into role_slug from public.agents a where a.id=run_row.agent_id;
  if not found
    or run_row.trigger_type <> 'founder_proposal'
    or run_row.run_order <> 5
    or role_slug <> 'product_manager'
    or run_row.status <> 'failed'
    or run_row.attempt_count not between 1 and 2
    or run_row.lease_token is not null
    or run_row.lease_expires_at is not null then
    raise exception 'PM retry is allowed only for a failed, bounded, terminal PM review' using errcode = '42501';
  end if;

  prior_error := run_row.output->>'error_code';
  prior_detail := run_row.output->>'failure_detail_code';
  if prior_error is null or prior_error not in ('unknown_or_overrun_spend','unknown_spend','invalid_agent_output') then
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
      output=jsonb_build_object('founder_retry','requested')
    where id=run_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.pm_review_retry_requested','agent_run',run_row.id::text,
      jsonb_build_object('project_id',run_row.project_id,'attempt_count',run_row.attempt_count,
        'previous_error_code',prior_error,'previous_failure_detail_code',prior_detail,
        'unknown_reservations_preserved',true,'new_project_spending_authorized',false));
  return jsonb_build_object('run_id',run_row.id,'status','queued',
    'attempts_remaining',3-run_row.attempt_count,'project_spend_authorized',false,
    'preserved_unknown_reservations',unknown_reservation_count);
end;
$$;

revoke all on function public.sutra_founder_retry_pm_review(text,uuid) from public, anon, authenticated;
grant execute on function public.sutra_founder_retry_pm_review(text,uuid) to service_role;

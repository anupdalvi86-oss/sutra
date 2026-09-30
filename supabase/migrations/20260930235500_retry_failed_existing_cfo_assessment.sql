-- Requeue only the founder-requested, CFO-only assessment for the same active
-- initiative. The failed attempt and all unknown reservations remain intact;
-- the worker must obtain a fresh standard reservation before another request.
create or replace function public.sutra_retry_existing_initiative_cfo_assessment(
  p_founder_telegram_user_id text,p_run_id uuid
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; run_row public.agent_runs%rowtype; project_row public.projects%rowtype;
  role_slug text; unknown_count integer;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_run_id is null then
    raise exception 'malformed initiative CFO retry request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder may recover an initiative CFO assessment' using errcode='42501';
  end if;
  select * into run_row from public.agent_runs where id=p_run_id for update;
  select a.slug into role_slug from public.agents a where a.id=run_row.agent_id;
  select * into project_row from public.projects where id=run_row.project_id for update;
  if not found or run_row.trigger_type<>'founder_proposal' or run_row.run_order<>1 or role_slug<>'cfo'
    or run_row.input->>'request' not like 'Founder-requested CFO-only all-in budget assessment of the existing initiative.%'
    or run_row.status<>'failed' or run_row.attempt_count not between 1 and 2
    or run_row.finished_at is null or run_row.lease_token is not null or run_row.lease_expires_at is not null
    or project_row.status not in ('active','proposed') or project_row.requested_budget<=0
    or project_row.currency<>'EUR' or project_row.budget_assessment_status<>'unassessed'
    or run_row.output->>'error_code' not in ('unknown_or_overrun_spend','unknown_spend','invalid_agent_output') then
    raise exception 'retry requires a bounded terminal failure of the same unassessed CFO-only initiative review' using errcode='42501';
  end if;
  select count(*) into unknown_count from public.agent_run_spend_reservations s
    where s.agent_run_id=run_row.id and s.status='unknown';
  if unknown_count=0 then
    raise exception 'CFO recovery requires preserved unknown provider usage from the prior attempt' using errcode='42501';
  end if;
  update public.agent_runs set status='queued',finished_at=null,lease_token=null,lease_expires_at=null,
    output=coalesce(output,'{}'::jsonb)||jsonb_build_object('automatic_retry','requested')
    where id=run_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system','sutra_standing_founder_mandate','initiative.cfo_assessment_retry_requested','agent_run',run_row.id::text,
      jsonb_build_object('project_id',run_row.project_id,'attempt_count',run_row.attempt_count,
        'previous_error_code',run_row.output->>'error_code','preserved_unknown_reservations',unknown_count,
        'same_budget_cap_eur',project_row.requested_budget,'new_spend_authority',false));
  return jsonb_build_object('run_id',run_row.id,'status','queued','attempts_remaining',3-run_row.attempt_count,
    'preserved_unknown_reservations',unknown_count,'budget_cap_eur',project_row.requested_budget);
end;
$$;
revoke all on function public.sutra_retry_existing_initiative_cfo_assessment(text,uuid) from public,anon,authenticated;
grant execute on function public.sutra_retry_existing_initiative_cfo_assessment(text,uuid) to service_role;

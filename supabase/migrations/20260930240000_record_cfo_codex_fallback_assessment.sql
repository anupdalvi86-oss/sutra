-- Allow an evidence-backed Codex CFO fallback only after the exact founder-
-- requested CFO-only run exhausts its three normal worker attempts. This does
-- not rewrite the failed run, alter the cap, release unknown usage or authorize
-- spending; the fallback method is stored in both project state and the audit.
create or replace function public.sutra_record_cfo_codex_fallback_assessment(
  p_founder_telegram_user_id text,p_project_id uuid,p_source_run_id uuid,p_assessment jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; project_row public.projects%rowtype; run_row public.agent_runs%rowtype;
  role_slug text; estimate jsonb; line_item jsonb; item jsonb; line_sum numeric(14,2); total numeric(14,2);
  recommendation text; decision text; unknown_count integer; assessment_status text;
begin
  if p_founder_telegram_user_id is null or p_project_id is null or p_source_run_id is null
    or p_assessment is null or jsonb_typeof(p_assessment)<>'object'
    or octet_length(p_assessment::text)>16000 then
    raise exception 'malformed CFO fallback assessment' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder may record a CFO fallback assessment' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||p_project_id::text));
  select * into project_row from public.projects where id=p_project_id for update;
  select * into run_row from public.agent_runs where id=p_source_run_id for update;
  select a.slug into role_slug from public.agents a where a.id=run_row.agent_id;
  if run_row.id is null or project_row.id is null or not found
    or run_row.project_id<>p_project_id or run_row.trigger_type<>'founder_proposal'
    or run_row.run_order<>1 or role_slug<>'cfo' or run_row.status<>'failed' or run_row.attempt_count<>3
    or run_row.finished_at is null or run_row.lease_token is not null or run_row.lease_expires_at is not null
    or run_row.input->>'request' not like 'Founder-requested CFO-only all-in budget assessment of the existing initiative.%'
    or run_row.output->>'error_code' not in ('unknown_or_overrun_spend','unknown_spend','invalid_agent_output')
    or project_row.status not in ('active','proposed') or project_row.currency<>'EUR'
    or project_row.requested_budget is null or project_row.requested_budget<=0
    or project_row.budget_assessment_status<>'unassessed' or project_row.legal_hold then
    raise exception 'fallback requires the same exhausted, terminal CFO-only run and a positive, unassessed, legally clear initiative' using errcode='42501';
  end if;
  if exists(select 1 from public.agent_runs r where r.project_id=p_project_id
      and r.trigger_type='founder_proposal' and r.id<>p_source_run_id) then
    raise exception 'CFO fallback cannot replace or bypass a multi-agent proposal review sequence' using errcode='42501';
  end if;
  select count(*) into unknown_count from public.agent_run_spend_reservations s
    where s.agent_run_id=p_source_run_id and s.status='unknown';
  if unknown_count<>3 then
    raise exception 'fallback requires all three unknown reservations to remain preserved' using errcode='42501';
  end if;
  if jsonb_typeof(p_assessment->'summary') is distinct from 'string'
    or length(trim(p_assessment->>'summary')) not between 8 and 5000
    or jsonb_typeof(p_assessment->'recommendation') is distinct from 'string'
    or length(trim(p_assessment->>'recommendation')) not between 2 and 5000
    or jsonb_typeof(p_assessment->'decision_rationale') is distinct from 'string'
    or length(trim(p_assessment->>'decision_rationale')) not between 8 and 2000 then
    raise exception 'CFO fallback summary, recommendation, or rationale is malformed' using errcode='22023';
  end if;
  decision:=p_assessment->>'decision';
  if decision is null or decision not in ('approve','reject') then raise exception 'CFO fallback decision is malformed' using errcode='22023'; end if;
  estimate:=p_assessment->'budget_estimate';
  if jsonb_typeof(estimate) is distinct from 'object'
    or jsonb_typeof(estimate->'estimated_total_eur') is distinct from 'number'
    or jsonb_typeof(estimate->'line_items') is distinct from 'array'
    or jsonb_array_length(estimate->'line_items') not between 1 and 10
    or estimate->>'recommended_action' not in ('proceed_within_cap','request_budget_increase','do_not_proceed','legal_escalation')
    or estimate->>'confidence' not in ('low','medium','high') then
    raise exception 'CFO fallback estimate is malformed' using errcode='22023';
  end if;
  for line_item in select value from jsonb_array_elements(estimate->'line_items') loop
    if jsonb_typeof(line_item) is distinct from 'object'
      or line_item->>'category' not in ('ai_model_usage','development','tools','infrastructure','hosting','marketing_ads','operations','contingency','other')
      or jsonb_typeof(line_item->'amount_eur') is distinct from 'number'
      or jsonb_typeof(line_item->'basis') is distinct from 'string'
      or (line_item->>'amount_eur')::numeric<0
      or length(trim(line_item->>'basis')) not between 8 and 500 then
      raise exception 'CFO fallback cost line is malformed' using errcode='22023';
    end if;
  end loop;
  select coalesce(sum((value->>'amount_eur')::numeric),0) into line_sum
    from jsonb_array_elements(estimate->'line_items');
  total:=(estimate->>'estimated_total_eur')::numeric;
  recommendation:=estimate->>'recommended_action';
  if total<0 or total>999999999999.99 or abs(total-line_sum)>0.01
    or (total>project_row.requested_budget and recommendation not in ('request_budget_increase','do_not_proceed','legal_escalation'))
    or (total<=project_row.requested_budget and recommendation='request_budget_increase') then
    raise exception 'CFO fallback total and recommendation must match the founder cap' using errcode='23514';
  end if;
  if jsonb_typeof(p_assessment->'evidence') is distinct from 'array'
    or jsonb_array_length(p_assessment->'evidence') not between 1 and 10 then
    raise exception 'CFO fallback assessment requires one to ten cited sources' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(p_assessment->'evidence') loop
    if jsonb_typeof(item) is distinct from 'object' or (select count(*) from jsonb_object_keys(item))<>3
      or jsonb_typeof(item->'source') is distinct from 'string' or length(trim(item->>'source')) not between 1 and 200
      or jsonb_typeof(item->'claim') is distinct from 'string' or length(trim(item->>'claim')) not between 1 and 1000
      or jsonb_typeof(item->'url') is distinct from 'string' or length(item->>'url')>2048
      or coalesce(item->>'url','') !~ '^https://[^[:space:]]+$' then
      raise exception 'CFO fallback citations require source, claim, and direct HTTPS URL' using errcode='22023';
    end if;
  end loop;
  assessment_status:=case when recommendation='request_budget_increase' then 'requires_increase'
    when recommendation='legal_escalation' then 'legal_escalation'
    when recommendation='do_not_proceed' or decision='reject' then 'not_recommended' else 'within_cap' end;
  update public.projects set budget_assessment=p_assessment->'budget_estimate'||jsonb_build_object(
      'assessment_method','codex_evidence_based_fallback_after_cfo_worker_exhaustion',
      'source_agent_run_id',p_source_run_id,'summary',left(p_assessment->>'summary',1000),
      'recommendation',left(p_assessment->>'recommendation',1000),'evidence',p_assessment->'evidence',
      'decision',decision,'decision_rationale',left(p_assessment->>'decision_rationale',1000)),
    budget_assessed_at=now(),budget_assessment_status=assessment_status,updated_at=now()
    where id=p_project_id;
  if assessment_status<>'within_cap' then
    update public.projects set status='paused',updated_at=now() where id=p_project_id;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent','codex_cfo_fallback','initiative.budget_assessed','project',p_project_id::text,
      jsonb_build_object('assessment_method','codex_evidence_based_fallback_after_cfo_worker_exhaustion',
        'source_agent_run_id',p_source_run_id,'estimated_total_eur',total,'cap_eur',project_row.requested_budget,
        'recommendation',recommendation,'confidence',estimate->>'confidence',
        'preserved_unknown_reservations',unknown_count,'budget_changed',false));
  return jsonb_build_object('project_id',p_project_id,'assessment_status',assessment_status,
    'estimated_total_eur',total,'cap_eur',project_row.requested_budget,
    'remaining_budget',project_row.requested_budget-total,'preserved_unknown_reservations',unknown_count);
end;
$$;
revoke all on function public.sutra_record_cfo_codex_fallback_assessment(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_record_cfo_codex_fallback_assessment(text,uuid,uuid,jsonb) to service_role;

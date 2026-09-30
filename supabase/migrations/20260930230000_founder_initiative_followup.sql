-- A follow-up stays within the existing founder-approved initiative and cap.
-- This RPC creates a durable PM task; it never changes or reserves a budget.
create or replace function public.sutra_founder_add_initiative_followup(
  p_founder_telegram_user_id text,p_project_id uuid,p_request text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  founder_id text;
  project_row public.projects%rowtype;
  pm_id uuid;
  objective_id uuid;
  task_id uuid;
  committed numeric(14,2);
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_project_id is null or p_request is null or length(trim(p_request)) not between 12 and 2000
    or p_request ~ '[[:cntrl:]]' then
    raise exception 'malformed initiative follow-up' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can add initiative work' using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||p_project_id::text));
  select * into project_row from public.projects p where p.id=p_project_id for update;
  if not found or project_row.status not in ('approved','active') then
    raise exception 'follow-up requires an approved active initiative' using errcode='42501';
  end if;
  if project_row.currency<>'EUR' or project_row.requested_budget is null or project_row.requested_budget<=0
    or project_row.budget_assessment_status<>'within_cap'
    or project_row.budget_assessment->>'recommended_action' is distinct from 'proceed_within_cap'
    or case when jsonb_typeof(project_row.budget_assessment->'estimated_total_eur')='number'
      then (project_row.budget_assessment->>'estimated_total_eur')::numeric>project_row.requested_budget
      else true end
    or not exists(select 1 from public.approvals a where a.project_id=p_project_id
      and a.approval_type='project_budget' and a.status='approved'
      and a.decisions #>> '{cfo,decision}'='approve') then
    raise exception 'follow-up requires a positive budget assessed within cap and approved by CFO' using errcode='23514';
  end if;
  if project_row.legal_hold or exists(select 1 from public.legal_escalations e
      where e.project_id=p_project_id and e.status='open') then
    raise exception 'legal hold or open legal escalation blocks new initiative work' using errcode='42501';
  end if;

  select id into pm_id from public.agents where slug='product_manager' and active;
  if pm_id is null then raise exception 'active Product Manager is unavailable' using errcode='23514'; end if;
  select id into objective_id from public.objectives where project_id=p_project_id and status='active'
    order by created_at desc,id limit 1;
  if objective_id is null then
    insert into public.objectives(project_id,title,description,success_metrics,status,owner_agent_id)
      values(p_project_id,'Founder follow-up: '||left(trim(p_request),120),trim(p_request),'[]'::jsonb,
        'active',pm_id) returning id into objective_id;
  end if;

  insert into public.tasks(project_id,objective_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(p_project_id,objective_id,'Founder follow-up: '||left(trim(p_request),140),trim(p_request),
      '["The Product Manager records a scoped plan and measurable acceptance criteria","All execution remains under the existing initiative budget and legal controls","Any paid action receives a fresh reservation under the existing shared spend policy"]'::jsonb,
      'product','ready',pm_id,pm_id) returning id into task_id;
  insert into public.decisions(project_id,agent_id,decision_type,summary,rationale,evidence)
    values(p_project_id,pm_id,'founder_initiative_followup',
      'Founder added follow-up work under the existing initiative budget',
      left(trim(p_request),2000),jsonb_build_array(jsonb_build_object(
        'task_id',task_id,'budget_preserved',project_row.requested_budget,'currency',project_row.currency)));
  select coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
      when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end),0)
    into committed from public.initiative_budget_ledger l where l.project_id=p_project_id
      and l.status in ('reserved','unknown','actual','overrun');
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'initiative.followup_task_created','task',task_id::text,
      jsonb_build_object('project_id',p_project_id,'objective_id',objective_id,
        'requested_budget',project_row.requested_budget,'currency',project_row.currency,
        'committed_before',committed,'budget_changed',false,'spend_reserved',false));
  return jsonb_build_object('status','created','task_id',task_id,'project_id',p_project_id,
    'objective_id',objective_id,'requested_budget',project_row.requested_budget,
    'remaining_budget',greatest(0,project_row.requested_budget-committed),
    'currency',project_row.currency,'budget_changed',false,'spend_reserved',false);
end;
$$;
revoke all on function public.sutra_founder_add_initiative_followup(text,uuid,text)
  from public,anon,authenticated;
grant execute on function public.sutra_founder_add_initiative_followup(text,uuid,text)
  to service_role;

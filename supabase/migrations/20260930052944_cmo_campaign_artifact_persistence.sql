-- Make internal CMO campaign plans queryable records without enabling delivery
-- or spending. The source task/artifact link makes the insert idempotent.
alter table public.campaigns
  add column source_task_id uuid references public.tasks(id) on delete restrict,
  add column source_artifact_id uuid references public.task_agent_artifacts(id) on delete restrict,
  add column created_by_agent_id uuid references public.agents(id) on delete restrict,
  add column updated_at timestamptz not null default now();
create unique index campaigns_source_task_unique_idx
  on public.campaigns(source_task_id) where source_task_id is not null;
create unique index campaigns_source_artifact_unique_idx
  on public.campaigns(source_artifact_id) where source_artifact_id is not null;
create index campaigns_project_status_idx
  on public.campaigns(project_id,status,created_at desc);

create or replace function public.sutra_validate_task_artifact(p_role text,p_artifact jsonb)
returns boolean language plpgsql immutable security invoker set search_path=pg_catalog,public as $$
declare field record; item jsonb; expected_fields text[]; value jsonb;
begin
  if p_artifact is null or jsonb_typeof(p_artifact)<>'object' or octet_length(p_artifact::text)>12000 then return false; end if;
  expected_fields:=case p_role
    when 'cpo' then array['customer_segments','competitors','buyer_workflows','market_gaps','pricing_signals']
    when 'product_manager' then array['scope','milestones','acceptance_criteria']
    when 'architect' then array['design','components','security_risks']
    when 'coo' then array['operational_dependencies','readiness_checklist','incident_plan']
    when 'devops' then array['deployment_steps','health_checks','rollback_steps']
    when 'cmo' then array['campaign_name','channel','audience','positioning','draft_copy','claims',
      'success_metrics','budget_amount_eur','budget_rationale']
    when 'sales' then array['ideal_customer_profile','lead_criteria','qualification_questions','first_contact_draft']
    when 'governance_audit' then array['controls_checked','findings','recommendation']
    else null end;
  if expected_fields is null then return false; end if;
  for field in select key,case
      when key=any(array['milestones','acceptance_criteria','components','security_risks',
        'operational_dependencies','readiness_checklist','deployment_steps','health_checks','rollback_steps',
        'claims','success_metrics','lead_criteria','qualification_questions','controls_checked','findings',
        'customer_segments','competitors','buyer_workflows','market_gaps','pricing_signals']) then 'array'
      when key='budget_amount_eur' then 'number' else 'string' end as value_type
    from unnest(expected_fields) as required(key)
  loop
    value:=p_artifact->field.key;
    if value is null or jsonb_typeof(value)<>field.value_type then return false; end if;
    if field.value_type='string' then
      if length(btrim(value#>>'{}'))<case when field.key='channel' then 3 else 8 end
        or length(btrim(value#>>'{}'))>case when field.key='campaign_name' then 160
          when field.key='channel' then 80 when field.key='budget_rationale' then 500 else 4000 end then
        return false;
      end if;
    elsif field.value_type='number' then
      if (value#>>'{}')::numeric<0 or (value#>>'{}')::numeric>999999999999.99
        or pg_catalog.round((value#>>'{}')::numeric,2)<>(value#>>'{}')::numeric then return false; end if;
    else
      if jsonb_array_length(value) not between 1 and 20 then return false; end if;
      for item in select element from jsonb_array_elements(value) as entries(element)
      loop
        if jsonb_typeof(item)<>'string' or length(btrim(item#>>'{}')) not between 1 and 1000 then return false; end if;
      end loop;
    end if;
  end loop;
  return true;
end
$$;
revoke all on function public.sutra_validate_task_artifact(text,jsonb) from public,anon,authenticated,service_role;

create function public.sutra_persist_cmo_campaign_draft()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; project_row public.projects%rowtype;
  agent_row public.agents%rowtype; plan jsonb; proposed_budget numeric;
  committed numeric(14,2); remaining numeric(14,2); campaign_id uuid;
  budget_fit text; campaign_state text;
begin
  if new.artifact_type<>'campaign_draft' then return new; end if;
  plan:=new.artifact->'artifact';
  if jsonb_typeof(plan) is distinct from 'object'
    or jsonb_typeof(plan->'campaign_name') is distinct from 'string'
    or length(btrim(plan->>'campaign_name')) not between 8 and 160
    or jsonb_typeof(plan->'channel') is distinct from 'string'
    or length(btrim(plan->>'channel')) not between 3 and 80
    or jsonb_typeof(plan->'budget_amount_eur') is distinct from 'number'
    or jsonb_typeof(plan->'budget_rationale') is distinct from 'string'
    or length(btrim(plan->>'budget_rationale')) not between 8 and 500 then
    raise exception 'CMO campaign plan is malformed' using errcode='22023';
  end if;
  proposed_budget:=(plan->>'budget_amount_eur')::numeric;
  if proposed_budget<0 or proposed_budget>999999999999.99
      or proposed_budget::text in ('NaN','Infinity','-Infinity')
      or pg_catalog.round(proposed_budget,2)<>proposed_budget then
    raise exception 'CMO campaign budget must be a non-negative EUR amount in cents' using errcode='22023';
  end if;
  select * into task_row from public.tasks where id=new.task_id;
  select * into agent_row from public.agents where id=new.agent_id and active and slug='cmo';
  select * into project_row from public.projects where id=task_row.project_id;
  if task_row.id is null or agent_row.id is null
      or new.agent_id is distinct from task_row.owner_agent_id
      or new.agent_id is distinct from task_row.assigned_agent_id
      or project_row.id is null then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('agent',coalesce(agent_row.id::text,new.agent_id::text),'marketing.campaign_draft_not_registered',
        'task_agent_artifact',new.id::text,pg_catalog.jsonb_build_object(
          'task_id',new.task_id,'project_id',task_row.project_id,'reason_code','task_or_initiative_not_active'));
    return new;
  end if;
  select coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
      when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end),0)
    into committed from public.initiative_budget_ledger l
    where l.project_id=project_row.id and l.status in ('reserved','unknown','actual','overrun');
  remaining:=greatest(project_row.requested_budget-committed,0);
  budget_fit:=case when project_row.status in ('approved','active')
      and project_row.budget_assessment_status='within_cap'
      and project_row.budget_assessment->>'recommended_action'='proceed_within_cap'
      and not project_row.legal_hold
      and not exists(select 1 from public.legal_escalations e
        where e.project_id=project_row.id and e.status='open')
      and proposed_budget<=remaining then 'within_cap' else 'requires_budget_or_legal_review' end;
  campaign_state:=case when budget_fit='within_cap' then 'draft' else 'approval_required' end;
  insert into public.campaigns(project_id,name,channel,status,budget_amount,currency,content,
      source_task_id,source_artifact_id,created_by_agent_id)
    values(project_row.id,btrim(plan->>'campaign_name'),btrim(plan->>'channel'),campaign_state,
      proposed_budget,'EUR',pg_catalog.jsonb_build_object(
        'audience',plan->>'audience','positioning',plan->>'positioning','draft_copy',plan->>'draft_copy',
        'claims',plan->'claims','success_metrics',plan->'success_metrics',
        'budget_rationale',plan->>'budget_rationale','proposed_budget_eur',proposed_budget,
        'budget_fit',budget_fit,'remaining_initiative_budget_eur',remaining,
        'delivery_started',false,'spend_reserved',false),
      new.task_id,new.id,new.agent_id)
    on conflict do nothing returning id into campaign_id;
  if campaign_id is not null then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('agent',agent_row.id::text,'marketing.campaign_draft_persisted','campaign',campaign_id::text,
        pg_catalog.jsonb_build_object('project_id',project_row.id,'task_id',task_row.id,
          'artifact_id',new.id,'budget_amount_eur',proposed_budget,
          'remaining_initiative_budget_eur',remaining,'budget_fit',budget_fit,
          'campaign_status',campaign_state,'external_delivery_started',false));
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_persist_cmo_campaign_draft() from public,anon,authenticated,service_role;
create trigger task_agent_artifacts_persist_cmo_campaign
  after insert on public.task_agent_artifacts
  for each row execute function public.sutra_persist_cmo_campaign_draft();

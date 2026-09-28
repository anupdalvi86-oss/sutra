-- Let the approved CPO research task flow through the same leased, spend-gated
-- artifact path as PM and other internal handoff roles.
alter table public.task_agent_artifacts
  drop constraint if exists task_agent_artifacts_artifact_type_check;
alter table public.task_agent_artifacts
  add constraint task_agent_artifacts_artifact_type_check check (artifact_type in (
    'market_research','product_plan','technical_design','operations_plan','release_plan',
    'campaign_draft','sales_handoff','governance_review'
  ));

create or replace function public.sutra_task_artifact_type(p_role text)
returns text language sql immutable security invoker set search_path=pg_catalog as $$
  select case p_role
    when 'cpo' then 'market_research'
    when 'product_manager' then 'product_plan'
    when 'architect' then 'technical_design'
    when 'coo' then 'operations_plan'
    when 'devops' then 'release_plan'
    when 'cmo' then 'campaign_draft'
    when 'sales' then 'sales_handoff'
    when 'governance_audit' then 'governance_review'
    else null end
$$;

create or replace function public.sutra_validate_task_artifact(p_role text,p_artifact jsonb)
returns boolean language plpgsql immutable security invoker set search_path=pg_catalog as $$
declare field record; item jsonb; expected_fields text[]; value jsonb;
begin
  if p_artifact is null or jsonb_typeof(p_artifact)<>'object' or octet_length(p_artifact::text)>12000 then return false; end if;
  expected_fields:=case p_role
    when 'cpo' then array['customer_segments','competitors','buyer_workflows','market_gaps','pricing_signals']
    when 'product_manager' then array['scope','milestones','acceptance_criteria']
    when 'architect' then array['design','components','security_risks']
    when 'coo' then array['operational_dependencies','readiness_checklist','incident_plan']
    when 'devops' then array['deployment_steps','health_checks','rollback_steps']
    when 'cmo' then array['audience','positioning','draft_copy','claims','success_metrics']
    when 'sales' then array['ideal_customer_profile','lead_criteria','qualification_questions','first_contact_draft']
    when 'governance_audit' then array['controls_checked','findings','recommendation']
    else null end;
  if expected_fields is null then return false; end if;
  for field in select key,case when key=any(array['milestones','acceptance_criteria','components','security_risks',
      'operational_dependencies','readiness_checklist','deployment_steps','health_checks','rollback_steps','claims',
      'success_metrics','lead_criteria','qualification_questions','controls_checked','findings',
      'customer_segments','competitors','buyer_workflows','market_gaps','pricing_signals'])
      then 'array' else 'string' end as value_type from unnest(expected_fields) as required(key)
  loop
    value:=p_artifact->field.key;
    if value is null or jsonb_typeof(value)<>field.value_type then return false; end if;
    if field.value_type='string' then
      if length(trim(value#>>'{}')) not between 8 and 4000 then return false; end if;
    else
      if jsonb_array_length(value) not between 1 and 20 then return false; end if;
      for item in select element from jsonb_array_elements(value) as entries(element)
      loop
        if jsonb_typeof(item)<>'string' or length(trim(item#>>'{}')) not between 1 and 1000 then return false; end if;
      end loop;
    end if;
  end loop;
  return true;
end
$$;

-- Patch only the supported-role allowlist in the latest claim function. The
-- guard fails closed if the expected current definition has changed.
do $$
declare function_sql text; old_allowlist text; old_order text;
begin
  function_sql:=pg_get_functiondef('public.sutra_claim_task_agent_run(text)'::regprocedure);
  old_allowlist:='a.slug in (''product_manager'',''architect'',''coo'',''devops'',''cmo'',''sales'',''governance_audit'')';
  old_order:='order by t.created_at,t.id limit 1 for update of t skip locked;';
  if position(old_allowlist in function_sql)=0
    or position(old_allowlist in substring(function_sql from
      position(old_allowlist in function_sql)+length(old_allowlist)))>0 then
    raise exception 'sutra_claim_task_agent_run role allowlist changed; update this migration before applying';
  end if;
  if position(old_order in function_sql)=0
    or position(old_order in substring(function_sql from
      position(old_order in function_sql)+length(old_order)))>0 then
    raise exception 'sutra_claim_task_agent_run ready-task ordering changed; update this migration before applying';
  end if;
  function_sql:=replace(function_sql,old_allowlist,
    'a.slug in (''cpo'',''product_manager'',''architect'',''coo'',''devops'',''cmo'',''sales'',''governance_audit'')');
  function_sql:=replace(function_sql,old_order,
    'order by case when a.slug=''cpo'' then 1 else 0 end,t.created_at,t.id limit 1 for update of t skip locked;');
  execute function_sql;
end $$;

create or replace function public.sutra_require_market_research_evidence()
returns trigger language plpgsql security invoker set search_path=pg_catalog,public as $$
declare item jsonb;
begin
  if new.artifact_type='market_research' then
    if jsonb_typeof(new.artifact->'evidence') is distinct from 'array' then
      raise exception 'CPO market research requires one to ten cited sources' using errcode='23514';
    end if;
    if jsonb_array_length(new.artifact->'evidence') not between 1 and 10 then
      raise exception 'CPO market research requires one to ten cited sources' using errcode='23514';
    end if;
    for item in select value from jsonb_array_elements(new.artifact->'evidence')
    loop
      if jsonb_typeof(item) is distinct from 'object' then
        raise exception 'CPO market research citations must be objects' using errcode='23514';
      end if;
      if (select count(*) from jsonb_object_keys(item))<>3
        or jsonb_typeof(item->'source') is distinct from 'string'
        or length(trim(item->>'source')) not between 1 and 200
        or jsonb_typeof(item->'url') is distinct from 'string'
        or length(item->>'url')>2048
        or coalesce(item->>'url','') !~ '^https://[^[:space:]]+$'
        or jsonb_typeof(item->'claim') is distinct from 'string'
        or length(trim(item->>'claim')) not between 1 and 1000 then
        raise exception 'CPO market research citations must contain a bounded source, HTTPS URL, and claim'
          using errcode='23514';
      end if;
    end loop;
  end if;
  return new;
end
$$;
revoke all on function public.sutra_require_market_research_evidence() from public,anon,authenticated,service_role;
create trigger task_agent_artifacts_require_market_research_evidence
  before insert or update on public.task_agent_artifacts
  for each row execute function public.sutra_require_market_research_evidence();

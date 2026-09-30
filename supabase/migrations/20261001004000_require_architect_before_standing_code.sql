-- Standalone standing-authority tasks enter the normal architecture -> code
-- gate. Developer work remains backlog until the Architect artifact releases it.
create or replace function public.sutra_founder_create_standing_code_task(
  p_founder_telegram_user_id text,p_title text,p_description text,p_acceptance_criteria jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; developer_id uuid; architect_id uuid; project_row public.projects%rowtype;
  authorization_row public.founder_code_authorizations%rowtype; developer_task_id uuid;
  architect_task_id uuid; project_approval_id uuid; estimate_text text; estimate_eur numeric;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_title is null or length(trim(p_title)) not between 8 and 200
    or p_description is null or length(trim(p_description)) not between 20 and 4000
    or p_acceptance_criteria is null or jsonb_typeof(p_acceptance_criteria)<>'array'
    or jsonb_array_length(p_acceptance_criteria) not between 1 and 12
    or (case when jsonb_typeof(p_acceptance_criteria)='array' then
      exists(select 1 from jsonb_array_elements(p_acceptance_criteria) as criterion(value)
        where jsonb_typeof(criterion.value)<>'string'
          or length(trim(criterion.value #>> '{}')) not between 1 and 500)
      else true end) then
    raise exception 'malformed standing-authorized Developer task' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can create the standing-authorized task' using errcode='42501';
  end if;
  select * into authorization_row from public.founder_code_authorizations
    where repository='anupdalvi86-oss/sutra' and active for update;
  if not found then raise exception 'standing code authorization is not active' using errcode='42501'; end if;
  select id into developer_id from public.agents where slug='developer' and active;
  select id into architect_id from public.agents where slug='architect' and active;
  if developer_id is null or architect_id is null then
    raise exception 'active Developer and Architect agents are required' using errcode='55000';
  end if;

  select * into project_row from public.projects where slug='sutra-operating-model' for update;
  if not found then
    insert into public.projects(name,description,status,owner_agent_id,budget_amount,budget_currency,
      created_at,updated_at,slug,requested_budget,currency,created_by)
      values('Sutra operating model implementation',
        'Founder-directed implementation of Sutra business operating capabilities. The initial all-in cap is EUR 0; paid work remains subject to a founder-approved initiative budget and the central spend policy.',
        'active',developer_id,0,'EUR',now(),now(),'sutra-operating-model',0,'EUR','founder:'||founder_id)
      returning * into project_row;
    insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
      decisions,amount,currency,summary,status,payload,decided_by,decided_at)
      values(project_row.id,'project_budget',project_row.id::text,'founder:'||founder_id,array['founder'],
        jsonb_build_object('founder',jsonb_build_object('decision','approve','comment','Founder directed zero-budget project; no spending authority.')),
        0,'EUR','Founder-directed Sutra implementation, zero-euro initial cap','approved',
        jsonb_build_object('all_in_budget',0,'currency','EUR','paid_work_allowed',false),
        'founder:'||founder_id,now()) returning id into project_approval_id;
  else
    if project_row.status is null or project_row.status not in ('active','approved')
      or project_row.legal_hold is distinct from false
      or project_row.budget_currency is distinct from 'EUR' or project_row.currency is distinct from 'EUR'
      or project_row.budget_amount is null or project_row.requested_budget is null
      or project_row.budget_amount<0 or project_row.requested_budget<>project_row.budget_amount then
      raise exception 'Sutra initiative is inactive, held, or has an invalid all-in budget; no task was created' using errcode='42501';
    end if;
    if project_row.budget_amount>0 then
      estimate_text:=project_row.budget_assessment->>'estimated_total_eur';
      if project_row.budget_assessment_status is distinct from 'within_cap'
        or project_row.budget_assessed_at is null
        or project_row.budget_assessment->>'recommended_action' is distinct from 'proceed_within_cap'
        or estimate_text is null or estimate_text !~ '^[0-9]+([.][0-9]{1,2})?$' then
        raise exception 'positive Sutra initiative budget requires a current within-cap assessment; no task was created' using errcode='42501';
      end if;
      estimate_eur:=estimate_text::numeric;
      if estimate_eur>project_row.budget_amount then
        raise exception 'Sutra initiative assessment exceeds its unchanged all-in cap; no task was created' using errcode='42501';
      end if;
      if exists(select 1 from public.legal_escalations
        where project_id=project_row.id and status='open') then
        raise exception 'Sutra initiative has an open legal escalation; no task was created' using errcode='42501';
      end if;
    end if;
    select id into project_approval_id from public.approvals where project_id=project_row.id
      and approval_type='project_budget' and status='approved' order by decided_at desc nulls last limit 1;
    if project_approval_id is null then
      raise exception 'Sutra initiative has no recorded founder project authorization; no task was created' using errcode='42501';
    end if;
  end if;

  insert into public.tasks(project_id,title,description,status,assigned_agent_id,owner_agent_id,priority,
      acceptance_criteria,task_type)
    values(project_row.id,left('Architecture design required: '||trim(p_title),200),
      left('Prepare a technical design before implementation. Do not change task scope, financial authority, or project budget. Developer scope: '
        ||trim(p_description)||' Acceptance criteria: '||p_acceptance_criteria::text,4000),
      'ready',architect_id,architect_id,1,
      '["Design covers the exact Developer scope","Components and interfaces are documented","Security risks and mitigations are explicit"]'::jsonb,
      'engineering') returning id into architect_task_id;
  insert into public.tasks(project_id,parent_task_id,title,description,status,assigned_agent_id,owner_agent_id,priority,
      acceptance_criteria,task_type)
    values(project_row.id,architect_task_id,trim(p_title),trim(p_description),'backlog',developer_id,developer_id,1,
      p_acceptance_criteria,'engineering') returning id into developer_task_id;
  insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
      decisions,amount,currency,summary,status,payload,decided_by,decided_at)
    values(project_row.id,'developer_scope',developer_task_id::text,'founder_standing_authorization',array['founder'],
      jsonb_build_object('founder',jsonb_build_object('decision','approve','comment','Standing repository authority; task remains gated on its Architect design.'),
        'standing_authorization',jsonb_build_object('authorization_id',authorization_row.id,'repository',authorization_row.repository,
          'capabilities',authorization_row.capabilities)),
      0,'EUR',left('Standing founder authorization: '||trim(p_title),500),'approved',
      jsonb_build_object('task_id',developer_task_id,'architect_task_id',architect_task_id,
        'repository',authorization_row.repository,'authorization_id',authorization_row.id,
        'project_all_in_cap_eur',project_row.budget_amount,
        'budget_assessment_status',project_row.budget_assessment_status,
        'technical_design_required',true,'spending_authority_changed',false),
      'founder:'||founder_id,now());
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.standing_code_task_created','task',developer_task_id::text,
      jsonb_build_object('project_id',project_row.id,'project_budget_eur',project_row.budget_amount,
        'budget_assessment_status',project_row.budget_assessment_status,'architect_task_id',architect_task_id,
        'developer_task_status','backlog','task_creation_cost_eur',0,'spending_authority_changed',false,
        'authorization_id',authorization_row.id,'scope_approval_recorded',true,
        'technical_design_required',true,'task_title',trim(p_title)));
  return jsonb_build_object('task_id',developer_task_id,'architect_task_id',architect_task_id,
    'project_id',project_row.id,'project_budget_eur',project_row.budget_amount,
    'project_budget_currency',project_row.budget_currency,
    'budget_assessment_status',project_row.budget_assessment_status,
    'project_approval_id',project_approval_id,'authorization_id',authorization_row.id,
    'spending_authority_changed',false,'status','backlog','waiting_for_architect',true);
end;
$$;
revoke all on function public.sutra_founder_create_standing_code_task(text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_founder_create_standing_code_task(text,text,text,jsonb) to service_role;

-- Rebase the one existing untouched fresh task created before the approved cap
-- and architecture gate were reflected in the founder-task RPC.
create or replace function public.sutra_founder_prepare_standing_code_task(
  p_founder_telegram_user_id text,p_task_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; task_row public.tasks%rowtype; project_row public.projects%rowtype;
  authorization_row public.founder_code_authorizations%rowtype; scope_row public.approvals%rowtype;
  developer_id uuid; architect_id uuid; architect_task_id uuid; estimate_text text; estimate_eur numeric;
  budget_context text; design_description text; revised_description text; revised_criteria jsonb;
  stale_criteria_count integer;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_task_id is null or p_reason is null or length(trim(p_reason)) not between 12 and 1000 then
    raise exception 'malformed standing-code task preparation request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can prepare the standing-authorized task' using errcode='42501';
  end if;
  select * into authorization_row from public.founder_code_authorizations
    where repository='anupdalvi86-oss/sutra' and active for update;
  if not found then raise exception 'standing code authorization is not active' using errcode='42501'; end if;
  select * into task_row from public.tasks where id=p_task_id for update;
  select id into developer_id from public.agents where slug='developer' and active;
  select id into architect_id from public.agents where slug='architect' and active;
  if task_row.id is null or developer_id is null or architect_id is null
    or task_row.task_type<>'engineering' or task_row.owner_agent_id<>developer_id
    or task_row.assigned_agent_id<>developer_id or task_row.status<>'in_progress'
    or task_row.parent_task_id is not null or task_row.project_id is null
    or position('The initiative all-in budget is EUR 0' in task_row.description)=0 then
    raise exception 'task is not the untouched stale-budget Developer task eligible for architecture preparation' using errcode='42501';
  end if;
  if exists(select 1 from public.agent_runs where task_id=task_row.id)
    or exists(select 1 from public.github_task_dispatches where task_id=task_row.id)
    or exists(select 1 from public.codex_task_executions where task_id=task_row.id)
    or exists(select 1 from public.task_agent_artifacts where task_id=task_row.id) then
    raise exception 'task has execution or usage history and cannot be rebased' using errcode='42501';
  end if;
  select * into scope_row from public.approvals where approval_type='developer_scope'
    and action_ref=task_row.id::text and project_id=task_row.project_id and status='approved' for update;
  if not found or scope_row.requested_by<>'founder_standing_authorization'
    or scope_row.decisions #>> '{standing_authorization,repository}'<>'anupdalvi86-oss/sutra'
    or scope_row.decisions #>> '{standing_authorization,authorization_id}'<>authorization_row.id::text then
    raise exception 'task does not carry this active standing repository authorization' using errcode='42501';
  end if;
  select * into project_row from public.projects where id=task_row.project_id for update;
  if project_row.slug<>'sutra-operating-model' or project_row.status not in ('active','approved')
    or project_row.legal_hold is distinct from false
    or project_row.budget_currency is distinct from 'EUR' or project_row.currency is distinct from 'EUR'
    or project_row.budget_amount is null or project_row.requested_budget is null
    or project_row.requested_budget<>project_row.budget_amount then
    raise exception 'Sutra initiative is inactive, held, or has an invalid all-in budget' using errcode='42501';
  end if;
  if project_row.budget_amount>0 then
    estimate_text:=project_row.budget_assessment->>'estimated_total_eur';
    if project_row.budget_assessment_status is distinct from 'within_cap'
      or project_row.budget_assessed_at is null
      or project_row.budget_assessment->>'recommended_action' is distinct from 'proceed_within_cap'
      or estimate_text is null or estimate_text !~ '^[0-9]+([.][0-9]{1,2})?$' then
      raise exception 'positive initiative budget requires a current within-cap assessment' using errcode='42501';
    end if;
    estimate_eur:=estimate_text::numeric;
    if estimate_eur>project_row.budget_amount then
      raise exception 'initiative assessment exceeds its unchanged all-in cap' using errcode='42501';
    end if;
    if exists(select 1 from public.legal_escalations where project_id=project_row.id and status='open') then
      raise exception 'Sutra initiative has an open legal escalation' using errcode='42501';
    end if;
  else
    estimate_eur:=0;
  end if;
  select count(*) into stale_criteria_count from jsonb_array_elements_text(task_row.acceptance_criteria) as c(value)
    where lower(c.value) like '%eur 0%' or lower(c.value) like '%zero-euro%';
  if stale_criteria_count<>1 then
    raise exception 'stale task budget acceptance criterion is ambiguous; no task was changed' using errcode='42501';
  end if;
  budget_context:=case when project_row.budget_amount>0 then
    format('This initiative has a founder-approved all-in cap of EUR %s and a recorded assessment of EUR %s within_cap. Provider usage must use this initiative shared ledger and existing monthly AI hard stop; never exceed or change the cap. ',
      to_char(project_row.budget_amount,'FM999999999990.00'),to_char(estimate_eur,'FM999999999990.00'))
    else 'This initiative has a zero-euro all-in cap; do not make provider calls or other paid commitments. ' end;
  revised_description:=regexp_replace(task_row.description,
    'The initiative all-in budget is EUR 0;[^.]*\.',budget_context,'g');
  if revised_description=task_row.description then
    raise exception 'stale task budget wording did not match the audited preparation rule' using errcode='42501';
  end if;
  revised_criteria:= (select jsonb_agg(to_jsonb(case
      when lower(c.value) like '%eur 0%' or lower(c.value) like '%zero-euro%'
        then format('Work remains within the founder-approved EUR %s all-in cap and configured monthly AI hard stop; preserve unknown reservations and never increase financial authority.',
          to_char(project_row.budget_amount,'FM999999999990.00'))
      else c.value end) order by c.ordinality)
    from jsonb_array_elements_text(task_row.acceptance_criteria) with ordinality as c(value,ordinality));
  design_description:=left(format('Prepare a technical design before implementation. Do not change the approved task scope or financial authority. Developer task: %s. Updated scope and budget context: %s. Acceptance criteria: %s',
    task_row.title,revised_description,revised_criteria::text),4000);
  insert into public.tasks(project_id,title,description,status,assigned_agent_id,owner_agent_id,priority,
      acceptance_criteria,task_type)
    values(project_row.id,left('Architecture design required: '||task_row.title,200),design_description,'ready',
      architect_id,architect_id,1,
      '["Design covers the exact Developer scope","Components and interfaces are documented","Security risks and mitigations are explicit"]'::jsonb,
      'engineering') returning id into architect_task_id;
  update public.tasks set status='backlog',parent_task_id=architect_task_id,
    description=revised_description,acceptance_criteria=revised_criteria,updated_at=now()
    where id=task_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.standing_code_task_prepared_for_architecture','task',task_row.id::text,
      jsonb_build_object('project_id',project_row.id,'architect_task_id',architect_task_id,
        'previous_status',task_row.status,'new_status','backlog','budget_cap_eur',project_row.budget_amount,
        'budget_assessment_status',project_row.budget_assessment_status,
        'estimated_total_eur',estimate_eur,'scope_approval_id',scope_row.id,
        'spending_authority_changed',false,'usage_or_reservations_changed',false,
        'reason',trim(p_reason),'previous_description',task_row.description,
        'previous_acceptance_criteria',task_row.acceptance_criteria,
        'new_description',revised_description,'new_acceptance_criteria',revised_criteria));
  return jsonb_build_object('task_id',task_row.id,'architect_task_id',architect_task_id,
    'status','backlog','waiting_for_architect',true,'project_budget_eur',project_row.budget_amount,
    'assessment_status',project_row.budget_assessment_status,
    'spending_authority_changed',false,'usage_or_reservations_changed',false);
end;
$$;
revoke all on function public.sutra_founder_prepare_standing_code_task(text,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_prepare_standing_code_task(text,uuid,text) to service_role;

-- Enrich a preapproved standing-authority scope record with the completed
-- Architect design before the Developer becomes claimable. If that expected
-- approval record is missing or has changed shape, leave the task blocked.
create or replace function public.sutra_release_child_tasks()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare child record; artifact_row public.task_agent_artifacts%rowtype; parent_slug text;
  authorization_id uuid; scope_approval_id uuid;
begin
  if old.status is distinct from new.status and new.status in ('done','deferred') then
    select slug into parent_slug from public.agents where id=new.assigned_agent_id and active;
    if new.status='deferred' and parent_slug not in ('qa','security') then return new; end if;
    for child in select t.id,t.project_id,t.title,t.description,a.slug as assigned_slug
      from public.tasks t left join public.agents a on a.id=t.assigned_agent_id
      where t.parent_task_id=new.id and t.project_id=new.project_id and t.status='backlog'
      for update of t
    loop
      if new.status='deferred' and not ((parent_slug='qa' and child.assigned_slug='security')
        or (parent_slug='security' and child.assigned_slug='devops')) then continue; end if;
      if child.assigned_slug='developer' and parent_slug='architect' and new.status='done' then
        select * into artifact_row from public.task_agent_artifacts
          where task_id=new.id and artifact_type='technical_design';
        update public.tasks set status='blocked',updated_at=now() where id=child.id;
        if artifact_row.id is null then
          insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
            values('system','sutra','developer.scope_gate_missing_design','task',child.id::text,
              jsonb_build_object('project_id',child.project_id,'architect_task_id',new.id));
        elsif public.sutra_has_standing_code_authorization() then
          select id into authorization_id from public.founder_code_authorizations
            where repository='anupdalvi86-oss/sutra' and active order by created_at desc limit 1;
          insert into public.approvals as current_approval(project_id,approval_type,action_ref,requested_by,required_roles,
              decisions,amount,currency,summary,status,payload,decided_by,decided_at)
            values(child.project_id,'developer_scope',child.id::text,'founder_standing_authorization',array['founder'],
              jsonb_build_object('founder',jsonb_build_object('decision','approve','comment','Standing founder repository authorization.'),
                'standing_authorization',jsonb_build_object('authorization_id',authorization_id,
                  'repository','anupdalvi86-oss/sutra')),
              0,'EUR',left('Standing founder code authorization: '||child.title,500),'approved',
              jsonb_build_object('task_id',child.id,'task_title',child.title,'task_description',child.description,
                'architect_task_id',new.id,'technical_design',artifact_row.artifact->'artifact',
                'authorization_id',authorization_id,'spending_authority_changed',false),
              'founder:standing-authorization',now())
            on conflict (action_ref) where approval_type='developer_scope' do update
              set payload=current_approval.payload||excluded.payload,summary=excluded.summary,decisions=excluded.decisions,
                status='approved',decided_by=excluded.decided_by,decided_at=excluded.decided_at
              where current_approval.requested_by='founder_standing_authorization'
                and current_approval.status='approved'
            returning id into scope_approval_id;
          if scope_approval_id is null then
            raise exception 'standing Developer scope record is missing or no longer approved';
          end if;
          update public.tasks set status='ready',updated_at=now() where id=child.id;
          insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
            values('system','sutra','developer.scope.standing_authorization_applied','task',child.id::text,
              jsonb_build_object('project_id',child.project_id,'architect_task_id',new.id,
                'authorization_id',authorization_id,'approval_id',scope_approval_id,
                'technical_design_present',true,'spending_authority_changed',false));
        else
          insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,amount,currency,summary,status,payload)
            values(child.project_id,'developer_scope',child.id::text,'system:architecture_scope_gate',array['founder'],0,'EUR',
              left('Founder scope review required before engineering: '||child.title||'. Design: '
                ||coalesce(artifact_row.artifact->'artifact'->>'design','')||'. Risks: '
                ||coalesce(artifact_row.artifact->'artifact'->>'security_risks',''),500),'pending',
              jsonb_build_object('task_id',child.id,'task_title',child.title,'task_description',child.description,
                'architect_task_id',new.id,'technical_design',artifact_row.artifact->'artifact')) on conflict (action_ref)
              where approval_type='developer_scope' do nothing returning id into scope_approval_id;
          insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
            values('system','sutra','developer.scope.approval_requested','task',child.id::text,
              jsonb_build_object('project_id',child.project_id,'architect_task_id',new.id,
                'approval_id',scope_approval_id));
        end if;
      else
        update public.tasks set status='ready',updated_at=now() where id=child.id;
      end if;
    end loop;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra',case when new.status='deferred' then 'task.deferred_review_children_released'
        else 'task.children_released' end,'task',new.id::text,
        jsonb_build_object('project_id',new.project_id,'parent_status',new.status,
          'internal_planning_only',new.status='deferred','release_authority_granted',false));
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_release_child_tasks() from public,anon,authenticated,service_role;

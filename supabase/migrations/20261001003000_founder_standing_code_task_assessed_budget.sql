-- Standing repository authority may create work under an existing, approved
-- initiative cap. Task creation never changes the cap or grants spending power.
create or replace function public.sutra_founder_create_standing_code_task(
  p_founder_telegram_user_id text,p_title text,p_description text,p_acceptance_criteria jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; developer_id uuid; project_row public.projects%rowtype;
  authorization_row public.founder_code_authorizations%rowtype; task_id uuid; project_approval_id uuid;
  estimate_text text; estimate_eur numeric;
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
  if developer_id is null then raise exception 'active Developer agent is missing' using errcode='55000'; end if;

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
    values(project_row.id,trim(p_title),trim(p_description),'in_progress',developer_id,developer_id,1,
      p_acceptance_criteria,'engineering') returning id into task_id;
  insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
      decisions,amount,currency,summary,status,payload,decided_by,decided_at)
    values(project_row.id,'developer_scope',task_id::text,'founder_standing_authorization',array['founder'],
      jsonb_build_object('founder',jsonb_build_object('decision','approve','comment','Standing repository authority; no spending authority.'),
        'standing_authorization',jsonb_build_object('authorization_id',authorization_row.id,'repository',authorization_row.repository,
          'capabilities',authorization_row.capabilities)),
      0,'EUR',left('Standing founder authorization: '||trim(p_title),500),'approved',
      jsonb_build_object('task_id',task_id,'repository',authorization_row.repository,
        'authorization_id',authorization_row.id,'project_all_in_cap_eur',project_row.budget_amount,
        'budget_assessment_status',project_row.budget_assessment_status,
        'spending_authority_changed',false),
      'founder:'||founder_id,now());
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.standing_code_task_created','task',task_id::text,
      jsonb_build_object('project_id',project_row.id,'project_budget_eur',project_row.budget_amount,
        'budget_assessment_status',project_row.budget_assessment_status,
        'task_creation_cost_eur',0,'spending_authority_changed',false,
        'authorization_id',authorization_row.id,'scope_approval_recorded',true,
        'task_title',trim(p_title)));
  return jsonb_build_object('task_id',task_id,'project_id',project_row.id,
    'project_budget_eur',project_row.budget_amount,'project_budget_currency',project_row.budget_currency,
    'budget_assessment_status',project_row.budget_assessment_status,
    'project_approval_id',project_approval_id,
    'authorization_id',authorization_row.id,'spending_authority_changed',false,'status','in_progress');
end;
$$;
revoke all on function public.sutra_founder_create_standing_code_task(text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_founder_create_standing_code_task(text,text,text,jsonb) to service_role;

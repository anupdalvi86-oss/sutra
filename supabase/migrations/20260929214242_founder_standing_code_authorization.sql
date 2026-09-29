-- Record the founder's standing repository authority as a database control.
-- This authorizes code-path actions for Sutra's repository, never spending.
create table public.founder_code_authorizations (
  id uuid primary key default gen_random_uuid(),
  repository text not null check (repository = 'anupdalvi86-oss/sutra'),
  capabilities text[] not null check (capabilities = array[
    'create_developer_tasks','create_branches','open_pull_requests','merge_pull_requests',
    'run_qa','run_security','deploy'
  ]::text[]),
  mandate text not null check (length(trim(mandate)) between 20 and 4000),
  granted_by text not null check (length(trim(granted_by)) between 1 and 64),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by text,
  revocation_reason text,
  constraint founder_code_authorization_revocation_shape check (
    (active and revoked_at is null and revoked_by is null and revocation_reason is null)
    or (not active and revoked_at is not null and revoked_by is not null
      and revocation_reason is not null and length(trim(revocation_reason)) between 8 and 500)
  )
);
alter table public.founder_code_authorizations enable row level security;
revoke all on public.founder_code_authorizations from public, anon, authenticated, service_role;
create unique index founder_code_authorization_one_active
  on public.founder_code_authorizations(repository) where active;

create or replace function public.sutra_has_standing_code_authorization()
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.founder_code_authorizations
    where repository='anupdalvi86-oss/sutra' and active
      and capabilities = array['create_developer_tasks','create_branches','open_pull_requests',
        'merge_pull_requests','run_qa','run_security','deploy']::text[])
$$;
revoke all on function public.sutra_has_standing_code_authorization() from public,anon,authenticated,service_role;

create or replace function public.sutra_founder_record_code_authorization(
  p_founder_telegram_user_id text,p_mandate text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; authorization_row public.founder_code_authorizations%rowtype;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_mandate is null or length(trim(p_mandate)) not between 20 and 4000 then
    raise exception 'malformed founder code authorization' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can grant standing code authority' using errcode='42501';
  end if;
  select * into authorization_row from public.founder_code_authorizations
    where repository='anupdalvi86-oss/sutra' and active for update;
  if not found then
    insert into public.founder_code_authorizations(repository,capabilities,mandate,granted_by)
      values('anupdalvi86-oss/sutra',array['create_developer_tasks','create_branches',
        'open_pull_requests','merge_pull_requests','run_qa','run_security','deploy'],
        trim(p_mandate),founder_id) returning * into authorization_row;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,'founder.standing_code_authorization_granted',
        'founder_code_authorization',authorization_row.id::text,
        jsonb_build_object('repository',authorization_row.repository,
          'capabilities',authorization_row.capabilities,'mandate',authorization_row.mandate,
          'spending_authority_changed',false,'scope', 'Sutra repository code path'));
  end if;
  return jsonb_build_object('authorization_id',authorization_row.id,'repository',authorization_row.repository,
    'capabilities',authorization_row.capabilities,'active',authorization_row.active,
    'spending_authority_changed',false);
end;
$$;
revoke all on function public.sutra_founder_record_code_authorization(text,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_record_code_authorization(text,text) to service_role;

create or replace function public.sutra_founder_revoke_code_authorization(
  p_founder_telegram_user_id text,p_authorization_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; authorization_row public.founder_code_authorizations%rowtype;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_authorization_id is null or p_reason is null or length(trim(p_reason)) not between 8 and 500 then
    raise exception 'malformed founder authorization revocation' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can revoke standing code authority' using errcode='42501';
  end if;
  update public.founder_code_authorizations set active=false,revoked_at=now(),revoked_by=founder_id,
    revocation_reason=trim(p_reason) where id=p_authorization_id and active returning * into authorization_row;
  if not found then raise exception 'active code authorization not found' using errcode='22023'; end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.standing_code_authorization_revoked',
      'founder_code_authorization',authorization_row.id::text,
      jsonb_build_object('repository',authorization_row.repository,'reason',authorization_row.revocation_reason,
        'spending_authority_changed',false));
  return jsonb_build_object('authorization_id',authorization_row.id,'active',false);
end;
$$;
revoke all on function public.sutra_founder_revoke_code_authorization(text,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_revoke_code_authorization(text,uuid,text) to service_role;

create or replace function public.sutra_founder_code_authorization_status(
  p_founder_telegram_user_id text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; authorization_row public.founder_code_authorizations%rowtype;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64 then
    raise exception 'malformed founder code authorization status request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can view standing code authority' using errcode='42501';
  end if;
  select * into authorization_row from public.founder_code_authorizations
    where repository='anupdalvi86-oss/sutra' order by created_at desc limit 1;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.standing_code_authorization_viewed',
      'founder_code_authorization',authorization_row.id::text,
      jsonb_build_object('active',coalesce(authorization_row.active,false)));
  if authorization_row.id is null then
    return jsonb_build_object('active',false,'repository','anupdalvi86-oss/sutra');
  end if;
  return jsonb_build_object('authorization_id',authorization_row.id,'active',authorization_row.active,
    'repository',authorization_row.repository,'capabilities',authorization_row.capabilities,
    'created_at',authorization_row.created_at,'revoked_at',authorization_row.revoked_at,
    'spending_authority_changed',false);
end;
$$;
revoke all on function public.sutra_founder_code_authorization_status(text) from public,anon,authenticated;
grant execute on function public.sutra_founder_code_authorization_status(text) to service_role;

-- Create the fresh, persistent Developer task under a zero-euro all-in budget.
-- Any provider usage is still subject to the existing spend reservation controls.
create or replace function public.sutra_founder_create_standing_code_task(
  p_founder_telegram_user_id text,p_title text,p_description text,p_acceptance_criteria jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; developer_id uuid; project_row public.projects%rowtype;
  authorization_row public.founder_code_authorizations%rowtype; task_id uuid; project_approval_id uuid;
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
        'Founder-directed implementation of Sutra business operating capabilities. Initial all-in spend budget is EUR 0; do not start paid actions without a later founder-approved budget.',
        'active',developer_id,0,'EUR',now(),now(),'sutra-operating-model',0,'EUR','founder:'||founder_id)
      returning * into project_row;
    insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
      decisions,amount,currency,summary,status,payload,decided_by,decided_at)
      values(project_row.id,'project_budget',project_row.id::text,'founder:'||founder_id,array['founder'],
        jsonb_build_object('founder',jsonb_build_object('decision','approve','comment','Founder directed implementation with EUR 0 all-in spend cap.')),
        0,'EUR','Founder-directed Sutra implementation, zero-euro all-in budget','approved',
        jsonb_build_object('all_in_budget',0,'currency','EUR','paid_work_allowed',false),
        'founder:'||founder_id,now()) returning id into project_approval_id;
  else
    if project_row.budget_amount<>0 or project_row.requested_budget<>0 or project_row.status not in ('active','approved') then
      raise exception 'Sutra implementation project budget or status changed; no task was created' using errcode='42501';
    end if;
    select id into project_approval_id from public.approvals where project_id=project_row.id
      and approval_type='project_budget' and status='approved' order by decided_at desc nulls last limit 1;
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
        'authorization_id',authorization_row.id,'spending_authority_changed',false),
      'founder:'||founder_id,now());
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.standing_code_task_created','task',task_id::text,
      jsonb_build_object('project_id',project_row.id,'project_budget_eur',0,
        'authorization_id',authorization_row.id,'scope_approval_recorded',true,
        'task_title',trim(p_title),'paid_actions_allowed',false));
  return jsonb_build_object('task_id',task_id,'project_id',project_row.id,
    'project_budget_eur',0,'project_approval_id',project_approval_id,
    'authorization_id',authorization_row.id,'status','in_progress');
end;
$$;
revoke all on function public.sutra_founder_create_standing_code_task(text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_founder_create_standing_code_task(text,text,text,jsonb) to service_role;

-- A completed Architect design remains a required input. The standing grant only
-- replaces the repeated founder scope approvals for this exact repository.
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
        else
          if public.sutra_has_standing_code_authorization() then
            select id into authorization_id from public.founder_code_authorizations
              where repository='anupdalvi86-oss/sutra' and active order by created_at desc limit 1;
            insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
              decisions,amount,currency,summary,status,payload,decided_by,decided_at)
            values(child.project_id,'developer_scope',child.id::text,'founder_standing_authorization',array['founder'],
              jsonb_build_object('founder',jsonb_build_object('decision','approve','comment','Standing founder repository authorization.'),
                'standing_authorization',jsonb_build_object('authorization_id',authorization_id,
                  'repository','anupdalvi86-oss/sutra')),
              0,'EUR',left('Standing founder code authorization: '||child.title,500),'approved',
              jsonb_build_object('task_id',child.id,'task_title',child.title,'task_description',child.description,
                'architect_task_id',new.id,'technical_design',artifact_row.artifact->'artifact',
                'authorization_id',authorization_id,'spending_authority_changed',false),
              'founder:standing-authorization',now()) on conflict (action_ref)
              where approval_type='developer_scope' do nothing returning id into scope_approval_id;
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

-- Codex still needs a task-bound approval record, an issue, an active project,
-- and a fresh reservation under existing spending policy and limits.
create or replace function public.sutra_authorize_codex_task(
  p_worker_id text,p_task_id uuid,p_issue_number integer,p_issue_url text,p_provider text,p_model text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; project_row public.projects%rowtype; developer_id uuid;
  run_row public.agent_runs%rowtype; execution_row public.codex_task_executions%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype; reserve_result jsonb; run_id uuid; lease uuid;
  v_approval_id uuid;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_task_id is null or p_issue_number is null or p_issue_number<1
    or p_issue_url is null or p_issue_url !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$'
    or split_part(p_issue_url,'/',7)<>p_issue_number::text
    or p_provider is null or p_provider !~ '^[a-z0-9][a-z0-9_-]{0,79}$'
    or p_model is null or length(p_model) not between 1 and 200 or p_model ~ '[[:cntrl:]]' then
    raise exception 'malformed Codex task authorization request' using errcode='22023';
  end if;
  select t.* into task_row from public.tasks t where t.id=p_task_id for update;
  select a.id into developer_id from public.agents a where a.slug='developer' and a.active;
  select p.* into project_row from public.projects p where p.id=task_row.project_id;
  if task_row.id is null or developer_id is null or task_row.task_type<>'engineering'
    or task_row.status not in ('in_progress','blocked') or task_row.owner_agent_id<>developer_id
    or task_row.assigned_agent_id<>developer_id or project_row.id is null
    or project_row.status not in ('approved','active')
    or not exists(select 1 from public.github_task_dispatches d where d.task_id=task_row.id
      and d.status='created' and d.issue_number=p_issue_number and d.issue_url=p_issue_url)
    or not exists(select 1 from public.approvals sa where sa.approval_type='developer_scope'
      and sa.action_ref=task_row.id::text and sa.project_id=task_row.project_id and sa.status='approved'
      and sa.decisions #>> '{founder,decision}'='approve'
      and ((sa.decisions #>> '{standing_authorization,repository}' is null)
        or (sa.decisions #>> '{standing_authorization,repository}'='anupdalvi86-oss/sutra'
          and public.sutra_has_standing_code_authorization()))) then
    raise exception 'Codex requires a signed issue, approved task scope, and active project' using errcode='42501';
  end if;

  select * into execution_row from public.codex_task_executions e where e.task_id=p_task_id for update;
  if found then
    if execution_row.issue_number<>p_issue_number or execution_row.provider<>p_provider or execution_row.model<>p_model then
      raise exception 'Codex task was already bound to another issue or model route' using errcode='42501';
    end if;
    select * into run_row from public.agent_runs r where r.id=execution_row.agent_run_id for update;
    select * into reservation_row from public.agent_run_spend_reservations s where s.id=execution_row.reservation_id for update;
    if execution_row.status='awaiting_approval' and reservation_row.status='awaiting_approval' and run_row.status='blocked' then
      return jsonb_build_object('status','awaiting_approval','task_id',p_task_id,'approval_id',execution_row.approval_id,'reservation_id',reservation_row.id);
    end if;
    if reservation_row.status='rejected' or execution_row.status='rejected' then
      update public.codex_task_executions set status='rejected',updated_at=now() where id=execution_row.id;
      return jsonb_build_object('status','rejected','task_id',p_task_id,'reservation_id',reservation_row.id);
    end if;
    if execution_row.status in ('reconciled','unknown','overrun','failed') then
      return jsonb_build_object('status','terminal','task_id',p_task_id,'execution_status',execution_row.status);
    end if;
    if run_row.status='queued' and reservation_row.status='reserved' and run_row.attempt_count<3 then
      lease:=gen_random_uuid();
      update public.agent_runs set status='running',attempt_count=attempt_count+1,
        started_at=coalesce(started_at,now()),finished_at=null,lease_token=lease,
        lease_expires_at=now()+interval '2 hours',output='{"spend_approval":"approved"}'::jsonb
        where id=run_row.id returning * into run_row;
    elsif run_row.status='running' and run_row.lease_expires_at>=now() then null;
    else raise exception 'Codex execution lease is unavailable or exhausted' using errcode='42501'; end if;
    if reservation_row.status='reserved' then
      update public.tasks set status='in_progress',updated_at=now() where id=execution_row.task_id and status='blocked';
      perform public.sutra_begin_agent_run_spend(p_worker_id,run_row.id,run_row.lease_token,reservation_row.id);
      update public.codex_task_executions set status='running',updated_at=now() where id=execution_row.id;
    end if;
    return jsonb_build_object('status','authorized','task_id',p_task_id,'run_id',run_row.id,
      'lease_token',run_row.lease_token,'reservation_id',reservation_row.id,'provider',execution_row.provider,
      'model',execution_row.model,'max_input_tokens',reservation_row.max_input_tokens,
      'max_output_tokens',reservation_row.max_output_tokens,'max_model_iterations',execution_row.max_requests);
  end if;
  if task_row.status<>'in_progress' then raise exception 'Codex requires an active Developer task without a prior execution' using errcode='42501'; end if;
  run_id:=gen_random_uuid(); lease:=gen_random_uuid();
  insert into public.agent_runs(id,agent_id,project_id,task_id,trigger_type,status,input,output,started_at,lease_token,lease_expires_at,attempt_count)
    values(run_id,developer_id,task_row.project_id,task_row.id,'codex_execution','running',
      jsonb_build_object('task_id',task_row.id,'issue_number',p_issue_number,'provider',p_provider,'model',p_model),
      '{}'::jsonb,now(),lease,now()+interval '2 hours',1);
  insert into public.codex_task_executions(task_id,agent_run_id,issue_number,provider,model,max_requests,status)
    values(task_row.id,run_id,p_issue_number,p_provider,p_model,3,'running') returning * into execution_row;
  reserve_result:=public.sutra_reserve_agent_run_spend_from_profile(p_worker_id,run_id,lease,p_provider,p_model);
  reservation_row.id:=(reserve_result->>'reservation_id')::uuid;
  reservation_row.max_input_tokens:=(reserve_result->>'max_input_tokens')::integer;
  reservation_row.max_output_tokens:=(reserve_result->>'max_output_tokens')::integer;
  v_approval_id:=nullif(reserve_result->>'approval_id','')::uuid;
  update public.codex_task_executions set reservation_id=reservation_row.id,approval_id=v_approval_id,
    status=case when reserve_result->>'status'='approved' then 'running' else 'awaiting_approval' end,
    updated_at=now() where id=execution_row.id;
  if reserve_result->>'status'<>'approved' then
    return jsonb_build_object('status','awaiting_approval','task_id',p_task_id,'approval_id',v_approval_id,
      'reservation_id',reservation_row.id,'required_approvers',reserve_result->'required_approvers');
  end if;
  perform public.sutra_begin_agent_run_spend(p_worker_id,run_id,lease,reservation_row.id);
  return jsonb_build_object('status','authorized','task_id',p_task_id,'run_id',run_id,'lease_token',lease,
    'reservation_id',reservation_row.id,'provider',p_provider,'model',p_model,
    'max_input_tokens',reservation_row.max_input_tokens,'max_output_tokens',reservation_row.max_output_tokens,
    'max_model_iterations',reserve_result->'max_model_iterations');
end;
$$;
revoke all on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text) from public,anon,authenticated;
grant execute on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text) to service_role;

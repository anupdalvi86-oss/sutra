-- Require founder approval of the concrete Architect design before Developer work.
create or replace function public.sutra_founder_decide_approval(
  p_founder_telegram_user_id text,
  p_approval_id uuid,
  p_decision text,
  p_comment text default ''
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  founder_id text;
  approval_row public.approvals%rowtype;
  project_row public.projects%rowtype;
  objective_id uuid;
  pm_id uuid;
  first_task_id uuid;
  previous_task_id uuid;
  stage record;
begin
  select value #>> '{}' into founder_id from public.company_settings where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the configured founder can decide this approval' using errcode = '42501';
  end if;
  if p_decision not in ('approve','reject') then raise exception 'decision must be approve or reject' using errcode = '22023'; end if;
  select * into approval_row from public.approvals where id = p_approval_id for update;
  if not found or approval_row.status <> 'pending' or not ('founder' = any(approval_row.required_roles)) then
    raise exception 'approval is missing, already resolved, or not founder-authorized' using errcode = '42501';
  end if;
  if p_decision = 'approve' and exists (
    select 1 from unnest(approval_row.required_roles) as r(role)
    where r.role <> 'founder' and coalesce(approval_row.decisions #>> array[r.role,'decision'],'') <> 'approve'
  ) then
    raise exception 'required department approvals are incomplete' using errcode = '42501';
  end if;
  if approval_row.approval_type = 'developer_scope' then
    if approval_row.action_ref is null or approval_row.action_ref !~ '^[0-9a-fA-F-]{36}$' then
      raise exception 'developer scope approval has no valid task reference' using errcode = '22023';
    end if;
    select * into project_row from public.projects where id=approval_row.project_id for update;
    if not exists (
      select 1 from public.tasks t
      join public.agents a on a.id=t.assigned_agent_id and a.slug='developer' and a.active
      join public.tasks parent on parent.id=t.parent_task_id and parent.status='done'
      join public.agents pa on pa.id=parent.assigned_agent_id and pa.slug='architect'
      join public.task_agent_artifacts artifact on artifact.task_id=parent.id and artifact.artifact_type='technical_design'
      where t.id=approval_row.action_ref::uuid and t.project_id=approval_row.project_id
        and t.status='blocked' and project_row.status in ('approved','active')
    ) then raise exception 'developer scope no longer matches a blocked task and completed Architect design' using errcode = '42501'; end if;
    update public.approvals set status=case p_decision when 'approve' then 'approved' else 'rejected' end,
      decided_by='founder:'||founder_id,decided_at=now(),
      decisions=decisions||jsonb_build_object('founder',jsonb_build_object('decision',p_decision,
        'comment',left(coalesce(p_comment,''),2000))) where id=p_approval_id;
    update public.tasks set status=case p_decision when 'approve' then 'ready' else 'cancelled' end,updated_at=now()
      where id=approval_row.action_ref::uuid;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,'approval.'||p_decision,'approval',p_approval_id::text,
        jsonb_build_object('approval_type','developer_scope','task_id',approval_row.action_ref,
          'project_id',approval_row.project_id,'comment',left(coalesce(p_comment,''),2000)));
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,'developer.scope.'||p_decision,'task',approval_row.action_ref,
        jsonb_build_object('approval_id',p_approval_id,'project_id',approval_row.project_id,
          'comment',left(coalesce(p_comment,''),2000)));
    return jsonb_build_object('approval_id',p_approval_id,
      'status',case p_decision when 'approve' then 'approved' else 'rejected' end,
      'project_id',approval_row.project_id,'task_id',approval_row.action_ref::uuid);
  end if;
  update public.approvals set status = case p_decision when 'approve' then 'approved' else 'rejected' end,
    decided_by = 'founder:' || founder_id, decided_at = now(), decisions = decisions || jsonb_build_object('founder',jsonb_build_object('decision',p_decision,'comment',left(coalesce(p_comment,''),2000)))
    where id = p_approval_id;
  if approval_row.expense_id is not null then
    update public.expenses set status = case p_decision when 'approve' then 'approved' else 'rejected' end,
      approved_at = case p_decision when 'approve' then now() else null end
      where id = approval_row.expense_id;
  end if;
  select * into project_row from public.projects where id = approval_row.project_id for update;
  if project_row.id is not null then
    update public.projects set status = case p_decision when 'approve' then 'approved' else 'rejected' end, updated_at = now() where id = project_row.id;
    if p_decision = 'approve' then
      update public.tasks set status = 'ready' where project_id = project_row.id and status = 'blocked';
      select id into objective_id from public.objectives where project_id = project_row.id and status = 'proposed' order by created_at limit 1;
      update public.objectives set status = 'active' where id = objective_id;
      select id into pm_id from public.agents where slug = 'product_manager';
      insert into public.tasks(project_id,objective_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
        values(project_row.id,objective_id,'Create approved product requirements and implementation plan',
          'Convert the approved proposal into a reviewed specification and engineering backlog.',
          '["Founder-approved budget is preserved","Requirements and acceptance criteria are recorded","Engineering work is split into reviewable tasks"]'::jsonb,'product','ready',pm_id,pm_id)
        returning id into first_task_id;
      previous_task_id := first_task_id;
      for stage in select * from (values
          ('Produce architecture and technical design','Record interfaces, data flow, deployment topology and technical risks.','["Design is recorded and linked to the project","Security assumptions are stated"]'::jsonb,'architect'),
          ('Implement approved product tasks','Create a branch and reviewable pull request for the approved scope.','["Changes map to approved tasks","No secrets are committed","Pull request is reviewable"]'::jsonb,'developer'),
          ('Verify acceptance criteria','Run and record reproducible automated and manual test results.','["Acceptance criteria have evidence","Failures are recorded"]'::jsonb,'qa'),
          ('Review security and dependencies','Record threat, dependency and data-handling findings.','["Security findings have severity and owner","Release blockers are explicit"]'::jsonb,'security'),
          ('Prepare release and rollback','Verify health checks, recovery path and release readiness.','["Deployment is repeatable","Rollback steps are documented"]'::jsonb,'devops'),
          ('Prepare marketing launch proposal','Draft positioning and an approval-ready campaign plan.','["Audience, claims and budget are reviewed","No message is sent externally"]'::jsonb,'cmo'),
          ('Prepare sales handoff','Create internal lead qualification and sales materials.','["Lead criteria and materials are recorded","No external outreach is sent"]'::jsonb,'sales')
      ) as stage(title,description,acceptance_criteria,owner_slug)
      loop
        insert into public.tasks(project_id,objective_id,parent_task_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
          select project_row.id,objective_id,previous_task_id,stage.title,stage.description,
            stage.acceptance_criteria,'engineering','backlog',a.id,a.id
          from public.agents a where a.slug=stage.owner_slug returning id into previous_task_id;
      end loop;
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system','sutra','project.approved_tasks_created','project',project_row.id::text,jsonb_build_object('first_task_id',first_task_id));
    end if;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'approval.' || p_decision,'approval',p_approval_id::text,jsonb_build_object('comment',left(coalesce(p_comment,''),2000)));
  return jsonb_build_object('approval_id',p_approval_id,'status',case p_decision when 'approve' then 'approved' else 'rejected' end,
    'project_id',approval_row.project_id,'first_task_id',first_task_id);
end;
$$;;

create function public.sutra_claim_github_task(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; dispatch_id uuid; lease uuid; attempts_now integer;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-github-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid GitHub dispatcher identity' using errcode='22023';
  end if;

  with expired as (
    update public.github_task_dispatches set status='failed',lease_token=null,lease_expires_at=null,
      last_error='dispatch_unknown',updated_at=now()
    where status='creating' and lease_expires_at < now() and attempts >= 3
    returning task_id,id,attempts
  )
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  select 'system',p_worker_id,'github.task_dispatch_exhausted','task',e.task_id::text,
    jsonb_build_object('dispatch_id',e.id,'attempt',e.attempts,'error_code','dispatch_unknown') from expired e;

  select t.* into task_row
  from public.tasks t
  join public.agents a on a.id=t.assigned_agent_id and a.active and a.slug='developer'
  join public.projects p on p.id=t.project_id and p.status in ('approved','active')
  left join public.github_task_dispatches d on d.task_id=t.id
  where t.task_type='engineering' and t.status='ready'
    and exists(select 1 from public.approvals sa where sa.approval_type='developer_scope'
      and sa.action_ref=t.id::text and sa.project_id=t.project_id and sa.status='approved'
      and sa.decisions #>> '{founder,decision}'='approve')
    and (d.id is null or d.status='queued' or (d.status='failed' and d.attempts < 3)
      or (d.status='creating' and d.lease_expires_at < now() and d.attempts < 3))
  order by t.created_at,t.id
  limit 1 for update of t skip locked;
  if not found then return null; end if;

  lease := gen_random_uuid();
  insert into public.github_task_dispatches(task_id,status,attempts,lease_token,lease_expires_at,updated_at)
  values(task_row.id,'creating',1,lease,now()+interval '3 minutes',now())
  on conflict(task_id) do update set status='creating',attempts=github_task_dispatches.attempts+1,
    lease_token=excluded.lease_token,lease_expires_at=excluded.lease_expires_at,
    issue_number=null,issue_url=null,last_error=null,updated_at=now()
  returning id,attempts into dispatch_id,attempts_now;

  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  values('system',p_worker_id,'github.task_dispatch_claimed','task',task_row.id::text,
    jsonb_build_object('dispatch_id',dispatch_id,'attempt',attempts_now));

  return jsonb_build_object('dispatch_id',dispatch_id,'task_id',task_row.id,'lease_token',lease,
    'attempt',attempts_now,'title',task_row.title,'description',task_row.description,
    'acceptance_criteria',task_row.acceptance_criteria,'project_id',task_row.project_id,
    'objective_id',task_row.objective_id);
end $$;;

create function public.sutra_complete_github_task_dispatch(
  p_worker_id text,p_task_id uuid,p_lease_token uuid,p_issue_number integer,p_issue_url text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare dispatch_row public.github_task_dispatches%rowtype; task_row public.tasks%rowtype;
  project_state text; task_status text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-github-worker-[a-z0-9]{8,64}$'
    or p_task_id is null or p_lease_token is null or p_issue_number is null or p_issue_number < 1
    or p_issue_url is null or p_issue_url !~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$'
    or split_part(p_issue_url,'/',7) <> p_issue_number::text then
    raise exception 'malformed GitHub task dispatch completion' using errcode='22023';
  end if;
  select * into dispatch_row from public.github_task_dispatches d
    where d.task_id=p_task_id and d.status='creating' and d.lease_token=p_lease_token for update;
  if not found or dispatch_row.lease_expires_at < now() then
    raise exception 'GitHub task dispatch lease is invalid or expired' using errcode='42501';
  end if;
  select * into task_row from public.tasks t where t.id=p_task_id for update;
  if not found then raise exception 'dispatched task no longer exists' using errcode='42501'; end if;
  select p.status into project_state from public.projects p where p.id=task_row.project_id;
  task_status := case when task_row.status='ready' and project_state in ('approved','active') and exists (
    select 1 from public.agents a where a.id=task_row.assigned_agent_id and a.active and a.slug='developer'
  ) and exists(select 1 from public.approvals sa where sa.approval_type='developer_scope'
    and sa.action_ref=task_row.id::text and sa.project_id=task_row.project_id and sa.status='approved'
    and sa.decisions #>> '{founder,decision}'='approve') then 'in_progress' else task_row.status end;
  update public.github_task_dispatches set status='created',issue_number=p_issue_number,issue_url=p_issue_url,
    lease_token=null,lease_expires_at=null,last_error=null,updated_at=now() where id=dispatch_row.id;
  update public.tasks set status=task_status,updated_at=now() where id=p_task_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
  values('system',p_worker_id,case when task_status='in_progress' then 'github.issue_created' else 'github.issue_linked' end,
    'task',p_task_id::text,jsonb_build_object('dispatch_id',dispatch_row.id,'issue_number',p_issue_number,
      'issue_url',p_issue_url,'project_status',project_state));
  return jsonb_build_object('task_id',p_task_id,'status',task_status,'issue_number',p_issue_number,'issue_url',p_issue_url);
end $$;;

create function public.sutra_authorize_codex_task(
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
    or task_row.status<>'in_progress' or task_row.owner_agent_id<>developer_id
    or task_row.assigned_agent_id<>developer_id or project_row.id is null
    or project_row.status not in ('approved','active')
    or not exists(select 1 from public.github_task_dispatches d where d.task_id=task_row.id
      and d.status='created' and d.issue_number=p_issue_number and d.issue_url=p_issue_url)
    or not exists(select 1 from public.approvals sa where sa.approval_type='developer_scope'
      and sa.action_ref=task_row.id::text and sa.project_id=task_row.project_id and sa.status='approved'
      and sa.decisions #>> '{founder,decision}'='approve') then
    raise exception 'Codex requires the signed issue for an assigned Developer task in an approved project' using errcode='42501';
  end if;

  select * into execution_row from public.codex_task_executions e where e.task_id=p_task_id for update;
  if found then
    if execution_row.issue_number<>p_issue_number or execution_row.provider<>p_provider or execution_row.model<>p_model then
      raise exception 'Codex task was already bound to another issue or model route' using errcode='42501';
    end if;
    select * into run_row from public.agent_runs r where r.id=execution_row.agent_run_id for update;
    select * into reservation_row from public.agent_run_spend_reservations s
      where s.id=execution_row.reservation_id for update;
    if execution_row.status='awaiting_approval' and reservation_row.status='awaiting_approval'
      and run_row.status='blocked' then
      return jsonb_build_object('status','awaiting_approval','task_id',p_task_id,
        'approval_id',execution_row.approval_id,'reservation_id',reservation_row.id);
    end if;
    if reservation_row.status='rejected' or execution_row.status='rejected' then
      update public.codex_task_executions set status='rejected',updated_at=now() where id=execution_row.id;
      return jsonb_build_object('status','rejected','task_id',p_task_id,'reservation_id',reservation_row.id);
    end if;
    if execution_row.status in ('reconciled','unknown','overrun','failed') then
      raise exception 'Codex task execution is terminal' using errcode='42501';
    end if;
    if run_row.status='queued' and reservation_row.status='reserved' and run_row.attempt_count<3 then
      lease:=gen_random_uuid();
      update public.agent_runs set status='running',attempt_count=attempt_count+1,
        started_at=coalesce(started_at,now()),finished_at=null,lease_token=lease,
        lease_expires_at=now()+interval '2 hours',output='{"spend_approval":"approved"}'::jsonb
        where id=run_row.id returning * into run_row;
    elsif run_row.status='running' and run_row.lease_expires_at>=now() then
      null;
    else
      raise exception 'Codex execution lease is unavailable or exhausted' using errcode='42501';
    end if;
    if reservation_row.status='reserved' then
      perform public.sutra_begin_agent_run_spend(p_worker_id,run_row.id,run_row.lease_token,reservation_row.id);
      update public.codex_task_executions set status='running',updated_at=now() where id=execution_row.id;
    end if;
    return jsonb_build_object('status','authorized','task_id',p_task_id,'run_id',run_row.id,
      'lease_token',run_row.lease_token,'reservation_id',reservation_row.id,
      'provider',execution_row.provider,'model',execution_row.model,
      'max_input_tokens',reservation_row.max_input_tokens,'max_output_tokens',reservation_row.max_output_tokens,
      'max_model_iterations',execution_row.max_requests);
  end if;

  run_id:=gen_random_uuid(); lease:=gen_random_uuid();
  insert into public.agent_runs(id,agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,lease_token,lease_expires_at,attempt_count)
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
    return jsonb_build_object('status','awaiting_approval','task_id',p_task_id,
      'approval_id',v_approval_id,'reservation_id',reservation_row.id,
      'required_approvers',reserve_result->'required_approvers');
  end if;
  perform public.sutra_begin_agent_run_spend(p_worker_id,run_id,lease,reservation_row.id);
  return jsonb_build_object('status','authorized','task_id',p_task_id,'run_id',run_id,
    'lease_token',lease,'reservation_id',reservation_row.id,'provider',p_provider,'model',p_model,
    'max_input_tokens',reservation_row.max_input_tokens,'max_output_tokens',reservation_row.max_output_tokens,
    'max_model_iterations',reserve_result->'max_model_iterations');
end;
$$;;

create or replace function public.sutra_release_child_tasks()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare child record; artifact_row public.task_agent_artifacts%rowtype; parent_slug text;
begin
  if old.status is distinct from new.status and new.status='done' then
    select slug into parent_slug from public.agents where id=new.assigned_agent_id;
    for child in select t.id,t.project_id,t.title,t.description,a.slug as assigned_slug
      from public.tasks t left join public.agents a on a.id=t.assigned_agent_id
      where t.parent_task_id=new.id and t.status='backlog' for update of t
    loop
      if child.assigned_slug='developer' and parent_slug='architect' then
        select * into artifact_row from public.task_agent_artifacts where task_id=new.id and artifact_type='technical_design';
        update public.tasks set status='blocked',updated_at=now() where id=child.id;
        if artifact_row.id is null then
          insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
            values('system','sutra','developer.scope_gate_missing_design','task',child.id::text,
              jsonb_build_object('project_id',child.project_id,'architect_task_id',new.id));
        else
          insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,amount,currency,summary,status,payload)
            values(child.project_id,'developer_scope',child.id::text,'system:architecture_scope_gate',array['founder'],0,'EUR',
              left('Founder scope review required before engineering: '||child.title||'. Design: '
                ||coalesce(artifact_row.artifact->>'design','')||'. Risks: '
                ||coalesce(artifact_row.artifact->>'security_risks',''),500),'pending',
              jsonb_build_object('task_id',child.id,'task_title',child.title,'task_description',child.description,
                'architect_task_id',new.id,'technical_design',artifact_row.artifact)) on conflict (action_ref)
              where approval_type='developer_scope' do nothing;
          insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
            values('system','sutra','developer.scope.approval_requested','task',child.id::text,
              jsonb_build_object('project_id',child.project_id,'architect_task_id',new.id,
                'approval_id',(select id from public.approvals where approval_type='developer_scope' and action_ref=child.id::text)));
        end if;
      else update public.tasks set status='ready',updated_at=now() where id=child.id;
      end if;
    end loop;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','task.children_released','task',new.id::text,jsonb_build_object('project_id',new.project_id));
  end if;
  return new;
end; $$;

create unique index if not exists approvals_developer_scope_task_unique on public.approvals(action_ref)
  where approval_type='developer_scope';

-- Quarantine previously released Developer tasks until the founder approves the exact persisted design.
update public.tasks t set status='blocked',updated_at=now()
from public.agents a,public.tasks parent,public.agents pa,public.projects p
where t.assigned_agent_id=a.id and a.slug='developer' and t.task_type='engineering' and t.status='ready'
  and t.parent_task_id=parent.id and parent.status='done' and parent.assigned_agent_id=pa.id and pa.slug='architect'
  and p.id=t.project_id and p.status in ('approved','active')
  and not exists(select 1 from public.approvals sa where sa.approval_type='developer_scope' and sa.action_ref=t.id::text);

insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
select 'system','sutra','developer.scope_gate_missing_design','task',t.id::text,
  jsonb_build_object('project_id',t.project_id,'architect_task_id',parent.id,'migration',true)
from public.tasks t join public.agents a on a.id=t.assigned_agent_id and a.slug='developer'
join public.tasks parent on parent.id=t.parent_task_id and parent.status='done'
join public.agents pa on pa.id=parent.assigned_agent_id and pa.slug='architect'
join public.projects p on p.id=t.project_id and p.status in ('approved','active')
where t.task_type='engineering' and t.status='blocked'
  and not exists(select 1 from public.task_agent_artifacts artifact where artifact.task_id=parent.id and artifact.artifact_type='technical_design')
  and not exists(select 1 from public.audit_log l where l.action='developer.scope_gate_missing_design' and l.resource_id=t.id::text);

insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,amount,currency,summary,status,payload)
select t.project_id,'developer_scope',t.id::text,'system:architecture_scope_gate',array['founder'],0,'EUR',
  left('Founder scope review required before engineering: '||t.title||'. Design: '
    ||coalesce(artifact.artifact->>'design','')||'. Risks: '||coalesce(artifact.artifact->>'security_risks',''),500),'pending',
  jsonb_build_object('task_id',t.id,'task_title',t.title,'task_description',t.description,
    'architect_task_id',parent.id,'technical_design',artifact.artifact)
from public.tasks t join public.agents a on a.id=t.assigned_agent_id and a.slug='developer'
join public.tasks parent on parent.id=t.parent_task_id and parent.status='done'
join public.agents pa on pa.id=parent.assigned_agent_id and pa.slug='architect'
join public.task_agent_artifacts artifact on artifact.task_id=parent.id and artifact.artifact_type='technical_design'
join public.projects p on p.id=t.project_id and p.status in ('approved','active')
where t.task_type='engineering' and t.status='blocked'
  and not exists(select 1 from public.approvals sa where sa.approval_type='developer_scope' and sa.action_ref=t.id::text);

insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
select 'system','sutra','developer.scope.approval_requested','task',t.id::text,
  jsonb_build_object('project_id',t.project_id,'approval_id',sa.id,'migration',true)
from public.approvals sa join public.tasks t on t.id=sa.action_ref::uuid
where sa.approval_type='developer_scope' and sa.status='pending' and sa.requested_by='system:architecture_scope_gate'
  and not exists(select 1 from public.audit_log l where l.action='developer.scope.approval_requested' and l.resource_id=t.id::text);

revoke all on function public.sutra_release_child_tasks() from public,anon,authenticated,service_role;
revoke all on function public.sutra_founder_decide_approval(text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_decide_approval(text,uuid,text,text) to service_role;
revoke all on function public.sutra_claim_github_task(text) from public,anon,authenticated;
grant execute on function public.sutra_claim_github_task(text) to service_role;
revoke all on function public.sutra_complete_github_task_dispatch(text,uuid,uuid,integer,text) from public,anon,authenticated;
grant execute on function public.sutra_complete_github_task_dispatch(text,uuid,uuid,integer,text) to service_role;
revoke all on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text) from public,anon,authenticated;
grant execute on function public.sutra_authorize_codex_task(text,uuid,integer,text,text,text) to service_role;


create or replace function public.sutra_founder_pending_approvals(
  p_founder_telegram_user_id text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  founder_id text;
  approval_list jsonb;
begin
  select value #>> '{}'
    into founder_id
    from public.company_settings
    where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id = '' or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the configured founder can view founder approvals' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(row_data.payload order by row_data.created_at desc), '[]'::jsonb)
    into approval_list
    from (
      select ap.created_at,
        jsonb_build_object(
          'approval_id', ap.id,
          'approval_type', ap.approval_type,
          'action_ref', ap.action_ref,
          'scope_review', case when ap.approval_type='developer_scope' then ap.payload->'technical_design' else null end,
          'summary', left(coalesce(ap.summary, 'Approval request'), 500),
          'amount', ap.amount,
          'currency', ap.currency,
          'pending_roles', roles.pending_roles,
          'ready', cardinality(roles.pending_roles) = 0
        ) as payload
      from public.approvals ap
      cross join lateral (
        select coalesce(array_agg(pending_role.role order by pending_role.role), '{}'::text[]) as pending_roles
        from (
          select required_role.role
          from unnest(ap.required_roles) as required_role(role)
          where required_role.role <> 'founder'
            and coalesce(ap.decisions #>> array[required_role.role, 'decision'], '') <> 'approve'
          union
          select 'product_manager'::text
          where ap.approval_type = 'project_budget'
            and not exists (
              select 1
              from public.agent_runs r
              join public.agents a on a.id = r.agent_id
              where r.project_id = ap.project_id
                and r.trigger_type = 'founder_proposal'
                and r.run_order = 5
                and a.slug = 'product_manager'
                and r.status = 'succeeded'
            )
        ) pending_role
      ) roles
      where ap.status = 'pending'
        and 'founder' = any(ap.required_roles)
      order by ap.created_at desc
      limit 5
    ) row_data;

  insert into public.audit_log(actor_type, actor_id, action, resource_type, resource_id, details)
    values('founder', founder_id, 'founder.approvals_listed', 'approval_queue', null,
      jsonb_build_object('count', jsonb_array_length(approval_list)));
  return jsonb_build_object('approvals', approval_list);
end;
$$;;
revoke all on function public.sutra_founder_pending_approvals(text) from public,anon,authenticated;
grant execute on function public.sutra_founder_pending_approvals(text) to service_role;

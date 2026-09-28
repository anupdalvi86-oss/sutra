-- Expose the typed technical design in founder approval requests.

-- The artifact store retains the complete agent result; founder scope review uses its typed artifact.
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
                ||coalesce(artifact_row.artifact->'artifact'->>'design','')||'. Risks: '
                ||coalesce(artifact_row.artifact->'artifact'->>'security_risks',''),500),'pending',
              jsonb_build_object('task_id',child.id,'task_title',child.title,'task_description',child.description,
                'architect_task_id',new.id,'technical_design',artifact_row.artifact->'artifact')) on conflict (action_ref)
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
end; $$;;

update public.approvals sa
set summary=left('Founder scope review required before engineering: '||t.title||'. Design: '
      ||coalesce(artifact.artifact->'artifact'->>'design','')||'. Risks: '
      ||coalesce(artifact.artifact->'artifact'->>'security_risks',''),500),
    payload=jsonb_set(sa.payload,'{technical_design}',artifact.artifact->'artifact',true)
from public.tasks t join public.tasks parent on parent.id=t.parent_task_id
join public.task_agent_artifacts artifact on artifact.task_id=parent.id and artifact.artifact_type='technical_design'
where sa.approval_type='developer_scope' and sa.status='pending' and sa.action_ref=t.id::text;

revoke all on function public.sutra_release_child_tasks() from public,anon,authenticated,service_role;


-- Prevent a Developer (or later project-approval event) from bypassing the scope RPC.
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
      update public.tasks t set status = 'ready' where t.project_id = project_row.id and t.status = 'blocked'
        and (not exists(select 1 from public.agents a where a.id=t.assigned_agent_id and a.slug='developer')
          or exists(select 1 from public.approvals sa where sa.approval_type='developer_scope'
            and sa.action_ref=t.id::text and sa.project_id=t.project_id and sa.status='approved'
            and sa.decisions #>> '{founder,decision}'='approve'));
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

create or replace function public.sutra_update_task(
  p_actor_agent_id uuid,p_task_id uuid,p_status text,p_evidence jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare task_row public.tasks%rowtype; agent_slug text;
begin
  if p_status is null or p_status not in ('in_progress','review','done','blocked','ready')
    or p_evidence is null or jsonb_typeof(p_evidence) <> 'object' or octet_length(p_evidence::text) > 16000 then
    raise exception 'invalid task update' using errcode = '22023';
  end if;
  select * into task_row from public.tasks where id=p_task_id for update;
  select slug into agent_slug from public.agents where id=p_actor_agent_id and active;
  if task_row.id is null or task_row.owner_agent_id is distinct from p_actor_agent_id or agent_slug is null then
    raise exception 'agent may update only its own assigned task' using errcode = '42501';
  end if;
  if task_row.status='blocked' and p_status='ready' and agent_slug='developer'
    and not exists(select 1 from public.approvals sa where sa.approval_type='developer_scope'
      and sa.action_ref=task_row.id::text and sa.project_id=task_row.project_id and sa.status='approved'
      and sa.decisions #>> '{founder,decision}'='approve') then
    raise exception 'Developer cannot self-release a task without founder scope approval' using errcode='42501';
  end if;
  if not (
    (task_row.status='ready' and p_status in ('in_progress','blocked')) or
    (task_row.status='in_progress' and p_status in ('review','done','blocked')) or
    (task_row.status='review' and p_status in ('done','blocked','in_progress')) or
    (task_row.status='blocked' and p_status='ready')
  ) then raise exception 'task status transition is not allowed' using errcode = '22023'; end if;
  if p_status in ('review','done') and p_evidence='{}'::jsonb then
    raise exception 'review and completion require evidence' using errcode = '22023';
  end if;
  update public.tasks set status=p_status,updated_at=now() where id=p_task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at)
    values(p_actor_agent_id,task_row.project_id,p_task_id,'task_update',
      case p_status when 'done' then 'succeeded' when 'blocked' then 'blocked' else 'running' end,
      jsonb_build_object('previous_status',task_row.status),p_evidence,now(),
      case when p_status in ('done','blocked') then now() else null end);
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',agent_slug,'task.status_changed','task',p_task_id::text,
      jsonb_build_object('from',task_row.status,'to',p_status,'evidence_keys',
        (select coalesce(jsonb_agg(k),'[]'::jsonb) from jsonb_object_keys(p_evidence) as keys(k))));
  return jsonb_build_object('task_id',p_task_id,'status',p_status);
end;
$$;;

revoke all on function public.sutra_founder_decide_approval(text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_decide_approval(text,uuid,text,text) to service_role;
revoke all on function public.sutra_update_task(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_update_task(uuid,uuid,text,jsonb) to service_role;

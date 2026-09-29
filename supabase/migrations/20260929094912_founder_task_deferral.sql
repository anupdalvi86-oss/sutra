-- Founder-approved review deferrals leave QA/Security explicitly incomplete
-- while allowing only the directly dependent internal planning task to proceed.
alter table public.tasks
  add column if not exists deferred_reason text,
  add column if not exists deferred_by text,
  add column if not exists deferred_at timestamptz;

alter table public.tasks drop constraint if exists tasks_status_check;
alter table public.tasks drop constraint if exists tasks_status_allowed_check;
alter table public.tasks add constraint tasks_status_allowed_check
  check (status in ('backlog','ready','in_progress','blocked','review','done','cancelled','deferred'));
alter table public.tasks drop constraint if exists tasks_deferred_fields_check;
alter table public.tasks add constraint tasks_deferred_fields_check check (
  (status='deferred' and deferred_at is not null and deferred_by is not null
    and length(trim(deferred_by)) between 1 and 64
    and deferred_reason is not null and length(trim(deferred_reason)) between 8 and 500)
  or
  (status<>'deferred' and deferred_at is null and deferred_by is null and deferred_reason is null)
);

create or replace function public.sutra_release_child_tasks()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare child record; artifact_row public.task_agent_artifacts%rowtype; parent_slug text;
begin
  if old.status is distinct from new.status and new.status in ('done','deferred') then
    select slug into parent_slug from public.agents where id=new.assigned_agent_id and active;
    if new.status='deferred' and parent_slug not in ('qa','security') then
      return new;
    end if;
    for child in select t.id,t.project_id,t.title,t.description,a.slug as assigned_slug
      from public.tasks t left join public.agents a on a.id=t.assigned_agent_id
      where t.parent_task_id=new.id and t.project_id=new.project_id and t.status='backlog'
      for update of t
    loop
      if new.status='deferred' and not (
        (parent_slug='qa' and child.assigned_slug='security')
        or (parent_slug='security' and child.assigned_slug='devops')
      ) then
        continue;
      end if;
      if child.assigned_slug='developer' and parent_slug='architect' and new.status='done' then
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
      else
        update public.tasks set status='ready',updated_at=now() where id=child.id;
      end if;
    end loop;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra',case when new.status='deferred'
        then 'task.deferred_review_children_released' else 'task.children_released' end,
        'task',new.id::text,jsonb_build_object('project_id',new.project_id,'parent_status',new.status,
          'internal_planning_only',new.status='deferred','release_authority_granted',false));
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_release_child_tasks() from public,anon,authenticated,service_role;

create or replace function public.sutra_founder_defer_task(
  p_founder_telegram_user_id text,p_task_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; parent_status text; assigned_role text; owner_role text;
  project_status text; released_tasks jsonb;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 4 and 64
    or p_task_id is null or p_reason is null or length(trim(p_reason)) not between 8 and 500 then
    raise exception 'invalid founder task deferral' using errcode='22023';
  end if;
  if not exists(select 1 from public.company_settings s where s.key='founder_telegram_user_id'
      and s.value #>> '{}'=p_founder_telegram_user_id and s.founder_only and s.governance_sensitive) then
    raise exception 'founder identity required to defer a task' using errcode='42501';
  end if;
  select t.* into task_row from public.tasks t where t.id=p_task_id for update;
  if not found then raise exception 'task does not exist' using errcode='22023'; end if;
  select assigned.slug,owner.slug,p.status,parent.status
    into assigned_role,owner_role,project_status,parent_status
  from public.tasks t
  join public.agents assigned on assigned.id=t.assigned_agent_id and assigned.active
  join public.agents owner on owner.id=t.owner_agent_id and owner.active
  join public.projects p on p.id=t.project_id
  left join public.tasks parent on parent.id=t.parent_task_id
  where t.id=p_task_id;
  if assigned_role not in ('qa','security') or owner_role is distinct from assigned_role then
    raise exception 'only assigned QA or Security review tasks may be deferred' using errcode='42501';
  end if;
  if project_status not in ('approved','active') or parent_status is null
    or parent_status not in ('done','deferred') then
    raise exception 'task is outside an approved review chain' using errcode='42501';
  end if;
  if task_row.status not in ('backlog','ready','blocked') then
    raise exception 'task is not in a deferrable state' using errcode='22023';
  end if;
  if assigned_role='qa' and not exists(select 1 from public.tasks c join public.agents a on a.id=c.assigned_agent_id
      where c.parent_task_id=task_row.id and c.project_id=task_row.project_id and c.status='backlog' and a.slug='security') then
    raise exception 'QA deferral has no pending Security child to release' using errcode='42501';
  end if;
  if assigned_role='security' and not exists(select 1 from public.tasks c join public.agents a on a.id=c.assigned_agent_id
      where c.parent_task_id=task_row.id and c.project_id=task_row.project_id and c.status='backlog' and a.slug='devops') then
    raise exception 'Security deferral has no pending DevOps planning child to release' using errcode='42501';
  end if;
  update public.tasks set status='deferred',deferred_reason=trim(p_reason),
    deferred_by=p_founder_telegram_user_id,deferred_at=now(),updated_at=now()
    where id=task_row.id;
  select coalesce(jsonb_agg(jsonb_build_object('task_id',c.id,'role',a.slug) order by c.id),'[]'::jsonb)
    into released_tasks from public.tasks c join public.agents a on a.id=c.assigned_agent_id
    where c.parent_task_id=task_row.id and c.status='ready';
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',p_founder_telegram_user_id,'founder.task_review_deferred','task',task_row.id::text,
      jsonb_build_object('project_id',task_row.project_id,'role',assigned_role,
        'previous_status',task_row.status,'reason',trim(p_reason),'released_internal_planning_tasks',released_tasks,
        'review_completed',false,'spending_authority_changed',false,'release_authority_granted',false));
  return jsonb_build_object('task_id',task_row.id,'status','deferred','role',assigned_role,
    'released_internal_planning_tasks',released_tasks,'review_completed',false,
    'spending_authority_changed',false,'release_authority_granted',false);
end;
$$;
revoke all on function public.sutra_founder_defer_task(text,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_defer_task(text,uuid,text) to service_role;

create or replace function public.sutra_founder_defer_quality_chain(
  p_founder_telegram_user_id text,p_qa_task_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare qa_result jsonb; security_result jsonb; security_task_id uuid; security_task_count integer;
begin
  if p_qa_task_id is null then raise exception 'QA task ID is required' using errcode='22023'; end if;
  select count(*)::integer,(array_agg(c.id order by c.id))[1]
    into security_task_count,security_task_id from public.tasks qa
  join public.agents qa_agent on qa_agent.id=qa.assigned_agent_id and qa_agent.slug='qa'
  join public.tasks c on c.parent_task_id=qa.id and c.project_id=qa.project_id and c.status='backlog'
  join public.agents security_agent on security_agent.id=c.assigned_agent_id and security_agent.slug='security'
  where qa.id=p_qa_task_id;
  if security_task_count<>1 then
    raise exception 'QA task must have exactly one pending direct Security review child' using errcode='42501';
  end if;
  qa_result:=public.sutra_founder_defer_task(p_founder_telegram_user_id,p_qa_task_id,p_reason);
  security_result:=public.sutra_founder_defer_task(p_founder_telegram_user_id,security_task_id,p_reason);
  return jsonb_build_object('status','deferred','qa',qa_result,'security',security_result,
    'qa_and_security_incomplete',true,'release_authority_granted',false,'spending_authority_changed',false);
end;
$$;
revoke all on function public.sutra_founder_defer_quality_chain(text,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_defer_quality_chain(text,uuid,text) to service_role;

create or replace function public.sutra_founder_restore_deferred_task(
  p_founder_telegram_user_id text,p_task_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; parent_status text; assigned_role text; owner_role text; project_status text;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 4 and 64
    or p_task_id is null or p_reason is null or length(trim(p_reason)) not between 8 and 500 then
    raise exception 'invalid founder task restoration' using errcode='22023';
  end if;
  if not exists(select 1 from public.company_settings s where s.key='founder_telegram_user_id'
      and s.value #>> '{}'=p_founder_telegram_user_id and s.founder_only and s.governance_sensitive) then
    raise exception 'founder identity required to restore a task' using errcode='42501';
  end if;
  select t.* into task_row from public.tasks t where t.id=p_task_id for update;
  if not found then raise exception 'task does not exist' using errcode='22023'; end if;
  select assigned.slug,owner.slug,p.status,parent.status
    into assigned_role,owner_role,project_status,parent_status
  from public.tasks t
  join public.agents assigned on assigned.id=t.assigned_agent_id and assigned.active
  join public.agents owner on owner.id=t.owner_agent_id and owner.active
  join public.projects p on p.id=t.project_id
  left join public.tasks parent on parent.id=t.parent_task_id
  where t.id=p_task_id;
  if assigned_role not in ('qa','security') or owner_role is distinct from assigned_role then
    raise exception 'only an assigned QA or Security review task may be restored' using errcode='42501';
  end if;
  if project_status not in ('approved','active') or parent_status is distinct from 'done' then
    raise exception 'the preceding approved workflow stage must be complete before restoring review' using errcode='42501';
  end if;
  if task_row.status is distinct from 'deferred' then
    raise exception 'task is not currently deferred' using errcode='22023';
  end if;
  update public.tasks set status='ready',deferred_reason=null,deferred_by=null,deferred_at=null,updated_at=now()
    where id=task_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',p_founder_telegram_user_id,'founder.task_review_restored','task',task_row.id::text,
      jsonb_build_object('project_id',task_row.project_id,'role',assigned_role,
        'previous_deferred_reason',task_row.deferred_reason,'reason',trim(p_reason),
        'spending_authority_changed',false,'release_authority_granted',false));
  return jsonb_build_object('task_id',task_row.id,'status','ready','role',assigned_role,
    'spending_authority_changed',false,'release_authority_granted',false);
end;
$$;
revoke all on function public.sutra_founder_restore_deferred_task(text,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_restore_deferred_task(text,uuid,text) to service_role;

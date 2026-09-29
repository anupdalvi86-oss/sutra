-- Task status updates are synchronous events, not leased background runs.
-- Terminalize the stuck snapshots created by the old function, with an audit
-- record for each repaired row. Only old, lease-free task_update rows qualify.
create or replace function public.sutra_reconcile_task_update_runs()
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare repaired_count integer;
begin
  with targets as (
    select r.id,r.task_id,r.agent_id,r.started_at,r.created_at
    from public.agent_runs r
    where r.trigger_type='task_update' and r.status='running'
      and r.lease_token is null and r.lease_expires_at is null
      and r.created_at < now()-interval '10 minutes'
    for update skip locked
  ), repaired as (
    update public.agent_runs r
    set status='succeeded',finished_at=coalesce(r.finished_at,t.started_at,t.created_at)
    from targets t where r.id=t.id
    returning r.id,r.task_id,r.agent_id,r.finished_at
  ), logged as (
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    select 'system','sutra-task-update-reconciler','agent_run.task_update_terminalized',
      'agent_run',repaired.id::text,
      jsonb_build_object('task_id',repaired.task_id,'agent_id',repaired.agent_id,
        'finished_at',repaired.finished_at,'reason','synchronous_task_update_without_lease')
    from repaired returning id
  )
  select count(*)::integer into repaired_count from logged;
  return repaired_count;
end;
$$;
revoke all on function public.sutra_reconcile_task_update_runs() from public,anon,authenticated;
grant execute on function public.sutra_reconcile_task_update_runs() to service_role;

select public.sutra_reconcile_task_update_runs();

-- Keep the established founder scope guard and task transition checks. A
-- successful synchronous update is terminal immediately; blocking the task
-- marks its event blocked while also recording its completion time.
create or replace function public.sutra_update_task(
  p_actor_agent_id uuid,p_task_id uuid,p_status text,p_evidence jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare task_row public.tasks%rowtype; agent_slug text; event_status text; event_time timestamptz:=now();
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
  update public.tasks set status=p_status,updated_at=event_time where id=p_task_id;
  event_status:=case when p_status='blocked' then 'blocked' else 'succeeded' end;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at)
    values(p_actor_agent_id,task_row.project_id,p_task_id,'task_update',event_status,
      jsonb_build_object('previous_status',task_row.status),p_evidence,event_time,event_time);
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',agent_slug,'task.status_changed','task',p_task_id::text,
      jsonb_build_object('from',task_row.status,'to',p_status,'evidence_keys',
        (select coalesce(jsonb_agg(k),'[]'::jsonb) from jsonb_object_keys(p_evidence) as keys(k))));
  return jsonb_build_object('task_id',p_task_id,'status',p_status);
end;
$$;
revoke all on function public.sutra_update_task(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_update_task(uuid,uuid,text,jsonb) to service_role;

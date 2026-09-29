begin;
select plan(12);

select ok(has_function_privilege('service_role',
  'public.sutra_reconcile_task_update_runs()','execute'),
  'the bounded task-update repair is available to the internal service role');
select ok(not has_function_privilege('anon',
  'public.sutra_reconcile_task_update_runs()','execute'),
  'anonymous clients cannot repair task-update runs');

create temporary table task_update_fixture(
  task_id uuid,agent_id uuid,stale_run_id uuid,leased_run_id uuid
) on commit drop;
do $$
declare actor_id uuid; task_id uuid; stale_id uuid; leased_id uuid;
begin
  select id into actor_id from public.agents where slug='cpo' and active;
  insert into public.tasks(title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
    values('Task update lifecycle','Exercise terminal status event records.','["Event is terminal"]'::jsonb,
      'research','ready',actor_id,actor_id) returning id into task_id;
  insert into public.agent_runs(agent_id,task_id,trigger_type,status,input,output,started_at,created_at)
    values(actor_id,task_id,'task_update','running','{}'::jsonb,'{}'::jsonb,
      now()-interval '1 hour',now()-interval '1 hour') returning id into stale_id;
  insert into public.agent_runs(agent_id,task_id,trigger_type,status,input,output,started_at,created_at,
      lease_token,lease_expires_at)
    values(actor_id,task_id,'task_update','running','{}'::jsonb,'{}'::jsonb,
      now()-interval '1 hour',now()-interval '1 hour',gen_random_uuid(),now()+interval '5 minutes')
    returning id into leased_id;
  insert into task_update_fixture values(task_id,actor_id,stale_id,leased_id);
end;
$$;
grant select on task_update_fixture to service_role;

set local role service_role;
select is(public.sutra_reconcile_task_update_runs(),1,
  'repair terminalizes only the old task-update event without a lease');
select public.sutra_update_task((select agent_id from task_update_fixture),
  (select task_id from task_update_fixture),'in_progress','{"reason":"test start"}'::jsonb);
reset role;

select is((select status from public.agent_runs where id=(select stale_run_id from task_update_fixture)),
  'succeeded','the orphaned synchronous event is marked complete');
select ok((select finished_at=started_at from public.agent_runs
    where id=(select stale_run_id from task_update_fixture)),
  'repair preserves the original event completion time');
select ok(exists(select 1 from public.audit_log where action='agent_run.task_update_terminalized'
  and resource_id=(select stale_run_id::text from task_update_fixture)),
  'every repaired event has an audit record');
select is((select status from public.agent_runs where id=(select leased_run_id from task_update_fixture)),
  'running','a run with a lease is left untouched');
select is((select status from public.tasks where id=(select task_id from task_update_fixture)),
  'in_progress','the task transition itself still succeeds');
select is((select status from public.agent_runs where task_id=(select task_id from task_update_fixture)
    and trigger_type='task_update' and input->>'previous_status'='ready'),
  'succeeded','a successful in-progress event is terminal immediately');
select ok((select finished_at is not null from public.agent_runs where task_id=(select task_id from task_update_fixture)
    and trigger_type='task_update' and input->>'previous_status'='ready'),
  'successful task-update events record their completion time');

set local role service_role;
select public.sutra_update_task((select agent_id from task_update_fixture),
  (select task_id from task_update_fixture),'blocked','{"reason":"test block"}'::jsonb);
reset role;
select is((select status from public.agent_runs where task_id=(select task_id from task_update_fixture)
    and trigger_type='task_update' and input->>'previous_status'='in_progress'),
  'blocked','a blocked task is represented as a terminal blocked event');
select ok((select finished_at is not null from public.agent_runs where task_id=(select task_id from task_update_fixture)
    and trigger_type='task_update' and input->>'previous_status'='in_progress'),
  'blocked task-update events record their completion time');

select * from finish();
rollback;

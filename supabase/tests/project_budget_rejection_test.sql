begin;
select no_plan();

create temporary table project_rejection_fixture(project_id uuid, approval_id uuid, cfo_id uuid, task_id uuid) on commit drop;
do $$
declare project_id uuid; approval_id uuid; cfo_id uuid; cpo_id uuid; task_id uuid;
begin
  select id into cfo_id from public.agents where slug='cfo' and active limit 1;
  select id into cpo_id from public.agents where slug='cpo' and active limit 1;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('rejected-project-'||gen_random_uuid(),'Rejected project fixture',
      'A proposed project used to test rejection state synchronization.','proposed',500,'EUR','test')
    returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,amount,currency,
      summary,status)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],500,'EUR',
      'Project rejection fixture','pending')
    returning id into approval_id;
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Unstarted research fixture','Research must not run before project approval.',
      '["Cited findings"]'::jsonb,'research','blocked',cpo_id,cpo_id)
    returning id into task_id;
  insert into project_rejection_fixture values(project_id,approval_id,cfo_id,task_id);
end;
$$;
grant select on project_rejection_fixture to service_role;

set local role service_role;
select is((public.sutra_decide_role_approval(
  (select approval_id from project_rejection_fixture),
  (select cfo_id::text from project_rejection_fixture),
  'cfo','reject','Fixture rejection') ->> 'status'), 'rejected',
  'the CFO role decision rejects the project budget approval');
reset role;

select is((select status from public.projects where id=(select project_id from project_rejection_fixture)),
  'rejected','a role-rejected project budget marks the proposed project rejected');
select is((select status from public.tasks where id=(select task_id from project_rejection_fixture)),
  'cancelled','unstarted work is cancelled when its project is role-rejected');
select ok(exists(
  select 1 from public.audit_log
   where action='project.rejected_by_role_review'
     and resource_id=(select project_id::text from project_rejection_fixture)
     and details->>'approval_id'=(select approval_id::text from project_rejection_fixture)
), 'project state synchronization is audit logged with its approval reference');
select ok(exists(
  select 1 from public.audit_log
   where action='task.cancelled_with_rejected_project'
     and resource_id=(select task_id::text from project_rejection_fixture)
), 'cancelling unstarted research is audit logged');

select * from finish();
rollback;

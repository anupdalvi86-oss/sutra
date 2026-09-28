begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

create temporary table github_retry_fixture(task_id uuid,dispatch_id uuid) on commit drop;
do $$
declare project_id uuid; task_id uuid; dispatch_id uuid; developer_id uuid; approval_id uuid;
begin
  select id into developer_id from public.agents where slug='developer' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('retry-github-'||gen_random_uuid(),'GitHub retry fixture',
      'Fixture for bounded founder-only issue dispatch retry.','approved',500,'EUR','test')
    returning id into project_id;
  insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'developer_scope',null,'founder:test',array['founder'],
      '{"founder":{"decision":"approve"}}'::jsonb,0,'EUR','Approved developer task scope',
      'approved','12345678',now()) returning id into approval_id;
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Approved retry fixture','Create a reviewable engineering change.',
      '["Task stays within founder-approved scope"]'::jsonb,'engineering','ready',developer_id,developer_id)
    returning id into task_id;
  update public.approvals set action_ref=task_id::text where id=approval_id;
  insert into public.github_task_dispatches(task_id,status,attempts,last_error)
    values(task_id,'failed',3,'github_permission_denied') returning id into dispatch_id;
  insert into github_retry_fixture values(task_id,dispatch_id);
end;
$$;

grant select on github_retry_fixture to service_role;
grant select on github_retry_fixture to anon;
set local role service_role;
select throws_ok($$select public.sutra_founder_retry_github_task_dispatch('99999999',(select task_id from github_retry_fixture))$$,
  '42501',null,'a nonfounder cannot retry a failed GitHub dispatch');
select throws_ok($$select public.sutra_founder_retry_github_task_dispatch('12345678',null)$$,
  '22023',null,'malformed retry requests are rejected');
create temporary table github_retry_result(payload jsonb) on commit drop;
insert into github_retry_result select public.sutra_founder_retry_github_task_dispatch(
  '12345678',(select task_id from github_retry_fixture));
reset role;

select is((select payload->>'status' from github_retry_result),'queued',
  'founder retry requeues the existing dispatch');
select is((select (payload->>'founder_retry_number')::integer from github_retry_result),1,
  'founder retry is counted');
select is((select (payload->>'founder_retries_remaining')::integer from github_retry_result),2,
  'founder retries have a lifetime limit');
select is((select payload->>'spending_authorized' from github_retry_result),'false',
  'retry does not authorize spending');
select is((select status from public.github_task_dispatches where id=(select dispatch_id from github_retry_fixture)),'queued',
  'dispatch returns to the queue');
select is((select attempts from public.github_task_dispatches where id=(select dispatch_id from github_retry_fixture)),0,
  'each founder-approved retry receives one bounded three-attempt cycle');
select is((select last_error from public.github_task_dispatches where id=(select dispatch_id from github_retry_fixture)),null::text,
  'the resolved permission error is cleared before retry');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and actor_id='12345678' and action='founder.github_dispatch_retry_requested'
  and resource_id=(select task_id::text from github_retry_fixture)
  and details->>'previous_error_code'='github_permission_denied'),
  'retry request records the founder and previous failure in the audit log');

-- The new RPC is not directly executable by client roles.
set local role anon;
select throws_ok($$select public.sutra_founder_retry_github_task_dispatch('12345678',(select task_id from github_retry_fixture))$$,
  '42501',null,'anonymous clients cannot call the retry RPC');
reset role;

update public.github_task_dispatches set status='failed',attempts=3,
  founder_retry_count=3,last_error='github_permission_denied'
  where id=(select dispatch_id from github_retry_fixture);
set local role service_role;
select throws_ok($$select public.sutra_founder_retry_github_task_dispatch('12345678',(select task_id from github_retry_fixture))$$,
  '42501',null,'the founder retry lifetime cap cannot be exceeded');
reset role;

select * from finish();
rollback;

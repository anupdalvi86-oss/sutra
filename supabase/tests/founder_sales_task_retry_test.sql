begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

select public.sutra_set_agent_model_spend_profile(
  '12345678','openai','gpt-6-luna',0.2,0.5,100000,10000,true
);

create temporary table sales_retry_fixture(task_id uuid,run_id uuid) on commit drop;
do $$
declare
  project_id uuid;
  task_id uuid;
  run_id uuid;
  sales_id uuid;
  expense_id uuid;
  attempt_no integer;
  reserve_amount numeric(14,2);
begin
  select id into sales_id from public.agents where slug='sales' and active;
  select greatest(0.01,ceil((max_input_tokens*3*input_eur_per_million_tokens
      + max_output_tokens*3*output_eur_per_million_tokens)/10000)/100)
    into reserve_amount from public.agent_model_spend_profiles
    where provider='openai' and model='gpt-6-luna' and active;
  if sales_id is null or reserve_amount is null then
    raise exception 'Sales retry test prerequisites are missing';
  end if;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('retry-sales-'||gen_random_uuid(),'Sales retry fixture',
      'Approved fixture for founder-only Sales artifact recovery.','approved',500,'EUR','test')
    returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      500,'EUR','Approved fixture project budget','approved','12345678',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Prepare sales handoff','Create internal sales materials.',
      '["The handoff is recorded","No outreach is sent"]'::jsonb,'planning','blocked',sales_id,sales_id)
    returning id into task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,finished_at,attempt_count)
    values(sales_id,project_id,task_id,'task_artifact','failed','{}'::jsonb,
      '{"error_code":"invalid_agent_output","failure_detail_code":"invalid_artifact_schema"}'::jsonb,
      now()-interval '1 minute',now(),3) returning id into run_id;
  for attempt_no in 1..3 loop
    insert into public.expenses(category,description,amount,actual_amount,currency,status,requested_by,approved_at)
      values('ai_inference','Reconciled Sales retry fixture',reserve_amount,0.01,'EUR','paid','test',now())
      returning id into expense_id;
    insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
        reserved_amount,actual_amount,usage,status,settled_at)
      values(run_id,attempt_no,expense_id,'openai','gpt-6-luna',reserve_amount,0.01,
        '{"input_tokens":1,"output_tokens":1}'::jsonb,'reconciled',now());
  end loop;
  insert into sales_retry_fixture values(task_id,run_id);
end;
$$;

grant select on sales_retry_fixture to service_role;
select ok(not has_function_privilege('anon',
  'public.sutra_founder_retry_sales_task_artifact(text,uuid)','execute'),
  'anon cannot retry a Sales artifact');
select ok(not has_function_privilege('authenticated',
  'public.sutra_founder_retry_sales_task_artifact(text,uuid)','execute'),
  'authenticated users cannot retry a Sales artifact');
select ok(has_function_privilege('service_role',
  'public.sutra_founder_retry_sales_task_artifact(text,uuid)','execute'),
  'the service role can invoke the guarded founder RPC');

set local role service_role;
select throws_ok($$select public.sutra_founder_retry_sales_task_artifact(
  '99999999',(select task_id from sales_retry_fixture))$$,
  '42501',null,'nonfounder cannot retry an approved Sales task');
create temporary table sales_retry_result(payload jsonb) on commit drop;
insert into sales_retry_result select public.sutra_founder_retry_sales_task_artifact(
  '12345678',(select task_id from sales_retry_fixture));
select throws_ok($$select public.sutra_founder_retry_sales_task_artifact(
  '12345678',(select task_id from sales_retry_fixture))$$,
  '42501',null,'the one-time founder recovery cannot be reused');
reset role;

select is((select payload->>'status' from sales_retry_result),'ready',
  'founder recovery requeues only the existing approved Sales task');
select is((select status from public.tasks where id=(select task_id from sales_retry_fixture)),'ready',
  'the task becomes claimable after the recovery');
select is((select count(*) from public.agent_runs where task_id=(select task_id from sales_retry_fixture)),1::bigint,
  'the recovery itself does not create a provider execution');
select is((select count(*) from public.agent_run_spend_reservations
  where agent_run_id=(select run_id from sales_retry_fixture)),3::bigint,
  'the recovery does not create, alter, or release a spend reservation');
select is((select count(*) from public.expenses where description='Reconciled Sales retry fixture'),3::bigint,
  'the recovery does not create an expense');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.sales_task_artifact_retry_requested'
  and resource_id=(select task_id::text from sales_retry_fixture)
  and details->>'project_spending_authorized'='false'
  and details->>'merge_authority_granted'='false'
  and details->>'release_authority_granted'='false'),
  'the founder recovery is audited without expanding project, merge, or release authority');

select * from finish();
rollback;

begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

create temporary table retry_fixture(task_id uuid,run_id uuid,project_id uuid) on commit drop;
do $$
declare project_id uuid; task_id uuid; run_id uuid; pm_id uuid; expense_id uuid;
begin
  select id into pm_id from public.agents where slug='product_manager' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('retry-product-plan-'||gen_random_uuid(),'Retry fixture','Fixture for founder-only task recovery.',
      'approved',500,'EUR','test') returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      500,'EUR','Approved fixture project budget','approved','12345678',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Create approved product requirements and implementation plan',
      'Create a bounded product plan.', '["The plan is persisted"]'::jsonb,'planning','blocked',pm_id,pm_id)
    returning id into task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,finished_at,attempt_count)
    values(pm_id,project_id,task_id,'task_artifact','failed','{}'::jsonb,
      '{"error_code":"unknown_or_overrun_spend","failure_detail_code":"invalid_evidence"}'::jsonb,
      now(),now(),1) returning id into run_id;
  insert into public.expenses(category,description,amount,currency,status,requested_by,approved_at)
    values('ai_inference','Unknown-usage fixture reserve',0.03,'EUR','approved','test',now())
    returning id into expense_id;
  insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
      reserved_amount,usage,status,settled_at)
    values(run_id,1,expense_id,'openai','gpt-6-luna',0.03,'{}'::jsonb,'unknown',now());
  insert into retry_fixture values(task_id,run_id,project_id);
end;
$$;

set local role service_role;
select throws_ok($$select public.sutra_founder_retry_product_task_artifact('99999999',(select task_id from retry_fixture))$$,
  '42501',null,'nonfounder cannot retry an approved product task');
create temporary table retry_result(payload jsonb) on commit drop;
insert into retry_result select public.sutra_founder_retry_product_task_artifact(
  '12345678',(select task_id from retry_fixture));
select is((select payload->>'status' from retry_result),'ready',
  'founder recovery requeues only the blocked PM task');
select is((select (payload->>'preserved_unknown_reservations')::integer from retry_result),1,
  'retry preserves the unknown usage reservation');
select is((select (payload->>'project_spending_authorized')::boolean from retry_result),false,
  'retry does not authorize project spending');
select is((select status from public.tasks where id=(select task_id from retry_fixture)),'ready',
  'recovered task becomes claimable');
select is((select status from public.agent_run_spend_reservations
  where agent_run_id=(select run_id from retry_fixture)),'unknown',
  'prior model spend remains reserved as unknown');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.product_task_retry_requested'
  and resource_id=(select task_id::text from retry_fixture)),
  'PM task retry is founder-audited');
select throws_ok($$select public.sutra_founder_retry_product_task_artifact('12345678',(select task_id from retry_fixture))$$,
  '42501',null,'a requeued task cannot be retried again without another failed run');

select * from finish();
rollback;

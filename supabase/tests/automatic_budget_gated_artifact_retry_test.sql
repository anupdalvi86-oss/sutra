begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true;
select public.sutra_set_agent_model_spend_profile(
  '12345678','openai','gpt-6-luna',0.2,0.5,100000,10000,true);

create temporary table automatic_retry_fixture(task_id uuid,project_id uuid,run_id uuid) on commit drop;
do $$
declare
  project_id uuid;
  task_id uuid;
  run_id uuid;
  pm_id uuid;
  expense_id uuid;
begin
  select id into pm_id from public.agents where slug='product_manager' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('automatic-retry-'||gen_random_uuid(),'Automatic retry fixture',
      'Internal fixture for a budget-gated artifact retry.','approved',100,'EUR','test')
    returning id into project_id;
  update public.projects set status='active',budget_assessment_status='within_cap',
      budget_assessed_at=now(),budget_assessment='{"estimated_total_eur":50,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"development","amount_eur":50,"basis":"Test fixture."}]}'::jsonb
    where id=project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      100,'EUR','Approved fixture budget','approved','test',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Recover a malformed but reconciled artifact',
      'Repeat the same bounded internal plan task once.', '["Persist the plan"]'::jsonb,
      'planning','blocked',pm_id,pm_id) returning id into task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,finished_at,attempt_count)
    values(pm_id,project_id,task_id,'task_artifact','failed','{"role":"product_manager"}'::jsonb,
      '{"error_code":"invalid_agent_output","failure_detail_code":"invalid_artifact_schema","usage_state":"reconciled"}'::jsonb,now()-interval '1 minute',now(),3)
    returning id into run_id;
  insert into public.expenses(project_id,category,description,amount,actual_amount,currency,status,
      requested_by,approved_at,incurred_at)
    values(project_id,'ai_inference','Reconciled retry fixture',0.08,0.01,'EUR','paid','test',now(),now())
    returning id into expense_id;
  insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
      reserved_amount,actual_amount,usage,status,settled_at)
    values(run_id,3,expense_id,'openai','gpt-6-luna',0.08,0.01,
      '{"input_tokens":1,"output_tokens":1}'::jsonb,'reconciled',now());
  insert into automatic_retry_fixture values(task_id,project_id,run_id);
end;
$$;
grant select on automatic_retry_fixture to service_role;

create temporary table automatic_retry_claim(payload jsonb) on commit drop;
grant insert,select on automatic_retry_claim to service_role;
set local role service_role;
insert into automatic_retry_claim select public.sutra_claim_task_agent_run('sutra-worker-auto1234');
reset role;

select is((select payload->'task_artifact'->>'task_id' from automatic_retry_claim),
  (select task_id::text from automatic_retry_fixture),
  'the worker claims the same eligible task after one automatic retry is audited');
select is((select payload->>'attempt' from automatic_retry_claim),'1',
  'automatic recovery creates a fresh bounded run');
select is((select status from public.tasks where id=(select task_id from automatic_retry_fixture)),
  'in_progress','an eligible terminal task returns to the normal worker queue');
select ok(exists(select 1 from public.audit_log where actor_type='system'
  and action='task.artifact.automatic_retry_queued'
  and resource_id=(select task_id::text from automatic_retry_fixture)
  and details->>'fresh_spend_reservation_required'='true'
  and details->>'spending_authority_changed'='false'),
  'the requeue is audited and explicitly requires the ordinary fresh spend reservation');
select is((select status from public.agent_run_spend_reservations
  where agent_run_id=(select run_id from automatic_retry_fixture) and attempt=3),
  'reconciled','the prior reconciled usage record is preserved');
select ok(not has_function_privilege('anon',
  'public.sutra_claim_task_agent_run(text)','execute'),
  'anonymous users cannot invoke automatic retries through the worker claim RPC');

select * from finish();
rollback;

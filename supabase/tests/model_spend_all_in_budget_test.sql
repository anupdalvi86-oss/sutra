begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true;
select public.sutra_set_agent_model_spend_profile(
  '12345678','openai','gpt-6-luna',0.2,0.5,100000,10000,true);
select public.sutra_set_agent_model_spend_profile(
  '12345678','kimi-coding','kimi-k2.6',0.2,0.5,100000,10000,true);

create temporary table model_budget_fixture(
  project_id uuid, task_id uuid, pm_id uuid, cpo_id uuid, safe_project_id uuid, safe_task_id uuid
) on commit drop;
do $$
declare
  project_id uuid;
  task_id uuid;
  pm_id uuid;
  cpo_id uuid;
  cpo_task_id uuid;
  safe_project_id uuid;
  safe_task_id uuid;
  failed_run_id uuid;
  expense_id uuid;
begin
  select id into pm_id from public.agents where slug='product_manager' and active;
  select id into cpo_id from public.agents where slug='cpo' and active;

  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('inference-cap-'||gen_random_uuid(),'Inference hard-cap fixture',
      'A bounded model reservation must count against the same all-in project ceiling.',
      'active',0.10,'EUR','test') returning id into project_id;
  update public.projects set budget_assessment_status='within_cap',budget_assessed_at=now(),
      budget_assessment='{"estimated_total_eur":0.10,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"development","amount_eur":0.10,"basis":"Model spend gate test fixture."}]}'::jsonb
    where id=project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      0.10,'EUR','Approved fixture budget','approved','12345678',now());

  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Try a new model reservation','Use the existing all-in policy gate.',
      '["No provider call starts without a reservation"]'::jsonb,'planning','ready',pm_id,pm_id)
    returning id into task_id;
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Prior Kimi task','An unknown Kimi reservation remains held.',
      '["Preserve the unknown amount"]'::jsonb,'research','blocked',cpo_id,cpo_id)
    returning id into cpo_task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,finished_at,attempt_count)
    values(cpo_id,project_id,cpo_task_id,'task_artifact','failed','{"role":"cpo"}'::jsonb,
      '{"error_code":"unknown_spend"}'::jsonb,now()-interval '1 minute',now(),1)
    returning id into failed_run_id;
  insert into public.expenses(project_id,category,description,amount,currency,status,requested_by,approved_at)
    values(project_id,'ai_inference','Held Kimi usage fixture',0.08,'EUR','approved','cpo',now())
    returning id into expense_id;
  insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
      reserved_amount,usage,status,settled_at)
    values(failed_run_id,1,expense_id,'kimi-coding','kimi-k2.6',0.08,'{}'::jsonb,'unknown',now());

  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('inference-safe-'||gen_random_uuid(),'In-cap model fixture',
      'A model reservation below the all-in cap remains allowed.',
      'active',0.10,'EUR','test') returning id into safe_project_id;
  update public.projects set budget_assessment_status='within_cap',budget_assessed_at=now(),
      budget_assessment='{"estimated_total_eur":0.10,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"development","amount_eur":0.10,"basis":"Model spend gate test fixture."}]}'::jsonb
    where id=safe_project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(safe_project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      0.10,'EUR','Approved fixture budget','approved','12345678',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(safe_project_id,'Reserve within the all-in cap','Use the same database price profile.',
      '["Reservation appears in the shared ledger"]'::jsonb,'planning','ready',pm_id,pm_id)
    returning id into safe_task_id;

  insert into model_budget_fixture values(project_id,task_id,pm_id,cpo_id,safe_project_id,safe_task_id);
end;
$$;
grant select on model_budget_fixture to service_role;

create temporary table capped_model_claim(payload jsonb) on commit drop;
create temporary table safe_model_claim(payload jsonb) on commit drop;
create temporary table safe_model_reservation(payload jsonb) on commit drop;
grant insert,select on capped_model_claim to service_role;
grant insert,select on safe_model_claim to service_role;
grant insert,select on safe_model_reservation to service_role;
set local role service_role;
insert into capped_model_claim select public.sutra_claim_task_agent_run('sutra-worker-cap12345678');
select throws_ok($$select public.sutra_reserve_agent_run_spend_from_profile(
  'sutra-worker-cap12345678',(select (payload->>'run_id')::uuid from capped_model_claim),
  (select (payload->>'lease_token')::uuid from capped_model_claim),'openai','gpt-6-luna')$$,
  '23514',null,'model inference cannot exceed remaining all-in initiative funds');
insert into safe_model_claim select public.sutra_claim_task_agent_run('sutra-worker-safe1234');
insert into safe_model_reservation select public.sutra_reserve_agent_run_spend_from_profile(
  'sutra-worker-safe1234',(select (payload->>'run_id')::uuid from safe_model_claim),
  (select (payload->>'lease_token')::uuid from safe_model_claim),'openai','gpt-6-luna');
reset role;

select is((select status from public.initiative_budget_ledger
  where project_id=(select project_id from model_budget_fixture)
    and description='Held Kimi usage fixture'),'unknown',
  'the previous unknown reservation remains held after the hard-stop check');
select is((select count(*)::integer from public.agent_run_spend_reservations
  where agent_run_id=(select (payload->>'run_id')::uuid from capped_model_claim)),0,
  'the over-cap run receives no new model reservation');
select is((select payload->>'status' from safe_model_reservation),'approved',
  'a reservation that fits within the all-in cap still succeeds');
select is((select status from public.initiative_budget_ledger
  where project_id=(select safe_project_id from model_budget_fixture)
    and description like 'Bounded Hermes review for product_manager%'),'reserved',
  'the successful model reservation is mirrored to the shared initiative ledger');
select ok(exists(select 1 from public.audit_log where action='agent_run.spend_reserved'
  and resource_type='agent_run_spend_reservation'
    and resource_id=(select (payload->>'reservation_id') from safe_model_reservation)),
  'successful model reservations retain the existing audit event');

select * from finish();
rollback;

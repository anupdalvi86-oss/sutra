begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

select public.sutra_set_agent_model_spend_profile(
  '12345678','openai','gpt-6-luna',0.2,0.5,100000,10000,true
);

create temporary table architect_retry_fixture(task_id uuid,run_id uuid) on commit drop;
do $$
declare project_id uuid; task_id uuid; run_id uuid; architect_id uuid;
  expense_id uuid; reserve_amount numeric(14,2);
begin
  select id into architect_id from public.agents where slug='architect' and active;
  select greatest(0.01,ceil((max_input_tokens*3*input_eur_per_million_tokens
      + max_output_tokens*3*output_eur_per_million_tokens)/10000)/100)
    into reserve_amount from public.agent_model_spend_profiles
    where provider='openai' and model='gpt-6-luna' and active;
  if reserve_amount is null then raise exception 'fixture model price profile was not configured'; end if;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('retry-architecture-'||gen_random_uuid(),'Retry architecture fixture',
      'Fixture for founder-only architecture task recovery.','approved',500,'EUR','test')
    returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      500,'EUR','Approved fixture project budget','approved','12345678',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Produce architecture and technical design','Record interfaces and security assumptions.',
      '["Design is recorded and linked to the project"]'::jsonb,'engineering','in_progress',architect_id,architect_id)
    returning id into task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,finished_at,attempt_count)
    values(architect_id,project_id,task_id,'task_artifact','failed',
      '{"role":"architect"}'::jsonb,'{"error_code":"unknown_or_overrun_spend"}'::jsonb,
      now(),now(),1) returning id into run_id;
  insert into public.expenses(category,description,amount,currency,status,requested_by,approved_at)
    values('ai_inference','Unknown architecture-run fixture reserve',reserve_amount,'EUR','approved','test',now())
    returning id into expense_id;
  insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
      reserved_amount,usage,status,settled_at)
    values(run_id,1,expense_id,'openai','gpt-6-luna',reserve_amount,'{}'::jsonb,'unknown',now());
  insert into architect_retry_fixture values(task_id,run_id);
end;
$$;

grant select on architect_retry_fixture to service_role;
set local role service_role;
select throws_ok($$select public.sutra_founder_retry_architecture_task_artifact('99999999',(select task_id from architect_retry_fixture))$$,
  '42501',null,'nonfounder cannot retry an architecture task');
create temporary table architecture_retry_result(payload jsonb) on commit drop;
insert into architecture_retry_result select public.sutra_founder_retry_architecture_task_artifact(
  '12345678',(select task_id from architect_retry_fixture));
reset role;
select is((select payload->>'status' from architecture_retry_result),'ready',
  'founder recovery requeues the blocked architecture task');
select is((select (payload->>'preserved_unknown_reservations')::integer from architecture_retry_result),1,
  'architecture retry preserves the unknown usage reservation');
select is((select (payload->>'project_spending_authorized')::boolean from architecture_retry_result),false,
  'architecture retry does not grant project spending authority');
select is((select (payload->>'attempts_remaining')::integer from architecture_retry_result),2,
  'architecture retry remains within the three-run ceiling');
select is((select status from public.tasks where id=(select task_id from architect_retry_fixture)),'ready',
  'recovered architecture task becomes claimable');
select is((select status from public.agent_run_spend_reservations
  where agent_run_id=(select run_id from architect_retry_fixture)),'unknown',
  'prior architecture usage remains reserved as unknown');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.architect_task_retry_requested'
  and resource_id=(select task_id::text from architect_retry_fixture)),
  'architecture retry is founder-audited');
set local role service_role;
select throws_ok($$select public.sutra_founder_retry_architecture_task_artifact('12345678',(select task_id from architect_retry_fixture))$$,
  '42501',null,'a requeued architecture task cannot be retried a second time');

select * from finish();
rollback;

begin;
select plan(15);

select ok(has_function_privilege('service_role',
  'public.sutra_founder_retry_cpo_research_task(text,uuid)','execute'),
  'the CPO retry is available to the internal service role');
select ok(not has_function_privilege('anon',
  'public.sutra_founder_retry_cpo_research_task(text,uuid)','execute'),
  'anonymous clients cannot request a CPO retry');

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value,updated_by=excluded.updated_by;
select public.sutra_set_agent_model_spend_profile(
  '12345678','openai','gpt-6-luna',0.0877,0.4385,100000,2200,true);

create temporary table cpo_retry_fixture(case_id integer,task_id uuid,failed_run_id uuid)
  on commit drop;
create temporary table cpo_retry_result(payload jsonb) on commit drop;
do $$
declare project_id uuid; cpo_id uuid; pm_id uuid; task_id uuid; failed_id uuid;
  active_id uuid; expense_id uuid; reserve_amount numeric(14,2); case_no integer;
  task_owner uuid;
begin
  select id into cpo_id from public.agents where slug='cpo' and active;
  select id into pm_id from public.agents where slug='product_manager' and active;
  select greatest(0.01,ceil((max_input_tokens*3*input_eur_per_million_tokens
      + max_output_tokens*3*output_eur_per_million_tokens)/10000)/100)
    into reserve_amount from public.agent_model_spend_profiles
    where provider='openai' and model='gpt-6-luna' and active;
  if cpo_id is null or pm_id is null or reserve_amount is null then
    raise exception 'CPO retry test prerequisites are missing';
  end if;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('cpo-retry-'||gen_random_uuid(),'Approved CPO retry fixture',
      'Internal market research recovery test.','approved',500,'EUR','test')
    returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      500,'EUR','Approved CPO retry fixture budget','approved','12345678',now());
  for case_no in 1..4 loop
    task_owner:=case when case_no=2 then pm_id else cpo_id end;
    insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
        owner_agent_id,assigned_agent_id)
      values(project_id,'CPO research retry case '||case_no,
        'Recover one bounded internal research task.','["Cited sources recorded"]'::jsonb,
        'research','blocked',task_owner,task_owner) returning id into task_id;
    insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
        started_at,finished_at,attempt_count)
      values(cpo_id,project_id,task_id,'task_artifact','failed','{"role":"cpo"}'::jsonb,
        '{"error_code":"unknown_or_overrun_spend","failure_detail_code":"malformed_json"}'::jsonb,
        now()-interval '1 minute',now(),1) returning id into failed_id;
    insert into public.expenses(project_id,category,description,amount,currency,status,
        requested_by,approved_at)
      values(project_id,'ai_inference','CPO unknown usage fixture',reserve_amount,'EUR',
        'approved','test',now()) returning id into expense_id;
    insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
        reserved_amount,usage,status,settled_at)
      values(failed_id,1,expense_id,'openai','gpt-6-luna',reserve_amount,'{}'::jsonb,'unknown',now());
    insert into cpo_retry_fixture values(case_no,task_id,failed_id);
    if case_no=3 then
      insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
          started_at,attempt_count,lease_token,lease_expires_at)
        values(cpo_id,project_id,task_id,'task_artifact','running','{"role":"cpo"}'::jsonb,
          '{}'::jsonb,now(),1,gen_random_uuid(),now()+interval '5 minutes') returning id into active_id;
    elsif case_no=4 then
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('founder','12345678','founder.cpo_research_task_retry_requested','task',task_id::text,'{}'::jsonb),
              ('founder','12345678','founder.cpo_research_task_retry_requested','task',task_id::text,'{}'::jsonb);
    end if;
  end loop;
end;
$$;
grant select on cpo_retry_fixture to service_role;
grant insert,select on cpo_retry_result to service_role;

set local role service_role;
select throws_ok($$select public.sutra_founder_retry_cpo_research_task('99999999',
  (select task_id from cpo_retry_fixture where case_id=1))$$,
  '42501',null,'a nonfounder cannot retry CPO research');
insert into cpo_retry_result select public.sutra_founder_retry_cpo_research_task(
  '12345678',(select task_id from cpo_retry_fixture where case_id=1));
reset role;

select is((select payload->>'status' from cpo_retry_result),'ready',
  'founder recovery requeues the same blocked CPO research task');
select is((select (payload->>'attempts_remaining')::integer from cpo_retry_result),2,
  'CPO recovery retains a three-run total ceiling');
select is((select (payload->>'preserved_unknown_reservations')::integer from cpo_retry_result),1,
  'CPO retry reports the held unknown reservation');
select is((select payload->>'model' from cpo_retry_result),'gpt-6-luna',
  'CPO retry is locked to the configured OpenAI model');
select is((select (payload->>'project_spending_authorized')::boolean from cpo_retry_result),false,
  'CPO retry adds no project spending authority');
select is((select status from public.tasks where id=(select task_id from cpo_retry_fixture where case_id=1)),
  'ready','the original approved task becomes claimable');
select is((select status from public.agent_run_spend_reservations
  where agent_run_id=(select failed_run_id from cpo_retry_fixture where case_id=1)),
  'unknown','the original usage reservation remains unknown');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.cpo_research_task_retry_requested'
  and resource_id=(select task_id::text from cpo_retry_fixture where case_id=1)),
  'the recovery request is founder-audited');

set local role service_role;
select throws_ok($$select public.sutra_founder_retry_cpo_research_task('12345678',
  (select task_id from cpo_retry_fixture where case_id=1))$$,
  '42501',null,'a queued retry cannot be submitted twice');
select throws_ok($$select public.sutra_founder_retry_cpo_research_task('12345678',
  (select task_id from cpo_retry_fixture where case_id=2))$$,
  '42501',null,'only the assigned CPO can retry this research task');
select throws_ok($$select public.sutra_founder_retry_cpo_research_task('12345678',
  (select task_id from cpo_retry_fixture where case_id=3))$$,
  '42501',null,'an active leased research run cannot be replaced');
select throws_ok($$select public.sutra_founder_retry_cpo_research_task('12345678',
  (select task_id from cpo_retry_fixture where case_id=4))$$,
  '42501',null,'the retry request count enforces the three-run ceiling');
reset role;

select * from finish();
rollback;

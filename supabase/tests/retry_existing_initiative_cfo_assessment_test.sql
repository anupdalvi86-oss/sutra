begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true;
select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-6-luna',1,1,1000,1000,true);
create temporary table cfo_retry_fixture on commit drop as
  select gen_random_uuid() as project_id,(select id from public.agents where slug='cfo' and active) as cfo_id,
    gen_random_uuid() as run_id,gen_random_uuid() as expense_id;
insert into public.projects(id,slug,name,description,status,requested_budget,currency,created_by)
  select project_id,'cfo-retry-'||replace(project_id::text,'-',''),'CFO retry fixture',
    'A bounded existing initiative CFO retry test fixture.','active',17.60,'EUR','founder:12345678'
  from cfo_retry_fixture;
insert into public.agent_runs(id,agent_id,project_id,trigger_type,status,run_order,input,output,attempt_count,finished_at)
  select run_id,cfo_id,project_id,'founder_proposal','failed',1,
    '{"request":"Founder-requested CFO-only all-in budget assessment of the existing initiative. Scope: test."}'::jsonb,
    '{"error_code":"unknown_or_overrun_spend","failure_detail_code":"invalid_evidence"}'::jsonb,1,now()
  from cfo_retry_fixture;
insert into public.expenses(id,project_id,agent_id,category,description,amount,currency,status,requested_by,actual_amount)
  select expense_id,project_id,cfo_id,'ai_inference','Unknown failed CFO fixture',0.03,'EUR','approved','cfo',null
  from cfo_retry_fixture;
insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
    reserved_amount,usage,status)
  select run_id,1,expense_id,'openai','gpt-6-luna',0.03,'{}'::jsonb,'unknown' from cfo_retry_fixture;

select throws_ok($$select public.sutra_retry_existing_initiative_cfo_assessment(
  '99999999',(select run_id from cfo_retry_fixture))$$,
  '42501',null,'non-founder callers cannot retry the CFO assessment');
select is((public.sutra_retry_existing_initiative_cfo_assessment(
  '12345678',(select run_id from cfo_retry_fixture))->>'preserved_unknown_reservations')::integer,
  1,'the bounded recovery preserves the prior unknown reservation');
select is((select status from public.agent_runs where id=(select run_id from cfo_retry_fixture)),
  'queued','the same CFO run is requeued for its next bounded attempt');
select is((select requested_budget from public.projects where id=(select project_id from cfo_retry_fixture)),
  17.60::numeric,'retrying never raises or alters the initiative budget');
select ok(exists(select 1 from public.agent_run_spend_reservations where agent_run_id=(select run_id from cfo_retry_fixture)
  and attempt=1 and status='unknown' and reserved_amount=0.03),
  'the original unknown usage remains reserved unchanged');
select ok(exists(select 1 from public.audit_log where actor_type='system'
  and action='initiative.cfo_assessment_retry_requested' and resource_id=(select run_id::text from cfo_retry_fixture)
  and details->>'preserved_unknown_reservations'='1'),'the automatic retry is audited with the retained usage count');

select * from finish();
rollback;

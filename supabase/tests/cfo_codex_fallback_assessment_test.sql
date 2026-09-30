begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true;
select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-6-luna',1,1,1000,7000,true);
create temporary table cfo_fallback_fixture on commit drop as
  select gen_random_uuid() as project_id,(select id from public.agents where slug='cfo' and active) as cfo_id,
    gen_random_uuid() as run_id,gen_random_uuid() as expense_1,gen_random_uuid() as expense_2,gen_random_uuid() as expense_3;
insert into public.projects(id,slug,name,description,status,requested_budget,currency,created_by)
  select project_id,'cfo-fallback-'||replace(project_id::text,'-',''),'CFO fallback fixture',
    'A bounded initiative for testing an audited evidence-backed CFO fallback.','active',17.60,'EUR','founder:12345678'
  from cfo_fallback_fixture;
insert into public.agent_runs(id,agent_id,project_id,trigger_type,status,run_order,input,output,attempt_count,finished_at)
  select run_id,cfo_id,project_id,'founder_proposal','failed',1,
    '{"request":"Founder-requested CFO-only all-in budget assessment of the existing initiative. Scope: test."}'::jsonb,
    '{"error_code":"unknown_or_overrun_spend","failure_detail_code":"invalid_evidence"}'::jsonb,3,now()
  from cfo_fallback_fixture;
insert into public.expenses(id,project_id,agent_id,category,description,amount,currency,status,requested_by)
  select expense_1,project_id,cfo_id,'ai_inference','Unknown CFO attempt one',0.03,'EUR','approved','cfo' from cfo_fallback_fixture
  union all select expense_2,project_id,cfo_id,'ai_inference','Unknown CFO attempt two',0.03,'EUR','approved','cfo' from cfo_fallback_fixture
  union all select expense_3,project_id,cfo_id,'ai_inference','Unknown CFO attempt three',0.03,'EUR','approved','cfo' from cfo_fallback_fixture;
insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
    reserved_amount,usage,status)
  select run_id,1,expense_1,'openai','gpt-6-luna',0.03,'{}'::jsonb,'unknown' from cfo_fallback_fixture
  union all select run_id,2,expense_2,'openai','gpt-6-luna',0.03,'{}'::jsonb,'unknown' from cfo_fallback_fixture
  union all select run_id,3,expense_3,'openai','gpt-6-luna',0.03,'{}'::jsonb,'unknown' from cfo_fallback_fixture;
create temporary table cfo_fallback_assessment on commit drop as select '{
  "summary":"Evidence-based bounded fallback after three invalid provider artifacts.",
  "recommendation":"Proceed within the €17.60 all-in ceiling, with provider and hosting hard stops preserved.",
  "decision":"approve",
  "decision_rationale":"The estimated €15.97 total fits the unchanged cap with medium confidence.",
  "evidence":[
    {"source":"Railway pricing plans","url":"https://docs.railway.com/pricing/plans","claim":"The Hobby plan is $5 per month and its subscription covers the first $5 of resource usage."},
    {"source":"Supabase pricing","url":"https://supabase.com/pricing","claim":"The existing Free plan costs $0; a Pro subscription starts at $25 per month."},
    {"source":"GitHub-hosted runner documentation","url":"https://docs.github.com/en/actions/reference/runners/github-hosted-runners","claim":"Standard GitHub-hosted runners are free and unlimited for public repositories."}
  ],
  "budget_estimate":{
    "estimated_total_eur":15.97,"confidence":"medium","recommended_action":"proceed_within_cap",
    "line_items":[
      {"category":"ai_model_usage","amount_eur":6.45,"basis":"Maximum available under the current €8 monthly hard stop after €1.55 of company-wide actual and unknown commitments."},
      {"category":"hosting","amount_eur":4.41,"basis":"One month at the Railway Hobby $5 subscription minimum converted at the recorded ECB 29 September 2026 rate; the actual account plan remains unverified."},
      {"category":"other","amount_eur":0.09,"basis":"Three failed CFO attempts remain unknown at €0.03 each and are included without releasing their reservations."},
      {"category":"contingency","amount_eur":5.02,"basis":"Reserve for bounded Railway usage variation during release and the first operating period; stop before any amount above the cap."}
    ]
  }
}'::jsonb as payload;

select throws_ok($$select public.sutra_record_cfo_codex_fallback_assessment(
  '99999999',(select project_id from cfo_fallback_fixture),(select run_id from cfo_fallback_fixture),
  (select payload from cfo_fallback_assessment))$$,
  '42501',null,'fallback assessment can only be recorded by the configured founder');
select is((public.sutra_record_cfo_codex_fallback_assessment(
  '12345678',(select project_id from cfo_fallback_fixture),(select run_id from cfo_fallback_fixture),
  (select payload from cfo_fallback_assessment))->>'assessment_status'),
  'within_cap','an evidenced estimate that fits the unchanged cap records the fallback assessment');
select is((select requested_budget from public.projects where id=(select project_id from cfo_fallback_fixture)),
  17.60::numeric,'fallback assessment cannot change the founder-set ceiling');
select is((select budget_assessment->>'assessment_method' from public.projects where id=(select project_id from cfo_fallback_fixture)),
  'codex_evidence_based_fallback_after_cfo_worker_exhaustion','the stored result identifies the fallback method');
select is((select count(*)::integer from public.agent_run_spend_reservations
  where agent_run_id=(select run_id from cfo_fallback_fixture) and status='unknown'),
  3,'all unknown provider reservations remain held');
select is((select status from public.agent_runs where id=(select run_id from cfo_fallback_fixture)),
  'failed','fallback preserves the exhausted provider run as a failed record');
select ok(exists(select 1 from public.audit_log where actor_type='agent' and actor_id='codex_cfo_fallback'
  and action='initiative.budget_assessed' and resource_id=(select project_id::text from cfo_fallback_fixture)
  and details->>'preserved_unknown_reservations'='3' and details->>'budget_changed'='false'),
  'fallback result and retained usage are fully auditable');

select * from finish();
rollback;

begin;
select no_plan();

select ok(not has_table_privilege('anon','public.campaigns','SELECT'),
  'campaign records are not readable by anonymous clients');
select ok(not has_table_privilege('authenticated','public.campaigns','SELECT'),
  'campaign records are not readable by authenticated clients');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true;
create temporary table campaign_fixture on commit drop as
  select (proposal.result->>'project_id')::uuid as project_id,
    (select id from public.agents where slug='cmo' and active) as cmo_id,
    gen_random_uuid() as task_within_id,gen_random_uuid() as task_over_id
  from (select public.sutra_submit_proposal('12345678','Campaign persistence test',
    'Verify CMO drafts become private durable campaign records without publishing',100,'EUR') as result) proposal;
update public.projects set status='active',budget_assessment_status='within_cap',budget_assessed_at=now(),
  budget_assessment='{"estimated_total_eur":50,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"marketing_ads","amount_eur":50,"basis":"A bounded internal campaign fixture estimate."}]}'::jsonb
  where id=(select project_id from campaign_fixture);
insert into public.tasks(id,project_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
  select task_within_id,project_id,'Plan an owned channel campaign','Create a private campaign record for this task.',
    '["Campaign scope and proposed cost are recorded"]'::jsonb,'marketing','in_progress',cmo_id,cmo_id from campaign_fixture
  union all
  select task_over_id,project_id,'Plan a paid campaign above cap','Estimate a campaign that exceeds remaining initiative funds.',
    '["Campaign scope and proposed cost are recorded"]'::jsonb,'marketing','in_progress',cmo_id,cmo_id from campaign_fixture;
insert into public.agent_runs(id,agent_id,project_id,task_id,trigger_type,status,input,output,finished_at)
  select gen_random_uuid(),cmo_id,project_id,task_within_id,'task_artifact','succeeded','{}'::jsonb,'{}'::jsonb,now()
    from campaign_fixture
  union all
  select gen_random_uuid(),cmo_id,project_id,task_over_id,'task_artifact','succeeded','{}'::jsonb,'{}'::jsonb,now()
    from campaign_fixture;

select ok(public.sutra_validate_task_artifact('cmo',
  '{"campaign_name":"Quality workflow discovery","channel":"Owned email and product site",
    "audience":"Engineering leaders evaluating QA tooling.","positioning":"Reduce repetitive quality checks.",
    "draft_copy":"A private draft for internal planning only.","claims":["Supports this workflow"],
    "success_metrics":["Qualified interest"],"budget_amount_eur":5.00,
    "budget_rationale":"A capped estimate for a small owned-channel test."}'::jsonb),
  'database contract accepts a bounded campaign name, channel, claims and EUR budget');
select ok(not public.sutra_validate_task_artifact('cmo',
  '{"campaign_name":"Quality workflow discovery","channel":"Owned email and product site",
    "audience":"Engineering leaders evaluating QA tooling.","positioning":"Reduce repetitive quality checks.",
    "draft_copy":"A private draft for internal planning only.","claims":["Supports this workflow"],
    "success_metrics":["Qualified interest"],"budget_amount_eur":-5,
    "budget_rationale":"A capped estimate for a small owned-channel test."}'::jsonb),
  'database contract rejects a negative campaign budget');

insert into public.task_agent_artifacts(task_id,agent_run_id,agent_id,artifact_type,artifact)
  select task_within_id,r.id,cmo_id,'campaign_draft',
    '{"artifact":{"campaign_name":"Quality workflow discovery","channel":"Owned email and product site",
      "audience":"Engineering leaders evaluating QA tooling.","positioning":"Reduce repetitive quality checks.",
      "draft_copy":"A private draft for internal planning only.","claims":["Supports this workflow"],
      "success_metrics":["Qualified interest"],"budget_amount_eur":5.00,
      "budget_rationale":"A capped estimate for a small owned-channel test."}}'::jsonb
  from campaign_fixture f join public.agent_runs r on r.task_id=f.task_within_id;
insert into public.task_agent_artifacts(task_id,agent_run_id,agent_id,artifact_type,artifact)
  select task_over_id,r.id,cmo_id,'campaign_draft',
    '{"artifact":{"campaign_name":"Over-cap quality launch","channel":"Paid search",
      "audience":"Engineering leaders evaluating QA tooling.","positioning":"Reduce repetitive quality checks.",
      "draft_copy":"A private draft for internal planning only.","claims":["Supports this workflow"],
      "success_metrics":["Qualified interest"],"budget_amount_eur":101.00,
      "budget_rationale":"A larger estimate that requires more than the remaining initiative budget."}}'::jsonb
  from campaign_fixture f join public.agent_runs r on r.task_id=f.task_over_id;

select is((select status from public.campaigns where source_task_id=(select task_within_id from campaign_fixture)),
  'draft','a within-cap CMO artifact creates a durable campaign draft');
select is((select budget_amount from public.campaigns where source_task_id=(select task_within_id from campaign_fixture)),
  5.00::numeric,'campaign record persists the proposed budget without reserving it');
select is((select status from public.campaigns where source_task_id=(select task_over_id from campaign_fixture)),
  'approval_required','a proposed campaign exceeding remaining initiative funds is flagged for budget review');
select ok((select content->>'delivery_started'='false' and content->>'spend_reserved'='false'
  from public.campaigns where source_task_id=(select task_within_id from campaign_fixture)),
  'persisting a campaign draft starts no external activity and reserves no spend');
select ok(exists(select 1 from public.audit_log where action='marketing.campaign_draft_persisted'
  and resource_id=(select id::text from public.campaigns where source_task_id=(select task_within_id from campaign_fixture))),
  'persisted campaign drafts are audit logged with their budget state');
select ok(exists(select 1 from public.audit_log where action='marketing.campaign_draft_persisted'
  and details->>'budget_fit'='requires_budget_or_legal_review'
  and resource_id=(select id::text from public.campaigns where source_task_id=(select task_over_id from campaign_fixture))),
  'budget-incompatible drafts retain an auditable escalation state');

select * from finish();
rollback;

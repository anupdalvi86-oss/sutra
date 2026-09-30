begin;
select no_plan();

select ok(to_regclass('public.customer_email_actions_campaign_status_idx') is not null,
  'campaign email attribution has a queue index');
select ok(has_column_privilege('service_role','public.customer_email_actions','campaign_id','SELECT')
  and not has_table_privilege('anon','public.customer_email_actions','SELECT'),
  'campaign attribution remains private to the service');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true;
select public.sutra_founder_set_customer_email_cost_ceiling('12345678',0.05,
  'Set a bounded message cost for the campaign email fixture.');
create temporary table campaign_email_fixture on commit drop as
  select (public.sutra_submit_proposal('12345678','Campaign email budget fixture',
    'Prove CMO email delivery remains inside its campaign-specific spend limit',20,'EUR')->>'project_id')::uuid as project_id,
    (select id from public.agents where slug='cmo' and active) as cmo_id,
    gen_random_uuid() as task_id,gen_random_uuid() as customer_id,gen_random_uuid() as no_campaign_task_id;
update public.projects set status='active',budget_assessment_status='within_cap',budget_assessed_at=now(),
  budget_assessment='{"estimated_total_eur":1,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"marketing_ads","amount_eur":1,"basis":"Campaign email policy fixture."}]}'::jsonb
  where id=(select project_id from campaign_email_fixture);
insert into public.tasks(id,project_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
  select task_id,project_id,'Send a budgeted campaign email','Task names the opted-in test contact.',
    jsonb_build_array('Keep campaign email spending within its own budget'),
    'marketing','in_progress',cmo_id,cmo_id from campaign_email_fixture
  union all
  select no_campaign_task_id,project_id,'Send an email without a campaign','This task has no campaign draft.',
    jsonb_build_array('This request must be rejected'),
    'marketing','in_progress',cmo_id,cmo_id from campaign_email_fixture;
insert into public.customers(id,name,email,status,marketing_email_consent,email_consent_recorded_at,email_consent_source)
  select customer_id,'Consented campaign contact','campaign@example.test','lead',true,now(),'Synthetic policy test opt-in'
    from campaign_email_fixture;
insert into public.campaigns(project_id,name,channel,status,budget_amount,currency,content,source_task_id,created_by_agent_id)
  select project_id,'Bounded lifecycle campaign','Owned email','draft',0.05,'EUR','{}'::jsonb,task_id,cmo_id
    from campaign_email_fixture;

select is((public.sutra_queue_customer_email(
  (select cmo_id from campaign_email_fixture),'cmo',(select task_id from campaign_email_fixture),
  (select project_id from campaign_email_fixture),(select customer_id from campaign_email_fixture),
  'marketing','Campaign message one','A bounded campaign update.',0.05,'campaign-email-0001')->>'status'),
  'queued','a CMO message queues within its campaign and initiative caps');
select ok((select a.campaign_id=c.id from public.customer_email_actions a
  join public.campaigns c on c.id=a.campaign_id where a.idempotency_key='campaign-email-0001'),
  'marketing email is linked to its same-task campaign');
select ok(exists(select 1 from public.audit_log where action='marketing.campaign_email_budget_reserved'
  and resource_id=(select id::text from public.campaigns where source_task_id=(select task_id from campaign_email_fixture))
  and details->>'email_action_id'=(select id::text from public.customer_email_actions where idempotency_key='campaign-email-0001')),
  'campaign allocation is audit logged with action and ledger references');

create temporary table campaign_email_claim(payload jsonb) on commit drop;
insert into campaign_email_claim select public.sutra_claim_customer_email_action('sutra-worker-campaign0001');
select is((select payload->>'status' from campaign_email_claim),'claimed',
  'delivery claims a reserved marketing message while campaign remains within cap');
select is((select public.sutra_validate_customer_email_claim('sutra-worker-campaign0001',
  (payload->>'action_id')::uuid,(payload->>'claim_token')::uuid) from campaign_email_claim),true,
  'pre-send revalidation includes campaign status and committed amount');
select public.sutra_finish_customer_email_action('sutra-worker-campaign0001',
  (select (payload->>'action_id')::uuid from campaign_email_claim),
  (select (payload->>'claim_token')::uuid from campaign_email_claim),
  'sent','synthetic-message-1',null,null,false);
select is((select status from public.campaigns where source_task_id=(select task_id from campaign_email_fixture)),
  'active','the campaign becomes active only after a delivery result is recorded');
select ok(exists(select 1 from public.audit_log where action='marketing.campaign_delivery_started'
  and resource_id=(select id::text from public.campaigns where source_task_id=(select task_id from campaign_email_fixture))),
  'first campaign delivery is audit logged');
select ok(has_function_privilege('service_role','public.sutra_company_campaign_performance()','EXECUTE')
  and not has_function_privilege('anon','public.sutra_company_campaign_performance()','EXECUTE')
  and not has_function_privilege('authenticated','public.sutra_company_campaign_performance()','EXECUTE'),
  'campaign performance is service-only');
select is((select (performance->>'sent_count')::integer
    from jsonb_array_elements(public.sutra_company_campaign_performance()) performance
    where performance->>'campaign_id'=(select id::text from public.campaigns
      where source_task_id=(select task_id from campaign_email_fixture))),1,
  'campaign performance reports sent delivery count');
select is((select (performance->>'unknown_cost_eur')::numeric
    from jsonb_array_elements(public.sutra_company_campaign_performance()) performance
    where performance->>'campaign_id'=(select id::text from public.campaigns
      where source_task_id=(select task_id from campaign_email_fixture))),0.05::numeric,
  'campaign performance keeps unknown provider usage reserved as unknown cost');
select ok((select performance::text not like '%campaign@example.test%'
    and performance::text not like '%Campaign message one%'
    from jsonb_array_elements(public.sutra_company_campaign_performance()) performance
    where performance->>'campaign_id'=(select id::text from public.campaigns
      where source_task_id=(select task_id from campaign_email_fixture))),
  'campaign status output excludes recipient and message content');

select throws_ok($$select public.sutra_queue_customer_email(
  (select cmo_id from campaign_email_fixture),'cmo',(select task_id from campaign_email_fixture),
  (select project_id from campaign_email_fixture),(select customer_id from campaign_email_fixture),
  'marketing','Campaign message two','This must exceed the campaign budget.',0.05,'campaign-email-0002')$$,
  '23514','marketing email exceeds the campaign budget',
  'unknown provider usage remains reserved against the campaign ceiling');
select is((select count(*)::integer from public.customer_email_actions where idempotency_key='campaign-email-0002'),0,
  'over-cap campaign email is not added to the customer delivery queue');
select is((select count(*)::integer from public.initiative_budget_ledger
  where project_id=(select project_id from campaign_email_fixture)
    and description='Budgeted customer email action'),1,
  'a rejected campaign email rolls back its initiative spend reservation');

select throws_ok($$select public.sutra_queue_customer_email(
  (select cmo_id from campaign_email_fixture),'cmo',(select no_campaign_task_id from campaign_email_fixture),
  (select project_id from campaign_email_fixture),(select customer_id from campaign_email_fixture),
  'marketing','No campaign','CMO email must have a campaign record.',0.05,'campaign-email-0003')$$,
  '42501','CMO campaign is blocked or has no positive EUR budget',
  'CMO cannot queue an unbudgeted message outside a campaign');

select * from finish();
rollback;

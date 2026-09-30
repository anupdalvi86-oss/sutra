begin;
select no_plan();

select ok((select relrowsecurity from pg_class where oid='public.customer_crm_sync_actions'::regclass),
  'CRM sync queue has row-level security enabled');
select ok(not has_table_privilege('anon','public.customer_crm_sync_actions','SELECT'),
  'anonymous clients cannot inspect CRM actions');
select ok(not has_table_privilege('service_role','public.customer_crm_sync_actions','INSERT'),
  'service role cannot bypass the queue authorization RPC');
select ok(has_function_privilege('service_role',
  'public.sutra_queue_customer_crm_sync(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE'),
  'service role can request a CRM action through its policy gate');
select ok(not has_function_privilege('authenticated',
  'public.sutra_queue_customer_crm_sync(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE'),
  'authenticated clients cannot queue CRM actions');
select ok(has_function_privilege('service_role','public.sutra_claim_customer_crm_sync_action(text)','EXECUTE'),
  'service role can claim authorized CRM actions');
select ok(not has_function_privilege('anon',
  'public.sutra_finish_customer_crm_sync_action(text,uuid,uuid,text,text,text,numeric,boolean)','EXECUTE'),
  'anonymous clients cannot settle CRM actions');
select ok(to_regclass('public.customer_crm_sync_actions_task_idx') is not null
  and to_regclass('public.customer_crm_sync_actions_customer_idx') is not null
  and to_regclass('public.customer_crm_sync_actions_agent_idx') is not null,
  'CRM action foreign keys have lookup indexes');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true;
create temporary table crm_project on commit drop as
  select (public.sutra_submit_proposal('12345678','CRM sync fixture',
    'Exercise consent and budget gates for HubSpot contact synchronization',3,'EUR')->>'project_id')::uuid as project_id;
update public.projects set status='active',requested_budget=3,budget_amount=3,
  budget_assessment_status='within_cap',
  budget_assessment='{"estimated_total_eur":3,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"crm","amount_eur":3,"basis":"Database test fixture."}]}'::jsonb
  where id=(select project_id from crm_project);
update public.approvals set status='approved',decisions='{"cfo":{"decision":"approve"},"product_manager":{"decision":"approve"}}'::jsonb
  where project_id=(select project_id from crm_project) and approval_type='project_budget';
create temporary table crm_ids on commit drop as
  select a.id agent_id,gen_random_uuid() customer_id,gen_random_uuid() task_id,
    (select project_id from crm_project) project_id
  from public.agents a where a.slug='sales' and a.active;
insert into public.tasks(id,project_id,title,description,task_type,status,owner_agent_id,assigned_agent_id)
  select task_id,project_id,'Sync opted-in CRM contact','Test only','sales_follow_up','in_progress',agent_id,agent_id
  from crm_ids;
insert into public.customers(id,name,email,company,status,crm_sync_consent,crm_consent_recorded_at,crm_consent_source)
  select customer_id,'Riley Example','riley@example.test','Example Co','lead',false,null,null
  from crm_ids;
select throws_ok($$select public.sutra_founder_set_customer_crm_consent('99999999',
  (select customer_id from crm_ids),true,'Verified customer data sharing form')$$,'42501',null,
  'only the configured founder can record CRM sharing consent');
select is((public.sutra_founder_set_customer_crm_consent('12345678',
  (select customer_id from crm_ids),true,'Verified customer data sharing form')->>'crm_sync_consent')::boolean,
  true,'founder can record consent with a traceable evidence source');

select throws_ok($$select public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),0,'crm-zero-cost')$$,'22023',null,
  'malformed zero-cost reservation is rejected');
select is((public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),1.00,'crm-action-0001')->>'status'),
  'queued','assigned Sales task queues CRM sync under an explicit initiative reservation');
select is((select status from public.initiative_budget_ledger where id=(
  select initiative_ledger_id from public.customer_crm_sync_actions where idempotency_key='crm-action-0001')),
  'reserved','CRM sync holds its all-in initiative budget reservation');
select is((public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),1.00,'crm-action-0001')->>'idempotent'),
  'true','CRM sync queue request is idempotent');
select is((select count(*)::integer from public.customer_crm_sync_actions),1,
  'idempotent queue replay does not duplicate actions');
select ok(exists(select 1 from public.audit_log where action='customer.crm_sync_queued'
  and resource_id=(select id::text from public.customer_crm_sync_actions where idempotency_key='crm-action-0001')),
  'CRM sync queue creation is audited');
select throws_ok($$select public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),3.01,'crm-over-cap')$$,'23514',null,
  'CRM reservation is rejected above the remaining all-in initiative cap');

update public.customers set crm_sync_consent=false where id=(select customer_id from crm_ids);
select throws_ok($$select public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),0.01,'crm-no-consent')$$,'42501',null,
  'CRM export requires recorded affirmative data-sharing consent');
update public.customers set crm_sync_consent=true,email_unsubscribed_at=now()
  where id=(select customer_id from crm_ids);
select throws_ok($$select public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),0.01,'crm-unsubscribed')$$,'42501',null,
  'unsubscribed contacts are excluded from CRM sync');
update public.customers set email_unsubscribed_at=null where id=(select customer_id from crm_ids);
select throws_ok($$select public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),gen_random_uuid(),
  (select customer_id from crm_ids),0.01,'crm-wrong-project')$$,'42501',null,
  'task assignment cannot authorize a sync for another project');
select is((public.sutra_founder_set_project_legal_hold('12345678',(select project_id from crm_ids),true,
  'Hold CRM data transfer during review')->>'legal_hold'),'true','founder can set legal hold fixture');
select throws_ok($$select public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),0.01,'crm-legal-hold')$$,'42501',null,
  'project legal hold blocks CRM export');
select public.sutra_founder_set_project_legal_hold('12345678',(select project_id from crm_ids),false,
  'Clear test-only CRM project hold');

create temporary table crm_claim on commit drop as
  select public.sutra_claim_customer_crm_sync_action('sutra-worker-hubspot1234') claim;
select is((select claim->>'status' from crm_claim),'claimed','worker claims a reserved CRM action');
select ok((select claim->'action' ?& array['email','name','company']
  and array(select jsonb_object_keys(claim->'action') order by 1)=array['company','email','name']::text[]
  from crm_claim),
  'worker receives only allowlisted contact fields, without notes or free text');
select ok(public.sutra_validate_customer_crm_sync_claim('sutra-worker-hubspot1234',
  ((select claim->>'action_id' from crm_claim))::uuid,((select claim->>'claim_token' from crm_claim))::uuid),
  'worker revalidates task, consent, legal state and reservation before upsert');
select public.sutra_founder_set_customer_crm_consent('12345678',(select customer_id from crm_ids),false,
  'Customer withdrew permission for CRM export');
select ok(not public.sutra_validate_customer_crm_sync_claim('sutra-worker-hubspot1234',
  ((select claim->>'action_id' from crm_claim))::uuid,((select claim->>'claim_token' from crm_claim))::uuid),
  'revoked consent blocks the provider request after claim');
select public.sutra_founder_set_customer_crm_consent('12345678',(select customer_id from crm_ids),true,
  'Verified customer data sharing form');
select is((public.sutra_finish_customer_crm_sync_action('sutra-worker-hubspot1234',
  ((select claim->>'action_id' from crm_claim))::uuid,((select claim->>'claim_token' from crm_claim))::uuid,
  'failed',null,'authorization_revoked',0,true)->>'status'),'failed',
  'revoked authorization releases reservation without calling HubSpot');
select is((select status from public.initiative_budget_ledger where id=(
  select initiative_ledger_id from public.customer_crm_sync_actions where idempotency_key='crm-action-0001')),
  'released','known no-request outcome releases the unused reservation');

select is((public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),1.00,'crm-action-0002')->>'status'),'queued',
  'a follow-up reservation can use budget released by a known no-request result');
create temporary table crm_unknown_claim on commit drop as
  select public.sutra_claim_customer_crm_sync_action('sutra-worker-hubspot1234') claim;
select is((public.sutra_finish_customer_crm_sync_action('sutra-worker-hubspot1234',
  ((select claim->>'action_id' from crm_unknown_claim))::uuid,
  ((select claim->>'claim_token' from crm_unknown_claim))::uuid,
  'unknown',null,'provider_outcome_unknown',null,false)->>'status'),'unknown',
  'ambiguous provider outcome is terminal and preserves unknown cost');
select is((select status from public.initiative_budget_ledger where id=(
  select initiative_ledger_id from public.customer_crm_sync_actions where idempotency_key='crm-action-0002')),
  'unknown','ambiguous CRM provider use stays reserved in the all-in ledger');
select is(public.sutra_claim_customer_crm_sync_action('sutra-worker-hubspot1234'),null::jsonb,
  'unknown CRM action is not automatically retried');
select is((public.sutra_queue_customer_crm_sync(
  (select agent_id from crm_ids),(select task_id from crm_ids),(select project_id from crm_ids),
  (select customer_id from crm_ids),1.00,'crm-action-0003')->>'status'),'queued',
  'a queued contact action may use only the remaining authorized initiative budget');
select is((public.sutra_founder_set_customer_crm_consent('12345678',(select customer_id from crm_ids),false,
  'Customer withdrew permission for CRM export')->>'queued_actions_cancelled')::integer,1,
  'withdrawing consent cancels queued actions and releases their reservations');
select is((select status from public.customer_crm_sync_actions where idempotency_key='crm-action-0003'),
  'cancelled','consent withdrawal prevents queued CRM export');
select is((select status from public.initiative_budget_ledger where id=(
  select initiative_ledger_id from public.customer_crm_sync_actions where idempotency_key='crm-action-0003')),
  'released','consent withdrawal settles the unused reservation as known zero');

select * from finish();
rollback;

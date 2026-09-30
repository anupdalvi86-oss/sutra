begin;
select no_plan();

select ok((select relrowsecurity from pg_class where oid='public.customer_email_actions'::regclass),
  'private delivery rows keep row level security enabled');
select ok(not has_table_privilege('anon','public.customer_email_actions','SELECT'),
  'anonymous clients cannot read delivery queue or message content');
select ok(not has_table_privilege('authenticated','public.customer_email_actions','SELECT'),
  'authenticated clients cannot read delivery queue or message content');
select ok(not has_function_privilege('anon',
  'public.sutra_claim_customer_email_action(text)','EXECUTE'),
  'anonymous clients cannot claim email delivery actions');
select ok(not has_function_privilege('authenticated',
  'public.sutra_validate_customer_email_claim(text,uuid,uuid)','EXECUTE'),
  'authenticated clients cannot validate a private delivery claim');
select ok(not has_function_privilege('authenticated',
  'public.sutra_finish_customer_email_action(text,uuid,uuid,text,text,text,numeric,boolean)','EXECUTE'),
  'authenticated clients cannot mark an email as delivered');
select ok(has_function_privilege('service_role',
  'public.sutra_claim_customer_email_action(text)','EXECUTE'),
  'the service role can claim approved delivery actions');
select ok(to_regclass('public.customer_email_actions_delivery_lease_idx') is not null,
  'expired delivery leases can be located efficiently');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true;
select public.sutra_founder_set_customer_email_cost_ceiling('12345678',0.05,
  'Bound provider delivery cost per message for this database fixture.');
select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-6-luna',1,1,1000,1000,true);
create temporary table delivery_fixture on commit drop as
  select (public.sutra_submit_proposal('12345678','Delivery worker fixture',
    'Exercise transactional claims and unknown cost holds',20,'EUR')->>'project_id')::uuid as project_id;
update public.projects set status='active',budget_assessment_status='within_cap',
  budget_assessment='{"estimated_total_eur":20,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"sales","amount_eur":20,"basis":"Delivery test fixture."}]}'::jsonb
  where id=(select project_id from delivery_fixture);
update public.approvals set status='approved',decisions='{"cfo":{"decision":"approve"},"product_manager":{"decision":"approve"}}'::jsonb
  where project_id=(select project_id from delivery_fixture) and approval_type='project_budget';
create temporary table delivery_ids on commit drop as
  select a.id as agent_id,gen_random_uuid() as customer_id,gen_random_uuid() as task_id,
    (select project_id from delivery_fixture) as project_id
  from public.agents a where a.slug='sales' and a.active;
insert into public.tasks(id,project_id,title,description,task_type,status,owner_agent_id,assigned_agent_id)
  select task_id,project_id,'Deliver an opted-in test email','Database fixture only',
    'customer_outreach','in_progress',agent_id,agent_id from delivery_ids;
insert into public.customers(id,name,email,status,marketing_email_consent,service_email_consent,
  email_consent_recorded_at,email_consent_source)
  select customer_id,'Consenting test contact','fixture@example.test','lead',true,true,now(),'test fixture'
  from delivery_ids;
select public.sutra_queue_customer_email(
  (select agent_id from delivery_ids),'sales',(select task_id from delivery_ids),
  (select project_id from delivery_ids),(select customer_id from delivery_ids),
  'sales','Test queued delivery','Database-only email body',0.05,'delivery-action-0001');
create temporary table first_delivery on commit drop as
  select public.sutra_claim_customer_email_action('sutra-worker-email0001') as claim;
select is((select claim->>'status' from first_delivery),'claimed',
  'worker receives one authorized queued action');
select is((select status from public.customer_email_actions where id=(select (claim->>'action_id')::uuid from first_delivery)),
  'sending','claim atomically moves the action to sending');
select is((select delivery_attempt_count::integer from public.customer_email_actions
  where id=(select (claim->>'action_id')::uuid from first_delivery)),1,
  'claim records its delivery attempt');
select ok((select public.sutra_validate_customer_email_claim('sutra-worker-email0001',
  (claim->>'action_id')::uuid,(claim->>'claim_token')::uuid) from first_delivery),
  'fresh consent, assignment, legal and budget state passes the pre-send check');
select is((select public.sutra_claim_customer_email_action('sutra-worker-email0002')),null::jsonb,
  'a sending action cannot be claimed concurrently by another worker');

update public.customers set email_unsubscribed_at=now() where id=(select customer_id from delivery_ids);
select ok(not (select public.sutra_validate_customer_email_claim('sutra-worker-email0001',
  (claim->>'action_id')::uuid,(claim->>'claim_token')::uuid) from first_delivery),
  'revoked consent blocks the external write');
update public.customers set email_unsubscribed_at=null where id=(select customer_id from delivery_ids);
select public.sutra_finish_customer_email_action('sutra-worker-email0001',
  (select (claim->>'action_id')::uuid from first_delivery),
  (select (claim->>'claim_token')::uuid from first_delivery),
  'sent','provider-msg-0001',null,null,false);
select is((select status from public.customer_email_actions where id=(select (claim->>'action_id')::uuid from first_delivery)),
  'sent','successful response is terminal');
select is((select status from public.initiative_budget_ledger where id=(select (claim->>'ledger_id')::uuid from first_delivery)),
  'unknown','successful delivery keeps its provider cost reservation until reconciled');
select ok(exists(select 1 from public.audit_log where action='customer.email_sent'
  and resource_id=(select claim->>'action_id' from first_delivery)
  and not (details ? 'recipient_email') and not (details ? 'body_text')),
  'delivery audit records outcome without recipient or message content');

select public.sutra_queue_customer_email(
  (select agent_id from delivery_ids),'sales',(select task_id from delivery_ids),
  (select project_id from delivery_ids),(select customer_id from delivery_ids),
  'sales','Test ambiguous delivery','Database-only email body',0.05,'delivery-action-0002');
create temporary table second_delivery on commit drop as
  select public.sutra_claim_customer_email_action('sutra-worker-email0001') as claim;
select is((select claim->>'status' from second_delivery),'claimed',
  'a separate queued action may be processed independently');
update public.customer_email_actions set delivery_lease_expires_at=now()-interval '1 second'
  where id=(select (claim->>'action_id')::uuid from second_delivery);
create temporary table third_claim on commit drop as
  select public.sutra_claim_customer_email_action('sutra-worker-email0002') as claim;
select is((select status from public.customer_email_actions where id=(select (claim->>'action_id')::uuid from second_delivery)),
  'unknown','expired worker lease is terminal and cannot trigger a duplicate send');
select is((select status from public.initiative_budget_ledger where id=(select (claim->>'ledger_id')::uuid from second_delivery)),
  'unknown','expired send preserves its full unknown-cost reservation');
select is((select claim from third_claim),null::jsonb,
  'an ambiguous expired delivery is never retried');
select ok(exists(select 1 from public.audit_log where action='customer.email_delivery_unknown'
  and resource_id=(select claim->>'action_id' from second_delivery)),
  'expired ambiguous send is audit logged');

select * from finish();
rollback;

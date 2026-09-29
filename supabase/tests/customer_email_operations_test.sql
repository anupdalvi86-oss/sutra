begin;
select plan(28);

select ok((select relrowsecurity from pg_class where oid='public.customer_email_actions'::regclass),
  'customer email actions have row level security enabled');
select ok(not has_table_privilege('anon','public.customer_email_actions','SELECT'),
  'anonymous clients cannot read email content');
select ok(not has_table_privilege('authenticated','public.customer_email_actions','SELECT'),
  'authenticated clients cannot read email content');
select ok(has_table_privilege('service_role','public.customer_email_actions','SELECT'),
  'the private service can inspect queued actions');
select ok(not has_table_privilege('service_role','public.customer_email_actions','INSERT'),
  'the private service cannot bypass the enqueue authorization RPC');
select ok(not has_function_privilege('anon',
  'public.sutra_queue_customer_email(uuid,text,uuid,uuid,uuid,text,text,text,numeric,text)','EXECUTE'),
  'anonymous clients cannot enqueue customer messages');
select ok(has_function_privilege('service_role',
  'public.sutra_queue_customer_email(uuid,text,uuid,uuid,uuid,text,text,text,numeric,text)','EXECUTE'),
  'only the internal service can request a database-authorized email action');
select ok(to_regclass('public.customer_email_actions_agent_idx') is not null,
  'the agent foreign key is indexed');
select ok(to_regclass('public.customer_email_actions_customer_idx') is not null,
  'the customer foreign key is indexed');
select ok(to_regclass('public.customer_email_actions_task_idx') is not null,
  'the task foreign key is indexed');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value;
select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-6-luna',1,1,1000,1000,true);
create temporary table customer_email_fixture on commit drop as
  select (public.sutra_submit_proposal('12345678','Customer email fixture',
    'Exercise consent, spend and legal controls on customer email actions',20,'EUR')->>'project_id')::uuid as project_id;
update public.projects set status='active',budget_assessment_status='within_cap',
  budget_assessment='{"estimated_total_eur":20,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"sales","amount_eur":20,"basis":"Database authorization test fixture."}]}'::jsonb
  where id=(select project_id from customer_email_fixture);
update public.approvals set status='approved',decisions='{"cfo":{"decision":"approve"},"product_manager":{"decision":"approve"}}'::jsonb
  where project_id=(select project_id from customer_email_fixture) and approval_type='project_budget';
create temporary table customer_email_ids on commit drop as
  select a.id as agent_id,gen_random_uuid() as customer_id,gen_random_uuid() as task_id,
    (select project_id from customer_email_fixture) as project_id
  from public.agents a where a.slug='sales' and a.active;
insert into public.tasks(id,project_id,title,description,task_type,status,owner_agent_id,assigned_agent_id)
  select task_id,project_id,'Contact an opted-in customer','Test fixture for the contact queue',
    'customer_outreach','in_progress',agent_id,agent_id from customer_email_ids;
insert into public.customers(id,name,email,status,marketing_email_consent,service_email_consent,
  email_consent_recorded_at,email_consent_source)
  select customer_id,'Consenting customer','fixture@example.test','lead',true,true,now(),'fixture signup checkbox'
  from customer_email_ids;

select is((public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','A short introduction','Would a short overview be useful?',0.05,'email-action-0001')->>'status'),
  'queued','an active assigned Sales task can enqueue a consented customer contact within the initiative budget');
select is((select count(*)::integer from public.customer_email_actions where idempotency_key='email-action-0001'),
  1,'customer message body and recipient persist in the private action queue');
select is((select status from public.initiative_budget_ledger where id=(
  select initiative_ledger_id from public.customer_email_actions where idempotency_key='email-action-0001')),
  'reserved','the customer email is backed by an all-in initiative reservation');
select ok(exists(select 1 from public.audit_log where action='customer.email_queued'
  and resource_id=(select id::text from public.customer_email_actions where idempotency_key='email-action-0001')),
  'queue creation records an audit event without copying message content');
select is((public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','A short introduction','Would a short overview be useful?',0.05,'email-action-0001')->>'idempotent'),
  'true','an identical action retry is idempotent');
select is((select count(*)::integer from public.customer_email_actions where idempotency_key='email-action-0001'),
  1,'retries do not duplicate the message or spend reservation');
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  gen_random_uuid(),(select customer_id from customer_email_ids),'sales','Wrong project','Message',
  0.05,'email-action-0002')$$,'42501',null,'a task cannot authorize customer contact in a different project');
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'marketing','Campaign message','Message',0.05,'email-action-0003')$$,
  '42501',null,'Sales cannot queue a Marketing campaign message');
update public.customers set marketing_email_consent=false
  where id=(select customer_id from customer_email_ids);
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','No consent','Message',0.05,'email-action-0004')$$,
  '42501',null,'marketing and sales contact requires explicit recorded opt-in');
update public.customers set marketing_email_consent=true where id=(select customer_id from customer_email_ids);

select is((public.sutra_founder_set_project_legal_hold('12345678',
  (select project_id from customer_email_ids),true,'Pause contact pending legal review')->>'legal_hold'),
  'true','the configured founder can set a project legal hold');
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','Held message','Message',0.05,'email-action-0005')$$,
  '42501',null,'legal holds block customer email queueing');
select throws_ok($$select public.sutra_founder_set_project_legal_hold('99999999',
  (select project_id from customer_email_ids),false,'Clear legal hold without founder identity')$$,
  '42501',null,'only the configured founder can clear a legal hold');
select is((public.sutra_founder_set_project_legal_hold('12345678',
  (select project_id from customer_email_ids),false,'Founder reviewed the legal question')->>'legal_hold'),
  'false','founder can explicitly clear a legal hold');
select ok(exists(select 1 from public.audit_log where action='project.legal_hold_set'
  and resource_id=(select project_id::text from customer_email_ids)),
  'setting legal hold is audit logged');
select ok(exists(select 1 from public.audit_log where action='project.legal_hold_cleared'
  and resource_id=(select project_id::text from customer_email_ids)),
  'clearing legal hold is audit logged');
update public.customers set email_unsubscribed_at=now() where id=(select customer_id from customer_email_ids);
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','Unsubscribed','Message',0.05,'email-action-0006')$$,
  '42501',null,'unsubscribed customers cannot be contacted');
update public.customers set email_unsubscribed_at=null where id=(select customer_id from customer_email_ids);
update public.projects set requested_budget=0.05,budget_amount=0.05 where id=(select project_id from customer_email_ids);
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','Over budget','Message',0.05,'email-action-0007')$$,
  '23514',null,'customer contact cannot exceed the remaining initiative all-in budget');
insert into public.legal_escalations(project_id,source_assessed_at,summary)
  select project_id,now(),'Test legal escalation blocks customer communications' from customer_email_ids;
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','Legal hold','Message',0.01,'email-action-0008')$$,
  '42501',null,'an open legal escalation blocks customer communications');
select * from finish();
rollback;

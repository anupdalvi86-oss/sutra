begin;
select plan(50);

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
  on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true;
select public.sutra_founder_set_customer_email_cost_ceiling('12345678',0.05,
  'Bound provider delivery cost per message for this database fixture.');
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

update public.projects set budget_assessment_status='unassessed',budget_assessment='{}'::jsonb
  where id=(select project_id from customer_email_ids);
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','Unassessed email','Must not be reserved',0.05,'email-action-unassessed')$$,
  '42501','customer email requires an active initiative with a within-cap CFO assessment',
  'customer email queue requires an assessed within-cap initiative');
select is((select count(*)::integer from public.customer_email_actions
  where idempotency_key='email-action-unassessed'),0,
  'an unassessed initiative cannot persist a customer email action');
select is((select count(*)::integer from public.initiative_budget_ledger
  where project_id=(select project_id from customer_email_ids)
    and description='Budgeted customer email action'),0,
  'a rejected unassessed email rolls back its attempted ledger reservation');
update public.projects set budget_assessment_status='within_cap',budget_assessment=
  '{"estimated_total_eur":25,"confidence":"medium","recommended_action":"request_budget_increase","line_items":[{"category":"sales","amount_eur":25,"basis":"Database authorization test fixture."}]}'::jsonb
  where id=(select project_id from customer_email_ids);
select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','Budget gap email','Must not be reserved',0.05,'email-action-budget-gap')$$,
  '42501','customer email requires an active initiative with a within-cap CFO assessment',
  'a budget increase recommendation blocks customer email even if project state is inconsistent');
select is((select count(*)::integer from public.initiative_budget_ledger
  where project_id=(select project_id from customer_email_ids)
    and description='Budgeted customer email action'),0,
  'a rejected budget-gap email rolls back its attempted ledger reservation');
update public.projects set budget_assessment_status='within_cap',budget_assessment=
  '{"estimated_total_eur":20,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"sales","amount_eur":20,"basis":"Database authorization test fixture."}]}'::jsonb
  where id=(select project_id from customer_email_ids);

select throws_ok($$select public.sutra_queue_customer_email(
  (select agent_id from customer_email_ids),'sales',(select task_id from customer_email_ids),
  (select project_id from customer_email_ids),(select customer_id from customer_email_ids),
  'sales','Underfunded email','Must not enter the queue',0.01,'email-action-underfunded')$$,
  '23514','customer email reservation is below the configured per-message ceiling',
  'database blocks an email whose shared-ledger reservation is below the founder ceiling');
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
select throws_ok($$select public.sutra_founder_set_customer_email_cost_ceiling('12345678',0.06,
  'Do not exceed existing per-action reservations')$$,'55000',
  'customer email ceiling cannot change while sends are active or queued reservations are below the new ceiling',
  'raising the ceiling cannot strand an already queued email below its unit-cost reservation');
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

create temporary table task_outreach_customers on commit drop as
  select gen_random_uuid() as opted_in_id,gen_random_uuid() as no_consent_id,
    gen_random_uuid() as out_of_scope_id,(select project_id from customer_email_ids) as project_id,
    (select agent_id from customer_email_ids) as agent_id;
insert into public.customers(id,name,email,status,marketing_email_consent,service_email_consent,
  email_consent_recorded_at,email_consent_source)
  select opted_in_id,'Opted-in contact','outreach@example.test','lead',true,true,now(),'fixture opt-in'
    from task_outreach_customers
  union all
  select no_consent_id,'Unconsented contact','no-consent@example.test','lead',false,false,null,null
    from task_outreach_customers
  union all
  select out_of_scope_id,'Out-of-scope contact','out-of-scope@example.test','lead',true,true,now(),'fixture opt-in'
    from task_outreach_customers;
insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
  select project_id,'Follow up with assigned contacts',
    'Customers explicitly assigned: '||opted_in_id::text||' and '||no_consent_id::text,
    jsonb_build_array('Queue only consented contacts within policy'),'customer_outreach','ready',agent_id,agent_id
    from task_outreach_customers;
create temporary table task_outreach_claim(payload jsonb) on commit drop;
create function pg_temp.prepare_task_outreach_run() returns jsonb language plpgsql as $$
declare claim jsonb; reservation jsonb; reservation_id uuid;
begin
  claim:=public.sutra_claim_task_agent_run('sutra-worker-12345678');
  if claim is null or claim->'agent'->>'slug'<>'sales' then
    raise exception 'expected the assigned Sales outreach task';
  end if;
  reservation:=public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
    (claim->>'run_id')::uuid,(claim->>'lease_token')::uuid,'openai','gpt-6-luna');
  if reservation->>'status'<>'approved' then raise exception 'fixture model spend was not approved'; end if;
  reservation_id:=(reservation->>'reservation_id')::uuid;
  perform public.sutra_begin_agent_run_spend('sutra-worker-12345678',
    (claim->>'run_id')::uuid,(claim->>'lease_token')::uuid,reservation_id);
  perform public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',
    (claim->>'run_id')::uuid,(claim->>'lease_token')::uuid,reservation_id,'openai','gpt-6-luna',1,1,
    '{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}'::jsonb,true);
  return claim;
end $$;
insert into task_outreach_claim select pg_temp.prepare_task_outreach_run();
create temporary table task_outreach_output(payload jsonb) on commit drop;
insert into task_outreach_output
select jsonb_build_object(
    'summary','Sales prepared task-scoped follow-up for assigned customer records.',
    'recommendation','Continue within recorded consent and initiative spend limits.',
    'evidence','[]'::jsonb,
    'task_acceptance',jsonb_build_array(jsonb_build_object(
      'criterion','Queue only consented contacts within policy','evidence','The database queued only the consented assigned contact.')),
    'artifact',jsonb_build_object('ideal_customer_profile','Software teams with an active quality workflow.',
      'lead_criteria',jsonb_build_array('Customer ID appears in this assigned task.'),
      'qualification_questions',jsonb_build_array('Would this workflow be useful?'),
      'first_contact_draft','A concise follow-up for the assigned customer.'),
    'customer_actions',jsonb_build_array(
      jsonb_build_object('customer_id',(select opted_in_id::text from task_outreach_customers),
        'purpose','sales','subject','A short workflow overview','body_text','Would a short overview be useful?'),
      jsonb_build_object('customer_id',(select no_consent_id::text from task_outreach_customers),
        'purpose','sales','subject','A follow-up','body_text','May I share a brief product overview?'),
      jsonb_build_object('customer_id',(select out_of_scope_id::text from task_outreach_customers),
        'purpose','sales','subject','Out of scope','body_text','This message must not be queued.')));
select throws_ok($$select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from task_outreach_claim),
  (select (payload->>'lease_token')::uuid from task_outreach_claim),
  jsonb_set((select payload from task_outreach_output),'{customer_actions,0}','"not-an-object"'::jsonb))$$,
  '22023',null,'malformed customer action requests cannot enter the email outbox');
create temporary table task_outreach_submit(payload jsonb) on commit drop;
insert into task_outreach_submit
select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',(c.payload->>'run_id')::uuid,
  (c.payload->>'lease_token')::uuid,(select payload from task_outreach_output))
from task_outreach_claim c;
select is((select payload->>'status' from task_outreach_submit),'succeeded',
  'Sales task artifacts complete while policy-blocked contacts are recorded as blocked');
select is((select count(*)::integer from public.customer_email_actions
  where task_id=(select (payload->'task_artifact'->>'task_id')::uuid from task_outreach_claim)),1,
  'a task artifact queues only the explicitly assigned opted-in customer');
select is((select (payload->'customer_action_results'->0->>'status') from public.task_agent_artifacts
  where task_id=(select (payload->'task_artifact'->>'task_id')::uuid from task_outreach_claim)),'queued',
  'the artifact records the queued outcome without asking for routine founder approval');
select is((select payload->'customer_action_results'->1->>'reason' from public.task_agent_artifacts
  where task_id=(select (payload->'task_artifact'->>'task_id')::uuid from task_outreach_claim)),
  'consent_or_authorization_blocked','missing customer consent blocks the action and preserves the work artifact');
select is((select payload->'customer_action_results'->2->>'reason' from public.task_agent_artifacts
  where task_id=(select (payload->'task_artifact'->>'task_id')::uuid from task_outreach_claim)),
  'customer_not_in_task_scope','customer IDs absent from the assigned task cannot be contacted');
select ok(exists(select 1 from public.audit_log where action='customer.action_blocked'
  and resource_type='task_agent_artifact'
  and resource_id=(select id::text from public.task_agent_artifacts
    where task_id=(select (payload->'task_artifact'->>'task_id')::uuid from task_outreach_claim))),
  'blocked customer actions are audit logged without recipient or message content');

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

create temporary table task_legal_fixture on commit drop as
  select (public.sutra_submit_proposal('12345678','Agent legal escalation fixture',
    'A Sales task that identifies a binding legal commitment',20,'EUR')->>'project_id')::uuid as project_id,
    (select id from public.agents where slug='sales' and active) as agent_id,
    gen_random_uuid() as customer_id;
update public.projects set status='active',budget_assessment_status='within_cap',
  budget_assessment='{"estimated_total_eur":20,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"sales","amount_eur":20,"basis":"Test fixture for legal escalation controls."}]}'::jsonb
  where id=(select project_id from task_legal_fixture);
insert into public.customers(id,name,email,status,marketing_email_consent,email_consent_recorded_at,email_consent_source)
  select customer_id,'Legal review contact','legal-contact@example.test','lead',true,now(),'fixture opt-in'
    from task_legal_fixture;
insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
  select project_id,'Review requested terms','Customer ID: '||customer_id::text,
    jsonb_build_array('Escalate binding legal terms to founder'),'customer_outreach','ready',agent_id,agent_id
    from task_legal_fixture;
create temporary table task_legal_claim(payload jsonb) on commit drop;
create function pg_temp.prepare_task_legal_run() returns jsonb language plpgsql as $$
declare claim jsonb; reservation jsonb; reservation_id uuid;
begin
  claim:=public.sutra_claim_task_agent_run('sutra-worker-12345678');
  if claim is null or claim->'agent'->>'slug'<>'sales' then
    raise exception 'expected the Sales legal review task';
  end if;
  reservation:=public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
    (claim->>'run_id')::uuid,(claim->>'lease_token')::uuid,'openai','gpt-6-luna');
  if reservation->>'status'<>'approved' then raise exception 'legal fixture model spend was not approved'; end if;
  reservation_id:=(reservation->>'reservation_id')::uuid;
  perform public.sutra_begin_agent_run_spend('sutra-worker-12345678',
    (claim->>'run_id')::uuid,(claim->>'lease_token')::uuid,reservation_id);
  perform public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',
    (claim->>'run_id')::uuid,(claim->>'lease_token')::uuid,reservation_id,'openai','gpt-6-luna',1,1,
    '{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}'::jsonb,true);
  return claim;
end $$;
insert into task_legal_claim select pg_temp.prepare_task_legal_run();
create temporary table task_legal_submit(payload jsonb) on commit drop;
insert into task_legal_submit
select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',(c.payload->>'run_id')::uuid,
  (c.payload->>'lease_token')::uuid,jsonb_build_object(
    'summary','Sales identified a binding customer commitment that needs legal review.',
    'recommendation','Founder legal review required before any customer contact.',
    'evidence','[]'::jsonb,
    'task_acceptance',jsonb_build_array(jsonb_build_object(
      'criterion','Escalate binding legal terms to founder','evidence','A legal case was created and the initiative paused.')),
    'artifact',jsonb_build_object('ideal_customer_profile','A business evaluating a service agreement.',
      'lead_criteria',jsonb_build_array('The assigned record is an existing lead.'),
      'qualification_questions',jsonb_build_array('Which terms require legal review?'),
      'first_contact_draft','Do not send until the legal question is resolved.'),
    'legal_escalation','The requested service-level guarantee may create a binding contractual commitment.',
    'customer_actions',jsonb_build_array(jsonb_build_object(
      'customer_id',(select customer_id::text from task_legal_fixture),'purpose','sales',
      'subject','Service commitment','body_text','We guarantee the requested service level.'))))
from task_legal_claim c;
select is((select payload->>'status' from task_legal_submit),'succeeded',
  'Sales completes the internal artifact while escalating the legal issue');
select is((select status from public.projects where id=(select project_id from task_legal_fixture)),
  'paused','an agent legal escalation pauses the initiative');
select is((select budget_assessment_status from public.projects where id=(select project_id from task_legal_fixture)),
  'legal_escalation','legal escalation becomes authoritative project state');
select is((select count(*)::integer from public.legal_escalations
  where project_id=(select project_id from task_legal_fixture) and status='open'),1,
  'the founder legal queue receives one durable task-generated case');
select is((select payload->'customer_action_results'->1->>'reason' from public.task_agent_artifacts
  where task_id=(select (payload->'task_artifact'->>'task_id')::uuid from task_legal_claim)),
  'legal_review_required','a legal escalation prevents the same task from contacting the customer');
select is((select count(*)::integer from public.customer_email_actions
  where project_id=(select project_id from task_legal_fixture)),0,
  'a task with an open legal issue creates no outbound customer email');
select ok(exists(select 1 from public.audit_log where actor_type='agent'
  and action='legal.escalation_opened' and resource_type='legal_escalation'
  and resource_id=(select id::text from public.legal_escalations
    where project_id=(select project_id from task_legal_fixture))),
  'agent legal escalation is audit logged for founder review');
update public.projects set status='active' where id=(select project_id from task_legal_fixture);
select throws_ok($$select public.sutra_authorize_initiative_cost('system','sutra',null,
  (select project_id from task_legal_fixture),'sales','email-provider',
  'Paid work after legal escalation',0.05,'EUR','legal-spend-blocked-01')$$,
  '42501','initiative has an open legal escalation; paid work is paused',
  'an open case still blocks a new expense if project status drifts back to active');
select * from finish();
rollback;

begin;
select no_plan();

select ok(has_function_privilege('service_role',
  'public.sutra_authorize_zendesk_task_context(uuid,uuid,text)','EXECUTE'),
  'only the internal service path can request task-scoped Zendesk context authorization');
select ok(not has_function_privilege('anon',
  'public.sutra_authorize_zendesk_task_context(uuid,uuid,text)','EXECUTE'),
  'anonymous clients cannot authorize Zendesk ticket reads');
select ok(not has_table_privilege('service_role','public.support_cases','SELECT'),
  'ticket metadata remains inaccessible by direct service-role table reads');
select ok((select relrowsecurity from pg_class where oid='public.zendesk_reply_actions'::regclass),
  'Zendesk reply delivery rows keep row-level security enabled');
select ok(not has_table_privilege('service_role','public.zendesk_reply_actions','SELECT'),
  'the service runtime can only access replies through claim functions');
select ok(not has_function_privilege('anon','public.sutra_claim_zendesk_reply_action(text)','EXECUTE'),
  'anonymous clients cannot claim a support reply for delivery');
select ok(has_function_privilege('service_role','public.sutra_claim_zendesk_reply_action(text)','EXECUTE'),
  'the private reply worker can claim a budget-reserved action');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true;
select public.sutra_founder_set_zendesk_reply_cost_ceiling('12345678',0.05,
  'Bound the maximum reserved support reply cost for this isolated database test.');
create temporary table zendesk_task_context_ids on commit drop as
  select (proposal.result->>'project_id')::uuid as project_id,
    (select id from public.agents where slug='sales' and active) as agent_id,
    gen_random_uuid() as task_id
  from (select public.sutra_submit_proposal('12345678','Zendesk task context fixture',
    'Exercise scoped support context and private reply draft controls',20,'EUR') as result) proposal;
update public.projects set status='active',budget_assessment_status='within_cap',
  budget_assessed_at=now(),budget_assessment='{"estimated_total_eur":20,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"support","amount_eur":20,"basis":"Test fixture only."}]}'::jsonb
  where id=(select project_id from zendesk_task_context_ids);
update public.approvals set status='approved',
  decisions='{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
  decided_by='founder:12345678',decided_at=now()
  where project_id=(select project_id from zendesk_task_context_ids) and approval_type='project_budget';
select public.sutra_ingest_zendesk_ticket_event('987650001','open','high',now());
insert into public.tasks(id,project_id,title,description,acceptance_criteria,task_type,status,
  owner_agent_id,assigned_agent_id)
  select task_id,project_id,'Triage one Zendesk request','Zendesk ticket ID: 987650001',
    jsonb_build_array('Classify the request and prepare a private unsent reply draft.'),
    'customer_outreach','ready',agent_id,agent_id from zendesk_task_context_ids;
select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-6-luna',1,1,1000,1000,true);
create temporary table zendesk_task_context_claim(payload jsonb) on commit drop;
insert into zendesk_task_context_claim select public.sutra_claim_task_agent_run('sutra-worker-12345678');
select throws_ok($$select public.sutra_authorize_zendesk_task_context(
  (select agent_id from zendesk_task_context_ids),
  (select task_id from zendesk_task_context_ids),'987650002')$$,
  '42501',null,'context authorization rejects a ticket not explicitly named by the exact task');
select is((public.sutra_authorize_zendesk_task_context(
  (select agent_id from zendesk_task_context_ids),
  (select task_id from zendesk_task_context_ids),'987650001')->>'ticket_id'),
  '987650001','the assigned Sales task can authorize only its named open Zendesk case');
select ok(exists(select 1 from public.audit_log where action='support.ticket_context_authorized'
  and resource_type='support_case' and details->>'task_id'=(select task_id::text from zendesk_task_context_ids)),
  'an authorized ephemeral ticket read is audit logged without ticket content');
update public.projects set legal_hold=true where id=(select project_id from zendesk_task_context_ids);
select throws_ok($$select public.sutra_authorize_zendesk_task_context(
  (select agent_id from zendesk_task_context_ids),
  (select task_id from zendesk_task_context_ids),'987650001')$$,
  '42501',null,'a legal hold prevents new support ticket context reads');
update public.projects set legal_hold=false where id=(select project_id from zendesk_task_context_ids);

create temporary table zendesk_task_context_reservation(payload jsonb) on commit drop;
insert into zendesk_task_context_reservation
select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,'openai','gpt-6-luna')
from zendesk_task_context_claim c;
select public.sutra_begin_agent_run_spend('sutra-worker-12345678',
  ((select payload->>'run_id' from zendesk_task_context_claim))::uuid,
  ((select payload->>'lease_token' from zendesk_task_context_claim))::uuid,
  ((select payload->>'reservation_id' from zendesk_task_context_reservation))::uuid);
select public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',
  ((select payload->>'run_id' from zendesk_task_context_claim))::uuid,
  ((select payload->>'lease_token' from zendesk_task_context_claim))::uuid,
  ((select payload->>'reservation_id' from zendesk_task_context_reservation))::uuid,
  'openai','gpt-6-luna',1,1,'{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}'::jsonb,true);
select throws_ok($$select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',
  ((select payload->>'run_id' from zendesk_task_context_claim))::uuid,
  ((select payload->>'lease_token' from zendesk_task_context_claim))::uuid,
  '{"summary":"Support case classified with a private response draft.","recommendation":"Send only after a separate authorized delivery integration is enabled.","evidence":[],"task_acceptance":[{"criterion":"Classify the request and prepare a private unsent reply draft.","evidence":"The output records a bounded category and private reply draft for ticket 987650001."}],"artifact":{"ideal_customer_profile":"A customer who reported an access issue.","lead_criteria":["An open support case has a verified task assignment."],"qualification_questions":["Which access step failed?"],"first_contact_draft":"Private support response draft."},"support_reply_draft":{"ticket_id":"987650002","category":"access","urgency":"high","reply_text":"Please try the account recovery flow; I can help further."}}'::jsonb)$$,
  '42501',null,'a Sales artifact cannot persist a reply draft for a different ticket');
select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',
  ((select payload->>'run_id' from zendesk_task_context_claim))::uuid,
  ((select payload->>'lease_token' from zendesk_task_context_claim))::uuid,
  '{"summary":"Support case classified with a private response draft.","recommendation":"Send only after a separate authorized delivery integration is enabled.","evidence":[],"task_acceptance":[{"criterion":"Classify the request and prepare a private unsent reply draft.","evidence":"The output records a bounded category and private reply draft for ticket 987650001."}],"artifact":{"ideal_customer_profile":"A customer who reported an access issue.","lead_criteria":["An open support case has a verified task assignment."],"qualification_questions":["Which access step failed?"],"first_contact_draft":"Private support response draft."},"support_reply_draft":{"ticket_id":"987650001","category":"access","urgency":"high","reply_text":"Please try the account recovery flow; I can help further."}}'::jsonb);
select is((select artifact->'support_reply_draft'->>'ticket_id' from public.task_agent_artifacts
  where task_id=(select task_id from zendesk_task_context_ids)),'987650001',
  'the task persists a validated support reply draft');
select is((select status from public.zendesk_reply_actions
  where task_id=(select task_id from zendesk_task_context_ids)),'queued',
  'a qualifying private reply draft queues once under a configured reservation ceiling');
select is((select l.reserved_amount from public.zendesk_reply_actions a
  join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
  where a.task_id=(select task_id from zendesk_task_context_ids)),0.05::numeric,
  'the outgoing support reply reserves its full founder-configured EUR cost ceiling');
create temporary table zendesk_reply_claim(payload jsonb) on commit drop;
insert into zendesk_reply_claim select public.sutra_claim_zendesk_reply_action('sutra-worker-zendesk0001');
select is((select payload->'action'->>'reply_text' from zendesk_reply_claim),
  'Please try the account recovery flow; I can help further.',
  'the worker retrieves the private draft only through its atomic claim');
select ok((select public.sutra_validate_zendesk_reply_claim('sutra-worker-zendesk0001',
  (payload->>'action_id')::uuid,(payload->>'claim_token')::uuid) from zendesk_reply_claim),
  'the fresh lease and current budget/legal/ticket state authorize delivery');
select throws_ok($$select public.sutra_founder_set_zendesk_reply_cost_ceiling(
  '12345678',0.06,'Do not change the reservation while a reply is leased.')$$,
  '55000',null,'the founder cannot raise the ceiling while an underfunded reply is sending');
update public.projects set legal_hold=true where id=(select project_id from zendesk_task_context_ids);
select ok(not (select public.sutra_validate_zendesk_reply_claim('sutra-worker-zendesk0001',
  (payload->>'action_id')::uuid,(payload->>'claim_token')::uuid) from zendesk_reply_claim),
  'a legal hold revokes reply delivery before the external write');
select public.sutra_finish_zendesk_reply_action('sutra-worker-zendesk0001',
  (select (payload->>'action_id')::uuid from zendesk_reply_claim),
  (select (payload->>'claim_token')::uuid from zendesk_reply_claim),
  'failed','authorization_revoked',0,true);
select is((select status from public.zendesk_reply_actions
  where id=(select (payload->>'action_id')::uuid from zendesk_reply_claim)),'failed',
  'revoked support replies terminate without a provider write');
select is((select status from public.initiative_budget_ledger
  where id=(select (payload->>'ledger_id')::uuid from zendesk_reply_claim)),'released',
  'a confirmed no-send releases only its known zero usage');
select ok(exists(select 1 from public.audit_log where action='support.reply_failed'
  and resource_id=(select payload->>'action_id' from zendesk_reply_claim)
  and not (details ? 'reply_text')),
  'support reply outcomes are audit logged without customer message text');
select * from finish();
rollback;

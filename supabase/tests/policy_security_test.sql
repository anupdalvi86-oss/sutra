begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

set local role service_role;

select lives_ok($$select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-4o-mini',0,5000,10000,2200,true)$$,
  'founder configures the test model price and hard token ceiling');
select throws_ok($$select public.sutra_set_agent_model_spend_profile('agent','openai','gpt-4o-mini',0,1,10000,2200,true)$$,
  '42501',null,'agents cannot configure model price or token authority');

select is((public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'test 10',10,'EUR')->>'status'),'approved','€10 is automatic');
select is((public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'test 10.01',10.01,'EUR')->'required_approvers')::text,'["department_head"]','above €10 requires department head');
select is((public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'test 50',50,'EUR')->'required_approvers')::text,'["department_head"]','€50 remains in department approval tier');
select is((public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'test 50.01',50.01,'EUR')->'required_approvers')::text,'["cfo", "ceo"]','above €50 requires CFO and CEO');
select is((public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'test 199.99',199.99,'EUR')->'required_approvers')::text,'["cfo", "ceo"]','below €200 remains CFO and CEO tier');
select is((public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'test 200',200,'EUR')->'required_approvers')::text,'["founder"]','€200 requires founder');
select is((public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'test 200.01',200.01,'EUR')->'required_approvers')::text,'["founder"]','above €200 requires founder');

select throws_ok($$select public.sutra_submit_proposal('99999999','Private proposal','Test proposal with a valid long description',500,'EUR')$$,
  '42501',null,'wrong Telegram identity cannot submit a proposal');
select throws_ok($$select public.sutra_set_spending_policy('99999999','automatic_up_to_10',0,10,true,true,'{}',80,true)$$,
  '42501',null,'nonfounder cannot change financial authority');
select throws_ok($$select public.sutra_authorize_spend('agent','founder',(select id from public.agents where slug='ceo'),null,null,'ai_api',null,'impersonation',2,'EUR')$$,
  '42501',null,'agent cannot impersonate founder');
select throws_ok($$select public.sutra_authorize_spend('agent','developer',(select id from public.agents where slug='developer'),null,(select id from public.departments where slug='finance'),'ai_api',null,'department spoof',2,'EUR')$$,
  '42501',null,'agent cannot spoof a different department');
select throws_ok($$select public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'negative spend',-1,'EUR')$$,
  '22023',null,'malformed spend amount is rejected');
select throws_ok($$select public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'infinite spend','Infinity'::numeric,'EUR')$$,
  '22023',null,'infinite spend amount is rejected');
select throws_ok($$select public.sutra_authorize_spend(null,'test',null,null,null,'ai_api',null,'missing actor',1,'EUR')$$,
  '22023',null,'missing actor type is rejected');
select is((public.sutra_submit_proposal('12345678','AI QA opportunity','Investigate an AI QA product for software teams',500,'EUR')->>'status'),
  'pending_founder_approval','valid founder proposal is persisted with approvals');
select ok(exists(select 1 from public.agent_runs where trigger_type='founder_proposal' and status='queued'),'workflow roles receive durable queued runs');
select ok(exists(select 1 from public.tasks where task_type='research' and status='blocked'),'execution work stays blocked before founder approval');
select throws_ok($$select public.sutra_founder_decide_approval('12345678',(select id from public.approvals where approval_type='project_budget' limit 1),'approve','')$$,
  '42501',null,'founder approval cannot skip the required CFO decision');
select throws_ok($$select public.sutra_claim_agent_run('bad-worker')$$,
  '22023',null,'worker claims require a bounded worker identity');

select throws_ok($$update public.spending_policies set required_approvers='{}' where name='founder_200_and_over'$$,
  '42501',null,'service_role cannot mutate spending authority directly');
select is((public.sutra_authorize_spend('agent','developer',(select id from public.agents where slug='developer'),null,null,
  'ai_api',null,'department approval test',11,'EUR')->>'status'),'requested','spend above €10 creates an approval request');
select throws_ok($$select public.sutra_decide_role_approval((select id from public.approvals where summary='department approval test' limit 1),
  (select id::text from public.agents where slug='developer'),'department_head','approve','')$$,
  '42501',null,'department approval requires a founder-designated head');
select lives_ok($$select public.sutra_set_company_setting('12345678',
  'department_head:' || (select department_id::text from public.agents where slug='developer'),
  to_jsonb((select id::text from public.agents where slug='developer')))$$,
  'founder can designate a department head through the audited setting function');
select ok(exists(select 1 from public.company_settings s join public.agents a on a.id::text=s.value #>> '{}'
  where s.key='department_head:' || (select department_id::text from public.agents where slug='developer')
    and a.slug='developer'),'founder-designated head is visible to the policy lookup');
select is((public.sutra_decide_role_approval((select id from public.approvals where summary='department approval test' limit 1),
  (select id::text from public.agents where slug='developer'),'department_head','approve','Designated head review')->>'status'),
  'approved','only the designated department head can approve');
reset role;
set local role anon;
select throws_ok($$select * from public.spending_policies$$,'42501',null,'anon role cannot read spending policies');
reset role;
set local role service_role;
select throws_ok($$select public.sutra_authorize_spend('system','test',null,(select id from public.projects order by created_at desc limit 1),null,'ai_api',null,'premature spend',5,'EUR')$$,
  '42501',null,'spending against a proposed project is blocked');
select lives_ok($$select public.sutra_set_company_setting('12345678',
  'department_head:' || (select department_id::text from public.agents where slug='cpo'),
  to_jsonb((select id::text from public.agents where slug='cpo')))$$,
  'founder designates a department head for review-spend approval');
create temporary table worker_claims(role text,run_id uuid,lease_token uuid,sequence_no integer) on commit drop;
create temporary table worker_spend_decision(payload jsonb) on commit drop;
create function pg_temp.prepare_agent_run_spend(p_run_id uuid,p_lease_token uuid) returns jsonb
language plpgsql as $$
declare reservation jsonb; reservation_id uuid; reconciliation jsonb;
begin
  reservation := public.sutra_reserve_agent_run_spend('sutra-worker-12345678',p_run_id,p_lease_token,
    'openai','gpt-4o-mini',11);
  if reservation->>'status' <> 'approved' then raise exception 'test reservation unexpectedly needs approval'; end if;
  reservation_id := (reservation->>'reservation_id')::uuid;
  perform public.sutra_begin_agent_run_spend('sutra-worker-12345678',p_run_id,p_lease_token,reservation_id);
  reconciliation := public.sutra_reconcile_agent_run_spend('sutra-worker-12345678',p_run_id,p_lease_token,reservation_id,
    'openai','gpt-4o-mini',0.01,1,1,'{"source":"test_usage"}'::jsonb,true);
  return reservation || jsonb_build_object('reconciliation',reconciliation);
end;
$$;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'ceo','CEO receives the first leased review run');
select is(public.sutra_claim_agent_run('sutra-worker-abcdefgh')::text,null::text,
  'later department work stays unclaimable until the prior review completes');
insert into worker_spend_decision select public.sutra_reserve_agent_run_spend('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'openai','gpt-4o-mini',11);
select is((select payload->>'status' from worker_spend_decision),'requested',
  'model spend above €10 follows the configured approval tier');
select is((select status from public.agent_runs where id=(select run_id from worker_claims)),'blocked',
  'worker cannot proceed while model spend approval is pending');
select is((select max_output_tokens from public.agent_run_spend_reservations where agent_run_id=(select run_id from worker_claims)),2200,
  'reservation snapshots the founder-configured output token ceiling');
select is((select output_eur_per_million_tokens from public.agent_run_spend_reservations where agent_run_id=(select run_id from worker_claims)),5000::numeric,
  'reservation snapshots database pricing instead of trusting the worker quote');
select is((select project_id::text from public.expenses where id=(select (payload->>'expense_id')::uuid from worker_spend_decision)),
  (select project_id::text from public.agent_runs where id=(select run_id from worker_claims)),
  'model spend approval is tied to its proposal project');
select is((select count(*)::integer from public.approvals ap
  join public.projects p on p.id=ap.project_id
  join public.agents a on a.slug='cpo' and a.department_id=p.department_id and a.active
  join public.company_settings s on s.key='department_head:' || p.department_id::text
    and s.value #>> '{}'=a.id::text where ap.id=(select (payload->>'approval_id')::uuid from worker_spend_decision)),
  1,'configured department head matches the proposal department and approval');
select is((public.sutra_decide_role_approval(
  (select (payload->>'approval_id')::uuid from worker_spend_decision),
  (select id::text from public.agents where slug='cpo'),'department_head','approve','Bounded review spend')->>'status'),
  'approved','designated department head can approve a model spend request');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'ceo','approved spend resumes the CEO run');
select is((select status from public.expenses where id=(select (payload->>'expense_id')::uuid from worker_spend_decision)),
  'approved','approval authorizes the model expense');
select throws_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),'00000000-0000-4000-8000-000000000099'::uuid,'succeeded',
  '{"summary":"A sufficiently long CEO summary","recommendation":"Proceed","evidence":[]}'::jsonb)$$,
  '42501',null,'a different lease token cannot complete a review');
select throws_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long CEO summary","recommendation":"Proceed to evidence review","evidence":[]}'::jsonb)$$,
  '42501',null,'a paid review cannot succeed before its spend is reconciled');
select throws_ok($$select public.sutra_begin_agent_run_spend('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),gen_random_uuid())$$,
  '42501',null,'provider call cannot start without an approved spend reservation');
select is((pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims))->>'reused'),'true','approved provider spend is reused, started, and reconciled');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long CEO summary","recommendation":"Proceed to evidence review","evidence":[]}'::jsonb)$$,
  'CEO review is stored through the leased completion RPC');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'cpo','Product research runs after CEO review');
select lives_ok($$select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims))$$,'product research provider spend is reconciled');
select throws_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long research summary","recommendation":"Proceed","evidence":[]}'::jsonb)$$,
  '22023',null,'Product research cannot complete without evidence');
select throws_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long research summary","recommendation":"Proceed","evidence":[{"source":"A source","url":"http://example.com","claim":"A claim"}]}'::jsonb)$$,
  '22023',null,'database rejects non-HTTPS research evidence');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long research summary","recommendation":"Proceed to technical review","evidence":[{"source":"Product documentation","url":"https://example.com/docs","claim":"Primary source describes a QA workflow."}]}'::jsonb)$$,
  'Product research records cited HTTPS evidence');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'cto','CTO review runs after Product research');
select lives_ok($$select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims))$$,'technical review provider spend is reconciled');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long technical summary","recommendation":"Proceed to finance review","evidence":[]}'::jsonb)$$,
  'CTO review is stored before finance review');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'cfo','CFO review runs after CTO review');
select lives_ok($$select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims))$$,'finance review provider spend is reconciled');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long CFO summary","recommendation":"Present the budget to the founder","evidence":[],"decision":"approve","decision_rationale":"The proposal is ready for a separate founder decision."}'::jsonb)$$,
  'CFO artifact records role approval without resolving founder approval');
select is((select status from public.approvals where approval_type='project_budget' limit 1),'pending',
  'CFO approval leaves founder approval pending');
select throws_ok($$select public.sutra_founder_decide_approval('12345678',
  (select id from public.approvals where approval_type='project_budget' limit 1),'approve','')$$,
  '42501',null,'founder approval also waits for the PM review');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'product_manager','PM review runs after CFO review');
select lives_ok($$select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims))$$,'PM review provider spend is reconciled');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long PM summary","recommendation":"Founder review is ready","evidence":[],"milestones":["Discovery"]}'::jsonb)$$,
  'PM work is stored before final founder approval');
select lives_ok($$select public.sutra_founder_decide_approval('12345678',
  (select id from public.approvals where approval_type='project_budget' limit 1),'approve','Proceed')$$,
  'founder can approve only after CEO, Product, CTO, CFO, and PM reviews');
select is((select status from public.projects order by created_at desc limit 1),'approved','founder approval activates the proposal');
select ok(exists(select 1 from public.tasks where task_type='product' and owner_agent_id=assigned_agent_id),
  'new tasks populate both current and legacy assignee columns');
select is((select status from public.tasks where task_type='research' order by created_at limit 1),'ready','research becomes executable after approval');
select is((select count(*)::integer from public.tasks where task_type='engineering' and status='backlog'),7,'engineering through sales handoff tasks are queued');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='product_manager'),
  (select id from public.tasks where task_type='product' order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  'assigned PM can start the approved planning task');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='product_manager'),
  (select id from public.tasks where task_type='product' order by created_at desc limit 1),'done','{"requirements":"recorded"}'::jsonb)$$,
  'PM completion requires and records evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='architect') order by created_at desc limit 1),
  'ready','PM completion releases architecture task');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  '22023',null,'developer cannot start before architecture handoff');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='architect'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='architect') order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  'assigned architect can start when its task is ready');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='architect'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='architect') order by created_at desc limit 1),'done','{"design":"reviewed"}'::jsonb)$$,
  'architecture completion records evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),
  'ready','architecture completion releases developer task');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  'assigned developer can start after architecture');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'done','{}'::jsonb)$$,
  '22023',null,'completion without evidence is rejected');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'done','{"pull_request":"drafted"}'::jsonb)$$,
  'developer completion requires evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  'ready','developer completion releases QA task');

select lives_ok($$select public.sutra_set_budget('12345678','company','*','transaction',5,80,true)$$,
  'founder can configure a transaction hard stop through the audited policy function');
select throws_ok($$select public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'over hard stop',6,'EUR')$$,
  '23514',null,'transaction budget exhaustion blocks the spend');
select throws_ok($$select public.sutra_set_budget('99999999','company','*','transaction',500,80,true)$$,
  '42501',null,'nonfounder cannot change company budget');

reset role;
select ok((select count(*) from public.audit_log where action='spending.authorization_requested') >= 7,'authorization decisions are audit logged');
select is((select count(*)::integer from public.audit_log where action='agent_run.succeeded'),5,
  'each executed department review is audit logged');
select is((select count(*)::integer from public.audit_log where action='agent_run.spend_reconciled'),5,
  'each model usage reconciliation is audit logged');
select is((select count(*)::integer from public.audit_log where action='agent_run.spend_reserved'),5,
  'each model spend reservation decision is audit logged');
select is((select count(*)::integer from public.audit_log where action='agent_run.spend_approval_resumed'),1,
  'approval-driven model run resumption is audit logged');
select is((select count(*)::integer from public.expenses where actual_amount=0.01),5,
  'actual model usage is reconciled into its authoritative expense');

select * from finish();
rollback;

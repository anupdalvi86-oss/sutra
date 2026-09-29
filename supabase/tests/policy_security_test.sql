begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

set local role service_role;

select lives_ok($$select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-4o-mini',0,1666.666,10000,2200,true)$$,
  'founder configures the test model price and hard token ceiling');
select lives_ok($$select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-4o-mini-test-cheap',0,1.5,10000,2200,true)$$,
  'founder configures a low-cost fixture route for downstream departments');
select is((public.sutra_get_agent_model_spend_profile('openai','gpt-4o-mini')->>'configured'),'true',
  'worker profile lookup returns an active exact route');
select is((public.sutra_get_agent_model_spend_profile('openai','unconfigured-model')->>'configured'),'false',
  'unconfigured models fail closed before any worker provider request');
select throws_ok($$select public.sutra_set_agent_model_spend_profile('agent','openai','gpt-4o-mini',0,1,10000,2200,true)$$,
  '42501',null,'agents cannot configure model price or token authority');
select throws_ok($$update public.agent_model_spend_profiles set output_eur_per_million_tokens=1 where provider='openai'$$,
  '42501',null,'server role cannot change model price profiles directly');
select throws_ok($$select * from public.agent_model_spend_profiles$$,
  '42501',null,'service role uses only the audited model profile RPC');

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
select throws_ok($$select public.sutra_set_budget('developer','agent','developer','monthly',999,80,true)$$,
  '42501',null,'agent cannot increase its own budget or financial authority');
select throws_ok($$select public.sutra_set_company_setting('developer','agent_budget_override','999'::jsonb)$$,
  '42501',null,'agent cannot write company settings to escalate its authority');
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
select throws_ok($$select public.sutra_founder_pending_approvals('99999999')$$,
  '42501',null,'nonfounder cannot inspect the founder approval queue');
create temporary table founder_approval_queue_test as
  select jsonb_array_elements(public.sutra_founder_pending_approvals('12345678')->'approvals') as item;
select ok(exists(select 1 from founder_approval_queue_test where item->>'approval_id'=(select id::text
  from public.approvals where approval_type='project_budget' order by created_at desc limit 1)),
  'founder approval queue includes the pending founder request');
select ok(exists(select 1 from founder_approval_queue_test
  where item->>'summary'='CFO review followed by founder approval: proposed maximum budget for AI QA opportunity'),
  'founder approval queue includes a bounded summary');
select ok(exists(select 1 from founder_approval_queue_test where (item->>'amount')::numeric=500 and item->>'currency'='EUR'),
  'founder approval queue shows the requested amount and currency');
select ok(exists(select 1 from founder_approval_queue_test where item->'pending_roles'='["cfo","product_manager"]'::jsonb),
  'founder approval queue reports CFO and PM reviews still outstanding');
select ok(exists(select 1 from founder_approval_queue_test where item->>'ready'='false'),
  'founder approval queue marks the request as not ready for founder approval');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='founder.approvals_listed' and resource_type='approval_queue'),
  'founder approval queue reads are audit logged');
select ok(exists(select 1 from public.agent_runs where trigger_type='founder_proposal' and status='queued'),'workflow roles receive durable queued runs');
select ok(exists(select 1 from public.tasks where task_type='research' and status='blocked'),'execution work stays blocked before founder approval');
select is(public.sutra_claim_task_agent_run('sutra-worker-12345678')::text,null::text,
  'internal task artifact workers cannot claim tasks before founder project approval');
select throws_ok($$select public.sutra_founder_decide_approval('12345678',(select id from public.approvals where approval_type='project_budget' limit 1),'approve','')$$,
  '42501',null,'founder approval cannot skip the required CFO decision');
select throws_ok($$select public.sutra_claim_agent_run('bad-worker')$$,
  '22023',null,'worker claims require a bounded worker identity');

select throws_ok($$update public.spending_policies set required_approvers='{}' where name='founder_200_and_over'$$,
  '42501',null,'service_role cannot mutate spending authority directly');
select is((public.sutra_authorize_spend('agent','architect',(select id from public.agents where slug='architect'),null,null,
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
select is((public.sutra_authorize_spend('agent','developer',(select id from public.agents where slug='developer'),null,null,
  'ai_api',null,'developer self approval test',11,'EUR')->>'status'),'requested','developer test expense awaits approval');
select is((select requested_by_agent_id from public.approvals where summary='developer self approval test' limit 1),
  (select id from public.agents where slug='developer'),'expense approval retains its requesting agent identity');
select throws_ok($$select public.sutra_decide_role_approval((select id from public.approvals where summary='developer self approval test' limit 1),
  (select id::text from public.agents where slug='developer'),'department_head','approve','')$$,
  '42501',null,'an agent cannot approve its own expense');
select lives_ok($$select public.sutra_set_company_setting('12345678',
  'department_head:' || (select department_id::text from public.agents where slug='qa'),
  to_jsonb((select id::text from public.agents where slug='cto')))$$,
  'founder can designate a cross-department head for a one-agent department');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='company.setting_changed' and resource_type='company_setting'
  and resource_id='department_head:' || (select department_id::text from public.agents where slug='qa')),
  'department-head delegation changes are audit logged');
select is((public.sutra_decide_role_approval(
  (public.sutra_authorize_spend('agent','qa',(select id from public.agents where slug='qa'),null,null,
    'ai_api',null,'cross department approval test',11,'EUR')->>'approval_id')::uuid,
  (select id::text from public.agents where slug='cto'),'department_head','approve','Scoped QA approval')->>'status'),
  'approved','cross-department head can approve only the department they were assigned');
reset role;
set local role anon;
select throws_ok($$select * from public.spending_policies$$,'42501',null,'anon role cannot read spending policies');
select throws_ok($$select * from public.agent_model_spend_profiles$$,'42501',null,'anon role cannot read model pricing profiles');
select throws_ok($$select public.sutra_get_agent_model_spend_profile('openai','gpt-4o-mini')$$,
  '42501',null,'anon role cannot inspect model route or pricing');
select throws_ok($$select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',gen_random_uuid(),gen_random_uuid(),'openai','gpt-4o-mini')$$,
  '42501',null,'anon role cannot create a paid model reservation');
select throws_ok($$select public.sutra_claim_github_task('sutra-github-worker-12345678')$$,
  '42501',null,'anon role cannot dispatch GitHub issues');
select throws_ok($$select * from public.github_task_dispatches$$,
  '42501',null,'anon role cannot read GitHub dispatch leases or issue metadata');
select throws_ok($$select public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',gen_random_uuid(),
  'acme/sutra','pull_request','{}'::jsonb)$$,'42501',null,'anon role cannot ingest GitHub evidence');
select throws_ok($$select * from public.github_webhook_deliveries$$,
  '42501',null,'anon role cannot read signed webhook deliveries');
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
create function pg_temp.model_usage_rejected(
  p_run_id uuid,p_lease_token uuid,p_reservation_id uuid,p_model text,
  p_input_tokens bigint,p_output_tokens bigint,p_usage jsonb,p_expected_sqlstate text
) returns boolean language plpgsql as $$
begin
  perform public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',p_run_id,p_lease_token,
    p_reservation_id,'openai',p_model,p_input_tokens,p_output_tokens,p_usage,true);
  return false;
exception
  when sqlstate '22023' then return p_expected_sqlstate='22023';
  when sqlstate '23514' then return p_expected_sqlstate='23514';
end;
$$;
create function pg_temp.prepare_agent_run_spend(p_run_id uuid,p_lease_token uuid) returns jsonb
language plpgsql as $$
declare reservation jsonb; reservation_id uuid; reconciliation jsonb; model_name text;
begin
  select case when a.slug='ceo' then 'gpt-4o-mini' else 'gpt-4o-mini-test-cheap' end
    into model_name from public.agent_runs r join public.agents a on a.id=r.agent_id where r.id=p_run_id;
  reservation := public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',p_run_id,p_lease_token,
    'openai',model_name);
  if reservation->>'status' <> 'approved' then raise exception 'test reservation unexpectedly needs approval'; end if;
  reservation_id := (reservation->>'reservation_id')::uuid;
  perform public.sutra_begin_agent_run_spend('sutra-worker-12345678',p_run_id,p_lease_token,reservation_id);
  if not pg_temp.model_usage_rejected(p_run_id,p_lease_token,reservation_id,model_name,1,1,
      '{"prompt_tokens":1,"completion_tokens":1}'::jsonb,'22023') then
    raise exception 'Hermes usage without total_tokens was accepted';
  end if;
  if not pg_temp.model_usage_rejected(p_run_id,p_lease_token,reservation_id,model_name,1,1,
      '{"prompt_tokens":"1","completion_tokens":1,"total_tokens":2}'::jsonb,'22023') then
    raise exception 'Hermes usage with nonnumeric token data was accepted';
  end if;
  if not pg_temp.model_usage_rejected(p_run_id,p_lease_token,reservation_id,model_name,2,1,
      '{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}'::jsonb,'22023') then
    raise exception 'Hermes token counts inconsistent with its usage envelope were accepted';
  end if;
  if not pg_temp.model_usage_rejected(p_run_id,p_lease_token,reservation_id,model_name,10001,1,
      '{"prompt_tokens":10001,"completion_tokens":1,"total_tokens":10002}'::jsonb,'23514') then
    raise exception 'model usage above its database profile was accepted';
  end if;
  reconciliation := public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',p_run_id,p_lease_token,reservation_id,
    'openai',model_name,1,1,'{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}'::jsonb,true);
  return reservation || jsonb_build_object('reconciliation',reconciliation);
end;
$$;
create function pg_temp.run_task_artifact(p_expected_role text,p_artifact jsonb) returns jsonb
language plpgsql as $$
declare claim jsonb; criteria jsonb; output jsonb; result jsonb;
begin
  claim:=public.sutra_claim_task_agent_run('sutra-worker-12345678');
  if claim is null or claim->'agent'->>'slug'<>p_expected_role then
    raise exception 'expected task artifact role %, received %',p_expected_role,claim->'agent'->>'slug';
  end if;
  perform pg_temp.prepare_agent_run_spend((claim->>'run_id')::uuid,(claim->>'lease_token')::uuid);
  criteria:=claim->'task_artifact'->'acceptance_criteria';
  select coalesce(jsonb_agg(jsonb_build_object('criterion',value,'evidence','Recorded in the persisted role artifact.')),'[]'::jsonb)
    into output from jsonb_array_elements_text(criteria) expected(value);
  output:=jsonb_build_object('summary','A durable role-specific artifact has been prepared.',
    'recommendation','Proceed to the next assigned review stage.','evidence',
      case when p_expected_role='cmo' then jsonb_build_array(jsonb_build_object(
        'source','Primary source','url','https://example.com/product','claim','The source supports the campaign claim.'))
      else '[]'::jsonb end,
    'task_acceptance',output,'artifact',p_artifact);
  result:=public.sutra_submit_task_agent_artifact('sutra-worker-12345678',(claim->>'run_id')::uuid,
    (claim->>'lease_token')::uuid,output);
  return result;
end;
$$;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select throws_ok($$select public.sutra_reserve_agent_run_spend('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'openai','gpt-4o-mini',0.01)$$,
  '42501',null,'worker cannot underquote the database-calculated maximum model cost');
select is((select role from worker_claims),'ceo','CEO receives the first leased review run');
select is(public.sutra_claim_agent_run('sutra-worker-abcdefgh')::text,null::text,
  'later department work stays unclaimable until the prior review completes');
insert into worker_spend_decision select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'openai','gpt-4o-mini');
select is((select payload->>'status' from worker_spend_decision),'requested',
  'model spend above €10 follows the configured approval tier');
select is((select status from public.agent_runs where id=(select run_id from worker_claims)),'blocked',
  'worker cannot proceed while model spend approval is pending');
select is((select (payload->>'max_output_tokens')::integer from worker_spend_decision),2200,
  'reservation snapshots the founder-configured output token ceiling');
select is((select (payload->>'max_model_iterations')::integer from worker_spend_decision),3,
  'reservation uses the image-enforced maximum model iterations');
select is((select (payload->>'output_eur_per_million_tokens')::numeric from worker_spend_decision),1666.666::numeric,
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
select ok(exists(select 1 from jsonb_array_elements(public.sutra_founder_pending_approvals('12345678')->'approvals') item
  where item->>'ready'='false' and item->'pending_roles'='["product_manager"]'::jsonb),
  'founder queue remains blocked until the product manager plan succeeds');
select throws_ok($$select public.sutra_founder_decide_approval('12345678',
  (select id from public.approvals where approval_type='project_budget' limit 1),'approve','')$$,
  '42501',null,'founder approval also waits for the PM review');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'product_manager','PM review runs after CFO review');
create temporary table retry_attempt_reservation(payload jsonb) on commit drop;
insert into retry_attempt_reservation
select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'openai','gpt-4o-mini-test-cheap');
select is((select payload->>'status' from retry_attempt_reservation),'approved','first PM review attempt is within its database-approved budget');
select lives_ok($$select public.sutra_begin_agent_run_spend('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),
  (select (payload->>'reservation_id')::uuid from retry_attempt_reservation))$$,
  'PM model request begins only after reservation');
select is((public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),
  (select (payload->>'reservation_id')::uuid from retry_attempt_reservation),
  'openai','gpt-4o-mini-test-cheap',null,null,'{"source":"simulated_unknown_usage"}'::jsonb,false)->>'status'),
  'unknown','first PM attempt fails closed when provider usage cannot be verified');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'failed',
  '{"summary":"PM usage could not be verified","usage_state":"unverified"}'::jsonb,
  'unknown_or_overrun_spend')$$,'unknown first PM attempt is terminal and audited');
select throws_ok($$select public.sutra_founder_retry_pm_review('99999999',(select run_id from worker_claims))$$,
  '42501',null,'nonfounder cannot retry a failed PM review');
select throws_ok($$select public.sutra_founder_retry_pm_review('12345678',null)$$,
  '22023',null,'malformed retry request is rejected');
create temporary table retry_request_result(payload jsonb) on commit drop;
insert into retry_request_result
select public.sutra_founder_retry_pm_review('12345678',(select run_id from worker_claims));
select is((select payload->>'status' from retry_request_result),
  'queued','founder can queue a bounded PM retry while the project approval is pending');
select is((select (payload->>'preserved_unknown_reservations')::integer from retry_request_result),1,
  'founder retry preserves the earlier unknown spend reservation');
select ok(exists(select 1 from public.audit_log where action='founder.pm_review_retry_requested'
  and resource_id=(select run_id::text from worker_claims)),
  'founder PM retry is audit logged');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'product_manager','founder retry reclaims the same PM stage');
select is((select attempt_count from public.agent_runs where id=(select run_id from worker_claims)),2,
  'retry increments the bounded PM run attempt counter');
create temporary table retry_attempt_two_reservation(payload jsonb) on commit drop;
insert into retry_attempt_two_reservation
select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims));
select is((select payload->>'status' from retry_attempt_two_reservation),'approved',
  'retry uses a new centrally reserved attempt');
select ok((select payload->>'reservation_id' from retry_attempt_two_reservation)
  <> (select payload->>'reservation_id' from retry_attempt_reservation),
  'retry creates a distinct spend reservation without rewriting the prior attempt');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'retry',
  '{"summary":"PM artifact schema was invalid","failure_category":"invalid_agent_output","failure_detail_code":"invalid_artifact_schema","usage_state":"reconciled"}'::jsonb,
  'invalid_agent_output')$$,'second PM schema failure uses the bounded third attempt');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'product_manager','third standard attempt remains the same PM stage');
select is((select attempt_count from public.agent_runs where id=(select run_id from worker_claims)),3,
  'standard PM retry limit stops at three attempts');
create temporary table retry_attempt_three_reservation(payload jsonb) on commit drop;
insert into retry_attempt_three_reservation
select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims));
select is((select payload->>'status' from retry_attempt_three_reservation),'approved',
  'third standard PM attempt requires its own central spend reservation');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'retry',
  '{"summary":"PM artifact schema was invalid","failure_category":"invalid_agent_output","failure_detail_code":"invalid_artifact_schema","usage_state":"reconciled"}'::jsonb,
  'invalid_agent_output')$$,'third schema failure becomes terminal');
create temporary table final_pm_recovery(payload jsonb) on commit drop;
insert into final_pm_recovery
select public.sutra_founder_retry_pm_review('12345678',(select run_id from worker_claims));
select is((select payload->>'final_recovery_attempt' from final_pm_recovery),'true',
  'founder can authorize one final recovery only for a reconciled PM schema failure');
select is((select payload->>'preserved_unknown_reservations' from final_pm_recovery),'1',
  'final recovery preserves the earlier unknown reservation');
select ok(exists(select 1 from public.audit_log where action='founder.pm_review_final_recovery_requested'
  and resource_id=(select run_id::text from worker_claims)),
  'final recovery is separately audit logged');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'product_manager','final recovery reclaims only the same PM stage');
select is((select attempt_count from public.agent_runs where id=(select run_id from worker_claims)),4,
  'founder recovery is exactly one fourth attempt');
reset role;
update public.agent_runs set output=output-'founder_pm_recovery' where id=(select run_id from worker_claims);
set local role service_role;
select throws_ok($$select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'openai','gpt-4o-mini-test-cheap')$$,
  '42501',null,'a fourth model reservation requires the founder recovery marker');
reset role;
update public.agent_runs set output=output||jsonb_build_object('founder_pm_recovery','requested') where id=(select run_id from worker_claims);
set local role service_role;
create temporary table final_pm_recovery_reservation(payload jsonb) on commit drop;
insert into final_pm_recovery_reservation
select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims));
select is((select payload->>'status' from final_pm_recovery_reservation),'approved',
  'final recovery still requires a fresh central reservation');
select ok((select payload->>'reservation_id' from final_pm_recovery_reservation)
  <> (select payload->>'reservation_id' from retry_attempt_three_reservation),
  'final recovery cannot reuse a prior attempt reservation');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A sufficiently long PM summary","recommendation":"Founder review is ready","evidence":[],"milestones":["Discovery"]}'::jsonb)$$,
  'final PM recovery can persist its valid artifact after spend reconciliation');
select ok(exists(select 1 from jsonb_array_elements(public.sutra_founder_pending_approvals('12345678')->'approvals') item
  where item->>'ready'='true' and item->'pending_roles'='[]'::jsonb),
  'founder queue becomes ready after all department and PM reviews succeed');
select lives_ok($$select public.sutra_founder_decide_approval('12345678',
  (select id from public.approvals where approval_type='project_budget' limit 1),'approve','Proceed')$$,
  'founder can approve only after CEO, Product, CTO, CFO, and PM reviews');
select is((select status from public.projects order by created_at desc limit 1),'approved','founder approval activates the proposal');
select ok(exists(select 1 from public.tasks where task_type='product' and owner_agent_id=assigned_agent_id),
  'new tasks populate both current and legacy assignee columns');
select is((select status from public.tasks where task_type='research' order by created_at limit 1),'ready','research becomes executable after approval');
select is((select count(*)::integer from public.tasks where task_type='engineering' and status='backlog'),7,'engineering through sales handoff tasks are queued');
create temporary table task_artifact_claim(payload jsonb) on commit drop;
insert into task_artifact_claim select public.sutra_claim_task_agent_run('sutra-worker-12345678');
select is((select payload->'agent'->>'slug' from task_artifact_claim),'product_manager',
  'the approved project leases the product planning task to its assigned PM');
select throws_ok($$select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from task_artifact_claim),(select (payload->>'lease_token')::uuid from task_artifact_claim),
  '{"summary":"A sufficiently long planning summary","recommendation":"Proceed","evidence":[],"task_acceptance":[],"artifact":{}}'::jsonb)$$,
  '42501',null,'task artifact cannot persist before this run has reconciled provider spend');
select lives_ok($$select pg_temp.prepare_agent_run_spend((select (payload->>'run_id')::uuid from task_artifact_claim),
  (select (payload->>'lease_token')::uuid from task_artifact_claim))$$,
  'PM task artifact provider spend is reconciled before deliverable persistence');
select throws_ok($$select public.sutra_submit_task_agent_artifact('bad-worker',
  (select (payload->>'run_id')::uuid from task_artifact_claim),(select (payload->>'lease_token')::uuid from task_artifact_claim),
  '{"summary":"A sufficiently long planning summary","recommendation":"Proceed","evidence":[],"task_acceptance":[],"artifact":{}}'::jsonb)$$,
  '22023',null,'malformed worker requests cannot persist a task artifact');
select throws_ok($$select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from task_artifact_claim),gen_random_uuid(),
  '{"summary":"A sufficiently long planning summary","recommendation":"Proceed","evidence":[],"task_acceptance":[],"artifact":{}}'::jsonb)$$,
  '42501',null,'task artifacts require the exact active database lease token');
create temporary table artifact_submit(payload jsonb) on commit drop;
insert into artifact_submit
select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',(c.payload->>'run_id')::uuid,
  (c.payload->>'lease_token')::uuid,jsonb_build_object('summary','A durable product plan has been prepared.',
    'recommendation','Proceed to technical design.','evidence','[]'::jsonb,
    'task_acceptance',(select jsonb_agg(jsonb_build_object('criterion',value,'evidence','Recorded in the product plan artifact.'))
      from jsonb_array_elements_text(c.payload->'task_artifact'->'acceptance_criteria') expected(value)),
    'artifact',jsonb_build_object('scope','A bounded scope for the founder-approved product proposal.',
      'milestones',jsonb_build_array('Discovery and validated requirements'),
      'acceptance_criteria',jsonb_build_array('Document the buyer need and measurable success criteria'))))
from task_artifact_claim c;
select is((select payload->>'status' from artifact_submit),'succeeded','PM task output is persisted through its spend-gated artifact RPC');
reset role;
select is((select count(*)::integer from public.task_agent_artifacts where artifact_type='product_plan'),1,
  'PM product plan artifact is durably stored');
reset role;
create temporary table retry_queue_fixture(task_id uuid, queued_run_id uuid) on commit drop;
do $$
declare task_id uuid; pm_id uuid; project_id uuid; queued_run_id uuid;
begin
  select id into pm_id from public.agents where slug='product_manager' and active;
  select id into project_id from public.projects where status='approved' order by created_at desc limit 1;
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
    values(project_id,'Retry-race fixture','A fixture for bounded retry recovery.','["The output is recorded"]'::jsonb,
      'planning','in_progress',pm_id,pm_id) returning id into task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at,attempt_count)
    values(pm_id,project_id,task_id,'task_artifact','failed','{}'::jsonb,
      '{"error_code":"invalid_agent_output","failure_detail_code":"invalid_acceptance_criteria"}'::jsonb,
      now()-interval '2 minutes',now()-interval '2 minutes',1);
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,attempt_count)
    values(pm_id,project_id,task_id,'task_artifact','queued','{}'::jsonb,'{}'::jsonb,
      now()-interval '1 minute',1) returning id into queued_run_id;
  insert into retry_queue_fixture values(task_id,queued_run_id);
end;
$$;
grant select on retry_queue_fixture to service_role;
create temporary table retry_queue_claim(payload jsonb) on commit drop;
grant insert,select on retry_queue_claim to service_role;
set local role service_role;
insert into retry_queue_claim select public.sutra_claim_task_agent_run('sutra-worker-12345678');
reset role;
select is((select payload->>'run_id' from retry_queue_claim),(select queued_run_id::text from retry_queue_fixture),
  'a queued bounded retry is claimed before an earlier failure can block its task');
select is((select status from public.agent_runs where id=(select queued_run_id from retry_queue_fixture)),'running',
  'claiming the retry moves its run to running');
select is((select attempt_count from public.agent_runs where id=(select queued_run_id from retry_queue_fixture)),2,
  'retry attempt count increments on claim');
select is((select status from public.tasks where id=(select task_id from retry_queue_fixture)),'in_progress',
  'queued retry keeps its task in progress');
select ok(to_regclass('public.task_agent_artifacts_agent_id_idx') is not null,
  'task artifact agent foreign key has a covering index');
set local role service_role;
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='architect') order by created_at desc limit 1),
  'ready','PM completion releases architecture task');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  '22023',null,'developer cannot start before architecture handoff');
select is((pg_temp.run_task_artifact('architect',jsonb_build_object('design','A component design with bounded interfaces and data flow.',
  'components',jsonb_build_array('Founder command service','Authoritative Supabase workflow'),
  'security_risks',jsonb_build_array('Protect private integration credentials')))->>'status'),
  'succeeded','Architect persists its spend-gated technical design and exact task evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),
  'blocked','architecture completion holds Developer work for founder scope review');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'ready','{}'::jsonb)$$,
  '42501',null,'Developer cannot self-release a blocked task');
select is((select item->'scope_review'->>'design'
  from jsonb_array_elements(public.sutra_founder_pending_approvals('12345678')->'approvals') item
  where item->>'approval_type'='developer_scope'
    and item->>'action_ref'=(select id::text from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1)),
  'A component design with bounded interfaces and data flow.','founder scope queue contains the exact persisted technical design');
select is((select count(*)::integer from public.approvals sa join public.tasks t on t.id::text=sa.action_ref
  where sa.approval_type='developer_scope' and sa.status='pending' and t.owner_agent_id=(select id from public.agents where slug='developer')),
  1,'completed technical design creates one durable founder scope approval');
select is(public.sutra_claim_github_task('sutra-github-worker-abcdefgh')::text,null::text,
  'GitHub cannot dispatch Developer work before founder approves scope');
select lives_ok($$select public.sutra_founder_decide_approval('12345678',
  (select sa.id from public.approvals sa join public.tasks t on t.id::text=sa.action_ref
    where sa.approval_type='developer_scope' and sa.status='pending' and t.owner_agent_id=(select id from public.agents where slug='developer') order by sa.created_at desc limit 1),
  'approve','Review concrete product scope')$$,'configured founder can approve the persisted Developer scope');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),
  'ready','founder scope approval releases the Developer task');
select ok(exists(select 1 from public.audit_log where action='developer.scope.approve'
  and resource_id=(select id::text from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1)),
  'founder scope decision is audit logged against the task');
select throws_ok($$select public.sutra_claim_github_task('bad-worker')$$,
  '22023',null,'GitHub task dispatch requires a bounded worker identity');
select ok(position('github_permission_denied' in pg_get_constraintdef(
  (select oid from pg_constraint where conname='github_task_dispatches_last_error_check'
    and conrelid='public.github_task_dispatches'::regclass))) > 0,
  'GitHub permission failures are persisted only as an allowlisted error category');
select ok(position('github_permission_denied' in pg_get_functiondef(
  'public.sutra_fail_github_task_dispatch(text,uuid,uuid,text)'::regprocedure)) > 0,
  'dispatch failure RPC accepts the safe GitHub permission category');
select ok(has_function_privilege('service_role','public.sutra_company_github_dispatch_status()','execute'),
  'the company status API can read safe dispatch health through its RPC');
select ok(not has_function_privilege('anon','public.sutra_company_github_dispatch_status()','execute')
  and not has_function_privilege('authenticated','public.sutra_company_github_dispatch_status()','execute'),
  'dispatch health is not exposed to client database roles');
select ok(has_function_privilege('service_role',
  'public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)','execute'),
  'Codex completion with sanitized diagnostics is available to the service runtime');
select ok(not has_function_privilege('anon',
  'public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)','execute')
  and not has_function_privilege('authenticated',
  'public.sutra_codex_finish_run(text,uuid,uuid,boolean,boolean,integer,text)','execute'),
  'Codex usage and diagnostic settlement are not exposed to client roles');
select throws_ok($$select * from public.github_task_dispatches$$,
  '42501',null,'service role cannot read GitHub issue state outside audited RPCs');
select throws_ok($$select * from public.task_agent_artifacts$$,
  '42501',null,'service role cannot bypass task artifact RPCs to read persisted deliverables');
create temporary table github_dispatch_claim(payload jsonb) on commit drop;
insert into github_dispatch_claim select public.sutra_claim_github_task('sutra-github-worker-12345678');
select is((select payload->>'title' from github_dispatch_claim),'Implement approved product tasks',
  'only the founder-approved and sequentially released Developer task is dispatched');
select throws_ok($$select public.sutra_complete_github_task_dispatch('sutra-github-worker-12345678',
  (select (payload->>'task_id')::uuid from github_dispatch_claim),gen_random_uuid(),41,'https://github.com/acme/sutra/issues/42')$$,
  '22023',null,'GitHub issue URL and issue number must match');
select throws_ok($$select public.sutra_complete_github_task_dispatch('sutra-github-worker-12345678',
  (select (payload->>'task_id')::uuid from github_dispatch_claim),gen_random_uuid(),41,'https://github.com/acme/sutra/issues/41')$$,
  '42501',null,'a different lease token cannot complete GitHub task dispatch');
select lives_ok($$select public.sutra_complete_github_task_dispatch('sutra-github-worker-12345678',
  (select (payload->>'task_id')::uuid from github_dispatch_claim),
  (select (payload->>'lease_token')::uuid from github_dispatch_claim),41,'https://github.com/acme/sutra/issues/41')$$,
  'valid GitHub issue is durably linked to its approved task');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),
  'in_progress','issue creation starts the assigned Developer task');
select is((select count(*)::integer from public.audit_log where action='github.issue_created'
  and resource_id=(select (payload->>'task_id')::uuid::text from github_dispatch_claim)),
  1,'GitHub task issue creation is audit logged');
select is((select details->>'issue_url' from public.audit_log where action='github.issue_created'
  and resource_id=(select (payload->>'task_id')::uuid::text from github_dispatch_claim) limit 1),
  'https://github.com/acme/sutra/issues/41','audit log retains the durable GitHub issue link');
select throws_ok($$select public.sutra_authorize_codex_task('bad-worker',
  (select (payload->>'task_id')::uuid from github_dispatch_claim),41,'https://github.com/acme/sutra/issues/41',
  'openai','gpt-4o-mini-test-cheap')$$,
  '22023',null,'Codex authorization rejects malformed worker identities');
select throws_ok($$select public.sutra_authorize_codex_task('sutra-worker-codex12345678',
  (select (payload->>'task_id')::uuid from github_dispatch_claim),42,'https://github.com/acme/sutra/issues/42',
  'openai','gpt-4o-mini-test-cheap')$$,
  '42501',null,'Codex execution is bound to the exact founder-approved GitHub issue');
create temporary table codex_run_claim(payload jsonb) on commit drop;
insert into codex_run_claim
select public.sutra_authorize_codex_task('sutra-worker-codex12345678',
  (c.payload->>'task_id')::uuid,41,'https://github.com/acme/sutra/issues/41',
  'openai','gpt-4o-mini-test-cheap') from github_dispatch_claim c;
select is((select payload->>'status' from codex_run_claim),'authorized',
  'Codex gets a lease only after policy reserves the founder-configured model spend');
create temporary table codex_runner_claim(payload jsonb) on commit drop;
insert into codex_runner_claim
select public.sutra_claim_codex_execution('sutra-worker-codex12345678',
  (c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid) from codex_run_claim c;
select is((select payload->>'claimed' from codex_runner_claim),'true',
  'a valid Codex execution lease can be claimed once');
select is((public.sutra_claim_codex_execution('sutra-worker-codex87654321',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim))->>'claimed'),'false',
  'a restarted or duplicate runner cannot claim the same Codex execution');
select throws_ok($$select public.sutra_codex_start_request('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),'openai/unapproved-model',100,100)$$,
  '42501',null,'Codex cannot switch away from its approved provider model');
select throws_ok($$select public.sutra_codex_start_request('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),'gpt-4o-mini-test-cheap',2201,100)$$,
  '42501',null,'Codex cannot exceed the reserved per-request output token limit');
select throws_ok($$select public.sutra_codex_start_request('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),'gpt-4o-mini-test-cheap',100,80001)$$,
  '42501',null,'Codex cannot exceed the bounded input payload size');
select lives_ok($$select public.sutra_codex_start_request('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),'gpt-4o-mini-test-cheap',2000,4096)$$,
  'Codex request must match the approved model and bounded input/output caps');
select lives_ok($$select public.sutra_codex_record_usage('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),1000,1000)$$,
  'provider usage is recorded against the reserved run');
select lives_ok($$select public.sutra_codex_start_request('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),'gpt-4o-mini-test-cheap',2000,4096)$$,
  'a second bounded Codex request consumes one unit of the policy iteration limit');
select lives_ok($$select public.sutra_codex_record_usage('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),1000,1000)$$,
  'second provider usage is included in aggregate reconciliation');
select lives_ok($$select public.sutra_codex_start_request('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),'gpt-4o-mini-test-cheap',2000,4096)$$,
  'the final configured Codex request is authorized');
select lives_ok($$select public.sutra_codex_record_usage('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),1000,1000)$$,
  'third provider usage is included in aggregate reconciliation');
select throws_ok($$select public.sutra_codex_start_request('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),'gpt-4o-mini-test-cheap',100,100)$$,
  '42501',null,'Codex cannot exceed the database-configured request count');
select throws_ok($$select public.sutra_codex_finish_run('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),false,true,0,null)$$,
  '22023',null,'a successful process cannot be reported without trusted provider usage');
select throws_ok($$select public.sutra_codex_finish_run('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),true,false,999,'codex_process_failed')$$,
  '22023',null,'malformed process exit codes are rejected');
select throws_ok($$select public.sutra_codex_finish_run('sutra-worker-codex12345678',
  (select (payload->>'run_id')::uuid from codex_run_claim),
  (select (payload->>'lease_token')::uuid from codex_run_claim),true,false,1,'raw-provider-error')$$,
  '22023',null,'failure detail must be a known sanitized category');
create temporary table codex_finish(payload jsonb) on commit drop;
insert into codex_finish
select public.sutra_codex_finish_run('sutra-worker-codex12345678',
  (c.payload->>'run_id')::uuid,(c.payload->>'lease_token')::uuid,true,false,1,'provider_rate_limited') from codex_run_claim c;
select is((select payload->>'status' from codex_finish),'reconciled',
  'trusted provider usage reconciles to policy even when the Codex process fails');
select is((select (payload->>'process_succeeded')::boolean from codex_finish),false,
  'Codex process outcome is returned independently from financial settlement');
select is((select payload->>'failure_detail_code' from codex_finish),'provider_rate_limited',
  'only the allowlisted diagnostic category is returned and persisted');
select throws_ok($$select public.sutra_codex_finish_run('sutra-worker-codex12345678',null,null,true)$$,
  '55000',null,'stale runners using the conflated completion call are safely rejected during rollout');
reset role;
select is((select status from public.agent_runs where id=(select (payload->>'run_id')::uuid from codex_run_claim)),
  'failed','a nonzero Codex process is persisted as a failed run');
select is((select output->>'failure_detail_code' from public.agent_runs where id=(select (payload->>'run_id')::uuid from codex_run_claim)),
  'provider_rate_limited','safe diagnosis is persisted without provider response content');
select is((select status from public.codex_task_executions where agent_run_id=(select (payload->>'run_id')::uuid from codex_run_claim)),
  'failed','the execution record distinguishes process failure from reconciled spend');
select is((select status from public.tasks where id=(select (payload->>'task_id')::uuid from github_dispatch_claim)),
  'blocked','a terminal Codex process failure moves its task to blocked');
select is((select status from public.agent_run_spend_reservations where agent_run_id=(select (payload->>'run_id')::uuid from codex_run_claim)),
  'reconciled','trusted spend remains reconciled instead of being released after process failure');
select ok((select count(*) from public.audit_log where action in
  ('codex.responses_request_authorized','codex.responses_usage_recorded'))=6
  and (select count(*) from public.audit_log where action='codex.process_failed')=1
  and (select count(*) from public.audit_log where action='codex.runner_claimed')=1,
  'Codex runner claim, requests, provider usage, and process failure are audit logged');
set local role service_role;
select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select (payload->>'task_id')::uuid from github_dispatch_claim),'ready',
  '{"reason":"test separate founder-approved implementation handoff"}'::jsonb);
select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select (payload->>'task_id')::uuid from github_dispatch_claim),'in_progress',
  '{"reason":"test implementation resumes under existing approved scope"}'::jsonb);
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select (payload->>'task_id')::uuid from github_dispatch_claim),'done','{"pull_request":"draft","ci":"passed"}'::jsonb)$$,
  '42501',null,'generic task updates cannot bypass the merged PR and matching CI completion gate');
select is(public.sutra_claim_github_task('sutra-github-worker-abcdefgh')::text,null::text,
  'the same task is not dispatched twice');
select throws_ok($$select public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',
  '00000000-0000-4000-8000-000000000097','evil/sutra','pull_request',jsonb_build_object(
    'kind','pull_request','action','closed','task_id',(select payload->>'task_id' from github_dispatch_claim),
    'issue_number',41,'pull_request_number',88,'pull_request_url','https://github.com/evil/sutra/pull/88',
    'head_sha',repeat('a',40),'merged',true,'base_ref','main'))$$,
  '22023',null,'signed repository must match the issue repository');
select is((public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',
  '00000000-0000-4000-8000-000000000096','acme/sutra','pull_request',jsonb_build_object(
    'kind','pull_request','action','closed','task_id',(select payload->>'task_id' from github_dispatch_claim),
    'issue_number',41,'pull_request_number',88,'pull_request_url','https://github.com/acme/sutra/pull/88',
    'head_sha',repeat('a',40),'merged',true,'base_ref','main'))->>'completed_tasks'),'0',
  'a merged pull request alone does not complete the Developer task');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),
  'in_progress','Developer work remains active while CI evidence is missing');
select is((public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',
  '00000000-0000-4000-8000-000000000095','acme/sutra','workflow_run',jsonb_build_object(
    'kind','workflow_run','workflow_name','CI','conclusion','failure','run_url','https://github.com/acme/sutra/actions/runs/200',
    'run_id',200,'head_sha',repeat('a',40),'pull_requests',jsonb_build_array(jsonb_build_object('number',88,'head_sha',repeat('a',40)))))->>'completed_tasks'),'0',
  'failed CI evidence never completes the Developer task');
select throws_ok($$select public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',
  '00000000-0000-4000-8000-000000000093','acme/sutra','workflow_run',jsonb_build_object(
    'kind','workflow_run','workflow_name','CI','conclusion','success','run_url','https://github.com/acme/sutra/actions/runs/202',
    'run_id',201,'head_sha',repeat('a',40),'pull_requests',jsonb_build_array(jsonb_build_object('number',88,'head_sha',repeat('a',40)))))$$,
  '22023',null,'workflow run URL must match its numeric run ID');
select throws_ok($$select public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',
  '00000000-0000-4000-8000-000000000092','acme/sutra','workflow_run',jsonb_build_object(
    'kind','workflow_run','workflow_name','CI','conclusion','success','run_url','https://github.com/acme/sutra/actions/runs/202',
    'run_id',202,'head_sha',repeat('a',40),'pull_requests',jsonb_build_array(jsonb_build_object('number',88,'head_sha',repeat('b',40)))))$$,
  '22023',null,'workflow run must match the immutable SHA of its associated pull request');
select is((public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',
  '00000000-0000-4000-8000-000000000095','acme/sutra','workflow_run',jsonb_build_object(
    'kind','workflow_run','workflow_name','CI','conclusion','success','run_url','https://github.com/acme/sutra/actions/runs/200',
    'run_id',200,'head_sha',repeat('a',40),'pull_requests',jsonb_build_array(jsonb_build_object('number',88,'head_sha',repeat('a',40)))))->>'duplicate'),'true',
  'GitHub webhook delivery IDs are idempotent');
select is((public.sutra_record_github_webhook_event('sutra-github-webhook-12345678',
  '00000000-0000-4000-8000-000000000094','acme/sutra','workflow_run',jsonb_build_object(
    'kind','workflow_run','workflow_name','CI','conclusion','success','run_url','https://github.com/acme/sutra/actions/runs/201',
    'run_id',201,'head_sha',repeat('a',40),'pull_requests',jsonb_build_array(jsonb_build_object('number',88,'head_sha',repeat('a',40)))))->>'completed_tasks'),'1',
  'merged PR plus successful CI completes Developer task through the database gate');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),
  'done','verified PR and CI complete the Developer task');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  'ready','verified Developer work releases the QA task');

select throws_ok($$select * from public.task_review_evidence$$,'42501',null,
  'service role cannot bypass the review RPC to read immutable review evidence');
create temporary table claimed_task_review(payload jsonb) on commit drop;
insert into claimed_task_review select public.sutra_claim_task_review_agent_run('sutra-worker-qa12345678');
select is((select payload->'agent'->>'slug' from claimed_task_review),'qa',
  'leased review worker claims only the released QA task');
select is((select payload->'task_review'->>'tested_commit_sha' from claimed_task_review),repeat('a',40),
  'worker context includes the exact merged and tested Developer commit');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='qa'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  'done','{"summary":"looks good"}'::jsonb)$$,'42501',null,
  'generic task completion cannot bypass persisted QA evidence');
select throws_ok($$select public.sutra_submit_task_review(
  (select id from public.agents where slug='qa'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  jsonb_build_object('result','pass','summary','QA evidence checked','tested_commit_sha',repeat('b',40),
    'acceptance_criteria','[]'::jsonb,'tests','[]'::jsonb))$$,'42501',null,
  'QA review cannot claim a commit other than the merged Developer commit');
select throws_ok($$select public.sutra_submit_task_review(
  (select id from public.agents where slug='security'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  jsonb_build_object('result','pass','summary','review submitted for wrong role','tested_commit_sha',repeat('a',40),
    'acceptance_criteria','[]'::jsonb))$$,'42501',null,'Security cannot submit evidence for QA work assigned to another role');
select lives_ok($$select public.sutra_submit_task_review(
  (select id from public.agents where slug='qa'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  jsonb_build_object('result','pass','summary','QA test suite and acceptance evidence passed','tested_commit_sha',repeat('a',40),
    'acceptance_criteria',jsonb_build_array(
      jsonb_build_object('criterion','Acceptance criteria have evidence','result','pass','evidence_url','https://github.com/acme/sutra/pull/88'),
      jsonb_build_object('criterion','Failures are recorded','result','pass','evidence_url','https://github.com/acme/sutra/actions/runs/201')),
    'tests',jsonb_build_array(jsonb_build_object('name','release test suite','result','pass','evidence_url','https://github.com/acme/sutra/actions/runs/201'))))$$,
  'valid QA review persists verified commit and test evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  'done','passing persisted QA evidence completes QA task');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='security') order by created_at desc limit 1),
  'ready','QA completion releases Security review');
reset role;
select is((select count(*)::integer from public.task_review_evidence where review_role='qa' and tested_commit_sha=repeat('a',40)),
  1,'QA evidence is durably stored with its exact Developer commit');
select is((select count(*)::integer from public.audit_log where action='task.review_submitted' and actor_id='qa'),
  1,'QA review submission is audit logged');
set local role service_role;
truncate claimed_task_review;
insert into claimed_task_review select public.sutra_claim_task_review_agent_run('sutra-worker-security123');
select is((select payload->'agent'->>'slug' from claimed_task_review),'security',
  'passing QA evidence releases a leased Security review task');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='security'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='security') order by created_at desc limit 1),
  'done','{"summary":"no findings"}'::jsonb)$$,'42501',null,
  'generic task completion cannot bypass persisted Security evidence');
select lives_ok($$select public.sutra_submit_task_review(
  (select id from public.agents where slug='security'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='security') order by created_at desc limit 1),
  jsonb_build_object('result','pass','summary','Security checks passed with no open findings','tested_commit_sha',repeat('a',40),
    'acceptance_criteria',jsonb_build_array(
      jsonb_build_object('criterion','Security findings have severity and owner','result','pass','evidence_url','https://github.com/acme/sutra/pull/88'),
      jsonb_build_object('criterion','Release blockers are explicit','result','pass','evidence_url','https://github.com/acme/sutra/actions/runs/201')),
    'findings','[]'::jsonb,'release_blockers','[]'::jsonb,
    'checks',jsonb_build_array(jsonb_build_object('name','dependency and secret checks','result','pass','evidence_url','https://github.com/acme/sutra/actions/runs/201'))))$$,
  'valid Security review persists checks, findings, blockers, and exact commit');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='security') order by created_at desc limit 1),
  'done','passing persisted Security evidence completes Security task');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='devops') order by created_at desc limit 1),
  'ready','Security completion releases DevOps handoff');
select is((pg_temp.run_task_artifact('devops',jsonb_build_object(
  'deployment_steps',jsonb_build_array('Deploy the reviewed release candidate'),
  'health_checks',jsonb_build_array('Confirm service health and worker recovery'),
  'rollback_steps',jsonb_build_array('Restore the last known healthy Railway image')))->>'status'),
  'succeeded','DevOps persists a spend-gated release and rollback plan');
select is((pg_temp.run_task_artifact('cmo',jsonb_build_object(
  'audience','Engineering leaders evaluating software quality workflows.',
  'positioning','Reduce repeated manual verification through a controlled workflow.',
  'draft_copy','Internal campaign draft for founder review only.',
  'claims',jsonb_build_array('Supports founder-approved workflow research'),
  'success_metrics',jsonb_build_array('Qualified interest from target teams')))->>'status'),
  'succeeded','CMO persists a cited internal campaign draft without sending or publishing');
select is((pg_temp.run_task_artifact('sales',jsonb_build_object(
  'ideal_customer_profile','Software teams with repeatable release and quality processes.',
  'lead_criteria',jsonb_build_array('Relevant software team'),
  'qualification_questions',jsonb_build_array('How do you verify release readiness?'),
  'first_contact_draft','Internal first-contact draft; do not send without separate founder approval.'))->>'status'),
  'succeeded','Sales persists an internal handoff without inventing or contacting leads');
reset role;
select is((select count(*)::integer from public.task_agent_artifacts),5,
  'PM, Architect, DevOps, Marketing and Sales artifacts persist for the exercised workflow');
set local role anon;
select throws_ok($$select * from public.task_agent_artifacts$$,
  '42501',null,'anon cannot read task artifacts');
select throws_ok($$select public.sutra_claim_task_agent_run('sutra-worker-12345678')$$,
  '42501',null,'anon cannot invoke task artifact worker RPCs');
select throws_ok($$select public.sutra_submit_task_agent_artifact('sutra-worker-12345678',gen_random_uuid(),gen_random_uuid(),'{}'::jsonb)$$,
  '42501',null,'anon cannot submit task artifact RPCs');
reset role;
set local role service_role;
select is((select count(*)::integer from public.audit_log where action='task.review_submitted' and actor_id='security'),
  1,'Security review submission is audit logged');

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
select is((select count(*)::integer from public.audit_log where action='agent_run.spend_reconciled'),13,
  'each Hermes and Codex model usage reconciliation is audit logged');
select is((select count(*)::integer from public.audit_log where action='agent_run.spend_reserved'),14,
  'each Hermes and Codex model spend reservation decision is audit logged');
select is((select count(*)::integer from public.audit_log where action='task.artifact_submitted'),5,
  'every persisted internal role artifact is audit logged');
select is((select count(*)::integer from public.audit_log where action='agent_run.spend_approval_resumed'),1,
  'approval-driven model run resumption is audit logged');
select is((select count(*)::integer from public.expenses where actual_amount=0.01),13,
  'actual Hermes and Codex model usage is reconciled into its authoritative expense');

-- Exercise every configurable budget scope and every supported period. Use
-- unique category/vendor keys so earlier workflow fixtures cannot affect the
-- usage totals, and set zero caps to prove a single positive spend is blocked.
select lives_ok($$select public.sutra_set_budget('12345678','company','*','daily',0,80,true)$$,
  'founder can configure a daily company hard stop');
select throws_ok($$select public.sutra_authorize_spend('system','policy-test',null,null,null,'policy-test-company-daily',null,'daily company cap',0.01,'EUR')$$,
  '23514',null,'daily company budget exhaustion blocks spend');
select lives_ok($$select public.sutra_set_budget('12345678','company','*','daily',999999999999.99,80,true)$$,
  'daily company fixture is isolated from subsequent spend checks');
select lives_ok($$select public.sutra_set_budget('12345678','department',
  (select department_id::text from public.agents where slug='developer'),'daily',0,80,true)$$,
  'founder can configure a daily department hard stop');
select throws_ok($$select public.sutra_authorize_spend('system','policy-test',null,null,
  (select department_id from public.agents where slug='developer'),'policy-test-department-daily',null,'daily department cap',0.01,'EUR')$$,
  '23514',null,'daily department budget exhaustion blocks spend');
select lives_ok($$select public.sutra_set_budget('12345678','department',
  (select department_id::text from public.agents where slug='developer'),'daily',999999999999.99,80,true)$$,
  'department fixture is isolated from subsequent spend checks');
select lives_ok($$select public.sutra_set_budget('12345678','agent','developer','monthly',0,80,true)$$,
  'founder can configure a monthly agent hard stop');
select throws_ok($$select public.sutra_authorize_spend('agent','developer',
  (select id from public.agents where slug='developer'),null,null,'policy-test-agent-monthly',null,'monthly agent cap',0.01,'EUR')$$,
  '23514',null,'monthly agent budget exhaustion blocks its spend');
select lives_ok($$select public.sutra_set_budget('12345678','agent','developer','monthly',999999999999.99,80,true)$$,
  'agent fixture is isolated from subsequent spend checks');
select lives_ok($$select public.sutra_set_budget('12345678','category','policy-test-category','monthly',0,80,true)$$,
  'founder can configure a monthly category hard stop');
select throws_ok($$select public.sutra_authorize_spend('system','policy-test',null,null,null,'policy-test-category',null,'monthly category cap',0.01,'EUR')$$,
  '23514',null,'monthly category budget exhaustion blocks spend');
select lives_ok($$select public.sutra_set_budget('12345678','category','policy-test-category','monthly',999999999999.99,80,true)$$,
  'category fixture is isolated from subsequent spend checks');
select lives_ok($$select public.sutra_set_budget('12345678','vendor','policy-test-vendor','monthly',0,80,true)$$,
  'founder can configure a monthly vendor hard stop');
select throws_ok($$select public.sutra_authorize_spend('system','policy-test',null,null,null,'policy-test-vendor-category','policy-test-vendor','monthly vendor cap',0.01,'EUR')$$,
  '23514',null,'monthly vendor budget exhaustion blocks spend');
select lives_ok($$select public.sutra_set_budget('12345678','vendor','policy-test-vendor','monthly',999999999999.99,80,true)$$,
  'vendor fixture is isolated from subsequent spend checks');
select lives_ok($$select public.sutra_set_budget('12345678','project',
  (select id::text from public.projects where status='approved' order by created_at desc limit 1),'lifetime',0,80,true)$$,
  'founder can configure a lifetime project hard stop');
select throws_ok($$select public.sutra_authorize_spend('system','policy-test',null,
  (select id from public.projects where status='approved' order by created_at desc limit 1),null,
  'policy-test-project-lifetime',null,'lifetime project cap',0.01,'EUR')$$,
  '23514',null,'lifetime project budget exhaustion blocks spend');
select lives_ok($$select public.sutra_set_budget('12345678','project',
  (select id::text from public.projects where status='approved' order by created_at desc limit 1),'lifetime',999999999999.99,80,true)$$,
  'project fixture is isolated from subsequent spend checks');

select lives_ok($$select public.sutra_set_budget('12345678','category','policy-test-daily-use','daily',0.05,80,true)$$,
  'founder can configure a positive daily category budget');
select is((public.sutra_authorize_spend('system','policy-test',null,null,null,'policy-test-daily-use',null,'first daily use',0.03,'EUR')->>'status'),
  'approved','spend below a fresh daily cap succeeds');
select throws_ok($$select public.sutra_authorize_spend('system','policy-test',null,null,null,'policy-test-daily-use',null,'exhausted daily use',0.03,'EUR')$$,
  '23514',null,'daily usage accumulates and blocks an over-budget transaction');
select lives_ok($$select public.sutra_set_budget('12345678','category','policy-test-daily-use','daily',999999999999.99,80,true)$$,
  'daily use fixture is isolated from subsequent spend checks');
select lives_ok($$select public.sutra_set_budget('12345678','vendor','policy-test-monthly-use','monthly',0.05,80,true)$$,
  'founder can configure a positive monthly vendor budget');
select is((public.sutra_authorize_spend('system','policy-test',null,null,null,'policy-test-monthly-vendor','policy-test-monthly-use','first monthly use',0.03,'EUR')->>'status'),
  'approved','spend below a fresh monthly vendor cap succeeds');
select throws_ok($$select public.sutra_authorize_spend('system','policy-test',null,null,null,'policy-test-monthly-vendor','policy-test-monthly-use','exhausted monthly use',0.03,'EUR')$$,
  '23514',null,'monthly vendor usage accumulates and blocks an over-budget transaction');
select lives_ok($$select public.sutra_set_budget('12345678','vendor','policy-test-monthly-use','monthly',999999999999.99,80,true)$$,
  'monthly use fixture is isolated from subsequent spend checks');

create temporary table budget_warning_test(payload jsonb) on commit drop;
select lives_ok($$select public.sutra_set_budget('12345678','category','policy-test-warning','transaction',0.05,80,false)$$,
  'founder can configure a nonblocking warning threshold');
insert into budget_warning_test select public.sutra_authorize_spend(
  'system','policy-test',null,null,null,'policy-test-warning',null,'warning threshold',0.06,'EUR');
select is((select payload->>'status' from budget_warning_test),'approved',
  'soft budget threshold allows the transaction');
select ok((select payload->'budget_warnings' @> '["category:policy-test-warning"]'::jsonb from budget_warning_test),
  'budget usage at or above its configurable warning threshold is returned');
select lives_ok($$select public.sutra_set_budget('12345678','agent','developer','monthly',3,80,true)$$,
  'founder can configure an agent budget through the audited policy function');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='governance.budget_changed' and details->>'scope'='agent'
  and details->>'scope_key'='developer' and details->>'limit_amount'='3'),
  'founder-authorized budget changes create an audit record with the configured limit');

reset role;
update public.github_task_dispatches set pull_request_number=160,
  pull_request_url='https://github.com/acme/sutra/pull/160',
  pull_request_head_sha=repeat('a',40),pull_request_merged=false,ci_conclusion=null,
  ci_run_url=null,ci_head_sha=null
where task_id=(select (payload->>'task_id')::uuid from github_dispatch_claim);
set local role service_role;
select is((select item->>'pull_request_number'
  from jsonb_array_elements(public.sutra_company_github_dispatch_status()->'dispatches') item
  where item->>'task_id'=(select (payload->>'task_id') from github_dispatch_claim)),
  '160','company status includes a linked PR while CI evidence is still pending');
select is((select item->>'pull_request_url'
  from jsonb_array_elements(public.sutra_company_github_dispatch_status()->'dispatches') item
  where item->>'task_id'=(select (payload->>'task_id') from github_dispatch_claim)),
  'https://github.com/acme/sutra/pull/160','company status includes the linked PR URL');

select * from finish();
rollback;

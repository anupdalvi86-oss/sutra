begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

set local role service_role;
select lives_ok($$select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-4o-mini',0,1.5,10000,2200,true)$$,
  'founder configures a low-cost review fixture route');
select lives_ok($$select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-4o-mini-test-cheap',0,1.5,10000,2200,true)$$,
  'founder configures a low-cost downstream fixture route');
create temporary table worker_claims(role text,run_id uuid,lease_token uuid,sequence_no integer) on commit drop;
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
  reconciliation := public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',p_run_id,p_lease_token,reservation_id,
    'openai',model_name,1,1,'{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}'::jsonb,true);
  return reservation || jsonb_build_object('reconciliation',reconciliation);
end;
$$;
-- A founder may recover an early failed review within the original three-attempt
-- ceiling. The generic recovery path must preserve unknown reservations and audit.
create temporary table retryable_proposal(payload jsonb) on commit drop;
insert into retryable_proposal
select public.sutra_submit_proposal('12345678','Bounded CPO retry fixture',
  'Test a founder-only CPO retry without authorizing project spend.',5,'EUR');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,
  (c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'ceo','retry fixture begins at the CEO review');
select lives_ok($$select pg_temp.prepare_agent_run_spend((select run_id from worker_claims),
  (select lease_token from worker_claims))$$,'fixture CEO run records reconciled spend');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'succeeded',
  '{"summary":"A bounded proposal fits the company direction.","recommendation":"Research customer needs.","evidence":[]}'::jsonb)$$,
  'fixture CEO review succeeds');
truncate worker_claims;
with c as (select public.sutra_claim_agent_run('sutra-worker-12345678') as payload)
insert into worker_claims select c.payload->'agent'->>'slug',(c.payload->>'run_id')::uuid,
  (c.payload->>'lease_token')::uuid,(c.payload->>'sequence')::integer from c;
select is((select role from worker_claims),'cpo','CPO review follows the fixture CEO');
create temporary table cpo_unknown_reservation(payload jsonb) on commit drop;
insert into cpo_unknown_reservation
select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'openai','gpt-4o-mini-test-cheap');
select lives_ok($$select public.sutra_begin_agent_run_spend('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),
  (select (payload->>'reservation_id')::uuid from cpo_unknown_reservation))$$,
  'CPO retry fixture starts its database reservation');
select is((public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),
  (select (payload->>'reservation_id')::uuid from cpo_unknown_reservation),
  'openai','gpt-4o-mini-test-cheap',null,null,'{"source":"simulated_unknown_usage"}'::jsonb,false)->>'status'),
  'unknown','CPO fixture retains unknown usage');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select run_id from worker_claims),(select lease_token from worker_claims),'failed',
  '{"summary":"CPO usage could not be verified"}'::jsonb,'unknown_or_overrun_spend')$$,
  'CPO run fails closed with a recoverable error code');
select throws_ok($$select public.sutra_founder_retry_agent_review('99999999',
  (select run_id from worker_claims))$$,'42501',null,'nonfounder cannot retry a review stage');
create temporary table agent_retry_result(payload jsonb) on commit drop;
insert into agent_retry_result select public.sutra_founder_retry_agent_review('12345678',
  (select run_id from worker_claims));
select is((select payload->>'review_role' from agent_retry_result),'cpo',
  'founder can retry the failed CPO stage');
select is((select (payload->>'attempts_remaining')::integer from agent_retry_result),2,
  'retry leaves the global three-attempt limit intact');
select is((select (payload->>'preserved_unknown_reservations')::integer from agent_retry_result),1,
  'retry preserves unknown usage reservations');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.agent_review_retry_requested'
  and resource_id=(select run_id::text from worker_claims)),
  'early-stage retries are founder-audited');

select * from finish();
rollback;

begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;
set local role service_role;

select lives_ok($$select public.sutra_set_agent_model_spend_profile(
  '12345678','kimi-coding','kimi-k2.6',0.1,0.3,1000,64,true)$$,
  'founder configures a small Kimi test profile');
select throws_ok($$select public.sutra_founder_queue_kimi_usage_probe('99999999')$$,
  '42501',null,'nonfounder cannot queue a Kimi usage probe');

create temporary table probe_claim(payload jsonb) on commit drop;
create temporary table first_probe(payload jsonb) on commit drop;
insert into first_probe select public.sutra_founder_queue_kimi_usage_probe('12345678');
select is((select payload->>'maximum_reservation_eur' from first_probe),'0.10',
  'probe has a fixed EUR 0.10 reservation ceiling');
select is((select p.status from public.provider_usage_probes p
  where p.id=(select (payload->>'probe_id')::uuid from first_probe)),'queued',
  'founder request is durably queued');
select is((select b.limit_amount from public.budgets b
  where b.scope='project' and b.scope_key=(select payload->>'project_id' from first_probe)),0.10::numeric,
  'probe project has its own matching hard-stop budget');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.kimi_usage_probe_requested'
  and resource_id=(select payload->>'probe_id' from first_probe)),
  'probe request is founder-audited');

insert into probe_claim
select public.sutra_claim_agent_run('sutra-worker-12345678');
select is((select payload->'input'->>'provider_usage_probe' from probe_claim),'kimi',
  'claimed run is explicitly tagged for the one-shot probe');
select is((select payload->>'attempt' from probe_claim),'1',
  'probe receives its single permitted claim attempt');

create temporary table probe_reservation(payload jsonb) on commit drop;
insert into probe_reservation
select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),'kimi-coding','kimi-k2.6');
select is((select payload->>'status' from probe_reservation),'approved',
  'probe uses the normal central spend authorization');
select lives_ok($$select public.sutra_begin_agent_run_spend('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),
  (select (payload->>'reservation_id')::uuid from probe_reservation))$$,
  'probe reservation must start before the model request');
select is((public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),
  (select (payload->>'reservation_id')::uuid from probe_reservation),
  'kimi-coding','kimi-k2.6',10,5,
  '{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}'::jsonb,true)->>'status'),
  'reconciled','known Kimi usage reconciles through the standard spend RPC');
select lives_ok($$select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),'succeeded',
  '{"summary":"Kimi usage reconciled within the probe reservation.","recommendation":"Keep ordinary Kimi role routes disabled.","evidence":[],"usage_state":"reconciled","usage_envelope_shape":"usage_object:prompt_tokens=int,completion_tokens=int,total_tokens=int","response_context_shape":"keys=choices,usage,finish=stop"}'::jsonb)$$,
  'successful probe stores only bounded response-shape labels');
select is((select status from public.provider_usage_probes
  where id=(select (payload->>'probe_id')::uuid from first_probe)),'succeeded',
  'probe status follows the reconciled agent run');

create temporary table ordinary_proposal(payload jsonb) on commit drop;
insert into ordinary_proposal select public.sutra_submit_proposal('12345678',
  'Ordinary Kimi route guard fixture','Test that ordinary work cannot use Kimi.',1,'EUR');
create temporary table ordinary_claim(payload jsonb) on commit drop;
insert into ordinary_claim select public.sutra_claim_agent_run('sutra-worker-12345678');
select throws_ok($$select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from ordinary_claim),
  (select (payload->>'lease_token')::uuid from ordinary_claim),'kimi-coding','kimi-k2.6')$$,
  '42501',null,'ordinary agent work cannot reserve Kimi');
select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from ordinary_claim),
  (select (payload->>'lease_token')::uuid from ordinary_claim),'failed',
  '{"summary":"Kimi route guard fixture stopped before spend."}'::jsonb,'test_guard');

create temporary table unknown_probe(payload jsonb) on commit drop;
insert into unknown_probe select public.sutra_founder_queue_kimi_usage_probe('12345678');
truncate probe_claim;
insert into probe_claim select public.sutra_claim_agent_run('sutra-worker-12345678');
truncate probe_reservation;
insert into probe_reservation
select public.sutra_reserve_agent_run_spend_from_profile('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),'kimi-coding','kimi-k2.6');
select public.sutra_begin_agent_run_spend('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),
  (select (payload->>'reservation_id')::uuid from probe_reservation));
select is((public.sutra_reconcile_agent_run_spend_from_usage('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),
  (select (payload->>'reservation_id')::uuid from probe_reservation),
  'kimi-coding','kimi-k2.6',null,null,'{}'::jsonb,false)->>'status'),
  'unknown','missing usage keeps the full Kimi reservation unknown');
select public.sutra_complete_agent_run('sutra-worker-12345678',
  (select (payload->>'run_id')::uuid from probe_claim),
  (select (payload->>'lease_token')::uuid from probe_claim),'failed',
  '{"summary":"Kimi usage was not verifiable.","usage_state":"unverified","usage_envelope_shape":"usage_missing"}'::jsonb,
  'unknown_or_overrun_spend');
select is((select status from public.provider_usage_probes
  where id=(select (payload->>'probe_id')::uuid from unknown_probe)),'failed',
  'unknown usage is terminal and does not auto-retry');
select is((select payload->>'status' from probe_reservation),'approved',
  'unknown usage retains the originally approved probe reservation');
select throws_ok($$update public.agent_runs set status='queued'
  where id=(select (payload->>'run_id')::uuid from probe_claim)$$,
  '42501',null,'one-shot probe cannot be requeued');
select ok(exists(select 1 from public.audit_log where action='agent_run.spend_unknown'
  and details->>'run_id'=(select payload->>'run_id' from probe_claim)),
  'unknown probe reservation is audit logged');

select * from finish();
rollback;

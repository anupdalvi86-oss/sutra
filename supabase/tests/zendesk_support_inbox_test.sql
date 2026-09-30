begin;
select no_plan();

select ok(has_function_privilege('service_role',
  'public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamp with time zone)','EXECUTE'),
  'service role can invoke the private Zendesk ingestion RPC');
select ok(not has_function_privilege('anon',
  'public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamp with time zone)','EXECUTE'),
  'anonymous clients cannot invoke the Zendesk ingestion RPC');
select ok(not has_table_privilege('service_role','public.support_cases','SELECT'),
  'support metadata is not directly readable even by service role');

select is((public.sutra_ingest_zendesk_ticket_event('987654321','open','normal',
  '2026-09-30T09:00:00Z'::timestamptz)->>'changed')::boolean,true,
  'first ticket event creates a support case');
select is((public.sutra_ingest_zendesk_ticket_event('987654321','open','normal',
  '2026-09-30T09:00:00Z'::timestamptz)->>'changed')::boolean,false,
  'replayed provider event is an idempotent no-op');
select is((public.sutra_ingest_zendesk_ticket_event('987654321','solved','high',
  '2026-09-30T08:59:00Z'::timestamptz)->>'changed')::boolean,false,
  'stale provider event cannot overwrite newer case state');
select is((public.sutra_ingest_zendesk_ticket_event('987654321','pending','urgent',
  '2026-09-30T09:01:00Z'::timestamptz)->>'changed')::boolean,true,
  'newer provider event updates current case state');
select is((select count(*)::integer from public.audit_log where resource_type='support_case'
  and action='support.ticket_state_ingested'),2,
  'only material case creation and update are audited');
select is((select status from public.support_cases where provider='zendesk'
  and external_ticket_id='987654321'),'pending','newest provider state is retained');

select throws_ok($$select public.sutra_ingest_zendesk_ticket_event('0','open','normal',now())$$,
  '22023',null,'invalid ticket identifiers are rejected');
select throws_ok($$select public.sutra_ingest_zendesk_ticket_event('987654322','new','critical',now())$$,
  '22023',null,'unsupported ticket priorities are rejected');
select ok(not exists(select 1 from information_schema.columns where table_schema='public'
  and table_name='support_cases' and column_name in ('body','description','requester_email','raw_payload')),
  'support inbox does not retain free-form message content or requester addresses');

select * from finish();
rollback;

begin;
select plan(7);

select ok(has_function_privilege('service_role',
  'public.sutra_company_support_case_status()','EXECUTE'),
  'service role can read aggregate support status');
select ok(not has_function_privilege('anon',
  'public.sutra_company_support_case_status()','EXECUTE'),
  'anonymous clients cannot read support status');
select ok(not has_function_privilege('authenticated',
  'public.sutra_company_support_case_status()','EXECUTE'),
  'authenticated users cannot read support status');
select ok(not has_table_privilege('service_role','public.support_cases','SELECT'),
  'service role still cannot read individual support cases');

select is(public.sutra_company_support_case_status(),
  '{"total":0,"open":0,"by_status":{},"open_by_priority":{}}'::jsonb,
  'empty support queue returns explicit zero aggregates');

insert into public.support_cases(provider,external_ticket_id,status,priority,provider_updated_at)
values
  ('zendesk','991000001','open','urgent','2026-09-30T10:00:00Z'),
  ('zendesk','991000002','open','urgent','2026-09-30T10:01:00Z'),
  ('zendesk','991000003','pending','normal','2026-09-30T10:02:00Z'),
  ('zendesk','991000004','solved','low','2026-09-30T10:03:00Z');

select is(public.sutra_company_support_case_status(),
  '{"total":4,"open":3,"by_status":{"open":2,"pending":1,"solved":1},"open_by_priority":{"urgent":2,"normal":1}}'::jsonb,
  'aggregate status counts unresolved cases and priorities without ticket identifiers');
select ok(not (public.sutra_company_support_case_status() ? 'tickets')
  and not (public.sutra_company_support_case_status() ? 'external_ticket_id'),
  'aggregate response exposes no ticket identifiers or ticket content');

select * from finish();
rollback;

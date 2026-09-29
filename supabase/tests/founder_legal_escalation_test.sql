begin;
select plan(27);

select ok((select relrowsecurity from pg_class where oid='public.legal_escalations'::regclass),
  'legal cases have RLS enabled');
select ok(not has_table_privilege('anon','public.legal_escalations','SELECT'),
  'anonymous clients cannot read legal cases');
select ok(not has_table_privilege('authenticated','public.legal_escalations','SELECT'),
  'authenticated clients cannot read legal cases');
select ok(not has_table_privilege('service_role','public.legal_escalations','SELECT'),
  'the service API cannot bypass the founder-only case listing function');
select ok(not has_table_privilege('service_role','public.legal_escalations','INSERT'),
  'the service API cannot forge legal cases');
select ok(not has_table_privilege('service_role','public.legal_escalations','UPDATE'),
  'the service API cannot rewrite legal case dispositions directly');
select ok(not has_function_privilege('anon',
  'public.sutra_founder_list_legal_escalations(text)','EXECUTE'),
  'anonymous clients cannot list legal cases');
select ok(has_function_privilege('service_role',
  'public.sutra_founder_list_legal_escalations(text)','EXECUTE'),
  'the private Telegram API can call the founder-checked case listing function');
select ok(not has_function_privilege('anon',
  'public.sutra_founder_record_legal_disposition(text,uuid,text,text)','EXECUTE'),
  'anonymous clients cannot record legal dispositions');
select ok(has_function_privilege('service_role',
  'public.sutra_founder_record_legal_disposition(text,uuid,text,text)','EXECUTE'),
  'the private Telegram API can call the founder-checked disposition function');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value;
create temporary table legal_fixture on commit drop as
  select (public.sutra_submit_proposal('12345678','Legal escalation fixture',
    'Test durable founder legal escalation and ensure the initiative remains paused',100,'EUR')->>'project_id')::uuid as project_id;
update public.projects set status='paused',budget_assessed_at=now(),budget_assessment_status='legal_escalation',
  budget_assessment='{"estimated_total_eur":75,"confidence":"high","recommended_action":"legal_escalation","line_items":[{"category":"other","amount_eur":75,"basis":"Legal review fixture without a binding purchase."}]}'::jsonb
  where id=(select project_id from legal_fixture);

select is((select count(*)::integer from public.legal_escalations where project_id=(select project_id from legal_fixture)),1,
  'the CFO legal escalation creates one durable founder case');
select is(jsonb_array_length(public.sutra_founder_list_legal_escalations('12345678')->'escalations'),1,
  'the configured founder sees the pending legal case through the bounded RPC');
select throws_ok($$select public.sutra_founder_list_legal_escalations('99999999')$$,
  '42501',null,'a nonfounder cannot list legal cases');
select throws_ok($$select public.sutra_founder_list_legal_escalations(null)$$,
  '42501',null,'a missing founder identity is rejected');
select throws_ok($$select public.sutra_founder_record_legal_disposition('99999999',
  (select id from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  'stop_initiative','The founder should stop this proposed work.')$$,
  '42501',null,'a nonfounder cannot record a disposition');
select throws_ok($$select public.sutra_founder_record_legal_disposition('12345678',
  (select id from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  'sign_contract','The commitment is acceptable.')$$,
  '22023',null,'the disposition allowlist rejects implied authority to sign a contract');
select throws_ok($$select public.sutra_founder_record_legal_disposition('12345678',
  (select id from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  null,'The founder should stop this proposed work.')$$,
  '22023',null,'a missing disposition is rejected');
select throws_ok($$select public.sutra_founder_record_legal_disposition('12345678',
  (select id from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  'stop_initiative','short')$$,
  '22023',null,'a short disposition reason is rejected');
select is((public.sutra_founder_record_legal_disposition('12345678',
  (select id from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  'seek_legal_counsel','Founder will obtain qualified counsel review before taking action.')->>'status'),
  'reviewed','the founder can record a bounded counsel disposition');
select is((select disposition from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  'seek_legal_counsel','the founder disposition persists on the case');
select is((select status from public.projects where id=(select project_id from legal_fixture)),
  'paused','recording a disposition never resumes work automatically');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='legal.disposition_recorded' and resource_type='legal_escalation'),
  'founder legal dispositions are audit logged');
select ok(exists(select 1 from public.audit_log where actor_type='system'
  and action='legal.escalation_opened' and resource_type='legal_escalation'),
  'the system audit logs case creation');
select throws_ok($$select public.sutra_founder_record_legal_disposition('12345678',
  (select id from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  'stop_initiative','This duplicate disposition must fail safely.')$$,
  'P0002',null,'a reviewed case cannot be changed or disposed a second time');
select is(jsonb_array_length(public.sutra_founder_list_legal_escalations('12345678')->'escalations'),0,
  'reviewed cases leave the open founder queue');
select is((select founder_reason from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  'Founder will obtain qualified counsel review before taking action.','the founder reason is durably recorded');
select is((select recorded_by from public.legal_escalations where project_id=(select project_id from legal_fixture)),
  '12345678','the case records which configured founder entered the disposition');

select * from finish();
rollback;

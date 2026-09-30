begin;
select no_plan();

select ok(not has_function_privilege('anon',
  'public.sutra_founder_set_customer_email_cost_ceiling(text,numeric,text)','EXECUTE'),
  'anonymous clients cannot change the customer email cost ceiling');
select ok(not has_function_privilege('authenticated',
  'public.sutra_founder_set_customer_email_cost_ceiling(text,numeric,text)','EXECUTE'),
  'authenticated clients cannot change the customer email cost ceiling');
select ok(has_function_privilege('service_role',
  'public.sutra_founder_set_customer_email_cost_ceiling(text,numeric,text)','EXECUTE'),
  'service role can call the founder-checked ceiling RPC');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true;
select is((public.sutra_founder_get_customer_email_cost_ceiling('12345678')->>'configured')::boolean,
  false,'email sending has no default ceiling and is initially fail closed');
select throws_ok($$select public.sutra_founder_set_customer_email_cost_ceiling('99999999',0.05,
  'Nonfounder attempt to configure delivery')$$,'42501',null,
  'a nonfounder cannot configure the ceiling');
select throws_ok($$select public.sutra_founder_set_customer_email_cost_ceiling('12345678',0,
  'Malformed zero ceiling')$$,'22023',null,'zero ceiling is rejected');
select throws_ok($$select public.sutra_founder_set_customer_email_cost_ceiling('12345678',0.055,
  'Malformed fractional-cent ceiling')$$,'22023',null,'fractional-cent ceiling is rejected');
select throws_ok($$select public.sutra_founder_set_customer_email_cost_ceiling('12345678',0.05,
  'short')$$,'22023',null,'a missing audit reason is rejected');
select is((public.sutra_founder_set_customer_email_cost_ceiling('12345678',0.05,
  'Set a bounded unit cost for customer email actions.') ->>'max_message_cost_eur')::numeric,
  0.05::numeric,'founder can configure an explicit per-message ceiling');
select is((public.sutra_founder_get_customer_email_cost_ceiling('12345678')->>'max_message_cost_eur')::numeric,
  0.05::numeric,'founder can read the active ceiling');
select ok(exists(select 1 from public.company_settings where key='customer_email_max_message_cost_eur'
  and founder_only and governance_sensitive),'ceiling is a protected company setting');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.customer_email_cost_ceiling_changed'
  and resource_id='customer_email_max_message_cost_eur'
  and details->>'reason'='Set a bounded unit cost for customer email actions.'
  and (details->>'new_max_message_cost_eur')::numeric=0.05),
  'founder change records old/new value and reason in audit log');
select throws_ok($$select public.sutra_founder_get_customer_email_cost_ceiling('99999999')$$,
  '42501',null,'a nonfounder cannot read the founder cost control');

select * from finish();
rollback;

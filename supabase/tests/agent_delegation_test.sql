begin;
select plan(4);

select ok(not exists (
  select 1
  from public.agents a
  cross join lateral unnest(a.can_delegate_to) target(slug)
  left join public.agents recipient on recipient.slug = target.slug and recipient.active
  where recipient.id is null
), 'every delegation target references an active agent');

select is((select can_delegate_to from public.agents where slug='cpo'),
  array['product_manager','sales','cmo']::text[], 'CPO delegates to the CMO agent slug');
select is((select can_delegate_to from public.agents where slug='sales'),
  array['product_manager','cmo']::text[], 'Sales delegates to the CMO agent slug');
select is((select config->'can_delegate_to' from public.agents where slug='cpo'),
  to_jsonb(array['product_manager','sales','cmo']::text[]), 'agent config stays consistent with delegation column');

select * from finish();
rollback;

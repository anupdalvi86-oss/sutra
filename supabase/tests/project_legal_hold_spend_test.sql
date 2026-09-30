begin;
select plan(2);

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
on conflict(key) do update set value=excluded.value,governance_sensitive=true,
  founder_only=true,updated_by='test';

create temporary table legal_hold_project on commit drop as
  select (public.sutra_submit_proposal('12345678','Legal hold spend fixture',
    'Verify central database reservation checks survive project status drift.',20,'EUR')->>'project_id')::uuid as id;
update public.projects set status='active',legal_hold=true where id=(select id from legal_hold_project);

select throws_ok($$select public.sutra_authorize_initiative_cost('system','sutra',null,
  (select id from legal_hold_project),'tools','fixture-vendor','Paid action under legal hold',0.05,
  'EUR','legal-hold-spend-001')$$,
  '42501','initiative is under legal hold; paid work is paused',
  'a project legal hold blocks shared reservations even if project status is active');
select is((select count(*)::integer from public.initiative_budget_ledger
  where project_id=(select id from legal_hold_project)),0,
  'a blocked legal-hold reservation leaves no expense or ledger commitment');

select * from finish();
rollback;

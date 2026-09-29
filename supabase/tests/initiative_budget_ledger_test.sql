begin;
select plan(38);

select ok((select relrowsecurity from pg_class where oid='public.initiative_budget_ledger'::regclass),
  'initiative spend ledger has row level security enabled');
select ok(not has_table_privilege('anon','public.initiative_budget_ledger','SELECT'),
  'anonymous clients cannot read initiative costs');
select ok(not has_table_privilege('authenticated','public.initiative_budget_ledger','SELECT'),
  'authenticated clients cannot read initiative costs');
select ok(has_table_privilege('service_role','public.initiative_budget_ledger','SELECT'),
  'the private company status API can read initiative costs');
select ok(not has_table_privilege('service_role','public.initiative_budget_ledger','INSERT'),
  'the service API cannot bypass the cost reservation RPC');
select ok(not has_table_privilege('service_role','public.initiative_budget_ledger','UPDATE'),
  'the service API cannot rewrite ledger entries directly');
select ok(not has_table_privilege('service_role','public.initiative_budget_ledger','DELETE'),
  'the service API cannot delete ledger history');
select ok(not has_table_privilege('service_role','public.projects','UPDATE'),
  'the service API cannot modify project budget ceilings directly');
select ok(not has_function_privilege('anon',
  'public.sutra_authorize_initiative_cost(text,text,uuid,uuid,text,text,text,numeric,character,text)','EXECUTE'),
  'anonymous clients cannot reserve initiative spend');
select ok(has_function_privilege('service_role',
  'public.sutra_authorize_initiative_cost(text,text,uuid,uuid,text,text,text,numeric,character,text)','EXECUTE'),
  'the central policy service can reserve initiative spend');
select ok(not has_function_privilege('anon',
  'public.sutra_founder_set_project_budget(text,uuid,numeric,text)','EXECUTE'),
  'anonymous clients cannot change initiative budgets');
select ok(has_function_privilege('service_role',
  'public.sutra_founder_set_project_budget(text,uuid,numeric,text)','EXECUTE'),
  'the private Telegram API can call the founder-checked budget control');
select ok(exists(select 1 from pg_trigger where tgrelid='public.approvals'::regclass
    and tgname='approvals_mark_initiative_budget_cfo_only' and not tgisinternal),
  'new initiative budget reviews do not require a second routine founder approval');
select ok(exists(select 1 from pg_trigger where tgrelid='public.approvals'::regclass
    and tgname='approvals_guard_project_budget_founder_approval' and not tgisinternal),
  'legacy founder project approvals still enforce completed CFO and proposal reviews');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value;
select public.sutra_set_agent_model_spend_profile('12345678','openai','gpt-6-luna',1,1,1000,1000,true);
create temporary table initiative_fixture on commit drop as
  select (public.sutra_submit_proposal('12345678','Budget ledger fixture',
    'Exercise initiative cost reservation and audited budget changes',20,'EUR')->>'project_id')::uuid as project_id;
update public.projects set status='approved',budget_assessment_status='within_cap',
  budget_assessment='{"estimated_total_eur":20,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"other","amount_eur":20,"basis":"Database authorization test fixture."}]}'::jsonb
  where id=(select project_id from initiative_fixture);
update public.approvals set status='approved',decisions='{"cfo":{"decision":"approve"},"product_manager":{"decision":"approve"}}'::jsonb
  where project_id=(select project_id from initiative_fixture) and approval_type='project_budget';
select is((public.sutra_authorize_initiative_cost('system','sutra',null,
  (select project_id from initiative_fixture),'tools','fixture-vendor','Routine tool expense',12,'EUR','cost-idem-0001')->>'status'),
  'reserved','an in-cap cost above the generic approval bands is authorized without another approval');
select is((select status from public.expenses where description='Routine tool expense'),'approved',
  'the authorized cost is committed in the expense ledger');
select is((select count(*)::integer from public.approvals where expense_id=(select id from public.expenses where description='Routine tool expense')),
  0,'ordinary in-cap spending creates no approval request');
select is((public.sutra_authorize_initiative_cost('system','sutra',null,
  (select project_id from initiative_fixture),'tools','fixture-vendor','Routine tool expense',12,'EUR','cost-idem-0001')->>'status'),
  'already_reserved','an identical request is idempotent');
select throws_ok($$select public.sutra_authorize_initiative_cost('system','sutra',null,
  (select project_id from initiative_fixture),'tools','fixture-vendor','Routine tool expense',11,'EUR','cost-idem-0001')$$,
  '23505',null,'idempotency keys cannot be reused with a different amount');
select throws_ok($$select public.sutra_authorize_initiative_cost('system','sutra',null,
  (select project_id from initiative_fixture),'tools','fixture-vendor','Exceeds all-in ceiling',9,'EUR','cost-idem-0002')$$,
  '23514',null,'the initiative ceiling hard-stops commitments beyond its remaining balance');
update public.budgets set limit_amount=13 where scope='project' and scope_key=(select project_id::text from initiative_fixture)
  and period='lifetime' and currency='EUR';
select throws_ok($$select public.sutra_authorize_initiative_cost('system','sutra',null,
  (select project_id from initiative_fixture),'tools','fixture-vendor','Exceeds configured project limit',2,'EUR','cost-idem-0003')$$,
  '23514',null,'configured project hard stops apply independently of the initiative ceiling');
select lives_ok($$update public.budgets set limit_amount=20 where scope='project'
  and scope_key=(select project_id::text from initiative_fixture) and period='lifetime' and currency='EUR'$$,
  'project test policy can restore its original fixture cap');
select is((public.sutra_settle_initiative_cost('sutra-worker-12345678',
  (select id from public.initiative_budget_ledger where idempotency_key='cost-idem-0001'),null,false)->>'status'),
  'unknown','unverified usage remains an unknown reservation');
select is((select reserved_amount from public.initiative_budget_ledger where idempotency_key='cost-idem-0001'),
  12::numeric,'unknown usage retains the complete reserved amount');
select is((select status from public.initiative_budget_ledger where idempotency_key='cost-idem-0001'),
  'unknown','the shared ledger preserves the unknown state');
select throws_ok($$select public.sutra_founder_set_project_budget('99999999',
  (select project_id from initiative_fixture),25,'Raise fixture budget for an authorization test')$$,
  '42501',null,'only the configured founder may change the initiative ceiling');
select throws_ok($$select public.sutra_founder_set_project_budget('12345678',
  (select project_id from initiative_fixture),11,'Lower below the held cost')$$,
  '23514',null,'a budget cannot be lowered beneath actual or unresolved reservations');
select is((public.sutra_founder_set_project_budget('12345678',
  (select project_id from initiative_fixture),25,'Raise fixture budget after CFO assessment')->>'changed'),
  'true','the configured founder can raise the initiative cap');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='initiative.budget_changed' and resource_id=(select project_id::text from initiative_fixture)),
  'initiative budget changes are audit logged');
select throws_ok($$select public.sutra_authorize_initiative_cost('agent','cfo',
  (select id from public.agents where slug='cfo'),(select project_id from initiative_fixture),
  'tools','fixture-vendor','Unassigned agent cost',1,'EUR','cost-idem-cfo01')$$,
  '42501',null,'an agent cannot reserve initiative costs without an assigned active task');

create temporary table over_cap_fixture on commit drop as
  select (public.sutra_submit_proposal('12345678','Over-cap initiative fixture',
    'Exercise the budget-gap pause and founder-adjustment workflow',10,'EUR')->>'project_id')::uuid as project_id;
create temporary table over_cap_run_expenses(expense_id uuid,run_id uuid,agent_id uuid) on commit drop;
with run_rows as (
  select r.id as run_id,r.agent_id,a.slug from public.agent_runs r
    join public.agents a on a.id=r.agent_id
    where r.project_id=(select project_id from over_cap_fixture) and r.run_order between 1 and 5
), created as (
  insert into public.expenses(project_id,agent_id,category,description,amount,actual_amount,currency,status,
      requested_by,approved_at,incurred_at)
    select (select project_id from over_cap_fixture),run_rows.agent_id,'ai_inference',
      'Simulated reconciled proposal review '||run_rows.slug,0.01,0.01,'EUR','paid',run_rows.slug,now(),now()
      from run_rows
    returning id,agent_id,description
)
insert into over_cap_run_expenses
  select created.id,run_rows.run_id,run_rows.agent_id from created join run_rows on run_rows.agent_id=created.agent_id;
insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
  reserved_amount,actual_amount,usage,status,settled_at)
  select run_id,1,expense_id,'openai','gpt-6-luna',0.01,0.01,
    '{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}'::jsonb,'reconciled',now()
    from over_cap_run_expenses;
update public.agent_runs set status='succeeded',finished_at=now(),output='{"summary":"Completed internal review","recommendation":"Continue","evidence":[]}'::jsonb
  where project_id=(select project_id from over_cap_fixture) and run_order between 1 and 3;
update public.agent_runs set status='succeeded',finished_at=now(),output=
  '{"summary":"Cost estimate exceeds the cap","decision":"approve","decision_rationale":"The all-in estimate is higher than the founder ceiling.","budget_estimate":{"estimated_total_eur":25,"confidence":"high","recommended_action":"request_budget_increase","line_items":[{"category":"development","amount_eur":15,"basis":"Estimated engineering work for the initiative."},{"category":"hosting","amount_eur":10,"basis":"Estimated hosting through initial delivery."}]}}'::jsonb
  where project_id=(select project_id from over_cap_fixture) and run_order=4;
select is((select status from public.projects where id=(select project_id from over_cap_fixture)),'paused',
  'an estimate above the founder ceiling pauses the initiative');
select is((select status from public.agent_runs where project_id=(select project_id from over_cap_fixture) and run_order=5),'blocked',
  'the PM stage stops until the founder resolves an all-in budget gap');
select is((public.sutra_decide_role_approval((select id from public.approvals where project_id=(select project_id from over_cap_fixture)
  and approval_type='project_budget'),(select id::text from public.agents where slug='cfo'),'cfo','approve','The estimate is complete')->>'status'),
  'approved','the finance approval decision can be recorded before a budget gap is resolved');
select is((select status from public.approvals where project_id=(select project_id from over_cap_fixture)
  and approval_type='project_budget'),'pending','CFO approval stays open until PM completes within the final cap');
select is((public.sutra_founder_set_project_budget('12345678',(select project_id from over_cap_fixture),30,
  'Increase the ceiling to cover the documented engineering estimate')->>'changed'),'true',
  'the founder can raise the cap to the CFO estimate');
select is((select status from public.projects where id=(select project_id from over_cap_fixture)),'proposed',
  'a sufficient founder budget change resumes the proposal review');
select is((select status from public.agent_runs where project_id=(select project_id from over_cap_fixture) and run_order=5),'queued',
  'a sufficient cap increase requeues the same PM review rather than bypassing it');
update public.agent_runs set status='succeeded',finished_at=now(),output=
  '{"summary":"A sufficiently long PM summary","recommendation":"Proceed within the revised cap","evidence":[],"milestones":["Discovery"]}'::jsonb
  where project_id=(select project_id from over_cap_fixture) and run_order=5;
select ok(exists(select 1 from public.audit_log where action='initiative.budget_increase_required'
  and resource_id=(select project_id::text from over_cap_fixture)),
  'the founder-visible budget gap is audit logged');

select * from finish();
rollback;

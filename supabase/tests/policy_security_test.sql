begin;
select plan(46);

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;

set local role service_role;

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
select ok(exists(select 1 from public.agent_runs where trigger_type='founder_proposal' and status='queued'),'workflow roles receive durable queued runs');
select ok(exists(select 1 from public.tasks where task_type='research' and status='blocked'),'execution work stays blocked before founder approval');
select throws_ok($$select public.sutra_founder_decide_approval('12345678',(select id from public.approvals order by created_at desc limit 1),'approve','')$$,
  '42501',null,'founder approval cannot skip the required CFO decision');

select throws_ok($$update public.spending_policies set required_approvers='{}' where name='founder_200_and_over'$$,
  '42501',null,'service_role cannot mutate spending authority directly');
select is((public.sutra_authorize_spend('agent','developer',(select id from public.agents where slug='developer'),null,null,
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
reset role;
set local role anon;
select throws_ok($$select * from public.spending_policies$$,'42501',null,'anon role cannot read spending policies');
reset role;
set local role service_role;
select throws_ok($$select public.sutra_authorize_spend('system','test',null,(select id from public.projects order by created_at desc limit 1),null,'ai_api',null,'premature spend',5,'EUR')$$,
  '42501',null,'spending against a proposed project is blocked');
select lives_ok($$select public.sutra_decide_role_approval((select id from public.approvals order by created_at desc limit 1),
  (select id::text from public.agents where slug='cfo'),'cfo','approve','Budget reviewed')$$,
  'CFO can record the required budget review');
select lives_ok($$select public.sutra_founder_decide_approval('12345678',
  (select id from public.approvals order by created_at desc limit 1),'approve','Proceed')$$,
  'founder can approve only after CFO review');
select is((select status from public.projects order by created_at desc limit 1),'approved','founder approval activates the proposal');
select is((select status from public.tasks where task_type='research' order by created_at limit 1),'ready','research becomes executable after approval');
select is((select count(*)::integer from public.tasks where task_type='engineering' and status='backlog'),7,'engineering through sales handoff tasks are queued');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='product_manager'),
  (select id from public.tasks where task_type='product' order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  'assigned PM can start the approved planning task');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='product_manager'),
  (select id from public.tasks where task_type='product' order by created_at desc limit 1),'done','{"requirements":"recorded"}'::jsonb)$$,
  'PM completion requires and records evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='architect') order by created_at desc limit 1),
  'ready','PM completion releases architecture task');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  '22023',null,'developer cannot start before architecture handoff');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='architect'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='architect') order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  'assigned architect can start when its task is ready');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='architect'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='architect') order by created_at desc limit 1),'done','{"design":"reviewed"}'::jsonb)$$,
  'architecture completion records evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),
  'ready','architecture completion releases developer task');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'in_progress','{}'::jsonb)$$,
  'assigned developer can start after architecture');
select throws_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'done','{}'::jsonb)$$,
  '22023',null,'completion without evidence is rejected');
select lives_ok($$select public.sutra_update_task((select id from public.agents where slug='developer'),
  (select id from public.tasks where owner_agent_id=(select id from public.agents where slug='developer') order by created_at desc limit 1),'done','{"pull_request":"drafted"}'::jsonb)$$,
  'developer completion requires evidence');
select is((select status from public.tasks where owner_agent_id=(select id from public.agents where slug='qa') order by created_at desc limit 1),
  'ready','developer completion releases QA task');

select lives_ok($$select public.sutra_set_budget('12345678','company','*','transaction',5,80,true)$$,
  'founder can configure a transaction hard stop through the audited policy function');
select throws_ok($$select public.sutra_authorize_spend('system','test',null,null,null,'ai_api',null,'over hard stop',6,'EUR')$$,
  '23514',null,'transaction budget exhaustion blocks the spend');
select throws_ok($$select public.sutra_set_budget('99999999','company','*','transaction',500,80,true)$$,
  '42501',null,'nonfounder cannot change company budget');

reset role;
select ok((select count(*) from public.audit_log where action='spending.authorization_requested') >= 7,'authorization decisions are audit logged');

select * from finish();
rollback;

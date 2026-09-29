begin;
select no_plan();

insert into public.company_settings(key,value,founder_only,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
on conflict(key) do update set value=excluded.value,founder_only=true,governance_sensitive=true,updated_by='test';

create temporary table review_deferral_fixture(
  developer_task_id uuid,qa_task_id uuid,security_task_id uuid,devops_task_id uuid,
  agent_run_count bigint,reservation_count bigint,expense_count bigint,unknown_reservations jsonb
) on commit drop;
do $$
declare project_uuid uuid; developer_uuid uuid; qa_uuid uuid; security_uuid uuid; devops_uuid uuid;
  developer_task uuid; qa_task uuid; security_task uuid; devops_task uuid;
begin
  select id into developer_uuid from public.agents where slug='developer' and active;
  select id into qa_uuid from public.agents where slug='qa' and active;
  select id into security_uuid from public.agents where slug='security' and active;
  select id into devops_uuid from public.agents where slug='devops' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('review-deferral-'||gen_random_uuid(),'Review deferral fixture',
      'Temporary fixture to test founder deferrals without launching or spending.','approved',500,'EUR','test')
    returning id into project_uuid;
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_uuid,'Developer completed fixture','Completed engineering prerequisite.',
      '["Implementation evidence exists"]'::jsonb,'engineering','done',developer_uuid,developer_uuid)
    returning id into developer_task;
  insert into public.tasks(project_id,parent_task_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_uuid,developer_task,'QA review fixture','Verify acceptance criteria.',
      '["Acceptance evidence is recorded"]'::jsonb,'engineering','blocked',qa_uuid,qa_uuid)
    returning id into qa_task;
  insert into public.tasks(project_id,parent_task_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_uuid,qa_task,'Security review fixture','Review security and dependencies.',
      '["Findings and owner are recorded"]'::jsonb,'engineering','backlog',security_uuid,security_uuid)
    returning id into security_task;
  insert into public.tasks(project_id,parent_task_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_uuid,security_task,'DevOps plan fixture','Prepare release and rollback plan only.',
      '["Deployment and rollback steps are documented"]'::jsonb,'engineering','backlog',devops_uuid,devops_uuid)
    returning id into devops_task;
  insert into review_deferral_fixture values(developer_task,qa_task,security_task,devops_task,
    (select count(*) from public.agent_runs),
    (select count(*) from public.agent_run_spend_reservations),
    (select count(*) from public.expenses),
    coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'status',s.status,
      'reserved_amount',s.reserved_amount,'actual_amount',s.actual_amount,
      'input_tokens',s.input_tokens,'output_tokens',s.output_tokens) order by s.id)
      from public.agent_run_spend_reservations s where s.status='unknown'),'[]'::jsonb));
end
$$;
grant select on review_deferral_fixture to service_role;

select ok(not has_function_privilege('anon','public.sutra_founder_defer_quality_chain(text,uuid,text)','EXECUTE'),
  'anonymous callers cannot defer the review chain');
select ok(not has_function_privilege('authenticated','public.sutra_founder_defer_quality_chain(text,uuid,text)','EXECUTE'),
  'authenticated callers cannot defer the review chain');
select ok(has_function_privilege('service_role','public.sutra_founder_defer_quality_chain(text,uuid,text)','EXECUTE'),
  'the trusted API role can invoke the founder-checked deferral function');

set local role service_role;
select throws_ok($$select public.sutra_founder_defer_task('99999999',(select qa_task_id from review_deferral_fixture),'Founder requested a temporary QA pause')$$,
  '42501',null,'nonfounder cannot defer a review task');
select throws_ok($$select public.sutra_founder_defer_task('12345678',null,'Founder requested a temporary QA pause')$$,
  '22023',null,'malformed task identifiers are rejected');
select throws_ok($$select public.sutra_founder_defer_task('12345678',(select qa_task_id from review_deferral_fixture),'pause')$$,
  '22023',null,'deferrals require a meaningful reason');
select throws_ok($$select public.sutra_founder_defer_task('12345678',(select devops_task_id from review_deferral_fixture),'Founder requested a temporary DevOps pause')$$,
  '42501',null,'founder deferral cannot skip DevOps release planning');
select throws_ok($$select public.sutra_update_task(
  (select owner_agent_id from public.tasks where id=(select qa_task_id from review_deferral_fixture)),
  (select qa_task_id from review_deferral_fixture),'deferred','{}'::jsonb)$$,
  '22023',null,'QA cannot self-defer through the agent task update API');
select is((public.sutra_founder_defer_quality_chain('12345678',(select qa_task_id from review_deferral_fixture),
  'Founder directed QA and Security reviews to pause; no pass or security approval is claimed.') -> 'qa' ->> 'status'),'deferred',
  'founder can atomically defer the assigned QA review');
select is((select status from public.tasks where id=(select qa_task_id from review_deferral_fixture)),'deferred',
  'deferred QA is not marked done');
select is((select status from public.tasks where id=(select security_task_id from review_deferral_fixture)),'deferred',
  'Security is never left ready between QA and Security deferral');
select is((select status from public.tasks where id=(select security_task_id from review_deferral_fixture)),'deferred',
  'deferred Security is not marked done');
select is((select status from public.tasks where id=(select devops_task_id from review_deferral_fixture)),'ready',
  'Security deferral releases only the direct DevOps planning child');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='founder.task_review_deferred' and resource_id=(select qa_task_id::text from review_deferral_fixture)
  and details->>'review_completed'='false' and details->>'release_authority_granted'='false'),
  'QA deferral is audit logged as incomplete and without release authority');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='founder.task_review_deferred' and resource_id=(select security_task_id::text from review_deferral_fixture)
  and details->>'review_completed'='false' and details->>'spending_authority_changed'='false'),
  'Security deferral is audit logged as incomplete and without spending authority changes');
reset role;
select is((select count(*)::bigint from public.agent_runs),
  (select agent_run_count from review_deferral_fixture),'deferral creates no agent runs or model requests');
select is((select count(*)::bigint from public.agent_run_spend_reservations),
  (select reservation_count from review_deferral_fixture),'deferral creates or releases no spend reservations');
select is(coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'status',s.status,
    'reserved_amount',s.reserved_amount,'actual_amount',s.actual_amount,
    'input_tokens',s.input_tokens,'output_tokens',s.output_tokens) order by s.id)
    from public.agent_run_spend_reservations s where s.status='unknown'),'[]'::jsonb)::text,
  (select unknown_reservations::text from review_deferral_fixture),
  'every pre-existing unknown reservation remains held and unchanged');
select is((select count(*)::bigint from public.expenses),
  (select expense_count from review_deferral_fixture),'deferral records no expenses');
select is((select count(*)::integer from public.task_review_evidence where task_id in
  (select qa_task_id from review_deferral_fixture union all select security_task_id from review_deferral_fixture)),0,
  'deferring review creates no pass/fail review evidence');
set local role service_role;
select throws_ok($$select public.sutra_founder_restore_deferred_task('12345678',(select security_task_id from review_deferral_fixture),'Revisit security review')$$,
  '42501',null,'Security cannot be restored before its QA prerequisite is complete');
select is((public.sutra_founder_restore_deferred_task('12345678',(select qa_task_id from review_deferral_fixture),
  'Founder is ready to resume QA review.') ->> 'status'),'ready',
  'founder can restore deferred QA when its Developer prerequisite is done');
select is((select status from public.tasks where id=(select security_task_id from review_deferral_fixture)),'deferred',
  'restoring QA does not automatically claim a Security review');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='founder.task_review_restored' and resource_id=(select qa_task_id::text from review_deferral_fixture)
  and details->>'release_authority_granted'='false'),
  'review restoration is audit logged without granting release authority');
reset role;

select * from finish();
rollback;

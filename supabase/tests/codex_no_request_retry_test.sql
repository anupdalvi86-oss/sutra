begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,'test')
on conflict(key) do update set value=excluded.value;
select public.sutra_set_agent_model_spend_profile(
  '12345678','openai','gpt-6-luna',0.2,0.5,1000,1000,true
);
select is((select value #>> '{}' from public.company_settings where key='codex_no_request_retry_limit'),'3',
  'Codex no-request retry limit defaults to three total attempts');

create temporary table codex_retry_fixture(task_id uuid,execution_id uuid,run_id uuid,reservation_id uuid) on commit drop;
do $$
declare project_id uuid; task_id uuid; developer_id uuid; run_id uuid; execution_id uuid;
  expense_id uuid; reservation_id uuid; approval_id uuid;
begin
  select id into developer_id from public.agents where slug='developer' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('retry-codex-'||gen_random_uuid(),'Codex retry fixture',
      'Founder-approved project fixture for a metered no-request Codex retry.','approved',500,'EUR','test')
    returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      500,'EUR','Approved fixture project budget','approved','12345678',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Implement approved product tasks','Implement engineering tasks in the approved scope.',
      '["Changes stay inside the approved scope"]'::jsonb,'engineering','in_progress',developer_id,developer_id)
    returning id into task_id;
  insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'developer_scope',task_id::text,'founder:test',array['founder'],
      '{"founder":{"decision":"approve"}}'::jsonb,0,'EUR','Approved fixture developer scope',
      'approved','12345678',now()) returning id into approval_id;
  insert into public.github_task_dispatches(task_id,status,attempts,issue_number,issue_url)
    values(task_id,'created',1,107,'https://github.com/anupdalvi86-oss/sutra/issues/107');
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,finished_at,attempt_count)
    values(developer_id,project_id,task_id,'codex_execution','failed',
      jsonb_build_object('issue_number',107),'{"codex_execution_status":"unknown"}'::jsonb,
      now(),now(),1) returning id into run_id;
  insert into public.expenses(category,description,amount,actual_amount,currency,status,requested_by,approved_at)
    values('ai_inference','Unknown pre-request Codex reserve fixture',0.01,null,'EUR','approved','test',now())
    returning id into expense_id;
  insert into public.agent_run_spend_reservations(agent_run_id,attempt,expense_id,provider,model,
      reserved_amount,usage,status,settled_at,input_eur_per_million_tokens,
      output_eur_per_million_tokens,max_input_tokens,max_output_tokens)
    values(run_id,1,expense_id,'openai','gpt-6-luna',0.01,
      '{"reason":"Codex execution ended without trusted complete usage"}'::jsonb,'unknown',now(),
      0.2,0.5,1000,1000) returning id into reservation_id;
  insert into public.codex_task_executions(task_id,agent_run_id,reservation_id,issue_number,
      provider,model,max_requests,request_count,input_tokens,output_tokens,status,approval_id)
    values(task_id,run_id,reservation_id,107,'openai','gpt-6-luna',3,0,0,0,'unknown',approval_id)
    returning id into execution_id;
  insert into codex_retry_fixture values(task_id,execution_id,run_id,reservation_id);
end;
$$;
grant select on codex_retry_fixture to service_role;
create temporary table retry_policy_snapshot on commit drop as
  select name,min_amount,max_amount,required_approvers,active from public.spending_policies;
create temporary table run_count_before_limit_change on commit drop as
  select count(*)::integer as count from public.agent_runs;
grant select on run_count_before_limit_change to service_role;

set local role service_role;
select throws_ok($$select public.sutra_founder_retry_codex_task_execution('99999999',(select task_id from codex_retry_fixture))$$,
  '42501',null,'a nonfounder cannot retry a Codex execution');
select throws_ok($$select public.sutra_founder_retry_codex_task_execution('12345678',null)$$,
  '22023',null,'malformed Codex retry requests are rejected');
select throws_ok($$select public.sutra_founder_set_codex_retry_limit('99999999',4)$$,
  '42501',null,'a nonfounder cannot change the Codex retry limit');
select throws_ok($$select public.sutra_founder_set_codex_retry_limit('12345678',0)$$,
  '22023',null,'an out-of-range Codex retry limit is rejected');
select throws_ok($$select public.sutra_founder_set_codex_retry_limit('12345678',4)$$,
  '22023',null,'the founder cannot raise the hard cap above three total attempts');
select is((public.sutra_founder_get_codex_retry_limit('12345678')->>'max_total_attempts')::integer,3,
  'founder can read the current total-attempt limit');
select is((public.sutra_founder_set_codex_retry_limit('12345678',2)->>'max_total_attempts')::integer,2,
  'founder can lower the retry limit to two total attempts');
select is((select count(*)::integer from public.agent_runs),
  (select count from run_count_before_limit_change),
  'changing retry authority does not start a retry or agent run');
select ok(exists(select 1 from public.audit_log where actor_type='founder' and actor_id='12345678'
  and action='founder.codex_retry_limit_changed' and resource_id='codex_no_request_retry_limit'
  and details->>'previous_total_attempts'='3' and details->>'new_total_attempts'='2'
  and details->>'no_retry_triggered'='true'),
  'retry-limit changes are audit logged with no retry side effect');
select public.sutra_founder_set_codex_retry_limit('12345678',3);
create temporary table codex_retry_result(payload jsonb) on commit drop;
insert into codex_retry_result select public.sutra_founder_retry_codex_task_execution(
  '12345678',(select task_id from codex_retry_fixture));
reset role;

select is((select payload->>'status' from codex_retry_result),'queued',
  'founder retry queues the existing scoped Codex task');
select is((select (payload->>'retry_number')::integer from codex_retry_result),1,
  'the initial failed run is recorded as the first retry ordinal');
select is((select (payload->>'attempt_number')::integer from codex_retry_result),2,
  'the first retry creates attempt two of three total attempts');
select is((select (payload->>'old_unknown_reservation_preserved')::boolean from codex_retry_result),true,
  'retry does not rewrite or release the old unknown reservation');
select is((select status from public.agent_run_spend_reservations
  where id=(select reservation_id from codex_retry_fixture)),'unknown',
  'original unknown spend remains reserved');
select is((select count(*)::integer from public.codex_task_execution_attempts
  where execution_id=(select execution_id from codex_retry_fixture)),1,
  'previous Codex attempt is retained in immutable attempt history');
select is((select request_count from public.codex_task_executions
  where id=(select execution_id from codex_retry_fixture)),0,
  'new execution starts with zero provider requests');
select is((select status from public.codex_task_executions
  where id=(select execution_id from codex_retry_fixture)),'running',
  'new execution is claimable by the metered runner');
select is((select s.status from public.agent_run_spend_reservations s
  join public.codex_task_executions e on e.reservation_id=s.id
  where e.id=(select execution_id from codex_retry_fixture)),'reserved',
  'retry gets a fresh reservation through the central spending policy');
select is((select count(*)::integer from (
  (select name,min_amount,max_amount,required_approvers,active from public.spending_policies
   except select name,min_amount,max_amount,required_approvers,active from retry_policy_snapshot)
  union all
  (select name,min_amount,max_amount,required_approvers,active from retry_policy_snapshot
   except select name,min_amount,max_amount,required_approvers,active from public.spending_policies)
) changed),0,
  'founder retry leaves financial authority thresholds unchanged');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and actor_id='12345678' and action='founder.codex_task_retry_requested'
  and resource_id=(select task_id::text from codex_retry_fixture)
  and details->>'prior_request_count'='0' and details->>'project_spending_authorized'='false'),
  'retry records founder identity, verified no-request evidence, and unchanged project authority');
-- A provider request blocks retry. When reset to a verified no-request failure,
-- attempt three may run; attempt four is blocked by the database-configured cap.
do $$
declare execution_id uuid; run_id uuid; reservation_id uuid; task_id uuid;
begin
  select e.id,e.agent_run_id,e.reservation_id,e.task_id into execution_id,run_id,reservation_id,task_id
    from public.codex_task_executions e where e.id=(select f.execution_id from codex_retry_fixture f);
  update public.agent_runs set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
    output='{"codex_execution_status":"unknown"}'::jsonb where id=run_id;
  update public.agent_run_spend_reservations set status='unknown',settled_at=now(),
    usage='{"reason":"Codex execution ended without trusted complete usage"}'::jsonb where id=reservation_id;
  update public.codex_task_executions set status='unknown',request_count=1 where id=execution_id;
end;
$$;
set local role service_role;
select throws_ok($$select public.sutra_founder_retry_codex_task_execution('12345678',(select task_id from codex_retry_fixture))$$,
  '42501',null,'a model request prevents the no-request retry path');
reset role;

do $$
declare execution_id uuid;
begin
  select e.id into execution_id from public.codex_task_executions e
    where e.id=(select f.execution_id from codex_retry_fixture f);
  update public.codex_task_executions set status='unknown',request_count=0,input_tokens=0,output_tokens=0
    where id=execution_id;
end;
$$;
set local role service_role;
create temporary table codex_retry_third_result(payload jsonb) on commit drop;
insert into codex_retry_third_result select public.sutra_founder_retry_codex_task_execution(
  '12345678',(select task_id from codex_retry_fixture));
reset role;
select is((select (payload->>'attempt_number')::integer from codex_retry_third_result),3,
  'the founder-configured three-attempt ceiling allows attempt three');
select is((select (payload->>'max_total_attempts')::integer from codex_retry_third_result),3,
  'retry response states the authoritative total-attempt ceiling');
select is((select count(*)::integer from public.codex_task_execution_attempts
  where execution_id=(select execution_id from codex_retry_fixture)),2,
  'both previous no-request attempts remain in immutable history');
do $$
declare execution_id uuid; run_id uuid; reservation_id uuid;
begin
  select e.id,e.agent_run_id,e.reservation_id into execution_id,run_id,reservation_id
    from public.codex_task_executions e where e.id=(select f.execution_id from codex_retry_fixture f);
  update public.agent_runs set status='failed',finished_at=now(),lease_token=null,lease_expires_at=null,
    output='{"codex_execution_status":"unknown"}'::jsonb where id=run_id;
  update public.agent_run_spend_reservations set status='unknown',settled_at=now(),
    usage='{"reason":"Codex execution ended without trusted complete usage"}'::jsonb where id=reservation_id;
  update public.codex_task_executions set status='unknown',request_count=0,input_tokens=0,output_tokens=0
    where id=execution_id;
end;
$$;
create temporary table codex_terminal_authorization_result(payload jsonb) on commit drop;
grant insert on codex_terminal_authorization_result to service_role;
set local role service_role;
insert into codex_terminal_authorization_result
select public.sutra_authorize_codex_task('sutra-worker-codex12345678',
  (select task_id from codex_retry_fixture),107,
  'https://github.com/anupdalvi86-oss/sutra/issues/107','openai','gpt-6-luna');
reset role;
select is((select payload->>'status' from codex_terminal_authorization_result),'terminal',
  'polling a terminal Codex execution returns a safe no-op result');
select is((select payload->>'execution_status' from codex_terminal_authorization_result),'unknown',
  'terminal status preserves the persisted execution outcome');
select is((select count(*)::integer from public.agent_runs
  where task_id=(select task_id from codex_retry_fixture)),3,
  'terminal authorization does not create another agent run');
select is((select count(*)::integer from public.agent_run_spend_reservations
  where agent_run_id in (select id from public.agent_runs
    where task_id=(select task_id from codex_retry_fixture))),3,
  'terminal authorization creates no reservation and preserves prior reserves');
set local role service_role;
select throws_ok($$select public.sutra_founder_retry_codex_task_execution('12345678',(select task_id from codex_retry_fixture))$$,
  '42501',null,'database total-attempt limit blocks attempt four');
select throws_ok($$select public.sutra_founder_get_codex_retry_limit('99999999')$$,
  '42501',null,'a nonfounder cannot read the retry limit');
reset role;

set local role anon;
select throws_ok($$select public.sutra_founder_retry_codex_task_execution('12345678',(select task_id from codex_retry_fixture))$$,
  '42501',null,'anonymous callers cannot execute the retry RPC');
select throws_ok($$select public.sutra_founder_set_codex_retry_limit('12345678',4)$$,
  '42501',null,'anonymous callers cannot execute the setting RPC');
select throws_ok($$select public.sutra_founder_get_codex_retry_limit('12345678')$$,
  '42501',null,'anonymous callers cannot execute the getter RPC');
reset role;

select * from finish();
rollback;

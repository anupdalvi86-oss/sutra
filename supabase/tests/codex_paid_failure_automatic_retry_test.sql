begin;
select no_plan();

insert into public.company_settings(key,value,founder_only,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'paid-retry-test')
on conflict(key) do update set value=excluded.value,founder_only=true,
  governance_sensitive=true,updated_by='paid-retry-test';
select public.sutra_set_agent_model_spend_profile(
  '12345678','openai','gpt-6-luna',0.2,0.5,20000,12000,true
);
create temporary table paid_retry_authorization(payload jsonb) on commit drop;
insert into paid_retry_authorization select public.sutra_founder_record_code_authorization(
  '12345678','Standing approval for the Sutra repository code path and automated bounded retry test.');

create temporary table paid_retry_fixture(
  project_id uuid,task_id uuid,execution_id uuid,run_id uuid,lease_token uuid,
  reservation_id uuid,budget_cap numeric,issue_number integer
) on commit drop;
do $$
declare project_id uuid; task_id uuid; developer_id uuid; run_id uuid; lease_token uuid;
  project_approval_id uuid; authorization_id uuid; cap numeric; issue_no integer:=228;
begin
  select id into developer_id from public.agents where slug='developer' and active;
  authorization_id:=(select (payload->>'authorization_id')::uuid from paid_retry_authorization);
  -- The trusted model profile reserves EUR 1.00 per run. The first cap allows
  -- a fresh retry; the second allows the initial reservation and EUR 0.01 of
  -- settled usage, but not another EUR 1.00 reservation.
  foreach cap in array array[3.00::numeric,1.01::numeric] loop
    insert into public.projects(slug,name,description,status,budget_amount,budget_currency,
      requested_budget,currency,created_by,budget_assessment_status,budget_assessed_at,budget_assessment)
    values('auto-paid-retry-'||gen_random_uuid(),'Codex paid retry fixture',
      'Founder-approved bounded retry fixture.','active',cap,'EUR',cap,'EUR','test',
      'within_cap',now(),jsonb_build_object('estimated_total_eur',round(cap/2,2),
        'recommended_action','proceed_within_cap')) returning id into project_id;
    insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
        decisions,amount,currency,summary,status,payload,decided_by,decided_at)
      values(project_id,'project_budget',project_id::text,'founder:test',array['founder'],
        '{"founder":{"decision":"approve"}}'::jsonb,cap,'EUR','Approved retry test budget','approved',
        jsonb_build_object('all_in_budget',cap,'currency','EUR'),'12345678',now())
      returning id into project_approval_id;
    insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
        owner_agent_id,assigned_agent_id)
      values(project_id,'Implement bounded Sutra retry behavior','Implement only within the approved Sutra repository scope.',
        '["The same approved task remains in scope"]'::jsonb,'engineering','in_progress',developer_id,developer_id)
      returning id into task_id;
    insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
        decisions,amount,currency,summary,status,payload,decided_by,decided_at)
      values(project_id,'developer_scope',task_id::text,'founder_standing_authorization',array['founder'],
        jsonb_build_object('founder',jsonb_build_object('decision','approve'),
          'standing_authorization',jsonb_build_object('authorization_id',authorization_id,
            'repository','anupdalvi86-oss/sutra')),
        0,'EUR','Standing authorized retry test scope','approved',
        jsonb_build_object('task_id',task_id,'authorization_id',authorization_id,
          'repository','anupdalvi86-oss/sutra'),'founder:standing-authorization',now());
    insert into public.github_task_dispatches(task_id,status,attempts,issue_number,issue_url)
      values(task_id,'created',1,issue_no,
        format('https://github.com/anupdalvi86-oss/sutra/issues/%s',issue_no));
    lease_token:=gen_random_uuid();
    insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,
        started_at,lease_token,lease_expires_at,attempt_count)
      values(developer_id,project_id,task_id,'codex_execution','running',
        jsonb_build_object('task_id',task_id,'issue_number',issue_no),'{}'::jsonb,
        now(),lease_token,now()+interval '2 hours',1) returning id into run_id;
    insert into paid_retry_fixture(project_id,task_id,run_id,lease_token,budget_cap,issue_number)
      values(project_id,task_id,run_id,lease_token,cap,issue_no);
    issue_no:=issue_no+1;
  end loop;
end;
$$;
grant select,update on paid_retry_fixture to service_role;
create temporary table paid_retry_reservation_result(task_id uuid,payload jsonb) on commit drop;
grant select,insert on paid_retry_reservation_result to service_role;

set local role service_role;
insert into paid_retry_reservation_result
select f.task_id,public.sutra_reserve_agent_run_spend_from_profile(
  'sutra-worker-codex12345678',f.run_id,f.lease_token,'openai','gpt-6-luna')
from paid_retry_fixture f;
reset role;

update paid_retry_fixture f set reservation_id=(r.payload->>'reservation_id')::uuid
from paid_retry_reservation_result r where r.task_id=f.task_id;
insert into public.codex_task_executions(task_id,agent_run_id,reservation_id,issue_number,
    provider,model,max_requests,request_count,input_tokens,output_tokens,status)
select f.task_id,f.run_id,f.reservation_id,f.issue_number,'openai','gpt-6-luna',3,3,20000,12000,'running'
from paid_retry_fixture f;
set local role service_role;
select public.sutra_begin_agent_run_spend('sutra-worker-codex12345678',f.run_id,f.lease_token,f.reservation_id)
from paid_retry_fixture f;
create temporary table paid_retry_finish_result(task_id uuid,payload jsonb) on commit drop;
grant select,insert on paid_retry_finish_result to service_role;
insert into paid_retry_finish_result
select f.task_id,public.sutra_codex_finish_run('sutra-worker-codex12345678',f.run_id,
  f.lease_token,true,false,1,'codex_process_failed')
from paid_retry_fixture f;
reset role;

select is((select payload #>> '{automatic_retry,status}' from paid_retry_finish_result r
  join paid_retry_fixture f using(task_id) where f.budget_cap=3.00),'queued',
  'known paid failure queues an automatic retry when the shared initiative cap has room');
select is((select (payload #>> '{automatic_retry,attempt_number}')::integer from paid_retry_finish_result r
  join paid_retry_fixture f using(task_id) where f.budget_cap=3.00),2,
  'automatic retry begins the second total execution attempt');
select is((select status from public.tasks where id=(select task_id from paid_retry_fixture where budget_cap=3.00)),
  'in_progress','the same Developer task resumes under its existing approval');
select is((select status from public.codex_task_executions where task_id=(select task_id from paid_retry_fixture where budget_cap=3.00)),
  'running','the metered runner receives the new execution only after reservation');
select is((select request_count from public.codex_task_executions where task_id=(select task_id from paid_retry_fixture where budget_cap=3.00)),
  0,'the new execution starts with fresh request counters');
select is((select status from public.agent_run_spend_reservations where id=(select reservation_id from paid_retry_fixture where budget_cap=3.00)),
  'reconciled','the prior metered usage is reconciled and retained');
select is((select request_count from public.codex_task_execution_attempts where task_id=(select task_id from paid_retry_fixture where budget_cap=3.00)),
  3,'the prior provider requests are preserved in attempt history');
select ok(exists(select 1 from public.agent_run_spend_reservations s
    join public.codex_task_executions e on e.reservation_id=s.id
    where e.task_id=(select task_id from paid_retry_fixture where budget_cap=3.00)
      and s.status='reserved'),
  'fresh attempt reserves through the active database model price and spend policy');
select ok(exists(select 1 from public.audit_log where action='codex.automatic_retry_queued'
  and resource_id=(select task_id::text from paid_retry_fixture where budget_cap=3.00)
  and details->>'prior_reservation_preserved'='true'
  and details->>'spending_authority_changed'='false'
  and details->>'merge_release_authority_changed'='false'),
  'automatic retry is audited without adding financial or release authority');

select is((select payload #>> '{automatic_retry,status}' from paid_retry_finish_result r
  join paid_retry_fixture f using(task_id) where f.budget_cap=1.01),'stopped_by_spend_gate',
  'automatic retry stops when the completed usage leaves insufficient initiative budget');
select is((select status from public.tasks where id=(select task_id from paid_retry_fixture where budget_cap=1.01)),
  'blocked','budget denial leaves the task visibly blocked');
select is((select status from public.codex_task_executions where task_id=(select task_id from paid_retry_fixture where budget_cap=1.01)),
  'failed','budget denial preserves the completed failed execution');
select is((select count(*)::integer from public.agent_runs where task_id=(select task_id from paid_retry_fixture where budget_cap=1.01)),
  1,'budget denial does not create an unreserved execution');
select is((select status from public.agent_run_spend_reservations where id=(select reservation_id from paid_retry_fixture where budget_cap=1.01)),
  'reconciled','budget denial does not release or rewrite the failed attempt usage');
select ok(exists(select 1 from public.audit_log where action='codex.automatic_retry_stopped_by_spend_gate'
  and resource_id=(select task_id::text from paid_retry_fixture where budget_cap=1.01)
  and details->>'error_class'='budget_hard_stop'
  and details->>'prior_reservation_preserved'='true'),
  'the blocked automatic retry records a sanitized budget-stop audit event');

select * from finish();
rollback;

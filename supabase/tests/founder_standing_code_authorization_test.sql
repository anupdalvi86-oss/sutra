begin;
select no_plan();

insert into public.company_settings(key,value,founder_only,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'standing-code-test')
on conflict(key) do update set value=excluded.value,founder_only=true,
  governance_sensitive=true,updated_by='standing-code-test';

select throws_ok($$select public.sutra_founder_record_code_authorization('87654321',
  'Founder authorizes code delivery in Sutra repository')$$,
  '42501',null,'non-founder cannot record standing code authority');

create temporary table standing_code_fixture(
  authorization_id uuid,task_id uuid,architect_task_id uuid,project_id uuid,qa_task_id uuid,
  security_task_id uuid,assessed_task_id uuid,assessed_architect_task_id uuid
) on commit drop;
insert into standing_code_fixture(authorization_id)
select (public.sutra_founder_record_code_authorization('12345678',
  'Founder standing approval: Sutra repository code changes, tasks, branches, pull requests, merge, QA, Security, and deployment. No spending authority.')
  ->>'authorization_id')::uuid;

select is((select repository from public.founder_code_authorizations
  where id=(select authorization_id from standing_code_fixture)),
  'anupdalvi86-oss/sutra','authorization is fixed to the Sutra repository');
select is((select capabilities from public.founder_code_authorizations
  where id=(select authorization_id from standing_code_fixture)),
  array['create_developer_tasks','create_branches','open_pull_requests','merge_pull_requests','run_qa','run_security','deploy']::text[],
  'capabilities are fixed and do not include spending');
select ok(public.sutra_has_standing_code_authorization(),'founder authorization is active in the policy layer');
select ok(not (select has_table_privilege('service_role','public.founder_code_authorizations','select')),
  'service_role cannot bypass the audited authorization RPC with direct table reads');

update standing_code_fixture set task_id=(result->>'task_id')::uuid,
  architect_task_id=(result->>'architect_task_id')::uuid,
  project_id=(result->>'project_id')::uuid
from (select public.sutra_founder_create_standing_code_task(
  '12345678','Implement Sutra autonomous code-to-release path',
  'Create the next reviewable implementation stage for Sutra under its founder-granted repository scope. Do not perform paid work under the zero-euro project budget.',
  '["Real repository changes stay within this task scope","Branches and PRs are auditable","QA and Security evidence is recorded","No provider spend is allowed by the EUR 0 budget"]'::jsonb
) as result) created;

select is((select p.budget_amount from public.projects p join standing_code_fixture f on f.project_id=p.id),
  0::numeric,'fresh implementation project has an explicit zero-euro all-in budget');
select is((select p.status from public.projects p join standing_code_fixture f on f.project_id=p.id),
  'active','fresh implementation project is recorded active');
select is((select a.slug from public.tasks t join public.agents a on a.id=t.assigned_agent_id
  join standing_code_fixture f on f.task_id=t.id),'developer','fresh task is assigned to the Developer');
select is((select status from public.tasks where id=(select task_id from standing_code_fixture)),
  'backlog','Developer work remains unavailable until its design is complete');
select is((select status from public.tasks where id=(select architect_task_id from standing_code_fixture)),
  'ready','the Architect task is ready first');
select is((select parent_task_id from public.tasks where id=(select task_id from standing_code_fixture)),
  (select architect_task_id from standing_code_fixture),'Developer task is a child of its Architect design task');
select is((select status from public.approvals where approval_type='developer_scope'
  and action_ref=(select task_id::text from standing_code_fixture)),'approved',
  'task scope approval is recorded through the standing authorization');
select is((select decisions #>> '{standing_authorization,repository}' from public.approvals
  where approval_type='developer_scope' and action_ref=(select task_id::text from standing_code_fixture)),
  'anupdalvi86-oss/sutra','task approval records its authorizing repository grant');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.standing_code_authorization_granted'
  and resource_id=(select authorization_id::text from standing_code_fixture)),
  'founder mandate is recorded in the audit log');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.standing_code_task_created'
  and resource_id=(select task_id::text from standing_code_fixture)),
  'fresh Developer task and zero budget are recorded in the audit log');

-- A founder-approved positive cap may support new task records only after an
-- in-cap assessment. Creating a task must leave both cap and assessment intact.
update public.projects set budget_amount=17.60,budget_currency='EUR',
  requested_budget=17.60,currency='EUR',budget_assessment_status='within_cap',
  budget_assessed_at=now(),budget_assessment=jsonb_build_object(
    'estimated_total_eur',15.97,'recommendation','proceed_within_cap',
    'recommended_action','proceed_within_cap')
where id=(select project_id from standing_code_fixture);
insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
  decisions,amount,currency,summary,status,payload,decided_by,decided_at)
select project_id,'project_budget',project_id::text,'founder:12345678',array['founder'],
  jsonb_build_object('founder',jsonb_build_object('decision','approve','comment','Founder-approved test cap')),
  17.60,'EUR','Founder-approved all-in test cap','approved',
  jsonb_build_object('all_in_budget',17.60,'currency','EUR'),'founder:12345678',now()
from standing_code_fixture;

create temporary table assessed_code_result(payload jsonb) on commit drop;
insert into assessed_code_result
select public.sutra_founder_create_standing_code_task(
  '12345678','Continue work within assessed Sutra budget',
  'Create a Developer task under the existing founder-approved cap and completed within-cap assessment. Do not alter financial authority.',
  '["Task remains within repository authorization","Existing project cap and CFO assessment stay unchanged"]'::jsonb
);
update standing_code_fixture set assessed_task_id=(payload->>'task_id')::uuid
  ,assessed_architect_task_id=(payload->>'architect_task_id')::uuid
from assessed_code_result;
select is((select payload->>'project_budget_eur' from assessed_code_result),
  '17.60','task creation reports the existing assessed all-in cap');
select is((select payload->>'budget_assessment_status' from assessed_code_result),
  'within_cap','task creation reports the completed within-cap assessment');
select is((select budget_amount from public.projects where id=(select project_id from standing_code_fixture)),
  17.60::numeric,'standing-authorized task creation never changes the existing project cap');
select is((select budget_assessment_status from public.projects where id=(select project_id from standing_code_fixture)),
  'within_cap','task creation preserves the completed CFO assessment');
select is((select amount from public.approvals where approval_type='developer_scope'
  and action_ref=(select assessed_task_id::text from standing_code_fixture)),
  0::numeric,'standing code task approval carries no spending amount');
select is((select payload->>'project_all_in_cap_eur' from public.approvals where approval_type='developer_scope'
  and action_ref=(select assessed_task_id::text from standing_code_fixture)),
  '17.60','task scope record snapshots the existing cap');
select is((select payload->>'budget_assessment_status' from public.approvals where approval_type='developer_scope'
  and action_ref=(select assessed_task_id::text from standing_code_fixture)),
  'within_cap','task scope record snapshots the passing assessment');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.standing_code_task_created'
  and resource_id=(select assessed_task_id::text from standing_code_fixture)
  and details->>'project_budget_eur'='17.60'
  and details->>'spending_authority_changed'='false'),
  'task creation under an assessed cap is audit logged without granting spend authority');

select is((select status from public.tasks where id=(select assessed_task_id from standing_code_fixture)),
  'backlog','assessed Developer task waits in backlog behind the Architect');
select is((select status from public.tasks where id=(select assessed_architect_task_id from standing_code_fixture)),
  'ready','assessed initiative can immediately run its Architect task');
insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at)
select architect.id,architect_task.project_id,architect_task.id,'task_artifact','succeeded','{}'::jsonb,
  '{"artifact":{"design":"Use bounded task dispatch with approval and budget checks","components":["database gate","worker"],"security_risks":["stale approval"]}}'::jsonb,
  now(),now()
from public.tasks architect_task join public.agents architect on architect.id=architect_task.assigned_agent_id
where architect_task.id=(select assessed_architect_task_id from standing_code_fixture);
insert into public.task_agent_artifacts(task_id,agent_run_id,agent_id,artifact_type,artifact)
select architect_task.id,run.id,architect.id,'technical_design',
  '{"artifact":{"design":"Use bounded task dispatch with approval and budget checks","components":["database gate","worker"],"security_risks":["stale approval"]}}'::jsonb
from public.tasks architect_task join public.agents architect on architect.id=architect_task.assigned_agent_id
join public.agent_runs run on run.task_id=architect_task.id and run.trigger_type='task_artifact'
where architect_task.id=(select assessed_architect_task_id from standing_code_fixture);
update public.tasks set status='done'
where id=(select assessed_architect_task_id from standing_code_fixture);
select is((select status from public.tasks where id=(select assessed_task_id from standing_code_fixture)),
  'ready','valid Architect design releases the Developer task without another founder prompt');
select is((select status from public.approvals where approval_type='developer_scope'
  and action_ref=(select assessed_task_id::text from standing_code_fixture)),
  'approved','standing founder authorization remains approved after the design handoff');
select ok((select payload #>> '{technical_design,design}' is not null from public.approvals
  where approval_type='developer_scope'
    and action_ref=(select assessed_task_id::text from standing_code_fixture)),
  'the approved Developer scope record carries the exact Architect design');
select ok(exists(select 1 from public.audit_log where action='developer.scope.standing_authorization_applied'
  and resource_id=(select assessed_task_id::text from standing_code_fixture)
  and details->>'technical_design_present'='true'
  and details->>'spending_authority_changed'='false'),
  'design handoff is audited without changing spending authority');

-- Exercise the audited repair for the one stale task that predates the cap.
create temporary table prepare_task_fixture(task_id uuid,architect_task_id uuid) on commit drop;
insert into prepare_task_fixture values(null,null);
insert into public.tasks(project_id,title,description,status,assigned_agent_id,owner_agent_id,priority,
  acceptance_criteria,task_type)
select p.id,'Rebase the untouched pre-cap Developer task',
  'The initiative all-in budget is EUR 0; paid work remains subject to a founder-approved budget.',
  'in_progress',developer.id,developer.id,1,
  '["Keep work within the EUR 0 budget","Preserve the existing scope"]'::jsonb,'engineering'
from public.projects p join public.agents developer on developer.slug='developer'
where p.id=(select project_id from standing_code_fixture);
update prepare_task_fixture set task_id=(select id from public.tasks
  where title='Rebase the untouched pre-cap Developer task' order by created_at desc limit 1);
insert into public.approvals(project_id,approval_type,action_ref,requested_by,required_roles,
  decisions,amount,currency,summary,status,payload,decided_by,decided_at)
select project_id,'developer_scope',id::text,'founder_standing_authorization',array['founder'],
  jsonb_build_object('standing_authorization',jsonb_build_object('authorization_id',
    (select authorization_id from standing_code_fixture),'repository','anupdalvi86-oss/sutra')),
  0,'EUR','Existing founder standing authorization','approved',
  jsonb_build_object('task_id',id,'authorization_id',(select authorization_id from standing_code_fixture)),
  'founder:standing-authorization',now()
from public.tasks where id=(select task_id from prepare_task_fixture);
create temporary table prepare_result(payload jsonb) on commit drop;
insert into prepare_result select public.sutra_founder_prepare_standing_code_task(
  '12345678',(select task_id from prepare_task_fixture),
  'Founder-authorized repair of the untouched task description and required design gate');
update prepare_task_fixture set architect_task_id=(payload->>'architect_task_id')::uuid from prepare_result;
select is((select status from public.tasks where id=(select task_id from prepare_task_fixture)),
  'backlog','audited preparation blocks the old Developer task behind architecture');
select is((select status from public.tasks where id=(select architect_task_id from prepare_task_fixture)),
  'ready','audited preparation creates a ready Architect parent');
select ok((select description like '%EUR 17.60%' and description not like '%EUR 0;%'
  from public.tasks where id=(select task_id from prepare_task_fixture)),
  'audited preparation replaces stale zero-budget wording with the approved cap');
select ok((select acceptance_criteria::text like '%EUR 17.60%'
  from public.tasks where id=(select task_id from prepare_task_fixture)),
  'audited preparation updates the budget criterion');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.standing_code_task_prepared_for_architecture'
  and resource_id=(select task_id::text from prepare_task_fixture)
  and details->>'usage_or_reservations_changed'='false'
  and details->>'spending_authority_changed'='false'),
  'task repair records before/after context without touching usage, reservations, or authority');
select throws_ok(format($q$select public.sutra_founder_prepare_standing_code_task('87654321','%s',
  'Nonfounder must not prepare this standing authorized task')$q$,
  (select task_id from prepare_task_fixture)),'42501',null,
  'nonfounder cannot prepare a standing-authorized task');

update public.projects set budget_assessment_status='unassessed'
where id=(select project_id from standing_code_fixture);
select throws_ok($$select public.sutra_founder_create_standing_code_task('12345678',
  'Reject unassessed budget task','This paid-budget project has no current within-cap assessment.',
  '["No task is created"]'::jsonb)$$,'42501',null,
  'positive budget without a current within-cap assessment cannot receive a new task');
update public.projects set budget_assessment_status='within_cap',legal_hold=true
where id=(select project_id from standing_code_fixture);
select throws_ok($$select public.sutra_founder_create_standing_code_task('12345678',
  'Reject legally held budget task','This assessed initiative is on legal hold.',
  '["No task is created"]'::jsonb)$$,'42501',null,
  'legal hold prevents new standing-authorized tasks');
update public.projects set legal_hold=false
where id=(select project_id from standing_code_fixture);

-- The release pipeline below exercises the Architect-released Developer task.
update standing_code_fixture set task_id=assessed_task_id;

select ok(not (select has_table_privilege('service_role','public.code_release_attempts','select')),
  'service role cannot bypass release authorization through direct table access');
select is(public.sutra_claim_ready_code_release('sutra-worker-release1234')::text,null::text,
  'a standing grant alone cannot claim a merge without CI and independent reviews');

-- A real GitHub issue dispatch moves the Developer task into execution before
-- QA/Security can claim a review against its open PR.
update public.tasks set status='in_progress'
where id=(select task_id from standing_code_fixture);

insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
  owner_agent_id,assigned_agent_id,parent_task_id)
select d.project_id,'Review tested PR acceptance criteria','Run bounded pre-merge QA for this PR.',
  '["Acceptance criteria have evidence","Failures are recorded"]'::jsonb,'engineering','backlog',qa.id,qa.id,d.id
from public.tasks d join public.agents qa on qa.slug='qa'
where d.id=(select task_id from standing_code_fixture)
returning id;

update standing_code_fixture set qa_task_id=(select id from public.tasks
  where title='Review tested PR acceptance criteria' order by created_at desc limit 1);
insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
  owner_agent_id,assigned_agent_id,parent_task_id)
select q.project_id,'Review tested PR security','Run bounded security checks for this PR.',
  '["Security findings have severity and owner","Release blockers are explicit"]'::jsonb,
  'engineering','backlog',sec.id,sec.id,q.id
from public.tasks q join public.agents sec on sec.slug='security'
where q.id=(select qa_task_id from standing_code_fixture)
returning id;
update standing_code_fixture set security_task_id=(select id from public.tasks
  where title='Review tested PR security' order by created_at desc limit 1);

insert into public.github_task_dispatches(task_id,status,attempts,issue_number,issue_url,
  pull_request_number,pull_request_url,pull_request_head_sha,pull_request_merged,
  ci_conclusion,ci_run_url,ci_head_sha)
select task_id,'created',1,41,'https://github.com/anupdalvi86-oss/sutra/issues/41',
  51,'https://github.com/anupdalvi86-oss/sutra/pull/51',repeat('a',40),false,
  'failure','https://github.com/anupdalvi86-oss/sutra/actions/runs/201',repeat('a',40)
from standing_code_fixture;
update public.github_task_dispatches set ci_conclusion='success'
where task_id=(select task_id from standing_code_fixture);
select is((select status from public.tasks where id=(select qa_task_id from standing_code_fixture)),
  'ready','matching successful CI on the open PR releases QA before merge');
select is(public.sutra_claim_ready_code_release('sutra-worker-release1234')::text,null::text,
  'CI alone cannot authorize merge before QA and Security evidence');

create temporary table release_claim(payload jsonb) on commit drop;
insert into release_claim select public.sutra_claim_task_review_agent_run('sutra-worker-qa12345678');
select is((select payload->'task_review'->>'tested_commit_sha' from release_claim),repeat('a',40),
  'pre-merge QA receives the exact open PR head that passed CI');
select lives_ok($$select public.sutra_submit_task_review(
  (select id from public.agents where slug='qa'),
  (select qa_task_id from standing_code_fixture),
  jsonb_build_object('result','pass','summary','Current open PR passed manual acceptance checks',
    'tested_commit_sha',repeat('a',40),
    'acceptance_criteria',jsonb_build_array(
      jsonb_build_object('criterion','Acceptance criteria have evidence','result','pass','evidence_url','https://github.com/anupdalvi86-oss/sutra/pull/51'),
      jsonb_build_object('criterion','Failures are recorded','result','pass','evidence_url','https://github.com/anupdalvi86-oss/sutra/actions/runs/201')),
    'tests',jsonb_build_array(jsonb_build_object('name','acceptance suite','result','pass','evidence_url','https://github.com/anupdalvi86-oss/sutra/actions/runs/201'))))$$,
  'QA evidence for the current open PR can complete before code is merged');
select is((select status from public.tasks where id=(select security_task_id from standing_code_fixture)),
  'ready','QA pass releases Security before merge');
select is(public.sutra_claim_ready_code_release('sutra-worker-release1234')::text,null::text,
  'QA alone cannot authorize merge before Security evidence');
truncate release_claim;
insert into release_claim select public.sutra_claim_task_review_agent_run('sutra-worker-security123');
select is((select payload->'task_review'->>'tested_commit_sha' from release_claim),repeat('a',40),
  'pre-merge Security receives the same CI-tested open PR head');
select lives_ok($$select public.sutra_submit_task_review(
  (select id from public.agents where slug='security'),
  (select security_task_id from standing_code_fixture),
  jsonb_build_object('result','pass','summary','Current open PR has no release blockers',
    'tested_commit_sha',repeat('a',40),
    'acceptance_criteria',jsonb_build_array(
      jsonb_build_object('criterion','Security findings have severity and owner','result','pass','evidence_url','https://github.com/anupdalvi86-oss/sutra/pull/51'),
      jsonb_build_object('criterion','Release blockers are explicit','result','pass','evidence_url','https://github.com/anupdalvi86-oss/sutra/actions/runs/201')),
    'findings','[]'::jsonb,'release_blockers','[]'::jsonb,
    'checks',jsonb_build_array(jsonb_build_object('name','dependency and secret checks','result','pass','evidence_url','https://github.com/anupdalvi86-oss/sutra/actions/runs/201'))))$$,
  'Security evidence for the current open PR can complete before code is merged');

truncate release_claim;
insert into release_claim select public.sutra_claim_ready_code_release('sutra-worker-release1234');
select ok((select payload->>'attempt_id' is not null and payload->>'head_sha'=repeat('a',40)
  from release_claim),'merge claim requires same-SHA passing CI, QA and Security evidence');
select ok(public.sutra_validate_code_release_claim('sutra-worker-release1234',
  (select (payload->>'attempt_id')::uuid from release_claim),
  (select (payload->>'claim_token')::uuid from release_claim)),
  'the live founder grant and all release evidence are rechecked immediately before GitHub write');
select is((public.sutra_finish_code_release('sutra-worker-release1234',
  (select (payload->>'attempt_id')::uuid from release_claim),
  (select (payload->>'claim_token')::uuid from release_claim),'merged',repeat('b',40))->>'status'),
  'merged','successful squash merge result is persisted through the restricted release RPC');
select ok(exists(select 1 from public.audit_log where action='github.code_release_merged'
  and resource_id=(select task_id::text from standing_code_fixture)),
  'automatic merge result is recorded in the audit log');

update public.github_task_dispatches set pull_request_head_sha=repeat('c',40)
where task_id=(select task_id from standing_code_fixture);
select is((select status from public.tasks where id=(select qa_task_id from standing_code_fixture)),
  'blocked','a new PR head invalidates QA evidence for the older commit');
select is((select status from public.tasks where id=(select security_task_id from standing_code_fixture)),
  'backlog','a new PR head invalidates downstream Security and release work');
select is(public.sutra_claim_ready_code_release('sutra-worker-release1234')::text,null::text,
  'old QA and Security evidence cannot authorize a changed PR commit');

select lives_ok($$select public.sutra_founder_revoke_code_authorization('12345678',
  (select authorization_id from standing_code_fixture),'Founder test revocation for policy coverage')$$,
  'configured founder can revoke their standing code authority');
select ok(not public.sutra_has_standing_code_authorization(),'revocation disables standing code authority');
select throws_ok($$select public.sutra_founder_create_standing_code_task('12345678',
  'Another code task after revocation','A valid description that should be rejected because the authority was revoked.',
  '["It remains blocked"]'::jsonb)$$,'42501',null,
  'revoked standing authority cannot create new Developer tasks');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='founder.standing_code_authorization_revoked'
  and resource_id=(select authorization_id::text from standing_code_fixture)),
  'revocation is audit logged');

select * from finish();
rollback;

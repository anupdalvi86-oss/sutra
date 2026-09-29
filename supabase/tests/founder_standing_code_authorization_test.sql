begin;
select no_plan();

insert into public.company_settings(key,value,founder_only,governance_sensitive,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'standing-code-test')
on conflict(key) do update set value=excluded.value,founder_only=true,
  governance_sensitive=true,updated_by='standing-code-test';

select throws_ok($$select public.sutra_founder_record_code_authorization('87654321',
  'Founder authorizes code delivery in Sutra repository')$$,
  '42501',null,'non-founder cannot record standing code authority');

create temporary table standing_code_fixture(authorization_id uuid,task_id uuid,project_id uuid) on commit drop;
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

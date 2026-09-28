begin;
select no_plan();

create temporary table context_fixture(project_id uuid,architect_task_id uuid) on commit drop;
do $$
declare project_id uuid; architect_task_id uuid; pm_task_id uuid;
  cpo_id uuid; pm_id uuid; architect_id uuid;
begin
  select id into cpo_id from public.agents where slug='cpo' and active;
  select id into pm_id from public.agents where slug='product_manager' and active;
  select id into architect_id from public.agents where slug='architect' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('artifact-context-'||gen_random_uuid(),'Context fixture','Approved product discovery project.',
      'approved',500,'EUR','test') returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      500,'EUR','Approved fixture project budget','approved','12345678',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Prior PM plan','Persisted product plan fixture.',
      '["Prior plan is recorded"]'::jsonb,'product','done',pm_id,pm_id)
    returning id into pm_task_id;
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id,parent_task_id)
    values(project_id,'Architecture design','Record interfaces and security assumptions.',
      '["Design is recorded"]'::jsonb,'engineering','ready',architect_id,architect_id,pm_task_id)
    returning id into architect_task_id;
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at,attempt_count)
    values(cpo_id,project_id,null,'founder_proposal','succeeded','{}'::jsonb,
      '{"summary":"CPO evidence assessment.","recommendation":"Carry the cited source into the PM plan.","evidence":[{"source":"CPO source","url":"https://example.com/cpo-source","claim":"Supports the bounded QA discovery hypothesis."}]}'::jsonb,
      now(),now(),1);
  insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at,attempt_count)
    values(pm_id,project_id,pm_task_id,'task_artifact','succeeded','{"role":"product_manager"}'::jsonb,
      '{"summary":"Bounded PM plan.","recommendation":"Proceed to architecture.","evidence":[{"source":"CPO source","url":"https://example.com/cpo-source","claim":"Supports discovery."}],"artifact":{"scope":"Bounded PM scope.","milestones":["Discovery"],"acceptance_criteria":["Record demand"]}}'::jsonb,
      now(),now(),1);
  insert into context_fixture values(project_id,architect_task_id);
end;
$$;

grant select on context_fixture to service_role;
set local role service_role;
create temporary table task_context_claim(payload jsonb) on commit drop;
insert into task_context_claim select public.sutra_claim_task_agent_run('sutra-worker-context123');
reset role;

select is((select payload->'project'->>'status' from task_context_claim),'approved',
  'task claim includes database project status');
select is((select (payload->'project'->>'founder_project_budget_approved')::boolean from task_context_claim),true,
  'task claim includes the persisted founder budget approval');
select ok((select payload->'prior_results' @> '[{"role":"cpo","stage":"founder_proposal"}]'::jsonb from task_context_claim),
  'task claim includes the prior CPO assessment');
select is((select payload->'prior_results'->0->'evidence'->0->>'url' from task_context_claim),
  'https://example.com/cpo-source','prior CPO source evidence remains available to the PM');
select is((select payload->'prior_results'->1->'artifact'->>'scope' from task_context_claim),
  'Bounded PM scope.','architecture claim includes the persisted PM plan');
select ok(exists(select 1 from public.audit_log where action='task_artifact.claimed'
  and resource_id=(select architect_task_id::text from context_fixture)
  and details->>'founder_project_budget_approved'='true'),
  'task claim audit records the approval context supplied to the agent');

select * from finish();
rollback;

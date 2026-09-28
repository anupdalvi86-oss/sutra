begin;
select no_plan();

create temporary table cpo_fixture(task_id uuid,project_id uuid,cpo_id uuid) on commit drop;
do $$
declare project_id uuid; task_id uuid; cpo_id uuid;
begin
  select id into cpo_id from public.agents where slug='cpo' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('cpo-market-research-'||gen_random_uuid(),'CPO research fixture',
      'Internal cited market research for an approved product opportunity.','approved',500,'EUR','test')
    returning id into project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
      amount,currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo','founder'],
      '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
      500,'EUR','Approved fixture budget','approved','test',now());
  insert into public.tasks(project_id,title,description,acceptance_criteria,task_type,status,
      owner_agent_id,assigned_agent_id)
    values(project_id,'Research the product market','Collect cited buyer, competitor, workflow and pricing evidence.',
      '["Cite primary sources","Separate evidence from assumptions","Estimate market and product risks"]'::jsonb,
      'research','ready',cpo_id,cpo_id) returning id into task_id;
  insert into cpo_fixture values(task_id,project_id,cpo_id);
end;
$$;

select is(public.sutra_task_artifact_type('cpo'),'market_research',
  'CPO research has an explicit durable artifact type');
select ok(public.sutra_validate_task_artifact('cpo',
  '{"customer_segments":["Quality-focused teams"],"competitors":["Published competitor evidence"],
    "buyer_workflows":["Teams review quality evidence before releases"],
    "market_gaps":["Willingness to pay remains unverified"],
    "pricing_signals":["A provider publishes its pricing tiers"]}'::jsonb),
  'CPO market research requires the complete bounded artifact contract');
select ok(not public.sutra_validate_task_artifact('cpo',
  '{"customer_segments":[],"competitors":["Published competitor evidence"],
    "buyer_workflows":["Teams review quality evidence before releases"],
    "market_gaps":["Willingness to pay remains unverified"],
    "pricing_signals":["A provider publishes its pricing tiers"]}'::jsonb),
  'CPO market research rejects empty contract sections');

create temporary table cpo_claim(payload jsonb) on commit drop;
grant insert on cpo_claim to service_role;
set local role service_role;
insert into cpo_claim select public.sutra_claim_task_agent_run('sutra-worker-cpo12345678');
reset role;
select is((select payload->'agent'->>'slug' from cpo_claim),'cpo',
  'the approved ready CPO task is claimable by the spend-gated worker');
select is((select payload->'task_artifact'->>'artifact_type' from cpo_claim),'market_research',
  'the CPO claim includes the research artifact contract');
select is((select status from public.tasks where id=(select task_id from cpo_fixture)),'in_progress',
  'claiming CPO research durably advances its task');

select throws_ok($$insert into public.task_agent_artifacts(task_id,agent_run_id,agent_id,artifact_type,artifact)
  select (payload->'task_artifact'->>'task_id')::uuid,(payload->>'run_id')::uuid,
    (payload->'agent'->>'id')::uuid,'market_research',
    '{"summary":"A bounded market research result.","evidence":[]}'::jsonb from cpo_claim$$,
  '23514',null,'CPO market research cannot persist without at least one citation');
select throws_ok($$insert into public.task_agent_artifacts(task_id,agent_run_id,agent_id,artifact_type,artifact)
  select (payload->'task_artifact'->>'task_id')::uuid,(payload->>'run_id')::uuid,
    (payload->'agent'->>'id')::uuid,'market_research',
    '{"summary":"A bounded market research result.","evidence":[{"source":"Unverified source",
      "url":"http://example.com/research","claim":"This source does not use HTTPS."}]}'::jsonb from cpo_claim$$,
  '23514',null,'CPO market research requires a direct HTTPS citation');
select lives_ok($$insert into public.task_agent_artifacts(task_id,agent_run_id,agent_id,artifact_type,artifact)
  select (payload->'task_artifact'->>'task_id')::uuid,(payload->>'run_id')::uuid,
    (payload->'agent'->>'id')::uuid,'market_research',
    '{"summary":"A bounded market research result.","evidence":[{"source":"Primary source",
      "url":"https://example.com/research","claim":"The primary source describes the target workflow."}]}'::jsonb
    from cpo_claim$$,
  'CPO market research persists with bounded HTTPS evidence');
select is((select artifact_type from public.task_agent_artifacts
  where task_id=(select task_id from cpo_fixture)),'market_research',
  'the CPO research artifact remains durably identifiable');

select * from finish();
rollback;

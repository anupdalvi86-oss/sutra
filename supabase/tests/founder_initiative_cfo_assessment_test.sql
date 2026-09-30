begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true;

create temporary table cfo_assessment_fixture on commit drop as
  select gen_random_uuid() as project_id;
insert into public.projects(id,slug,name,description,status,requested_budget,currency,created_by)
  select project_id,'cfo-assess-'||replace(project_id::text,'-',''),'CFO assessment fixture',
    'A bounded implementation initiative for a founder-requested CFO assessment.','active',17.60,'EUR','founder:12345678'
  from cfo_assessment_fixture;

select throws_ok($$select public.sutra_founder_queue_initiative_cfo_assessment(
  '99999999',(select project_id from cfo_assessment_fixture),
  'Estimate all-in costs for this reviewable implementation scope')$$,
  '42501',null,'a non-founder cannot queue an initiative CFO assessment');
select throws_ok($$select public.sutra_founder_queue_initiative_cfo_assessment(
  '12345678',(select project_id from cfo_assessment_fixture),'too short')$$,
  '22023',null,'assessment requests must describe a bounded work scope');
select is((public.sutra_founder_queue_initiative_cfo_assessment(
  '12345678',(select project_id from cfo_assessment_fixture),
  'Estimate all-in costs for this reviewable implementation scope')->>'status'),
  'queued','the configured founder can queue a real CFO-only review');
select is((select a.slug from public.agent_runs r join public.agents a on a.id=r.agent_id
  where r.project_id=(select project_id from cfo_assessment_fixture) and r.trigger_type='founder_proposal'),
  'cfo','the queued review is assigned to the active CFO agent');
select is((select requested_budget from public.projects where id=(select project_id from cfo_assessment_fixture)),
  17.60::numeric,'queuing an assessment never changes the founder-set budget ceiling');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='initiative.cfo_assessment_requested'
  and resource_id=(select project_id::text from cfo_assessment_fixture)),
  'the founder request is recorded in the audit trail');
select throws_ok($$select public.sutra_founder_queue_initiative_cfo_assessment(
  '12345678',(select project_id from cfo_assessment_fixture),
  'Estimate all-in costs for this reviewable implementation scope')$$,
  '23505',null,'the founder cannot queue a duplicate CFO review sequence');

select * from finish();
rollback;

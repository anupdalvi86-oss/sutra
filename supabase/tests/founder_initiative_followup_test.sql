begin;
select no_plan();

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
on conflict(key) do update set value=excluded.value,governance_sensitive=true,
  founder_only=true,updated_by='test';

create temporary table followup_fixture(project_id uuid,unassessed_id uuid,legal_hold_id uuid,pm_id uuid) on commit drop;
grant select on followup_fixture to service_role;
do $$
declare project_id uuid; unassessed_id uuid; legal_hold_id uuid; pm_id uuid;
begin
  select id into pm_id from public.agents where slug='product_manager' and active;
  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('followup-'||gen_random_uuid(),'Follow-up fixture','Test existing initiative work routing.',
      'active',500,'EUR','founder:12345678') returning id into project_id;
  update public.projects set budget_assessment_status='within_cap',budget_assessed_at=now(),
      budget_assessment='{"estimated_total_eur":400,"confidence":"medium","recommended_action":"proceed_within_cap","line_items":[{"category":"development","amount_eur":400,"basis":"Fixture."}]}'::jsonb
    where id=project_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,amount,
      currency,summary,status,decided_by,decided_at)
    values(project_id,'project_budget','founder:test',array['cfo'],
      '{"cfo":{"decision":"approve"}}'::jsonb,500,'EUR','Approved fixture budget','approved','cfo:test',now());
  insert into public.objectives(project_id,title,description,success_metrics,status,owner_agent_id)
    values(project_id,'Pilot delivery','Deliver the approved pilot.','[]'::jsonb,'active',pm_id);

  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('followup-unassessed-'||gen_random_uuid(),'Unassessed fixture','Must not accept follow-up work.',
      'active',500,'EUR','founder:12345678') returning id into unassessed_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,amount,
      currency,summary,status,decided_by,decided_at)
    values(unassessed_id,'project_budget','founder:test',array['cfo'],
      '{"cfo":{"decision":"approve"}}'::jsonb,500,'EUR','Approved but unassessed','approved','cfo:test',now());

  insert into public.projects(slug,name,description,status,requested_budget,currency,created_by)
    values('followup-legal-'||gen_random_uuid(),'Legal hold fixture','Must not accept follow-up work.',
      'active',500,'EUR','founder:12345678') returning id into legal_hold_id;
  update public.projects set legal_hold=true,budget_assessment_status='within_cap',budget_assessed_at=now(),
      budget_assessment='{"estimated_total_eur":400,"confidence":"medium","recommended_action":"proceed_within_cap"}'::jsonb
    where id=legal_hold_id;
  insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,amount,
      currency,summary,status,decided_by,decided_at)
    values(legal_hold_id,'project_budget','founder:test',array['cfo'],
      '{"cfo":{"decision":"approve"}}'::jsonb,500,'EUR','Approved held budget','approved','cfo:test',now());
  insert into followup_fixture values(project_id,unassessed_id,legal_hold_id,pm_id);
end;
$$;

select throws_ok($$select public.sutra_founder_add_initiative_followup('99999999',
  (select project_id from followup_fixture),'Add the reporting workflow for pilot customers')$$,
  '42501',null,'nonfounder cannot add work to an initiative');
select throws_ok($$select public.sutra_founder_add_initiative_followup('12345678',
  (select unassessed_id from followup_fixture),'Add the reporting workflow for pilot customers')$$,
  '23514',null,'an unassessed initiative cannot start follow-up work');
select throws_ok($$select public.sutra_founder_add_initiative_followup('12345678',
  (select legal_hold_id from followup_fixture),'Add the reporting workflow for pilot customers')$$,
  '42501',null,'a legal hold blocks follow-up work even with an assessed budget');

create temporary table followup_result(payload jsonb) on commit drop;
grant insert,select on followup_result to service_role;
set local role service_role;
insert into followup_result select public.sutra_founder_add_initiative_followup('12345678',
  (select project_id from followup_fixture),'Add the reporting workflow for pilot customers');
reset role;

select is((select payload->>'status' from followup_result),'created',
  'founder can add follow-up work to an approved assessed initiative');
select is((select status from public.tasks where id=(select (payload->>'task_id')::uuid from followup_result)),
  'ready','follow-up is durably queued for the Product Manager');
select is((select a.slug from public.tasks t join public.agents a on a.id=t.assigned_agent_id
  where t.id=(select (payload->>'task_id')::uuid from followup_result)),'product_manager',
  'follow-up begins with Product Manager planning');
select is((select requested_budget from public.projects where id=(select project_id from followup_fixture)),
  500::numeric,'follow-up preserves the existing all-in budget');
select is((select payload->>'budget_changed' from followup_result),'false',
  'the response confirms that the budget authority did not change');
select is((select payload->>'spend_reserved' from followup_result),'false',
  'creating a follow-up task makes no cost commitment');
select is((select count(*)::integer from public.initiative_budget_ledger
  where project_id=(select project_id from followup_fixture)),0,
  'follow-up creation does not reserve or record spend');
select ok(exists(select 1 from public.decisions where project_id=(select project_id from followup_fixture)
  and decision_type='founder_initiative_followup'
  and evidence @> jsonb_build_array(jsonb_build_object('task_id',
    (select payload->>'task_id' from followup_result)))),
  'follow-up intent and unchanged budget are recorded as a durable decision');
select ok(exists(select 1 from public.audit_log where actor_type='founder'
  and action='initiative.followup_task_created'
  and resource_id=(select payload->>'task_id' from followup_result)
  and details->>'budget_changed'='false' and details->>'spend_reserved'='false'),
  'follow-up creation is audit logged without granting budget authority');

select * from finish();
rollback;

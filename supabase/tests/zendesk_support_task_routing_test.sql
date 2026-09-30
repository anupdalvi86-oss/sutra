begin;
select no_plan();

select ok(has_function_privilege('service_role',
  'public.sutra_founder_set_zendesk_support_routing(text,uuid,text)','EXECUTE'),
  'the internal founder interface can set Zendesk routing');
select ok(not has_function_privilege('anon',
  'public.sutra_founder_set_zendesk_support_routing(text,uuid,text)','EXECUTE'),
  'anonymous clients cannot set Zendesk routing');
select ok(not has_function_privilege('service_role',
  'public.sutra_route_zendesk_support_case(uuid)','EXECUTE'),
  'the internal routing helper cannot be called as a public RPC');
select ok(has_function_privilege('service_role',
  'public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamp with time zone,boolean)','EXECUTE'),
  'the configured API can explicitly request task routing with the signed metadata event');
select ok(not has_table_privilege('service_role','public.zendesk_support_task_routes','SELECT'),
  'ticket-to-task routing metadata is not directly readable');

insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
  values('founder_telegram_user_id','"12345678"'::jsonb,true,true,'test')
  on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true;
select throws_ok($$select public.sutra_founder_set_zendesk_support_routing(
  '99999999',null,'Stop support ticket routing for this test')$$,'42501',null,
  'only the configured founder can change support routing');
select ok(not (public.sutra_founder_get_zendesk_support_routing('12345678')->>'configured')::boolean,
  'Zendesk task routing is disabled until the founder configures a support initiative');

create temporary table zendesk_routing_fixture on commit drop as
  select gen_random_uuid() as project_id,(select id from public.agents where slug='sales' and active) as sales_id;
insert into public.projects(id,slug,name,description,status,requested_budget,currency,
    budget_assessment_status,budget_assessed_at,budget_assessment)
  select project_id,'support-routing-'||replace(project_id::text,'-',''),'Zendesk routing fixture',
    'Database-only founder-approved support task routing fixture.','active',25,'EUR','within_cap',now(),
    '{"estimated_total_eur":20,"confidence":"high","recommended_action":"proceed_within_cap","line_items":[{"category":"support","amount_eur":20,"basis":"SQL policy test fixture only."}]}'::jsonb
  from zendesk_routing_fixture;
insert into public.approvals(project_id,approval_type,requested_by,required_roles,decisions,
    amount,currency,summary,status,decided_by,decided_at)
  select project_id,'project_budget','founder:12345678',array['cfo','founder'],
    '{"cfo":{"decision":"approve"},"founder":{"decision":"approve"}}'::jsonb,
    25,'EUR','Approved support routing fixture','approved','founder:12345678',now()
  from zendesk_routing_fixture;

select throws_ok($$select public.sutra_founder_set_zendesk_support_routing(
  '12345678',gen_random_uuid(),'Use a nonexistent initiative for support routing')$$,'42501',null,
  'routing cannot target an unknown initiative');
select is((public.sutra_founder_set_zendesk_support_routing(
  '12345678',(select project_id from zendesk_routing_fixture),
  'Route new Zendesk cases to the assessed support initiative')->>'configured')::boolean,
  true,'founder may configure a founder-approved, budget-assessed, legally clear initiative');
select ok(exists(select 1 from public.audit_log where action='support.ticket_routing_configured'
  and resource_id='zendesk_support_project_id'
  and details->>'new_project_id'=(select project_id::text from zendesk_routing_fixture)
  and details ? 'reason'),'support routing changes persist an audit record with a reason');

select ok(not (public.sutra_ingest_zendesk_ticket_event('987651000','open','normal',
  '2026-09-30T08:59:00Z'::timestamptz)->>'routed')::boolean,
  'the legacy metadata-only call cannot start routed agent work');
select is((select count(*)::integer from public.tasks where description like '%Zendesk ticket ID: 987651000%'),0,
  'routing must be explicitly enabled by the configured support-context API path');

create temporary table first_support_event on commit drop as
  select public.sutra_ingest_zendesk_ticket_event('987651001','open','high',
    '2026-09-30T09:00:00Z'::timestamptz,true) as result;
select is(((select result->>'routed' from first_support_event))::boolean,true,
  'a new actionable ticket routes to the founder-selected initiative');
select ok(exists(select 1 from public.zendesk_support_task_routes r
    join public.tasks t on t.id=r.task_id
    where r.support_case_id=(select (result->>'case_id')::uuid from first_support_event)
      and r.project_id=(select project_id from zendesk_routing_fixture)
      and t.owner_agent_id=(select sales_id from zendesk_routing_fixture)
      and t.assigned_agent_id=t.owner_agent_id and t.status='ready'
      and t.description like '%Zendesk ticket ID: 987651001%'
      and t.description not like '%requester%'
      and t.description not like '%customer message body%'),
  'routing creates a durable, privacy-minimized Sales task with exact ticket scope');
select is((select count(*)::integer from public.tasks where project_id=(select project_id from zendesk_routing_fixture)
    and description like '%Zendesk ticket ID: 987651001%'),1,
  'one webhook event creates only one support task');
select is(((public.sutra_ingest_zendesk_ticket_event('987651001','open','high',
    '2026-09-30T09:00:00Z'::timestamptz,true)->>'changed')::boolean,false,
  'a replayed webhook event is a no-op and cannot create a duplicate task');

select is((public.sutra_ingest_zendesk_ticket_event('987651001','pending','high',
    '2026-09-30T09:01:00Z'::timestamptz,true)->>'routing_reason'),'ticket_waiting',
  'a ticket waiting on the customer stops active agent work');
select is((select status from public.tasks where id=(select task_id from public.zendesk_support_task_routes
    where support_case_id=(select (result->>'case_id')::uuid from first_support_event))),'blocked',
  'the assigned task is blocked while Zendesk marks the case pending');
select is((public.sutra_ingest_zendesk_ticket_event('987651001','open','high',
    '2026-09-30T09:02:00Z'::timestamptz,true)->>'routed')::boolean,true,
  'a reopened ticket resumes its same unfinished task');
select is((select count(*)::integer from public.tasks where project_id=(select project_id from zendesk_routing_fixture)
    and description like '%Zendesk ticket ID: 987651001%'),1,
  'reopening without a completed artifact does not fork duplicate tasks');
select is((public.sutra_ingest_zendesk_ticket_event('987651001','closed','high',
    '2026-09-30T09:03:00Z'::timestamptz,true)->>'routing_reason'),'ticket_closed',
  'a closed provider case stops further task execution');
select is((select routing_state from public.zendesk_support_task_routes
  where support_case_id=(select (result->>'case_id')::uuid from first_support_event)),'closed',
  'the route records that the customer ticket is closed');

update public.projects set legal_hold=true where id=(select project_id from zendesk_routing_fixture);
create temporary table held_support_event on commit drop as
  select public.sutra_ingest_zendesk_ticket_event('987651002','open','normal',
    '2026-09-30T09:00:00Z'::timestamptz,true) as result;
select is((select result->>'routing_reason' from held_support_event),'initiative_legal_hold',
  'legal holds prevent incoming support work from starting');
select is((select count(*)::integer from public.tasks where project_id=(select project_id from zendesk_routing_fixture)
    and description like '%Zendesk ticket ID: 987651002%'),0,
  'legal-held ticket metadata does not create an agent task');
update public.projects set legal_hold=false where id=(select project_id from zendesk_routing_fixture);

select is((public.sutra_founder_set_zendesk_support_routing(
  '12345678',null,'Stop routing while support ownership changes')->>'configured')::boolean,
  false,'founder can disable future automatic ticket routing');
create temporary table disabled_support_event on commit drop as
  select public.sutra_ingest_zendesk_ticket_event('987651003','new','normal',
    '2026-09-30T09:00:00Z'::timestamptz,true) as result;
select is((select result->>'routing_reason' from disabled_support_event),'routing_not_configured',
  'disabled routing records ticket state without creating tasks');
select is((select count(*)::integer from public.tasks where project_id=(select project_id from zendesk_routing_fixture)
    and description like '%Zendesk ticket ID: 987651003%'),0,
  'disabling routing leaves new webhook events without agent tasks');
select ok(exists(select 1 from public.audit_log where action='support.ticket_task_routing_skipped'
  and details->>'reason_code'='initiative_legal_hold'),
  'support routing blocks are auditable without storing customer content');

select * from finish();
rollback;

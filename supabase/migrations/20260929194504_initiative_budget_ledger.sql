-- An initiative's requested project budget is its all-in lifetime ceiling.
-- This ledger unifies model reservations and ordinary business commitments by
-- mirroring the already-authoritative expenses rows, including unresolved use.
alter table public.projects
  add column if not exists budget_basis text not null default 'all_in'
    check (budget_basis in ('all_in')),
  add column if not exists budget_assessment jsonb not null default '{}'::jsonb
    check (jsonb_typeof(budget_assessment)='object' and octet_length(budget_assessment::text)<=16000),
  add column if not exists budget_assessed_at timestamptz,
  add column if not exists budget_assessment_status text not null default 'unassessed'
    check (budget_assessment_status in ('unassessed','within_cap','requires_increase','legal_escalation','not_recommended'));

create table if not exists public.initiative_budget_ledger (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete restrict,
  expense_id uuid not null unique references public.expenses(id) on delete restrict,
  category text not null,
  vendor text,
  description text not null,
  currency char(3) not null default 'EUR' check (currency = 'EUR'),
  reserved_amount numeric(14,2) not null check (reserved_amount >= 0),
  actual_amount numeric(14,2) check (actual_amount is null or actual_amount >= 0),
  status text not null check (status in ('reserved','unknown','actual','overrun','released')),
  idempotency_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists initiative_budget_ledger_project_idempotency_idx
  on public.initiative_budget_ledger(project_id,idempotency_key) where idempotency_key is not null;
alter table public.initiative_budget_ledger enable row level security;
revoke all on public.initiative_budget_ledger from public, anon, authenticated, service_role;
grant select on public.initiative_budget_ledger to service_role;
create index if not exists initiative_budget_ledger_project_status_idx
  on public.initiative_budget_ledger(project_id,status,created_at);

create or replace function public.sutra_sync_initiative_budget_ledger()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  reservation_status text;
  old_reserved numeric(14,2);
  ledger_status text;
  ledger_actual numeric(14,2);
  ledger_reserved numeric(14,2);
begin
  if new.project_id is null then return new; end if;

  select s.status into reservation_status
    from public.agent_run_spend_reservations s where s.expense_id=new.id
    order by s.created_at desc limit 1;
  select l.reserved_amount into old_reserved
    from public.initiative_budget_ledger l where l.expense_id=new.id;

  ledger_actual := coalesce(new.actual_amount,case when new.status='paid' then new.amount end);
  ledger_reserved := coalesce(old_reserved,new.amount);
  if reservation_status='unknown' then
    ledger_status := 'unknown';
  elsif new.status in ('rejected','void') then
    ledger_status := 'released';
    ledger_reserved := 0;
  elsif ledger_actual is not null and ledger_actual > ledger_reserved then
    ledger_status := 'overrun';
  elsif ledger_actual is not null then
    ledger_status := 'actual';
  else
    ledger_status := 'reserved';
  end if;

  insert into public.initiative_budget_ledger(
    project_id,expense_id,category,vendor,description,currency,reserved_amount,actual_amount,status,updated_at
  ) values (
    new.project_id,new.id,new.category,new.vendor,new.description,new.currency,
    ledger_reserved,ledger_actual,ledger_status,now()
  ) on conflict (expense_id) do update set
    project_id=excluded.project_id,category=excluded.category,vendor=excluded.vendor,
    description=excluded.description,currency=excluded.currency,
    reserved_amount=case when initiative_budget_ledger.status='released' then excluded.reserved_amount
      else initiative_budget_ledger.reserved_amount end,
    actual_amount=excluded.actual_amount,status=excluded.status,updated_at=now();
  return new;
end;
$$;
revoke all on function public.sutra_sync_initiative_budget_ledger() from public,anon,authenticated,service_role;
drop trigger if exists expenses_sync_initiative_budget_ledger on public.expenses;
create trigger expenses_sync_initiative_budget_ledger
  after insert or update of project_id,category,vendor,description,amount,actual_amount,currency,status
  on public.expenses for each row execute function public.sutra_sync_initiative_budget_ledger();

create or replace function public.sutra_sync_initiative_budget_reservation()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare expense_row public.expenses%rowtype;
begin
  select * into expense_row from public.expenses where id=new.expense_id;
  if not found or expense_row.project_id is null then return new; end if;
  perform public.sutra_sync_initiative_budget_ledger_for_expense(new.expense_id);
  return new;
end;
$$;

-- Keep trigger work in one helper so model reservations and ordinary costs use
-- the same row projection without granting clients access to either table.
create or replace function public.sutra_sync_initiative_budget_ledger_for_expense(p_expense_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare expense_row public.expenses%rowtype; reservation_status text; current_reserved numeric(14,2);
  row_status text; row_actual numeric(14,2);
begin
  select * into expense_row from public.expenses where id=p_expense_id;
  if not found or expense_row.project_id is null then return; end if;
  select s.status into reservation_status from public.agent_run_spend_reservations s
    where s.expense_id=p_expense_id order by s.created_at desc limit 1;
  select l.reserved_amount into current_reserved from public.initiative_budget_ledger l where l.expense_id=p_expense_id;
  current_reserved := coalesce(current_reserved,expense_row.amount);
  row_actual := coalesce(expense_row.actual_amount,case when expense_row.status='paid' then expense_row.amount end);
  if reservation_status='unknown' then row_status:='unknown';
  elsif expense_row.status in ('rejected','void') then row_status:='released'; current_reserved:=0;
  elsif row_actual is not null and row_actual>current_reserved then row_status:='overrun';
  elsif row_actual is not null then row_status:='actual';
  else row_status:='reserved'; end if;
  insert into public.initiative_budget_ledger(project_id,expense_id,category,vendor,description,currency,
    reserved_amount,actual_amount,status,updated_at)
    values(expense_row.project_id,expense_row.id,expense_row.category,expense_row.vendor,expense_row.description,
      expense_row.currency,current_reserved,row_actual,row_status,now())
    on conflict(expense_id) do update set project_id=excluded.project_id,category=excluded.category,
      vendor=excluded.vendor,description=excluded.description,currency=excluded.currency,
      reserved_amount=case when initiative_budget_ledger.status='released' then excluded.reserved_amount
        else initiative_budget_ledger.reserved_amount end,
      actual_amount=excluded.actual_amount,status=excluded.status,updated_at=now();
end;
$$;
revoke all on function public.sutra_sync_initiative_budget_reservation() from public,anon,authenticated,service_role;
revoke all on function public.sutra_sync_initiative_budget_ledger_for_expense(uuid) from public,anon,authenticated,service_role;
drop trigger if exists agent_run_reservations_sync_initiative_budget_ledger on public.agent_run_spend_reservations;
create trigger agent_run_reservations_sync_initiative_budget_ledger
  after insert or update of status,actual_amount on public.agent_run_spend_reservations
  for each row execute function public.sutra_sync_initiative_budget_reservation();

-- Rebuild the view for existing project costs without changing their amounts or
-- reservation states. Unknown provider usage remains held at its full reserve.
select public.sutra_sync_initiative_budget_ledger_for_expense(e.id)
  from public.expenses e where e.project_id is not null;

-- Initial explicit all-in budget is the founder's spending ceiling. CFO review
-- remains mandatory; a routine second founder approval after review is removed.
create or replace function public.sutra_mark_initiative_budget_cfo_only()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.approval_type='project_budget' and new.project_id is not null
    and new.status='pending' and 'founder'=any(new.required_roles) then
    new.required_roles:=array['cfo']::text[];
    new.summary:='CFO assessment of all-in initiative budget: '||left(coalesce(new.summary,''),450);
    new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
      'approval_meaning','financial_review_only','founder_authorized_all_in_cap',new.amount);
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_mark_initiative_budget_cfo_only() from public,anon,authenticated,service_role;
drop trigger if exists approvals_mark_initiative_budget_cfo_only on public.approvals;
create trigger approvals_mark_initiative_budget_cfo_only
  before insert on public.approvals for each row execute function public.sutra_mark_initiative_budget_cfo_only();

alter function public.sutra_submit_proposal(text,text,text,numeric,char)
  rename to sutra_submit_proposal_legacy;
create function public.sutra_submit_proposal(
  p_founder_telegram_user_id text,p_name text,p_description text,p_requested_budget numeric,
  p_currency char(3) default 'EUR'
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
  result:=public.sutra_submit_proposal_legacy(
    p_founder_telegram_user_id,p_name,p_description,p_requested_budget,p_currency);
  return jsonb_set(result,'{status}',to_jsonb('pending_financial_review'::text),true);
end;
$$;
revoke all on function public.sutra_submit_proposal_legacy(text,text,text,numeric,char) from public,anon,authenticated;
revoke all on function public.sutra_submit_proposal(text,text,text,numeric,char) from public,anon,authenticated;
grant execute on function public.sutra_submit_proposal(text,text,text,numeric,char) to service_role;

create or replace function public.sutra_record_cfo_budget_assessment()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare estimate jsonb; line_item jsonb; total numeric(14,2); cap numeric(14,2); line_total numeric(14,2);
  recommendation text;
begin
  if new.status<>'succeeded' or old.status is not distinct from new.status or new.trigger_type<>'founder_proposal'
    or not exists(select 1 from public.agents a where a.id=new.agent_id and a.slug='cfo') then
    return new;
  end if;
  estimate:=new.output->'budget_estimate';
  if jsonb_typeof(estimate) is distinct from 'object'
    or jsonb_typeof(estimate->'estimated_total_eur') is distinct from 'number'
    or jsonb_typeof(estimate->'line_items') is distinct from 'array' then
    raise exception 'CFO budget estimate is malformed' using errcode='22023';
  end if;
  if jsonb_array_length(estimate->'line_items') not between 1 and 10
    or estimate->>'recommended_action' is null
    or estimate->>'recommended_action' not in ('proceed_within_cap','request_budget_increase','do_not_proceed','legal_escalation')
    or estimate->>'confidence' is null or estimate->>'confidence' not in ('low','medium','high') then
    raise exception 'CFO budget estimate is malformed' using errcode='22023';
  end if;
  for line_item in select value from jsonb_array_elements(estimate->'line_items') loop
    if jsonb_typeof(line_item) is distinct from 'object' then
      raise exception 'CFO budget estimate line item is malformed' using errcode='22023';
    end if;
    if line_item->>'category' is null
      or line_item->>'category' not in ('ai_model_usage','development','tools','infrastructure','hosting','marketing_ads','operations','contingency','other')
      or jsonb_typeof(line_item->'amount_eur') is distinct from 'number'
      or jsonb_typeof(line_item->'basis') is distinct from 'string' then
      raise exception 'CFO budget estimate line item is malformed' using errcode='22023';
    end if;
    if (line_item->>'amount_eur')::numeric<0
      or length(trim(line_item->>'basis')) not between 8 and 500 then
      raise exception 'CFO budget estimate line item is malformed' using errcode='22023';
    end if;
  end loop;
  select coalesce(sum((value->>'amount_eur')::numeric),0) into line_total
    from jsonb_array_elements(estimate->'line_items');
  total:=(estimate->>'estimated_total_eur')::numeric;
  if total<0 or total>999999999999.99 or abs(total-line_total)>0.01 then
    raise exception 'CFO budget estimate total must match its all-in cost breakdown' using errcode='22023';
  end if;
  select requested_budget into cap from public.projects where id=new.project_id for update;
  if not found or cap<=0 then raise exception 'CFO assessment requires an explicit initiative budget' using errcode='23514'; end if;
  recommendation:=estimate->>'recommended_action';
  if total>cap and recommendation not in ('request_budget_increase','do_not_proceed','legal_escalation') then
    raise exception 'CFO must recommend a higher budget or stop when all-in estimate exceeds cap' using errcode='23514';
  end if;
  if total<=cap and recommendation='request_budget_increase' then
    raise exception 'CFO cannot request a budget increase when the estimate fits the current cap' using errcode='23514';
  end if;
  update public.projects set budget_assessment=estimate,budget_assessed_at=now(),
    budget_assessment_status=case
      when recommendation='request_budget_increase' then 'requires_increase'
      when recommendation='legal_escalation' then 'legal_escalation'
      when recommendation='do_not_proceed' or new.output->>'decision'='reject' then 'not_recommended'
      else 'within_cap' end
    where id=new.project_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',(select slug from public.agents where id=new.agent_id),'initiative.budget_assessed','project',new.project_id::text,
      jsonb_build_object('estimated_total_eur',total,'cap_eur',cap,'recommendation',recommendation,
        'confidence',estimate->>'confidence','line_item_count',jsonb_array_length(estimate->'line_items')));
  if recommendation in ('request_budget_increase','legal_escalation','do_not_proceed')
      or new.output->>'decision'='reject' or total>cap then
    update public.projects set status='paused',updated_at=now() where id=new.project_id;
    update public.agent_runs set status='blocked',finished_at=now(),lease_token=null,lease_expires_at=null,
      output=coalesce(output,'{}'::jsonb)||jsonb_build_object('blocked_by',
        case when recommendation='legal_escalation' then 'legal_escalation'
          when recommendation='request_budget_increase' or total>cap then 'initiative_budget_increase'
          else 'cfo_not_recommended' end)
      where project_id=new.project_id and trigger_type='founder_proposal' and run_order>new.run_order and status='queued';
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra',case
        when recommendation='legal_escalation' then 'initiative.legal_escalation'
        when recommendation='request_budget_increase' or total>cap then 'initiative.budget_increase_required'
        else 'initiative.not_recommended' end,'project',new.project_id::text,
        jsonb_build_object('estimated_total_eur',total,'founder_all_in_cap',cap,
          'estimated_gap',greatest(total-cap,0),'recommendation',recommendation,
          'cfo_reason',left(coalesce(new.output->>'decision_rationale',''),1000)));
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_record_cfo_budget_assessment() from public,anon,authenticated,service_role;
drop trigger if exists agent_runs_record_cfo_budget_assessment on public.agent_runs;
create trigger agent_runs_record_cfo_budget_assessment
  after update of status on public.agent_runs for each row execute function public.sutra_record_cfo_budget_assessment();

create or replace function public.sutra_guard_project_budget_founder_approval()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare cfo_approved boolean; all_reviews_complete boolean;
begin
  if new.status='approved' and old.status is distinct from new.status
    and new.approval_type='project_budget' and new.project_id is not null then
    select coalesce(new.decisions #>> '{cfo,decision}'='approve',false) into cfo_approved;
    select count(*)=5 into all_reviews_complete from public.agent_runs r
      where r.project_id=new.project_id and r.trigger_type='founder_proposal'
        and r.run_order between 1 and 5 and r.status='succeeded';
    if not cfo_approved or ('founder'=any(new.required_roles) and not all_reviews_complete) then
      raise exception 'project budget approval requires an affirmative CFO assessment and the completed review sequence when founder approval is required' using errcode='42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists approvals_guard_project_budget_founder_approval on public.approvals;
create trigger approvals_guard_project_budget_founder_approval
  before update of status on public.approvals for each row execute function public.sutra_guard_project_budget_founder_approval();

create or replace function public.sutra_keep_budget_review_open_until_pm()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.approval_type='project_budget' and new.status='approved' and old.status='pending'
    and 'founder'<>all(new.required_roles) and coalesce(new.decisions #>> '{cfo,decision}','')='approve'
    and not (new.decisions ? 'product_manager') then
    update public.approvals set status='pending',decided_by=null,decided_at=null where id=new.id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','initiative.cfo_review_complete_pm_review_pending','approval',new.id::text,
        jsonb_build_object('project_id',new.project_id,'cfo_decision','approve'));
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_keep_budget_review_open_until_pm() from public,anon,authenticated,service_role;
drop trigger if exists approvals_keep_budget_review_open_until_pm on public.approvals;
create trigger approvals_keep_budget_review_open_until_pm
  after update of status on public.approvals for each row execute function public.sutra_keep_budget_review_open_until_pm();

create or replace function public.sutra_activate_budgeted_initiative(p_project_id uuid,p_actor text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare project_row public.projects%rowtype; objective_id uuid; pm_id uuid; first_task_id uuid;
  previous_task_id uuid; stage record;
begin
  select * into project_row from public.projects where id=p_project_id for update;
  if not found or project_row.budget_assessment_status<>'within_cap'
    or project_row.budget_assessment->>'recommended_action'<>'proceed_within_cap'
    or (project_row.budget_assessment->>'estimated_total_eur')::numeric>project_row.requested_budget
    or not exists(select 1 from public.approvals ap where ap.project_id=p_project_id
      and ap.approval_type='project_budget' and ap.status='approved'
      and ap.decisions #>> '{cfo,decision}'='approve')
    or (select count(*) from public.agent_runs r where r.project_id=p_project_id
      and r.trigger_type='founder_proposal' and r.run_order between 1 and 5 and r.status='succeeded')<>5 then
    return jsonb_build_object('status','not_ready');
  end if;
  if exists(select 1 from public.tasks t where t.project_id=p_project_id
      and t.title='Create approved product requirements and implementation plan') then
    return jsonb_build_object('status','already_activated');
  end if;
  update public.projects set status='approved',updated_at=now() where id=p_project_id;
  update public.tasks set status='ready',updated_at=now() where project_id=p_project_id and status='blocked';
  select id into objective_id from public.objectives where project_id=p_project_id and status='proposed' order by created_at limit 1;
  update public.objectives set status='active' where id=objective_id;
  select id into pm_id from public.agents where slug='product_manager' and active;
  insert into public.tasks(project_id,objective_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
    values(p_project_id,objective_id,'Create approved product requirements and implementation plan',
      'Convert the reviewed proposal into product requirements and engineering-ready tasks within the founder-set all-in cap.',
      '["CFO estimate is within the founder-set all-in cap","Requirements and acceptance criteria are recorded","Engineering work is split into reviewable tasks"]'::jsonb,
      'product','ready',pm_id,pm_id) returning id into first_task_id;
  previous_task_id:=first_task_id;
  for stage in select * from (values
    ('Produce architecture and technical design','Record interfaces, data flow, deployment topology and technical risks.','["Design is recorded and linked to the project","Security assumptions are stated"]'::jsonb,'architect'),
    ('Implement approved product tasks','Create a branch and reviewable pull request for the approved scope.','["Changes map to approved tasks","No secrets are committed","Pull request is reviewable"]'::jsonb,'developer'),
    ('Verify acceptance criteria','Run and record reproducible automated and manual test results.','["Acceptance criteria have evidence","Failures are recorded"]'::jsonb,'qa'),
    ('Review security and dependencies','Record threat, dependency and data-handling findings.','["Security findings have severity and owner","Release blockers are explicit"]'::jsonb,'security'),
    ('Prepare release and rollback','Verify health checks, recovery path and release readiness.','["Deployment is repeatable","Rollback steps are documented"]'::jsonb,'devops'),
    ('Prepare marketing launch proposal','Draft positioning and a budgeted campaign plan.','["Audience, claims and budget are reviewed","External activity stays within the initiative budget"]'::jsonb,'cmo'),
    ('Prepare sales handoff','Create lead qualification and sales materials.','["Lead criteria and materials are recorded","Customer contact follows company policy"]'::jsonb,'sales')
  ) as stages(title,description,acceptance_criteria,owner_slug)
  loop
    insert into public.tasks(project_id,objective_id,parent_task_id,title,description,acceptance_criteria,task_type,status,owner_agent_id,assigned_agent_id)
      select p_project_id,objective_id,previous_task_id,stage.title,stage.description,stage.acceptance_criteria,
        'engineering','backlog',a.id,a.id from public.agents a where a.slug=stage.owner_slug and a.active
      returning id into previous_task_id;
  end loop;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system','sutra','initiative.activated_within_budget','project',p_project_id::text,
      jsonb_build_object('activation_actor',left(p_actor,120),'budget',project_row.requested_budget,
        'estimated_total',project_row.budget_assessment->>'estimated_total_eur','first_task_id',first_task_id));
  return jsonb_build_object('status','approved','project_id',p_project_id,'first_task_id',first_task_id);
end;
$$;
revoke all on function public.sutra_activate_budgeted_initiative(uuid,text) from public,anon,authenticated,service_role;

create or replace function public.sutra_finish_initiative_budget_review()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare project_row public.projects%rowtype; estimate_total numeric(14,2); recommendation text;
begin
  if new.status<>'succeeded' or old.status is not distinct from new.status or new.trigger_type<>'founder_proposal'
    or new.run_order<>5 or not exists(select 1 from public.agents a where a.id=new.agent_id and a.slug='product_manager') then
    return new;
  end if;
  select * into project_row from public.projects where id=new.project_id for update;
  estimate_total:=(project_row.budget_assessment->>'estimated_total_eur')::numeric;
  recommendation:=project_row.budget_assessment->>'recommended_action';
  if project_row.budget_assessment_status in ('legal_escalation','not_recommended') or recommendation in ('do_not_proceed','legal_escalation') then
    update public.projects set status='paused',updated_at=now() where id=project_row.id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra',case when recommendation='legal_escalation' then 'initiative.legal_escalation' else 'initiative.not_recommended' end,
        'project',project_row.id::text,jsonb_build_object('estimated_total_eur',estimate_total,
          'founder_all_in_cap',project_row.requested_budget,'cfo_summary',left(coalesce((select output->>'decision_rationale'
            from public.agent_runs r where r.id=(select id from public.agent_runs where project_id=project_row.id
              and trigger_type='founder_proposal' and run_order=4 order by created_at desc limit 1)),''),1000)));
    return new;
  end if;
  if project_row.budget_assessment_status='requires_increase' or estimate_total>project_row.requested_budget then
    update public.projects set status='paused',budget_assessment_status='requires_increase',updated_at=now()
      where id=project_row.id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','initiative.budget_increase_required','project',project_row.id::text,
        jsonb_build_object('recommended_all_in_budget',estimate_total,'founder_all_in_cap',project_row.requested_budget,
          'estimated_gap',greatest(estimate_total-project_row.requested_budget,0)));
    return new;
  end if;
  update public.projects set budget_assessment_status='within_cap' where id=project_row.id;
  update public.approvals set status='approved',decided_by='initiative:product_manager',decided_at=now(),
    decisions=decisions||jsonb_build_object('product_manager',jsonb_build_object(
      'decision','approve','actor_id',new.agent_id::text,'comment','PM review completed within the founder-set all-in budget'))
    where project_id=project_row.id and approval_type='project_budget' and status='pending'
      and coalesce(decisions #>> '{cfo,decision}','')='approve';
  perform public.sutra_activate_budgeted_initiative(project_row.id,'automatic after CFO and PM review');
  return new;
end;
$$;
revoke all on function public.sutra_finish_initiative_budget_review() from public,anon,authenticated,service_role;
drop trigger if exists agent_runs_finish_initiative_budget_review on public.agent_runs;
create trigger agent_runs_finish_initiative_budget_review
  after update of status on public.agent_runs for each row execute function public.sutra_finish_initiative_budget_review();

create or replace function public.sutra_authorize_initiative_cost(
  p_actor_type text,p_actor_id text,p_agent_id uuid,p_project_id uuid,
  p_category text,p_vendor text,p_description text,p_amount numeric,
  p_currency char(3),p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare project_row public.projects%rowtype; founder_id text; existing public.initiative_budget_ledger%rowtype;
  current_commitment numeric(14,2); created_expense_id uuid; ledger_id uuid; warning_percent numeric(5,2);
  policy_row public.spending_policies%rowtype; budget_row public.budgets%rowtype;
  actual_department_id uuid; used_amount numeric(14,2); budget_warnings text[]:=array[]::text[];
begin
  if p_actor_type is null or p_actor_type not in ('founder','agent','system')
    or p_actor_id is null or length(trim(p_actor_id)) not between 1 and 120
    or p_project_id is null or p_category is null or length(trim(p_category)) not between 1 and 80
    or p_vendor is not null and length(p_vendor)>200
    or p_description is null or length(trim(p_description)) not between 2 and 1000
    or p_amount is null or p_amount<=0 or p_amount>999999999999.99
    or p_amount::text in ('NaN','Infinity','-Infinity') or p_currency is null or p_currency<>'EUR'
    or p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$' then
    raise exception 'malformed initiative cost request' using errcode='22023';
  end if;
  if p_actor_type='founder' then
    select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
    if founder_id is null or founder_id<>p_actor_id or p_agent_id is not null then
      raise exception 'only the configured founder may act as founder' using errcode='42501';
    end if;
  elsif p_actor_type='agent' then
    if p_agent_id is null or not exists(select 1 from public.agents a
      where a.id=p_agent_id and a.slug=p_actor_id and a.active) then
      raise exception 'agent identity is invalid or inactive' using errcode='42501';
    end if;
  elsif p_agent_id is not null then
    raise exception 'system requests cannot name an agent' using errcode='42501';
  elsif p_actor_type='system' and p_actor_id<>'sutra'
    and p_actor_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'system actor identity is invalid' using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||p_project_id::text));
  select * into project_row from public.projects p where p.id=p_project_id for update;
  if not found or project_row.status not in ('approved','active') then
    raise exception 'initiative is not active for operating costs' using errcode='42501';
  end if;
  if project_row.currency<>p_currency or project_row.requested_budget<=0 then
    raise exception 'initiative has no explicit all-in budget in the requested currency' using errcode='23514';
  end if;
  if p_actor_type='agent' and not exists(select 1 from public.tasks t
      where t.project_id=p_project_id and t.owner_agent_id=p_agent_id and t.assigned_agent_id=p_agent_id
        and t.status in ('ready','in_progress','review')) then
    raise exception 'agent cost requires an active task assignment in this initiative' using errcode='42501';
  end if;

  select l.* into existing from public.initiative_budget_ledger l
    where l.project_id=p_project_id and l.idempotency_key=p_idempotency_key limit 1;
  if found then
    if existing.category<>lower(trim(p_category))
      or coalesce(existing.vendor,'')<>coalesce(nullif(trim(p_vendor),''),'')
      or existing.description<>trim(p_description)
      or existing.reserved_amount<>p_amount
      or not exists(select 1 from public.expenses e where e.id=existing.expense_id and e.requested_by=p_actor_id) then
      raise exception 'initiative cost idempotency key was reused for a different request' using errcode='23505';
    end if;
    return jsonb_build_object('status','already_reserved','ledger_id',existing.id,
      'expense_id',existing.expense_id,'reserved_amount',existing.reserved_amount,
      'actual_amount',existing.actual_amount,'remaining_budget',greatest(0,project_row.requested_budget-
        coalesce((select sum(case when l.status in ('reserved','unknown') then l.reserved_amount
          when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end)
          from public.initiative_budget_ledger l
          where l.project_id=p_project_id and l.status in ('reserved','unknown','actual','overrun')),0)));
  end if;

  -- A founder-approved, assessed initiative budget delegates ordinary costs
  -- inside that cap. Keep every configured hard budget and warning in force;
  -- transaction approval bands do not re-open routine approval requests.
  actual_department_id:=project_row.department_id;
  select * into policy_row from public.spending_policies p
    where p.active and p.currency=p_currency
      and (p_amount>p.min_amount or (p.min_inclusive and p_amount=p.min_amount))
      and (p.max_amount is null or p_amount<p.max_amount or (p.max_inclusive and p_amount=p.max_amount))
    order by p.min_amount desc limit 1;
  if not found then raise exception 'no active spending policy matches this amount' using errcode='23514'; end if;
  if policy_row.per_transaction_limit is not null and p_amount>policy_row.per_transaction_limit then
    raise exception 'spending policy per-transaction hard stop exceeded' using errcode='23514';
  end if;
  if policy_row.daily_limit is not null then
    select coalesce(sum(e.amount),0) into used_amount from public.expenses e
      where e.status in ('requested','approved','paid') and e.currency=p_currency
        and e.created_at>=date_trunc('day',now());
    if used_amount+p_amount>policy_row.daily_limit then
      raise exception 'spending policy daily hard stop exceeded' using errcode='23514';
    end if;
  end if;
  if policy_row.monthly_limit is not null then
    select coalesce(sum(e.amount),0) into used_amount from public.expenses e
      where e.status in ('requested','approved','paid') and e.currency=p_currency
        and e.created_at>=date_trunc('month',now());
    if used_amount+p_amount>policy_row.monthly_limit then
      raise exception 'spending policy monthly hard stop exceeded' using errcode='23514';
    end if;
  end if;

  for budget_row in select * from public.budgets b where b.active and b.currency=p_currency
    and ((b.scope='company' and b.scope_key='*')
      or (b.scope='project' and b.scope_key in ('*',p_project_id::text))
      or (b.scope='department' and b.scope_key in ('*',coalesce(actual_department_id::text,'')))
      or (b.scope='agent' and b.scope_key in ('*',coalesce(p_actor_id,'')))
      or (b.scope='category' and (b.scope_key='*' or lower(b.scope_key)=lower(p_category)))
      or (b.scope='vendor' and (b.scope_key='*' or lower(b.scope_key)=lower(coalesce(p_vendor,'')))))
    order by b.scope,b.scope_key,b.period for update
  loop
    if budget_row.limit_amount is null then continue; end if;
    if budget_row.period='transaction' then
      used_amount:=0;
    elsif budget_row.period='daily' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.status in ('requested','approved','paid') and e.currency=p_currency
          and e.created_at>=date_trunc('day',now())
          and (budget_row.scope<>'project' or e.project_id=p_project_id)
          and (budget_row.scope<>'department' or budget_row.scope_key='*' or e.department_id=budget_row.scope_key::uuid)
          and (budget_row.scope<>'agent' or e.agent_id=p_agent_id)
          and (budget_row.scope<>'category' or lower(e.category)=lower(p_category))
          and (budget_row.scope<>'vendor' or lower(coalesce(e.vendor,''))=lower(coalesce(p_vendor,'')));
    elsif budget_row.period='monthly' then
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.status in ('requested','approved','paid') and e.currency=p_currency
          and e.created_at>=date_trunc('month',now())
          and (budget_row.scope<>'project' or e.project_id=p_project_id)
          and (budget_row.scope<>'department' or budget_row.scope_key='*' or e.department_id=budget_row.scope_key::uuid)
          and (budget_row.scope<>'agent' or e.agent_id=p_agent_id)
          and (budget_row.scope<>'category' or lower(e.category)=lower(p_category))
          and (budget_row.scope<>'vendor' or lower(coalesce(e.vendor,''))=lower(coalesce(p_vendor,'')));
    else
      select coalesce(sum(e.amount),0) into used_amount from public.expenses e
        where e.status in ('requested','approved','paid') and e.currency=p_currency
          and (budget_row.scope<>'project' or e.project_id=p_project_id)
          and (budget_row.scope<>'department' or budget_row.scope_key='*' or e.department_id=budget_row.scope_key::uuid)
          and (budget_row.scope<>'agent' or e.agent_id=p_agent_id)
          and (budget_row.scope<>'category' or lower(e.category)=lower(p_category))
          and (budget_row.scope<>'vendor' or lower(coalesce(e.vendor,''))=lower(coalesce(p_vendor,'')));
    end if;
    if used_amount+p_amount>budget_row.limit_amount and budget_row.hard_stop then
      raise exception 'budget hard stop: % % budget exceeded',budget_row.scope,budget_row.scope_key using errcode='23514';
    end if;
    if used_amount+p_amount>=budget_row.limit_amount*budget_row.warning_percent/100 then
      budget_warnings:=array_append(budget_warnings,budget_row.scope||':'||budget_row.scope_key);
    end if;
  end loop;

  select coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
    when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end),0) into current_commitment
    from public.initiative_budget_ledger l where l.project_id=p_project_id
      and l.status in ('reserved','unknown','actual','overrun');
  if current_commitment+p_amount>project_row.requested_budget then
    raise exception 'initiative all-in budget hard stop: request requires founder budget change' using errcode='23514';
  end if;
  select coalesce(max(b.warning_percent),80) into warning_percent from public.budgets b
    where b.active and b.scope='project' and b.scope_key in ('*',p_project_id::text)
      and b.period='lifetime' and b.currency=p_currency;
  insert into public.expenses(project_id,department_id,agent_id,category,vendor,description,amount,currency,
    status,requested_by,approved_at)
    values(p_project_id,project_row.department_id,p_agent_id,lower(trim(p_category)),nullif(trim(p_vendor),''),
      trim(p_description),p_amount,p_currency,'approved',p_actor_id,now())
    returning id into created_expense_id;
  update public.initiative_budget_ledger set idempotency_key=p_idempotency_key
    where initiative_budget_ledger.expense_id=created_expense_id;
  select id into ledger_id from public.initiative_budget_ledger where initiative_budget_ledger.expense_id=created_expense_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values(p_actor_type,p_actor_id,'initiative.cost_reserved','initiative_budget_ledger',ledger_id::text,
      jsonb_build_object('project_id',p_project_id,'expense_id',created_expense_id,'category',lower(trim(p_category)),
        'vendor',nullif(trim(p_vendor),''),'amount',p_amount,'currency',p_currency,
        'all_in_budget',project_row.requested_budget,'committed_before',current_commitment,
        'warning_threshold',warning_percent,'budget_warnings',to_jsonb(budget_warnings)));
  return jsonb_build_object('status','reserved','ledger_id',ledger_id,'expense_id',created_expense_id,
    'reserved_amount',p_amount,'actual_amount',null,
    'remaining_budget',project_row.requested_budget-current_commitment-p_amount,
    'warning',current_commitment+p_amount>=project_row.requested_budget*warning_percent/100,
    'budget_warnings',to_jsonb(budget_warnings));
end;
$$;

create or replace function public.sutra_settle_initiative_cost(
  p_actor_id text,p_ledger_id uuid,p_actual_amount numeric,p_usage_known boolean
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare entry public.initiative_budget_ledger%rowtype; project_row public.projects%rowtype; new_status text;
begin
  if p_actor_id is null or p_ledger_id is null or p_usage_known is null
    or (p_usage_known and (p_actual_amount is null or p_actual_amount<0 or p_actual_amount>999999999999.99
      or p_actual_amount::text in ('NaN','Infinity','-Infinity'))) then
    raise exception 'malformed initiative cost settlement' using errcode='22023';
  end if;
  select * into entry from public.initiative_budget_ledger l where l.id=p_ledger_id for update;
  if not found or entry.status not in ('reserved','unknown') then
    raise exception 'initiative reservation is not open for settlement' using errcode='42501';
  end if;
  select * into project_row from public.projects where id=entry.project_id for update;
  if p_actor_id<>'sutra' and p_actor_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'settlement actor identity is invalid' using errcode='42501';
  end if;
  if not p_usage_known then
    update public.initiative_budget_ledger set status='unknown',updated_at=now() where id=entry.id;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',left(p_actor_id,120),'initiative.cost_unknown','initiative_budget_ledger',entry.id::text,
        jsonb_build_object('project_id',entry.project_id,'reserved_amount',entry.reserved_amount));
    return jsonb_build_object('status','unknown','reserved_amount',entry.reserved_amount,'actual_amount',null);
  end if;
  new_status:=case when p_actual_amount>entry.reserved_amount then 'overrun' else 'actual' end;
  update public.initiative_budget_ledger set status=new_status,actual_amount=p_actual_amount,updated_at=now()
    where id=entry.id;
  update public.expenses set actual_amount=p_actual_amount,
    amount=greatest(p_actual_amount,0.01),status=case when p_actual_amount=0 then 'void' else 'paid' end,
    incurred_at=case when p_actual_amount=0 then null else now() end where id=entry.expense_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_actor_id,120),'initiative.cost_'||new_status,'initiative_budget_ledger',entry.id::text,
      jsonb_build_object('project_id',entry.project_id,'reserved_amount',entry.reserved_amount,
        'actual_amount',p_actual_amount,'all_in_budget',project_row.requested_budget));
  if new_status='overrun' then
    update public.projects set status='paused',updated_at=now() where id=entry.project_id;
  end if;
  return jsonb_build_object('status',new_status,'reserved_amount',entry.reserved_amount,'actual_amount',p_actual_amount);
end;
$$;

create or replace function public.sutra_founder_set_project_budget(
  p_founder_telegram_user_id text,p_project_id uuid,p_new_budget numeric,p_reason text
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare founder_id text; project_row public.projects%rowtype; committed numeric(14,2); activation jsonb;
begin
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder may change an initiative budget' using errcode='42501';
  end if;
  if p_project_id is null or p_new_budget is null or p_new_budget<=0 or p_new_budget>999999999999.99
    or p_new_budget::text in ('NaN','Infinity','-Infinity')
    or p_reason is null or length(trim(p_reason)) not between 8 and 500 then
    raise exception 'malformed initiative budget change' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||p_project_id::text));
  select * into project_row from public.projects where id=p_project_id for update;
  if not found or project_row.status not in ('proposed','approved','active','paused') then
    raise exception 'initiative budget is not changeable in its current state' using errcode='42501';
  end if;
  select coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
    when l.status in ('actual','overrun') then coalesce(l.actual_amount,0) else 0 end),0) into committed
    from public.initiative_budget_ledger l where l.project_id=p_project_id
      and l.status in ('reserved','unknown','actual','overrun');
  if p_new_budget<committed then
    raise exception 'new budget cannot be lower than actual, reserved, or unknown costs' using errcode='23514';
  end if;
  if p_new_budget=project_row.requested_budget then
    return jsonb_build_object('project_id',p_project_id,'old_budget',project_row.requested_budget,
      'new_budget',p_new_budget,'committed',committed,'remaining_budget',p_new_budget-committed,
      'changed',false);
  end if;
  update public.projects set requested_budget=p_new_budget,budget_amount=p_new_budget,
    updated_at=now() where id=p_project_id;
  update public.budgets set limit_amount=p_new_budget where scope='project'
    and scope_key=p_project_id::text and period='lifetime' and currency=project_row.currency;
  update public.approvals set amount=p_new_budget,
    payload=coalesce(payload,'{}'::jsonb)||jsonb_build_object('requested_budget',p_new_budget)
    where project_id=p_project_id and approval_type='project_budget' and status='pending';
  if project_row.budget_assessment_status='requires_increase'
    and project_row.budget_assessment->>'recommended_action'='request_budget_increase'
    and (project_row.budget_assessment->>'estimated_total_eur')::numeric<=p_new_budget then
    update public.projects set status='proposed',budget_assessment_status='within_cap',
      budget_assessment=(budget_assessment-'recommended_action')||jsonb_build_object(
        'recommended_action','proceed_within_cap','founder_budget_change_at',now())
      where id=p_project_id;
    update public.agent_runs set status='queued',finished_at=null,output=output-'blocked_by'
      where project_id=p_project_id and trigger_type='founder_proposal' and run_order=5
        and status='blocked' and output->>'blocked_by'='initiative_budget_increase';
    activation:=jsonb_build_object('status','pm_review_requeued');
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'initiative.budget_changed','project',p_project_id::text,
      jsonb_build_object('old_budget',project_row.requested_budget,'new_budget',p_new_budget,
        'currency',project_row.currency,'committed',committed,'reason',left(trim(p_reason),500)));
  return jsonb_build_object('project_id',p_project_id,'old_budget',project_row.requested_budget,
    'new_budget',p_new_budget,'committed',committed,'remaining_budget',p_new_budget-committed,
    'changed',true,'initiative_status',coalesce(activation->>'status',project_row.status),
    'assessment_status',project_row.budget_assessment_status);
end;
$$;

revoke all on function public.sutra_authorize_initiative_cost(text,text,uuid,uuid,text,text,text,numeric,char,text)
  from public,anon,authenticated;
revoke all on function public.sutra_settle_initiative_cost(text,uuid,numeric,boolean)
  from public,anon,authenticated;
revoke all on function public.sutra_founder_set_project_budget(text,uuid,numeric,text)
  from public,anon,authenticated;
grant execute on function public.sutra_authorize_initiative_cost(text,text,uuid,uuid,text,text,text,numeric,char,text)
  to service_role;
grant execute on function public.sutra_settle_initiative_cost(text,uuid,numeric,boolean)
  to service_role;
grant execute on function public.sutra_founder_set_project_budget(text,uuid,numeric,text)
  to service_role;

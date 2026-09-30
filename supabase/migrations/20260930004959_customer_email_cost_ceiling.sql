-- Customer email delivery remains disabled until a founder configures a maximum
-- per-message reservation. The value is company state, never prompt-only policy.
alter table public.company_settings
  add constraint company_settings_customer_email_cost_ceiling_check
  check (key <> 'customer_email_max_message_cost_eur' or
    case when pg_catalog.jsonb_typeof(value)='number' then
      (value #>> '{}')::numeric between 0.01 and 100.00
    else false end);

create or replace function public.sutra_customer_email_cost_ceiling()
returns numeric language sql stable security definer set search_path=pg_catalog,public as $$
  select case when pg_catalog.jsonb_typeof(s.value)='number'
    then (s.value #>> '{}')::numeric else null end
  from public.company_settings s where s.key='customer_email_max_message_cost_eur'
$$;
revoke all on function public.sutra_customer_email_cost_ceiling() from public,anon,authenticated;
grant execute on function public.sutra_customer_email_cost_ceiling() to service_role;

create or replace function public.sutra_guard_customer_email_reservation()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare ceiling_eur numeric; reserved_eur numeric;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.customer_email_cost_ceiling'));
  ceiling_eur:=public.sutra_customer_email_cost_ceiling();
  if ceiling_eur is null then
    raise exception 'customer email cost ceiling is not configured' using errcode='55000';
  end if;
  select l.reserved_amount into reserved_eur from public.initiative_budget_ledger l
    where l.id=new.initiative_ledger_id and l.status='reserved';
  if reserved_eur is null or reserved_eur<ceiling_eur then
    raise exception 'customer email reservation is below the configured per-message ceiling' using errcode='23514';
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_guard_customer_email_reservation() from public,anon,authenticated;
drop trigger if exists customer_email_reservation_guard on public.customer_email_actions;
create trigger customer_email_reservation_guard before insert on public.customer_email_actions
  for each row execute function public.sutra_guard_customer_email_reservation();

create or replace function public.sutra_founder_get_customer_email_cost_ceiling(
  p_founder_telegram_user_id text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; ceiling_eur numeric;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64 then
    raise exception 'malformed customer email cost ceiling request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings where key='founder_telegram_user_id';
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can read the customer email cost ceiling' using errcode='42501';
  end if;
  ceiling_eur:=public.sutra_customer_email_cost_ceiling();
  return pg_catalog.jsonb_build_object('configured',ceiling_eur is not null,
    'max_message_cost_eur',ceiling_eur,'minimum_eur',0.01,'maximum_eur',100.00);
end;
$$;
revoke all on function public.sutra_founder_get_customer_email_cost_ceiling(text) from public,anon,authenticated;
grant execute on function public.sutra_founder_get_customer_email_cost_ceiling(text) to service_role;

create or replace function public.sutra_founder_set_customer_email_cost_ceiling(
  p_founder_telegram_user_id text,p_max_message_cost_eur numeric,p_reason text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; previous_eur numeric;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_max_message_cost_eur is null or p_max_message_cost_eur not between 0.01 and 100.00
    or pg_catalog.round(p_max_message_cost_eur,2)<>p_max_message_cost_eur
    or p_reason is null or length(pg_catalog.btrim(p_reason)) not between 8 and 500 then
    raise exception 'customer email ceiling must be EUR 0.01 to 100.00 in cents and include a reason' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.customer_email_cost_ceiling'));
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' and founder_only and governance_sensitive for update;
  if founder_id is null or founder_id is distinct from p_founder_telegram_user_id then
    raise exception 'only the configured founder can change the customer email cost ceiling' using errcode='42501';
  end if;
  previous_eur:=public.sutra_customer_email_cost_ceiling();
  if p_max_message_cost_eur>coalesce(previous_eur,0) and exists(select 1 from public.customer_email_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    where a.status='sending' or (a.status='queued' and l.reserved_amount<p_max_message_cost_eur)) then
    raise exception 'customer email ceiling cannot change while sends are active or queued reservations are below the new ceiling' using errcode='55000';
  end if;
  insert into public.company_settings(key,value,governance_sensitive,founder_only,updated_by)
    values('customer_email_max_message_cost_eur',pg_catalog.to_jsonb(p_max_message_cost_eur),true,true,founder_id)
    on conflict(key) do update set value=excluded.value,governance_sensitive=true,founder_only=true,
      updated_at=pg_catalog.now(),updated_by=founder_id;
  if previous_eur is distinct from p_max_message_cost_eur then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,'founder.customer_email_cost_ceiling_changed','company_setting',
        'customer_email_max_message_cost_eur',pg_catalog.jsonb_build_object(
          'previous_max_message_cost_eur',previous_eur,'new_max_message_cost_eur',p_max_message_cost_eur,
          'reason',pg_catalog.btrim(p_reason),'no_email_sent',true));
  end if;
  return pg_catalog.jsonb_build_object('configured',true,'previous_max_message_cost_eur',previous_eur,
    'max_message_cost_eur',p_max_message_cost_eur,'changed',previous_eur is distinct from p_max_message_cost_eur,
    'no_email_sent',true);
end;
$$;
revoke all on function public.sutra_founder_set_customer_email_cost_ceiling(text,numeric,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_set_customer_email_cost_ceiling(text,numeric,text) to service_role;

-- Claims and pre-send validation read the same founder-configured ceiling while
-- holding the setting lock, so an existing underfunded queue item cannot escape.
create or replace function public.sutra_claim_customer_email_action(p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare action_row public.customer_email_actions%rowtype; stale_row record; claim_uuid uuid; ceiling_eur numeric;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'customer email worker identity is invalid' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.customer_email_cost_ceiling'));
  ceiling_eur:=public.sutra_customer_email_cost_ceiling();
  if ceiling_eur is null then return null; end if;
  for stale_row in select a.id,a.initiative_ledger_id from public.customer_email_actions a
    where a.status='sending' and a.delivery_lease_expires_at<=pg_catalog.clock_timestamp() for update skip locked
  loop
    perform public.sutra_settle_initiative_cost(p_worker_id,stale_row.initiative_ledger_id,null,false);
    update public.customer_email_actions set status='unknown',delivery_claim_token=null,
      delivery_lease_expires_at=null,last_delivery_error_code='provider_outcome_unknown',updated_at=pg_catalog.now()
      where id=stale_row.id and status='sending';
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',left(p_worker_id,120),'customer.email_delivery_unknown','customer_email_action',stale_row.id::text,
        pg_catalog.jsonb_build_object('error_code','provider_outcome_unknown','reason','delivery_lease_expired'));
  end loop;
  select a.* into action_row from public.customer_email_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    join public.projects p on p.id=a.project_id join public.tasks t on t.id=a.task_id
    join public.agents g on g.id=a.agent_id join public.customers c on c.id=a.customer_id
    where a.status='queued' and l.status='reserved' and l.reserved_amount>=ceiling_eur
      and p.status='active' and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap' and not p.legal_hold
      and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.assigned_agent_id=g.id and t.owner_agent_id=g.id
      and t.status in ('ready','in_progress','review') and g.active
      and ((a.purpose='marketing' and g.slug='cmo' and c.marketing_email_consent)
        or (a.purpose in ('sales','support') and g.slug='sales'
          and case when a.purpose='support' then c.service_email_consent else c.marketing_email_consent end))
      and c.email_unsubscribed_at is null and c.email_consent_recorded_at is not null
      and c.email_consent_source is not null and c.email is not null
      and pg_catalog.lower(pg_catalog.btrim(c.email))=a.recipient_email
    order by a.created_at,a.id limit 1 for update of a skip locked;
  if not found then return null; end if;
  claim_uuid:=pg_catalog.gen_random_uuid();
  update public.customer_email_actions set status='sending',delivery_attempt_count=delivery_attempt_count+1,
    delivery_claim_token=claim_uuid,delivery_lease_expires_at=pg_catalog.clock_timestamp()+interval '2 minutes',
    last_delivery_error_code=null,updated_at=pg_catalog.now() where id=action_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_worker_id,120),'customer.email_delivery_claimed','customer_email_action',action_row.id::text,
      pg_catalog.jsonb_build_object('project_id',action_row.project_id,'task_id',action_row.task_id,
        'ledger_id',action_row.initiative_ledger_id,'attempt',action_row.delivery_attempt_count+1,
        'max_message_cost_eur',ceiling_eur));
  return pg_catalog.jsonb_build_object('status','claimed','action_id',action_row.id,'claim_token',claim_uuid,
    'ledger_id',action_row.initiative_ledger_id,'action',pg_catalog.jsonb_build_object(
      'recipient_email',action_row.recipient_email,'subject',action_row.subject,'body_text',action_row.body_text,
      'idempotency_key',action_row.idempotency_key));
end;
$$;
revoke all on function public.sutra_claim_customer_email_action(text) from public,anon,authenticated;
grant execute on function public.sutra_claim_customer_email_action(text) to service_role;

create or replace function public.sutra_validate_customer_email_claim(
  p_worker_id text,p_action_id uuid,p_claim_token uuid
) returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare action_row public.customer_email_actions%rowtype; ceiling_eur numeric;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_action_id is null or p_claim_token is null then
    raise exception 'customer email claim is malformed' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('sutra.customer_email_cost_ceiling'));
  ceiling_eur:=public.sutra_customer_email_cost_ceiling();
  if ceiling_eur is null then return false; end if;
  select * into action_row from public.customer_email_actions a where a.id=p_action_id
    and a.status='sending' and a.delivery_claim_token=p_claim_token
    and a.delivery_lease_expires_at>pg_catalog.clock_timestamp() for update;
  if not found then return false; end if;
  return exists(select 1 from public.initiative_budget_ledger l
    join public.projects p on p.id=action_row.project_id join public.tasks t on t.id=action_row.task_id
    join public.agents g on g.id=action_row.agent_id join public.customers c on c.id=action_row.customer_id
    where l.id=action_row.initiative_ledger_id and l.status='reserved' and l.reserved_amount>=ceiling_eur
      and p.status='active' and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap' and not p.legal_hold
      and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.assigned_agent_id=g.id and t.owner_agent_id=g.id
      and t.status in ('ready','in_progress','review') and g.active
      and ((action_row.purpose='marketing' and g.slug='cmo' and c.marketing_email_consent)
        or (action_row.purpose in ('sales','support') and g.slug='sales'
          and case when action_row.purpose='support' then c.service_email_consent else c.marketing_email_consent end))
      and c.email_unsubscribed_at is null and c.email_consent_recorded_at is not null
      and c.email_consent_source is not null and c.email is not null
      and pg_catalog.lower(pg_catalog.btrim(c.email))=action_row.recipient_email);
end;
$$;
revoke all on function public.sutra_validate_customer_email_claim(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.sutra_validate_customer_email_claim(text,uuid,uuid) to service_role;

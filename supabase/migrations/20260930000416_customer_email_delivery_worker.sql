alter table public.customer_email_actions
  drop constraint customer_email_actions_status_check,
  add column delivery_attempt_count smallint not null default 0
    check (delivery_attempt_count between 0 and 3),
  add column delivery_claim_token uuid,
  add column delivery_lease_expires_at timestamptz,
  add column last_delivery_error_code text
    check (last_delivery_error_code is null or last_delivery_error_code in (
      'authorization_revoked','invalid_action','provider_rejected',
      'provider_outcome_unknown','provider_response_too_large','malformed_provider_response')),
  add constraint customer_email_actions_status_check
    check (status in ('queued','sending','cancelled','sent','failed','unknown')),
  add constraint customer_email_actions_delivery_lease_check
    check ((status='sending')=(delivery_claim_token is not null and delivery_lease_expires_at is not null));

create index customer_email_actions_delivery_lease_idx
  on public.customer_email_actions(delivery_lease_expires_at,id) where status='sending';

create or replace function public.sutra_claim_customer_email_action(p_worker_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  action_row public.customer_email_actions%rowtype;
  stale_row record;
  claim_uuid uuid;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'customer email worker identity is invalid' using errcode='22023';
  end if;

  -- A worker crash after the provider request leaves an ambiguous send. Preserve
  -- its full reservation and mark it terminal; never claim it for a second send.
  for stale_row in
    select a.id,a.initiative_ledger_id from public.customer_email_actions a
      where a.status='sending' and a.delivery_lease_expires_at<=pg_catalog.clock_timestamp()
      for update skip locked
  loop
    perform public.sutra_settle_initiative_cost(p_worker_id,stale_row.initiative_ledger_id,null,false);
    update public.customer_email_actions set status='unknown',delivery_claim_token=null,
      delivery_lease_expires_at=null,last_delivery_error_code='provider_outcome_unknown',updated_at=pg_catalog.now()
      where id=stale_row.id and status='sending';
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',left(p_worker_id,120),'customer.email_delivery_unknown','customer_email_action',stale_row.id::text,
        pg_catalog.jsonb_build_object('error_code','provider_outcome_unknown','reason','delivery_lease_expired'));
  end loop;

  select a.* into action_row
    from public.customer_email_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    join public.projects p on p.id=a.project_id
    join public.tasks t on t.id=a.task_id
    join public.agents g on g.id=a.agent_id
    join public.customers c on c.id=a.customer_id
    where a.status='queued' and l.status='reserved'
      and p.status='active' and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap'
      and not p.legal_hold
      and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.assigned_agent_id=g.id and t.owner_agent_id=g.id
      and t.status in ('ready','in_progress','review') and g.active
      and ((a.purpose='marketing' and g.slug='cmo' and c.marketing_email_consent)
        or (a.purpose in ('sales','support') and g.slug='sales'
          and case when a.purpose='support' then c.service_email_consent else c.marketing_email_consent end))
      and c.email_unsubscribed_at is null
      and c.email_consent_recorded_at is not null and c.email_consent_source is not null
      and c.email is not null and pg_catalog.lower(pg_catalog.btrim(c.email))=a.recipient_email
    order by a.created_at,a.id
    limit 1 for update of a skip locked;
  if not found then return null; end if;

  claim_uuid:=pg_catalog.gen_random_uuid();
  update public.customer_email_actions set status='sending',
    delivery_attempt_count=delivery_attempt_count+1,
    delivery_claim_token=claim_uuid,
    delivery_lease_expires_at=pg_catalog.clock_timestamp()+interval '2 minutes',
    last_delivery_error_code=null,updated_at=pg_catalog.now()
    where id=action_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_worker_id,120),'customer.email_delivery_claimed','customer_email_action',action_row.id::text,
      pg_catalog.jsonb_build_object('project_id',action_row.project_id,'task_id',action_row.task_id,
        'ledger_id',action_row.initiative_ledger_id,'attempt',action_row.delivery_attempt_count+1));
  return pg_catalog.jsonb_build_object(
    'status','claimed','action_id',action_row.id,'claim_token',claim_uuid,
    'ledger_id',action_row.initiative_ledger_id,
    'action',pg_catalog.jsonb_build_object('recipient_email',action_row.recipient_email,
      'subject',action_row.subject,'body_text',action_row.body_text,
      'idempotency_key',action_row.idempotency_key));
end;
$$;
revoke all on function public.sutra_claim_customer_email_action(text) from public,anon,authenticated;
grant execute on function public.sutra_claim_customer_email_action(text) to service_role;

create or replace function public.sutra_validate_customer_email_claim(
  p_worker_id text,p_action_id uuid,p_claim_token uuid
) returns boolean language plpgsql security definer set search_path = '' as $$
declare action_row public.customer_email_actions%rowtype;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_action_id is null or p_claim_token is null then
    raise exception 'customer email claim is malformed' using errcode='22023';
  end if;
  select * into action_row from public.customer_email_actions a where a.id=p_action_id
    and a.status='sending' and a.delivery_claim_token=p_claim_token
    and a.delivery_lease_expires_at>pg_catalog.clock_timestamp() for update;
  if not found then return false; end if;
  return exists(
    select 1 from public.initiative_budget_ledger l
    join public.projects p on p.id=action_row.project_id
    join public.tasks t on t.id=action_row.task_id
    join public.agents g on g.id=action_row.agent_id
    join public.customers c on c.id=action_row.customer_id
    where l.id=action_row.initiative_ledger_id and l.status='reserved'
      and p.status='active' and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap'
      and not p.legal_hold
      and not exists(select 1 from public.legal_escalations e where e.project_id=p.id and e.status='open')
      and t.project_id=p.id and t.assigned_agent_id=g.id and t.owner_agent_id=g.id
      and t.status in ('ready','in_progress','review') and g.active
      and ((action_row.purpose='marketing' and g.slug='cmo' and c.marketing_email_consent)
        or (action_row.purpose in ('sales','support') and g.slug='sales'
          and case when action_row.purpose='support' then c.service_email_consent else c.marketing_email_consent end))
      and c.email_unsubscribed_at is null
      and c.email_consent_recorded_at is not null and c.email_consent_source is not null
      and c.email is not null and pg_catalog.lower(pg_catalog.btrim(c.email))=action_row.recipient_email
  );
end;
$$;
revoke all on function public.sutra_validate_customer_email_claim(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.sutra_validate_customer_email_claim(text,uuid,uuid) to service_role;

create or replace function public.sutra_finish_customer_email_action(
  p_worker_id text,p_action_id uuid,p_claim_token uuid,p_status text,
  p_provider_message_id text,p_error_code text,p_actual_cost_eur numeric,p_cost_known boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare action_row public.customer_email_actions%rowtype; settlement jsonb; audit_action text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$'
    or p_action_id is null or p_claim_token is null
    or p_status is null or p_status not in ('sent','failed','unknown') or p_cost_known is null
    or (p_status='sent' and (p_provider_message_id is null or p_provider_message_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
      or p_cost_known or p_actual_cost_eur is not null))
    or (p_status='failed' and (p_provider_message_id is not null or not p_cost_known
      or p_actual_cost_eur is distinct from 0::numeric))
    or (p_status='unknown' and (p_provider_message_id is not null or p_cost_known or p_actual_cost_eur is not null))
    or (p_error_code is not null and p_error_code not in (
      'authorization_revoked','invalid_action','provider_rejected',
      'provider_outcome_unknown','provider_response_too_large','malformed_provider_response')) then
    raise exception 'customer email result is malformed' using errcode='22023';
  end if;
  select * into action_row from public.customer_email_actions a where a.id=p_action_id
    and a.status='sending' and a.delivery_claim_token=p_claim_token
    and a.delivery_lease_expires_at>pg_catalog.clock_timestamp() for update;
  if not found then raise exception 'customer email claim is no longer active' using errcode='42501'; end if;

  settlement:=public.sutra_settle_initiative_cost(p_worker_id,action_row.initiative_ledger_id,
    p_actual_cost_eur,p_cost_known);
  update public.customer_email_actions set status=p_status,
    provider_message_id=p_provider_message_id,last_delivery_error_code=p_error_code,
    delivery_claim_token=null,delivery_lease_expires_at=null,updated_at=pg_catalog.now()
    where id=p_action_id;
  audit_action:=case p_status when 'sent' then 'customer.email_sent'
    when 'failed' then 'customer.email_failed' else 'customer.email_delivery_unknown' end;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('system',left(p_worker_id,120),audit_action,'customer_email_action',p_action_id::text,
      pg_catalog.jsonb_build_object('project_id',action_row.project_id,'task_id',action_row.task_id,
        'ledger_id',action_row.initiative_ledger_id,'error_code',p_error_code,
        'cost_status',settlement->>'status'));
  return pg_catalog.jsonb_build_object('status',p_status,'action_id',p_action_id,
    'ledger_status',settlement->>'status');
end;
$$;
revoke all on function public.sutra_finish_customer_email_action(text,uuid,uuid,text,text,text,numeric,boolean)
  from public,anon,authenticated;
grant execute on function public.sutra_finish_customer_email_action(text,uuid,uuid,text,text,text,numeric,boolean)
  to service_role;

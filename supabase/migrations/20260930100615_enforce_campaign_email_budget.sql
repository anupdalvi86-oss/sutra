-- Bound every CMO email campaign by the campaign's own estimate as well as
-- the initiative ledger. Campaign records remain internal until a message is
-- actually delivered; no provider call is made by this migration.
alter table public.customer_email_actions
  add column campaign_id uuid references public.campaigns(id) on delete restrict;

create index customer_email_actions_campaign_status_idx
  on public.customer_email_actions(campaign_id,status,created_at)
  where campaign_id is not null;

-- Associate any already queued CMO messages with the campaign artifact from
-- the same task before enabling the delivery guards.
update public.customer_email_actions a
set campaign_id=c.id
from public.campaigns c
where a.campaign_id is null and a.purpose='marketing'
  and a.project_id=c.project_id and a.task_id=c.source_task_id
  and a.agent_id=c.created_by_agent_id;

create function public.sutra_campaign_email_within_cap(p_campaign_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare campaign_row public.campaigns%rowtype; committed numeric(14,2);
begin
  if p_campaign_id is null then return false; end if;
  select * into campaign_row from public.campaigns where id=p_campaign_id;
  if not found or campaign_row.status not in ('draft','active') or campaign_row.budget_amount<=0
    or campaign_row.currency<>'EUR' then return false; end if;
  select coalesce(sum(case
      when l.status in ('reserved','unknown') then l.reserved_amount
      when l.status in ('actual','overrun') then coalesce(l.actual_amount,l.reserved_amount)
      else 0 end),0)
    into committed
    from public.customer_email_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    where a.campaign_id=p_campaign_id and l.status in ('reserved','unknown','actual','overrun');
  return committed<=campaign_row.budget_amount;
end;
$$;
revoke all on function public.sutra_campaign_email_within_cap(uuid) from public,anon,authenticated,service_role;

create function public.sutra_guard_campaign_email_budget()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare agent_slug text; task_row public.tasks%rowtype; campaign_row public.campaigns%rowtype;
  committed numeric(14,2); action_reserve numeric(14,2);
begin
  select slug into agent_slug from public.agents where id=new.agent_id and active;
  if agent_slug is distinct from 'cmo' then
    if new.purpose='marketing' or new.campaign_id is not null then
      raise exception 'marketing email requires an active CMO campaign' using errcode='42501';
    end if;
    return new;
  end if;
  if new.purpose<>'marketing' then
    raise exception 'CMO campaign email purpose is invalid' using errcode='42501';
  end if;
  select * into task_row from public.tasks where id=new.task_id;
  select * into campaign_row from public.campaigns
    where project_id=new.project_id and source_task_id=new.task_id
      and created_by_agent_id=new.agent_id for update;
  if not found or task_row.id is null or task_row.project_id<>new.project_id
    or task_row.owner_agent_id<>new.agent_id or task_row.assigned_agent_id<>new.agent_id
    or campaign_row.status not in ('draft','active') or campaign_row.currency<>'EUR'
    or campaign_row.budget_amount<=0 then
    raise exception 'CMO campaign is blocked or has no positive EUR budget' using errcode='42501';
  end if;
  select l.reserved_amount into action_reserve from public.initiative_budget_ledger l
    where l.id=new.initiative_ledger_id and l.project_id=new.project_id and l.status='reserved';
  if action_reserve is null then
    raise exception 'marketing email requires a fresh campaign spend reservation' using errcode='23514';
  end if;
  select coalesce(sum(case
      when l.status in ('reserved','unknown') then l.reserved_amount
      when l.status in ('actual','overrun') then coalesce(l.actual_amount,l.reserved_amount)
      else 0 end),0)
    into committed
    from public.customer_email_actions a
    join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    where a.campaign_id=campaign_row.id and l.status in ('reserved','unknown','actual','overrun');
  if committed+action_reserve>campaign_row.budget_amount then
    raise exception 'marketing email exceeds the campaign budget' using errcode='23514';
  end if;
  new.campaign_id:=campaign_row.id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',new.agent_id::text,'marketing.campaign_email_budget_reserved',
      'campaign',campaign_row.id::text,jsonb_build_object('task_id',new.task_id,
        'email_action_id',new.id,'ledger_id',new.initiative_ledger_id,
        'new_reservation_eur',action_reserve,'previous_campaign_commitment_eur',committed,
        'campaign_budget_eur',campaign_row.budget_amount,
        'remaining_campaign_budget_eur',campaign_row.budget_amount-committed-action_reserve));
  return new;
end;
$$;
revoke all on function public.sutra_guard_campaign_email_budget() from public,anon,authenticated,service_role;
create trigger customer_email_actions_campaign_budget_guard
  before insert on public.customer_email_actions
  for each row execute function public.sutra_guard_campaign_email_budget();

create function public.sutra_guard_campaign_email_delivery()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.status='sending' and new.purpose='marketing'
    and not public.sutra_campaign_email_within_cap(new.campaign_id) then
    raise exception 'marketing campaign is not within its reserved budget' using errcode='42501';
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_guard_campaign_email_delivery() from public,anon,authenticated,service_role;
create trigger customer_email_actions_campaign_delivery_guard
  before update of status on public.customer_email_actions
  for each row execute function public.sutra_guard_campaign_email_delivery();

create function public.sutra_mark_campaign_email_delivery()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare changed_campaign_id uuid;
begin
  if new.status='sent' and old.status is distinct from new.status and new.campaign_id is not null then
    update public.campaigns set status='active',updated_at=pg_catalog.now(),
      content=content||pg_catalog.jsonb_build_object('delivery_started',true,
        'first_delivery_at',coalesce(content->>'first_delivery_at',pg_catalog.now()::text))
      where id=new.campaign_id and status='draft' returning id into changed_campaign_id;
    if changed_campaign_id is not null then
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system','sutra','marketing.campaign_delivery_started','campaign',changed_campaign_id::text,
          pg_catalog.jsonb_build_object('email_action_id',new.id,'project_id',new.project_id,
            'task_id',new.task_id,'ledger_id',new.initiative_ledger_id));
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.sutra_mark_campaign_email_delivery() from public,anon,authenticated,service_role;
create trigger customer_email_actions_campaign_delivery_lifecycle
  after update of status on public.customer_email_actions
  for each row execute function public.sutra_mark_campaign_email_delivery();

-- Older queued campaigns can include reservations made before per-campaign
-- attribution. Pause any campaign whose retained commitments exceed its cap.
with commitments as (
  select c.id,c.budget_amount,
    coalesce(sum(case when l.status in ('reserved','unknown') then l.reserved_amount
      when l.status in ('actual','overrun') then coalesce(l.actual_amount,l.reserved_amount)
      else 0 end),0) as committed
  from public.campaigns c
  left join public.customer_email_actions a on a.campaign_id=c.id
  left join public.initiative_budget_ledger l on l.id=a.initiative_ledger_id
    and l.status in ('reserved','unknown','actual','overrun')
  group by c.id,c.budget_amount
), blocked as (
  update public.campaigns c set status='approval_required',updated_at=pg_catalog.now(),
    content=c.content||pg_catalog.jsonb_build_object('budget_fit','requires_campaign_budget_review',
      'committed_email_cost_eur',x.committed,'campaign_budget_eur',x.budget_amount)
  from commitments x where x.id=c.id and c.status in ('draft','active')
    and x.committed>x.budget_amount returning c.id
)
insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
select 'system','sutra','marketing.campaign_email_budget_reconciled','campaign',c.id::text,
  pg_catalog.jsonb_build_object('committed_email_cost_eur',x.committed,
    'campaign_budget_eur',x.budget_amount,'delivery_blocked',true)
from blocked b join commitments x on x.id=b.id join public.campaigns c on c.id=b.id;

-- Existing claim and validation paths recheck the campaign ceiling before a
-- provider request, including campaigns that were blocked during backfill.
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
      and ((a.purpose='marketing' and g.slug='cmo' and c.marketing_email_consent
            and public.sutra_campaign_email_within_cap(a.campaign_id))
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
        'max_message_cost_eur',ceiling_eur,'campaign_id',action_row.campaign_id));
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
      and ((action_row.purpose='marketing' and g.slug='cmo' and c.marketing_email_consent
            and public.sutra_campaign_email_within_cap(action_row.campaign_id))
        or (action_row.purpose in ('sales','support') and g.slug='sales'
          and case when action_row.purpose='support' then c.service_email_consent else c.marketing_email_consent end))
      and c.email_unsubscribed_at is null and c.email_consent_recorded_at is not null
      and c.email_consent_source is not null and c.email is not null
      and pg_catalog.lower(pg_catalog.btrim(c.email))=action_row.recipient_email);
end;
$$;
revoke all on function public.sutra_validate_customer_email_claim(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.sutra_validate_customer_email_claim(text,uuid,uuid) to service_role;

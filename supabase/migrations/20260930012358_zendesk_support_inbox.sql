-- Store privacy-minimized inbound Zendesk ticket state. Customer message bodies,
-- email addresses, attachments and arbitrary provider payloads are not retained.
create table public.support_cases (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider = 'zendesk'),
  external_ticket_id text not null check (external_ticket_id ~ '^[1-9][0-9]{0,18}$'),
  status text not null check (status in ('new','open','pending','hold','solved','closed')),
  priority text check (priority is null or priority in ('low','normal','high','urgent')),
  provider_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, external_ticket_id)
);

alter table public.support_cases enable row level security;
revoke all on public.support_cases from public, anon, authenticated, service_role;
create index support_cases_status_updated_idx
  on public.support_cases(status, provider_updated_at desc);

create or replace function public.sutra_ingest_zendesk_ticket_event(
  p_ticket_id text, p_status text, p_priority text, p_provider_updated_at timestamptz
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare existing public.support_cases%rowtype; case_id uuid; changed boolean := false;
begin
  if p_ticket_id is null or p_ticket_id !~ '^[1-9][0-9]{0,18}$'
      or p_status is null or p_status not in ('new','open','pending','hold','solved','closed')
      or (p_priority is not null and p_priority not in ('low','normal','high','urgent'))
      or p_provider_updated_at is null then
    raise exception 'invalid support event' using errcode='22023';
  end if;

  insert into public.support_cases(provider,external_ticket_id,status,priority,provider_updated_at)
    values('zendesk',p_ticket_id,p_status,p_priority,p_provider_updated_at)
    on conflict(provider,external_ticket_id) do nothing returning id into case_id;
  if case_id is not null then
    changed := true;
  else
    select * into existing from public.support_cases
      where provider='zendesk' and external_ticket_id=p_ticket_id for update;
    case_id := existing.id;
    -- Ignore duplicate and stale delivery; provider timestamps make retries safe.
    if p_provider_updated_at > existing.provider_updated_at then
      update public.support_cases set status=p_status, priority=p_priority,
        provider_updated_at=p_provider_updated_at, updated_at=now() where id=case_id;
      changed := true;
    end if;
  end if;

  if changed then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system','sutra','support.ticket_state_ingested','support_case',case_id::text,
        jsonb_build_object('status',p_status,'priority',p_priority,
          'provider_updated_at',p_provider_updated_at));
  end if;
  return jsonb_build_object('case_id',case_id,'changed',changed);
end;
$$;
revoke all on function public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.sutra_ingest_zendesk_ticket_event(text,text,text,timestamptz)
  to service_role;

-- Serialize governed Hermes work across overlapping Railway replicas/deploys.
-- The database remains the authority for this short-lived global worker lease.
create table public.agent_worker_execution_leases (
  lease_key text primary key check (lease_key='agent-worker'),
  worker_id text not null check (worker_id ~ '^sutra-worker-[a-z0-9]{8,64}$'),
  lease_expires_at timestamptz not null,
  updated_at timestamptz not null default now()
);
alter table public.agent_worker_execution_leases enable row level security;
revoke all on public.agent_worker_execution_leases from public,anon,authenticated,service_role;

create function public.sutra_acquire_agent_worker_execution_lease(p_worker_id text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare acquired boolean;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode='22023';
  end if;
  insert into public.agent_worker_execution_leases(lease_key,worker_id,lease_expires_at,updated_at)
    values('agent-worker',p_worker_id,clock_timestamp()+interval '10 minutes',clock_timestamp())
    on conflict(lease_key) do update set worker_id=excluded.worker_id,
      lease_expires_at=excluded.lease_expires_at,updated_at=excluded.updated_at
      where public.agent_worker_execution_leases.lease_expires_at<=clock_timestamp()
        or public.agent_worker_execution_leases.worker_id=p_worker_id
    returning true into acquired;
  return coalesce(acquired,false);
end
$$;

create function public.sutra_release_agent_worker_execution_lease(p_worker_id text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode='22023';
  end if;
  update public.agent_worker_execution_leases
    set lease_expires_at=clock_timestamp(),updated_at=clock_timestamp()
    where lease_key='agent-worker' and worker_id=p_worker_id;
  return found;
end
$$;

revoke all on function public.sutra_acquire_agent_worker_execution_lease(text) from public,anon,authenticated;
revoke all on function public.sutra_release_agent_worker_execution_lease(text) from public,anon,authenticated;
grant execute on function public.sutra_acquire_agent_worker_execution_lease(text) to service_role;
grant execute on function public.sutra_release_agent_worker_execution_lease(text) to service_role;

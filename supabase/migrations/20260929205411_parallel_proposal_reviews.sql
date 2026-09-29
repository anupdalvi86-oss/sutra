-- Allow the market and technical feasibility reviews to proceed independently.
-- Keep the established CEO (1), CFO (4), and PM (5) sequence numbers so the
-- founder-authorized PM recovery limit remains attached to stage 5.
drop index if exists public.agent_runs_project_sequence_unique;
create unique index agent_runs_project_sequence_unique
  on public.agent_runs(project_id,run_order,agent_id)
  where trigger_type='founder_proposal' and run_order is not null;

create or replace function public.sutra_assign_agent_run_order()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare role_slug text;
begin
  if new.trigger_type='founder_proposal' and new.run_order is null then
    select slug into role_slug from public.agents where id=new.agent_id;
    new.run_order:=case role_slug
      when 'ceo' then 1
      when 'cpo' then 2
      when 'cto' then 2
      when 'cfo' then 4
      when 'product_manager' then 5
      else null end;
    if new.run_order is null then
      select coalesce(max(r.run_order),0)+1 into new.run_order
        from public.agent_runs r where r.project_id=new.project_id and r.trigger_type='founder_proposal';
    end if;
  end if;
  return new;
end;
$$;

-- Replace the single global execution lease with two database-coordinated
-- slots. Existing workers use the same RPC signatures and remain safe during
-- rolling deployments. Spend reservations still serialize against the EUR
-- ledger lock and all existing project/company caps.
alter table public.agent_worker_execution_leases
  drop constraint agent_worker_execution_leases_lease_key_check;
alter table public.agent_worker_execution_leases rename column lease_key to slot_no;
alter table public.agent_worker_execution_leases alter column slot_no type smallint using 1::smallint;
alter table public.agent_worker_execution_leases add constraint agent_worker_execution_leases_slot_no_check
  check(slot_no between 1 and 2);
insert into public.agent_worker_execution_leases(slot_no,worker_id,lease_expires_at,updated_at)
  values(1,'sutra-worker-slot0001',clock_timestamp(),clock_timestamp()),
        (2,'sutra-worker-slot0002',clock_timestamp(),clock_timestamp())
  on conflict(slot_no) do nothing;

create or replace function public.sutra_acquire_agent_worker_execution_lease(p_worker_id text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare acquired_slot smallint;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode='22023';
  end if;
  select slot_no into acquired_slot from public.agent_worker_execution_leases
    where lease_expires_at<=clock_timestamp() or worker_id=p_worker_id
    order by slot_no limit 1 for update skip locked;
  if not found then return false; end if;
  update public.agent_worker_execution_leases set worker_id=p_worker_id,
    lease_expires_at=clock_timestamp()+interval '10 minutes',updated_at=clock_timestamp()
    where slot_no=acquired_slot;
  return true;
end
$$;

create or replace function public.sutra_release_agent_worker_execution_lease(p_worker_id text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-worker-[a-z0-9]{8,64}$' then
    raise exception 'invalid worker identity' using errcode='22023';
  end if;
  update public.agent_worker_execution_leases
    set lease_expires_at=clock_timestamp(),updated_at=clock_timestamp()
    where worker_id=p_worker_id;
  return found;
end
$$;

revoke all on function public.sutra_acquire_agent_worker_execution_lease(text) from public,anon,authenticated;
revoke all on function public.sutra_release_agent_worker_execution_lease(text) from public,anon,authenticated;
grant execute on function public.sutra_acquire_agent_worker_execution_lease(text) to service_role;
grant execute on function public.sutra_release_agent_worker_execution_lease(text) to service_role;

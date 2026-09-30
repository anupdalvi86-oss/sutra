-- Every paid reservation is represented by an expense row. Enforce legal
-- holds at that common database boundary, even if project status drifts back
-- to active. Existing reservations are preserved for reconciliation.
create or replace function public.sutra_block_expenses_for_open_legal_escalation()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare project_on_hold boolean;
begin
  if new.project_id is null then return new; end if;

  select p.legal_hold into project_on_hold
    from public.projects p where p.id=new.project_id for update;
  if project_on_hold then
    raise exception 'initiative is under legal hold; paid work is paused'
      using errcode='42501';
  end if;

  if exists(select 1 from public.legal_escalations e
      where e.project_id=new.project_id and e.status='open') then
    raise exception 'initiative has an open legal escalation; paid work is paused'
      using errcode='42501';
  end if;
  return new;
end;
$$;

-- Do not reserve or enqueue a customer email until Finance has assessed the
-- founder's all-in initiative cap and recommended proceeding within that cap.
-- The queue RPC is atomic: rejecting its insert rolls back its preceding
-- ledger reservation and expense as well.
create or replace function public.sutra_guard_customer_email_budget_assessment()
returns trigger
language plpgsql
set search_path=pg_catalog,public
as $$
begin
  if not exists (
    select 1
    from public.projects p
    where p.id=new.project_id
      and p.status='active'
      and p.budget_assessment_status='within_cap'
      and p.budget_assessment->>'recommended_action'='proceed_within_cap'
      and case
        when pg_catalog.jsonb_typeof(p.budget_assessment->'estimated_total_eur')='number'
          then (p.budget_assessment->>'estimated_total_eur')::numeric<=p.requested_budget
        else false
      end
  ) then
    raise exception 'customer email requires an active initiative with a within-cap CFO assessment'
      using errcode='42501';
  end if;
  return new;
end;
$$;

revoke all on function public.sutra_guard_customer_email_budget_assessment()
  from public,anon,authenticated,service_role;
drop trigger if exists customer_email_requires_assessed_budget on public.customer_email_actions;
create trigger customer_email_requires_assessed_budget
  before insert on public.customer_email_actions
  for each row execute function public.sutra_guard_customer_email_budget_assessment();

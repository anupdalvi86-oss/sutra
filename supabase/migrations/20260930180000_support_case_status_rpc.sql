-- Expose only aggregate support queue state to the service role. Ticket IDs,
-- requester details, message content and provider payloads remain private.
create or replace function public.sutra_company_support_case_status()
returns jsonb
language sql
stable
security definer
set search_path=pg_catalog,public
as $$
with status_counts as (
  select status, count(*)::integer as case_count
  from public.support_cases
  group by status
), open_priority_counts as (
  select coalesce(priority, 'unspecified') as priority, count(*)::integer as case_count
  from public.support_cases
  where status not in ('solved','closed')
  group by coalesce(priority, 'unspecified')
)
select jsonb_build_object(
  'total', (select count(*)::integer from public.support_cases),
  'open', (select count(*)::integer from public.support_cases where status not in ('solved','closed')),
  'by_status', coalesce((select jsonb_object_agg(status,case_count) from status_counts), '{}'::jsonb),
  'open_by_priority', coalesce((select jsonb_object_agg(priority,case_count) from open_priority_counts), '{}'::jsonb)
);
$$;

revoke all on function public.sutra_company_support_case_status() from public,anon,authenticated,service_role;
grant execute on function public.sutra_company_support_case_status() to service_role;

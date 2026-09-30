-- Provide a bounded, privacy-safe marketing performance view for founder status
-- reports. Never return campaign content, customer IDs, or recipient details.
create function public.sutra_company_campaign_performance()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'campaign_id', c.id,
    'status', c.status,
    'sent_count', coalesce(a.sent_count, 0),
    'queued_count', coalesce(a.queued_count, 0),
    'sending_count', coalesce(a.sending_count, 0),
    'unknown_count', coalesce(a.unknown_count, 0),
    'failed_count', coalesce(a.failed_count, 0),
    'reserved_cost_eur', coalesce(a.reserved_cost_eur, 0),
    'unknown_cost_eur', coalesce(a.unknown_cost_eur, 0),
    'actual_cost_eur', coalesce(a.actual_cost_eur, 0)
  ) order by c.created_at desc), '[]'::jsonb)
  from (select * from public.campaigns order by created_at desc limit 100) c
  left join lateral (
    select count(*) filter (where action.status='sent')::integer as sent_count,
      count(*) filter (where action.status='queued')::integer as queued_count,
      count(*) filter (where action.status='sending')::integer as sending_count,
      count(*) filter (where action.status='unknown')::integer as unknown_count,
      count(*) filter (where action.status='failed')::integer as failed_count,
      coalesce(sum(ledger.reserved_amount) filter (where ledger.status='reserved'),0)::numeric(14,2)
        as reserved_cost_eur,
      coalesce(sum(ledger.reserved_amount) filter (where ledger.status='unknown'),0)::numeric(14,2)
        as unknown_cost_eur,
      coalesce(sum(coalesce(ledger.actual_amount,ledger.reserved_amount))
        filter (where ledger.status in ('actual','overrun')),0)::numeric(14,2) as actual_cost_eur
    from public.customer_email_actions action
    join public.initiative_budget_ledger ledger on ledger.id=action.initiative_ledger_id
    where action.campaign_id=c.id
  ) a on true
$$;
revoke all on function public.sutra_company_campaign_performance() from public,anon,authenticated;
grant execute on function public.sutra_company_campaign_performance() to service_role;

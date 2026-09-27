create or replace function public.sutra_founder_pending_approvals(
  p_founder_telegram_user_id text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  founder_id text;
  approval_list jsonb;
begin
  select value #>> '{}' into founder_id
    from public.company_settings
    where key = 'founder_telegram_user_id';
  if founder_id is null or founder_id = '' or founder_id <> p_founder_telegram_user_id then
    raise exception 'only the configured founder can view founder approvals' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(row_data.payload order by row_data.created_at desc), '[]'::jsonb)
    into approval_list
    from (
      select ap.created_at,
        jsonb_build_object(
          'approval_id', ap.id,
          'summary', left(coalesce(ap.summary, 'Approval request'), 500),
          'amount', ap.amount,
          'currency', ap.currency,
          'pending_roles', roles.pending_roles,
          'ready', cardinality(roles.pending_roles) = 0
        ) as payload
      from public.approvals ap
      cross join lateral (
        select coalesce(array_agg(required_role.role order by required_role.role), '{}'::text[]) as pending_roles
        from unnest(ap.required_roles) as required_role(role)
        where required_role.role <> 'founder'
          and coalesce(ap.decisions #>> array[required_role.role, 'decision'], '') <> 'approve'
      ) roles
      where ap.status = 'pending'
        and 'founder' = any(ap.required_roles)
      order by ap.created_at desc
      limit 5
    ) row_data;

  insert into public.audit_log(actor_type, actor_id, action, resource_type, resource_id, details)
    values('founder', founder_id, 'founder.approvals_listed', 'approval_queue', null,
      jsonb_build_object('count', jsonb_array_length(approval_list)));
  return jsonb_build_object('approvals', approval_list);
end;
$$;

revoke all on function public.sutra_founder_pending_approvals(text) from public, anon, authenticated;
grant execute on function public.sutra_founder_pending_approvals(text) to service_role;

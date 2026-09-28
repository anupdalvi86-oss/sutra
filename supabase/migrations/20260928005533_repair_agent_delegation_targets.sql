-- The role graph stores agent slugs. `marketing` is a department label, not
-- an agent slug; the organization uses `cmo` for CMO / Marketing.
update public.agents
set can_delegate_to = array_replace(can_delegate_to, 'marketing', 'cmo'),
    config = jsonb_set(
      coalesce(config, '{}'::jsonb),
      '{can_delegate_to}',
      to_jsonb(array_replace(can_delegate_to, 'marketing', 'cmo')),
      true
    )
where 'marketing' = any(can_delegate_to);

do $$
begin
  if exists (
    select 1
    from public.agents a
    cross join lateral unnest(a.can_delegate_to) target(slug)
    left join public.agents recipient on recipient.slug = target.slug and recipient.active
    where recipient.id is null
  ) then
    raise exception 'Agent delegation metadata contains a missing or inactive agent slug';
  end if;
end;
$$;

-- Owners may remove their own draft and its dependent review history at any time.
-- There is no automatic TTL; retention ends on explicit owner deletion or account deletion.
grant delete on public.test_drafts to authenticated;

create policy "draft owners delete their own tenant rows"
  on public.test_drafts for delete to authenticated
  using ((select auth.uid()) = tenant_id and (select auth.uid()) = owner_id);

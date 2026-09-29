-- Draft-only, synthetic prototype. Drafts are inert data and cannot execute tests.
create table public.test_drafts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  scenario text not null check (length(trim(scenario)) between 8 and 12000),
  context text not null default '' check (octet_length(context) <= 16000),
  framework text not null check (framework = 'playwright'),
  language text not null check (language in ('javascript','typescript','python')),
  test_draft jsonb not null check (
    jsonb_typeof(test_draft) = 'object' and octet_length(test_draft::text) <= 24000
  ),
  rationale jsonb not null check (
    jsonb_typeof(rationale) = 'array' and jsonb_array_length(rationale) <= 20
    and octet_length(rationale::text) <= 16000
  ),
  warnings jsonb not null default '[]'::jsonb check (
    jsonb_typeof(warnings) = 'array' and jsonb_array_length(warnings) <= 20
    and octet_length(warnings::text) <= 8000
  ),
  generator_kind text not null default 'synthetic' check (generator_kind = 'synthetic'),
  generator_name text not null check (length(trim(generator_name)) between 1 and 80),
  generator_version text not null check (length(trim(generator_version)) between 1 and 80),
  created_at timestamptz not null default now(),
  check (tenant_id = owner_id)
);

create index test_drafts_owner_created_idx
  on public.test_drafts (tenant_id, owner_id, created_at desc);

create table public.test_draft_reviews (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  draft_id uuid not null references public.test_drafts(id) on delete cascade,
  reviewer_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  decision text not null check (decision in ('accept','edit','reject')),
  edited_draft jsonb,
  comment text not null default '' check (octet_length(comment) <= 2000),
  created_at timestamptz not null default now(),
  check (tenant_id = reviewer_id),
  check (
    (decision = 'edit' and jsonb_typeof(edited_draft) = 'object'
      and octet_length(edited_draft::text) <= 24000)
    or (decision in ('accept','reject') and edited_draft is null)
  )
);

create index test_draft_reviews_tenant_draft_created_idx
  on public.test_draft_reviews (tenant_id, draft_id, created_at desc);

alter table public.test_drafts enable row level security;
alter table public.test_draft_reviews enable row level security;

revoke all on public.test_drafts, public.test_draft_reviews from public, anon, authenticated;
grant select, insert on public.test_drafts, public.test_draft_reviews to authenticated;
grant all on public.test_drafts, public.test_draft_reviews to service_role;

create policy "draft owners read their own tenant rows"
  on public.test_drafts for select to authenticated
  using ((select auth.uid()) = tenant_id and (select auth.uid()) = owner_id);
create policy "draft owners create rows in their own tenant"
  on public.test_drafts for insert to authenticated
  with check ((select auth.uid()) = tenant_id and (select auth.uid()) = owner_id);

create policy "draft owners read review history"
  on public.test_draft_reviews for select to authenticated
  using (
    (select auth.uid()) = tenant_id
    and exists (
      select 1 from public.test_drafts d
      where d.id = draft_id and d.tenant_id = (select auth.uid()) and d.owner_id = (select auth.uid())
    )
  );
create policy "draft owners append review decisions"
  on public.test_draft_reviews for insert to authenticated
  with check (
    (select auth.uid()) = tenant_id
    and (select auth.uid()) = reviewer_id
    and exists (
      select 1 from public.test_drafts d
      where d.id = draft_id and d.tenant_id = (select auth.uid()) and d.owner_id = (select auth.uid())
    )
  );

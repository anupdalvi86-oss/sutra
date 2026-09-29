begin;
select plan(13);

select ok((select relrowsecurity from pg_class where oid='public.test_drafts'::regclass),
  'draft rows enforce RLS');
select ok((select relrowsecurity from pg_class where oid='public.test_draft_reviews'::regclass),
  'review rows enforce RLS');
select ok(has_table_privilege('authenticated','public.test_drafts','SELECT,INSERT,DELETE')
  and not has_table_privilege('authenticated','public.test_drafts','UPDATE'),
  'draft owners can read/create/delete but cannot update stored drafts');
select ok(has_table_privilege('authenticated','public.test_draft_reviews','SELECT,INSERT')
  and not has_table_privilege('authenticated','public.test_draft_reviews','UPDATE,DELETE'),
  'review history is append-only to authenticated owners');

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('00000000-0000-4000-8000-000000000111','authenticated','authenticated','draft-owner-one@example.test','',now(),'{}','{}',now(),now()),
  ('00000000-0000-4000-8000-000000000112','authenticated','authenticated','draft-owner-two@example.test','',now(),'{}','{}',now(),now());

create temporary table draft_fixture(owner_id uuid not null,draft_id uuid not null) on commit drop;
grant select,insert on draft_fixture to authenticated;

set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000111';
with created as (
  insert into public.test_drafts(owner_id,tenant_id,scenario,context,framework,language,
      test_draft,rationale,warnings,generator_kind,generator_name,generator_version)
  values(auth.uid(),auth.uid(),'A synthetic member signs in.','synthetic','playwright','typescript',
      '{"kind":"manual_test_plan","executable":false,"verification":"unverified","framework":"playwright","language":"typescript","steps":[{"id":"step-1","instruction":"Manually review sign in","expected_observation":"No browser is launched"}]}'::jsonb,
      '[{"step_id":"step-1","relation":"manual"}]','["synthetic offline draft"]','synthetic','sutra-offline-synthetic','1')
  returning id
)
insert into draft_fixture select auth.uid(),id from created;
select is((select count(*)::integer from public.test_drafts),1,
  'authenticated owner can create a draft with their user-scoped JWT');

select throws_ok($$insert into public.test_drafts(owner_id,tenant_id,scenario,framework,language,test_draft,rationale,generator_kind,generator_name,generator_version)
  values('00000000-0000-4000-8000-000000000112','00000000-0000-4000-8000-000000000112','A spoofed owner cannot write this','playwright','typescript',
  '{"kind":"manual_test_plan","executable":false,"verification":"unverified","framework":"playwright","language":"typescript","steps":[{"id":"step-1","instruction":"Review","expected_observation":"No execution"}]}'::jsonb,'[]','synthetic','test','1')$$,
  '42501',null,'owner cannot create rows for another user');

insert into public.test_draft_reviews(draft_id,tenant_id,reviewer_id,decision,comment)
select draft_id,auth.uid(),auth.uid(),'accept','Reviewed in the local SQL test'
from draft_fixture where owner_id=auth.uid();
select is((select count(*)::integer from public.test_draft_reviews),1,
  'owner can append a review for their own draft');
reset role;

set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000112';
with created as (
  insert into public.test_drafts(owner_id,tenant_id,scenario,context,framework,language,
      test_draft,rationale,warnings,generator_kind,generator_name,generator_version)
  values(auth.uid(),auth.uid(),'A second synthetic user signs in.','synthetic','playwright','typescript',
      '{"kind":"manual_test_plan","executable":false,"verification":"unverified","framework":"playwright","language":"typescript","steps":[{"id":"step-1","instruction":"Review second user","expected_observation":"No browser is launched"}]}'::jsonb,
      '[]','["synthetic offline draft"]','synthetic','sutra-offline-synthetic','1')
  returning id
)
insert into draft_fixture select auth.uid(),id from created;
insert into public.test_draft_reviews(draft_id,tenant_id,reviewer_id,decision,comment)
select draft_id,auth.uid(),auth.uid(),'reject','Private second-user test history'
from draft_fixture where owner_id=auth.uid();
reset role;

set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000111';
select is((select count(*)::integer from public.test_drafts),1,
  'owner sees only their own draft');
select is((select count(*)::integer from public.test_draft_reviews),1,
  'owner sees only review history for their own draft');
select throws_ok($$insert into public.test_draft_reviews(draft_id,tenant_id,reviewer_id,decision,comment)
  select draft_id,auth.uid(),auth.uid(),'accept','cross-user review' from draft_fixture
  where owner_id='00000000-0000-4000-8000-000000000112'$$,
  '42501',null,'owner cannot append a review to another owner draft');
reset role;

set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000112';
delete from public.test_drafts where id=(select draft_id from draft_fixture
  where owner_id='00000000-0000-4000-8000-000000000111');
reset role;
set local role authenticated;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000111';
select is((select count(*)::integer from public.test_drafts),1,
  'another user cannot delete another owner''s draft');
delete from public.test_drafts where id=(select draft_id from draft_fixture where owner_id=auth.uid());
select is((select count(*)::integer from public.test_drafts),0,
  'owner can delete their own draft');
select is((select count(*)::integer from public.test_draft_reviews),0,
  'draft deletion cascades its review history');
reset role;

select * from finish();
rollback;

begin;
select no_plan();

select ok(to_regclass('public.campaigns_created_by_agent_id_idx') is not null,
  'campaign creator foreign key is indexed');
select ok(to_regclass('public.provider_usage_probes_project_id_idx') is not null,
  'provider probe project foreign key is indexed');
select ok(to_regclass('public.test_drafts_owner_id_idx') is not null,
  'test draft owner foreign key is indexed');
select ok(to_regclass('public.test_draft_reviews_draft_id_idx') is not null,
  'draft review parent foreign key is indexed');
select ok(to_regclass('public.test_draft_reviews_reviewer_id_idx') is not null,
  'draft review author foreign key is indexed');
select ok(to_regclass('public.zendesk_reply_actions_task_id_idx') is not null,
  'support reply task foreign key is indexed');
select ok(to_regclass('public.zendesk_reply_actions_support_case_id_idx') is not null,
  'support reply case foreign key is indexed');
select ok(to_regclass('public.zendesk_reply_actions_agent_id_idx') is not null,
  'support reply agent foreign key is indexed');

select * from finish();
rollback;

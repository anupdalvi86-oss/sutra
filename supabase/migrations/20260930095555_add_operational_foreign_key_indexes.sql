-- Cover foreign keys that Supabase Advisors identified on the operational
-- tables. These indexes keep parent deletes and task/customer joins bounded.
create index if not exists campaigns_created_by_agent_id_idx
  on public.campaigns(created_by_agent_id);
create index if not exists provider_usage_probes_project_id_idx
  on public.provider_usage_probes(project_id);
create index if not exists test_drafts_owner_id_idx
  on public.test_drafts(owner_id);
create index if not exists test_draft_reviews_draft_id_idx
  on public.test_draft_reviews(draft_id);
create index if not exists test_draft_reviews_reviewer_id_idx
  on public.test_draft_reviews(reviewer_id);
create index if not exists zendesk_reply_actions_task_id_idx
  on public.zendesk_reply_actions(task_id);
create index if not exists zendesk_reply_actions_support_case_id_idx
  on public.zendesk_reply_actions(support_case_id);
create index if not exists zendesk_reply_actions_agent_id_idx
  on public.zendesk_reply_actions(agent_id);

-- Cover review evidence foreign keys and avoid advisor warnings on joins/deletes.
create index task_review_evidence_reviewer_idx on public.task_review_evidence(reviewer_agent_id);
create index task_review_evidence_developer_task_idx on public.task_review_evidence(developer_task_id);

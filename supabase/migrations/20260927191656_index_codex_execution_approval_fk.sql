-- Support joins and FK checks from approvals to Codex executions.
create index if not exists codex_task_executions_approval_id_idx
  on public.codex_task_executions (approval_id);

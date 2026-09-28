-- Preserve each failed Codex attempt and permit only a founder-authorized retry
-- when the metering gateway proves it admitted no provider request.
create table public.codex_task_execution_attempts (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null references public.codex_task_executions(id) on delete restrict,
  task_id uuid not null references public.tasks(id) on delete restrict,
  attempt_number smallint not null check (attempt_number between 1 and 2),
  agent_run_id uuid not null references public.agent_runs(id) on delete restrict,
  reservation_id uuid not null references public.agent_run_spend_reservations(id) on delete restrict,
  status text not null,
  request_count integer not null check (request_count between 0 and 3),
  input_tokens bigint not null check (input_tokens >= 0),
  output_tokens bigint not null check (output_tokens >= 0),
  retried_by text not null,
  created_at timestamptz not null default now(),
  unique (execution_id, attempt_number),
  unique (agent_run_id),
  unique (reservation_id)
);
alter table public.codex_task_execution_attempts enable row level security;
revoke all on public.codex_task_execution_attempts from public, anon, authenticated, service_role;
create index codex_task_execution_attempts_task_idx
  on public.codex_task_execution_attempts(task_id, attempt_number);

create or replace function public.sutra_founder_retry_codex_task_execution(
  p_founder_telegram_user_id text,
  p_task_id uuid
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  founder_id text;
  task_row public.tasks%rowtype;
  project_row public.projects%rowtype;
  execution_row public.codex_task_executions%rowtype;
  failed_run public.agent_runs%rowtype;
  reservation_row public.agent_run_spend_reservations%rowtype;
  developer_id uuid;
  approval_id uuid;
  retry_number smallint;
  new_run_id uuid;
  new_lease uuid;
  reserve_result jsonb;
  new_reservation_id uuid;
begin
  if p_founder_telegram_user_id is null or length(p_founder_telegram_user_id) not between 1 and 64
    or p_task_id is null then
    raise exception 'malformed Codex retry request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder can retry Codex' using errcode='42501';
  end if;

  select * into task_row from public.tasks where id=p_task_id for update;
  if not found or task_row.task_type<>'engineering' or task_row.status<>'in_progress' then
    raise exception 'Codex retry requires the existing in-progress engineering task' using errcode='42501';
  end if;
  select a.id into developer_id from public.agents a where a.slug='developer' and a.active;
  select * into project_row from public.projects p where p.id=task_row.project_id for update;
  if developer_id is null or project_row.id is null or project_row.status not in ('approved','active')
    or task_row.owner_agent_id<>developer_id or task_row.assigned_agent_id<>developer_id then
    raise exception 'Codex retry requires the same assigned Developer and approved project' using errcode='42501';
  end if;
  select id into approval_id from public.approvals a where a.project_id=task_row.project_id
    and a.approval_type='project_budget' and a.status='approved'
    and a.decisions #>> '{founder,decision}'='approve'
  order by a.decided_at desc nulls last limit 1;
  if approval_id is null or not exists (
      select 1 from public.approvals a where a.approval_type='developer_scope'
        and a.action_ref=p_task_id::text and a.project_id=task_row.project_id
        and a.status='approved' and a.decisions #>> '{founder,decision}'='approve') then
    raise exception 'Codex retry requires the existing founder-approved project and Developer scope' using errcode='42501';
  end if;
  if not exists(select 1 from public.github_task_dispatches d where d.task_id=p_task_id
      and d.status='created' and d.pull_request_number is null and d.pull_request_merged=false) then
    raise exception 'Codex retry requires the existing signed GitHub issue with no pull request' using errcode='42501';
  end if;

  select * into execution_row from public.codex_task_executions e where e.task_id=p_task_id for update;
  if not found or execution_row.status<>'unknown' or execution_row.request_count<>0
    or execution_row.input_tokens<>0 or execution_row.output_tokens<>0
    or execution_row.reservation_id is null then
    raise exception 'Codex retry requires a terminal failure with zero provider requests and usage' using errcode='42501';
  end if;
  select * into failed_run from public.agent_runs r where r.id=execution_row.agent_run_id for update;
  select * into reservation_row from public.agent_run_spend_reservations s
    where s.id=execution_row.reservation_id for update;
  if failed_run.status<>'failed' or failed_run.trigger_type<>'codex_execution'
    or failed_run.lease_token is not null or failed_run.lease_expires_at is not null
    or failed_run.output->>'codex_execution_status'<>'unknown'
    or reservation_row.status<>'unknown'
    or reservation_row.usage->>'reason'<>'Codex execution ended without trusted complete usage'
    or exists(select 1 from public.codex_task_execution_attempts a where a.execution_id=execution_row.id
       and a.attempt_number>=2) then
    raise exception 'Codex retry is limited to a verified no-request terminal failure and one retry' using errcode='42501';
  end if;
  retry_number:=coalesce((select max(attempt_number)+1 from public.codex_task_execution_attempts
      where execution_id=execution_row.id),1);

  insert into public.codex_task_execution_attempts(execution_id,task_id,attempt_number,agent_run_id,
      reservation_id,status,request_count,input_tokens,output_tokens,retried_by)
    values(execution_row.id,p_task_id,retry_number,execution_row.agent_run_id,
      execution_row.reservation_id,execution_row.status,execution_row.request_count,
      execution_row.input_tokens,execution_row.output_tokens,founder_id);

  new_run_id:=gen_random_uuid();
  new_lease:=gen_random_uuid();
  insert into public.agent_runs(id,agent_id,project_id,task_id,trigger_type,status,input,output,
      started_at,lease_token,lease_expires_at,attempt_count)
    values(new_run_id,developer_id,task_row.project_id,task_row.id,'codex_execution','running',
      jsonb_build_object('task_id',task_row.id,'issue_number',execution_row.issue_number,
        'provider',execution_row.provider,'model',execution_row.model,'founder_retry_number',retry_number+1),
      '{}'::jsonb,now(),new_lease,now()+interval '2 hours',1);
  update public.codex_task_executions set agent_run_id=new_run_id,reservation_id=null,
    approval_id=null,request_count=0,input_tokens=0,output_tokens=0,status='running',
    runner_claimed_at=null,updated_at=now() where id=execution_row.id returning * into execution_row;

  reserve_result:=public.sutra_reserve_agent_run_spend_from_profile(
    'sutra-worker-founderretry1',new_run_id,new_lease,execution_row.provider,execution_row.model);
  new_reservation_id:=(reserve_result->>'reservation_id')::uuid;
  update public.codex_task_executions set reservation_id=new_reservation_id,
    approval_id=nullif(reserve_result->>'approval_id','')::uuid,
    status=case when reserve_result->>'status'='approved' then 'running' else 'awaiting_approval' end,
    updated_at=now() where id=execution_row.id;
  if reserve_result->>'status'<>'approved' then
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('founder',founder_id,'founder.codex_retry_awaiting_spend_approval','task',p_task_id::text,
        jsonb_build_object('execution_id',execution_row.id,'prior_run_id',failed_run.id,
          'new_run_id',new_run_id,'reservation_id',new_reservation_id,
          'retry_number',retry_number,'project_spending_authorized',false));
    return jsonb_build_object('task_id',p_task_id,'status','awaiting_approval',
      'approval_id',reserve_result->>'approval_id','retry_number',retry_number);
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'founder.codex_task_retry_requested','task',p_task_id::text,
      jsonb_build_object('execution_id',execution_row.id,'prior_run_id',failed_run.id,
        'prior_reservation_id',reservation_row.id,'new_run_id',new_run_id,
        'new_reservation_id',new_reservation_id,'retry_number',retry_number,
        'prior_request_count',0,'prior_tokens',0,'unknown_reservation_preserved',true,
        'project_spending_authorized',false,'merge_release_authorized',false));
  return jsonb_build_object('task_id',p_task_id,'status','queued','execution_id',execution_row.id,
    'run_id',new_run_id,'retry_number',retry_number,'old_unknown_reservation_preserved',true,
    'project_spending_authorized',false);
end;
$$;

revoke all on function public.sutra_founder_retry_codex_task_execution(text,uuid) from public,anon,authenticated;
grant execute on function public.sutra_founder_retry_codex_task_execution(text,uuid) to service_role;

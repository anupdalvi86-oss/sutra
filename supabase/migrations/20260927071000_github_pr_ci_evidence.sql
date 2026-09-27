-- Signed GitHub PR/CI events are durable inputs to engineering/QA handoffs.
alter table public.github_task_dispatches
  add column pull_request_number integer,
  add column pull_request_url text,
  add column pull_request_head_sha text,
  add column pull_request_merged boolean not null default false,
  add column ci_conclusion text,
  add column ci_run_url text,
  add column ci_head_sha text;

alter table public.github_task_dispatches
  add constraint github_task_dispatch_pr_number check (pull_request_number is null or pull_request_number > 0),
  add constraint github_task_dispatch_pr_url check (pull_request_url is null or
    pull_request_url ~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$'),
  add constraint github_task_dispatch_pr_shape check (
    (pull_request_number is null and pull_request_url is null and pull_request_head_sha is null and not pull_request_merged)
    or (pull_request_number is not null and pull_request_url is not null and pull_request_head_sha ~ '^[a-fA-F0-9]{40}$')
  ),
  add constraint github_task_dispatch_ci_conclusion check (ci_conclusion is null or ci_conclusion in
    ('success','failure','cancelled','timed_out','action_required','stale','skipped','neutral')),
  add constraint github_task_dispatch_ci_shape check (
    (ci_conclusion is null and ci_run_url is null and ci_head_sha is null)
    or (ci_conclusion is not null and ci_run_url is not null and ci_head_sha ~ '^[a-fA-F0-9]{40}$')
  ),
  add constraint github_task_dispatch_ci_url check (ci_run_url is null or
    ci_run_url ~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*$');

create unique index github_task_dispatch_pr_number_unique on public.github_task_dispatches(pull_request_number)
  where pull_request_number is not null;

create table public.github_webhook_deliveries (
  delivery_id uuid primary key,
  event_name text not null check (event_name in ('pull_request','workflow_run')),
  repository text not null check (repository ~ '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'),
  normalized_event jsonb not null check (jsonb_typeof(normalized_event)='object' and octet_length(normalized_event::text)<=8000),
  result jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now()
);
alter table public.github_webhook_deliveries enable row level security;
revoke all on public.github_webhook_deliveries from public,anon,authenticated,service_role;

create function public.sutra_record_github_webhook_event(
  p_worker_id text,p_delivery_id uuid,p_repository text,p_event_name text,p_event jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare inserted_id uuid; task_uuid uuid; dispatch_row public.github_task_dispatches%rowtype;
  pr_number integer; issue_number integer; pr_url text; head_sha text; merged boolean;
  workflow_name text; conclusion text; run_url text; pr_numbers jsonb; prior_ci_event jsonb; completed_count integer:=0;
  task_row public.tasks%rowtype; project_status text;
begin
  if p_worker_id is null or p_worker_id !~ '^sutra-github-webhook-[a-z0-9]{8,64}$'
    or p_delivery_id is null or p_repository is null
    or p_repository !~ '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'
    or p_event_name is null or p_event_name not in ('pull_request','workflow_run')
    or p_event is null or jsonb_typeof(p_event)<>'object' or octet_length(p_event::text)>8000
    or p_event->>'kind' is distinct from p_event_name then
    raise exception 'malformed signed GitHub event' using errcode='22023';
  end if;
  insert into public.github_webhook_deliveries(delivery_id,event_name,repository,normalized_event)
  values(p_delivery_id,p_event_name,p_repository,p_event) on conflict(delivery_id) do nothing
  returning delivery_id into inserted_id;
  if inserted_id is null then return jsonb_build_object('duplicate',true,'completed_tasks',0); end if;

  if p_event_name='pull_request' then
    begin
      task_uuid:=(p_event->>'task_id')::uuid;
      pr_number:=(p_event->>'pull_request_number')::integer;
      issue_number:=(p_event->>'issue_number')::integer;
    exception when others then raise exception 'malformed GitHub pull request identifiers' using errcode='22023'; end;
    pr_url:=p_event->>'pull_request_url'; head_sha:=p_event->>'head_sha';
    merged:=p_event->>'merged'='true';
    if task_uuid is null or pr_number is null or issue_number is null or pr_number<1 or issue_number<1
      or p_event->>'action' is null or p_event->>'action' not in ('opened','edited','synchronize','reopened','closed')
      or p_event->>'base_ref' is distinct from 'main'
      or p_event->'merged' is null or jsonb_typeof(p_event->'merged') is distinct from 'boolean'
      or pr_url is null or head_sha is null
      or lower(split_part(pr_url,'/',3))<>'github.com'
      or lower(split_part(pr_url,'/',4)||'/'||split_part(pr_url,'/',5))<>lower(p_repository)
      or split_part(pr_url,'/',6)<>'pull' or split_part(pr_url,'/',7)<>pr_number::text
      or head_sha !~ '^[a-fA-F0-9]{40}$' then
      raise exception 'GitHub pull request is not a valid Sutra task handoff' using errcode='22023';
    end if;
    select * into dispatch_row from public.github_task_dispatches d
      where d.task_id=task_uuid and d.status='created' and d.issue_number=issue_number
        and d.issue_url is not null for update;
    if not found then
      update public.github_webhook_deliveries set result=jsonb_build_object('ignored','unlinked_task') where delivery_id=p_delivery_id;
      return jsonb_build_object('accepted',true,'ignored','unlinked_task','completed_tasks',0);
    end if;
    if lower(p_repository) is distinct from lower(split_part(dispatch_row.issue_url, '/', 4)
        || '/' || split_part(dispatch_row.issue_url, '/', 5))
    then
      raise exception 'GitHub pull request is not a valid Sutra task handoff' using errcode='22023';
    end if;
    if dispatch_row.pull_request_number is not null and dispatch_row.pull_request_number<>pr_number then
      update public.github_webhook_deliveries set result=jsonb_build_object('ignored','task_already_has_pull_request') where delivery_id=p_delivery_id;
      return jsonb_build_object('accepted',true,'ignored','task_already_has_pull_request','completed_tasks',0);
    end if;
    select d.normalized_event into prior_ci_event from public.github_webhook_deliveries d
      where d.event_name='workflow_run' and lower(d.repository)=lower(p_repository)
        and d.normalized_event->'pull_requests' @> jsonb_build_array(
          jsonb_build_object('number',pr_number,'head_sha',head_sha))
      order by d.received_at desc limit 1;
    update public.github_task_dispatches set pull_request_number=pr_number,pull_request_url=pr_url,
      pull_request_head_sha=head_sha,pull_request_merged=merged,
      ci_conclusion=case when ci_head_sha=head_sha then ci_conclusion else prior_ci_event->>'conclusion' end,
      ci_run_url=case when ci_head_sha=head_sha then ci_run_url else prior_ci_event->>'run_url' end,
      ci_head_sha=case when ci_head_sha=head_sha then ci_head_sha
        when prior_ci_event is not null then head_sha else null end,updated_at=now()
      where id=dispatch_row.id returning * into dispatch_row;
    insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
      values('system',p_worker_id,'github.pull_request_linked','task',task_uuid::text,
        jsonb_build_object('delivery_id',p_delivery_id,'pull_request_number',pr_number,'pull_request_url',pr_url,
          'merged',merged,'head_sha',head_sha));
    if dispatch_row.ci_conclusion is not null and dispatch_row.ci_run_url is not null then
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system',p_worker_id,'github.ci_completed','task',task_uuid::text,
          jsonb_build_object('delivery_id',p_delivery_id,'workflow_name','CI','conclusion',dispatch_row.ci_conclusion,
            'run_url',dispatch_row.ci_run_url,'head_sha',head_sha,'pull_request_number',pr_number,
            'recovered_from_earlier_delivery',true));
    end if;
  else
    workflow_name:=p_event->>'workflow_name'; conclusion:=p_event->>'conclusion';
    run_url:=p_event->>'run_url'; head_sha:=p_event->>'head_sha'; pr_numbers:=p_event->'pull_requests';
    if workflow_name is distinct from 'CI' or conclusion is null or conclusion not in ('success','failure','cancelled','timed_out','action_required','stale','skipped','neutral')
      or run_url is null or head_sha is null
      or lower(split_part(run_url,'/',3))<>'github.com'
      or lower(split_part(run_url,'/',4)||'/'||split_part(run_url,'/',5))<>lower(p_repository)
      or split_part(run_url,'/',6)<>'actions' or split_part(run_url,'/',7)<>'runs'
      or split_part(run_url,'/',8) !~ '^[1-9][0-9]*$'
      or head_sha !~ '^[a-fA-F0-9]{40}$' or jsonb_typeof(pr_numbers) is distinct from 'array' then
      raise exception 'GitHub workflow evidence is malformed or not from the Sutra CI workflow' using errcode='22023';
    end if;
    if jsonb_array_length(pr_numbers)>30 or exists (
      select 1 from jsonb_array_elements(pr_numbers) entry(value)
      where jsonb_typeof(entry.value) is distinct from 'object'
        or entry.value->>'number' is null or entry.value->>'number' !~ '^[1-9][0-9]{0,9}$'
        or entry.value->>'head_sha' is null or entry.value->>'head_sha' !~ '^[a-fA-F0-9]{40}$'
    ) then
      raise exception 'GitHub workflow pull request list is malformed' using errcode='22023';
    end if;
    if exists (select 1 from jsonb_array_elements(pr_numbers) entry(value)
      where (entry.value->>'number')::numeric>2147483647) then
      raise exception 'GitHub workflow pull request number is outside the supported range' using errcode='22023';
    end if;
    update public.github_task_dispatches d set ci_conclusion=conclusion,ci_run_url=run_url,
      ci_head_sha=lower(entry.value->>'head_sha'),updated_at=now()
      from jsonb_array_elements(pr_numbers) entry(value)
      where d.status='created' and d.pull_request_number=(entry.value->>'number')::integer
        and d.pull_request_head_sha=lower(entry.value->>'head_sha')
        and lower(split_part(d.issue_url,'/',4)||'/'||split_part(d.issue_url,'/',5))=lower(p_repository);
    for dispatch_row in select d.* from public.github_task_dispatches d
      join jsonb_array_elements(pr_numbers) entry(value)
        on d.pull_request_number=(entry.value->>'number')::integer
        and d.pull_request_head_sha=lower(entry.value->>'head_sha')
      where d.status='created'
        and lower(split_part(d.issue_url,'/',4)||'/'||split_part(d.issue_url,'/',5))=lower(p_repository)
    loop
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system',p_worker_id,'github.ci_completed','task',dispatch_row.task_id::text,
          jsonb_build_object('delivery_id',p_delivery_id,'workflow_name',workflow_name,'conclusion',conclusion,
            'run_url',run_url,'head_sha',head_sha,'pull_request_number',dispatch_row.pull_request_number));
    end loop;
  end if;

  for dispatch_row in select d.* from public.github_task_dispatches d
    join public.tasks t on t.id=d.task_id and t.status='in_progress'
    join public.projects p on p.id=t.project_id and p.status in ('approved','active')
    where d.status='created' and d.pull_request_merged and d.ci_conclusion='success'
      and d.ci_head_sha=d.pull_request_head_sha and d.pull_request_url is not null
      and lower(split_part(d.issue_url,'/',4)||'/'||split_part(d.issue_url,'/',5))=lower(p_repository)
    for update of d skip locked
  loop
    update public.tasks set status='done',updated_at=now() where id=dispatch_row.task_id and status='in_progress';
    if found then
      insert into public.agent_runs(agent_id,project_id,task_id,trigger_type,status,input,output,started_at,finished_at)
        select t.assigned_agent_id,t.project_id,t.id,'github_ci_review','succeeded',
          jsonb_build_object('source','signed_github_webhook'),
          jsonb_build_object('pull_request_url',dispatch_row.pull_request_url,'pull_request_head_sha',dispatch_row.pull_request_head_sha,
            'workflow','CI','ci_conclusion',dispatch_row.ci_conclusion,'ci_run_url',dispatch_row.ci_run_url),now(),now()
          from public.tasks t where t.id=dispatch_row.task_id;
      insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
        values('system',p_worker_id,'github.developer_task_verified','task',dispatch_row.task_id::text,
          jsonb_build_object('pull_request_url',dispatch_row.pull_request_url,'ci_run_url',dispatch_row.ci_run_url,
            'head_sha',dispatch_row.pull_request_head_sha));
      completed_count:=completed_count+1;
    end if;
  end loop;

  update public.github_webhook_deliveries set result=jsonb_build_object('accepted',true,'completed_tasks',completed_count)
    where delivery_id=p_delivery_id;
  return jsonb_build_object('accepted',true,'completed_tasks',completed_count);
end $$;

revoke all on function public.sutra_record_github_webhook_event(text,uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.sutra_record_github_webhook_event(text,uuid,text,text,jsonb) to service_role;

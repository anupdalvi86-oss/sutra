-- Queue one audited CFO-only review for an existing, explicitly budgeted
-- initiative. This reuses the normal leased founder-proposal worker and its
-- spend reservation and assessment triggers; it cannot alter the ceiling.
create or replace function public.sutra_founder_queue_initiative_cfo_assessment(
  p_founder_telegram_user_id text,p_project_id uuid,p_scope text
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare founder_id text; project_row public.projects%rowtype; cfo_id uuid; run_id uuid;
begin
  if p_founder_telegram_user_id is null or p_project_id is null or p_scope is null
    or length(trim(p_scope)) not between 20 and 2000 or p_scope ~ '[[:cntrl:]]' then
    raise exception 'malformed initiative CFO assessment request' using errcode='22023';
  end if;
  select value #>> '{}' into founder_id from public.company_settings
    where key='founder_telegram_user_id' for update;
  if founder_id is null or founder_id<>p_founder_telegram_user_id then
    raise exception 'only the configured founder may request an initiative CFO assessment' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('sutra-budget:EUR'));
  perform pg_advisory_xact_lock(hashtext('sutra-initiative-budget:'||p_project_id::text));
  select * into project_row from public.projects where id=p_project_id for update;
  if not found or project_row.status not in ('active','proposed')
    or project_row.currency<>'EUR' or project_row.requested_budget is null or project_row.requested_budget<=0
    or project_row.budget_assessment_status<>'unassessed' then
    raise exception 'initiative must be active or proposed, explicitly budgeted in EUR, and unassessed' using errcode='42501';
  end if;
  if exists(select 1 from public.agent_runs r where r.project_id=p_project_id
      and r.trigger_type='founder_proposal') then
    raise exception 'initiative already has a founder proposal review sequence' using errcode='23505';
  end if;
  select id into cfo_id from public.agents where slug='cfo' and active;
  if cfo_id is null then raise exception 'active CFO agent is required' using errcode='23514'; end if;
  insert into public.agent_runs(agent_id,project_id,trigger_type,status,run_order,input,output)
    values(cfo_id,p_project_id,'founder_proposal','queued',1,
      jsonb_build_object('request','Founder-requested CFO-only all-in budget assessment of the existing initiative. '
        ||'Estimate costs for the supplied implementation scope. Preserve the existing founder ceiling; do not authorize '
        ||'spending beyond it or start other department reviews. Scope: '||trim(p_scope)), '{}'::jsonb)
    returning id into run_id;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('founder',founder_id,'initiative.cfo_assessment_requested','project',p_project_id::text,
      jsonb_build_object('agent_run_id',run_id,'budget_cap_eur',project_row.requested_budget,
        'scope',left(trim(p_scope),1000)));
  return jsonb_build_object('project_id',p_project_id,'agent_run_id',run_id,
    'status','queued','budget_cap_eur',project_row.requested_budget);
end;
$$;
revoke all on function public.sutra_founder_queue_initiative_cfo_assessment(text,uuid,text) from public,anon,authenticated;
grant execute on function public.sutra_founder_queue_initiative_cfo_assessment(text,uuid,text) to service_role;

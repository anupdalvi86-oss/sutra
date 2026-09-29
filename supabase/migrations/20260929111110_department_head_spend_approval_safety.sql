-- Department heads are explicitly assigned by the founder for each department.
-- The assignment can name a leader from another department (for example, CTO
-- for the one-agent Security department); the scoped setting remains the gate.
-- An agent may never approve an expense it requested.
create or replace function public.sutra_decide_role_approval(
  p_approval_id uuid,p_actor_id text,p_actor_role text,p_decision text,p_comment text default ''
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare approval_row public.approvals%rowtype; actor_ok boolean; next_status text; approval_department_id uuid;
begin
  if p_decision not in ('approve','reject') or p_actor_role not in ('ceo','cfo','department_head') then raise exception 'invalid role approval request' using errcode = '22023'; end if;
  select * into approval_row from public.approvals where id=p_approval_id for update;
  if not found or approval_row.status <> 'pending' or not (p_actor_role = any(approval_row.required_roles)) then raise exception 'approval is missing, resolved, or not assigned to this role' using errcode = '42501'; end if;
  if p_actor_role = 'department_head' then
    if approval_row.expense_id is not null and approval_row.requested_by_agent_id=(
      select a.id from public.agents a where a.id::text=p_actor_id and a.active
    ) then
      raise exception 'agents cannot approve their own expenses' using errcode = '42501';
    end if;
    select coalesce(p.department_id, e.department_id) into approval_department_id
      from public.approvals ap
      left join public.projects p on p.id=ap.project_id
      left join public.expenses e on e.id=ap.expense_id
      where ap.id=p_approval_id;
    select exists(
      select 1 from public.company_settings s
      join public.agents a on a.id::text = s.value #>> '{}'
      where s.key='department_head:' || approval_department_id::text
        and a.id::text=p_actor_id and a.active
    ) into actor_ok;
  else
    select exists(select 1 from public.agents a where a.id::text=p_actor_id and a.slug=p_actor_role and a.active) into actor_ok;
  end if;
  if not coalesce(actor_ok,false) then raise exception 'agent identity does not match the approving role' using errcode = '42501'; end if;
  if approval_row.decisions ? p_actor_role then raise exception 'role has already decided this approval' using errcode = '23505'; end if;
  approval_row.decisions := approval_row.decisions || jsonb_build_object(p_actor_role,
    jsonb_build_object('decision',p_decision,'actor_id',p_actor_id,'comment',left(coalesce(p_comment,''),2000)));
  if p_decision='reject' then next_status:='rejected';
  elsif not exists(select 1 from unnest(approval_row.required_roles) as r(role)
    where coalesce(approval_row.decisions #>> array[r.role,'decision'],'') <> 'approve' and r.role <> p_actor_role) then next_status:='approved';
  else next_status:='pending'; end if;
  update public.approvals set status=next_status,decisions=approval_row.decisions,
    decided_by=case when next_status in ('approved','rejected') then 'role:' || p_actor_role else null end,
    decided_at=case when next_status in ('approved','rejected') then now() else null end where id=p_approval_id;
  if approval_row.expense_id is not null and next_status in ('approved','rejected') then
    update public.expenses set status=next_status,approved_at=case when next_status='approved' then now() else null end where id=approval_row.expense_id;
  end if;
  insert into public.audit_log(actor_type,actor_id,action,resource_type,resource_id,details)
    values('agent',p_actor_id,'approval.' || p_decision,'approval',p_approval_id::text,jsonb_build_object('role',p_actor_role,'status',next_status,'comment',left(coalesce(p_comment,''),2000)));
  return jsonb_build_object('approval_id',p_approval_id,'status',next_status,'decided_role',p_actor_role);
end;
$$;

revoke all on function public.sutra_decide_role_approval(uuid,text,text,text,text) from public, anon, authenticated;
grant execute on function public.sutra_decide_role_approval(uuid,text,text,text,text) to service_role;

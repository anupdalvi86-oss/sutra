-- A Sutra probe is one Hermes invocation, but the existing Hermes loop can
-- issue up to three upstream model requests. Correct the persisted control
-- evidence before insertion without rewriting append-only historical audits.

create function public.sutra_clarify_kimi_probe_audit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.action = 'founder.kimi_usage_probe_requested' then
    new.details := (coalesce(new.details, '{}'::jsonb) - 'one_provider_request')
      || jsonb_build_object('one_hermes_invocation', true, 'max_model_iterations', 3);
  end if;
  return new;
end;
$$;

revoke all on function public.sutra_clarify_kimi_probe_audit() from public, anon, authenticated, service_role;
create trigger clarify_kimi_probe_audit_before_insert
  before insert on public.audit_log
  for each row
  when (new.action = 'founder.kimi_usage_probe_requested')
  execute function public.sutra_clarify_kimi_probe_audit();

create function public.sutra_clarify_kimi_probe_decision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.decision_type = 'founder_operational_authorization'
    and new.summary = 'Founder authorized one Kimi usage reconciliation probe up to EUR 0.10.' then
    new.rationale := 'This one-shot internal diagnostic creates one Sutra-to-Hermes invocation. Hermes may make up to three upstream model requests under the active Kimi price profile reservation, capped by ordinary spend policies and the company monthly hard stop. It does not enable ordinary Kimi routes or authorize any other project spending or external action.';
  end if;
  return new;
end;
$$;

revoke all on function public.sutra_clarify_kimi_probe_decision() from public, anon, authenticated, service_role;
create trigger clarify_kimi_probe_decision_before_insert
  before insert on public.decisions
  for each row
  when (new.decision_type = 'founder_operational_authorization')
  execute function public.sutra_clarify_kimi_probe_decision();

-- A worker must not be able to reconcile token counts that disagree with the
-- provider usage evidence stored alongside them. Hermes uses Chat Completions
-- field names; the metered Codex runner records Responses field names.
create or replace function public.sutra_reconcile_agent_run_spend_from_usage(
  p_worker_id text,p_run_id uuid,p_lease_token uuid,p_reservation_id uuid,
  p_provider text,p_model text,p_input_tokens bigint,p_output_tokens bigint,p_usage jsonb,p_usage_known boolean
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  reservation public.agent_run_spend_reservations%rowtype;
  actual_amount numeric(14,2);
  usage_input numeric;
  usage_output numeric;
  usage_total numeric;
  has_chat_usage boolean;
  has_responses_usage boolean;
begin
  select * into reservation from public.agent_run_spend_reservations s where s.id=p_reservation_id;
  if not found then raise exception 'agent spend reservation was not found' using errcode='42501'; end if;
  if p_usage_known then
    if p_input_tokens is null or p_input_tokens<0 or p_output_tokens is null or p_output_tokens<0
      or jsonb_typeof(p_usage) is distinct from 'object' then
      raise exception 'malformed model token usage' using errcode='22023';
    end if;

    has_chat_usage := p_usage ?| array['prompt_tokens','completion_tokens','total_tokens'];
    has_responses_usage := p_usage ?| array['input_tokens','output_tokens'];
    if has_chat_usage = has_responses_usage then
      raise exception 'model usage has a missing or ambiguous token schema' using errcode='22023';
    end if;

    if has_chat_usage then
      if jsonb_typeof(p_usage->'prompt_tokens') is distinct from 'number'
        or p_usage->>'prompt_tokens' !~ '^(0|[1-9][0-9]*)$'
        or jsonb_typeof(p_usage->'completion_tokens') is distinct from 'number'
        or p_usage->>'completion_tokens' !~ '^(0|[1-9][0-9]*)$'
        or jsonb_typeof(p_usage->'total_tokens') is distinct from 'number'
        or p_usage->>'total_tokens' !~ '^(0|[1-9][0-9]*)$' then
        raise exception 'malformed Chat Completions usage envelope' using errcode='22023';
      end if;
      usage_input := (p_usage->>'prompt_tokens')::numeric;
      usage_output := (p_usage->>'completion_tokens')::numeric;
      usage_total := (p_usage->>'total_tokens')::numeric;
      if usage_input<>p_input_tokens or usage_output<>p_output_tokens
        or usage_total<>usage_input+usage_output then
        raise exception 'Chat Completions usage counts disagree with the reconciled token counts' using errcode='22023';
      end if;
    else
      if jsonb_typeof(p_usage->'input_tokens') is distinct from 'number'
        or p_usage->>'input_tokens' !~ '^(0|[1-9][0-9]*)$'
        or jsonb_typeof(p_usage->'output_tokens') is distinct from 'number'
        or p_usage->>'output_tokens' !~ '^(0|[1-9][0-9]*)$' then
        raise exception 'malformed Responses usage envelope' using errcode='22023';
      end if;
      usage_input := (p_usage->>'input_tokens')::numeric;
      usage_output := (p_usage->>'output_tokens')::numeric;
      if usage_input<>p_input_tokens or usage_output<>p_output_tokens then
        raise exception 'Responses usage counts disagree with the reconciled token counts' using errcode='22023';
      end if;
    end if;

    actual_amount := ceil((p_input_tokens*reservation.input_eur_per_million_tokens
      + p_output_tokens*reservation.output_eur_per_million_tokens)/10000)/100;
  end if;
  return public.sutra_reconcile_agent_run_spend(p_worker_id,p_run_id,p_lease_token,p_reservation_id,
    p_provider,p_model,actual_amount,p_input_tokens,p_output_tokens,p_usage,p_usage_known);
end $$;

revoke all on function public.sutra_reconcile_agent_run_spend_from_usage(text,uuid,uuid,uuid,text,text,bigint,bigint,jsonb,boolean)
  from public,anon,authenticated;
grant execute on function public.sutra_reconcile_agent_run_spend_from_usage(text,uuid,uuid,uuid,text,text,bigint,bigint,jsonb,boolean)
  to service_role;

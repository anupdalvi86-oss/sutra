"""Apply Sutra's cost-critical request controls to the pinned Hermes source."""

from pathlib import Path
import os


ROOT = Path(os.environ.get("HERMES_SOURCE_ROOT", "/opt/hermes"))


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Hermes pin does not match expected {label} source (found {count})")
    return source.replace(old, new, 1)


def patch_api_server() -> None:
    path = ROOT / "gateway/platforms/api_server.py"
    source = path.read_text(encoding="utf-8")
    if "SUTRA_ENFORCE_MAX_TOKENS_AND_ROUTE_LOCK_V1" in source:
        return
    source = replace_once(
        source,
        '    if isinstance(model_options, dict):\n'
        '        overrides["model_options"] = dict(model_options)\n'
        '    return overrides\n',
        '    if isinstance(model_options, dict):\n'
        '        overrides["model_options"] = dict(model_options)\n'
        '    # SUTRA_ENFORCE_MAX_TOKENS_AND_ROUTE_LOCK_V1\n'
        '    if "max_tokens" in body:\n'
        '        max_tokens = body.get("max_tokens")\n'
        '        if isinstance(max_tokens, bool) or not isinstance(max_tokens, int) or not 1 <= max_tokens <= 32768:\n'
        '            raise ValueError("max_tokens must be an integer from 1 to 32768")\n'
        '        overrides["max_tokens"] = max_tokens\n'
        '    if body.get("require_model_lock") is True:\n'
        '        overrides["confirmed_runtime_lock"] = True\n'
        '    return overrides\n',
        "request override parser",
    )
    source = replace_once(
        source,
        '        model_options: Optional[Dict[str, Any]] = None, route: Optional[Dict[str, Any]] = None,\n'
        '        session_model: Optional[str] = None, confirmed_runtime_lock: bool = False,\n',
        '        model_options: Optional[Dict[str, Any]] = None, max_tokens: Optional[int] = None,\n'
        '        route: Optional[Dict[str, Any]] = None, session_model: Optional[str] = None,\n'
        '        confirmed_runtime_lock: bool = False,\n',
        "agent factory signature",
    )
    source = replace_once(
        source,
        '            "max_iterations": max_iterations, "quiet_mode": True, "verbose_logging": False,\n',
        '            "max_iterations": max_iterations, "max_tokens": max_tokens,\n'
        '            "quiet_mode": True, "verbose_logging": False,\n',
        "AIAgent max_tokens forwarding",
    )
    source = replace_once(
        source,
        '        requested_provider: Optional[str] = None, model_options: Optional[Dict[str, Any]] = None,\n'
        '        route: Optional[Dict[str, Any]] = None, session_model: Optional[str] = None,\n',
        '        requested_provider: Optional[str] = None, model_options: Optional[Dict[str, Any]] = None,\n'
        '        max_tokens: Optional[int] = None, route: Optional[Dict[str, Any]] = None,\n'
        '        session_model: Optional[str] = None,\n',
        "agent run signature",
    )
    source = replace_once(
        source,
        '        loop = asyncio.get_running_loop()\n'
        '        # ContextVars do not follow run_in_executor threads: capture here, re-enter in _run().\n',
        '        if max_tokens is not None and (isinstance(max_tokens, bool) or not isinstance(max_tokens, int) or not 1 <= max_tokens <= 32768):\n'
        '            raise ValueError("max_tokens must be an integer from 1 to 32768")\n'
        '        if confirmed_runtime_lock and (not requested_provider or not requested_model):\n'
        '            raise ValueError("A locked Hermes request requires an exact provider and model")\n'
        '        loop = asyncio.get_running_loop()\n'
        '        # ContextVars do not follow run_in_executor threads: capture here, re-enter in _run().\n',
        "fail-closed run validation",
    )
    source = replace_once(
        source,
        '                        requested_provider=requested_provider, model_options=model_options, route=route,\n',
        '                        requested_provider=requested_provider, model_options=model_options,\n'
        '                        max_tokens=max_tokens, route=route,\n',
        "agent factory max_tokens forwarding",
    )
    compile(source, str(path), "exec")
    path.write_text(source, encoding="utf-8")


def patch_openai_routes() -> None:
    path = ROOT / "gateway/platforms/api_server_openai_routes.py"
    source = path.read_text(encoding="utf-8")
    if "SUTRA_REJECT_INVALID_COST_CONTROLS_V1" in source:
        return
    source = replace_once(
        source,
        '        overrides = _request_agent_overrides(\n'
        '            body, virtual_model=self._model_name, allow_bare_model=self._direct_model_requests)\n',
        '        # SUTRA_REJECT_INVALID_COST_CONTROLS_V1\n'
        '        try:\n'
        '            overrides = _request_agent_overrides(\n'
        '                body, virtual_model=self._model_name, allow_bare_model=self._direct_model_requests)\n'
        '        except ValueError as exc:\n'
        '            return None, {}, _error_response(str(exc), 400)\n',
        "OpenAI-compatible route validation",
    )
    source = replace_once(
        source,
        '            fingerprint_keys=["model", "provider", "model_options", "messages", "tools", "tool_choice", "stream",\n',
        '            fingerprint_keys=["model", "provider", "model_options", "max_tokens", "require_model_lock",\n'
        '                              "messages", "tools", "tool_choice", "stream",\n',
        "idempotency fingerprint cost controls",
    )
    compile(source, str(path), "exec")
    path.write_text(source, encoding="utf-8")


if __name__ == "__main__":
    patch_api_server()
    patch_openai_routes()

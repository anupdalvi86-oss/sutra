#!/usr/bin/env python3
"""Exercise the local draft API through Supabase Auth and PostgREST."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class CheckFailed(RuntimeError):
    pass


def request_json(
    url: str,
    method: str = "GET",
    payload: dict | None = None,
    api_key: str = "",
    access_token: str = "",
) -> tuple[int, object]:
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if api_key:
        headers["apikey"] = api_key
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            body = json.loads(raw)
        except (TypeError, ValueError):
            body = None
        return exc.code, body
    except urllib.error.URLError as exc:
        raise CheckFailed("local Supabase or Sutra API is unreachable") from exc


def local_supabase(workdir: Path) -> dict[str, str]:
    result = subprocess.run(
        ["supabase", "status", "--workdir", str(workdir), "--output", "json"],
        cwd=workdir,
        capture_output=True,
        text=True,
        check=False,
    )
    raw = result.stdout
    json_start = raw.find("{")
    if result.returncode or json_start < 0:
        raise CheckFailed("Supabase CLI did not return local connection settings; run `supabase start` first")
    try:
        details = json.loads(raw[json_start:])
    except json.JSONDecodeError as exc:
        raise CheckFailed("Supabase CLI returned invalid local connection settings") from exc
    api_url = details.get("API_URL")
    parsed = urllib.parse.urlsplit(api_url or "")
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise CheckFailed("refusing to run integration data against a non-loopback Supabase URL")
    required = ("ANON_KEY", "SERVICE_ROLE_KEY")
    if any(not isinstance(details.get(key), str) or not details[key] for key in required):
        raise CheckFailed("Supabase CLI did not return the expected local keys")
    return {"api_url": api_url.rstrip("/"), "anon_key": details["ANON_KEY"],
            "service_role_key": details["SERVICE_ROLE_KEY"]}


def create_test_user(api_url: str, anon_key: str) -> tuple[str, str]:
    suffix = uuid.uuid4().hex
    status, body = request_json(
        f"{api_url}/auth/v1/signup",
        "POST",
        {"email": f"sutra-e2e-{suffix}@example.test", "password": f"{uuid.uuid4().hex}Aa9!"},
        api_key=anon_key,
    )
    user = body.get("user") if isinstance(body, dict) else None
    access_token = body.get("access_token") if isinstance(body, dict) else None
    user_id = user.get("id") if isinstance(user, dict) else None
    if status not in (200, 201) or not isinstance(access_token, str) or not isinstance(user_id, str):
        raise CheckFailed(f"local Auth sign-up did not issue a user token (HTTP {status})")
    return access_token, user_id


def wait_for_api(process: subprocess.Popen[bytes], base_url: str) -> None:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise CheckFailed("Sutra API exited before becoming ready")
        try:
            with urllib.request.urlopen(f"{base_url}/health", timeout=1):
                return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.25)
    raise CheckFailed("Sutra API health check timed out")


def run(workdir: Path) -> None:
    supabase = local_supabase(workdir)
    api_url = supabase["api_url"]
    anon_key = supabase["anon_key"]
    service_role_key = supabase["service_role_key"]
    users: list[str] = []
    server: subprocess.Popen[bytes] | None = None
    results: dict[str, object] = {}
    try:
        owner_token, owner_id = create_test_user(api_url, anon_key)
        users.append(owner_id)
        other_token, other_id = create_test_user(api_url, anon_key)
        users.append(other_id)

        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = os.environ.copy()
        env.update({
            "SUTRA_ENV": "development",
            "SUTRA_ENABLE_DRAFT_API": "true",
            "SUPABASE_URL": api_url,
            "SUPABASE_ANON_KEY": anon_key,
            "SUTRA_BIND_HOST": "127.0.0.1",
            "PORT": str(port),
        })
        # The Sutra API under test must use caller JWTs; it must not have a service key.
        env.pop("SUPABASE_SERVICE_ROLE_KEY", None)
        server = subprocess.Popen(
            [sys.executable, "-m", "sutra.server"],
            cwd=REPO_ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        base_url = f"http://127.0.0.1:{port}"
        wait_for_api(server, base_url)

        status, _ = request_json(
            f"{base_url}/v1/drafts", "POST", {"scenario": "A member saves an item."}, api_key=anon_key,
        )
        if status != 401:
            raise CheckFailed(f"unauthenticated draft creation was not rejected (HTTP {status})")

        status, created = request_json(
            f"{base_url}/v1/drafts",
            "POST",
            {"scenario": "A signed-in member saves an item.", "context": "Synthetic test account"},
            api_key=anon_key,
            access_token=owner_token,
        )
        if (status != 201 or not isinstance(created, dict)
                or created.get("tenant_id") != owner_id or created.get("owner_id") != owner_id):
            raise CheckFailed(f"draft creation or tenant binding failed (HTTP {status})")
        draft_id = created["id"]

        status, own_draft = request_json(
            f"{base_url}/v1/drafts/{draft_id}", api_key=anon_key, access_token=owner_token,
        )
        if (status != 200 or not isinstance(own_draft, dict) or own_draft.get("id") != draft_id
                or own_draft.get("test_draft", {}).get("executable") is not False):
            raise CheckFailed(f"draft owner read or inert-plan check failed (HTTP {status})")

        other_read, _ = request_json(
            f"{base_url}/v1/drafts/{draft_id}", api_key=anon_key, access_token=other_token,
        )
        other_review, _ = request_json(
            f"{base_url}/v1/drafts/{draft_id}/review",
            "PATCH",
            {"decision": "accept"},
            api_key=anon_key,
            access_token=other_token,
        )
        other_delete, _ = request_json(
            f"{base_url}/v1/drafts/{draft_id}", "DELETE", api_key=anon_key, access_token=other_token,
        )
        if other_read != 404 or other_review != 404 or other_delete != 404:
            raise CheckFailed(
                f"cross-user access was not hidden (read {other_read}, review {other_review}, delete {other_delete})"
            )

        status, review = request_json(
            f"{base_url}/v1/drafts/{draft_id}/review",
            "PATCH",
            {"decision": "accept", "comment": "Synthetic E2E review"},
            api_key=anon_key,
            access_token=owner_token,
        )
        if status != 201 or not isinstance(review, dict):
            raise CheckFailed(f"owner review append failed (HTTP {status})")
        status, reloaded = request_json(
            f"{base_url}/v1/drafts/{draft_id}", api_key=anon_key, access_token=owner_token,
        )
        if (status != 200 or not isinstance(reloaded, dict) or len(reloaded.get("reviews", [])) != 1
                or reloaded["reviews"][0].get("decision") != "accept"):
            raise CheckFailed("owner could not read the persisted review")

        review_url = f"{api_url}/rest/v1/test_draft_reviews?id=eq.{review['id']}"
        update_status, _ = request_json(
            review_url, "PATCH", {"comment": "overwrite"}, api_key=anon_key, access_token=owner_token,
        )
        delete_status, _ = request_json(
            review_url, "DELETE", api_key=anon_key, access_token=owner_token,
        )
        if update_status < 400 or delete_status < 400:
            raise CheckFailed("authenticated users could modify or delete append-only review history")
        owner_delete, _ = request_json(
            f"{base_url}/v1/drafts/{draft_id}", "DELETE", api_key=anon_key, access_token=owner_token,
        )
        if owner_delete != 204:
            raise CheckFailed(f"owner could not delete their draft (HTTP {owner_delete})")
        remaining_reviews, review_rows = request_json(
            f"{api_url}/rest/v1/test_draft_reviews?draft_id=eq.{review['draft_id']}&select=id",
            api_key=anon_key,
            access_token=owner_token,
        )
        if remaining_reviews != 200 or review_rows != []:
            raise CheckFailed("draft deletion did not remove its dependent review history")
        results = {"auth": "passed", "owner_create_read": "passed", "cross_user_read_review": "denied",
                   "review_persistence": "passed", "review_update_http": update_status,
                   "review_delete_http": delete_status, "owner_delete": "passed",
                   "review_cascade": "passed", "provider_calls": "none"}
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
        cleanup_errors = []
        for user_id in users:
            status, _ = request_json(
                f"{api_url}/auth/v1/admin/users/{user_id}",
                "DELETE",
                api_key=service_role_key,
                access_token=service_role_key,
            )
            if status not in (200, 204):
                cleanup_errors.append(status)
        if cleanup_errors:
            raise CheckFailed(f"local Supabase test-user cleanup failed (HTTP {cleanup_errors})")
    print(json.dumps(results, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", type=Path, default=REPO_ROOT,
                        help="Supabase project directory (defaults to this repository)")
    args = parser.parse_args()
    try:
        run(args.workdir.resolve())
    except (CheckFailed, OSError, subprocess.SubprocessError) as exc:
        print(f"Draft Auth/PostgREST integration failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

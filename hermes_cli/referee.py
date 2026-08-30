"""Provision the minimal, read-only Hermes profile used by Athena."""

from __future__ import annotations

import sys
import os
import time
from typing import Callable

import httpx


_READINESS_TIMEOUT_SECONDS = 30.0
_READINESS_POLL_SECONDS = 0.25
_REFEREE_CONTRACT_VERSION = 1


def build_referee_parser(subparsers, *, cmd_referee: Callable) -> None:
    parser = subparsers.add_parser(
        "referee",
        help="Manage a dedicated read-only referee profile",
        description="Provision the local OpenAI-compatible read-only referee service.",
    )
    children = parser.add_subparsers(dest="referee_command", required=True)
    provision = children.add_parser(
        "provision", help="Configure, install, and start the referee service"
    )
    provision.add_argument("--profile", default="athena-referee")
    provision.add_argument("--host", default="127.0.0.1")
    provision.add_argument("--port", type=int, default=8643)
    provision.add_argument(
        "--key-stdin",
        action="store_true",
        help="Read the API bearer key from stdin (never display it).",
    )
    install = children.add_parser(
        "install", help="Alias for provision"
    )
    install.add_argument("--profile", default="athena-referee")
    install.add_argument("--host", default="127.0.0.1")
    install.add_argument("--port", type=int, default=8643)
    install.add_argument("--key-stdin", action="store_true")
    parser.set_defaults(func=cmd_referee)


def cmd_referee(args) -> None:
    """Configure and start the profile without touching messaging state."""
    if getattr(args, "referee_command", None) not in {"provision", "install"}:
        raise ValueError("unsupported referee command")
    profile = _safe_profile(getattr(args, "profile", "athena-referee"))
    host = str(getattr(args, "host", "127.0.0.1")).strip()
    port = int(getattr(args, "port", 8643))
    if host != "127.0.0.1":
        raise ValueError("the referee must bind to loopback 127.0.0.1")
    if not 1 <= port <= 65535:
        raise ValueError("referee port must be between 1 and 65535")
    key = sys.stdin.read().strip() if getattr(args, "key_stdin", False) else ""
    if not key:
        raise ValueError("referee provisioning requires --key-stdin with a non-empty key")
    if any(char in key for char in "\r\n"):
        raise ValueError("referee key must be single-line")

    _ensure_profile_exists(profile)
    from hermes_cli.profiles import resolve_profile_env

    # ``--profile`` is a referee-subcommand option, so it is not consumed by
    # main's early ``-p`` selector. Set the active home before any config or
    # service helper reads its cached profile-scoped paths.
    os.environ["HERMES_HOME"] = resolve_profile_env(profile)
    _write_referee_profile(host=host, port=port)
    _save_profile_key(key)
    _install_and_start_service()
    _verify_live_referee(profile=profile, host=host, port=port, key=key)
    print(f"Referee profile '{profile}' provisioned on http://{host}:{port}")


def _safe_profile(value: str) -> str:
    from hermes_cli.profiles import normalize_profile_name, validate_profile_name

    profile = normalize_profile_name(str(value))
    validate_profile_name(profile)
    if profile == "default":
        raise ValueError("the referee must use a named profile")
    return profile


def _ensure_profile_exists(profile: str) -> None:
    from hermes_cli.profiles import create_profile, get_profile_dir

    profile_dir = get_profile_dir(profile)
    if profile_dir.is_dir():
        return
    create_profile(profile, no_skills=True, no_alias=True)


def _write_referee_profile(*, host: str, port: int) -> None:
    from hermes_cli.config import atomic_config_write, get_config_path, load_config

    config_path = get_config_path()
    data = load_config()
    if not isinstance(data, dict):
        raise ValueError("referee config must be a YAML mapping")

    platforms = data.setdefault("platforms", {})
    if not isinstance(platforms, dict):
        raise ValueError("referee profile platforms must be a YAML mapping")
    for platform_name, platform_config in list(platforms.items()):
        if isinstance(platform_config, dict):
            platform_config["enabled"] = platform_name == "api_server"
    api_server = platforms.setdefault("api_server", {})
    if not isinstance(api_server, dict):
        raise ValueError("referee profile api_server must be a YAML mapping")
    api_server["enabled"] = True
    extra = api_server.setdefault("extra", {})
    if not isinstance(extra, dict):
        raise ValueError("referee profile api_server.extra must be a YAML mapping")
    extra.update({"host": host, "port": port})

    # A referee profile must not inherit an MCP or unattended auxiliary path
    # from a cloned profile. The API server's own agent hardening remains the
    # final enforcement point for late/runtime-created work.
    data["mcp_servers"] = {}
    gateway = data.setdefault("gateway", {})
    if isinstance(gateway, dict):
        gateway["multiplex_profiles"] = False
    auxiliary = data.setdefault("auxiliary", {})
    if isinstance(auxiliary, dict):
        # A referee only needs the API server. Disable every inherited
        # auxiliary path, including new ones added after this provisioner was
        # written, so a cloned profile cannot retain side effects by default.
        for name, setting in list(auxiliary.items()):
            if isinstance(setting, dict):
                setting["enabled"] = False
            elif isinstance(setting, bool):
                # Preserve the shape of boolean-only legacy settings.
                auxiliary[name] = False
    referee = data.setdefault("referee", {})
    if not isinstance(referee, dict):
        raise ValueError("referee profile referee must be a YAML mapping")
    referee.update({"enabled": True, "policy_version": 1})
    atomic_config_write(config_path, data, sort_keys=False)


def _save_profile_key(key: str) -> None:
    from hermes_cli.config import save_env_value

    save_env_value("API_SERVER_KEY", key)


def _install_and_start_service() -> None:
    from hermes_cli import gateway

    if gateway.supports_systemd_services():
        gateway.systemd_install(force=True, non_interactive=True)
        gateway.systemd_start()
        return
    if gateway.is_macos():
        gateway.launchd_install(force=True)
        gateway.launchd_start()
        return
    if gateway.is_windows():
        from hermes_cli import gateway_windows

        gateway_windows.install(force=True, start_now=True, start_on_login=True)
        gateway_windows.start()
        return
    raise RuntimeError(
        "no supported user service manager found; run `hermes gateway run` "
        "under an explicit supervisor"
    )


def _verify_live_referee(*, profile: str, host: str, port: int, key: str) -> None:
    """Prove the started service exposes the exact read-only contract.

    This check intentionally uses the same profile-prefixed API path Athena
    uses.  A service that starts on the wrong checkout, wrong profile, or
    stale configuration must make provisioning fail rather than appear
    successful to the caller.
    """
    base = f"http://{host}:{port}/p/{profile}/v1"
    headers = {"Authorization": f"Bearer {key}", "Accept": "application/json"}
    deadline = time.monotonic() + _READINESS_TIMEOUT_SECONDS
    last_error = "service did not become ready"
    with httpx.Client(timeout=2.0, headers=headers, follow_redirects=False) as client:
        while time.monotonic() < deadline:
            try:
                models = client.get(f"{base}/models")
                models.raise_for_status()
                models_payload = models.json()
                rows = models_payload.get("data") if isinstance(models_payload, dict) else None
                if not isinstance(rows, list) or not any(
                    isinstance(row, dict) and row.get("id") for row in rows
                ):
                    raise RuntimeError("/models did not advertise a model")

                capabilities = client.get(f"{base}/capabilities")
                capabilities.raise_for_status()
                payload = capabilities.json()
                if not isinstance(payload, dict):
                    raise RuntimeError("/capabilities did not return an object")
                runtime = payload.get("runtime")
                referee = payload.get("referee")
                build = payload.get("build")
                if not isinstance(runtime, dict) or runtime.get("mode") != "referee":
                    raise RuntimeError("runtime.mode is not referee")
                if runtime.get("tool_execution") != "disabled":
                    raise RuntimeError("runtime.tool_execution is not disabled")
                if not isinstance(referee, dict) or referee.get("enabled") is not True:
                    raise RuntimeError("referee.enabled is not true")
                if referee.get("policy_version") != 1:
                    raise RuntimeError("unsupported referee policy version")
                if referee.get("effective_tools") != []:
                    raise RuntimeError("referee.effective_tools is not empty")
                if not isinstance(build, dict) or build.get("referee_contract") != _REFEREE_CONTRACT_VERSION:
                    raise RuntimeError("referee build contract is missing or stale")
                return
            except (httpx.HTTPError, ValueError, RuntimeError) as exc:
                # Do not include response bodies: a future server could echo
                # request material or otherwise make the bearer key visible.
                last_error = str(exc).splitlines()[0][:240] or type(exc).__name__
                time.sleep(_READINESS_POLL_SECONDS)
    raise RuntimeError(f"referee service failed live contract proof: {last_error}")


__all__ = ["build_referee_parser", "cmd_referee"]

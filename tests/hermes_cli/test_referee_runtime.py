from __future__ import annotations

import sys
import types
from pathlib import Path

import pytest


def test_profile_wrapper_pins_runtime_and_source_root(tmp_path, monkeypatch):
    from hermes_cli import profiles

    monkeypatch.setattr(profiles, "_get_wrapper_dir", lambda: tmp_path)
    wrapper = profiles.create_wrapper_script("athena-referee")

    assert wrapper is not None
    content = wrapper.read_text(encoding="utf-8")
    assert "hermes_cli.main -p athena-referee" in content
    assert "HERMES_EXPECTED_RUNTIME_ROOT=" in content
    assert str(Path(profiles.__file__).resolve().parents[1]) in content
    assert "exec hermes " not in content


def test_runtime_provenance_rejects_foreign_loaded_gateway(monkeypatch):
    from hermes_cli.runtime_provenance import RuntimeProvenanceError, verify_runtime_provenance

    foreign = types.ModuleType("gateway.run")
    foreign.__file__ = "/tmp/foreign-hermes/gateway/run.py"
    monkeypatch.setitem(sys.modules, "gateway.run", foreign)
    monkeypatch.setenv(
        "HERMES_EXPECTED_RUNTIME_ROOT",
        str(Path(__file__).resolve().parents[2]),
    )

    with pytest.raises(RuntimeProvenanceError, match="provenance mismatch"):
        verify_runtime_provenance()


def test_referee_profile_write_disables_inherited_surfaces(tmp_path, monkeypatch):
    from hermes_cli import config as hermes_config
    from hermes_cli import referee

    config_path = tmp_path / "config.yaml"
    source = {
        "platforms": {
            "telegram": {"enabled": True},
            "api_server": {"enabled": False, "extra": {}},
        },
        "mcp_servers": {"inherited": {"url": "http://example.test"}},
        "auxiliary": {
            "background_review": {"enabled": True},
            "title_generation": {"enabled": True},
        },
    }
    captured: dict = {}

    monkeypatch.setattr(hermes_config, "get_config_path", lambda: config_path)
    monkeypatch.setattr(hermes_config, "load_config", lambda: source)
    monkeypatch.setattr(
        hermes_config,
        "atomic_config_write",
        lambda path, data, **_kwargs: captured.update(path=path, data=data),
    )

    referee._write_referee_profile(host="127.0.0.1", port=8643)
    data = captured["data"]
    assert data["platforms"]["telegram"]["enabled"] is False
    assert data["platforms"]["api_server"]["enabled"] is True
    assert data["platforms"]["api_server"]["extra"] == {
        "host": "127.0.0.1",
        "port": 8643,
    }
    assert data["mcp_servers"] == {}
    assert data["auxiliary"]["background_review"]["enabled"] is False
    assert data["auxiliary"]["title_generation"]["enabled"] is False
    assert data["gateway"]["multiplex_profiles"] is False
    assert data["referee"] == {"enabled": True, "policy_version": 1}


def test_live_referee_probe_requires_the_complete_contract(monkeypatch):
    from hermes_cli import referee

    class Response:
        def __init__(self, payload):
            self._payload = payload

        def raise_for_status(self):
            return None

        def json(self):
            return self._payload

    class Client:
        def __init__(self, **_kwargs):
            self.urls = []

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def get(self, url):
            self.urls.append(url)
            if url.endswith("/models"):
                return Response({"data": [{"id": "referee-model"}]})
            return Response(
                {
                    "runtime": {"mode": "referee", "tool_execution": "disabled"},
                    "referee": {"enabled": True, "policy_version": 1, "effective_tools": []},
                    "build": {"referee_contract": 1},
                }
            )

    client = Client()
    monkeypatch.setattr(referee.httpx, "Client", lambda **kwargs: client)
    referee._verify_live_referee(
        profile="athena-referee", host="127.0.0.1", port=8643, key="test-key"
    )
    assert client.urls == [
        "http://127.0.0.1:8643/p/athena-referee/v1/models",
        "http://127.0.0.1:8643/p/athena-referee/v1/capabilities",
    ]

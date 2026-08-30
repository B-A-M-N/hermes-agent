"""Fail-closed checks that a Hermes process is running one installation.

The CLI can be launched through wrappers, editable installs, service managers,
or a copied shell environment.  Those entry points must agree on the source
tree that owns the runtime.  In particular, a referee must never silently
load ``gateway`` or ``api_server`` from a sibling checkout.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


_MODULES_TO_CHECK = (
    "hermes_cli",
    "hermes_cli.main",
    "gateway",
    "gateway.run",
    "gateway.platforms.api_server",
)


class RuntimeProvenanceError(RuntimeError):
    """The loaded Python modules do not belong to the expected Hermes tree."""


def expected_runtime_root() -> Path:
    """Resolve the installation root pinned by the launcher or this package."""
    configured = os.environ.get("HERMES_EXPECTED_RUNTIME_ROOT", "").strip()
    if configured:
        return Path(configured).expanduser().resolve()
    return Path(__file__).resolve().parents[1]


def verify_runtime_provenance() -> Path:
    """Raise unless all already-loaded Hermes runtime modules share one root."""
    root = expected_runtime_root()
    if not root.is_dir():
        raise RuntimeProvenanceError(f"expected Hermes runtime root does not exist: {root}")

    observed: dict[str, str] = {}
    for module_name in _MODULES_TO_CHECK:
        module = sys.modules.get(module_name)
        if module is None:
            continue
        path = getattr(module, "__file__", None)
        if not path:
            continue
        resolved = Path(path).resolve()
        observed[module_name] = str(resolved)
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise RuntimeProvenanceError(
                "Hermes runtime provenance mismatch: "
                f"{module_name} loaded from {resolved}, expected under {root}"
            ) from exc

    if not observed:
        raise RuntimeProvenanceError(
            f"Hermes runtime provenance could not identify loaded modules under {root}"
        )
    return root


__all__ = ["RuntimeProvenanceError", "expected_runtime_root", "verify_runtime_provenance"]

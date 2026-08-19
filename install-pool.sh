#!/bin/bash
# LongCatLongClawsContrib: Pool feature installer
# Installs the /pool multi-connection feature into any Hermes agent checkout
#
# Usage:
#   bash install-pool.sh [HERMES_AGENT_DIR]
#
# Default: installs into ~/.hermes/hermes-agent or /home/bamn/hermes-agent

set -euo pipefail

REPO_ROOT="${1:-${HERMES_AGENT_DIR:-/home/bamn/hermes-agent}}"
POOL_SRC="${2:-/tmp/hermes-pool}"

if [ ! -d "$REPO_ROOT" ]; then
    echo "ERROR: Hermes agent directory not found: $REPO_ROOT"
    echo "Usage: bash install-pool.sh [HERMES_AGENT_DIR]"
    exit 1
fi

if [ ! -d "$POOL_SRC" ]; then
    echo "ERROR: Pool source not found: $POOL_SRC"
    echo "Clone the repo first:"
    echo "  git clone https://github.com/B-A-M-N/hermes-agent.git /tmp/hermes-pool"
    echo "  cd /tmp/hermes-pool && git checkout feat/LongCatLongClawsContrib"
    exit 1
fi

echo "=== LongCatLongClawsContrib Pool Feature Installer ==="
echo ""
echo "Installing into: $REPO_ROOT"
echo ""

# ─── Step 1: Copy new files ───────────────────────────────────────────────
echo "[1/5] Copying new files..."

# Connection config + manager
install -m 644 "$POOL_SRC/tui_gateway/connection_config.py" "$REPO_ROOT/tui_gateway/connection_config.py"
install -m 644 "$POOL_SRC/tui_gateway/connection_manager.py" "$REPO_ROOT/tui_gateway/connection_manager.py"

# Desktop plugin
mkdir -p "$REPO_ROOT/apps/desktop/src/plugins/pool"
install -m 644 "$POOL_SRC/apps/desktop/src/plugins/pool/plugin.tsx" "$REPO_ROOT/apps/desktop/src/plugins/pool/plugin.tsx"

# Tests
mkdir -p "$REPO_ROOT/tests/tui_gateway"
install -m 644 "$POOL_SRC/tests/tui_gateway/test_connection_manager.py" "$REPO_ROOT/tests/tui_gateway/test_connection_manager.py"
install -m 644 "$POOL_SRC/tests/tui_gateway/test_pool_integration.py" "$REPO_ROOT/tests/tui_gateway/test_pool_integration.py"

echo "  ✓ New files copied"

# ─── Step 2: Patch methods_tools.py (add pool RPC handlers) ───────────────
echo "[2/5] Patching tui_gateway/methods_tools.py..."

if grep -q '@method("pool.list")' "$REPO_ROOT/tui_gateway/methods_tools.py"; then
    echo "  ⚠ pool handlers already present, skipping"
else
    # Insert pool handlers before insights.get
    python3 << 'PYEOF'
import re

repo_root = "/home/bamn/hermes-agent"
methods_file = f"{repo_root}/tui_gateway/methods_tools.py"

with open(methods_file, "r") as f:
    content = f.read()

pool_handlers = '''
@method("pool.list")
def _(rid, params: dict) -> dict:
    """List all configured connections and their status."""
    try:
        from tui_gateway.connection_manager import get_connection_manager
        mgr = get_connection_manager()
        return _ok(rid, {"connections": mgr.list_status()})
    except Exception as e:
        return _err(rid, 5017, str(e))


@method("pool.add")
def _(rid, params: dict) -> dict:
    """Add a new connection."""
    try:
        from tui_gateway.connection_manager import get_connection_manager
        mgr = get_connection_manager()
        name = params.get("name", "").strip()
        url = params.get("url", "").strip()
        mode = params.get("mode", "remote")
        auth = params.get("auth")
        token = params.get("token")
        if not name or not url:
            return _err(rid, 4004, "name and url required")
        ok, msg = mgr.add(name, url, mode=mode, auth=auth, token=token)
        if ok:
            return _ok(rid, {"message": msg})
        return _err(rid, 4018, msg)
    except Exception as e:
        return _err(rid, 5017, str(e))


@method("pool.remove")
def _(rid, params: dict) -> dict:
    """Remove a connection."""
    try:
        from tui_gateway.connection_manager import get_connection_manager
        mgr = get_connection_manager()
        name = params.get("name", "").strip()
        if not name:
            return _err(rid, 4004, "name required")
        ok, msg = mgr.remove(name)
        if ok:
            return _ok(rid, {"message": msg})
        return _err(rid, 4018, msg)
    except Exception as e:
        return _err(rid, 5017, str(e))


@method("pool.switch")
def _(rid, params: dict) -> dict:
    """Switch to a different connection."""
    try:
        from tui_gateway.connection_manager import get_connection_manager
        mgr = get_connection_manager()
        name = params.get("name", "").strip()
        if not name:
            return _err(rid, 4004, "name required")
        ok, msg = mgr.switch(name)
        if ok:
            return _ok(rid, {"message": msg, "url": mgr.active_url})
        return _err(rid, 4018, msg)
    except Exception as e:
        return _err(rid, 5017, str(e))


@method("pool.test")
def _(rid, params: dict) -> dict:
    """Test a connection by probing its health endpoint."""
    try:
        from tui_gateway.connection_manager import get_connection_manager
        mgr = get_connection_manager()
        name = params.get("name", "").strip()
        if not name:
            return _err(rid, 4004, "name required")
        ok, msg = mgr.test_connection(name)
        if ok:
            return _ok(rid, {"message": msg})
        return _err(rid, 4018, msg)
    except Exception as e:
        return _err(rid, 5017, str(e))


@method("pool.discover")
def _(rid, params: dict) -> dict:
    """Discover Hermes instances on Tailscale."""
    try:
        from tui_gateway.connection_manager import get_connection_manager
        mgr = get_connection_manager()
        count, msg = mgr.discover_tailscale()
        if count > 0:
            return _ok(rid, {"message": msg, "count": count})
        return _err(rid, 4018, msg)
    except Exception as e:
        return _err(rid, 5017, str(e))


'''

# Insert before @method("insights.get")
content = content.replace(
    '@method("insights.get")',
    pool_handlers + '@method("insights.get")'
)

with open(methods_file, "w") as f:
    f.write(content)

print("  ✓ pool handlers added to methods_tools.py")
PYEOF

    echo "  ✓ methods_tools.py patched"
fi

# ─── Step 3: Patch commands.py (register /pool in COMMAND_REGISTRY) ───────
echo "[3/5] Patching hermes_cli/commands.py..."

if grep -q 'CommandDef("pool"' "$REPO_ROOT/hermes_cli/commands.py"; then
    echo "  ⚠ /pool already in COMMAND_REGISTRY, skipping"
else
    python3 << 'PYEOF'
repo_root = "/home/bamn/hermes-agent"
cmd_file = f"{repo_root}/hermes_cli/commands.py"

with open(cmd_file, "r") as f:
    content = f.read()

pool_entry = '''    # Pool (multi-connection management)
    CommandDef("pool", "Manage and monitor multiple Hermes connections (Tailscale, remote, local)", "Session",
               args_hint="[list|add|remove|switch|test|discover]",
               subcommands=("list", "add", "remove", "switch", "test", "discover")),

'''

# Insert after sessions entry
content = content.replace(
    'CommandDef("sessions", "Browse and resume previous sessions", "Session"),\n',
    'CommandDef("sessions", "Browse and resume previous sessions", "Session"),\n' + pool_entry
)

with open(cmd_file, "w") as f:
    f.write(content)

print("  ✓ /pool added to COMMAND_REGISTRY")
PYEOF

    echo "  ✓ commands.py patched"
fi

# ─── Step 4: Patch cli.py + cli_commands_mixin.py ─────────────────────────
echo "[4/5] Patching cli.py + cli_commands_mixin.py..."

if grep -q '_handle_pool_command' "$REPO_ROOT/cli.py"; then
    echo "  ⚠ /pool handler already in cli.py, skipping"
else
    python3 << 'PYEOF'
repo_root = "/home/bamn/hermes-agent"

# Patch cli.py - add dispatch branch
cli_file = f"{repo_root}/cli.py"
with open(cli_file, "r") as f:
    content = f.read()

pool_dispatch = '''        elif canonical == "pool":
            self._handle_pool_command(cmd_original)
'''

content = content.replace(
    'elif canonical == "sessions":\n            self._handle_sessions_command(cmd_original)\n',
    'elif canonical == "sessions":\n            self._handle_sessions_command(cmd_original)\n' + pool_dispatch
)

with open(cli_file, "w") as f:
    f.write(content)

print("  ✓ cli.py dispatch branch added")

# Patch cli_commands_mixin.py - add handler
mixin_file = f"{repo_root}/hermes_cli/cli_commands_mixin.py"
with open(mixin_file, "r") as f:
    content = f.read()

pool_handler = '''
    def _handle_pool_command(self, cmd_original: str) -> None:
        """Handle /pool [list|add|remove|switch|test|discover] — manage multiple Hermes connections."""
        from cli import _cprint
        parts = cmd_original.split(None, 1)
        arg = parts[1].strip() if len(parts) > 1 else ""
        sub = arg.lower().split()[0] if arg else "list"

        from tui_gateway.connection_manager import get_connection_manager
        mgr = get_connection_manager()

        if sub == "list" or not arg:
            _cprint(mgr.format_list())
            return

        if sub == "add":
            tokens = arg.split()
            if len(tokens) < 3:
                _cprint("Usage: /pool add <name> <url> [--token <token>]")
                return
            name = tokens[1]
            url = tokens[2]
            token = None
            if "--token" in tokens:
                idx = tokens.index("--token")
                if idx + 1 < len(tokens):
                    token = tokens[idx + 1]
            ok, msg = mgr.add(name, url, token=token)
            _cprint(f"  {'✓' if ok else '✗'} {msg}")
            return

        if sub == "remove":
            name = arg.split()[1] if len(arg.split()) > 1 else ""
            if not name:
                _cprint("Usage: /pool remove <name>")
                return
            ok, msg = mgr.remove(name)
            _cprint(f"  {'✓' if ok else '✗'} {msg}")
            return

        if sub == "switch":
            name = arg.split()[1] if len(arg.split()) > 1 else ""
            if not name:
                _cprint("Usage: /pool switch <name>")
                return
            ok, msg = mgr.switch(name)
            _cprint(f"  {'✓' if ok else '✗'} {msg}")
            if ok:
                _cprint("  Reconnect to the new backend to use it.")
            return

        if sub == "test":
            name = arg.split()[1] if len(arg.split()) > 1 else ""
            if not name:
                _cprint("Usage: /pool test <name>")
                return
            ok, msg = mgr.test_connection(name)
            _cprint(f"  {'✓' if ok else '✗'} {msg}")
            return

        if sub == "discover":
            count, msg = mgr.discover_tailscale()
            _cprint(f"  {'✓' if count > 0 else '✗'} {msg}")
            return

        _cprint(f"  Unknown subcommand: {sub}")
        _cprint("  Usage: /pool [list|add|remove|switch|test|discover]")

'''

# Insert after _handle_sessions_command
content = content.replace(
    '        # /sessions <id_or_title> behaves the same as /resume <id_or_title>.\n        self._handle_resume_command(f"/resume {arg}")\n',
    '        # /sessions <id_or_title> behaves the same as /resume <id_or_title>.\n        self._handle_resume_command(f"/resume {arg}")\n' + pool_handler
)

with open(mixin_file, "w") as f:
    f.write(content)

print("  ✓ _handle_pool_command added to cli_commands_mixin.py")
PYEOF

    echo "  ✓ cli.py + cli_commands_mixin.py patched"
fi

# ─── Step 5: Patch session.ts (add TUI /pool handler) ──────────────────────
echo "[5/5] Patching ui-tui/src/app/slash/commands/session.ts..."

if grep -q "name: 'pool'" "$REPO_ROOT/ui-tui/src/app/slash/commands/session.ts"; then
    echo "  ⚠ /pool handler already in session.ts, skipping"
else
    python3 << 'PYEOF'
repo_root = "/home/bamn/hermes-agent"
session_file = f"{repo_root}/ui-tui/src/app/slash/commands/session.ts"

with open(session_file, "r") as f:
    content = f.read()

pool_tui = '''
  {
    help: 'manage and monitor multiple Hermes connections (Tailscale, remote, local)',
    name: 'pool',
    usage: '/pool [list|add|remove|switch|test|discover]',
    run: (arg, ctx) => {
      const trimmed = arg.trim()
      const parts = trimmed.split(/\\s+/)
      const sub = parts[0]?.toLowerCase() || 'list'

      if (sub === 'list' || !trimmed) {
        ctx.gateway.rpc<{ connections: Array<{ name: string; url: string; active: boolean; status: string }> }>(
          'pool.list',
          { session_id: ctx.sid }
        ).then(
          ctx.guarded(r => {
            const lines = ['Configured connections:']
            for (const c of r.connections) {
              const marker = c.active ? ' * ' : '   '
              lines.push(`${marker}${c.name.padEnd(15)} ${c.url.padEnd(45)} [${c.status}]`)
            }
            lines.push('')
            lines.push("Use '/pool switch <name>' to switch active connection.")
            ctx.transcript.sys(lines.join('\\n'))
          })
        )
        return
      }

      if (sub === 'add') {
        const name = parts[1]
        const url = parts[2]
        if (!name || !url) {
          return ctx.transcript.sys('Usage: /pool add <name> <url> [--token <token>]')
        }
        const tokenIdx = parts.indexOf('--token')
        const token = tokenIdx >= 0 && parts[tokenIdx + 1] ? parts[tokenIdx + 1] : undefined
        ctx.gateway.rpc('pool.add', { name, url, token, session_id: ctx.sid }).then(
          ctx.guarded(r => ctx.transcript.sys(r.message))
        )
        return
      }

      if (sub === 'remove') {
        const name = parts[1]
        if (!name) {
          return ctx.transcript.sys('Usage: /pool remove <name>')
        }
        ctx.gateway.rpc('pool.remove', { name, session_id: ctx.sid }).then(
          ctx.guarded(r => ctx.transcript.sys(r.message))
        )
        return
      }

      if (sub === 'switch') {
        const name = parts[1]
        if (!name) {
          return ctx.transcript.sys('Usage: /pool switch <name>')
        }
        ctx.gateway.rpc('pool.switch', { name, session_id: ctx.sid }).then(
          ctx.guarded(r => {
            ctx.transcript.sys(r.message)
            ctx.transcript.sys('Reconnect to use the new backend.')
          })
        )
        return
      }

      if (sub === 'test') {
        const name = parts[1]
        if (!name) {
          return ctx.transcript.sys('Usage: /pool test <name>')
        }
        ctx.gateway.rpc('pool.test', { name, session_id: ctx.sid }).then(
          ctx.guarded(r => ctx.transcript.sys(r.message))
        )
        return
      }

      if (sub === 'discover') {
        ctx.gateway.rpc('pool.discover', { session_id: ctx.sid }).then(
          ctx.guarded(r => ctx.transcript.sys(r.message))
        )
        return
      }

      ctx.transcript.sys(`Unknown subcommand: ${sub}`)
      ctx.transcript.sys('Usage: /pool [list|add|remove|switch|test|discover]')
    }
  },

'''

# Insert after the sessions command
content = content.replace(
    "    aliases: ['switch', 'session', 'resume'],\n    help: 'browse, switch, or resume sessions',\n    name: 'sessions',",
    "    aliases: ['switch', 'session', 'resume'],\n    help: 'browse, switch, or resume sessions',\n    name: 'sessions',\n    run: (arg, ctx) => {\n      const trimmed = arg.trim()\n      if (trimmed.toLowerCase() === 'new') {\n        return ctx.session.newLiveSession()\n      }\n      if (trimmed) {\n        if (ctx.session.guardBusySessionSwitch('switch sessions')) {\n          return\n        }\n        return ctx.session.resumeById(trimmed)\n      }\n      patchOverlayState({ sessions: true })\n    }\n  },\n\n  {"
)

# Simpler approach: insert before the 'image' command
content = content.replace(
    "    help: 'attach an image',",
    pool_tui + "    help: 'attach an image',"
)

with open(session_file, "w") as f:
    f.write(content)

print("  ✓ /pool handler added to session.ts")
PYEOF

    echo "  ✓ session.ts patched"
fi

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== Installation Complete ==="
echo ""
echo "Pool feature installed into: $REPO_ROOT"
echo ""
echo "To activate:"
echo "  1. Restart your TUI: hermes --tui"
echo "  2. Type /pool list"
echo "  3. Type /pool add <name> <url>"
echo "  4. Type /pool test <name>"
echo "  5. Type /pool switch <name>"
echo ""
echo "For Desktop plugin:"
echo "  1. Run: hermes desktop"
echo "  2. Settings → Plugins → Enable 'Connection Pool'"
echo "  3. The Pool pane appears in the right sidebar"
echo ""
echo "To uninstall: git checkout -- . (if in a git repo)"

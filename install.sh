#!/usr/bin/env bash
# Install serena-shared-bridge: scripts -> ~/.local/bin, reaper -> systemd user
# timer, and register serena to route through the bridge in Claude Code (user
# scope). Idempotent.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
UNITS="$HOME/.config/systemd/user"

echo "==> Installing scripts to $BIN"
mkdir -p "$BIN" "$UNITS"
install -m 0755 "$HERE/bin/serena-shared-bridge" "$BIN/serena-shared-bridge"
install -m 0755 "$HERE/bin/serena-shared-reap" "$BIN/serena-shared-reap"

echo "==> Installing reaper timer to $UNITS"
install -m 0644 "$HERE/systemd/serena-shared-reap.service" "$UNITS/serena-shared-reap.service"
install -m 0644 "$HERE/systemd/serena-shared-reap.timer" "$UNITS/serena-shared-reap.timer"
if systemctl --user daemon-reload 2>/dev/null; then
  systemctl --user enable --now serena-shared-reap.timer 2>/dev/null \
    && echo "    reaper timer enabled" \
    || echo "    WARN: could not enable timer (no systemd user session?)"
else
  echo "    WARN: systemctl --user unavailable; skipping timer (orphans won't be auto-reaped)"
fi

echo "==> Registering serena via the bridge (Claude Code user scope)"
if command -v claude >/dev/null 2>&1; then
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$HOME/.claude.json" "$HOME/.claude.json.bak-serena-bridge-$ts" 2>/dev/null \
    && echo "    backed up ~/.claude.json -> ~/.claude.json.bak-serena-bridge-$ts"
  claude mcp remove serena -s user >/dev/null 2>&1 || true
  if claude mcp add -s user serena -- "$BIN/serena-shared-bridge"; then
    echo "    registered."
  else
    echo "    WARN: 'claude mcp add' failed; register manually (see below)."
  fi
else
  echo "    'claude' CLI not found. Register manually:"
  echo "      claude mcp add -s user serena -- $BIN/serena-shared-bridge"
fi

cat <<EOF

Done. New agents share one serena per project; running agents switch on restart.

  Verify:  claude mcp list | grep serena
  Disable: claude mcp remove serena -s user   (or set SERENA_SHARED=0)
EOF

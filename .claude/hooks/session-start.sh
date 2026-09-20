#!/usr/bin/env bash
#
# Claude Code SessionStart hook.
#
# Remote containers are recreated between sessions, so PostgreSQL, Redis,
# pgvector, the databases and .env all have to be provisioned again each time.
# This delegates to the shared setup script so the same steps are available to
# anyone not using Claude Code:
#
#   ./.devcontainer/scripts/setup-dev-env.sh
#
set -uo pipefail

# Local machines have their own long-lived services; don't touch them.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SETUP="${PROJECT_DIR}/.devcontainer/scripts/setup-dev-env.sh"

if [ ! -x "$SETUP" ]; then
  echo "[session-start] ${SETUP} is missing or not executable; skipping setup." >&2
  exit 0
fi

# Never fail the session on a setup problem — the script prints its own
# per-service status and degrades gracefully.
"$SETUP" || true
exit 0

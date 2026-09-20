#!/usr/bin/env bash
#
# Provision a working Chatwoot development environment.
#
# Remote/ephemeral containers (Claude Code on the web, fresh Codespaces) start
# with PostgreSQL, Redis and Docker installed but stopped, without the pgvector
# extension db/schema.rb requires, and without an .env file. This script brings
# all of that up.
#
# Safe to run repeatedly — every step is idempotent. Run it by hand with:
#
#   ./.devcontainer/scripts/setup-dev-env.sh
#
# It is also invoked automatically by .claude/hooks/session-start.sh.
#
# Individual steps are allowed to fail without aborting the run: a broken
# optional service should degrade the environment, never block the session.
# The final summary reports what is actually up.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$PROJECT_DIR" || exit 1

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARNING: %s\n' "$*" >&2; }

# Most remote containers run as root; fall back to sudo elsewhere.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Read a KEY=value out of .env (empty string when absent).
env_value() {
  [ -f .env ] || return 0
  sed -n "s|^$1=||p" .env | head -1
}

# Set KEY=value in .env, replacing any existing definition.
set_env_value() {
  local key="$1" value="$2"
  [ -f .env ] || return 1
  if grep -qE "^${key}=" .env; then
    # `#` delimiter so values containing `/` (URLs) don't need escaping.
    sed -i -e "s#^${key}=.*#${key}=${value}#" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

# --------------------------------------------------------------------------
# .env
# --------------------------------------------------------------------------
# dotenv-rails loads .env, so its values override config/database.yml defaults.
# .env.example ships docker-compose service names (POSTGRES_HOST=postgres),
# which do not resolve outside compose — point them at localhost, mirroring
# what .devcontainer/scripts/setup.sh already does for Codespaces.
setup_env_file() {
  if [ -f .env ]; then
    return 0
  fi
  [ -f .env.example ] || { warn "No .env.example to copy."; return 1; }

  log "Creating .env for local (non-Docker) development..."
  cp .env.example .env
  set_env_value POSTGRES_HOST localhost
  set_env_value REDIS_URL "redis://localhost:6379"
  set_env_value SMTP_ADDRESS localhost
  set_env_value FRONTEND_URL "http://localhost:3000"

  # .env.example ships a placeholder secret; generate a real one.
  if command -v openssl >/dev/null 2>&1; then
    set_env_value SECRET_KEY_BASE "$(openssl rand -hex 64)"
  fi

  log "Note: these values target a local run. For 'docker compose up', set"
  log "      POSTGRES_HOST=postgres and REDIS_URL=redis://redis:6379 instead."
  return 0
}

# --------------------------------------------------------------------------
# PostgreSQL
# --------------------------------------------------------------------------
setup_postgres() {
  if ! command -v pg_isready >/dev/null 2>&1; then
    warn "PostgreSQL is not installed; skipping database setup."
    return 1
  fi

  # Resolve the installed major version (e.g. "16") from the cluster layout.
  local pg_version
  pg_version="$(ls /etc/postgresql 2>/dev/null | sort -V | tail -1)"
  if [ -z "$pg_version" ]; then
    warn "No PostgreSQL cluster found under /etc/postgresql; skipping."
    return 1
  fi

  # db/schema.rb does `enable_extension "vector"`, so migrations fail outright
  # without pgvector. Install it before the server comes up.
  if ! as_root test -f "/usr/share/postgresql/${pg_version}/extension/vector.control"; then
    log "Installing pgvector (postgresql-${pg_version}-pgvector)..."
    if ! as_root apt-get install -y -qq "postgresql-${pg_version}-pgvector" >/dev/null 2>&1; then
      as_root apt-get update -qq >/dev/null 2>&1
      as_root apt-get install -y -qq "postgresql-${pg_version}-pgvector" >/dev/null 2>&1 \
        || warn "Could not install pgvector; migrations will fail on enable_extension \"vector\"."
    fi
  fi

  if ! pg_isready -h localhost -p 5432 -q 2>/dev/null; then
    log "Starting PostgreSQL ${pg_version}..."
    as_root pg_ctlcluster "$pg_version" main start >/dev/null 2>&1 \
      || as_root service postgresql start >/dev/null 2>&1
  fi

  # Wait for the socket rather than assuming the start was instant.
  local i
  for i in $(seq 1 20); do
    pg_isready -h localhost -p 5432 -q 2>/dev/null && break
    sleep 1
  done

  if ! pg_isready -h localhost -p 5432 -q 2>/dev/null; then
    warn "PostgreSQL did not come up; check /var/log/postgresql/."
    return 1
  fi

  # A stock cluster requires scram-sha-256 over localhost, but config/database.yml
  # defaults to an empty password. Give the postgres role a real password and put
  # it in .env, so authentication stays enabled (rather than relaxing pg_hba.conf
  # to `trust`, which would let any local user connect as any role).
  local pgpass
  pgpass="$(env_value POSTGRES_PASSWORD)"
  if [ -z "$pgpass" ]; then
    if command -v openssl >/dev/null 2>&1; then
      pgpass="$(openssl rand -hex 24)"
    else
      pgpass="chatwoot_dev_$(date +%s)"
    fi
    log "Setting a password for the postgres role..."
  fi

  # Applied through the local peer-authenticated socket, so no password is
  # needed to set one. Kept out of the process list and shell history.
  if ! as_root su - postgres -c "psql -v ON_ERROR_STOP=1 -q -f -" <<SQL >/dev/null 2>&1
ALTER ROLE postgres WITH PASSWORD '${pgpass}';
SQL
  then
    warn "Could not set the postgres role password; Rails may not be able to connect."
  fi
  set_env_value POSTGRES_PASSWORD "$pgpass" || true
  export PGPASSWORD="$pgpass"

  # Create the databases Rails expects. `bundle exec rails db:chatwoot_prepare`
  # still owns schema load and migrations; this only guarantees they exist.
  local db
  for db in chatwoot_dev chatwoot_test; do
    if ! psql -h localhost -U postgres -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null | grep -q 1; then
      log "Creating database ${db}..."
      createdb -h localhost -U postgres "$db" >/dev/null 2>&1 \
        || warn "Could not create ${db}."
    fi
    # Extensions are per-database, so enable them in each.
    psql -h localhost -U postgres -d "$db" -q >/dev/null 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;
SQL
  done

  return 0
}

# --------------------------------------------------------------------------
# Redis
# --------------------------------------------------------------------------
setup_redis() {
  if ! command -v redis-cli >/dev/null 2>&1; then
    warn "Redis is not installed; skipping."
    return 1
  fi

  if [ "$(redis-cli -h 127.0.0.1 ping 2>/dev/null)" = "PONG" ]; then
    return 0
  fi

  log "Starting Redis..."
  # The init script's ulimit call fails under container limits but the server
  # still starts, so ignore its exit status and probe instead.
  as_root service redis-server start >/dev/null 2>&1 || true

  local i
  for i in $(seq 1 10); do
    [ "$(redis-cli -h 127.0.0.1 ping 2>/dev/null)" = "PONG" ] && return 0
    sleep 1
  done

  warn "Redis did not come up."
  return 1
}

# --------------------------------------------------------------------------
# Docker (optional — only needed for the docker-compose workflow)
# --------------------------------------------------------------------------
setup_docker() {
  command -v dockerd >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 && return 0

  log "Starting Docker daemon..."
  # setsid fully detaches the daemon; a plain background job dies with the
  # shell that launched it.
  as_root rm -f /var/run/docker.pid
  as_root setsid dockerd >/tmp/dockerd.log 2>&1 </dev/null &
  disown 2>/dev/null || true

  local i
  for i in $(seq 1 15); do
    docker info >/dev/null 2>&1 && return 0
    sleep 1
  done

  warn "Docker daemon did not start (see /tmp/dockerd.log). Only affects docker-compose."
  return 1
}

# --------------------------------------------------------------------------
# Frontend dependencies
# --------------------------------------------------------------------------
setup_frontend() {
  command -v pnpm >/dev/null 2>&1 || { warn "pnpm is not installed; skipping."; return 1; }

  # `install` (not `--frozen-lockfile`) so the warm container cache is reused.
  log "Installing frontend dependencies (pnpm install)..."
  pnpm install --reporter=silent >/dev/null 2>&1 || {
    warn "pnpm install failed; re-run manually to see the error."
    return 1
  }
  return 0
}

# --------------------------------------------------------------------------
# Ruby / bundler
# --------------------------------------------------------------------------
# The Gemfile pins an exact Ruby. When the container ships a different one,
# bundler refuses every command, which blocks Rails, Sidekiq, migrations and
# bin/vite. Nothing here can fix that, so report it precisely instead.
setup_ruby() {
  local required current
  required="$(tr -d '[:space:]' < .ruby-version 2>/dev/null)"
  current="$(ruby -v 2>/dev/null | cut -d' ' -f2)"

  if [ -z "$current" ]; then
    warn "Ruby is not installed — the Rails backend cannot run."
    return 1
  fi

  if [ -n "$required" ] && [ "$current" != "$required" ]; then
    warn "Ruby ${required} is required (.ruby-version) but ${current} is active."
    warn "  The Rails backend, Sidekiq, migrations and bin/vite are all blocked."
    warn "  Install it with: rbenv install ${required}"
    warn "  If that fails with a 403, this container's network policy is blocking"
    warn "  cache.ruby-lang.org and it must be allowlisted."
    return 1
  fi

  if bundle check >/dev/null 2>&1; then
    return 0
  fi

  log "Installing Ruby gems (bundle install)..."
  bundle install --quiet >/dev/null 2>&1 || {
    warn "bundle install failed; re-run manually to see the error."
    return 1
  }
  return 0
}

# --------------------------------------------------------------------------
main() {
  log "Preparing Chatwoot development environment..."

  # .env first: setup_postgres records the database password in it.
  setup_env_file; env_ok=$?
  setup_postgres; pg_ok=$?
  setup_redis;    redis_ok=$?
  setup_docker;   docker_ok=$?
  setup_frontend; fe_ok=$?
  setup_ruby;     ruby_ok=$?

  status() { [ "$1" -eq 0 ] && printf 'ready' || printf 'UNAVAILABLE'; }

  log "---------------------------------------------"
  log ".env       : $(status $env_ok)"
  log "PostgreSQL : $(status $pg_ok)"
  log "Redis      : $(status $redis_ok)"
  log "Docker     : $(status $docker_ok)"
  log "Frontend   : $(status $fe_ok)"
  log "Ruby/gems  : $(status $ruby_ok)"
  log "---------------------------------------------"

  if [ "$ruby_ok" -ne 0 ]; then
    log "Frontend work (pnpm test, pnpm eslint, pnpm build:sdk) is available."
    log "Backend work needs the Ruby issue above resolved first."
  else
    log "Next: bundle exec rails db:chatwoot_prepare"
  fi

  # Always succeed: a partially provisioned environment must not fail the session.
  return 0
}

main "$@"

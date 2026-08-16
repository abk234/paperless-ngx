#!/usr/bin/env bash
# Start / stop / update Paperless-ngx locally with data-safe upgrades and configurable backups.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_FILE="${PAPERLESS_APP_CONFIG:-$ROOT/scripts/paperless-app.env}"
SYNC_SCRIPT="$ROOT/scripts/sync-upstream.sh"
COMPOSE_DIR="$ROOT/docker/compose"

# Defaults (overridden by config / env)
BACKUP_DIR="${BACKUP_DIR:-$ROOT/../paperless-backups}"
BACKUP_INTERVAL_DAYS="${BACKUP_INTERVAL_DAYS:-30}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.postgres.yml}"
PAPERLESS_PORT="${PAPERLESS_PORT:-18000}"
UPDATE_SYNC_ON_UPDATE="${UPDATE_SYNC_ON_UPDATE:-true}"

usage() {
  cat <<'EOF'
Usage: scripts/paperless-app.sh <command> [options]

Commands:
  start                 Start Paperless in the background
  stop                  Stop containers (keeps all data)
  down                  Remove containers (keeps volumes/bind mounts; never uses -v)
  status                Show stack, ports, and backup status
  backup                Create a backup now
  backup --if-due       Backup only if last one is older than BACKUP_INTERVAL_DAYS
  update                Backup (if due) → optional git sync → pull & recreate (data kept)
  schedule-hint         Print cron / launchd examples for monthly backups
  help                  Show this help

Update options:
  --sync / --no-sync    Force or skip git sync with upstream (default from config)
  --backup / --no-backup Force or skip pre-update backup
  --rebase              When syncing, rebase instead of merge

Config:
  Copy scripts/paperless-app.env.example → scripts/paperless-app.env
  Or set PAPERLESS_APP_CONFIG=/path/to/file
EOF
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "warning: $*" >&2; }

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$CONFIG_FILE"
    set +a
  fi

  if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$ROOT/$BACKUP_DIR"
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
  docker info >/dev/null 2>&1 || die "docker is not running (start Docker Desktop)"
}

project_name() {
  local name
  name="$(grep -E '^COMPOSE_PROJECT_NAME=' "$COMPOSE_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  echo "${name:-paperless}"
}

ensure_runtime_files() {
  mkdir -p "$COMPOSE_DIR/consume" "$COMPOSE_DIR/export"

  if [[ ! -f "$COMPOSE_DIR/docker-compose.local.env" ]]; then
    info "creating docker/compose/docker-compose.local.env (secret key)"
    local secret
    secret="$(openssl rand -hex 32)"
    cat >"$COMPOSE_DIR/docker-compose.local.env" <<EOF
# Local-only (gitignored). Loaded via docker-compose.override.yml.
PAPERLESS_SECRET_KEY=${secret}
PAPERLESS_TIME_ZONE=America/New_York
PAPERLESS_OCR_LANGUAGE=eng
EOF
  fi

  if [[ ! -f "$COMPOSE_DIR/docker-compose.override.yml" ]]; then
    info "creating docker/compose/docker-compose.override.yml (localhost bind on ${PAPERLESS_PORT})"
    cat >"$COMPOSE_DIR/docker-compose.override.yml" <<EOF
# Local-only override (gitignored). Binds UI to localhost; LAN access via paperless-lan-proxy.
services:
  webserver:
    env_file:
      - docker-compose.env
      - docker-compose.local.env
    ports: !override
      - "127.0.0.1:${PAPERLESS_PORT}:8000"
EOF
  fi
}

compose() {
  (
    cd "$COMPOSE_DIR"
    local args=(-f "./$COMPOSE_FILE")
    # Explicit -f disables automatic override loading; include it when present.
    if [[ -f ./docker-compose.override.yml ]]; then
      args+=(-f ./docker-compose.override.yml)
    fi
    docker compose "${args[@]}" "$@"
  )
}

stack_running() {
  local ids
  ids="$(compose ps -q 2>/dev/null || true)"
  [[ -n "$ids" ]]
}

db_container() {
  local name
  name="$(project_name)-db-1"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    echo "$name"
    return 0
  fi
  # Fallback: any running compose db service
  compose ps -q db 2>/dev/null | head -n1
}

volume_name() {
  # Compose named volume → <project>_<volume>
  echo "$(project_name)_$1"
}

last_backup_dir() {
  [[ -d "$BACKUP_DIR" ]] || return 1
  local latest
  latest="$(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null | head -n1 || true)"
  [[ -n "$latest" ]] || return 1
  echo "$latest"
}

backup_age_days() {
  local latest mtime now
  latest="$(last_backup_dir)" || return 1
  if [[ -f "$latest/.paperless-backup-complete" ]]; then
    mtime="$(stat -f %m "$latest/.paperless-backup-complete" 2>/dev/null || stat -c %Y "$latest/.paperless-backup-complete")"
  else
    mtime="$(stat -f %m "$latest" 2>/dev/null || stat -c %Y "$latest")"
  fi
  now="$(date +%s)"
  echo $(( (now - mtime) / 86400 ))
}

prune_backups() {
  local keep="${BACKUP_KEEP:-3}"
  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  [[ -d "$BACKUP_DIR" ]] || return 0
  local i=0 dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    i=$((i + 1))
    if [[ "$i" -gt "$keep" ]]; then
      info "pruning old backup: $dir"
      rm -rf "$dir"
    fi
  done < <(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null || true)
}

LAN_PROXY="$ROOT/scripts/paperless-lan-proxy.py"
LAN_PROXY_PID="$ROOT/scripts/.paperless-lan-proxy.pid"

lan_ip() {
  ipconfig getifaddr en7 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true
}

stop_lan_proxy() {
  if [[ -f "$LAN_PROXY_PID" ]]; then
    local pid
    pid="$(cat "$LAN_PROXY_PID" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "stopping LAN proxy (pid $pid)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$LAN_PROXY_PID"
  fi
  pkill -f 'paperless-lan-proxy.py' 2>/dev/null || true
}

start_lan_proxy() {
  stop_lan_proxy
  [[ -f "$LAN_PROXY" ]] || die "missing $LAN_PROXY"
  info "starting LAN proxy (phone access via LAN IP:${PAPERLESS_PORT} → localhost:${PAPERLESS_PORT})"
  python3 "$LAN_PROXY" \
    --listen-port "$PAPERLESS_PORT" \
    --target-port "$PAPERLESS_PORT" \
    --daemon \
    --pid-file "$LAN_PROXY_PID"
  sleep 0.5
  local lip
  lip="$(lan_ip)"
  if [[ -n "$lip" ]]; then
    info "phone / LAN URL: http://${lip}:${PAPERLESS_PORT}"
  else
    info "phone / LAN URL: http://<your-mac-lan-ip>:${PAPERLESS_PORT}"
  fi
}

cmd_start() {
  require_docker
  ensure_runtime_files
  info "pulling images (if needed) and starting Paperless (detached)"
  compose pull
  compose up -d --remove-orphans
  start_lan_proxy
  info "web UI: http://localhost:${PAPERLESS_PORT}"
  info "first boot can take a minute while the webserver initializes"
  compose ps
}

cmd_stop() {
  require_docker
  ensure_runtime_files
  stop_lan_proxy
  info "stopping Paperless containers (data retained)"
  compose stop
}

cmd_down() {
  require_docker
  ensure_runtime_files
  stop_lan_proxy
  info "removing Paperless containers (no -v; volumes retained)"
  compose down --remove-orphans
}

cmd_status() {
  require_docker
  ensure_runtime_files
  local lip
  lip="$(lan_ip)"

  echo "config:     $CONFIG_FILE$([ -f "$CONFIG_FILE" ] && echo '' || echo ' (missing — using defaults)')"
  echo "compose:    docker/compose/$COMPOSE_FILE"
  echo "project:    $(project_name)"
  echo "port:       $PAPERLESS_PORT (localhost bind + LAN proxy)"
  echo "local URL:  http://localhost:${PAPERLESS_PORT}"
  if [[ -n "$lip" ]]; then
    echo "LAN URL:    http://${lip}:${PAPERLESS_PORT}"
  fi
  echo "consume:    $COMPOSE_DIR/consume"
  echo "export:     $COMPOSE_DIR/export"
  echo "backups:    $BACKUP_DIR"
  echo "interval:   every $BACKUP_INTERVAL_DAYS day(s), keep $BACKUP_KEEP"
  echo

  if stack_running; then
    compose ps
  else
    echo "stack:      not running"
  fi
  echo

  local latest age
  if latest="$(last_backup_dir)"; then
    age="$(backup_age_days || echo '?')"
    echo "last backup: $latest (${age} day(s) ago)"
  else
    echo "last backup: none"
  fi
}

do_backup() {
  local if_due=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --if-due) if_due=true ;;
      *) die "unknown backup option: $1" ;;
    esac
    shift
  done

  ensure_runtime_files

  if [[ "$if_due" == true ]]; then
    local age
    if age="$(backup_age_days 2>/dev/null)"; then
      if [[ "$age" -lt "$BACKUP_INTERVAL_DAYS" ]]; then
        info "backup not due (last was ${age}d ago; interval ${BACKUP_INTERVAL_DAYS}d)"
        return 0
      fi
    fi
  fi

  require_docker
  mkdir -p "$BACKUP_DIR"
  local stamp dest was_running=false dbc
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"

  info "backing up to $dest"

  if stack_running; then
    was_running=true
  fi

  dbc="$(db_container || true)"
  if [[ -n "$dbc" ]]; then
    info "dumping database (pg_dump)"
    docker exec "$dbc" pg_dump -U paperless -d paperless --clean --if-exists \
      >"$dest/paperless.sql"
  else
    warn "db container not running — skipping SQL dump; copying pgdata volume instead"
  fi

  info "copying Docker volumes (data, media, pgdata)"
  mkdir -p "$dest/volumes"
  local vol
  for vol in data media pgdata; do
    local vname
    vname="$(volume_name "$vol")"
    if docker volume inspect "$vname" >/dev/null 2>&1; then
      docker run --rm \
        -v "${vname}:/from:ro" \
        -v "$dest/volumes:/to" \
        docker.io/library/alpine:3.20 \
        sh -c "mkdir -p /to/$vol && cp -a /from/. /to/$vol/"
    else
      warn "volume missing: $vname"
    fi
  done

  if [[ -d "$COMPOSE_DIR/consume" ]]; then
    mkdir -p "$dest/consume"
    rsync -a "$COMPOSE_DIR/consume/" "$dest/consume/" 2>/dev/null || cp -a "$COMPOSE_DIR/consume/." "$dest/consume/"
  fi
  if [[ -d "$COMPOSE_DIR/export" ]]; then
    mkdir -p "$dest/export"
    rsync -a "$COMPOSE_DIR/export/" "$dest/export/" 2>/dev/null || cp -a "$COMPOSE_DIR/export/." "$dest/export/"
  fi

  for f in docker-compose.env docker-compose.local.env .env docker-compose.override.yml; do
    if [[ -f "$COMPOSE_DIR/$f" ]]; then
      cp "$COMPOSE_DIR/$f" "$dest/$f"
    fi
  done

  cat >"$dest/MANIFEST.txt" <<EOF
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
project=$(project_name)
hostname=$(hostname)
git_head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
compose_file=$COMPOSE_FILE
port=$PAPERLESS_PORT
EOF
  touch "$dest/.paperless-backup-complete"

  prune_backups
  info "backup complete: $dest"

  if [[ "$was_running" == true ]] && ! stack_running; then
    info "restarting stack after backup"
    compose start
  fi
}

cmd_update() {
  local do_sync="$UPDATE_SYNC_ON_UPDATE"
  local do_backup="if-due"
  local rebase=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync) do_sync=true ;;
      --no-sync) do_sync=false ;;
      --backup) do_backup=force ;;
      --no-backup) do_backup=skip ;;
      --rebase) rebase=true ;;
      *) die "unknown update option: $1" ;;
    esac
    shift
  done

  require_docker
  ensure_runtime_files

  case "$do_backup" in
    force) do_backup ;;
    if-due) do_backup --if-due ;;
    skip) info "skipping backup (--no-backup)" ;;
  esac

  if [[ "$do_sync" == true || "$do_sync" == "true" ]]; then
    [[ -x "$SYNC_SCRIPT" ]] || die "missing $SYNC_SCRIPT"
    info "syncing from paperless-ngx upstream"
    if [[ "$rebase" == true ]]; then
      "$SYNC_SCRIPT" sync --rebase
    else
      "$SYNC_SCRIPT" sync
    fi
  else
    info "skipping git sync"
  fi

  info "pulling images and recreating containers (volumes / data kept)"
  # Intentionally no -v / --renew-anon-volumes: protect named volumes.
  compose pull
  compose up -d --remove-orphans --force-recreate
  start_lan_proxy
  info "update complete"
  compose ps
  info "web UI: http://localhost:${PAPERLESS_PORT}"
}

cmd_schedule_hint() {
  local script="$ROOT/scripts/paperless-app.sh"
  cat <<EOF
# Cron (monthly check on the 1st at 03:15) — uses BACKUP_INTERVAL_DAYS via --if-due
15 3 1 * * $script backup --if-due >>$BACKUP_DIR/backup.log 2>&1

# Cron (daily check; only backs up when due)
15 3 * * * $script backup --if-due >>$BACKUP_DIR/backup.log 2>&1

# macOS launchd (save as ~/Library/LaunchAgents/com.paperless.host-backup.plist)
# ProgramArguments: $script
#               backup
#               --if-due
# StartCalendarInterval: Day=1 Hour=3 Minute=15

Config file: $CONFIG_FILE
BACKUP_DIR=$BACKUP_DIR
BACKUP_INTERVAL_DAYS=$BACKUP_INTERVAL_DAYS
EOF
}

main() {
  load_config
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  case "$cmd" in
    -h|--help|help) usage ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    down) cmd_down ;;
    status) cmd_status ;;
    backup) do_backup "$@" ;;
    update) cmd_update "$@" ;;
    schedule-hint) cmd_schedule_hint ;;
    *) die "unknown command: $cmd (try help)" ;;
  esac
}

main "$@"

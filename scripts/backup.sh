#!/usr/bin/env bash
set -euo pipefail

saludu_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
saludu_env_file="${SALUDU_ENV_FILE:-$saludu_root/.env}"
saludu_project="${SALUDU_PROJECT:-salud-u}"
saludu_backup_dir="${1:-$saludu_root/backups}"

if [[ ! -f "$saludu_env_file" ]]; then
  printf 'No se encontró el archivo de entorno: %s\n' "$saludu_env_file" >&2
  exit 2
fi

mkdir -p "$saludu_backup_dir"
umask 077
saludu_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
saludu_backup_file="$saludu_backup_dir/salud-u-$saludu_stamp.dump"

docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'pg_dump --format=custom --no-owner --no-privileges --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
  > "$saludu_backup_file"

if [[ ! -s "$saludu_backup_file" ]]; then
  printf 'El respaldo generado está vacío: %s\n' "$saludu_backup_file" >&2
  exit 1
fi

printf '%s\n' "$saludu_backup_file"

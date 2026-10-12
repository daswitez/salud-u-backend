#!/usr/bin/env bash
set -euo pipefail

saludu_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
saludu_env_file="${SALUDU_ENV_FILE:-$saludu_root/.env}"
saludu_project="${SALUDU_PROJECT:-salud-u}"
saludu_backup_file="${1:-}"
saludu_confirmation="${2:-}"

if [[ "$saludu_confirmation" != "--confirm-restore" ]]; then
  printf 'La restauración reemplaza por completo la base del proyecto. Usa: scripts/restore.sh ARCHIVO --confirm-restore\n' >&2
  exit 2
fi
if [[ ! -f "$saludu_backup_file" ]]; then
  printf 'No se encontró el respaldo: %s\n' "$saludu_backup_file" >&2
  exit 2
fi
if [[ ! -f "$saludu_env_file" ]]; then
  printf 'No se encontró el archivo de entorno: %s\n' "$saludu_env_file" >&2
  exit 2
fi

docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" stop backend || true
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu '
    psql --set=ON_ERROR_STOP=1 --username="$POSTGRES_USER" --dbname=postgres \
      -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '\''$POSTGRES_DB'\'' AND pid <> pg_backend_pid()"
    psql --set=ON_ERROR_STOP=1 --username="$POSTGRES_USER" --dbname=postgres \
      -c "DROP DATABASE \"$POSTGRES_DB\""
    psql --set=ON_ERROR_STOP=1 --username="$POSTGRES_USER" --dbname=postgres \
      -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\""
  '
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'pg_restore --exit-on-error --no-owner --no-privileges --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
  < "$saludu_backup_file"
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" up -d backend

printf 'Restauración completada desde %s\n' "$saludu_backup_file"

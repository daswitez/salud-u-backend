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

# Verificar el descifrado y formato antes de detener el servicio o borrar la base.
saludu_encrypted=false
if [[ "$saludu_backup_file" == *.gpg ]]; then
  saludu_encrypted=true
  command -v gpg >/dev/null || { printf 'Falta gpg.\n' >&2; exit 2; }
  [[ -n "${SALUDU_BACKUP_KEY_FILE:-}" && -s "${SALUDU_BACKUP_KEY_FILE:-}" ]] || { printf 'Define SALUDU_BACKUP_KEY_FILE con la clave externa.\n' >&2; exit 2; }
fi
saludu_stream() {
  if "$saludu_encrypted"; then
    gpg --batch --pinentry-mode loopback --passphrase-file "$SALUDU_BACKUP_KEY_FILE" --decrypt "$saludu_backup_file"
  else
    cat -- "$saludu_backup_file"
  fi
}
saludu_stream | docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'pg_restore --list >/dev/null'

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
saludu_stream | docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'pg_restore --exit-on-error --no-owner --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"'
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" up -d backend

printf 'Restauración completada desde %s\n' "$saludu_backup_file"

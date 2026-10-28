#!/usr/bin/env bash
set -euo pipefail

saludu_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
saludu_env_file="${SALUDU_ENV_FILE:-$saludu_root/.env}"
saludu_project="${SALUDU_PROJECT:-salud-u}"
saludu_backup_dir="${1:-$saludu_root/backups}"
saludu_encrypt="${2:-}"
if [[ -n "$saludu_encrypt" && "$saludu_encrypt" != "--encrypt" ]]; then
  printf 'Uso: scripts/backup.sh [DIRECTORIO] [--encrypt]\n' >&2; exit 2
fi
if [[ "$saludu_encrypt" == "--encrypt" ]]; then
  command -v gpg >/dev/null || { printf 'Falta gpg.\n' >&2; exit 2; }
  [[ -n "${SALUDU_BACKUP_KEY_FILE:-}" && -s "${SALUDU_BACKUP_KEY_FILE:-}" ]] || { printf 'Define SALUDU_BACKUP_KEY_FILE con la clave externa.\n' >&2; exit 2; }
fi

if [[ ! -f "$saludu_env_file" ]]; then
  printf 'No se encontró el archivo de entorno: %s\n' "$saludu_env_file" >&2
  exit 2
fi

mkdir -p "$saludu_backup_dir"
umask 077
saludu_stamp="$(date -u +%Y%m%dT%H%M%S%NZ)"
saludu_backup_file="$saludu_backup_dir/salud-u-$saludu_stamp.dump"

if [[ "$saludu_encrypt" == "--encrypt" ]]; then
  saludu_backup_file="$saludu_backup_file.gpg"
fi
saludu_temp_file="$(mktemp "$saludu_backup_dir/.salud-u-backup.XXXXXXXX")"
trap 'rm -f -- "$saludu_temp_file"' EXIT
if [[ "$saludu_encrypt" == "--encrypt" ]]; then
  docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
    sh -ceu 'pg_dump --format=custom --no-owner --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
    | gpg --batch --yes --pinentry-mode loopback --passphrase-file "$SALUDU_BACKUP_KEY_FILE" --symmetric --cipher-algo AES256 > "$saludu_temp_file"
else
  docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
    sh -ceu 'pg_dump --format=custom --no-owner --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' > "$saludu_temp_file"
fi
[[ -s "$saludu_temp_file" ]] || { printf 'El respaldo generado está vacío.\n' >&2; exit 1; }
mv -- "$saludu_temp_file" "$saludu_backup_file"

if [[ ! -s "$saludu_backup_file" ]]; then
  printf 'El respaldo generado está vacío: %s\n' "$saludu_backup_file" >&2
  exit 1
fi

printf '%s\n' "$saludu_backup_file"

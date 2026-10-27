#!/usr/bin/env bash
# Inventario de nombres y valores en inglés en la base de una instancia levantada con Docker Compose (ES-00).
# A diferencia de EsquemaEspanolIntegrationTest, que revisa una base recién migrada, aquí también cuentan
# los datos reales (estados, roles y códigos de auditoría guardados).
# Uso: ./scripts/inventario-ingles.sh [--detalle]   (local: SALUDU_PROJECT=salud-u-backend)
set -euo pipefail

saludu_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
saludu_env_file="${SALUDU_ENV_FILE:-$saludu_root/.env}"
saludu_project="${SALUDU_PROJECT:-salud-u}"
saludu_sql="$saludu_root/scripts/inventario-ingles.sql"

if [[ ! -f "$saludu_env_file" ]]; then
  printf 'No se encontró el archivo de entorno: %s\n' "$saludu_env_file" >&2
  exit 2
fi

saludu_result="$(docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'psql --no-psqlrc --quiet --tuples-only --no-align --field-separator="|" --set=ON_ERROR_STOP=1 --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
  < "$saludu_sql")"

# ES-10: contrato utilizable desde CI; falla si reaparece inglés.
if [[ "${1:-}" == "--exigir-cero" ]]; then
  if [[ -n "$saludu_result" ]]; then
    printf '%s\n' "$saludu_result" >&2
    exit 1
  fi
  printf '0\n'
  exit 0
fi

if [[ "${1:-}" == "--detalle" ]]; then
  printf '%s\n' "$saludu_result"
  exit 0
fi

printf 'Elementos en inglés por categoría:\n'
if [[ -z "$saludu_result" ]]; then
  printf '  ninguno\n'
else
  printf '%s\n' "$saludu_result" | cut -d'|' -f1 | sort | uniq -c
  printf '  total: %s\n' "$(printf '%s\n' "$saludu_result" | wc -l)"
fi

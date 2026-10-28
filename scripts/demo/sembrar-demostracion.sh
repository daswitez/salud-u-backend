#!/usr/bin/env bash
# Sembrado exclusivamente en proyecto de demostración vacío, nunca en la base operativa.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ -f "${DEMO_ENV_FILE:-}" && -s "${DEMO_PASSWORD_FILE:-}" ]] || { printf 'Define DEMO_ENV_FILE y DEMO_PASSWORD_FILE externos.\n' >&2; exit 2; }
saludu_demo_project=salud-u-capturas
compose() { docker compose --env-file "$DEMO_ENV_FILE" -p "$saludu_demo_project" "$@"; }
saludu_demo_container=$(compose ps -q postgres)
[[ -n "$saludu_demo_container" ]] || { printf 'No está activo el proyecto de demostración.\n' >&2; exit 2; }
[[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$saludu_demo_container")" == "$saludu_demo_project" ]] || exit 2
saludu_demo_count=$(compose exec -T postgres sh -ceu 'psql -X -A -t -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select count(*) from salud_u.principal"')
[[ "$saludu_demo_count" == 0 ]] || { printf 'La base de demostración no está vacía; no se modificó.\n' >&2; exit 2; }
compose exec -T postgres sh -ceu 'psql -q -v ON_ERROR_STOP=1 -v clave="$1" -U "$POSTGRES_USER" -d "$POSTGRES_DB"' demo "$(cat "$DEMO_PASSWORD_FILE")" < scripts/demo/sembrar-demostracion.sql

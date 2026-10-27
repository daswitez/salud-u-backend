#!/usr/bin/env bash
# FE-CORTE / BE-CORTE: ensayo mixto de búsquedas y reportes de fin de mes sobre una pila desechable con volumen sintético.
# Levanta un proyecto Compose aislado (puertos 18080/15432), siembra volumen, mide con concurrencia y lo elimina al terminar.
# Uso: scripts/load-mixed.sh [pacientes]   (LOAD_CONCURRENCY, LOAD_ROUNDS y LOAD_RESULT ajustan el ensayo)
set -euo pipefail

saludu_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
saludu_temp_dir="$(mktemp -d)"
saludu_project="salud-u-carga-${RANDOM}${RANDOM}"
saludu_env_file="$saludu_temp_dir/compose.env"
saludu_backend_port="18080"
saludu_patients="${1:-3000}"
compose() { docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" "$@"; }
cleanup() { compose down --volumes --remove-orphans >/dev/null 2>&1 || true; rm -rf "$saludu_temp_dir"; }
trap cleanup EXIT

for saludu_command in docker curl openssl node; do
  command -v "$saludu_command" >/dev/null || { printf 'Falta el comando: %s\n' "$saludu_command" >&2; exit 2; }
done
umask 077
saludu_password="Carga-$(openssl rand -hex 12)"
printf 'DB_NAME=salud_u\nDB_MIGRATOR_USER=salud_u_migrator\nDB_MIGRATOR_PASSWORD=%s\nDB_APP_USER=salud_u_runtime\nDB_APP_PASSWORD=%s\nDB_PORT=15432\nBACKEND_PORT=%s\nSESSION_COOKIE_SECURE=false\n' \
  "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" "$saludu_backend_port" > "$saludu_env_file"

cd "$saludu_root"
compose up --build --detach
for saludu_attempt in $(seq 1 60); do
  curl --fail --silent "http://127.0.0.1:$saludu_backend_port/actuator/health/readiness" | grep -q '"status":"UP"' && break
  [[ "$saludu_attempt" == 60 ]] && { compose logs backend >&2; printf 'Readiness no llegó a UP\n' >&2; exit 1; }
  sleep 2
done

compose exec -T postgres sh -ceu 'psql --quiet --tuples-only --no-align -v clave="$1" -v pacientes="$2" --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' seed \
  "$saludu_password" "$saludu_patients" < scripts/load/seed-volume.sql
LOAD_ORIGIN="http://127.0.0.1:$saludu_backend_port" LOAD_PASSWORD="$saludu_password" node scripts/load/mixed-load.mjs

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
if [[ "${LOAD_MODE:-mixed}" == "rnf" ]]; then
  saludu_override="$saludu_temp_dir/override.yaml"
  printf 'services:\n  backend:\n    image: salud-u-rnf-local\n' > "$saludu_override"
  compose() { docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" -f "$saludu_root/compose.yaml" -f "$saludu_override" "$@"; }
else
  compose() { docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" "$@"; }
fi
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
if [[ "${LOAD_MODE:-mixed}" == "rnf" ]]; then compose up --no-build --detach; else compose up --build --detach; fi
for saludu_attempt in $(seq 1 60); do
  curl --fail --silent "http://127.0.0.1:$saludu_backend_port/actuator/health/readiness" | grep -q '"status":"UP"' && break
  [[ "$saludu_attempt" == 60 ]] && { compose logs backend >&2; printf 'Readiness no llegó a UP\n' >&2; exit 1; }
  sleep 2
done

compose exec -T postgres sh -ceu 'psql --quiet --tuples-only --no-align -v clave="$1" -v pacientes="$2" --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' seed \
  "$saludu_password" "$saludu_patients" < scripts/load/seed-volume.sql
if [[ "${LOAD_MODE:-mixed}" == "rnf" ]]; then
  compose exec -T postgres sh -ceu 'psql --quiet --tuples-only --no-align --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' < scripts/load/seed-rnf-agenda.sql
  for saludu_concurrency in 5 10 20; do
    LOAD_ORIGIN="http://127.0.0.1:$saludu_backend_port" LOAD_PASSWORD="$saludu_password" LOAD_PATIENTS="$saludu_patients" LOAD_CONCURRENCY="$saludu_concurrency" \
      LOAD_RESULT="${LOAD_RESULT_DIR:?Definir LOAD_RESULT_DIR}/carga-${saludu_patients}-${saludu_concurrency}.json" node scripts/load/rnf-load.mjs
  done
  # Solo después de la carga: ejecutar la tarea real mediante cron, sin solaparla con los percentiles.
  printf 'services:\n  backend:\n    image: salud-u-rnf-local\n    environment:\n      SALUD_U_SCHEDULING_ENABLED: "true"\n      SALUD_U_DAY_CLOSE_CRON: "0 * * * * *"\n' > "$saludu_override"
  compose up --no-build --detach --force-recreate backend
  saludu_backend_id="$(compose ps -q backend)"
  saludu_deadline=$(( $(date +%s) + 360 ))
  while :; do
    docker logs "$saludu_backend_id" > "${LOAD_RESULT_DIR}/cierre-${saludu_patients}.log" 2>&1
    if grep -q 'Actualización diaria: fin; duración_ms=' "${LOAD_RESULT_DIR}/cierre-${saludu_patients}.log"; then break; fi
    [[ $(date +%s) -lt $saludu_deadline ]] || { printf 'No terminó DayCloseJob en 360 segundos.\n' >&2; exit 1; }
    sleep 2
  done
  LOAD_PATIENTS="$saludu_patients" LOAD_CLOSE_LOG="${LOAD_RESULT_DIR}/cierre-${saludu_patients}.log" \
    LOAD_CLOSE_RESULT="${LOAD_RESULT_DIR}/cierre-${saludu_patients}.json" node scripts/load/parse-day-close.mjs
else
  LOAD_ORIGIN="http://127.0.0.1:$saludu_backend_port" LOAD_PASSWORD="$saludu_password" node scripts/load/mixed-load.mjs
fi

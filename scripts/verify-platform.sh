#!/usr/bin/env bash
set -euo pipefail

saludu_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
saludu_temp_dir="$(mktemp -d)"
saludu_project="salud-u-t02-${RANDOM}${RANDOM}"
saludu_env_file="$saludu_temp_dir/compose.env"
saludu_backup_dir="$saludu_temp_dir/backups"
saludu_backend_port="18080"
saludu_probe_value="before-backup"
shopt -s nullglob
saludu_migration_files=("$saludu_root"/src/main/resources/db/migration/*.sql)
saludu_expected_migration_count="${#saludu_migration_files[@]}"
[[ "$saludu_expected_migration_count" -gt 0 ]] || { printf 'No se encontraron migraciones Flyway.\n' >&2; exit 1; }

cleanup() {
  docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$saludu_temp_dir"
}
trap cleanup EXIT

wait_for_readiness() {
  saludu_health_url="http://127.0.0.1:$saludu_backend_port/actuator/health/readiness"
  saludu_health_body=""
  for saludu_attempt in $(seq 1 40); do
    if saludu_health_body="$(curl --fail --silent --show-error "$saludu_health_url" 2>/dev/null)"; then
      case "$saludu_health_body" in *'"status":"UP"'*) return 0 ;; esac
    fi
    sleep 2
  done
  docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" logs backend >&2
  printf 'Health/readiness no llegó a UP\n' >&2
  return 1
}

for saludu_command in docker curl openssl; do
  command -v "$saludu_command" >/dev/null || { printf 'Falta el comando: %s\n' "$saludu_command" >&2; exit 2; }
done
docker compose version >/dev/null

umask 077
saludu_migrator_password="$(openssl rand -hex 24)"
saludu_runtime_password="$(openssl rand -hex 24)"
printf 'DB_NAME=salud_u\nDB_MIGRATOR_USER=salud_u_migrator\nDB_MIGRATOR_PASSWORD=%s\nDB_APP_USER=salud_u_runtime\nDB_APP_PASSWORD=%s\nDB_PORT=15432\nBACKEND_PORT=%s\nSESSION_COOKIE_SECURE=false\n' \
  "$saludu_migrator_password" "$saludu_runtime_password" "$saludu_backend_port" > "$saludu_env_file"

cd "$saludu_root"
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" config --quiet
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" up --build --detach
wait_for_readiness

saludu_migration_count="$(docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'psql --tuples-only --no-align --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -c "SELECT count(*) FROM flyway_schema_history WHERE success"')"
[[ "$saludu_migration_count" == "$saludu_expected_migration_count" ]] || { printf 'Flyway aplicó %s de %s migraciones esperadas.\n' "$saludu_migration_count" "$saludu_expected_migration_count" >&2; exit 1; }

docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T backend \
  sh -ceu 'printf t02-volume-probe > "$DOCUMENTS_ROOT/t02-volume-probe"'
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" stop
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" up --detach
wait_for_readiness
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T backend \
  sh -ceu 'test "$(cat "$DOCUMENTS_ROOT/t02-volume-probe")" = t02-volume-probe'

docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'psql --set=ON_ERROR_STOP=1 --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -c "CREATE TABLE salud_u.t02_restore_probe (value text NOT NULL); INSERT INTO salud_u.t02_restore_probe(value) VALUES ('\''before-backup'\'');"'
export SALUDU_ENV_FILE="$saludu_env_file"
export SALUDU_PROJECT="$saludu_project"
saludu_backup_file="$($saludu_root/scripts/backup.sh "$saludu_backup_dir")"
docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'psql --set=ON_ERROR_STOP=1 --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -c "INSERT INTO salud_u.t02_restore_probe(value) VALUES ('\''after-backup'\'');"'
"$saludu_root/scripts/restore.sh" "$saludu_backup_file" --confirm-restore
wait_for_readiness
saludu_restored_value="$(docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'psql --tuples-only --no-align --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -c "SELECT string_agg(value, '\'', '\'' ORDER BY value) FROM salud_u.t02_restore_probe"')"
[[ "$saludu_restored_value" == "$saludu_probe_value" ]] || { printf 'La restauración no recuperó el estado esperado: %s\n' "$saludu_restored_value" >&2; exit 1; }
saludu_restored_migration_count="$(docker compose --env-file "$saludu_env_file" --project-name "$saludu_project" exec -T postgres \
  sh -ceu 'psql --tuples-only --no-align --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -c "SELECT count(*) FROM flyway_schema_history WHERE success"')"
[[ "$saludu_restored_migration_count" == "$saludu_expected_migration_count" ]] || { printf 'Flyway no quedó restaurado correctamente: %s de %s.\n' "$saludu_restored_migration_count" "$saludu_expected_migration_count" >&2; exit 1; }

printf 'T-02 OK: build, Flyway, health/readiness, persistencia y respaldo/restauración verificados.\n'

#!/usr/bin/env sh
set -eu

case "${APP_DB_USER:-}" in
  ''|*[!a-zA-Z0-9_]*)
    printf '%s\n' 'APP_DB_USER debe contener únicamente letras, números o guion bajo.' >&2
    exit 1
    ;;
esac

if [ -z "${APP_DB_PASSWORD:-}" ]; then
  printf '%s\n' 'APP_DB_PASSWORD es obligatorio.' >&2
  exit 1
fi

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=runtime_role="$APP_DB_USER" \
  --set=runtime_password="$APP_DB_PASSWORD" \
  --set=runtime_database="$POSTGRES_DB" <<'SQL'
CREATE ROLE :"runtime_role" LOGIN PASSWORD :'runtime_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
GRANT CONNECT ON DATABASE :"runtime_database" TO :"runtime_role";
SQL

#!/usr/bin/env bash
# Concilia metadatos de documentos clínicos (PostgreSQL) con los archivos del volumen de documentos.
# Sólo lectura: informa diferencias y termina con código 1 si existe alguna; nunca borra ni corrige.
set -euo pipefail

saludu_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
saludu_env_file="${SALUDU_ENV_FILE:-$saludu_root/.env}"
saludu_project="${SALUDU_PROJECT:-salud-u}"

if [[ ! -f "$saludu_env_file" ]]; then
  printf 'No se encontró el archivo de entorno: %s\n' "$saludu_env_file" >&2
  exit 2
fi

saludu_compose=(docker compose --env-file "$saludu_env_file" --project-name "$saludu_project")
saludu_temp_dir="$(mktemp -d)"
trap 'rm -rf "$saludu_temp_dir"' EXIT

# Ruta, checksum y estado de cada fila; las filas PROCESSING confirmadas no deberían existir (la carga es una sola transacción).
"${saludu_compose[@]}" exec -T postgres sh -ceu \
  'psql -v ON_ERROR_STOP=1 -At -F " " --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" -c "select coalesce(checksum_sha256, chr(45)), ruta_objeto, estado from salud_u.documento_clinico order by ruta_objeto"' \
  > "$saludu_temp_dir/database.txt"
"${saludu_compose[@]}" exec -T backend bash -ceu \
  'cd "${DOCUMENTS_ROOT:-/var/lib/salud-u/documents}" && find . -type f -print0 | sort -z | xargs -0r sha256sum | sed "s#  \./# #"' \
  > "$saludu_temp_dir/files.txt"

python3 -I - "$saludu_temp_dir/database.txt" "$saludu_temp_dir/files.txt" <<'PY'
import json, sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    checksum, path, state = line.rstrip("\n").split(" ", 2)
    rows[path] = (checksum, state)
files = {}
for line in open(sys.argv[2], encoding="utf-8"):
    checksum, path = line.rstrip("\n").split(" ", 1)
    files[path] = checksum
report = {
    "filasDisponibles": sum(1 for _, state in rows.values() if state == "AVAILABLE"),
    "archivos": len(files),
    "filasSinArchivo": sorted(p for p, (_, s) in rows.items() if s == "AVAILABLE" and p not in files),
    "checksumDistinto": sorted(p for p, (c, s) in rows.items() if s == "AVAILABLE" and p in files and files[p] != c),
    "archivosSinFila": sorted(p for p in files if p not in rows and not p.rsplit("/", 1)[-1].startswith("upload-")),
    "temporalesAbandonados": sorted(p for p in files if p.rsplit("/", 1)[-1].startswith("upload-")),
    "filasProcesando": sorted(p for p, (_, s) in rows.items() if s == "PROCESSING"),
}
problems = sum(len(v) for k, v in report.items() if isinstance(v, list))
report["estado"] = "CONCILIADO" if problems == 0 else "DIFERENCIAS"
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if problems == 0 else 1)
PY

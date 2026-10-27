# Imagen solo para desarrollo y pruebas: la misma base que producción más plpgsql_check,
# que revisa el cuerpo de las funciones PL/pgSQL (columnas, tipos y valores) sin ejecutarlas.
# La imagen de producción sigue siendo postgres:17-bookworm sin cambios.
FROM postgres:17-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-plpgsql-check \
 && rm -rf /var/lib/apt/lists/*

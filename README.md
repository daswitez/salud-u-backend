# Salud-U Backend

Base de un monolito modular independiente del frontend Next.js. No se ha inicializado Git.

Tecnologías: Java 21, Spring Boot 3.5.16, Maven, Spring Security, Spring Data JPA/Hibernate, Bean Validation, PostgreSQL 17, Flyway y Actuator. Java 21 y Maven son compatibles con la [versión elegida](https://docs.spring.io/spring-boot/3.5/system-requirements.html). Docker construye y ejecuta la aplicación sin instalar Java o Maven en el equipo.

## Iniciar con Docker

Requiere Docker Engine con Compose v2.

```bash
cp .env.example .env
# Editar .env: establecer DB_MIGRATOR_PASSWORD y DB_APP_PASSWORD.
docker compose up --build -d
docker compose logs -f backend
curl --fail http://localhost:8080/actuator/health
curl --fail http://localhost:8080/actuator/health/readiness
```

El estado esperado es `{"status":"UP"}`; readiness comprueba también PostgreSQL. `docker compose down` detiene los servicios conservando sus volúmenes.

La API escucha en localhost:8080 y PostgreSQL en localhost:5432. Los documentos se reservan en un volumen privado accesible por el backend, sin servidor público de archivos. Compose levanta únicamente backend y base de datos; el frontend sigue arrancando desde su propio proyecto.

## Desarrollo sin contenedor del backend

Con JDK 21 y Maven 3.6.3 o superior:

```bash
docker compose up -d postgres
# Definir DB_APP_PASSWORD, DB_MIGRATOR_USER y DB_MIGRATOR_PASSWORD en el proceso Maven.
mvn spring-boot:run
mvn verify
```

Spring Boot no lee `.env` automáticamente fuera de Compose. DB_URL, DB_APP_USER, DB_APP_PASSWORD, DB_MIGRATOR_USER, DB_MIGRATOR_PASSWORD, SERVER_PORT y DOCUMENTS_ROOT configuran la ejecución local.

## Alcance de esta base

Paquetes por dominio con capas api, application, domain e infrastructure; configuración transversal en shared. Flyway crea únicamente el esquema inicial vacío. Hibernate valida el esquema y no genera tablas.

Se publican salud técnica, CSRF, login, logout y la consulta de sesión. Las demás solicitudes están denegadas y CSRF permanece activo. BE-01 usa credenciales persistidas y sesiones opacas HttpOnly/SameSite/Secure, aplica límite de intentos y resuelve roles vigentes en cada solicitud. No hay usuario de prueba, datos clínicos ni endpoints de negocio; el alta administrativa y la migración institucional de usuarios se implementarán después. Esto aún no es una implementación de seguridad lista para producción.

Apache POI y OpenPDF se incorporarán cuando existan exportaciones concretas. No se añade JWT, MinIO ni microservicios: el documento indica sesiones y sistema de archivos privado.

Consulta [el estudio y plan de migración](docs/estudio-migracion.md), la [operación, TLS y recuperación](docs/operations/platform-and-recovery.md), la [decisión de persistencia y RLS](docs/operations/persistence-security.md), los [contratos HTTP base](docs/operations/api-contracts.md) y [la operación de identidad](docs/operations/identity-session.md). La especificación se sirve en `/openapi/salud-u-v1.yaml` y la colección está en `docs/postman/`.

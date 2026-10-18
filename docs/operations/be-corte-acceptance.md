# BE-CORTE — informe de aceptación integral

Fecha de corte: 2026-10-17. Este informe usa solamente código, contenedores y datos temporales locales. No se conectó ni modificó una instancia institucional, Supabase ni archivos clínicos reales.

## Dictamen

**No aceptado todavía como “backend listo para integrar”.** La regresión actual del backend es satisfactoria, pero faltan tres evidencias que forman parte de la aceptación de H-CORTE: la suite independiente de Next, el ensayo completo de la plataforma Docker con recuperación y una migración de datos/cuentas con datos sintéticos aprobados. No es correcto convertir esos pendientes en una aceptación por el mero hecho de que las pruebas Java pasen.

## Trazabilidad funcional

La matriz completa y vigente está en [backlog-backend.md](../backlog-backend.md), líneas 610–637. Relaciona UC-01…UC-27 con BE-01…BE-27 y RF-01…RF-34, incluyendo BE-CAT para RF-28, BE-INV para RF-34 y el carácter transversal de RF-27.

La referencia HTTP de Next está caracterizada en [reference-t01/http-contract-notes.md](../reference-t01/http-contract-notes.md) y los contratos expuestos por Spring están en [`src/main/resources/static/openapi/salud-u-v1.yaml`](../../src/main/resources/static/openapi/salud-u-v1.yaml). No se ha cambiado el repositorio `codigo/salud-u`: continúa siendo la referencia serverless hasta que se autorice su integración.

## Evidencia ejecutada

| Control | Resultado | Alcance comprobado |
| --- | --- | --- |
| `mvn test` | **PASA** | 77 pruebas; 0 fallos, 0 errores, 0 omitidas. Incluye MVC, permisos y persistencia PostgreSQL temporal mediante Testcontainers. Ejecutado el 2026-10-17, 14.265 s. |
| `npm run lint` en `codigo/salud-u` | **BLOQUEADO por entorno** | No hay dependencias instaladas. `npm` resolvió ESLint global 6.4.0, incompatible con la configuración declarada para ESLint 9, y terminó antes de analizar el código. |
| `pnpm` / Corepack | **BLOQUEADO por entorno** | El repositorio usa `pnpm-lock.yaml`, pero `pnpm` no está instalado; Corepack no pudo resolver `registry.npmjs.org` (`EAI_AGAIN`). Por tanto no se ejecutaron `lint`, `typecheck` ni `build` con dependencias bloqueadas. |
| `./scripts/verify-platform.sh` | **INCONCLUSO** | El proyecto y credenciales son temporales, pero el proceso se interrumpió durante `mvn dependency:go-offline` dentro de la imagen Docker, antes de levantar PostgreSQL/Flyway. No existe resultado de health, backup ni restore que pueda marcarse como aprobado. |

Comandos ejecutados en este corte:

```bash
# backend
mvn test
./scripts/verify-platform.sh

# frontend ejecutado (sin alterar fuentes)
npm run lint
pnpm --version
corepack pnpm --version
```

`npm run typecheck` y `npm run build` no se ejecutaron: `npm run lint` falló primero; las comprobaciones posteriores identificaron la falta de `pnpm` y el bloqueo de red de Corepack.

## Migración, recuperación y credenciales

`scripts/verify-platform.sh`, `scripts/backup.sh` y `scripts/restore.sh` ya delimitan un ensayo efímero: crean un proyecto Docker y una base temporales, aplican Flyway, hacen backup/restauración y eliminan sus recursos al final. El ensayo debe completarse antes de declararlo aprobado.

Eso no sustituye una migración histórica. El SQL serverless depende de `auth.users`, políticas RLS y Storage de Supabase, por lo que no puede cargarse como una migración Flyway de PostgreSQL independiente. Aún falta un mapeador y un fixture sintético aprobado que permitan comparar, antes y después de la migración, UUID, claves foráneas, versiones, recuentos y checksums de archivos.

Las cuentas tampoco se copian de manera implícita: Flyway deliberadamente no crea usuarios ni contraseñas de demostración. La estrategia documentada exige alta/importación institucional con contraseña inicial bcrypt entregada fuera de la API o restablecimiento controlado; no se ha ensayado contra una fuente sanitizada. No se deben migrar hashes de Supabase sin validar su formato, origen y mecanismo de recuperación.

## Diferencias contractuales conocidas

- Next mantiene rutas `/api` serverless y Supabase; Spring publica contratos `/api/v1` documentados. La sustitución de transporte/cookies/CSRF y el proxy de integración siguen fuera de alcance hasta tocar el frontend.
- Los DTO conservan el envelope `ok/data/error` cuando la referencia lo exige; las diferencias de validación inseguras identificadas por T-01 no se deben reproducir solo para obtener paridad.
- Las URLs firmadas, archivos DOCX/XLSX/PDF y exportaciones se comparan por contenido, permiso y vigencia, no por token, fecha ni bytes de ZIP.

## Condiciones objetivas para cerrar H-CORTE

1. Instalar el gestor declarado por el lockfile y ejecutar en limpio `pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm typecheck` y `pnpm build` en `codigo/salud-u`.
2. Completar `./scripts/verify-platform.sh` y adjuntar su salida de health, Flyway, reinicio, backup y restauración.
3. Definir el volumen institucional y ejecutar la regresión por roles, concurrencia y accesos entre áreas; registrar percentiles de los flujos comunes y demostrar el objetivo menor a 3 s.
4. Crear y ejecutar un ensayo de migración exclusivamente con fixture sintético: comparar UUID/FK/versiones/recuentos/checksums y probar rollback.
5. Aprobar y ensayar la estrategia de cuentas y contraseñas con el responsable institucional, sin exponer secretos ni tocar datos reales.

Hasta cumplir los cinco puntos, esta historia permanece abierta y el frontend no debe apuntar al backend como reemplazo productivo.

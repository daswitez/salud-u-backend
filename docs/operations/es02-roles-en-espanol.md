# ES-02 · Roles en español

Fecha: 26 de octubre de 2026. Estado: **terminada**, salvo la tarea 5, que se completa en ES-03 a ES-08. Migración: `V73__roles_en_espanol.sql`.

## Qué cambió

| Antes (base) | Ahora (base) | API, Spring y frontend |
|---|---|---|
| `ADMINISTRATIVE` | `ADMINISTRATIVO` | `ADMINISTRATIVE` |
| `REVIEW_DOCTOR` | `MEDICO_REVISION` | `REVIEW_DOCTOR` |
| `SPECIALIST` | `ESPECIALISTA` | `SPECIALIST` |
| `STUDENT` | `ESTUDIANTE` | `STUDENT` |
| `AUDITOR` | `AUDITOR` | `AUDITOR` |
| `REPORTING_OFFICER` | `RESPONSABLE_REPORTES` | `REPORTING_OFFICER` |

- **Datos.** `rol_principal.codigo_rol` es del tipo enum `codigo_rol_aplicacion`, así que basta con `ALTER TYPE … RENAME VALUE`: todas las filas cambian a la vez, sin `UPDATE`, y el orden del tipo se conserva. El enum ya limita los valores; no hace falta un CHECK.
- **Entrada desde Java.** `DatabaseActorContext.apply` traduce los roles del actor con `desde_codigo_api` en el mismo `set_config`, una sola vez por transacción. `salud_u.roles_actor` ya llega en español y `roles_actor_actual` no cambia. Un rol desconocido hace fallar la transacción. Antes se ignoraba, pero Java solo envía roles leídos de la base.
- **Salida hacia Java.** Estas funciones devuelven códigos de API con `a_codigo_api`:
  - `autenticar_principal` y `resolver_sesion_autenticacion`: ordenan los roles por el orden del tipo, que da el mismo orden que el `CASE` anterior;
  - `listar_principales_administracion`;
  - `listar_eventos_auditoria_paginados`: sigue ordenando alfabéticamente por código de API.

  `crear_principal_administrativo` y `establecer_rol_principal` reciben códigos de API y los traducen al guardar.
- **Java no cambia** fuera de esa sentencia: `AuthenticationService`, `SessionAuthenticationFilter`, `@PreAuthorize`, `SessionUserResponse` (`/api/me`) y la validación `@Pattern` de las solicitudes siguen en inglés.
- **Vacunación.** `registrar_dosis_vacuna` y `contexto_registro_vacunacion` comparaban `rol_principal` con el literal `'REVIEW_DOCTOR'::codigo_rol_aplicacion`, que dejó de existir. Se reescribieron con `'MEDICO_REVISION'` y sus llamadas a `tiene_rol_actor` ya están en español.

## Transición de `tiene_rol_actor`

`tiene_rol_actor(p_rol text)` acepta el rol en español o el código de API. Primero compara en español; solo consulta el diccionario cuando llega un código de API. Un rol que no existe lanza `CODIGO_DOMINIO_DESCONOCIDO`, igual que antes fallaba la conversión al tipo.

Quedan **60 llamadas con el código en inglés en 31 funciones**. Las lista el inventario como `literal_funcion|<función>=ADMINISTRATIVE`, etc. Cada historia de ES-03 a ES-08 las pasa a español cuando reescribe su función. En ES-10, `tiene_rol_actor` vuelve a recibir solo `codigo_rol_aplicacion` y desaparece la rama del diccionario.

## Política de auditoría

La única política del rol de la aplicación que mira roles dependía de la firma vieja de `tiene_rol_actor`, así que hubo que recrearla. Al hacerlo:

- cambió el nombre mal formado `auditoria_event_read_auditoriaor` por `evento_auditoria_lectura_auditor`;
- la llamada quedó envuelta en `(SELECT …)`, para que PostgreSQL la evalúe una vez por consulta y no en cada fila.

## Ensayo de rendimiento

El ensayo se hizo sobre una copia de la base local restaurada desde `backups/salud-u-20261027T011438Z.dump`, con 7450 eventos de auditoría.

| Versión | `count(*)` de `evento_auditoria`, como auditor | Como médico (no ve nada) |
|---|---|---|
| V72 (antes) | 87 ms | 86 ms |
| Primer borrador de V73: traducía los roles en cada lectura de `roles_actor_actual` | 343 ms | — |
| V73 final | 0,5 ms | 0,3 ms |

El primer borrador quedó descartado por esta medición. En la misma copia, las 257 cuentas devuelven exactamente los mismos roles antes y después de V73. Distribución final de roles: `ADMINISTRATIVO` 1, `MEDICO_REVISION` 63, `ESPECIALISTA` 85, `ESTUDIANTE` 12, `AUDITOR` 45, `RESPONSABLE_REPORTES` 64. La copia se eliminó; la base local no se tocó.

## Pruebas

- `CaracterizacionFlujosIntegrationTest.losSeisRolesInicianSesionConLasMismasAutoridadesYElMismoApiMe`: se escribió y pasó **antes** de V73, y pasa igual después. Para cada uno de los seis roles prueba:
  - creación de la cuenta;
  - listado de cuentas;
  - inicio de sesión y resolución de la sesión;
  - `role` y `clinicalRole` de `/api/me`.

  Con una cuenta que tiene los seis roles, también comprueba el orden en la sesión, en el listado de cuentas y en la auditoría.
- `DatabaseActorContextIntegrationTest.actorContextStoresRolesInSpanishAndRejectsUnknownApiCodes`: el contexto guarda los roles en español y rechaza los códigos desconocidos.
- `EsquemaEspanolIntegrationTest.tieneRolActorAceptaAmbosNombresEnTransicionYLosRolesEstanEnEspanol`: la transición y el orden de los valores del enum.
- Datos de prueba: las inserciones directas en `rol_principal` se pasaron a español, y los `cast(? as codigo_rol_aplicacion)` con parámetro ahora pasan por `desde_codigo_api`.

Resultados:

- `mvn verify` con **198 pruebas aprobadas** (antes 195).
- `plpgsql_check` sin errores.
- Cobertura de funciones: 104 de 106.
- La línea base del inventario bajó de 550 a **531**: salieron 19 elementos y no entró ninguno. Son los 5 valores del enum, 12 literales de sesión y vacunación, el parámetro `required_rol` y la política mal nombrada.

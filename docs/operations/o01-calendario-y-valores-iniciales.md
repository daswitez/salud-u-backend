# O-01 · Calendario académico y valores iniciales

Fecha: 27 de octubre de 2026. Estado: **terminada**. Migración: `V86__calendario_academico_y_valores_iniciales.sql`.
Trazabilidad: RF-37, UC-29, DV-10.

Es la entrada del componente de optimización (O-02 a O-04). Solo Administración la configura; nada de esto toca tablas clínicas.

## 1. Tablas

**`periodo_academico`**: `nombre`, `tipo`, `fecha_inicio`, `fecha_fin`, `creado_por`, `creado_en`.

- `tipo` admite INICIO_SEMESTRE, CLASES, EXAMENES o VACACIONES (CHECK).
- Las fechas son inclusivas, con `fecha_inicio <= fecha_fin` y a lo sumo 367 días por período.
- **Sin solapes:** la restricción de exclusión `periodo_academico_sin_solapes` (`daterange(fecha_inicio, fecha_fin, '[]') WITH &&`) impide que un día pertenezca a dos períodos, sea cual sea su tipo. Así O-02 obtiene un único tipo de período por fecha. No necesita `btree_gist`, porque los rangos ya tienen su operador GiST.

**`valor_inicial_agenda`**: `id_especialidad`, `tipo_periodo`, `demanda_diaria_esperada`, `asistencia_esperada`, `peso_citas`, `registrado_por`, `creado_en`, `actualizado_en`.

- `id_especialidad` NULL es el valor del **área**, del que parten las especialidades sin datos (O-03).
- Una fila por especialidad (o área) y tipo de período: `UNIQUE NULLS NOT DISTINCT`.
- **Valores por defecto de DV-10:**
  - asistencia 0,800;
  - peso de 10 citas;
  - `demanda_diaria_esperada` NULL, que significa "igual a la capacidad publicada". La capacidad cambia con cada cupo, por eso no se copia un número: O-03 la resuelve al estimar.
- Rangos: asistencia en (0, 1) abierto, porque con 0 o 1 la Beta inicial de O-03 degenera; demanda de 0 a 1000; peso de 1 a 100.

Ambas tablas tienen RLS forzada con solo la política del migrador. El rol de la aplicación no tiene permisos sobre ellas: solo usa las cuatro funciones.

## 2. Funciones (todas `SECURITY DEFINER`, con `requerir_administrativo()` y `GRANT EXECUTE` explícito)

| Función | Uso |
|---|---|
| `listar_periodos_academicos()` | Calendario ordenado por fecha de inicio. |
| `registrar_periodo_academico(nombre, tipo, inicio, fin)` | Valida, inserta y audita `PERIODO_ACADEMICO_REGISTRADO`. Un solape responde `PERIODO_ACADEMICO_SOLAPADO`. |
| `listar_valores_iniciales_agenda()` | Una fila por tipo de período para el área y para cada especialidad activa o con valores guardados. Lo no guardado sale con los valores de DV-10 y `predeterminado = true`. |
| `guardar_valores_iniciales_agenda(jsonb)` | Guarda un lote todo o nada. |

Detalles de `guardar_valores_iniciales_agenda`:

- Rechaza filas repetidas, especialidades inactivas o inexistentes, y valores fuera de rango.
- Rechaza más decimales de los que guarda la columna (3 en asistencia, 2 en demanda), en vez de redondear en silencio.
- Una fila igual a la guardada no se reescribe ni se audita.
- Cada cambio audita `VALOR_INICIAL_AGENDA_GUARDADO` con el valor nuevo y el anterior.

## 3. Códigos y API

Nuevo dominio del diccionario, `tipo_periodo_academico`: INICIO_SEMESTRE→SEMESTER_START, CLASES→CLASSES, EXAMENES→EXAMS, VACACIONES→VACATION. Queda en **100 equivalencias / 30 dominios**.

Paquete Java `scheduling` (`SchedulingSetupController`, `SchedulingSetupService`), todo con `hasRole('ADMINISTRATIVE')` y `Cache-Control: no-store, private`:

| Método | Ruta | Respuesta |
|---|---|---|
| GET | `/api/academic-periods` | `{ok, data: [{id, name, type, startDate, endDate, createdAt}]}` |
| POST | `/api/academic-periods` | 201 con el período. 400 si los datos son inválidos o hay campos de más; 409 si se solapa. |
| GET | `/api/scheduling/initial-values` | `{ok, data: [{specialtyId, specialtyName, periodType, expectedDailyDemand, expectedAttendance, appointmentWeight, isDefault, updatedAt}]}` |
| PUT | `/api/scheduling/initial-values` | Cuerpo `{values: [...]}` con las filas que cambian; devuelve la tabla completa. |

Las rutas están en `SecurityConfig`, en el OpenAPI y en el proxy `beforeFiles` de `codigo/salud-u/next.config.ts`. La pantalla es F-03, todavía pendiente.

## Pruebas y resultados

- `mvn verify`: **240 pruebas**, sin fallos, errores ni omisiones; `plpgsql_check` aprobado; inventario de inglés en cero. Las pruebas ejecutan 118 de las 120 funciones SQL, incluidas las cuatro nuevas.
- `SchedulingSetupApiIntegrationTest` (3 pruebas, MockMvc sobre PostgreSQL) comprueba:
  - registro con códigos en inglés y guardado en español; un día compartido ya es solape; seis cuerpos inválidos, incluido el código en español `CLASES`;
  - valores por defecto de DV-10 para el área y cada especialidad activa; guardado de demanda NULL; reenvío sin auditoría; cambio auditado con el valor anterior;
  - nueve lotes inválidos que no guardan nada, fila repetida y especialidad inactiva;
  - 403 para estudiante, reportes, médico de revisión y auditor; 401 sin sesión; el rol de la aplicación no puede leer las tablas, y la función rechaza sin contexto administrativo.
- `EsquemaEspanolIntegrationTest` registra las dos columnas nuevas en `DOMINIO_POR_COLUMNA`, y su prueba de RLS y permisos de PUBLIC cubre las tablas y funciones nuevas.

## Base local

1. Respaldo previo: `backups/salud-u-20261027T051227Z.dump`.
2. Backend reconstruido. Flyway aplicó **V86**, la preparación responde 200 y no hay errores ni advertencias en el log.
3. Comprobado sobre la base local:
   - 0 funciones abiertas a PUBLIC; RLS forzada en las dos tablas;
   - los valores iniciales salen como 380 filas (área y 94 especialidades × 4 tipos), todas predeterminadas;
   - un registro de prueba devolvió `EXAMS` dentro de una transacción que se deshizo;
   - sin sesión, ambos endpoints responden 401.

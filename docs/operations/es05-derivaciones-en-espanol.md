# ES-05 · Derivaciones en español

Fecha: 26 de octubre de 2026. Estado: **terminada**. Migración: `V76__derivaciones_en_espanol.sql`.

## Qué cambió

| Columna | Antes | Ahora |
|---|---|---|
| `derivacion.estado`, `evento_estado_derivacion.estado_anterior` y `estado_nuevo` | PENDING_ASSIGNMENT, ASSIGNED, IN_PROGRESS, RETURNED, CLOSED, CANCELLED | PENDIENTE_ASIGNACION, ASIGNADA, EN_CURSO, DEVUELTA, CERRADA, CANCELADA |
| `derivacion.prioridad` | ROUTINE, PRIORITY, URGENT | RUTINA, PRIORITARIA, URGENTE |

Se sigue el mismo orden que en ES-03 y ES-04:

1. Quitar los CHECK y el valor por defecto. Estas tablas no tienen índices parciales ni disparadores.
2. Traducir los datos con `desde_codigo_api`.
3. Recrear los CHECK con nombres en español. Los estados de `evento_estado_derivacion` no tenían CHECK: se agregan, y `estado_anterior` sigue admitiendo NULL, que es el evento de emisión.

## Funciones

Se reescribieron 13 funciones a partir de su última definición en la base, con reemplazos explícitos por función:

- emisión (`finalizar_encuentro_revision` de 12 parámetros);
- programación (`crear_solicitud_derivacion` y la rama de derivación de `asignar_solicitud_cita`);
- inicio de la atención (`abrir_encuentro_borrador`);
- devolución y resolución (`resolver_o_devolver_derivacion`);
- bandejas y listados: `listar_bandeja_derivaciones_administracion`, `listar_derivaciones_paciente_para_cita`, `consultar_derivaciones_asignadas`, `listar_derivaciones_emitidas_propias`, `obtener_derivacion_emitida_propia`, `contexto_origen_especialidad` y `obtener_historia_longitudinal_area`;
- `resumen_administrativo`.

Detalles:

- **Salidas hacia Java** con `a_codigo_api`: estado, prioridad y los estados `from`/`to` de los eventos.
- **Entradas desde Java**, traducidas sin cambiar el error ni el orden de las validaciones:
  - `finalizar_encuentro_revision` traduce la prioridad. Ante un código desconocido sigue lanzando `DERIVACION_INCOMPLETA`.
  - `resolver_o_devolver_derivacion` traduce la acción `RESOLVE`/`RETURN` con el dominio `accion_derivacion` (RESOLVER, DEVOLVER). Una acción desconocida o NULL sigue llegando a `ACCION_DERIVACION_INVALIDA` después de las mismas comprobaciones de permiso, estado y longitud.
- **El orden de la bandeja administrativa no cambió:** el `CASE` que la ordena (pendiente, asignada, en curso, resto) solo cambió sus literales.
- **Auditoría.** `resolver_o_devolver_derivacion` guarda `estadoAnterior` y `estadoNuevo` en los detalles del evento, y desde ahora quedan en español. Ninguna función ni Java expone esos detalles (`listar_eventos_auditoria_paginados` no los devuelve). Los eventos anteriores conservan sus valores en inglés, porque la auditoría es de solo agregar.
- **Literales que siguen en inglés** en estas funciones: `AVAILABLE`, de documentos (ES-06), y `SUCCESS`, de auditoría (ES-08). Los nombres de columna de las bandejas (`status`, `priority`…) son nombres, no valores, y los leen los controladores; quedan para ES-09.

**Java no cambió.** `MedicalEncounterController` y `ReferralController` solo validan códigos de API (`ROUTINE`…, `RESOLVE`/`RETURN`), y es lo que siguen enviando.

## Pruebas y resultados

- `mvn verify` con **198 pruebas aprobadas**, `plpgsql_check` sin errores y cobertura de funciones de 104 de 106.
- Caracterización igual que antes: la derivación completa de `CaracterizacionFlujosIntegrationTest` sigue viendo `ASSIGNED` e `IN_PROGRESS` en la API.
- Datos de prueba: se tradujeron 11 líneas de `DatabaseActorContextIntegrationTest` que escriben o leen las dos tablas directamente.
- Inventario: de 365 a **335** elementos. Salieron 30 (21 literales y 9 valores CHECK) y no entró ninguno. Ya no queda ningún valor de derivación en inglés.

## Ensayo con datos reales

Se hizo sobre una copia restaurada desde `backups/salud-u-20261027T015805Z.dump`, aplicando V72 a V75 y luego V76.

**Conteos traducidos uno a uno:**

- 66 derivaciones: por ejemplo, 26 `EN_CURSO/URGENTE`, 15 en `PENDIENTE_ASIGNACION` y 7 `CERRADA`;
- 166 eventos de estado.

**91 llamadas comparadas antes y después de V76:**

- bandeja asignada, contexto de origen e historia de los pacientes del especialista con derivaciones asignadas;
- derivaciones emitidas, en lista y una por una, del médico de revisión que las emitió;
- bandeja administrativa, derivaciones programables de cada paciente con derivaciones, y resumen administrativo;
- en transacciones que se deshacen:
  - devolver y resolver 4 derivaciones activas;
  - una acción inválida, una acción NULL y una devolución sin motivo;
  - una emisión con prioridad inválida.

**Resultado: las mismas 123 filas y los mismos errores.** Solo cambian los números de línea en el `CONTEXT` de los errores (`ACCION_DERIVACION_INVALIDA`, `MOTIVO_DEVOLUCION_REQUERIDO`, `ATENCION_ESPECIALIZADA_REQUERIDA`, `DERIVACION_INCOMPLETA`), porque las funciones tienen líneas nuevas.

Las copias se eliminaron; la base local no se tocó.

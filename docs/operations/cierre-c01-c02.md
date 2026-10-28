# C-01 / C-02 · Estado del backend y ejecución del Apéndice A.6

Fecha: **27/10/2026**. Fuente vigente confirmada por el usuario: **MSD-Documento proyecto de grado Ver.1.10 u.docx**. Se leyó directamente el DOCX, incluidos Cuadros 3.66/3.67 y Apéndices A.5/A.6. No se usó el Markdown antiguo para fijar la numeración del cierre ni se modificó el documento fuente.

## Dictamen

**C-01 terminada. C-02 ejecutada, con una observación de PA-23.** Las pruebas técnicas pasan, pero no se equipara ese resultado a una conformidad documental sin reservas. El correo sigue fuera del alcance autorizado; no se simula una prueba SMTP inexistente. El cierre institucional y SUS permanecen pendientes.

- Backend **Flyway V96**, sin migraciones nuevas en este trabajo.
- `mvn -B -ntp verify`: **312 pruebas, 0 fallos, 0 errores, 0 omitidas**. Ejecución actual del 27/10, no reutilización de los conteos históricos.
- Código de producción identificado por SHA-256 de sus archivos; pruebas, fuente DOCX y frontend también tienen huella. El frontend tiene cambios sin commit: no se presenta HEAD como si incluyera esos cambios. [Versión y entorno](../evaluacion/cierre-20261027/version-entorno.json).
- PostgreSQL/Testcontainers real en integración; MockMvc real de Spring para los escenarios O-04/O-06/O-07. Datos sintéticos; los tests unitarios/MockMvc simulados se distinguen en la suite general.

## C-01 · Estados registrados

`docs/backlog-backend.md` ahora contiene estado de cierre explícito para **BE-05…BE-27, BE-INV y BE-CORTE: 25 historias**. Cada historia enlaza las pruebas actuales y la evidencia funcional anterior que corresponda. Se preservan los hechos y resultados de incrementos anteriores como historia, sin convertir una prueba de 2026-10-25 en una ejecución del 27.

La cabecera ya no afirma que no se dispone de Maven/Docker; los avisos antiguos de T-01…BE-04 se contextualizan como históricos. Las funcionalidades se consideran implementadas/verificadas **localmente**, no aprobadas por la institución. BE-23 conserva la validación de regla académica/volumen; BE-CORTE conserva migración histórica, cuentas, hardware/volumen y aceptación humana pendientes. [Dictamen de corte](be-corte-acceptance.md).

## C-02 · Registro y resultados

[Tabla A.6](../evaluacion/cierre-20261027/registro-a6.md) y [CSV de seis columnas](../evaluacion/cierre-20261027/registro-a6.csv): **ID de prueba, fecha, versión, entorno, resultado, evidencia**, conforme al Cuadro A.24. Cada ID tiene un JSON con los métodos realmente ejecutados y su alcance. [Resumen de las 312 pruebas](../evaluacion/cierre-20261027/pruebas.json) excluye las propiedades y el stdout de JUnit; [log Maven](../evaluacion/cierre-20261027/maven.log).

| ID | Escenario ejecutado | Resultado |
|---|---|---|
| PV-7.1 | Asignación y cancelación generan avisos; concurrencia, privacidad y rollback | APROBADA |
| PV-7.2 | Recordatorio de mañana según Bolivia, preferencias, reintento tras fallo y ausencia de duplicados | APROBADA EN ALCANCE BANDEJA; escenario SMTP original NO APLICA |
| PV-7.3 | Cierre con 8 asistencias/2 ausencias y recálculo α/β con λ=0,95, versión `o03-v1` | APROBADA |
| PV-7.4 | Asistencia del 60 %, capacidad 10, sobrecupo máximo 1 y explicación | APROBADA |
| PV-7.5 | Sugerencia sin decidir vence y conserva capacidades de agenda | APROBADA |
| PV-7.6 | Bloqueo de tres citas: destinos distintos compatibles, confirmación, movimiento y avisos | APROBADA |
| PA-20 | Asignación/reprogramación/cancelación en bandeja, lectura propia y 404 sin fuga | APROBADA EN ALCANCE BANDEJA; parte SMTP NO APLICA |
| PA-21 | Ningún cambio de agenda sin decisión; vencimiento verificable | APROBADA |
| PA-22 | Tope institucional al aceptar/modificar; horarios/duración sin cambios | APROBADA |
| PA-23 | Auditoría de cierre, estimación y generación; revisión adicional de O-05 | **OBSERVADA: núcleo aprobado, discrepancia en O-05** |

PV-7.5 se mapea al vencimiento según el documento vigente. Aunque el backlog de O-05 menciona ese ID para los cupos sugeridos, no se usa esa referencia como sustituto del escenario documental.

### Cambio de alcance del correo

PV-7.2 y PA-20 del DOCX todavía mencionan servidor de correo caído/reintentos. La decisión vigente del usuario excluye SMTP y exige solo bandeja. Se registra esa parte como **NO APLICA**, y se adjunta la ejecución adaptada a recordatorios/reintentos transaccionales de bandeja. No se afirma haber enviado correos, apagado un servidor SMTP ni verificado su recuperación. La actualización del texto documental corresponde a la épica D.

### Observación PA-23

Los tres tests de dependencia del núcleo pasan: `cerrar_jornada`, las funciones de estimación y las de generación general consultan agenda/calendario/estimaciones. Sin embargo, la función **vigente en la base** `cupos_para_solicitud(uuid)` de O-05 consulta `salud_u.derivacion` para especialidad, prioridad, estado y paciente. No lee diagnósticos, antecedentes ni motivos clínicos, pero PA-23 dice expresamente «ninguna tabla clínica».

Se conserva la [definición real](../evaluacion/cierre-20261027/pa23-cupos-para-solicitud.sql) y la [auditoría](../evaluacion/cierre-20261027/pa23-auditoria.json). Por esa diferencia no se aprueba PA-23 para todo el componente. Requiere resolver la frontera: trasladar los metadatos operativos necesarios a agenda y mantener su consistencia, o precisar el criterio documental mediante una decisión de alcance. No se modifica esa regla ni se introduce una migración de sincronización durante el registro de evidencias.

## Reproducción

Desde el backend, con Docker disponible:

```bash
python3 scripts/registrar-cierre.py --directorio /tmp/salud-u-cierre-nuevo
SALUDU_PROJECT=salud-u-backend ./scripts/inventario-ingles.sh --exigir-cero
```

El primer comando ejecuta Maven, verifica que no existan fallos ni omisiones, extrae únicamente metadatos de los casos JUnit, consulta versión/definición SQL y genera A.6. También admite `--log /ruta/maven.log` para consumir una ejecución recién terminada junto a sus informes (ventana de 15 minutos). Si faltan métodos mapeados o la ejecución no terminó en BUILD SUCCESS, no registra un cierre aprobado. Usar un directorio nuevo por corrida para conservar la evidencia anterior.

Inventario inglés actual: **0**. El manifiesto SHA-256 del directorio permite comprobar que los artefactos conservados no cambiaron. [C-03: recorridos, capturas e instrumento SUS](../../../salud-u/docs/evidencia-cierre-c03.md).

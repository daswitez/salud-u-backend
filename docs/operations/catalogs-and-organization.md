# Catálogos y organización (BE-CAT)

## Alcance

BE-CAT introduce carreras, especialidades, personal, vigencias de especialidad y los catálogos clínicos de diagnósticos, mediciones, etiquetas y tipos de documento. Ninguna migración inserta valores de muestra. Los códigos son inmutables después de crear un registro; las bajas son lógicas mediante `is_active`, de modo que las referencias históricas permanecen válidas.

Las lecturas de compatibilidad conservan las formas actuales:

| Ruta | Acceso | Orden y JSON |
| --- | --- | --- |
| `GET /api/careers` | público | carreras activas por `name, code`; `{ok,data:[id,code,name]}`. |
| `GET /api/specialties` | médico de revisión, especialista o administrativo | especialidades activas por `name, code`; misma forma. |
| `GET /api/my-specialties` | médico de revisión o especialista | solo especialidades activas y vigentes de su personal; misma forma. |

Las extensiones se publican bajo `/api/v1/catalogs/{CAREER|SPECIALTY|CONDITION|MEASUREMENT|TAG|DOCUMENT_TYPE}` y `/api/v1/admin`. El acceso de escritura requiere `ROLE_ADMINISTRATIVE` en Spring y se vuelve a comprobar en PostgreSQL mediante el contexto de actor de la transacción.

## Persistencia y permisos

Las tablas nuevas tienen RLS forzado. El runtime no recibe permisos directos `SELECT/INSERT/UPDATE/DELETE`; solo ejecuta funciones de lectura y administración con `SECURITY DEFINER`, cuyo dueño es el migrador. Las funciones validan el rol administrativo antes de escribir. El servicio Spring registra cada escritura administrativa en el evento append-only de auditoría con el actor de la transacción. Esto permite que una llamada accidental desde una capa de aplicación sin autorización no modifique catálogos ni personal.

`staff_specialty` registra rango de vigencia. `list_my_specialties` exige que el principal tenga rol médico, que el miembro de personal y la especialidad estén activos, y que la fecha actual esté dentro del rango. Desactivar una especialidad evita su nueva selección, sin borrar asignaciones ni referencias anteriores.

La creación de un principal solicita una contraseña inicial de al menos 12 caracteres y roles explícitos. La contraseña se convierte en bcrypt dentro de PostgreSQL, no se devuelve y no aparece en fixtures. Las operaciones de rol y desactivación se aplican al principal existente; BE-01 invalida el acceso de sesiones cuando ya no existe un rol vigente.

## Pruebas y contrato

`CatalogControllerMvcTest` prueba lectura pública de carreras, las formas heredadas de prohibición, especialidades propias y escritura administrativa con CSRF. La prueba Testcontainers base agrega control de privilegios, rechazo de una función administrativa sin actor y desactivación sin eliminación. Las rutas, contratos nuevos y escenarios de Postman deben añadirse por cada catálogo que se exponga en una pantalla.

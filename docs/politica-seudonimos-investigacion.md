# Política de seudónimos de investigación

La exportación de investigación usa `MONTHLY-V1`: `R-` seguido de 20 caracteres derivados de un secreto exclusivo del servidor, el identificador interno del paciente y el mes calendario de la exportación en hora de Bolivia (`America/La_Paz`, desde V69).

Un mismo paciente conserva el seudónimo dentro de un mes, incluso en exportaciones repetidas y por solicitantes distintos. Al cambiar el mes, el seudónimo rota y no permite vincular los archivos entre meses. El diccionario describe columnas y categorías; no incluye ninguna clave de reidentificación.

El conjunto excluye carnet, código de registro, nombres, teléfonos, correo, identificadores internos y texto clínico libre. Edad se expresa por rango y fechas de atención por mes.

Cada exportación registra solicitante, finalidad, filtros normalizados, formato, filas, versión y mes de política y SHA-256 del archivo entregado; el solicitante puede consultar su constancia, pero no las de otros.

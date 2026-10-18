# Política de seudónimos de investigación

La exportación de investigación usa `MONTHLY-V1`: `R-` seguido de 20 caracteres derivados de un secreto exclusivo del servidor, el identificador interno del paciente y el mes calendario de la exportación.

Un mismo paciente conserva el seudónimo dentro de un mes, incluso en exportaciones repetidas y por solicitantes distintos. Al cambiar el mes, el seudónimo rota y no permite vincular los archivos entre meses. El diccionario describe columnas y categorías; no incluye ninguna clave de reidentificación.

El conjunto excluye carnet, código de registro, nombres, teléfonos, correo, identificadores internos y texto clínico libre. Edad se expresa por rango y fechas de atención por mes.

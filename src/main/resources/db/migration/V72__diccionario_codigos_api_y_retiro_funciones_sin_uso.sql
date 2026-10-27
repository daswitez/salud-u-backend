-- ES-01: la base pasa a español y el contrato HTTP conserva sus códigos en inglés. Este diccionario es el
-- único lugar donde conviven ambos: cada función que llama Java traduce con a_codigo_api al devolver y con
-- desde_codigo_api al recibir; dentro de la función todo es español. Los valores de "valor" son los que
-- usarán las tablas desde ES-02; hoy las tablas siguen en inglés y nada existente consulta el diccionario.
-- Los códigos que solo viajan entre SQL y Java (DUPLICATE_CARNET, AUTHENTICATED…) no van aquí: no llegan al
-- frontend y se traducen a la vez en SQL y en Java en su historia.
CREATE TABLE salud_u.equivalencia_codigo_api (
  dominio text NOT NULL CHECK (dominio ~ '^[a-z][a-z_]*$'),
  valor text NOT NULL CHECK (valor ~ '^[A-Z0-9][A-Z0-9_]*$'),
  codigo_api text NOT NULL CHECK (codigo_api ~ '^[A-Z0-9][A-Z0-9_]*$'),
  CONSTRAINT equivalencia_codigo_api_pkey PRIMARY KEY (dominio, valor),
  CONSTRAINT equivalencia_codigo_api_codigo_unico UNIQUE (dominio, codigo_api)
);
ALTER TABLE salud_u.equivalencia_codigo_api ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.equivalencia_codigo_api FORCE ROW LEVEL SECURITY;
CREATE POLICY equivalencia_codigo_api_migrador ON salud_u.equivalencia_codigo_api FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.equivalencia_codigo_api FROM PUBLIC, ${runtime_role};

INSERT INTO salud_u.equivalencia_codigo_api(dominio, valor, codigo_api) VALUES
  -- Roles (rol_principal.codigo_rol, tipo codigo_rol_aplicacion)
  ('rol','ADMINISTRATIVO','ADMINISTRATIVE'), ('rol','MEDICO_REVISION','REVIEW_DOCTOR'), ('rol','ESPECIALISTA','SPECIALIST'),
  ('rol','ESTUDIANTE','STUDENT'), ('rol','AUDITOR','AUDITOR'), ('rol','RESPONSABLE_REPORTES','REPORTING_OFFICER'),
  -- Pacientes e inscripción
  ('estado_academico','ACTIVO','ACTIVE'), ('estado_academico','INACTIVO','INACTIVE'),
  ('estado_academico','EGRESADO','GRADUATED'), ('estado_academico','SUSPENDIDO','SUSPENDED'),
  ('estado_inscripcion','ACTIVA','ACTIVE'), ('estado_inscripcion','INACTIVA','INACTIVE'), ('estado_inscripcion','COMPLETADA','COMPLETED'),
  -- Agenda
  ('estado_cupo','BORRADOR','DRAFT'), ('estado_cupo','PUBLICADO','PUBLISHED'), ('estado_cupo','BLOQUEADO','BLOCKED'), ('estado_cupo','CERRADO','CLOSED'),
  ('estado_solicitud','PENDIENTE','PENDING'), ('estado_solicitud','ASIGNADA','ASSIGNED'), ('estado_solicitud','CANCELADA','CANCELLED'),
  ('tipo_cita','INICIAL','INITIAL'), ('tipo_cita','ESPECIALIDAD','SPECIALTY'), ('tipo_cita','DERIVACION','REFERRAL'),
  ('origen_solicitud','INICIAL','INITIAL'), ('origen_solicitud','DIRECTA_ADMINISTRACION','ADMIN_DIRECT'),
  ('estado_cita','PROGRAMADA','SCHEDULED'), ('estado_cita','LLEGADA','CHECKED_IN'), ('estado_cita','ATENDIDA','ATTENDED'),
  ('estado_cita','CANCELADA','CANCELLED'), ('estado_cita','AUSENTE','NO_SHOW'),
  -- Atención clínica
  ('estado_encuentro','BORRADOR','DRAFT'), ('estado_encuentro','CERRADA','CLOSED'), ('estado_encuentro','ANULADA','VOIDED'),
  ('tipo_encuentro','INICIAL','INITIAL'), ('tipo_encuentro','ESPECIALIDAD','SPECIALTY'),
  ('estado_quimica','ADJUNTA','ATTACHED'), ('estado_quimica','PENDIENTE','PENDING'), ('estado_quimica','NO_PRESENTADA','NOT_PRESENTED'),
  ('estado_verificacion','CONFIRMADO','CONFIRMED'), ('estado_verificacion','REQUIERE_REVISION','NEEDS_REVIEW'),
  ('acceso_historia','AREA','AREA'), ('acceso_historia','ORIGEN_DERIVACION','REFERRAL_SOURCE'),
  -- Derivaciones
  ('estado_derivacion','PENDIENTE_ASIGNACION','PENDING_ASSIGNMENT'), ('estado_derivacion','ASIGNADA','ASSIGNED'),
  ('estado_derivacion','EN_CURSO','IN_PROGRESS'), ('estado_derivacion','DEVUELTA','RETURNED'),
  ('estado_derivacion','CERRADA','CLOSED'), ('estado_derivacion','CANCELADA','CANCELLED'),
  ('prioridad_derivacion','RUTINA','ROUTINE'), ('prioridad_derivacion','PRIORITARIA','PRIORITY'), ('prioridad_derivacion','URGENTE','URGENT'),
  ('accion_derivacion','RESOLVER','RESOLVE'), ('accion_derivacion','DEVOLVER','RETURN'),
  -- Documentos
  ('estado_documento','PROCESANDO','PROCESSING'), ('estado_documento','DISPONIBLE','AVAILABLE'), ('estado_documento','RECHAZADO','REJECTED'),
  ('tipo_documento','QUIMICA_SANGUINEA','BLOOD_CHEMISTRY'), ('tipo_documento','RESULTADO_LABORATORIO','LAB_RESULT'),
  ('tipo_documento','RADIOGRAFIA','RADIOGRAPH'), ('tipo_documento','RECETA','PRESCRIPTION'),
  ('tipo_documento','FOTOGRAFIA_CLINICA','CLINICAL_PHOTO'), ('tipo_documento','DOCUMENTO_DERIVACION','REFERRAL_DOCUMENT'),
  ('tipo_documento','OTRO','OTHER'),
  -- Catálogos administrables (parámetro de guardar_catalogo_administracion y listar_catalogo*)
  ('tipo_catalogo','CARRERA','CAREER'), ('tipo_catalogo','ESPECIALIDAD','SPECIALTY'), ('tipo_catalogo','CONDICION_CLINICA','CONDITION'),
  ('tipo_catalogo','TIPO_MEDICION','MEASUREMENT'), ('tipo_catalogo','ETIQUETA','TAG'), ('tipo_catalogo','TIPO_DOCUMENTO','DOCUMENT_TYPE'),
  -- Reportes, vacunación e investigación
  ('estado_exportacion','COMPLETADA','COMPLETED'), ('estado_exportacion','FALLIDA','FAILED'),
  ('estado_cumplimiento','CUMPLE','COMPLIANT'), ('estado_cumplimiento','PENDIENTE','PENDING'),
  ('estado_esquema_vacunacion','COMPLETO','COMPLETE'), ('estado_esquema_vacunacion','PARCIAL','PARTIAL'), ('estado_esquema_vacunacion','PENDIENTE','PENDING'),
  ('rango_edad','MENOR_20','UNDER_20'), ('rango_edad','20_24','20_24'), ('rango_edad','25_29','25_29'),
  ('rango_edad','30_O_MAS','30_PLUS'), ('rango_edad','DESCONOCIDO','UNKNOWN'),
  -- Auditoría (evento_auditoria.resultado, tipo codigo_resultado_auditoria)
  ('resultado_auditoria','EXITO','SUCCESS'), ('resultado_auditoria','DENEGADO','DENIED'), ('resultado_auditoria','FALLO','FAILURE');

-- Valor de la base → código de la API. NULL devuelve NULL; un valor fuera del dominio es un error de programación.
CREATE FUNCTION salud_u.a_codigo_api(p_dominio text, p_valor text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE resultado text;
BEGIN
  IF p_valor IS NULL THEN RETURN NULL; END IF;
  SELECT e.codigo_api INTO resultado FROM salud_u.equivalencia_codigo_api e WHERE e.dominio = p_dominio AND e.valor = p_valor;
  IF resultado IS NULL THEN
    RAISE EXCEPTION 'CODIGO_DOMINIO_DESCONOCIDO' USING ERRCODE = '22023', DETAIL = format('dominio=%s valor=%s', p_dominio, p_valor);
  END IF;
  RETURN resultado;
END $$;

-- Código de la API → valor de la base. NULL devuelve NULL; un código desconocido es un dato inválido del cliente.
CREATE FUNCTION salud_u.desde_codigo_api(p_dominio text, p_codigo text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE resultado text;
BEGIN
  IF p_codigo IS NULL THEN RETURN NULL; END IF;
  SELECT e.valor INTO resultado FROM salud_u.equivalencia_codigo_api e WHERE e.dominio = p_dominio AND e.codigo_api = p_codigo;
  IF resultado IS NULL THEN
    RAISE EXCEPTION 'CODIGO_DOMINIO_DESCONOCIDO' USING ERRCODE = '22023', DETAIL = format('dominio=%s codigo=%s', p_dominio, p_codigo);
  END IF;
  RETURN resultado;
END $$;

REVOKE ALL ON FUNCTION salud_u.a_codigo_api(text, text), salud_u.desde_codigo_api(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.a_codigo_api(text, text), salud_u.desde_codigo_api(text, text) TO ${runtime_role};

-- Funciones sin uso detectadas en ES-00: nadie las llama (ni Java, ni otras funciones, ni políticas) y
-- fueron reemplazadas por versiones posteriores. Se retiran en vez de traducirlas.
DROP FUNCTION salud_u.crear_solicitud_derivacion(uuid);  -- Java usa crear_solicitud_derivacion(uuid, uuid)
DROP FUNCTION salud_u.documento_compartido_con_especialista(uuid);
DROP FUNCTION salud_u.listar_adendas_encuentro(uuid);
DROP FUNCTION salud_u.listar_derivaciones_administracion();
DROP FUNCTION salud_u.obtener_antecedentes_clinicos(uuid);

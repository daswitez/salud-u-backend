-- Correcciones de la revisión posterior a ES-10 y N-03.
--
-- 1. Nueve funciones SECURITY DEFINER conservaban el EXECUTE de PUBLIC desde su creación (V17, V18, V26…): se
--    les concedió al rol de la aplicación, pero nunca se revocó el permiso por defecto. Se revoca a PUBLIC en
--    todo el esquema y se cambia el privilegio por defecto del migrador, para que las funciones nuevas nazcan
--    cerradas y cada migración tenga que concederlas explícitamente.
-- 2. rol_principal era la única tabla de salud_u sin RLS. El rol de la aplicación no tiene permisos sobre ella;
--    se habilita y fuerza RLS con la política del migrador, igual que en el resto del esquema.
-- 3. La API de notificaciones devolvía códigos en español. El contrato HTTP del proyecto está en inglés, así que
--    se cambian sus equivalencias de API; la base sigue guardando los valores en español.
-- 4. Un recordatorio deja de mostrarse cuando su cita ya no está programada para la fecha que anuncia
--    (cancelada, ausente, atendida o movida a otro día). No se borra: si la cita vuelve a quedar para mañana,
--    generar_recordatorios_citas_en lo actualiza y lo vuelve a entregar.

-- 1. Funciones sin EXECUTE para PUBLIC.
DO $$
DECLARE funcion regprocedure;
BEGIN
  FOR funcion IN SELECT p.oid::regprocedure FROM pg_proc p
    WHERE p.pronamespace = 'salud_u'::regnamespace AND has_function_privilege('public', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', funcion);
  END LOOP;
END $$;
ALTER DEFAULT PRIVILEGES FOR ROLE ${migrator_role} REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 2. RLS en rol_principal. Solo la leen funciones SECURITY DEFINER, que corren como el migrador.
ALTER TABLE salud_u.rol_principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.rol_principal FORCE ROW LEVEL SECURITY;
CREATE POLICY rol_principal_migrador ON salud_u.rol_principal FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);
REVOKE ALL ON salud_u.rol_principal FROM PUBLIC, ${runtime_role};

-- 3. Códigos de API en inglés para la bandeja. Falla si alguna equivalencia no existe.
DO $$
DECLARE cambiadas integer;
BEGIN
  UPDATE salud_u.equivalencia_codigo_api e SET codigo_api = n.codigo_api
    FROM (VALUES
      ('tipo_evento_notificacion', 'CITA_ASIGNADA', 'APPOINTMENT_ASSIGNED'),
      ('tipo_evento_notificacion', 'CITA_CANCELADA', 'APPOINTMENT_CANCELLED'),
      ('tipo_evento_notificacion', 'AUSENCIA_REGISTRADA', 'APPOINTMENT_NO_SHOW'),
      ('tipo_evento_notificacion', 'CITA_REPROGRAMADA', 'APPOINTMENT_RESCHEDULED'),
      ('tipo_evento_notificacion', 'RECORDATORIO_CITA', 'APPOINTMENT_REMINDER'),
      ('canal_notificacion', 'BANDEJA', 'INBOX'),
      ('estado_notificacion', 'PENDIENTE', 'PENDING'),
      ('estado_notificacion', 'ENTREGADA', 'DELIVERED'),
      ('estado_notificacion', 'LEIDA', 'READ')) AS n(dominio, valor, codigo_api)
   WHERE e.dominio = n.dominio AND e.valor = n.valor;
  GET DIAGNOSTICS cambiadas = ROW_COUNT;
  IF cambiadas <> 9 THEN RAISE EXCEPTION 'EQUIVALENCIAS_NOTIFICACION_INCOMPLETAS: %', cambiadas; END IF;
END $$;

-- 4. Recordatorios vigentes. Solo responde por citas del propio actor, así que no revela el estado de citas ajenas.
CREATE FUNCTION salud_u.recordatorio_vigente(p_id_cita uuid, p_fecha_objetivo date)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
  SELECT EXISTS(SELECT 1 FROM salud_u.cita c JOIN salud_u.paciente p ON p.id = c.id_paciente
    WHERE c.id = p_id_cita AND p.id_principal = salud_u.id_actor_actual() AND c.estado = 'PROGRAMADA'
      AND (c.programada_para AT TIME ZONE 'America/La_Paz')::date = p_fecha_objetivo);
$$;
REVOKE ALL ON FUNCTION salud_u.recordatorio_vigente(uuid,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.recordatorio_vigente(uuid,date) TO ${runtime_role};

CREATE OR REPLACE FUNCTION salud_u.listar_mis_notificaciones(p_limite integer DEFAULT 51,p_antes timestamptz DEFAULT NULL,p_antes_id uuid DEFAULT NULL)
RETURNS TABLE(id uuid,id_cita uuid,tipo_evento text,canal text,asunto text,mensaje text,estado text,
  programada_para timestamptz,entregada_en timestamptz,leida_en timestamptz,creado_en timestamptz)
LANGUAGE plpgsql SECURITY INVOKER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  IF p_limite IS NULL OR p_limite<1 OR p_limite>101 OR (p_antes IS NULL)<>(p_antes_id IS NULL) THEN
    RAISE EXCEPTION 'PAGINACION_NOTIFICACION_INVALIDA' USING ERRCODE='22023';
  END IF;
  RETURN QUERY SELECT n.id,n.id_cita,salud_u.a_codigo_api('tipo_evento_notificacion',n.tipo_evento),
    salud_u.a_codigo_api('canal_notificacion',n.canal),n.asunto,n.mensaje,
    salud_u.a_codigo_api('estado_notificacion',n.estado),n.programada_para,n.entregada_en,n.leida_en,n.creado_en
    FROM salud_u.notificacion n
    WHERE n.id_destinatario=actor AND n.estado IN ('ENTREGADA','LEIDA')
      AND n.programada_para<=now() AND n.entregada_en<=now()
      AND (n.tipo_evento<>'RECORDATORIO_CITA' OR salud_u.recordatorio_vigente(n.id_cita,n.fecha_objetivo))
      AND (p_antes IS NULL OR (n.entregada_en,n.id)<(p_antes,p_antes_id))
    ORDER BY n.entregada_en DESC,n.id DESC LIMIT p_limite;
END;
$$;

CREATE OR REPLACE FUNCTION salud_u.contar_mis_notificaciones_no_leidas()
RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual(); total bigint;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT count(*) INTO total FROM salud_u.notificacion n
    WHERE n.id_destinatario=actor AND n.estado='ENTREGADA' AND n.programada_para<=now() AND n.entregada_en<=now()
      AND (n.tipo_evento<>'RECORDATORIO_CITA' OR salud_u.recordatorio_vigente(n.id_cita,n.fecha_objetivo));
  RETURN total;
END;
$$;

CREATE OR REPLACE FUNCTION salud_u.marcar_mi_notificacion_leida(p_id uuid)
RETURNS TABLE(id uuid,id_cita uuid,tipo_evento text,canal text,asunto text,mensaje text,estado text,
  programada_para timestamptz,entregada_en timestamptz,leida_en timestamptz,creado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual(); aviso salud_u.notificacion%ROWTYPE;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT n.* INTO aviso FROM salud_u.notificacion n
    WHERE n.id=p_id AND n.id_destinatario=actor AND n.estado IN ('ENTREGADA','LEIDA')
      AND n.programada_para<=now() AND n.entregada_en<=now()
      AND (n.tipo_evento<>'RECORDATORIO_CITA' OR salud_u.recordatorio_vigente(n.id_cita,n.fecha_objetivo)) FOR UPDATE;
  -- Ajena, inexistente, aún no entregada o recordatorio sin vigencia producen la misma ausencia de resultado.
  IF NOT FOUND THEN RETURN; END IF;
  IF aviso.estado='ENTREGADA' THEN
    UPDATE salud_u.notificacion n SET estado='LEIDA',leida_en=now() WHERE n.id=aviso.id RETURNING n.* INTO aviso;
    PERFORM salud_u.agregar_evento_auditoria('NOTIFICACION_LEIDA','notificacion',aviso.id,'EXITO','{}'::jsonb);
  END IF;
  RETURN QUERY SELECT aviso.id,aviso.id_cita,salud_u.a_codigo_api('tipo_evento_notificacion',aviso.tipo_evento),
    salud_u.a_codigo_api('canal_notificacion',aviso.canal),aviso.asunto,aviso.mensaje,
    salud_u.a_codigo_api('estado_notificacion',aviso.estado),aviso.programada_para,aviso.entregada_en,aviso.leida_en,aviso.creado_en;
END;
$$;

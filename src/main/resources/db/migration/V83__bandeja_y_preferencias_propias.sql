-- N-02 / PA-20: bandeja y preferencias propias. Las escrituras se autorizan por actor, no por rol.
CREATE INDEX notificacion_destinatario_entregada_en_idx
  ON salud_u.notificacion(id_destinatario,entregada_en DESC,id DESC)
  WHERE estado IN ('ENTREGADA','LEIDA');

CREATE FUNCTION salud_u.listar_mis_notificaciones(p_limite integer DEFAULT 51,p_antes timestamptz DEFAULT NULL,p_antes_id uuid DEFAULT NULL)
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
      AND (p_antes IS NULL OR (n.entregada_en,n.id)<(p_antes,p_antes_id))
    ORDER BY n.entregada_en DESC,n.id DESC LIMIT p_limite;
END;
$$;

CREATE FUNCTION salud_u.contar_mis_notificaciones_no_leidas()
RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual(); total bigint;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT count(*) INTO total FROM salud_u.notificacion n
    WHERE n.id_destinatario=actor AND n.estado='ENTREGADA' AND n.programada_para<=now() AND n.entregada_en<=now();
  RETURN total;
END;
$$;

CREATE FUNCTION salud_u.marcar_mi_notificacion_leida(p_id uuid)
RETURNS TABLE(id uuid,id_cita uuid,tipo_evento text,canal text,asunto text,mensaje text,estado text,
  programada_para timestamptz,entregada_en timestamptz,leida_en timestamptz,creado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual(); aviso salud_u.notificacion%ROWTYPE;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  SELECT n.* INTO aviso FROM salud_u.notificacion n
    WHERE n.id=p_id AND n.id_destinatario=actor AND n.estado IN ('ENTREGADA','LEIDA')
      AND n.programada_para<=now() AND n.entregada_en<=now() FOR UPDATE;
  -- Ajena, inexistente y aún no entregada producen la misma ausencia de resultado.
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

CREATE FUNCTION salud_u.obtener_mis_preferencias_notificacion()
RETURNS TABLE(recibir_recordatorios boolean,recordatorio_reforzado boolean,actualizado_en timestamptz)
LANGUAGE plpgsql SECURITY INVOKER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual();
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  -- GET no escribe filas: sin preferencia persistida rigen los valores por defecto de N-01.
  RETURN QUERY SELECT coalesce(p.recibir_recordatorios,true),coalesce(p.recordatorio_reforzado,true),p.actualizado_en
    FROM (VALUES (actor)) AS cuenta(id_principal)
    LEFT JOIN salud_u.preferencia_notificacion p ON p.id_principal=cuenta.id_principal;
END;
$$;

CREATE FUNCTION salud_u.guardar_mis_preferencias_notificacion(p_recibir_recordatorios boolean,p_recordatorio_reforzado boolean)
RETURNS TABLE(recibir_recordatorios boolean,recordatorio_reforzado boolean,actualizado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE actor uuid:=salud_u.id_actor_actual(); guardada salud_u.preferencia_notificacion%ROWTYPE;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'CONTEXTO_ACTOR_REQUERIDO' USING ERRCODE='42501'; END IF;
  IF p_recibir_recordatorios IS NULL OR p_recordatorio_reforzado IS NULL THEN
    RAISE EXCEPTION 'PREFERENCIAS_NOTIFICACION_INVALIDAS' USING ERRCODE='22023';
  END IF;
  INSERT INTO salud_u.preferencia_notificacion AS p(id_principal,recibir_recordatorios,recordatorio_reforzado)
    VALUES(actor,p_recibir_recordatorios,p_recordatorio_reforzado)
    ON CONFLICT (id_principal) DO UPDATE SET recibir_recordatorios=EXCLUDED.recibir_recordatorios,
      recordatorio_reforzado=EXCLUDED.recordatorio_reforzado,actualizado_en=now()
    RETURNING p.* INTO guardada;
  PERFORM salud_u.agregar_evento_auditoria('PREFERENCIAS_NOTIFICACION_ACTUALIZADAS','preferencia_notificacion',actor,'EXITO',
    jsonb_build_object('recibirRecordatorios',guardada.recibir_recordatorios,'recordatorioReforzado',guardada.recordatorio_reforzado));
  RETURN QUERY SELECT guardada.recibir_recordatorios,guardada.recordatorio_reforzado,guardada.actualizado_en;
END;
$$;

REVOKE ALL ON FUNCTION salud_u.listar_mis_notificaciones(integer,timestamptz,uuid),
  salud_u.contar_mis_notificaciones_no_leidas(),salud_u.marcar_mi_notificacion_leida(uuid),
  salud_u.obtener_mis_preferencias_notificacion(),salud_u.guardar_mis_preferencias_notificacion(boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_mis_notificaciones(integer,timestamptz,uuid),
  salud_u.contar_mis_notificaciones_no_leidas(),salud_u.marcar_mi_notificacion_leida(uuid),
  salud_u.obtener_mis_preferencias_notificacion(),salud_u.guardar_mis_preferencias_notificacion(boolean,boolean) TO ${runtime_role};

-- FE-CORTE: el listado de cupos publicados heredó el límite de 100 de Supabase. Con varios médicos
-- se supera en pocas semanas y Administración deja de ver cupos asignables (sobre todo de especialidad,
-- que quedaban detrás de los de revisión). Devuelve todos los cupos futuros publicados.
CREATE OR REPLACE FUNCTION salud_u.listar_disponibilidad_publicada(p_initial_only boolean DEFAULT false, p_my_personal_only boolean DEFAULT false)
RETURNS TABLE(id uuid, id_especialidad uuid, inicia_a timestamptz, termina_a timestamptz, capacidad integer, cantidad_reservada integer, estado text, nombre_medico text) LANGUAGE plpgsql SECURITY DEFINER SET search_path = salud_u, pg_temp AS $$
DECLARE own_personal_id uuid;
BEGIN
  IF NOT (salud_u.tiene_rol_actor('ADMINISTRATIVE') OR salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'No autorizado para consultar cupos' USING ERRCODE = '42501'; END IF;
  IF p_my_personal_only THEN own_personal_id := salud_u.id_mi_personal_activo(); END IF;
  RETURN QUERY SELECT s.id,s.id_especialidad,s.inicia_a,s.termina_a,s.capacidad,s.cantidad_reservada,s.estado,p.nombre_mostrado FROM salud_u.cupo_disponibilidad s JOIN salud_u.personal sm ON sm.id=s.id_personal JOIN salud_u.principal p ON p.id=sm.id_principal WHERE s.estado='PUBLISHED' AND s.inicia_a>now() AND (NOT p_initial_only OR s.id_especialidad IS NULL) AND (own_personal_id IS NULL OR s.id_personal=own_personal_id) ORDER BY s.inicia_a, s.id;
END;
$$;

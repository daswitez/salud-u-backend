-- FE-CORTE: con más de 200 citas el listado devolvía las 200 más antiguas, ocultando las de hoy
-- y las próximas. Ahora devuelve todas las activas (programadas, con llegada o con borrador)
-- más las 200 finalizadas más recientes; y permite pedir una cita concreta del profesional.
DROP FUNCTION salud_u.listar_mis_citas_medicas();
CREATE FUNCTION salud_u.listar_mis_citas_medicas(p_id uuid DEFAULT NULL)
RETURNS TABLE(
  id uuid,tipo_cita text,estado_cita text,programada_para timestamptz,inicia_a timestamptz,termina_a timestamptz,
  nombre_especialidad text,id_paciente uuid,carnet text,nombres text,apellidos text,
  codigo_registro text,fecha_nacimiento date,telefono text,email text,codigo_especialidad text,
  ingreso_registrado_en timestamptz,id_encuentro uuid,estado_encuentro text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal_actual uuid:=salud_u.id_mi_personal_activo();
BEGIN
  IF NOT(salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN
    RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    WITH propias AS (
      SELECT c.id,c.tipo_cita,c.estado,c.programada_para,cupo.inicia_a,cupo.termina_a,esp.nombre,
        p.id AS id_paciente,p.carnet,p.nombres,p.apellidos,p.codigo_registro,p.fecha_nacimiento,p.telefono,p.email,
        esp.codigo,c.ingreso_registrado_en,e.id AS id_encuentro,e.estado AS estado_encuentro,
        (c.estado IN ('SCHEDULED','CHECKED_IN') OR e.estado IS NOT DISTINCT FROM 'DRAFT') AS activa
      FROM salud_u.cita c
      JOIN salud_u.paciente p ON p.id=c.id_paciente
      JOIN salud_u.cupo_disponibilidad cupo ON cupo.id=c.id_cupo
      LEFT JOIN salud_u.especialidad esp ON esp.id=cupo.id_especialidad
      LEFT JOIN salud_u.encuentro_clinico e ON e.id_cita=c.id
      WHERE c.id_personal_asignado=personal_actual
        AND (p_id IS NULL OR c.id=p_id)
        AND ((salud_u.tiene_rol_actor('REVIEW_DOCTOR') AND c.tipo_cita='INITIAL')
          OR (salud_u.tiene_rol_actor('SPECIALIST') AND c.tipo_cita='SPECIALTY'))
    ), visibles AS (
      SELECT * FROM propias WHERE activa OR p_id IS NOT NULL
      UNION ALL
      (SELECT * FROM propias WHERE NOT activa AND p_id IS NULL ORDER BY programada_para DESC,id DESC LIMIT 200)
    )
    SELECT v.id,v.tipo_cita,v.estado,v.programada_para,v.inicia_a,v.termina_a,v.nombre,v.id_paciente,v.carnet,v.nombres,v.apellidos,
      v.codigo_registro,v.fecha_nacimiento,v.telefono,v.email,v.codigo,v.ingreso_registrado_en,v.id_encuentro,v.estado_encuentro
    FROM visibles v ORDER BY v.programada_para ASC,v.id ASC;
END $$;
REVOKE ALL ON FUNCTION salud_u.listar_mis_citas_medicas(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_mis_citas_medicas(uuid) TO ${runtime_role};

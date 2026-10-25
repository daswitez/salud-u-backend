CREATE FUNCTION salud_u.listar_documentos_encuentro_propio(p_encuentro uuid)
RETURNS TABLE(id uuid,tipo_documento text,nombre_original text,tipo_mime text,tamano_bytes bigint,fecha_estudio date,descripcion text,cargado_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro AND e.id_personal=personal
    AND ((e.tipo_encuentro='INITIAL' AND salud_u.tiene_rol_actor('REVIEW_DOCTOR')) OR
         (e.tipo_encuentro='SPECIALTY' AND salud_u.tiene_rol_actor('SPECIALIST')))) THEN
    RAISE EXCEPTION 'ENCUENTRO_AJENO_O_INEXISTENTE' USING ERRCODE='P0002';
  END IF;
  RETURN QUERY SELECT d.id,d.tipo_documento,d.nombre_original,d.tipo_mime,d.tamano_bytes,d.fecha_estudio,d.descripcion,d.cargado_en
    FROM salud_u.documento_clinico d WHERE d.id_encuentro=p_encuentro AND d.estado='AVAILABLE' ORDER BY d.cargado_en DESC,d.id DESC;
END $$;
REVOKE ALL ON FUNCTION salud_u.listar_documentos_encuentro_propio(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.listar_documentos_encuentro_propio(uuid) TO ${runtime_role};

-- Serializar carga y cierre para que un documento no se incorpore después del cierre.
CREATE OR REPLACE FUNCTION salud_u.preparar_carga_documento(p_paciente uuid, p_encuentro uuid, p_tipo text, p_nombre text, p_mime text, p_fecha date, p_descripcion text)
RETURNS TABLE(id_documento uuid, ruta_objeto text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); documento uuid:=gen_random_uuid(); ruta text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 IF p_tipo NOT IN ('BLOOD_CHEMISTRY','LAB_RESULT','RADIOGRAPH','PRESCRIPTION','CLINICAL_PHOTO','REFERRAL_DOCUMENT','OTHER') OR p_mime NOT IN ('application/pdf','image/jpeg','image/png','image/webp') OR length(btrim(coalesce(p_nombre,'')))=0 THEN RAISE EXCEPTION 'DOCUMENTO_INVALIDO' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro AND e.id_paciente=p_paciente AND e.id_personal=personal AND e.estado='DRAFT' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_CERRADO' USING ERRCODE='42501'; END IF;
 ruta:=format('paciente/%s/%s/%s',p_paciente,to_char(current_date,'YYYY'),documento);
 INSERT INTO salud_u.documento_clinico(id,id_paciente,id_encuentro,tipo_documento,ruta_objeto,nombre_original,tipo_mime,fecha_estudio,descripcion,cargado_por) VALUES(documento,p_paciente,p_encuentro,p_tipo,ruta,left(btrim(p_nombre),255),p_mime,p_fecha,nullif(btrim(coalesce(p_descripcion,'')),''),salud_u.id_actor_actual());
 RETURN QUERY SELECT documento,ruta;
END $$;

CREATE TABLE salud_u.documento_clinico (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), id_paciente uuid NOT NULL REFERENCES salud_u.paciente(id),
  id_encuentro uuid NOT NULL REFERENCES salud_u.encuentro_clinico(id), tipo_documento text NOT NULL,
  estado text NOT NULL DEFAULT 'PROCESSING' CHECK (estado IN ('PROCESSING','AVAILABLE','REJECTED')),
  ruta_objeto text NOT NULL UNIQUE, nombre_original text NOT NULL, tipo_mime text NOT NULL,
  tamano_bytes bigint NULL CHECK (tamano_bytes > 0), checksum_sha256 text NULL, fecha_estudio date NULL,
  descripcion text NULL, cargado_por uuid NOT NULL REFERENCES salud_u.principal(id), cargado_en timestamptz NOT NULL DEFAULT now(), disponible_en timestamptz NULL,
  CHECK (tipo_mime IN ('application/pdf','image/jpeg','image/png','image/webp')),
  CHECK ((estado = 'AVAILABLE') = (disponible_en IS NOT NULL))
);
ALTER TABLE salud_u.documento_clinico ENABLE ROW LEVEL SECURITY;
ALTER TABLE salud_u.documento_clinico FORCE ROW LEVEL SECURITY;
CREATE POLICY documento_clinico_migrador ON salud_u.documento_clinico FOR ALL TO ${migrator_role} USING (true) WITH CHECK (true);

CREATE FUNCTION salud_u.preparar_carga_documento(p_paciente uuid, p_encuentro uuid, p_tipo text, p_nombre text, p_mime text, p_fecha date, p_descripcion text)
RETURNS TABLE(id_documento uuid, ruta_objeto text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE personal uuid:=salud_u.id_mi_personal_activo(); documento uuid:=gen_random_uuid(); ruta text;
BEGIN
 IF NOT(salud_u.tiene_rol_actor('REVIEW_DOCTOR') OR salud_u.tiene_rol_actor('SPECIALIST')) THEN RAISE EXCEPTION 'MEDICO_NO_AUTORIZADO' USING ERRCODE='42501'; END IF;
 IF p_tipo NOT IN ('BLOOD_CHEMISTRY','LAB_RESULT','RADIOGRAPH','PRESCRIPTION','CLINICAL_PHOTO','REFERRAL_DOCUMENT','OTHER') OR p_mime NOT IN ('application/pdf','image/jpeg','image/png','image/webp') OR length(btrim(coalesce(p_nombre,'')))=0 THEN RAISE EXCEPTION 'DOCUMENTO_INVALIDO' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT 1 FROM salud_u.encuentro_clinico e WHERE e.id=p_encuentro AND e.id_paciente=p_paciente AND e.id_personal=personal AND e.estado='DRAFT') THEN RAISE EXCEPTION 'ENCUENTRO_AJENO_O_CERRADO' USING ERRCODE='42501'; END IF;
 ruta:=format('paciente/%s/%s/%s',p_paciente,to_char(current_date,'YYYY'),documento);
 INSERT INTO salud_u.documento_clinico(id,id_paciente,id_encuentro,tipo_documento,ruta_objeto,nombre_original,tipo_mime,fecha_estudio,descripcion,cargado_por) VALUES(documento,p_paciente,p_encuentro,p_tipo,ruta,left(btrim(p_nombre),255),p_mime,p_fecha,nullif(btrim(coalesce(p_descripcion,'')),''),salud_u.id_actor_actual());
 RETURN QUERY SELECT documento,ruta;
END $$;
CREATE FUNCTION salud_u.finalizar_carga_documento(p_id uuid,p_tamano bigint,p_checksum text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
 IF p_tamano IS NULL OR p_tamano<1 OR p_tamano>15728640 OR p_checksum !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'ARCHIVO_INVALIDO' USING ERRCODE='22023'; END IF;
 UPDATE salud_u.documento_clinico SET estado='AVAILABLE',tamano_bytes=p_tamano,checksum_sha256=p_checksum,disponible_en=now() WHERE id=p_id AND estado='PROCESSING' AND cargado_por=salud_u.id_actor_actual();
 IF NOT FOUND THEN RAISE EXCEPTION 'DOCUMENTO_NO_DISPONIBLE' USING ERRCODE='42501'; END IF;
END $$;
REVOKE ALL ON TABLE salud_u.documento_clinico FROM ${runtime_role};
GRANT EXECUTE ON FUNCTION salud_u.preparar_carga_documento(uuid,uuid,text,text,text,date,text),salud_u.finalizar_carga_documento(uuid,bigint,text) TO ${runtime_role};

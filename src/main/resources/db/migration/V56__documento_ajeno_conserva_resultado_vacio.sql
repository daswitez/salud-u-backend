-- Conservar semántica de lectura SQL: documento no autorizado produce cero filas. HTTP sigue siendo 404.
CREATE OR REPLACE FUNCTION salud_u.obtener_documento_autorizado(p_id uuid)
RETURNS TABLE(ruta_objeto text,tipo_mime text,nombre_original text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
DECLARE paciente uuid; ids uuid[];
BEGIN
 SELECT d.id_paciente INTO paciente FROM salud_u.documento_clinico d WHERE d.id=p_id AND d.estado='AVAILABLE';
 IF paciente IS NULL THEN RETURN; END IF;
 ids:=salud_u.ids_historia_autorizada(paciente);
 RETURN QUERY SELECT d.ruta_objeto,d.tipo_mime,d.nombre_original FROM salud_u.documento_clinico d WHERE d.id=p_id AND d.id_encuentro=ANY(ids) AND d.estado='AVAILABLE';
EXCEPTION WHEN SQLSTATE 'P0002' THEN RETURN;
END $$;


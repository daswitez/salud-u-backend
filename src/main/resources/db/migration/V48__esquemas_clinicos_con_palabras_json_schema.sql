-- Las palabras reservadas de JSON Schema (items, properties, required...) no son datos clínicos.
-- Traducir nombres/opciones de campos sin invalidar el estándar de sus plantillas.
CREATE FUNCTION salud_u.traducir_esquema_clinico(p_esquema jsonb,p_campo text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=salud_u,pg_temp AS $$
DECLARE resultado jsonb:='{}'::jsonb; entrada record; propiedad record; propiedades jsonb; requerido jsonb;
  clave text; campo text;
BEGIN
  IF jsonb_typeof(p_esquema)='array' THEN
    RETURN (SELECT coalesce(jsonb_agg(salud_u.traducir_esquema_clinico(value,p_campo) ORDER BY orden),'[]'::jsonb)
      FROM jsonb_array_elements(p_esquema) WITH ORDINALITY AS lista(value,orden));
  ELSIF jsonb_typeof(p_esquema) IS DISTINCT FROM 'object' THEN RETURN p_esquema; END IF;
  FOR entrada IN SELECT key,value FROM jsonb_each(p_esquema) LOOP
    IF entrada.key='properties' AND jsonb_typeof(entrada.value)='object' THEN
      propiedades:='{}'::jsonb;
      FOR propiedad IN SELECT key,value FROM jsonb_each(entrada.value) LOOP
        SELECT jsonb_object_keys(salud_u.traducir_json_clinico(jsonb_build_object(propiedad.key,null))) INTO clave;
        propiedades:=propiedades||jsonb_build_object(clave,salud_u.traducir_esquema_clinico(propiedad.value,propiedad.key));
      END LOOP;
      resultado:=resultado||jsonb_build_object('properties',propiedades);
    ELSIF entrada.key='required' AND jsonb_typeof(entrada.value)='array' THEN
      requerido:='[]'::jsonb;
      FOR propiedad IN SELECT value FROM jsonb_array_elements(entrada.value) LOOP
        SELECT jsonb_object_keys(salud_u.traducir_json_clinico(jsonb_build_object(propiedad.value#>>'{}',null))) INTO clave;
        requerido:=requerido||jsonb_build_array(clave);
      END LOOP;
      resultado:=resultado||jsonb_build_object('required',requerido);
    ELSIF entrada.key IN('enum','const','default') AND p_campo<>'' THEN
      SELECT jsonb_object_keys(salud_u.traducir_json_clinico(jsonb_build_object(p_campo,null))) INTO campo;
      resultado:=resultado||jsonb_build_object(entrada.key,salud_u.traducir_json_clinico(jsonb_build_object(p_campo,entrada.value))->campo);
    ELSIF entrada.key IN('items','allOf','anyOf','oneOf','not','if','then','else','additionalProperties') THEN
      resultado:=resultado||jsonb_build_object(entrada.key,salud_u.traducir_esquema_clinico(entrada.value,p_campo));
    ELSE resultado:=resultado||jsonb_build_object(entrada.key,entrada.value);
    END IF;
  END LOOP;
  RETURN resultado;
END $$;
REVOKE ALL ON FUNCTION salud_u.traducir_esquema_clinico(jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION salud_u.traducir_esquema_clinico(jsonb,text) TO ${runtime_role};

DROP TRIGGER canonizar_plantilla ON salud_u.plantilla_ficha_especialidad;
UPDATE salud_u.plantilla_ficha_especialidad
  SET esquema=salud_u.traducir_esquema_clinico(salud_u.traducir_json_clinico(esquema,true));
CREATE OR REPLACE FUNCTION salud_u.canonizar_json_clinico() RETURNS trigger
LANGUAGE plpgsql SET search_path=salud_u,pg_temp AS $$
BEGIN
  IF TG_TABLE_NAME='plantilla_ficha_especialidad' THEN
    NEW.esquema:=salud_u.traducir_esquema_clinico(NEW.esquema);
  ELSE NEW.datos:=salud_u.traducir_json_clinico(NEW.datos);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER canonizar_plantilla BEFORE INSERT OR UPDATE OF esquema ON salud_u.plantilla_ficha_especialidad
FOR EACH ROW EXECUTE FUNCTION salud_u.canonizar_json_clinico();

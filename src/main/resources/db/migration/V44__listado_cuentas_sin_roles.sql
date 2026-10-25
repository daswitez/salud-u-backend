-- Mantener la firma SQL existente; excluir la fila NULL del LEFT JOIN
-- permite representar cuentas sin roles como [] en lugar de [null].
CREATE OR REPLACE FUNCTION salud_u.listar_principales_administracion()
RETURNS TABLE(id uuid,email text,nombre_mostrado text,activo boolean,rols text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=salud_u,pg_temp AS $$
BEGIN
  PERFORM salud_u.requerir_administrativo();
  RETURN QUERY
    SELECT p.id,p.email,p.nombre_mostrado,p.activo,
      COALESCE(array_agg(r.codigo_rol::text ORDER BY r.codigo_rol)
        FILTER(WHERE r.codigo_rol IS NOT NULL AND r.revocado_en IS NULL),ARRAY[]::text[])
    FROM salud_u.principal p LEFT JOIN salud_u.rol_principal r ON r.id_principal=p.id
    GROUP BY p.id,p.email,p.nombre_mostrado,p.activo
    ORDER BY p.nombre_mostrado,p.email;
END $$;

package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.images.builder.ImageFromDockerfile;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

/**
 * Red de seguridad de la épica ES (base de datos en español).
 *
 * <p>Aplica todas las migraciones sobre la imagen de desarrollo con plpgsql_check y verifica: que ninguna
 * función PL/pgSQL haga referencia a columnas, tablas o tipos inexistentes; que el inventario de nombres y
 * valores en inglés coincida exactamente con la línea base; y que el diccionario de códigos entre la base y
 * la API (ES-01) sea reversible y cubra todo valor que la base permite. Cada migración de traducción debe
 * achicar la línea base; ES-10 la deja vacía. Para regenerarla después de una traducción:
 * {@code mvn -Dtest=EsquemaEspanolIntegrationTest -Dinventario.actualizar=true test}.
 */
@Testcontainers(disabledWithoutDocker = true)
class EsquemaEspanolIntegrationTest {
    private static final Path LINEA_BASE = Path.of("src/test/resources/inventario/linea-base-ingles.txt");
    private static final Path REPORTE = Path.of("target/inventario-ingles.txt");

    /** Columnas de la base que guardan códigos, con su dominio del diccionario. Una columna de códigos nueva se agrega aquí. */
    private static final Map<String, String> DOMINIO_POR_COLUMNA = Map.ofEntries(
        Map.entry("rol_principal.codigo_rol", "rol"),
        Map.entry("paciente.estado_academico", "estado_academico"),
        Map.entry("inscripcion_academica.estado", "estado_inscripcion"),
        Map.entry("cupo_disponibilidad.estado", "estado_cupo"),
        Map.entry("solicitud_cita.estado", "estado_solicitud"),
        Map.entry("solicitud_cita.tipo_cita", "tipo_cita"),
        Map.entry("solicitud_cita.origen", "origen_solicitud"),
        Map.entry("cita.estado", "estado_cita"),
        Map.entry("cita.tipo_cita", "tipo_cita"),
        Map.entry("evento_estado_cita.estado_anterior", "estado_cita"),
        Map.entry("evento_estado_cita.estado_nuevo", "estado_cita"),
        Map.entry("encuentro_clinico.estado", "estado_encuentro"),
        Map.entry("encuentro_clinico.tipo_encuentro", "tipo_encuentro"),
        Map.entry("encuentro_clinico.estado_quimica_sanguinea", "estado_quimica"),
        Map.entry("version_antecedente_clinico.estado_verificacion", "estado_verificacion"),
        Map.entry("derivacion.estado", "estado_derivacion"),
        Map.entry("derivacion.prioridad", "prioridad_derivacion"),
        Map.entry("evento_estado_derivacion.estado_anterior", "estado_derivacion"),
        Map.entry("evento_estado_derivacion.estado_nuevo", "estado_derivacion"),
        Map.entry("documento_clinico.estado", "estado_documento"),
        Map.entry("documento_clinico.tipo_documento", "tipo_documento"),
        Map.entry("exportacion_reporte_clinico.estado", "estado_exportacion"),
        Map.entry("evento_auditoria.resultado", "resultado_auditoria"),
        Map.entry("notificacion.tipo_evento", "tipo_evento_notificacion"),
        Map.entry("notificacion.canal", "canal_notificacion"),
        Map.entry("notificacion.estado", "estado_notificacion"));

    /** Dominios que solo existen en el contrato HTTP (parámetros o valores calculados), sin columna propia. */
    private static final Set<String> DOMINIOS_SOLO_API = Set.of(
        "acceso_historia", "accion_derivacion", "tipo_catalogo", "estado_cumplimiento", "estado_esquema_vacunacion", "rango_edad", "tipo_diagnostico", "dato_ausente");

    private static PostgreSQLContainer<?> postgres;
    private static JdbcTemplate migratorJdbc;
    private static JdbcTemplate runtimeJdbc;

    @BeforeAll
    static void setUp() throws Exception {
        String imagen = new ImageFromDockerfile("salud-u/postgres-dev:17", false)
            .withDockerfile(Path.of("docker/postgres-dev/Dockerfile"))
            .get();
        postgres = new PostgreSQLContainer<>(DockerImageName.parse(imagen).asCompatibleSubstituteFor("postgres"))
            .withDatabaseName("salud_u")
            .withUsername("salud_u_migrator")
            .withPassword("migrator-test-password")
            .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
        postgres.start();
        migratorJdbc = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migratorJdbc.execute("CREATE ROLE salud_u_runtime LOGIN PASSWORD 'runtime-test-password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS");
        Flyway.configure()
            .dataSource(postgres.getJdbcUrl(), "salud_u_migrator", "migrator-test-password")
            .schemas("salud_u")
            .defaultSchema("salud_u")
            .createSchemas(true)
            .placeholders(Map.of("runtime_role", "salud_u_runtime", "migrator_role", "salud_u_migrator"))
            .load()
            .migrate();
        migratorJdbc.execute("CREATE EXTENSION plpgsql_check SCHEMA public");
        runtimeJdbc = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), "salud_u_runtime", "runtime-test-password"));
    }

    @AfterAll
    static void tearDown() {
        if (postgres != null) {
            CoberturaFuncionesSql.registrar(postgres.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "EsquemaEspanolIntegrationTest");
            postgres.stop();
        }
    }

    @Test
    void ningunaFuncionPlpgsqlReferenciaObjetosInexistentes() {
        var errores = migratorJdbc.query(sql("plpgsql-check.sql"),
            (rs, i) -> rs.getString("funcion") + " línea " + rs.getInt("linea") + ": " + rs.getString("mensaje"));
        assertTrue(errores.isEmpty(), "plpgsql_check encontró errores:\n" + String.join("\n", errores));
    }

    @Test
    void inventarioEnInglesCoincideConLaLineaBase() throws IOException {
        var actual = new TreeSet<>(migratorJdbc.query(sql("inventario-ingles.sql"),
            (rs, i) -> rs.getString("categoria") + "|" + rs.getString("elemento")));
        Files.createDirectories(REPORTE.getParent());
        Files.write(REPORTE, actual, StandardCharsets.UTF_8);
        if (Boolean.getBoolean("inventario.actualizar")) {
            Files.write(LINEA_BASE, actual, StandardCharsets.UTF_8);
            return;
        }
        var base = new TreeSet<>(Files.readAllLines(LINEA_BASE, StandardCharsets.UTF_8));
        base.removeIf(String::isBlank);
        var nuevos = new ArrayList<>(actual);
        nuevos.removeAll(base);
        var resueltos = new ArrayList<>(base);
        resueltos.removeAll(actual);
        List<String> problemas = new ArrayList<>();
        if (!nuevos.isEmpty()) {
            problemas.add("Nombres o valores nuevos en inglés (la base debe quedar en español):\n  " + String.join("\n  ", nuevos));
        }
        if (!resueltos.isEmpty()) {
            problemas.add("Elementos ya traducidos que siguen en la línea base; regenérala con -Dinventario.actualizar=true:\n  "
                + String.join("\n  ", resueltos));
        }
        if (!problemas.isEmpty()) {
            fail(String.join("\n\n", problemas));
        }
    }

    @Test
    void diccionarioEsReversibleEnCadaDominioParaElRolDeLaAplicacion() {
        var filas = migratorJdbc.queryForList("select dominio, valor, codigo_api from salud_u.equivalencia_codigo_api order by 1, 2");
        var dominios = new TreeSet<String>();
        for (var fila : filas) {
            String dominio = (String) fila.get("dominio"), valor = (String) fila.get("valor"), codigo = (String) fila.get("codigo_api");
            dominios.add(dominio);
            assertEquals(codigo, runtimeJdbc.queryForObject("select salud_u.a_codigo_api(?, ?)", String.class, dominio, valor), dominio + "." + valor);
            assertEquals(valor, runtimeJdbc.queryForObject("select salud_u.desde_codigo_api(?, ?)", String.class, dominio, codigo), dominio + "." + codigo);
        }
        var esperados = new TreeSet<>(DOMINIO_POR_COLUMNA.values());
        esperados.addAll(DOMINIOS_SOLO_API);
        assertEquals(esperados, dominios, "Cada dominio del diccionario debe tener una columna o estar en DOMINIOS_SOLO_API");
    }

    @Test
    void diccionarioRechazaCodigosDesconocidosDejaPasarNullYNoSeLeeDirecto() {
        for (String funcion : List.of("a_codigo_api", "desde_codigo_api")) {
            var error = assertThrows(DataAccessException.class,
                () -> runtimeJdbc.queryForObject("select salud_u." + funcion + "('estado_cita', 'NO_EXISTE')", String.class));
            assertTrue(String.valueOf(error.getMostSpecificCause().getMessage()).contains("CODIGO_DOMINIO_DESCONOCIDO"), funcion);
            assertThrows(DataAccessException.class,
                () -> runtimeJdbc.queryForObject("select salud_u." + funcion + "('dominio_inexistente', 'SCHEDULED')", String.class));
            assertNull(runtimeJdbc.queryForObject("select salud_u." + funcion + "('estado_cita', null)", String.class), funcion);
        }
        assertThrows(DataAccessException.class, () -> runtimeJdbc.queryForList("select * from salud_u.equivalencia_codigo_api"));
    }

    /**
     * Todo valor que hoy permite un CHECK o un enum de una columna de códigos debe estar en su dominio, como valor
     * en español o como código de API. Vale antes y después de traducir cada tabla: si una migración agrega un
     * valor a la base sin agregarlo al diccionario, esta prueba falla.
     */
    @Test
    void diccionarioCubreTodosLosValoresPermitidosPorLaBase() {
        var faltantes = new TreeMap<String, List<String>>();
        DOMINIO_POR_COLUMNA.forEach((columna, dominio) -> {
            String tabla = columna.substring(0, columna.indexOf('.')), atributo = columna.substring(columna.indexOf('.') + 1);
            assertEquals(1, migratorJdbc.queryForObject("""
                select count(*) from pg_attribute a join pg_class c on c.oid = a.attrelid
                where c.relnamespace = 'salud_u'::regnamespace and c.relname = ? and a.attname = ? and not a.attisdropped
                """, Integer.class, tabla, atributo), "No existe la columna " + columna + "; actualiza DOMINIO_POR_COLUMNA");
            var permitidos = migratorJdbc.queryForList("""
                select distinct m[1] from pg_constraint k
                join pg_class c on c.oid = k.conrelid
                join pg_attribute a on a.attrelid = c.oid and a.attnum = any(k.conkey)
                cross join lateral regexp_matches(pg_get_constraintdef(k.oid), '''([A-Z0-9][A-Z0-9_]*)''', 'g') m
                where c.relnamespace = 'salud_u'::regnamespace and k.contype = 'c' and c.relname = ? and a.attname = ?
                union
                select e.enumlabel::text from pg_attribute a
                join pg_class c on c.oid = a.attrelid
                join pg_enum e on e.enumtypid = a.atttypid
                where c.relnamespace = 'salud_u'::regnamespace and c.relname = ? and a.attname = ?
                """, String.class, tabla, atributo, tabla, atributo);
            var conocidos = Set.copyOf(migratorJdbc.queryForList(
                "select valor from salud_u.equivalencia_codigo_api where dominio = ? union select codigo_api from salud_u.equivalencia_codigo_api where dominio = ?",
                String.class, dominio, dominio));
            var sinDominio = permitidos.stream().filter(valor -> !conocidos.contains(valor)).sorted().toList();
            if (!sinDominio.isEmpty()) faltantes.put(columna + " (" + dominio + ")", sinDominio);
        });
        assertTrue(faltantes.isEmpty(), "Valores permitidos por la base que no están en el diccionario: " + faltantes);
    }

    /**
     * ES-02: el contexto del actor guarda los roles en español (DatabaseActorContext los traduce al fijarlo).
     * ES-10: tiene_rol_actor solo acepta el enum español; un rol inexistente o de API se rechaza.
     */
    @Test
    void tieneRolActorSoloAceptaEnumEspanolYRechazaElPuenteAnterior() {
        var conexion = new SingleConnectionDataSource(postgres.getJdbcUrl(), "salud_u_runtime", "runtime-test-password", true);
        try {
            var jdbc = new JdbcTemplate(conexion);
            jdbc.queryForObject("select set_config('salud_u.roles_actor', 'ESTUDIANTE,MEDICO_REVISION', false)", String.class);
            for (String rol : List.of("MEDICO_REVISION", "ESTUDIANTE")) {
                assertTrue(jdbc.queryForObject("select salud_u.tiene_rol_actor(cast(? as salud_u.codigo_rol_aplicacion))", Boolean.class, rol), rol);
            }
            for (String rol : List.of("ADMINISTRATIVO", "AUDITOR")) {
                assertEquals(false, jdbc.queryForObject("select salud_u.tiene_rol_actor(cast(? as salud_u.codigo_rol_aplicacion))", Boolean.class, rol), rol);
            }
            assertThrows(DataAccessException.class, () -> jdbc.queryForObject("select salud_u.tiene_rol_actor('NO_EXISTE')", Boolean.class));
            for (String anterior : List.of("ADMINISTRATIVE", "REVIEW_DOCTOR", "SPECIALIST", "STUDENT", "REPORTING_OFFICER")) {
                assertThrows(DataAccessException.class, () -> jdbc.queryForObject("select salud_u.tiene_rol_actor(cast(? as salud_u.codigo_rol_aplicacion))", Boolean.class, anterior));
            }
            assertNull(jdbc.queryForObject("select to_regprocedure('salud_u.tiene_rol_actor(text)')::text", String.class));
        } finally {
            conexion.destroy();
        }
        assertEquals(List.of("ADMINISTRATIVO", "MEDICO_REVISION", "ESPECIALISTA", "ESTUDIANTE", "AUDITOR", "RESPONSABLE_REPORTES"),
            migratorJdbc.queryForList("select unnest(enum_range(null::salud_u.codigo_rol_aplicacion))::text", String.class));
    }

    @Test
    void cierreNoAdmiteInglesNiAmpliaLosPermisosDeFuncionesInternas() {
        assertTrue(migratorJdbc.queryForList(sql("inventario-ingles.sql")).isEmpty(), "ES-10 requiere inventario cero");
        for (String firma : List.of("identificar_paciente(text)", "cupo_esta_bloqueado(uuid,timestamptz,timestamptz)", "generar_cupos_disponibilidad(uuid,date,date)", "elementos_antecedente_reporte(jsonb,text)")) {
            assertEquals(false, runtimeJdbc.queryForObject("select has_function_privilege(current_user,?,'EXECUTE')", Boolean.class, "salud_u." + firma), firma);
        }
    }

    @Test
    void ningunaFuncionQuedaAbiertaAPublicYTodasLasTablasTienenRlsForzada() {
        assertEquals(List.of(), migratorJdbc.queryForList("""
            select p.oid::regprocedure::text from pg_proc p
             where p.pronamespace = 'salud_u'::regnamespace and has_function_privilege('public', p.oid, 'EXECUTE') order by 1
            """, String.class));
        assertEquals(List.of(), migratorJdbc.queryForList("""
            select c.relname::text from pg_class c
             where c.relnamespace = 'salud_u'::regnamespace and c.relkind in ('r', 'p') and c.relname <> 'flyway_schema_history'
               and not (c.relrowsecurity and c.relforcerowsecurity) order by 1
            """, String.class));
        // El privilegio por defecto del migrador hace que las funciones nuevas también nazcan cerradas.
        migratorJdbc.execute("create function salud_u.prueba_privilegio_por_defecto() returns integer language sql as 'select 1'");
        try {
            assertEquals(false, migratorJdbc.queryForObject(
                "select has_function_privilege('public', 'salud_u.prueba_privilegio_por_defecto()', 'EXECUTE')", Boolean.class));
        } finally {
            migratorJdbc.execute("drop function salud_u.prueba_privilegio_por_defecto()");
        }
    }

    private static String sql(String nombre) {
        try (var in = EsquemaEspanolIntegrationTest.class.getResourceAsStream("/inventario/" + nombre)) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}

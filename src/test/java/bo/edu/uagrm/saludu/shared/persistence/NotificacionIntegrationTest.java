package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

@Testcontainers(disabledWithoutDocker = true)
class NotificacionIntegrationTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
    private static final UUID ADMIN = UUID.randomUUID(), DOCTOR = UUID.randomUUID(), PERSONAL = UUID.randomUUID();
    private static final AtomicInteger HORARIO = new AtomicInteger();
    private static final List<String> PROTEGIDAS = List.of("asignar_solicitud_cita(uuid,uuid)",
        "registrar_llegada_cita(uuid)", "registrar_ausencia_cita(uuid,text)", "cancelar_solicitud_cita(uuid,text)");
    private static JdbcTemplate migrador, runtime;
    private static TransactionTemplate transaccion;
    private static DatabaseActorContext contexto;
    private static Map<String, String> definicionesAnteriores;
    private static UUID citaAnterior;

    @BeforeAll
    static void preparar() {
        POSTGRES.start();
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.execute("CREATE ROLE salud_u_runtime LOGIN PASSWORD 'runtime-test-password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS");
        configuracion().target("81").load().migrate();
        var fuente = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_runtime", "runtime-test-password");
        runtime = new JdbcTemplate(fuente);
        contexto = new DatabaseActorContext(runtime);
        transaccion = new TransactionTemplate(new DataSourceTransactionManager(fuente));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,'admin-n01@example.invalid','Administración N01'),(?,'medico-n01@example.invalid','Médico N01')", ADMIN, DOCTOR);
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'ADMINISTRATIVO'),(?,'MEDICO_REVISION')", ADMIN, DOCTOR);
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'MEDICO-N01')", PERSONAL, DOCTOR);
        citaAnterior = asignar(caso(true));
        definicionesAnteriores = definiciones();
        configuracion().load().migrate();
    }

    private static org.flywaydb.core.api.configuration.FluentConfiguration configuracion() {
        return Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password")
            .schemas("salud_u").defaultSchema("salud_u").createSchemas(true)
            .placeholders(Map.of("runtime_role", "salud_u_runtime", "migrator_role", "salud_u_migrator"));
    }

    @AfterAll
    static void cerrar() {
        if (POSTGRES.isRunning()) {
            CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "NotificacionIntegrationTest");
            POSTGRES.stop();
        }
    }

    @Test
    void migracionNoReescribeAgendaNiGeneraAvisosRetroactivos() {
        assertEquals(definicionesAnteriores, definiciones());
        assertEquals(0, contar("select count(*) from salud_u.notificacion where id_cita=?", citaAnterior));
        assertEquals("PROGRAMADA", migrador.queryForObject("select estado from salud_u.cita where id=?", String.class, citaAnterior));
        assertEquals(2, contar("select count(*) from pg_class where relnamespace='salud_u'::regnamespace and relname in ('notificacion','preferencia_notificacion') and relrowsecurity and relforcerowsecurity"));
    }

    @Test
    void asignacionCreaUnSoloAvisoInclusoConReintentosConcurrentesYRespetaRls() throws Exception {
        Caso caso = caso(true), ajeno = caso(true);
        UUID cita = asignar(caso);
        var aviso = aviso(cita, "CITA_ASIGNADA");
        assertEquals(caso.estudiante(), aviso.get("id_destinatario"));
        assertEquals("BANDEJA", aviso.get("canal"));
        assertEquals("ENTREGADA", aviso.get("estado"));
        assertNotNull(aviso.get("entregada_en"));
        assertNull(aviso.get("leida_en"));
        assertTrue(aviso.get("mensaje").toString().contains("hora de Bolivia"));
        assertEquals(1, contar("select count(*) from salud_u.notificacion where id_cita=?", cita));
        migrador.update("update salud_u.notificacion set estado='LEIDA',leida_en=now() where id=?", aviso.get("id"));
        try (var ejecutor = Executors.newFixedThreadPool(4)) {
            var resultados = java.util.stream.IntStream.range(0, 4).mapToObj(i -> ejecutor.submit(() ->
                migrador.queryForObject("select salud_u.registrar_notificacion(?,'CITA_ASIGNADA')", UUID.class, cita))).toList();
            for (var resultado : resultados) assertEquals(aviso.get("id"), resultado.get(15, TimeUnit.SECONDS));
        }
        assertEquals(1, contar("select count(*) from salud_u.notificacion where id_cita=?", cita));
        assertEquals("LEIDA", aviso(cita, "CITA_ASIGNADA").get("estado"));
        assertEquals(1, leerComo(caso.estudiante(), "STUDENT", "select count(*) from salud_u.notificacion where id_cita=?", cita));
        assertEquals(0, leerComo(ajeno.estudiante(), "STUDENT", "select count(*) from salud_u.notificacion where id_cita=?", cita));
        assertEquals(0, leerComo(ADMIN, "ADMINISTRATIVE", "select count(*) from salud_u.notificacion where id_cita=?", cita));
        assertEquals(0, runtime.queryForObject("select count(*) from salud_u.notificacion", Integer.class));
        migrador.update("insert into salud_u.preferencia_notificacion(id_principal) values (?),(?)", caso.estudiante(), ajeno.estudiante());
        assertEquals(1, leerComo(caso.estudiante(), "STUDENT", "select count(*) from salud_u.preferencia_notificacion where id_principal in (?,?)", caso.estudiante(), ajeno.estudiante()));
        assertTrue(migrador.queryForObject("select recibir_recordatorios and recordatorio_reforzado from salud_u.preferencia_notificacion where id_principal=?", Boolean.class, caso.estudiante()));
        assertEquals(2, contar("select count(*) from salud_u.preferencia_notificacion where id_principal in (?,?)", caso.estudiante(), ajeno.estudiante()));
        assertFalse(runtime.queryForObject("select has_function_privilege(current_user,'salud_u.registrar_notificacion(uuid,text)','EXECUTE')", Boolean.class));
        assertFalse(runtime.queryForObject("select has_function_privilege(current_user,'salud_u.notificar_cambio_cita()','EXECUTE')", Boolean.class));
        assertThrows(DataAccessException.class, () -> runtime.update("update salud_u.notificacion set estado='ENTREGADA',leida_en=null where id=?", aviso.get("id")));
        assertThrows(DataAccessException.class, () -> runtime.update("delete from salud_u.notificacion where id=?", aviso.get("id")));
        assertThrows(DataAccessException.class, () -> runtime.update("update salud_u.preferencia_notificacion set recibir_recordatorios=false where id_principal=?", caso.estudiante()));
        var error = assertThrows(DataAccessException.class, () -> migrador.update("insert into salud_u.notificacion(id_destinatario,id_cita,tipo_evento,canal,asunto,mensaje) values (?,?,'CITA_ASIGNADA','CORREO','Prueba','Prueba')", caso.estudiante(), cita));
        assertTrue(error.getMostSpecificCause().getMessage().contains("notificacion_canal_valido"));
    }

    @Test
    void falloPosteriorAlInsertDeCitaRevierteAvisoCitaSolicitudYCupo() {
        Caso caso = caso(true);
        migrador.execute("CREATE FUNCTION salud_u.fallo_controlado_n01() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id='" + caso.solicitud() + "'::uuid AND NEW.estado='ASIGNADA' THEN RAISE EXCEPTION 'FALLO_CONTROLADO_N01'; END IF; RETURN NEW; END $$");
        migrador.execute("CREATE TRIGGER fallo_controlado_n01 AFTER UPDATE ON salud_u.solicitud_cita FOR EACH ROW EXECUTE FUNCTION salud_u.fallo_controlado_n01()");
        try {
            var error = assertThrows(DataAccessException.class, () -> asignar(caso));
            assertTrue(error.getMostSpecificCause().getMessage().contains("FALLO_CONTROLADO_N01"));
            assertEquals(0, contar("select count(*) from salud_u.notificacion where id_destinatario=?", caso.estudiante()));
            assertEquals(0, contar("select count(*) from salud_u.cita where id_paciente=?", caso.paciente()));
            assertEquals("PENDIENTE", migrador.queryForObject("select estado from salud_u.solicitud_cita where id=?", String.class, caso.solicitud()));
            assertEquals(0, contar("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", caso.cupo()));
        } finally {
            migrador.execute("DROP TRIGGER fallo_controlado_n01 ON salud_u.solicitud_cita");
            migrador.execute("DROP FUNCTION salud_u.fallo_controlado_n01()");
        }
    }

    @Test
    void cancelacionYAusenciaGeneranAvisosSinFiltrarMotivosYLaLlegadaNoDuplica() {
        Caso cancelada = caso(true), ausente = caso(true);
        UUID citaCancelada = asignar(cancelada), citaAusente = asignar(ausente);
        comoAdmin(() -> { runtime.queryForList("select salud_u.cancelar_solicitud_cita(?,'MOTIVO_PRIVADO_N01')", cancelada.solicitud()); return null; });
        comoAdmin(() -> { runtime.queryForList("select salud_u.cancelar_solicitud_cita(?,'MOTIVO_PRIVADO_N01')", cancelada.solicitud()); return null; });
        assertEquals(2, contar("select count(*) from salud_u.notificacion where id_cita=?", citaCancelada));
        assertFalse(aviso(citaCancelada, "CITA_CANCELADA").get("mensaje").toString().contains("MOTIVO_PRIVADO_N01"));
        comoAdmin(() -> { runtime.queryForList("select salud_u.registrar_llegada_cita(?)", citaAusente); return null; });
        assertEquals(1, contar("select count(*) from salud_u.notificacion where id_cita=?", citaAusente));
        comoAdmin(() -> { runtime.queryForList("select salud_u.registrar_ausencia_cita(?,'MOTIVO_PRIVADO_N01')", citaAusente); return null; });
        assertEquals(2, contar("select count(*) from salud_u.notificacion where id_cita=?", citaAusente));
        assertFalse(aviso(citaAusente, "AUSENCIA_REGISTRADA").get("mensaje").toString().contains("MOTIVO_PRIVADO_N01"));
    }

    @Test
    void reprogramacionesSinCambiarEstadoActualizanElMismoAvisoYReabrenSuLectura() {
        UUID cita = asignar(caso(true));
        migrador.update("update salud_u.cita set programada_para=programada_para+interval '1 day' where id=?", cita);
        var primero = aviso(cita, "CITA_REPROGRAMADA");
        migrador.update("update salud_u.notificacion set estado='LEIDA',leida_en=now() where id=?", primero.get("id"));
        migrador.update("update salud_u.cita set estado=estado,programada_para=programada_para where id=?", cita);
        assertEquals("LEIDA", aviso(cita, "CITA_REPROGRAMADA").get("estado"));
        migrador.update("update salud_u.cita set programada_para=programada_para+interval '2 days' where id=?", cita);
        var ultimo = aviso(cita, "CITA_REPROGRAMADA");
        assertEquals(primero.get("id"), ultimo.get("id"));
        assertEquals(primero.get("creado_en"), ultimo.get("creado_en"));
        assertEquals("ENTREGADA", ultimo.get("estado"));
        assertNull(ultimo.get("leida_en"));
        String horario = migrador.queryForObject("select to_char(programada_para AT TIME ZONE 'America/La_Paz','DD/MM/YYYY HH24:MI') from salud_u.cita where id=?", String.class, cita);
        assertTrue(ultimo.get("mensaje").toString().contains(horario));
        assertNotEquals(primero.get("mensaje"), ultimo.get("mensaje"));
        assertEquals(1, contar("select count(*) from salud_u.notificacion where id_cita=? and tipo_evento='CITA_REPROGRAMADA'", cita));
        UUID otroCupo = caso(false).cupo();
        migrador.update("update salud_u.notificacion set estado='LEIDA',leida_en=now() where id=?", ultimo.get("id"));
        migrador.update("update salud_u.cita set id_cupo=? where id=?", otroCupo, cita);
        assertEquals("ENTREGADA", aviso(cita, "CITA_REPROGRAMADA").get("estado"));
        assertEquals(2, contar("select count(*) from salud_u.notificacion where id_cita=?", cita));
    }

    @Test
    void pacienteSinCuentaPuedeAgendarseYLosInsertHistoricosNoGeneranAsignaciones() {
        Caso sinCuenta = caso(false);
        UUID cita = asignar(sinCuenta);
        assertNotNull(cita);
        assertEquals(0, contar("select count(*) from salud_u.notificacion where id_cita=?", cita));
        Caso historico = caso(true);
        UUID atendida = UUID.randomUUID();
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,id_personal_asignado,tipo_cita,estado,programada_para) values (?,?,?,?,'INICIAL','ATENDIDA',now())", atendida, historico.paciente(), historico.cupo(), PERSONAL);
        assertEquals(0, contar("select count(*) from salud_u.notificacion where id_cita=?", atendida));
    }

    private static Map<String, String> definiciones() {
        var resultado = new java.util.LinkedHashMap<String, String>();
        for (String firma : PROTEGIDAS) resultado.put(firma, migrador.queryForObject("select pg_get_functiondef(cast(? as regprocedure))", String.class, "salud_u." + firma));
        return resultado;
    }

    private static Caso caso(boolean conCuenta) {
        UUID paciente = UUID.randomUUID(), estudiante = conCuenta ? UUID.randomUUID() : null, cupo = UUID.randomUUID();
        if (conCuenta) {
            migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Estudiante N01')", estudiante, estudiante + "@example.invalid");
            migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'ESTUDIANTE')", estudiante);
        }
        migrador.update("insert into salud_u.paciente(id,id_principal,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,?,'Paciente','N01',?,?)", paciente, estudiante, "N01-" + paciente, "N01" + paciente, "REG-" + paciente, "REG" + paciente, ADMIN, ADMIN);
        OffsetDateTime inicio = OffsetDateTime.now().plusDays(14).plusHours(HORARIO.incrementAndGet());
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,1,'PUBLICADO',now(),?)", cupo, PERSONAL, inicio, inicio.plusMinutes(30), ADMIN);
        UUID solicitud = comoAdmin(() -> runtime.queryForObject("select salud_u.crear_solicitud_inicial(?)", UUID.class, paciente));
        return new Caso(paciente, estudiante, solicitud, cupo);
    }

    private static UUID asignar(Caso caso) {
        return comoAdmin(() -> runtime.queryForObject("select salud_u.asignar_solicitud_cita(?,?)", UUID.class, caso.solicitud(), caso.cupo()));
    }

    private static <T> T comoAdmin(java.util.function.Supplier<T> operacion) {
        return transaccion.execute(estado -> { contexto.apply(new DatabaseActor(ADMIN, Set.of("ADMINISTRATIVE"))); return operacion.get(); });
    }

    private static int leerComo(UUID actor, String rol, String sql, Object... argumentos) {
        return transaccion.execute(estado -> { contexto.apply(new DatabaseActor(actor, Set.of(rol))); return runtime.queryForObject(sql, Integer.class, argumentos); });
    }

    private static int contar(String sql, Object... argumentos) { return migrador.queryForObject(sql, Integer.class, argumentos); }
    private static Map<String, Object> aviso(UUID cita, String tipo) { return migrador.queryForMap("select * from salud_u.notificacion where id_cita=? and tipo_evento=?", cita, tipo); }
    private record Caso(UUID paciente, UUID estudiante, UUID solicitud, UUID cupo) {}
}

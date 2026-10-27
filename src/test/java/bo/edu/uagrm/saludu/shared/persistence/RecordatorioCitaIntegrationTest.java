package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

@Testcontainers(disabledWithoutDocker = true)
class RecordatorioCitaIntegrationTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
    private static final UUID DOCTOR = UUID.randomUUID(), PERSONAL = UUID.randomUUID();
    private static JdbcTemplate migrador, runtime;
    private static TransactionTemplate transaction;
    private static DatabaseActorContext actors;

    @BeforeAll
    static void prepare() {
        POSTGRES.start();
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.execute("CREATE ROLE salud_u_runtime LOGIN PASSWORD 'runtime-test-password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS");
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password")
            .schemas("salud_u").defaultSchema("salud_u").createSchemas(true)
            .placeholders(Map.of("runtime_role", "salud_u_runtime", "migrator_role", "salud_u_migrator")).load().migrate();
        var dataSource = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_runtime", "runtime-test-password");
        runtime = new JdbcTemplate(dataSource);
        transaction = new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        actors = new DatabaseActorContext(runtime);
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico N03')", DOCTOR, DOCTOR + "@example.invalid");
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'N03-MEDICO')", PERSONAL, DOCTOR);
    }

    @AfterAll
    static void close() {
        if (POSTGRES.isRunning()) {
            CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "RecordatorioCitaIntegrationTest");
            POSTGRES.stop();
        }
    }

    @Test
    void tomorrowUsesBoliviaMidnightAndAHalfOpenRangeRegardlessOfSessionTimezone() {
        var reference = OffsetDateTime.parse("2051-10-27T03:59:59Z"); // 26/10 23:59:59 en Bolivia.
        var start = OffsetDateTime.parse("2051-10-27T04:00:00Z");
        Case before = appointment(start.minusNanos(1000), "PROGRAMADA", true, null, null);
        Case first = appointment(start, "PROGRAMADA", true, null, null);
        Case last = appointment(start.plusDays(1).minusNanos(1000), "PROGRAMADA", true, null, null);
        Case after = appointment(start.plusDays(1), "PROGRAMADA", true, null, null);
        for (String state : List.of("LLEGADA", "ATENDIDA", "CANCELADA", "AUSENTE"))
            appointment(start.plusHours(6), state, true, null, null);
        appointment(start.plusHours(7), "PROGRAMADA", false, null, null);
        var connection = new SingleConnectionDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", true);
        try {
            var jdbc = new JdbcTemplate(connection);
            jdbc.execute("set time zone 'Asia/Tokyo'");
            assertEquals(2, jdbc.queryForObject("select salud_u.generar_recordatorios_citas_en(?)", Integer.class, reference));
            assertEquals(0, reminders(before));
            assertEquals(1, reminders(first));
            assertEquals(1, reminders(last));
            assertEquals(0, reminders(after));
            assertEquals("2051-10-27", notice(first).get("fecha_objetivo").toString());
            assertTrue(notice(first).get("mensaje").toString().contains("27/10/2051 00:00"));
            assertEquals(1, jdbc.queryForObject("select salud_u.generar_recordatorios_citas_en(?)", Integer.class, start));
            assertEquals(1, reminders(after)); // Ya es 27/10 en Bolivia: mañana es el 28.
        } finally { connection.destroy(); }
    }

    @Test
    void preferencesDefaultToEnabledAndReinforcedOptOutDoesNotDisableOrdinaryReminders() {
        var reference = OffsetDateTime.parse("2052-02-01T12:00:00Z");
        Case defaults = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        Case off = appointment(reference.plusDays(1), "PROGRAMADA", true, false, true);
        Case ordinaryOnly = appointment(reference.plusDays(1), "PROGRAMADA", true, true, false);
        assertEquals(2, generate(reference));
        assertEquals(1, reminders(defaults));
        assertEquals(0, reminders(off));
        assertEquals(1, reminders(ordinaryOnly));
        migrador.update("update salud_u.preferencia_notificacion set recibir_recordatorios=true where id_principal=?", off.student());
        assertEquals(1, generate(reference.plusHours(1)));
        assertEquals(1, reminders(off));
        migrador.update("update salud_u.preferencia_notificacion set recibir_recordatorios=false where id_principal=?", off.student());
        assertEquals(0, generate(reference.plusHours(2)));
        assertEquals(1, reminders(off)); // No se borra un aviso ya entregado al cambiar la preferencia.
    }

    @Test
    void repeatedRunsKeepTheSameIdAndReadState() {
        var reference = OffsetDateTime.parse("2053-03-01T12:00:00Z");
        Case item = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        assertEquals(1, generate(reference));
        var original = notice(item);
        migrador.update("update salud_u.notificacion set estado='LEIDA',leida_en=entregada_en where id=?", original.get("id"));
        assertEquals(0, generate(reference.plusHours(1)));
        var repeated = notice(item);
        assertEquals(original.get("id"), repeated.get("id"));
        assertEquals(original.get("entregada_en"), repeated.get("entregada_en"));
        assertEquals("LEIDA", repeated.get("estado"));
        assertNotNull(repeated.get("leida_en"));
        assertEquals(1, reminders(item));
    }

    @Test
    void concurrentWorkersDoNotCreateDuplicates() throws Exception {
        var reference = OffsetDateTime.parse("2054-04-01T12:00:00Z");
        var items = java.util.stream.IntStream.range(0, 8)
            .mapToObj(i -> appointment(reference.plusDays(1).plusMinutes(i), "PROGRAMADA", true, null, null)).toList();
        int total = 0;
        try (var pool = Executors.newFixedThreadPool(4)) {
            var results = java.util.stream.IntStream.range(0, 4).mapToObj(i -> pool.submit(() -> generate(reference))).toList();
            for (var result : results) total += result.get(15, TimeUnit.SECONDS);
        }
        assertEquals(items.size(), total);
        for (Case item : items) assertEquals(1, reminders(item));
        assertEquals(0, generate(reference.plusHours(1)));
    }

    @Test
    void changesToTimeOrTargetDateRefreshTheExistingNoticeInsteadOfDuplicatingIt() {
        var reference = OffsetDateTime.parse("2055-05-01T12:00:00Z");
        Case item = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        assertEquals(1, generate(reference));
        var original = notice(item);
        migrador.update("update salud_u.notificacion set estado='LEIDA',leida_en=entregada_en where id=?", original.get("id"));
        migrador.update("update salud_u.cita set programada_para=programada_para+interval '1 hour' where id=?", item.appointment());
        assertEquals(1, generate(reference.plusHours(2)));
        var refreshed = notice(item);
        assertEquals(original.get("id"), refreshed.get("id"));
        assertEquals(original.get("creado_en"), refreshed.get("creado_en"));
        assertEquals("ENTREGADA", refreshed.get("estado"));
        assertNull(refreshed.get("leida_en"));
        assertNotEquals(original.get("mensaje"), refreshed.get("mensaje"));
        migrador.update("update salud_u.cita set programada_para=programada_para+interval '2 days' where id=?", item.appointment());
        assertEquals(0, generate(reference.plusHours(3)));
        assertEquals(1, generate(reference.plusDays(2)));
        assertEquals(original.get("id"), notice(item).get("id"));
        assertEquals("2055-05-04", notice(item).get("fecha_objetivo").toString());
        assertEquals(1, reminders(item));
    }

    @Test
    void batchFailureRollsBackAllRemindersAndTheNextAttemptCanRecover() {
        var reference = OffsetDateTime.parse("2056-06-01T12:00:00Z");
        Case first = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        Case second = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        UUID failOn = migrador.queryForObject("select id from salud_u.cita where id in (?,?) order by id desc limit 1", UUID.class, first.appointment(), second.appointment());
        migrador.execute("create function salud_u.fallo_recordatorio_n03() returns trigger language plpgsql as $$ begin if NEW.tipo_evento='RECORDATORIO_CITA' and NEW.id_cita='" + failOn + "'::uuid then raise exception 'FALLO_CONTROLADO_N03'; end if; return NEW; end $$");
        migrador.execute("create trigger fallo_recordatorio_n03 after insert on salud_u.notificacion for each row execute function salud_u.fallo_recordatorio_n03()");
        try {
            var error = assertThrows(DataAccessException.class, () -> generate(reference));
            assertTrue(error.getMostSpecificCause().getMessage().contains("FALLO_CONTROLADO_N03"));
            assertEquals(0, reminders(first));
            assertEquals(0, reminders(second));
        } finally {
            migrador.execute("drop trigger fallo_recordatorio_n03 on salud_u.notificacion");
            migrador.execute("drop function salud_u.fallo_recordatorio_n03()");
        }
        assertEquals(2, generate(reference));
    }

    @Test
    void runtimeOnlyHasTheBoundedJobEntryAndNewTypeIsVisibleThroughTheOwnInbox() {
        assertFalse(runtime.queryForObject("select has_function_privilege(current_user,'salud_u.generar_recordatorios_citas_en(timestamptz)','EXECUTE')", Boolean.class));
        assertThrows(DataAccessException.class, () -> runtime.queryForObject("select salud_u.generar_recordatorios_citas_en(now())", Integer.class));
        assertEquals(0, runtime.queryForObject("select salud_u.generar_recordatorios_citas()", Integer.class));
        assertThrows(DataAccessException.class, () -> migrador.queryForObject("select salud_u.generar_recordatorios_citas_en(null)", Integer.class));
        var reference = OffsetDateTime.parse("2020-07-01T12:00:00Z");
        Case own = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        Case other = appointment(reference.plusDays(1), "PROGRAMADA", true, false, true);
        assertEquals(1, generate(reference));
        var rows = transaction.execute(status -> {
            actors.apply(new DatabaseActor(own.student(), Set.of("STUDENT")));
            return runtime.queryForList("select * from salud_u.listar_mis_notificaciones(100,null,null)");
        });
        assertTrue(rows.stream().anyMatch(row -> "APPOINTMENT_REMINDER".equals(row.get("tipo_evento"))));
        assertEquals(0, transaction.<Integer>execute(status -> {
            actors.apply(new DatabaseActor(other.student(), Set.of("STUDENT")));
            return runtime.queryForObject("select count(*) from salud_u.notificacion where tipo_evento='RECORDATORIO_CITA'", Integer.class);
        }));
    }

    @Test
    void reminderIsHiddenWhileItsAppointmentIsNotScheduledForThatDayAndReturnsWhenItIs() {
        // Fechas pasadas: la bandeja solo muestra avisos ya entregados.
        var reference = OffsetDateTime.parse("2019-03-10T12:00:00Z");
        Case moved = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        Case cancelled = appointment(reference.plusDays(1), "PROGRAMADA", true, null, null);
        assertEquals(2, generate(reference));
        assertEquals(Set.of("APPOINTMENT_ASSIGNED", "APPOINTMENT_REMINDER"), visibleTypes(moved));
        assertEquals(2L, unread(moved));

        migrador.update("update salud_u.cita set estado='CANCELADA' where id=?", cancelled.appointment());
        assertEquals(Set.of("APPOINTMENT_ASSIGNED", "APPOINTMENT_CANCELLED"), visibleTypes(cancelled));
        assertEquals(2L, unread(cancelled));
        assertEquals(0, markRead(cancelled, (UUID) notice(cancelled).get("id")));
        assertEquals("ENTREGADA", notice(cancelled).get("estado"));

        migrador.update("update salud_u.cita set programada_para=programada_para+interval '2 days' where id=?", moved.appointment());
        assertEquals(Set.of("APPOINTMENT_ASSIGNED", "APPOINTMENT_RESCHEDULED"), visibleTypes(moved));
        assertEquals(2L, unread(moved));
        assertEquals(1, generate(reference.plusDays(2)));
        assertEquals(Set.of("APPOINTMENT_ASSIGNED", "APPOINTMENT_RESCHEDULED", "APPOINTMENT_REMINDER"), visibleTypes(moved));
        assertEquals(3L, unread(moved));
        assertEquals(1, markRead(moved, (UUID) notice(moved).get("id")));
    }

    private static Set<String> visibleTypes(Case item) {
        return transaction.execute(status -> {
            actors.apply(new DatabaseActor(item.student(), Set.of("STUDENT")));
            return Set.copyOf(runtime.queryForList("select tipo_evento from salud_u.listar_mis_notificaciones(100,null,null)", String.class));
        });
    }
    private static long unread(Case item) {
        return transaction.execute(status -> {
            actors.apply(new DatabaseActor(item.student(), Set.of("STUDENT")));
            return runtime.queryForObject("select salud_u.contar_mis_notificaciones_no_leidas()", Long.class);
        });
    }
    private static int markRead(Case item, UUID id) {
        return transaction.execute(status -> {
            actors.apply(new DatabaseActor(item.student(), Set.of("STUDENT")));
            return runtime.queryForList("select id from salud_u.marcar_mi_notificacion_leida(?)", id).size();
        });
    }
    private static int generate(OffsetDateTime reference) {
        return migrador.queryForObject("select salud_u.generar_recordatorios_citas_en(?)", Integer.class, reference);
    }
    private static int reminders(Case item) {
        return migrador.queryForObject("select count(*) from salud_u.notificacion where id_cita=? and tipo_evento='RECORDATORIO_CITA'", Integer.class, item.appointment());
    }
    private static Map<String, Object> notice(Case item) {
        return migrador.queryForMap("select * from salud_u.notificacion where id_cita=? and tipo_evento='RECORDATORIO_CITA'", item.appointment());
    }
    private static Case appointment(OffsetDateTime starts, String state, boolean linked, Boolean receive, Boolean reinforced) {
        UUID student = linked ? UUID.randomUUID() : null, patient = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID();
        if (linked) {
            migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Estudiante N03')", student, student + "@example.invalid");
            migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'ESTUDIANTE')", student);
            if (receive != null || reinforced != null)
                migrador.update("insert into salud_u.preferencia_notificacion(id_principal,recibir_recordatorios,recordatorio_reforzado) values (?,?,?)", student, receive == null || receive, reinforced == null || reinforced);
        }
        migrador.update("insert into salud_u.paciente(id,id_principal,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,?,'Paciente','N03',?,?)", patient, student, "N03-" + patient, "N03" + patient, "REG-" + patient, "REG" + patient, DOCTOR, DOCTOR);
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,1,'PUBLICADO',now(),?)", slot, PERSONAL, starts, starts.plusMinutes(30), DOCTOR);
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,id_personal_asignado,tipo_cita,estado,programada_para) values (?,?,?,?,'INICIAL',?,?)", appointment, patient, slot, PERSONAL, state, starts);
        return new Case(appointment, student);
    }
    private record Case(UUID appointment, UUID student) {}
}

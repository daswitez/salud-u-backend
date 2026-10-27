package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;

import bo.edu.uagrm.saludu.scheduling.application.ScheduleEstimationService;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

/** O-03: estimaciones de asistencia y demanda y recordatorio reforzado (RN-36). */
@Testcontainers(disabledWithoutDocker = true)
class EstimacionAgendaIntegrationTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
    private static final UUID DOCTOR = UUID.randomUUID();
    private static JdbcTemplate migrador, runtime;

    @BeforeAll
    static void prepare() {
        POSTGRES.start();
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.execute("CREATE ROLE salud_u_runtime LOGIN PASSWORD 'runtime-test-password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS");
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password")
            .schemas("salud_u").defaultSchema("salud_u").createSchemas(true)
            .placeholders(Map.of("runtime_role", "salud_u_runtime", "migrator_role", "salud_u_migrator")).load().migrate();
        runtime = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_runtime", "runtime-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O03')", DOCTOR, DOCTOR + "@example.invalid");
    }

    @AfterAll
    static void close() {
        if (POSTGRES.isRunning()) {
            CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "EstimacionAgendaIntegrationTest");
            POSTGRES.stop();
        }
    }

    @Test
    void recomputeStoresVersionedEstimatesInSpanishFromObservationsAndInitialValues() {
        UUID specialty = specialty(), staff = staff();
        LocalDate tuesday = LocalDate.parse("2020-03-03");
        migrador.update("insert into salud_u.valor_inicial_agenda(id_especialidad,tipo_periodo,demanda_diaria_esperada,asistencia_esperada,peso_citas,registrado_por) values (?,'CLASES',10,0.5,20,?)", specialty, DOCTOR);
        observation(tuesday, staff, specialty, "CLASES", 12, 8, 2, null);
        observation(tuesday, null, specialty, "CLASES", 12, 8, 2, 4);
        observation(tuesday.plusDays(1), null, specialty, null, 0, 0, 0, 3);

        int rows = service().recompute();
        assertTrue(rows >= 3);
        Map<String, Object> doctor = estimate(staff, specialty, 2, "CLASES");
        // α₀ = 20·0,5 = 10 y β₀ = 10: α = 9,5 + 8 = 17,5; β = 9,5 + 2 = 11,5.
        assertEquals(0, new java.math.BigDecimal("17.500000").compareTo((java.math.BigDecimal) doctor.get("alfa_asistencia")));
        assertEquals(0, new java.math.BigDecimal("11.500000").compareTo((java.math.BigDecimal) doctor.get("beta_asistencia")));
        assertNull(doctor.get("demanda_suavizada"));
        assertEquals(10, doctor.get("citas_observadas"));
        assertEquals("INICIAL", doctor.get("fuente_vigente"));
        assertEquals("0.603", doctor.get("asistencia_vigente").toString());
        assertEquals("o03-v1", doctor.get("version_modelo"));
        Map<String, Object> row = estimate(null, specialty, 2, "CLASES");
        assertEquals("8.2000", row.get("demanda_suavizada").toString(), "D = 0,3·4 + 0,7·10");
        // Fecha sin período: valores de DV-10 y demanda inicial igual a la capacidad (0).
        assertEquals("0.9000", estimate(null, specialty, 3, null).get("demanda_suavizada").toString());

        List<Map<String, Object>> before = migrador.queryForList("select id_especialidad,id_personal,dia_semana,tipo_periodo,alfa_asistencia,beta_asistencia,demanda_suavizada,asistencia_vigente,fuente_vigente from salud_u.estimacion_agenda order by 1,2,3,4");
        assertEquals(rows, service().recompute());
        assertEquals(before, migrador.queryForList("select id_especialidad,id_personal,dia_semana,tipo_periodo,alfa_asistencia,beta_asistencia,demanda_suavizada,asistencia_vigente,fuente_vigente from salud_u.estimacion_agenda order by 1,2,3,4"),
            "Recalcular con las mismas observaciones da lo mismo");

        // Diez jornadas más completan 20 citas propias: el médico pasa a su propia estimación.
        observation(tuesday.plusWeeks(1), staff, specialty, "CLASES", 12, 9, 1, null);
        service().recompute();
        assertEquals("MEDICO", estimate(staff, specialty, 2, "CLASES").get("fuente_vigente"));
    }

    @Test
    void theRuntimeOnlyUsesTheFunctionsAndInvalidBatchesKeepThePreviousEstimates() {
        UUID specialty = specialty();
        observation(LocalDate.parse("2020-05-05"), null, specialty, "CLASES", 4, 3, 1, 2);
        service().recompute();
        int count = migrador.queryForObject("select count(*) from salud_u.estimacion_agenda", Integer.class);
        assertTrue(count > 0);
        for (String sql : List.of("select count(*) from salud_u.estimacion_agenda", "select count(*) from salud_u.observacion_jornada"))
            assertThrows(DataAccessException.class, () -> runtime.queryForObject(sql, Integer.class));
        assertThrows(DataAccessException.class, () -> runtime.queryForObject("select salud_u.asistencia_estimada(null,null,current_date)", Double.class));
        String valid = "{\"id_especialidad\":\"" + specialty + "\",\"id_personal\":null,\"dia_semana\":2,\"tipo_periodo\":\"CLASSES\",\"alfa_asistencia\":1,\"beta_asistencia\":1,\"demanda_suavizada\":1,\"citas_observadas\":0,\"jornadas_observadas\":1,\"ultima_fecha\":\"2020-05-05\",\"asistencia_vigente\":0.5,\"fuente_vigente\":\"SPECIALTY\",\"alfa_vigente\":1,\"beta_vigente\":1";
        for (String[] invalid : new String[][] {
            {"[" + valid + "}," + valid + "}]", "o03-v1"},
            {"[" + valid.replace("\"CLASSES\"", "\"CLASES\"") + "}]", "o03-v1"},
            {"[" + valid.replace("\"SPECIALTY\"", "\"DOCTOR\"") + "}]", "o03-v1"},
            {"[" + valid.replace("\"alfa_asistencia\":1", "\"alfa_asistencia\":0") + "}]", "o03-v1"},
            {"[" + valid.replace("\"demanda_suavizada\":1", "\"demanda_suavizada\":null") + "}]", "o03-v1"},
            {"[" + valid + "}]", "Versión X"},
            {"{}", "o03-v1"}})
            assertThrows(DataAccessException.class, () -> runtime.queryForObject("select salud_u.guardar_estimaciones_agenda(cast(? as jsonb), ?)", Integer.class, invalid[0], invalid[1]));
        assertEquals(count, migrador.queryForObject("select count(*) from salud_u.estimacion_agenda", Integer.class));
    }

    @Test
    void theAttendanceForAnAppointmentFallsBackFromDoctorToSpecialtyToArea() {
        UUID specialty = specialty(), staff = staff(), other = staff();
        LocalDate day = LocalDate.parse("2061-06-07"); // Martes, dentro de un período de exámenes.
        migrador.update("insert into salud_u.periodo_academico(nombre,tipo,fecha_inicio,fecha_fin,creado_por) values ('Exámenes 2061','EXAMENES','2061-06-01','2061-06-30',?)", DOCTOR);
        estimateRow(null, null, 2, "EXAMENES", "0.810");
        assertEquals("0.810", attendance(staff, specialty, day));
        estimateRow(specialty, null, 2, "EXAMENES", "0.720");
        assertEquals("0.720", attendance(staff, specialty, day));
        estimateRow(specialty, staff, 2, "EXAMENES", "0.650");
        assertEquals("0.650", attendance(staff, specialty, day));
        assertEquals("0.720", attendance(other, specialty, day), "Otro médico usa la especialidad");
        assertNull(attendance(staff, specialty, day.plusDays(1)), "Miércoles sin estimaciones");
        assertNull(attendance(staff, specialty, LocalDate.parse("2061-07-05")), "Fuera del período el tipo es otro");
    }

    @Test
    void lowEstimatedAttendanceAddsAReinforcedReminderOnTheDayRespectingPreferences() {
        LocalDate day = LocalDate.parse("2062-03-07"); // Martes, sin período.
        UUID specialty = specialty(), staff = staff();
        estimateRow(specialty, staff, 2, null, "0.650");
        Case low = appointment(staff, specialty, at(day, "10:00"), null, null);
        Case optOut = appointment(staff, specialty, at(day, "10:30"), true, false);
        Case noReminders = appointment(staff, specialty, at(day, "11:00"), false, true);
        Case early = appointment(staff, specialty, at(day, "07:30"), null, null);
        UUID otherStaff = staff();
        estimateRow(specialty, otherStaff, 2, null, "0.700");
        Case atThreshold = appointment(otherStaff, specialty, at(day, "10:00"), null, null);
        Case noEstimate = appointment(staff(), specialty(), at(day, "10:00"), null, null);

        assertEquals(0, reinforced(generate(at(day, "06:59")), low), "Antes de las 07:00 no hay reforzado");
        generate(at(day, "08:00"));
        assertEquals(1, reinforced(0, low));
        Map<String, Object> notice = migrador.queryForMap("select asunto, mensaje, fecha_objetivo, estado from salud_u.notificacion where id_cita=? and tipo_evento='RECORDATORIO_REFORZADO'", low.appointment());
        assertEquals("Tu cita es hoy", notice.get("asunto"));
        assertTrue(notice.get("mensaje").toString().contains("hoy a las 10:00"));
        assertEquals(day.toString(), notice.get("fecha_objetivo").toString());
        assertEquals("ENTREGADA", notice.get("estado"));
        for (Case none : List.of(optOut, noReminders, early, atThreshold, noEstimate)) assertEquals(0, reinforced(0, none));
        assertEquals(0, generate(at(day, "08:15")), "Repetir no duplica ni reescribe");
        assertEquals("APPOINTMENT_REMINDER_REINFORCED", migrador.queryForObject("select salud_u.a_codigo_api('tipo_evento_notificacion','RECORDATORIO_REFORZADO')", String.class));
    }

    @Test
    void theReinforcedReminderIsOnlyVisibleWhileItsAppointmentIsStillScheduledForThatDay() {
        LocalDate day = LocalDate.parse("2019-04-09"); // Martes pasado: la bandeja solo muestra entregas ya ocurridas.
        UUID specialty = specialty(), staff = staff();
        estimateRow(specialty, staff, 2, null, "0.400");
        Case item = appointment(staff, specialty, at(day, "15:00"), null, null);
        generate(at(day, "09:00"));
        assertEquals(1, visibleReinforced(item));
        migrador.update("update salud_u.cita set estado='CANCELADA', cancelada_en=? where id=?", at(day, "10:00"), item.appointment());
        assertEquals(0, visibleReinforced(item));
    }

    @Test
    void estimationFunctionsOnlyReadAgendaAndCalendarTables() {
        var pattern = java.util.regex.Pattern.compile("salud_u\\.([a-z_]+)");
        Map<String, List<String>> allowed = Map.of(
            "observaciones_para_estimacion", List.of("a_codigo_api", "observacion_jornada"),
            "valores_iniciales_para_estimacion", List.of("a_codigo_api", "valor_inicial_agenda"),
            "guardar_estimaciones_agenda", List.of("desde_codigo_api", "estimacion_agenda", "guardar_estimaciones_agenda"),
            "asistencia_estimada", List.of("estimacion_agenda", "periodo_academico"));
        allowed.forEach((function, names) -> {
            String source = migrador.queryForObject("select prosrc from pg_proc where proname=? and pronamespace='salud_u'::regnamespace", String.class, function);
            var found = new java.util.TreeSet<String>();
            var matcher = pattern.matcher(source);
            while (matcher.find()) found.add(matcher.group(1));
            assertEquals(new java.util.TreeSet<>(names), found, function);
        });
    }

    private static ScheduleEstimationService service() { return new ScheduleEstimationService(runtime, new ObjectMapper()); }

    private static int generate(OffsetDateTime instant) {
        return migrador.queryForObject("select salud_u.generar_recordatorios_citas_en(?)", Integer.class, instant);
    }

    private static int reinforced(int ignored, Case item) {
        return migrador.queryForObject("select count(*) from salud_u.notificacion where id_cita=? and tipo_evento='RECORDATORIO_REFORZADO'", Integer.class, item.appointment());
    }

    private static int visibleReinforced(Case item) {
        var connection = new SingleConnectionDataSource(POSTGRES.getJdbcUrl(), "salud_u_runtime", "runtime-test-password", true);
        try {
            var jdbc = new JdbcTemplate(connection);
            jdbc.queryForObject("select set_config('salud_u.id_actor', ?, false)", String.class, item.student().toString());
            return jdbc.queryForObject("select count(*) from salud_u.listar_mis_notificaciones() where tipo_evento='APPOINTMENT_REMINDER_REINFORCED'", Integer.class);
        } finally { connection.destroy(); }
    }

    private static String attendance(UUID staff, UUID specialty, LocalDate day) {
        Object value = migrador.queryForObject("select salud_u.asistencia_estimada(?,?,?)", Object.class, staff, specialty, day);
        return value == null ? null : value.toString();
    }

    private static Map<String, Object> estimate(UUID staff, UUID specialty, int weekday, String type) {
        return migrador.queryForMap("select * from salud_u.estimacion_agenda where id_personal is not distinct from ? and id_especialidad is not distinct from ? and dia_semana=? and tipo_periodo is not distinct from ?",
            staff, specialty, weekday, type);
    }

    private static void estimateRow(UUID specialty, UUID staff, int weekday, String type, String attendance) {
        migrador.update("insert into salud_u.estimacion_agenda(id_especialidad,id_personal,dia_semana,tipo_periodo,alfa_asistencia,beta_asistencia,demanda_suavizada,citas_observadas,jornadas_observadas,ultima_fecha,asistencia_vigente,fuente_vigente,alfa_vigente,beta_vigente,version_modelo) values (?,?,?,?,1,1,?,0,1,'2020-01-01',cast(? as numeric),?,1,1,'o03-v1')",
            specialty, staff, weekday, type, staff == null ? 1 : null, attendance, staff == null ? (specialty == null ? "AREA" : "ESPECIALIDAD") : "MEDICO");
    }

    private static void observation(LocalDate day, UUID staff, UUID specialty, String type, int capacity, int arrivals, int noShows, Integer requests) {
        UUID period = null;
        if (type != null) {
            period = migrador.queryForList("select id from salud_u.periodo_academico where ? between fecha_inicio and fecha_fin", UUID.class, day).stream().findFirst().orElse(null);
            if (period == null) {
                period = UUID.randomUUID();
                migrador.update("insert into salud_u.periodo_academico(id,nombre,tipo,fecha_inicio,fecha_fin,creado_por) values (?,?,?,?,?,?)", period, "Período " + day, type, day, day, DOCTOR);
            }
        }
        migrador.update("insert into salud_u.observacion_jornada(fecha,id_personal,id_especialidad,id_periodo_academico,tipo_periodo,capacidad,citas_programadas,asistencias,ausencias,sin_registrar,cancelaciones,solicitudes_ingresadas) values (?,?,?,?,?,?,?,?,?,0,0,?)",
            day, staff, specialty, period, type, capacity, arrivals + noShows, arrivals, noShows, requests);
    }

    private static OffsetDateTime at(LocalDate day, String time) { return OffsetDateTime.parse(day + "T" + time + ":00-04:00"); }

    private static UUID specialty() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,?,?)", id, "O03-" + id, "Especialidad O03 " + id);
        return id;
    }

    private static UUID staff() {
        UUID principal = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O03')", principal, principal + "@example.invalid");
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "O03-" + id);
        return id;
    }

    private static Case appointment(UUID staff, UUID specialty, OffsetDateTime start, Boolean reminders, Boolean reinforced) {
        UUID student = UUID.randomUUID(), patient = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Estudiante O03')", student, student + "@example.invalid");
        migrador.update("insert into salud_u.paciente(id,id_principal,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,?,'Paciente','O03',?,?)",
            patient, student, "O03-" + patient, "O03" + patient, "REG-" + patient, "REG" + patient, DOCTOR, DOCTOR);
        if (reminders != null)
            migrador.update("insert into salud_u.preferencia_notificacion(id_principal,recibir_recordatorios,recordatorio_reforzado) values (?,?,?)", student, reminders, reinforced);
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,?,1,'PUBLICADO',?,?)",
            slot, staff, specialty, start, start.plusMinutes(30), start.minusDays(7), DOCTOR);
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,id_personal_asignado,tipo_cita,estado,programada_para) values (?,?,?,?,'ESPECIALIDAD','PROGRAMADA',?)",
            appointment, patient, slot, staff, start);
        return new Case(student, appointment);
    }

    private record Case(UUID student, UUID appointment) {}
}

package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

/** O-02: observación de jornada y cierre nocturno (RN-34, PA-23, PV-7.3). */
@Testcontainers(disabledWithoutDocker = true)
class ObservacionJornadaIntegrationTest {
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
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O02')", DOCTOR, DOCTOR + "@example.invalid");
    }

    @AfterAll
    static void close() {
        if (POSTGRES.isRunning()) {
            CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "ObservacionJornadaIntegrationTest");
            POSTGRES.stop();
        }
    }

    @Test
    void closingADayCountsEachDoctorAndSpecialtyWithItsPeriodAndIsIdempotent() {
        LocalDate day = LocalDate.parse("2019-03-12");
        UUID period = UUID.randomUUID();
        migrador.update("insert into salud_u.periodo_academico(id,nombre,tipo,fecha_inicio,fecha_fin,creado_por) values (?,'Clases 1/2019','CLASES','2019-03-01','2019-06-30',?)", period, DOCTOR);
        UUID specialty = specialty(), withoutSlots = specialty(), doctorA = staff(), doctorB = staff();

        // PV-7.3: el médico A cierra la jornada con 8 asistencias y 2 ausencias, más una cancelada y una sin registrar.
        UUID slotA = slot(doctorA, specialty, at(day, "08:00"), 12, "PUBLICADO");
        for (String state : List.of("ATENDIDA", "ATENDIDA", "ATENDIDA", "ATENDIDA", "ATENDIDA", "ATENDIDA", "LLEGADA", "LLEGADA", "AUSENTE", "AUSENTE", "CANCELADA", "PROGRAMADA"))
            appointment(slotA, doctorA, state);
        slot(doctorA, specialty, at(day, "14:00"), 5, "BLOQUEADO");
        slot(doctorA, specialty, at(day, "15:00"), 3, "BORRADOR");
        slot(doctorA, specialty, at(day, "16:00"), 2, "CERRADO");
        // El médico B atiende revisión inicial (área): un cupo publicado y uno cerrado que llegó a usarse.
        UUID slotB = slot(doctorB, null, at(day, "09:00"), 4, "PUBLICADO"), usedClosed = slot(doctorB, null, at(day, "10:00"), 1, "CERRADO");
        appointment(slotB, doctorB, "AUSENTE");
        appointment(usedClosed, doctorB, "ATENDIDA");
        // Límites de Bolivia: el último instante del día anterior y la medianoche siguiente no cuentan.
        appointment(slot(doctorA, specialty, at(day.minusDays(1), "23:59:59.999"), 1, "PUBLICADO"), doctorA, "ATENDIDA");
        appointment(slot(doctorA, specialty, at(day.plusDays(1), "00:00"), 1, "PUBLICADO"), doctorA, "ATENDIDA");

        request("INICIAL", null, at(day, "00:00"));
        request("INICIAL", null, at(day, "23:59"));
        request("ESPECIALIDAD", specialty, at(day, "11:00"));
        request("DERIVACION", specialty, at(day, "12:00"));
        request("ESPECIALIDAD", withoutSlots, at(day, "13:00"));
        request("INICIAL", null, at(day.plusDays(1), "00:00"));

        assertEquals(5, close(day));
        assertEquals(List.of(12, 11, 8, 2, 1, 1), counts(day, doctorA, specialty));
        assertEquals(List.of(5, 2, 1, 1, 0, 0), counts(day, doctorB, null));
        assertEquals(List.of(12, 11, 8, 2, 1, 1, 2), countsWithRequests(day, specialty));
        assertEquals(List.of(5, 2, 1, 1, 0, 0, 2), countsWithRequests(day, null));
        assertEquals(List.of(0, 0, 0, 0, 0, 0, 1), countsWithRequests(day, withoutSlots), "Demanda sin oferta también se observa");
        assertEquals(5, migrador.queryForObject("select count(*) from salud_u.observacion_jornada where fecha=? and id_periodo_academico=? and tipo_periodo='CLASES'", Integer.class, day, period));
        assertNull(migrador.queryForObject("select solicitudes_ingresadas from salud_u.observacion_jornada where fecha=? and id_personal=?", Integer.class, day, doctorA));

        // Repetir no cambia nada, ni siquiera los identificadores.
        List<Map<String, Object>> before = snapshot(day);
        assertEquals(0, close(day));
        assertEquals(before, snapshot(day));

        // Una asistencia registrada tarde actualiza solo la fila del médico y la de su especialidad.
        migrador.update("update salud_u.cita set estado='LLEGADA' where id_cupo=? and estado='PROGRAMADA'", slotA);
        assertEquals(2, close(day));
        assertEquals(List.of(12, 11, 9, 2, 0, 1), counts(day, doctorA, specialty));

        // Si los cupos de B pasan a otro día, su fila desaparece y el área se queda con su demanda.
        migrador.update("update salud_u.cupo_disponibilidad set inicia_a=inicia_a+interval '7 days', termina_a=termina_a+interval '7 days' where id_personal=?", doctorB);
        assertEquals(2, close(day));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.observacion_jornada where fecha=? and id_personal=?", Integer.class, day, doctorB));
        assertEquals(List.of(0, 0, 0, 0, 0, 0, 2), countsWithRequests(day, null));
    }

    @Test
    void todayAndFutureDaysAreNeverClosed() {
        UUID doctor = staff();
        String today = migrador.queryForObject("select ((now() at time zone 'America/La_Paz')::date)::text", String.class);
        appointment(slot(doctor, null, OffsetDateTime.now().plusMinutes(5), 2, "PUBLICADO"), doctor, "PROGRAMADA");
        LocalDate date = LocalDate.parse(today);
        assertEquals(0, close(date));
        assertEquals(0, close(date.plusDays(1)));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.observacion_jornada where fecha>=?", Integer.class, date));
    }

    @Test
    void theRuntimeOnlyRunsTheRecentDaysEntryAndCannotReadTheObservations() {
        UUID doctor = staff();
        LocalDate yesterday = LocalDate.parse(migrador.queryForObject("select ((now() at time zone 'America/La_Paz')::date - 1)::text", String.class));
        LocalDate eightDaysAgo = yesterday.minusDays(7);
        appointment(slot(doctor, null, at(yesterday, "10:00"), 3, "PUBLICADO"), doctor, "ATENDIDA");
        appointment(slot(doctor, null, at(eightDaysAgo, "10:00"), 3, "PUBLICADO"), doctor, "ATENDIDA");

        assertTrue(runtime.queryForObject("select salud_u.cerrar_jornadas_recientes()", Integer.class) >= 2);
        assertEquals(List.of(3, 1, 1, 0, 0, 0), counts(yesterday, doctor, null));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.observacion_jornada where fecha=?", Integer.class, eightDaysAgo), "Solo los siete días anteriores");
        assertEquals(0, runtime.queryForObject("select salud_u.cerrar_jornadas_recientes()", Integer.class));

        assertThrows(DataAccessException.class, () -> runtime.queryForObject("select salud_u.cerrar_jornada(?)", Integer.class, yesterday));
        assertThrows(DataAccessException.class, () -> runtime.queryForObject("select count(*) from salud_u.observacion_jornada", Integer.class));
    }

    @Test
    void theCloseOnlyDependsOnAgendaAndCalendarColumnsAndNeverMentionsClinicalTables() {
        // RN-34 / PA-23. El cuerpo SQL estándar hace que PostgreSQL registre cada columna usada en pg_depend.
        Set<String> used = new TreeSet<>(migrador.queryForList("""
            select c.relname || coalesce('.' || a.attname, '')
              from pg_depend d join pg_class c on c.oid = d.refobjid
              left join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid and d.refobjsubid > 0
             where d.classid = 'pg_proc'::regclass and d.objid = 'salud_u.cerrar_jornada(date)'::regprocedure
               and d.refclassid = 'pg_class'::regclass""", String.class));
        assertEquals(new TreeSet<>(Set.of(
            "cita.estado", "cita.id_cupo",
            "cupo_disponibilidad.capacidad", "cupo_disponibilidad.estado", "cupo_disponibilidad.id", "cupo_disponibilidad.id_especialidad",
            "cupo_disponibilidad.id_personal", "cupo_disponibilidad.inicia_a",
            "periodo_academico.fecha_fin", "periodo_academico.fecha_inicio", "periodo_academico.id", "periodo_academico.tipo",
            "solicitud_cita.id_especialidad", "solicitud_cita.solicitado_en",
            "observacion_jornada.actualizada_en", "observacion_jornada.asistencias", "observacion_jornada.ausencias",
            "observacion_jornada.cancelaciones", "observacion_jornada.capacidad", "observacion_jornada.cerrada_en",
            "observacion_jornada.citas_programadas", "observacion_jornada.fecha", "observacion_jornada.id",
            "observacion_jornada.id_especialidad", "observacion_jornada.id_periodo_academico", "observacion_jornada.id_personal",
            "observacion_jornada.sin_registrar", "observacion_jornada.solicitudes_ingresadas", "observacion_jornada.tipo_periodo")), used);
        assertEquals(0, migrador.queryForObject("select count(*) from pg_proc p where p.oid='salud_u.cerrar_jornada(date)'::regprocedure and p.prosqlbody is null", Integer.class),
            "cerrar_jornada debe tener cuerpo SQL estándar para que pg_depend sea completo");

        String close = migrador.queryForObject("select pg_get_functiondef('salud_u.cerrar_jornada(date)'::regprocedure)", String.class);
        assertEquals(Set.of("cerrar_jornada", "cita", "cupo_disponibilidad", "observacion_jornada", "periodo_academico", "solicitud_cita"), schemaNames(close));
        String recent = migrador.queryForObject("select prosrc from pg_proc where oid='salud_u.cerrar_jornadas_recientes()'::regprocedure", String.class);
        assertEquals(Set.of("cerrar_jornada"), schemaNames(recent), "La entrada nocturna solo delega en cerrar_jornada");
        Pattern clinical = Pattern.compile("paciente|derivaci|encuentro|diagn|antecedente|documento|ficha|historia|medicion|vacun|consentimiento|motivo|adenda", Pattern.CASE_INSENSITIVE);
        assertFalse(clinical.matcher(close).find(), close);
        assertFalse(clinical.matcher(recent).find(), recent);
    }

    @Test
    void everyRequestCarriesItsSpecialtyExceptTheInitialReview() {
        UUID patient = patient(), specialty = specialty();
        for (String[] invalid : new String[][] { {"DERIVACION", null}, {"ESPECIALIDAD", null}, {"INICIAL", specialty.toString()} })
            assertThrows(DataAccessException.class, () -> migrador.update(
                "insert into salud_u.solicitud_cita(id_paciente,tipo_cita,id_especialidad,origen,estado,solicitado_por) values (?,?,cast(? as uuid),'INICIAL','CANCELADA',?)",
                patient, invalid[0], invalid[1], DOCTOR));
        String source = migrador.queryForObject("select prosrc from pg_proc where oid='salud_u.crear_solicitud_derivacion(uuid,uuid)'::regprocedure", String.class);
        assertTrue(source.contains("d.id_especialidad"), "La solicitud por derivación copia la especialidad de su derivación");
    }

    private static Set<String> schemaNames(String text) {
        Set<String> names = new TreeSet<>();
        Matcher matcher = Pattern.compile("salud_u\\.([a-z_]+)").matcher(text);
        while (matcher.find()) names.add(matcher.group(1));
        return names;
    }

    private static int close(LocalDate day) {
        return migrador.queryForObject("select salud_u.cerrar_jornada(?)", Integer.class, day);
    }

    private static List<Integer> counts(LocalDate day, UUID staff, UUID specialty) {
        return migrador.queryForObject("""
            select array[capacidad, citas_programadas, asistencias, ausencias, sin_registrar, cancelaciones]
              from salud_u.observacion_jornada where fecha=? and id_personal=? and id_especialidad is not distinct from ?""",
            (rs, n) -> List.of((Integer[]) rs.getArray(1).getArray()), day, staff, specialty);
    }

    private static List<Integer> countsWithRequests(LocalDate day, UUID specialty) {
        return migrador.queryForObject("""
            select array[capacidad, citas_programadas, asistencias, ausencias, sin_registrar, cancelaciones, solicitudes_ingresadas]
              from salud_u.observacion_jornada where fecha=? and id_personal is null and id_especialidad is not distinct from ?""",
            (rs, n) -> List.of((Integer[]) rs.getArray(1).getArray()), day, specialty);
    }

    private static List<Map<String, Object>> snapshot(LocalDate day) {
        return migrador.queryForList("select * from salud_u.observacion_jornada where fecha=? order by id", day);
    }

    private static OffsetDateTime at(LocalDate day, String time) {
        return OffsetDateTime.parse(day + "T" + (time.length() == 5 ? time + ":00" : time) + "-04:00");
    }

    private static UUID specialty() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,?,?)", id, "O02-" + id, "Especialidad O02 " + id);
        return id;
    }

    private static UUID staff() {
        UUID principal = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O02')", principal, principal + "@example.invalid");
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "O02-" + id);
        return id;
    }

    private static UUID patient() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,'Paciente','O02',?,?)",
            id, "O02-" + id, "O02" + id, "REG-" + id, "REG" + id, DOCTOR, DOCTOR);
        return id;
    }

    private static UUID slot(UUID staff, UUID specialty, OffsetDateTime start, int capacity, String state) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,?,?,?,?,?)",
            id, staff, specialty, start, start.plusMinutes(30), capacity, state, state.equals("BORRADOR") ? null : start.minusDays(7), DOCTOR);
        return id;
    }

    private static void appointment(UUID slot, UUID staff, String state) {
        Map<String, Object> cupo = migrador.queryForMap("select inicia_a, id_especialidad from salud_u.cupo_disponibilidad where id=?", slot);
        migrador.update("insert into salud_u.cita(id_paciente,id_cupo,id_personal_asignado,tipo_cita,estado,programada_para) values (?,?,?,?,?,?)",
            patient(), slot, staff, cupo.get("id_especialidad") == null ? "INICIAL" : "ESPECIALIDAD", state, cupo.get("inicia_a"));
    }

    private static void request(String type, UUID specialty, OffsetDateTime at) {
        migrador.update("insert into salud_u.solicitud_cita(id_paciente,tipo_cita,id_especialidad,origen,estado,solicitado_en,solicitado_por) values (?,?,?,?,'CANCELADA',?,?)",
            patient(), type, specialty, type.equals("ESPECIALIDAD") ? "DIRECTA_ADMINISTRACION" : "INICIAL", at, DOCTOR);
    }
}

package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.temporal.TemporalAdjusters;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/** O-08: indicadores del componente de optimización (RF-41, cuadro 3.70). */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class MetricasAgendaIntegrationTest {
    @Container static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withInitScript("notificaciones/crear-rol-runtime.sql")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
    private static final UUID DOCTOR = UUID.randomUUID();
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;
    @Autowired com.zaxxer.hikari.HikariDataSource runtimeDataSource;
    private static com.zaxxer.hikari.HikariDataSource runtimePool;
    private JdbcTemplate migrador;

    @DynamicPropertySource
    static void properties(DynamicPropertyRegistry registry) throws Exception {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", () -> "salud_u_runtime");
        registry.add("spring.datasource.password", () -> "runtime-test-password");
        registry.add("spring.flyway.url", POSTGRES::getJdbcUrl);
        registry.add("spring.flyway.user", () -> "salud_u_migrator");
        registry.add("spring.flyway.password", () -> "migrator-test-password");
        registry.add("salud-u.auth.cookie-secure", () -> false);
        String documents = Files.createTempDirectory("salud-u-o08-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "MetricasAgendaIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O08') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
    }

    private static final java.time.ZoneId BOLIVIA = java.time.ZoneId.of("America/La_Paz");

    @Test
    void metricsCountIdlePlacesWaitOverloadSuggestionsNoticesAndEvaluateTheForecasts() throws Exception {
        LocalDate today = LocalDate.now(BOLIVIA), day = today.minusDays(10);
        UUID specialty = specialty(), rivas = staff("Dra. Rivas"), paz = staff("Dr. Paz");
        Actor admin = actor("ADMINISTRATIVE");
        // Rivas: 10 lugares, 6 llegan y 2 faltan → 4 ociosos. Paz: el médico definió 10 y Administración subió a 12;
        // llegan 11 → 1 ocioso y sobrecarga, porque 11 supera lo que definió el médico.
        observation(day, rivas, specialty, 10, 6, 2, null);
        observation(day, paz, specialty, 12, 11, 1, null);
        observation(day, null, specialty, 22, 17, 3, 15);
        observation(day.minusWeeks(1), null, specialty, 20, 0, 0, 20);          // historia: fuera del período
        observation(today.minusDays(40), rivas, specialty, 10, 0, 10, null);    // fuera del período
        decision(suggestion("SOBRECUPO", day, paz, specialty, "now() - interval '9 days'"), "ACEPTADA", "{\"capacidad\":12,\"sobrecupo\":2}", admin);
        decision(suggestion("SOBRECUPO", today.plusDays(1), rivas, specialty, "now() + interval '1 day'"), "MODIFICADA", "{\"capacidad\":11,\"sobrecupo\":1}", admin);
        decision(suggestion("ALERTA_CAPACIDAD", day, null, specialty, "now() - interval '9 days'"), "RECHAZADA", null, admin);
        suggestion("CUPOS_JORNADA", day, rivas, specialty, "now() - interval '9 days'");                  // vencida sin decidir
        suggestion("CUPOS_JORNADA", today.plusDays(2), rivas, specialty, "now() + interval '2 days'");    // pendiente
        suggestion("CUPOS_JORNADA", today.minusDays(31), rivas, specialty, "now() - interval '30 days'"); // fuera del período
        // Esperas de 4 y 2 días asignadas en el período; una asignada hace 20 días no cuenta.
        request(4, "now() - interval '1 day'");
        request(2, "now()"); // now(): sigue siendo de hoy aunque la prueba corra pasada la medianoche.
        request(9, "now() - interval '20 days'");
        UUID student = UUID.randomUUID(), studentPatient = patient(student), avisos = staff("Dr. Avisos");
        UUID first = booking(studentPatient, slot(avisos, null, OffsetDateTime.now().plusDays(3)));
        UUID second = booking(studentPatient, slot(avisos, null, OffsetDateTime.now().plusDays(4)));
        migrador.update("delete from salud_u.notificacion where id_cita in (?,?)", first, second);
        notice(student, first, "CITA_ASIGNADA", "ENTREGADA");
        notice(student, second, "CITA_ASIGNADA", "PENDIENTE");
        notice(student, first, "CITA_REPROGRAMADA", "LEIDA");

        JsonNode data = metrics(admin, "?from=" + today.minusDays(14) + "&to=" + today.plusDays(3)).path("data");
        assertEquals(today.minusDays(14).toString(), data.path("from").asText());
        assertEquals("o03-v1", data.path("modelVersion").asText());
        assertEquals(json.readTree("{\"days\":2,\"publishedPlaces\":22,\"idlePlaces\":5,\"rate\":0.2273}"), data.path("idlePlaces"));
        assertEquals(json.readTree("{\"assignedRequests\":2,\"averageDays\":3.0,\"medianDays\":3.0,\"p90Days\":3.8}"), data.path("waitTime"));
        assertEquals(json.readTree("{\"days\":2,\"overloadedDays\":1,\"rate\":0.5,\"maxRisk\":0.2,\"daysWithOverbooking\":1}"), data.path("overload"));
        // Sin historia de los médicos el pronóstico es 0,8, igual que la línea base: (17·0,04 + 3·0,64) / 20 = 0,13.
        assertEquals(json.readTree("{\"appointments\":20,\"brierScore\":0.13,\"baselineBrierScore\":0.13,\"skill\":0.0}"), data.path("attendanceCalibration"));
        // Demanda: la semana anterior dejó 20 (0,3·20 + 0,7·20); llegaron 15 → error 5, igual que repetir la semana anterior.
        assertEquals(json.readTree("{\"days\":1,\"meanAbsoluteError\":5.0,\"comparableDays\":1,\"comparableMeanAbsoluteError\":5.0,\"baselineMeanAbsoluteError\":5.0}"), data.path("demandError"));
        JsonNode suggestions = data.path("suggestions");
        assertEquals(List.of(5, 1, 1, 1, 1, 1), List.of(suggestions.path("issued").asInt(), suggestions.path("accepted").asInt(), suggestions.path("modified").asInt(),
            suggestions.path("rejected").asInt(), suggestions.path("expired").asInt(), suggestions.path("pending").asInt()));
        assertEquals(0.4, suggestions.path("acceptanceRate").asDouble());
        assertEquals(json.readTree("[{\"type\":\"CAPACITY_ALERT\",\"issued\":1,\"accepted\":0,\"modified\":0,\"rejected\":1,\"expired\":0,\"pending\":0},"
            + "{\"type\":\"DAY_SLOTS\",\"issued\":2,\"accepted\":0,\"modified\":0,\"rejected\":0,\"expired\":1,\"pending\":1},"
            + "{\"type\":\"OVERBOOKING\",\"issued\":2,\"accepted\":1,\"modified\":1,\"rejected\":0,\"expired\":0,\"pending\":0}]"), suggestions.path("byType"));
        assertEquals(json.readTree("{\"registered\":3,\"delivered\":2,\"read\":1,\"readRate\":0.5,\"byType\":["
            + "{\"eventType\":\"APPOINTMENT_ASSIGNED\",\"registered\":2,\"delivered\":1,\"read\":0},"
            + "{\"eventType\":\"APPOINTMENT_RESCHEDULED\",\"registered\":1,\"delivered\":1,\"read\":1}]}"), data.path("notifications"));

        // Período por defecto: los 30 días que terminan ayer; no incluye lo futuro ni lo de hoy.
        JsonNode recent = metrics(admin, "").path("data");
        assertEquals(today.minusDays(1).toString(), recent.path("to").asText());
        assertEquals(today.minusDays(30).toString(), recent.path("from").asText());
        assertEquals(3, recent.path("suggestions").path("issued").asInt());
        assertEquals(0, recent.path("notifications").path("registered").asInt());
        assertEquals(2, recent.path("waitTime").path("assignedRequests").asInt(), "La de hace 20 días entra; la de ahora es de hoy");
    }

    @Test
    void anEmptyPeriodHasNullRatesAndInvalidRequestsAreRejected() throws Exception {
        Actor admin = actor("ADMINISTRATIVE");
        JsonNode empty = metrics(admin, "?from=2020-01-01&to=2020-01-31").path("data");
        assertEquals(0, empty.path("idlePlaces").path("days").asInt());
        assertTrue(empty.path("idlePlaces").path("rate").isNull());
        assertTrue(empty.path("waitTime").path("averageDays").isNull());
        assertTrue(empty.path("attendanceCalibration").path("brierScore").isNull());
        assertTrue(empty.path("attendanceCalibration").path("skill").isNull());
        assertTrue(empty.path("demandError").path("meanAbsoluteError").isNull());
        assertTrue(empty.path("suggestions").path("acceptanceRate").isNull());
        assertEquals(0, empty.path("suggestions").path("byType").size());
        assertTrue(empty.path("notifications").path("readRate").isNull());

        for (String query : List.of("?from=2026-02-01&to=2026-01-01", "?from=2025-01-01&to=2026-06-01", "?from=ayer", "?to=2026-13-01"))
            mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/metrics" + query).with(authentication(admin.auth())))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("Indica un período de hasta 366 días con fechas AAAA-MM-DD, la inicial antes que la final."));
        for (String role : List.of("STUDENT", "REVIEW_DOCTOR", "SPECIALIST"))
            mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/metrics").with(authentication(actor(role).auth()))).andExpect(status().isForbidden());
        mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/metrics")).andExpect(status().isUnauthorized());
        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        assertThrows(org.springframework.dao.DataAccessException.class,
            () -> runtime.queryForList("select * from salud_u.metricas_agenda(current_date - 1, current_date)"), "Sin actor administrativo");
    }

    private JsonNode metrics(Actor actor, String query) throws Exception {
        return json.readTree(mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/metrics" + query).with(authentication(actor.auth())))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store, private")).andReturn().getResponse().getContentAsString());
    }

    private void observation(LocalDate day, UUID staff, UUID specialty, int capacity, int arrivals, int absences, Integer requests) {
        migrador.update("insert into salud_u.observacion_jornada(fecha,id_personal,id_especialidad,capacidad,citas_programadas,asistencias,ausencias,sin_registrar,cancelaciones,solicitudes_ingresadas,cerrada_en) values (?,?,?,?,?,?,?,0,0,?,now())",
            day, staff, specialty, capacity, arrivals + absences, arrivals, absences, requests);
    }

    private UUID suggestion(String type, LocalDate day, UUID staff, UUID specialty, String expires) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.sugerencia_agenda(id,tipo,fecha,id_personal,id_especialidad,valor_sugerido,explicacion,version_modelo,vence_en) values (?,?,?,?,?,'{}'::jsonb,'Prueba O08','o04-v1'," + expires + ")",
            id, type, day, staff, specialty);
        return id;
    }

    private void decision(UUID suggestion, String decision, String applied, Actor actor) {
        migrador.update("insert into salud_u.decision_sugerencia(id_sugerencia,decision,motivo,valor_aplicado,decidida_por) values (?,?,?,cast(? as jsonb),?)",
            suggestion, decision, "ACEPTADA".equals(decision) ? null : "Prueba O08", applied, actor.id());
    }

    /** Solicitud asignada a una cita que empieza {@code days} días después de pedirla. */
    private void request(int days, String assigned) {
        UUID requester = actor("STUDENT").id(), patient = patient(null), id = UUID.randomUUID();
        OffsetDateTime requested = migrador.queryForObject("select " + assigned + " - interval '1 hour'", OffsetDateTime.class);
        UUID appointment = booking(patient, slot(staff("Dr. Espera"), null, requested.plusDays(days).isAfter(OffsetDateTime.now()) ? requested.plusDays(days) : OffsetDateTime.now().plusDays(1)));
        migrador.update("update salud_u.cita set programada_para=? where id=?", requested.plusDays(days), appointment);
        migrador.update("insert into salud_u.solicitud_cita(id,id_paciente,tipo_cita,estado,solicitado_en,solicitado_por,id_cita,asignado_en,asignado_por) values (?,?,'INICIAL','ASIGNADA',?,?,?," + assigned + ",?)",
            id, patient, requested, requester, appointment, DOCTOR);
    }

    private void notice(UUID recipient, UUID appointment, String event, String state) {
        migrador.update("insert into salud_u.notificacion(id_destinatario,id_cita,tipo_evento,asunto,mensaje,estado,entregada_en,leida_en) values (?,?,?,'Aviso O08','Mensaje O08',?,"
            + ("PENDIENTE".equals(state) ? "null" : "now() - interval '1 hour'") + "," + ("LEIDA".equals(state) ? "now()" : "null") + ")",
            recipient, appointment, event, state);
    }

    private UUID slot(UUID staff, UUID specialty, OffsetDateTime start) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,?,1,'PUBLICADO',now(),?)",
            id, staff, specialty, start, start.plusMinutes(30), DOCTOR);
        return id;
    }

    private UUID booking(UUID patient, UUID slot) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) select ?, ?, u.id, 'INICIAL', u.id_personal, u.inicia_a from salud_u.cupo_disponibilidad u where u.id=?",
            id, patient, slot);
        migrador.update("update salud_u.cupo_disponibilidad set cantidad_reservada=cantidad_reservada+1 where id=?", slot);
        return id;
    }

    private UUID patient(UUID principal) {
        UUID id = UUID.randomUUID();
        if (principal != null) migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Estudiante O08')", principal, principal + "@example.invalid");
        migrador.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por,id_principal) values (?,?,?,?,?,'Paciente','O08',?,?,?)",
            id, "O08-" + id, "O08" + id, "REG-" + id, "REG" + id, DOCTOR, DOCTOR, principal);
        return id;
    }

    private UUID specialty() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,?,?)", id, "O08-" + id, "Especialidad O08 " + id);
        return id;
    }

    private UUID staff(String name) {
        UUID principal = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", principal, principal + "@example.invalid", name);
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "O08-" + id);
        return id;
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor O08')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor O08", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

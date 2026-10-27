package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.scheduling.application.ScheduleSuggestionService;
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

/** O-06: decidir una sugerencia (RN-33, RF-41, PA-21, PA-22). */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class DecisionSugerenciaIntegrationTest {
    @Container static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withInitScript("notificaciones/crear-rol-runtime.sql")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
    private static final UUID DOCTOR = UUID.randomUUID();
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;
    @Autowired ScheduleSuggestionService suggestions;
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
        String documents = Files.createTempDirectory("salud-u-o06-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "DecisionSugerenciaIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O06') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
    }

    @Test
    void pa22AcceptingTheOverbookingRaisesTheLatestSlotOnceAndFreezesTheDay() throws Exception {
        Day day = overbookedDay(LocalDate.parse("2071-03-02"));
        Actor admin = actor("ADMINISTRATIVE");
        String endsBefore = migrador.queryForObject("select string_agg(termina_a::text, ',' order by inicia_a) from salud_u.cupo_disponibilidad where id_personal=?", String.class, day.staff());

        JsonNode decided = decide(admin, day.overbooking(), "{\"decision\":\"ACCEPTED\"}").andExpect(status().isOk()).andReturn().getResponse().getContentAsString().transform(this::read).path("data");
        assertEquals("ACCEPTED", decided.path("status").asText());
        assertEquals(admin.id().toString(), decided.at("/decision/decidedBy").asText());
        assertEquals("Actor O06", decided.at("/decision/decidedByName").asText());
        assertTrue(decided.at("/decision/reason").isNull());
        assertEquals(1, decided.at("/decision/appliedValue/overbooking").asInt());
        assertEquals(10, decided.at("/decision/appliedValue/capacity").asInt());
        assertEquals(day.slots().getLast().toString(), decided.at("/decision/appliedValue/slots/0/slotId").asText());
        assertEquals(1, decided.at("/decision/appliedValue/slots/0/currentCapacity").asInt());
        assertEquals(2, decided.at("/decision/appliedValue/slots/0/appliedCapacity").asInt());
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 2), capacities(day.staff()));
        assertEquals(endsBefore, migrador.queryForObject("select string_agg(termina_a::text, ',' order by inicia_a) from salud_u.cupo_disponibilidad where id_personal=?", String.class, day.staff()),
            "La duración de los cupos no cambia");
        // Audita sin el motivo (el detalle no admite texto libre).
        String detail = migrador.queryForObject("select detalles::text from salud_u.evento_auditoria where accion='SUGERENCIA_AGENDA_DECIDIDA' and id_recurso=?", String.class, day.overbooking());
        assertTrue(detail.contains("\"sobrecupoAplicado\": 1") && detail.contains("\"decision\": \"ACEPTADA\""), detail);

        decide(admin, day.overbooking(), "{\"decision\":\"REJECTED\",\"reason\":\"Otra vez\"}")
            .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("La sugerencia ya tiene una decisión."));
        // La próxima generación no suma otro sobrecupo sobre la capacidad ya subida.
        suggestions.generate(day.monday());
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 2), capacities(day.staff()));
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.sugerencia_agenda where tipo='SOBRECUPO' and id_personal=?", Integer.class, day.staff()));
    }

    @Test
    void aModifiedOverbookingIsValidatedAgainstTheLimitTheDayAndItsCurrentCapacity() throws Exception {
        Day day = overbookedDay(LocalDate.parse("2072-03-01"));
        Actor admin = actor("ADMINISTRATIVE");
        String first = day.slots().getFirst().toString(), second = day.slots().get(1).toString();
        decide(admin, day.overbooking(), "{\"decision\":\"MODIFIED\",\"slots\":[{\"slotId\":\"" + first + "\",\"capacity\":2}]}")
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("Indica el motivo para modificar o rechazar la sugerencia."));
        decide(admin, day.overbooking(), "{\"decision\":\"MODIFIED\",\"reason\":\"Dos más\",\"slots\":[{\"slotId\":\"" + first + "\",\"capacity\":2},{\"slotId\":\"" + second + "\",\"capacity\":2}]}")
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("El sobrecupo supera el 10 % de la capacidad de la jornada (RN-35)."));
        decide(admin, day.overbooking(), "{\"decision\":\"MODIFIED\",\"reason\":\"Igual\",\"slots\":[{\"slotId\":\"" + first + "\",\"capacity\":1}]}")
            .andExpect(status().isBadRequest());
        decide(admin, day.overbooking(), "{\"decision\":\"MODIFIED\",\"reason\":\"Otro día\",\"slots\":[{\"slotId\":\"" + slots(day.staff(), day.specialty(), day.date().plusDays(1), 1).getFirst() + "\",\"capacity\":2}]}")
            .andExpect(status().isConflict());
        decide(admin, day.overbooking(), "{\"decision\":\"ACCEPTED\",\"slots\":[{\"slotId\":\"" + first + "\",\"capacity\":2}]}").andExpect(status().isBadRequest());
        decide(admin, day.overbooking(), "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[{\"slotId\":\"" + first + "\",\"capacity\":2,\"extra\":1}]}").andExpect(status().isBadRequest());
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 1), capacities(day.staff()), "Ningún intento fallido cambió la agenda");

        // Si la jornada cambió desde la sugerencia, el tope ya no es el que vio el modelo.
        migrador.update("update salud_u.cupo_disponibilidad set capacidad=2 where id=?", day.slots().get(4));
        decide(admin, day.overbooking(), "{\"decision\":\"ACCEPTED\"}").andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("La jornada cambió desde que se generó la sugerencia; se actualizará en la próxima generación."));
        migrador.update("update salud_u.cupo_disponibilidad set capacidad=1 where id=?", day.slots().get(4));

        JsonNode modified = read(decide(admin, day.overbooking(), "{\"decision\":\"MODIFIED\",\"reason\":\"El médico prefiere el primer horario\",\"slots\":[{\"slotId\":\"" + first + "\",\"capacity\":2}]}")
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("data");
        assertEquals("MODIFIED", modified.path("status").asText());
        assertEquals("El médico prefiere el primer horario", modified.at("/decision/reason").asText());
        assertEquals(first, modified.at("/decision/appliedValue/slots/0/slotId").asText());
        assertEquals(List.of(2, 1, 1, 1, 1, 1, 1, 1, 1, 1), capacities(day.staff()));
    }

    @Test
    void rejectionsAndReviewOnlySuggestionsLeaveTheAgendaUntouched() throws Exception {
        Day day = overbookedDay(LocalDate.parse("2073-03-01"));
        Actor admin = actor("ADMINISTRATIVE");
        decide(admin, day.overbooking(), "{\"decision\":\"REJECTED\"}").andExpect(status().isBadRequest());
        decide(admin, day.overbooking(), "{\"decision\":\"REJECTED\",\"reason\":\"   \"}").andExpect(status().isBadRequest());
        JsonNode rejected = read(decide(admin, day.overbooking(), "{\"decision\":\"REJECTED\",\"reason\":\"Jornada con procedimientos largos\"}")
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("data");
        assertEquals("REJECTED", rejected.path("status").asText());
        assertTrue(rejected.at("/decision/appliedValue").isNull());
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 1), capacities(day.staff()));

        UUID daySlots = migrador.queryForObject("select id from salud_u.sugerencia_agenda where tipo='CUPOS_JORNADA' and id_personal=?", UUID.class, day.staff());
        decide(admin, daySlots, "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[{\"slotId\":\"" + day.slots().getFirst() + "\",\"capacity\":2}]}")
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("La decisión no es válida para esta sugerencia."));
        decide(admin, daySlots, "{\"decision\":\"ACCEPTED\"}").andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("ACCEPTED"));
        decide(admin, daySlots, "{\"decision\":\"EXPIRED\"}").andExpect(status().isBadRequest()); // VENCIDA solo la marca el sistema
        decide(admin, daySlots, "{\"decision\":\"REJECTED\",\"reason\":\"Tarde\"}").andExpect(status().isConflict());
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 1), capacities(day.staff()));

        UUID request = UUID.randomUUID();
        migrador.update("insert into salud_u.sugerencia_agenda(id,tipo,fecha,valor_sugerido,explicacion,version_modelo,vence_en) values (?,'CUPO_SOLICITUD',?,'{}','x','o05-v1',now()+interval '1 day')", request, day.date());
        decide(admin, request, "{\"decision\":\"ACCEPTED\"}").andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("Este tipo de sugerencia todavía no se puede decidir."));
    }

    @Test
    void pa21UndecidedSuggestionsExpireAndCanNoLongerBeDecided() throws Exception {
        Actor admin = actor("ADMINISTRATIVE");
        UUID specialty = specialty(), staff = staff("Dra. Vence");
        List<UUID> slots = slots(staff, specialty, LocalDate.parse("2074-03-05"), 10);
        UUID late = UUID.randomUUID();
        migrador.update("insert into salud_u.sugerencia_agenda(id,tipo,fecha,id_personal,id_especialidad,valor_sugerido,explicacion,version_modelo,vence_en) values (?,'SOBRECUPO','2074-03-05',?,?,?::jsonb,'x','o04-v1',now()-interval '1 minute')",
            late, staff, specialty, "{\"capacidad\":10,\"sobrecupo\":1,\"cupos\":[{\"id_cupo\":\"" + slots.getLast() + "\",\"capacidad_actual\":1,\"capacidad_sugerida\":2}]}");
        decide(admin, late, "{\"decision\":\"ACCEPTED\"}").andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("La sugerencia venció sin decisión; la agenda no cambió."));
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 1), capacities(staff));
        assertTrue(suggestions.expire() >= 1);
        assertEquals(0, suggestions.expire(), "Marcar vencidas es idempotente");
        assertEquals("VENCIDA", migrador.queryForObject("select decision from salud_u.decision_sugerencia where id_sugerencia=?", String.class, late));
        JsonNode listed = read(mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/suggestions").param("date", "2074-03-05").with(authentication(admin.auth())))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("data").get(0);
        assertEquals("EXPIRED", listed.path("status").asText());
        assertTrue(listed.at("/decision/decidedBy").isNull());
        decide(admin, late, "{\"decision\":\"ACCEPTED\"}").andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("La sugerencia ya tiene una decisión."));
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 1), capacities(staff));
    }

    @Test
    void onlyAdministrationDecidesWithCsrfAndAValidBody() throws Exception {
        Day day = overbookedDay(LocalDate.parse("2075-03-04"));
        for (String role : List.of("STUDENT", "REVIEW_DOCTOR", "SPECIALIST", "REPORTING_OFFICER"))
            decide(actor(role), day.overbooking(), "{\"decision\":\"ACCEPTED\"}").andExpect(status().isForbidden());
        Actor admin = actor("ADMINISTRATIVE");
        mvc.perform(MockMvcRequestBuilders.post("/api/scheduling/suggestions/" + day.overbooking() + "/decision").with(authentication(admin.auth()))
            .contentType("application/json").content("{\"decision\":\"ACCEPTED\"}")).andExpect(status().isForbidden());
        decide(admin, UUID.randomUUID(), "{\"decision\":\"ACCEPTED\"}").andExpect(status().isNotFound());
        for (String invalid : List.of("[]", "{}", "{\"decision\":1}", "{\"decision\":\"ACCEPTED\",\"other\":1}", "{\"decision\":\"ACCEPTED\",\"reason\":3}",
                "{\"decision\":\"ACEPTADA\"}", "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[]}",
                "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[{\"slotId\":\"no\",\"capacity\":2}]}"))
            decide(admin, day.overbooking(), invalid).andExpect(status().isBadRequest());
        decide(admin, day.overbooking(), "{\"decision\":\"ACCEPTED\",\"reason\":\"" + "x".repeat(501) + "\"}").andExpect(status().isBadRequest());
        assertEquals(List.of(1, 1, 1, 1, 1, 1, 1, 1, 1, 1), capacities(day.staff()));
        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForObject(
            "select salud_u.decidir_sugerencia_agenda(?, 'ACCEPTED', null, null)", Object.class, day.overbooking()));
    }

    private record Day(LocalDate monday, LocalDate date, UUID specialty, UUID staff, List<UUID> slots, UUID overbooking) {}

    /** Jornada de 10 cupos de 1 con 60 % de asistencia: el modelo sugiere 1 de sobrecupo en el último cupo. */
    private Day overbookedDay(LocalDate from) {
        LocalDate monday = from.with(TemporalAdjusters.nextOrSame(DayOfWeek.MONDAY)), date = monday.plusDays(1);
        UUID specialty = specialty(), staff = staff("Dra. Decide");
        List<UUID> slots = slots(staff, specialty, date, 10);
        estimate(specialty, staff, date, 6, 4);
        suggestions.generate(monday);
        UUID overbooking = migrador.queryForObject("select id from salud_u.sugerencia_agenda where tipo='SOBRECUPO' and id_personal=?", UUID.class, staff);
        return new Day(monday, date, specialty, staff, slots, overbooking);
    }

    private org.springframework.test.web.servlet.ResultActions decide(Actor actor, UUID id, String body) throws Exception {
        return mvc.perform(MockMvcRequestBuilders.post("/api/scheduling/suggestions/" + id + "/decision").with(authentication(actor.auth())).with(csrf())
            .contentType("application/json").content(body));
    }

    private List<Integer> capacities(UUID staff) {
        return migrador.queryForList("select capacidad from salud_u.cupo_disponibilidad where id_personal=? and inicia_a < (select min(inicia_a) + interval '1 day' from salud_u.cupo_disponibilidad where id_personal=?) order by inicia_a", Integer.class, staff, staff);
    }

    private JsonNode read(String body) {
        try { return json.readTree(body); } catch (Exception exception) { throw new IllegalStateException(exception); }
    }

    private void estimate(UUID specialty, UUID staff, LocalDate day, double alfa, double beta) {
        migrador.update("delete from salud_u.estimacion_agenda where id_personal=?", staff);
        migrador.update("insert into salud_u.estimacion_agenda(id_especialidad,id_personal,dia_semana,tipo_periodo,alfa_asistencia,beta_asistencia,citas_observadas,jornadas_observadas,ultima_fecha,asistencia_vigente,fuente_vigente,alfa_vigente,beta_vigente,version_modelo) values (?,?,?,null,?,?,30,3,'2020-01-01',?,'MEDICO',?,?,'o03-v1')",
            specialty, staff, day.getDayOfWeek().getValue(), alfa, beta, Math.round(1000 * alfa / (alfa + beta)) / 1000.0, alfa, beta);
    }

    private List<UUID> slots(UUID staff, UUID specialty, LocalDate day, int count) {
        List<UUID> ids = new ArrayList<>();
        for (int i = 0; i < count; i++) {
            UUID id = UUID.randomUUID();
            OffsetDateTime start = OffsetDateTime.parse(day + "T08:00:00-04:00").plusMinutes(30L * i);
            migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,?,1,'PUBLICADO',now(),?)",
                id, staff, specialty, start, start.plusMinutes(30), DOCTOR);
            ids.add(id);
        }
        return ids;
    }

    private UUID specialty() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,?,?)", id, "O06-" + id, "Especialidad O06 " + id);
        return id;
    }

    private UUID staff(String name) {
        UUID principal = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", principal, principal + "@example.invalid", name);
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "O06-" + id);
        return id;
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor O06')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor O06", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

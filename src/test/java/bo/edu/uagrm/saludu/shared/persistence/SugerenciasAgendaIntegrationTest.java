package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
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

/** O-04: sugerencias de cupos, sobrecupo y alertas de capacidad (RN-35, PV-7.4). */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class SugerenciasAgendaIntegrationTest {
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
        String documents = Files.createTempDirectory("salud-u-o04-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "SugerenciasAgendaIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O04') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
    }

    @Test
    void pv74LowAttendanceSuggestsOverbookingOnTheLatestSlotAndRegeneratesIdempotently() throws Exception {
        LocalDate monday = LocalDate.parse("2063-03-05").with(TemporalAdjusters.nextOrSame(DayOfWeek.MONDAY)), day = monday.plusDays(1);
        UUID specialty = specialty(), staff = staff("Dra. Rivas");
        List<UUID> slots = slots(staff, specialty, day, 10);
        estimate(specialty, staff, day, 6, 4);
        Actor admin = actor("ADMINISTRATIVE");

        assertTrue(suggestions.generate(monday) >= 2);
        JsonNode list = list(admin, day);
        JsonNode overbooking = only(list, "OVERBOOKING", staff), daySlots = only(list, "DAY_SLOTS", staff);
        assertEquals("Dra. Rivas", overbooking.path("staffName").asText());
        assertEquals("PENDING", overbooking.path("status").asText());
        assertEquals("o04-v1", overbooking.path("modelVersion").asText());
        assertEquals(1, overbooking.at("/suggestedValue/overbooking").asInt());
        assertEquals(11, overbooking.at("/suggestedValue/suggestedAppointments").asInt());
        assertEquals(slots.getLast().toString(), overbooking.at("/suggestedValue/slots/0/slotId").asText());
        assertEquals(2, overbooking.at("/suggestedValue/slots/0/suggestedCapacity").asInt());
        assertTrue(overbooking.at("/suggestedValue/saturationRisk").asDouble() <= 0.2);
        assertTrue(overbooking.path("explanation").asText().contains("asistencia estimada del 60 % (estimación del médico)"));
        assertEquals(10, daySlots.at("/suggestedValue/capacity").asInt());
        assertEquals(OffsetDateTime.parse(day + "T08:00:00-04:00").toInstant(), OffsetDateTime.parse(daySlots.path("expiresAt").asText()).toInstant());
        // La base guarda tipo y claves en español; la API recibe la traducción.
        assertEquals("SOBRECUPO", migrador.queryForObject("select tipo from salud_u.sugerencia_agenda where id=?", String.class, UUID.fromString(overbooking.path("id").asText())));
        assertEquals(2, migrador.queryForObject("select (valor_sugerido->'cupos'->0->>'capacidad_sugerida')::int from salud_u.sugerencia_agenda where id=?", Integer.class, UUID.fromString(overbooking.path("id").asText())));
        assertEquals(1, migrador.queryForObject("select capacidad from salud_u.cupo_disponibilidad where id=?", Integer.class, slots.getLast()),
            "Sugerir no cambia el cupo: se aplica al decidir (O-06)");

        assertEquals(0, suggestions.generate(monday), "Regenerar sin cambios no toca nada");
        assertEquals(overbooking.path("id"), only(list(admin, day), "OVERBOOKING", staff).path("id"));

        // Con asistencia alta el sobrecupo pendiente desaparece y la sugerencia de la jornada se actualiza.
        estimate(specialty, staff, day, 95, 5);
        suggestions.generate(monday);
        JsonNode high = list(admin, day);
        assertTrue(of(high, "OVERBOOKING", staff).isEmpty());
        assertEquals(daySlots.path("id"), only(high, "DAY_SLOTS", staff).path("id"));
        assertEquals(10, only(high, "DAY_SLOTS", staff).at("/suggestedValue/suggestedAppointments").asInt());
    }

    @Test
    void aDecidedOverbookingFreezesItsDayAndExpiredSuggestionsShowAsExpired() throws Exception {
        LocalDate monday = LocalDate.parse("2064-03-03").with(TemporalAdjusters.nextOrSame(DayOfWeek.MONDAY)), day = monday.plusDays(2);
        UUID specialty = specialty(), staff = staff("Dr. Paz");
        slots(staff, specialty, day, 10);
        estimate(specialty, staff, day, 6, 4);
        suggestions.generate(monday);
        UUID overbooking = migrador.queryForObject("select id from salud_u.sugerencia_agenda where tipo='SOBRECUPO' and id_personal=?", UUID.class, staff);
        migrador.update("insert into salud_u.decision_sugerencia(id_sugerencia,decision,decidida_por) values (?,'ACEPTADA',?)", overbooking, DOCTOR);
        // Aunque el cupo ya subió y la asistencia cambió, la jornada no se vuelve a sugerir ni se borra.
        migrador.update("update salud_u.cupo_disponibilidad set capacidad=2 where id_personal=? and inicia_a=(select max(inicia_a) from salud_u.cupo_disponibilidad where id_personal=?)", staff, staff);
        estimate(specialty, staff, day, 95, 5);
        String before = migrador.queryForObject("select string_agg(id::text||valor_sugerido::text, ',' order by id) from salud_u.sugerencia_agenda where id_personal=?", String.class, staff);
        suggestions.generate(monday);
        assertEquals(before, migrador.queryForObject("select string_agg(id::text||valor_sugerido::text, ',' order by id) from salud_u.sugerencia_agenda where id_personal=?", String.class, staff));
        Actor admin = actor("ADMINISTRATIVE");
        assertEquals("ACCEPTED", only(list(admin, day), "OVERBOOKING", staff).path("status").asText());
        assertEquals("PENDING", only(list(admin, day), "DAY_SLOTS", staff).path("status").asText());

        UUID old = UUID.randomUUID();
        migrador.update("insert into salud_u.sugerencia_agenda(id,tipo,fecha,id_personal,id_especialidad,valor_sugerido,explicacion,version_modelo,vence_en) values (?,'CUPOS_JORNADA','2020-01-07',?,?,'{\"capacidad\":3}','Vencida','o04-v1','2020-01-07 08:00-04')", old, staff, specialty);
        JsonNode expired = list(admin, LocalDate.parse("2020-01-07"));
        assertEquals("EXPIRED", expired.path("data").get(0).path("status").asText());
        assertEquals(3, expired.path("data").get(0).at("/suggestedValue/capacity").asInt());
    }

    @Test
    void capacityAlertsCompareProjectedDemandWithFreePublishedPlaces() throws Exception {
        LocalDate monday = LocalDate.parse("2065-03-02").with(TemporalAdjusters.nextOrSame(DayOfWeek.MONDAY));
        UUID noSupply = specialty(), balanced = specialty(), idle = specialty(), staff = staff("Dra. Vaca");
        for (int i = 0; i < 3; i++) pendingRequest(noSupply);
        slots(staff, balanced, monday.plusDays(1), 4); // Sin estimación: la demanda es la capacidad (DV-10), 100 %.
        UUID idleStaff = staff("Dr. Ortiz");
        slots(idleStaff, idle, monday.plusDays(3), 10);
        migrador.update("insert into salud_u.valor_inicial_agenda(id_especialidad,tipo_periodo,demanda_diaria_esperada,asistencia_esperada,peso_citas,registrado_por) select ?, t, 0.2, 0.8, 10, ? from unnest(array['INICIO_SEMESTRE','CLASES','EXAMENES','VACACIONES']) t", idle, DOCTOR);
        migrador.update("insert into salud_u.periodo_academico(nombre,tipo,fecha_inicio,fecha_fin,creado_por) values ('Clases 2065','CLASES',?,?,?)", monday, monday.plusDays(30), DOCTOR);
        suggestions.generate(monday);

        Actor admin = actor("ADMINISTRATIVE");
        JsonNode list = list(admin, monday);
        JsonNode shortage = alert(list, noSupply);
        assertEquals(true, shortage.at("/suggestedValue/demandExceedsSupply").asBoolean());
        assertEquals(3, shortage.at("/suggestedValue/pendingRequests").asInt());
        assertEquals(0, shortage.at("/suggestedValue/freePlaces").asInt());
        assertTrue(shortage.at("/suggestedValue/percentage").isNull());
        assertEquals(10, shortage.at("/suggestedValue/businessDays").asInt());
        assertEquals(monday.toString(), shortage.at("/suggestedValue/from").asText());
        assertTrue(shortage.path("explanation").asText().contains("no hay lugares libres publicados"));
        assertNull(alert(list, balanced), "Demanda igual a la capacidad: 100 %, sin alerta");
        JsonNode surplus = alert(list, idle);
        assertEquals(false, surplus.at("/suggestedValue/demandExceedsSupply").asBoolean());
        assertEquals(20.0, surplus.at("/suggestedValue/percentage").asDouble(), 0.001, "10 días × 0,2 = 2 de 10 lugares");
        assertTrue(surplus.path("explanation").asText().contains("menos de la mitad"));
        assertEquals("CAPACITY_ALERT", surplus.path("type").asText());
    }

    @Test
    void onlyAdministrationReadsSuggestionsAndTheRuntimeCannotTouchTheTables() throws Exception {
        for (String role : List.of("STUDENT", "REPORTING_OFFICER", "REVIEW_DOCTOR", "AUDITOR"))
            mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/suggestions").with(authentication(actor(role).auth()))).andExpect(status().isForbidden());
        mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/suggestions")).andExpect(status().isUnauthorized());
        mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/suggestions").param("date", "07/03/2063").with(authentication(actor("ADMINISTRATIVE").auth())))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("La fecha debe tener el formato AAAA-MM-DD."));
        mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/suggestions").with(authentication(actor("ADMINISTRATIVE").auth())))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store, private"));

        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        for (String sql : List.of("select count(*) from salud_u.sugerencia_agenda", "select count(*) from salud_u.decision_sugerencia"))
            assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForObject(sql, Integer.class));
        assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForList("select * from salud_u.listar_sugerencias_agenda(current_date)"));
        for (String invalid : List.of(
            "[{\"tipo\":\"RESCHEDULE\",\"fecha\":\"2070-01-06\",\"id_personal\":null,\"id_especialidad\":null,\"valor_sugerido\":{},\"explicacion\":\"x\",\"vence_en\":\"2070-01-07T00:00Z\"}]",
            "[{\"tipo\":\"CAPACITY_ALERT\",\"fecha\":\"2070-01-06\",\"id_personal\":null,\"id_especialidad\":null,\"valor_sugerido\":{\"capacity\":1},\"explicacion\":\"x\",\"vence_en\":\"2070-01-07T00:00Z\"}]",
            "[{\"tipo\":\"CAPACITY_ALERT\",\"fecha\":\"2070-02-06\",\"id_personal\":null,\"id_especialidad\":null,\"valor_sugerido\":{},\"explicacion\":\"x\",\"vence_en\":\"2070-01-07T00:00Z\"}]",
            "[{\"tipo\":\"ALERTA_CAPACIDAD\",\"fecha\":\"2070-01-06\",\"id_personal\":null,\"id_especialidad\":null,\"valor_sugerido\":{},\"explicacion\":\"x\",\"vence_en\":\"2070-01-07T00:00Z\"}]",
            "[{\"tipo\":\"DAY_SLOTS\",\"fecha\":\"2070-01-06\",\"id_personal\":null,\"id_especialidad\":null,\"valor_sugerido\":{},\"explicacion\":\"x\",\"vence_en\":\"2070-01-07T00:00Z\"}]"))
            assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForObject(
                "select salud_u.guardar_sugerencias_agenda(cast(? as jsonb),'o04-v1','2070-01-05','2070-01-16')", Integer.class, invalid));
    }

    @Test
    void generatorInputsOnlyReadAgendaCalendarAndEstimates() {
        // RN-34: igual que el cierre y la estimación, las sugerencias no leen tablas clínicas.
        var allowed = java.util.Set.of("cita", "cupo_disponibilidad", "solicitud_cita", "periodo_academico", "especialidad",
            "estimacion_agenda", "valor_inicial_agenda", "sugerencia_agenda", "decision_sugerencia",
            "a_codigo_api", "desde_codigo_api", "estimacion_vigente", "sobrecupo_decidido", "sugerencias_desde_json", "valor_sugerido_api",
            "guardar_sugerencias_agenda"); // nombre del bloqueo consultivo
        var pattern = java.util.regex.Pattern.compile("salud_u\\.([a-z_]+)");
        for (String function : List.of("jornadas_para_sugerencias", "demanda_para_alertas", "estimacion_vigente", "sobrecupo_decidido",
                "sugerencias_desde_json", "guardar_sugerencias_agenda", "valor_sugerido_api")) {
            String source = migrador.queryForObject("select prosrc from pg_proc where proname=? and pronamespace='salud_u'::regnamespace", String.class, function);
            var matcher = pattern.matcher(source);
            while (matcher.find()) assertTrue(allowed.contains(matcher.group(1)), function + " usa " + matcher.group(1));
        }
    }

    private JsonNode list(Actor actor, LocalDate day) throws Exception {
        return json.readTree(mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/suggestions").param("date", day.toString()).with(authentication(actor.auth())))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray());
    }

    private static List<JsonNode> of(JsonNode list, String type, UUID staff) {
        List<JsonNode> found = new ArrayList<>();
        list.path("data").forEach(s -> { if (s.path("type").asText().equals(type) && s.path("staffId").asText().equals(staff.toString())) found.add(s); });
        return found;
    }

    private static JsonNode only(JsonNode list, String type, UUID staff) {
        List<JsonNode> found = of(list, type, staff);
        assertEquals(1, found.size(), type);
        return found.getFirst();
    }

    private static JsonNode alert(JsonNode list, UUID specialty) {
        for (JsonNode s : list.path("data"))
            if (s.path("type").asText().equals("CAPACITY_ALERT") && s.path("specialtyId").asText().equals(specialty.toString())) return s;
        return null;
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

    private void pendingRequest(UUID specialty) {
        UUID patient = UUID.randomUUID();
        migrador.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,'Paciente','O04',?,?)",
            patient, "O04-" + patient, "O04" + patient, "REG-" + patient, "REG" + patient, DOCTOR, DOCTOR);
        migrador.update("insert into salud_u.solicitud_cita(id_paciente,tipo_cita,id_especialidad,origen,estado,solicitado_por) values (?,'ESPECIALIDAD',?,'DIRECTA_ADMINISTRACION','PENDIENTE',?)", patient, specialty, DOCTOR);
    }

    private UUID specialty() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,?,?)", id, "O04-" + id, "Especialidad O04 " + id);
        return id;
    }

    private UUID staff(String name) {
        UUID principal = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", principal, principal + "@example.invalid", name);
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "O04-" + id);
        return id;
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor O04')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor O04", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

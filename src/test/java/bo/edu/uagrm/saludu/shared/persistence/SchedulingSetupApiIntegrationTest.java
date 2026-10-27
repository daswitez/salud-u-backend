package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.util.List;
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
import org.springframework.test.web.servlet.ResultActions;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/** O-01: calendario académico y valores iniciales de la agenda, solo para Administración. */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class SchedulingSetupApiIntegrationTest {
    @Container static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withInitScript("notificaciones/crear-rol-runtime.sql")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
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
        String documents = Files.createTempDirectory("salud-u-o01-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "SchedulingSetupApiIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
    }

    @Test
    void administrationRegistersNonOverlappingPeriodsWithApiCodesAndAudit() throws Exception {
        Actor admin = actor("ADMINISTRATIVE");
        JsonNode created = body(post(admin, "/api/academic-periods",
            "{\"name\":\" Inicio 1/2031 \",\"type\":\"SEMESTER_START\",\"startDate\":\"2031-02-01\",\"endDate\":\"2031-02-14\"}").andExpect(status().isCreated()));
        assertEquals("Inicio 1/2031", created.at("/data/name").asText());
        assertEquals("SEMESTER_START", created.at("/data/type").asText());
        UUID id = UUID.fromString(created.at("/data/id").asText());
        assertEquals("INICIO_SEMESTRE", migrador.queryForObject("select tipo from salud_u.periodo_academico where id=?", String.class, id));

        // Un día compartido ya es solape, aunque el tipo sea otro.
        post(admin, "/api/academic-periods", "{\"name\":\"Clases\",\"type\":\"CLASSES\",\"startDate\":\"2031-02-14\",\"endDate\":\"2031-06-30\"}")
            .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("El período se superpone con otro ya registrado."));
        post(admin, "/api/academic-periods", "{\"name\":\"Clases\",\"type\":\"CLASSES\",\"startDate\":\"2031-02-15\",\"endDate\":\"2031-06-30\"}")
            .andExpect(status().isCreated());

        for (String invalid : List.of(
            "{\"name\":\"Clases\",\"type\":\"CLASES\",\"startDate\":\"2031-08-01\",\"endDate\":\"2031-08-30\"}",
            "{\"name\":\"Al revés\",\"type\":\"EXAMS\",\"startDate\":\"2031-08-30\",\"endDate\":\"2031-08-01\"}",
            "{\"name\":\"  \",\"type\":\"EXAMS\",\"startDate\":\"2031-08-01\",\"endDate\":\"2031-08-30\"}",
            "{\"name\":\"Largo\",\"type\":\"VACATION\",\"startDate\":\"2031-08-01\",\"endDate\":\"2032-12-30\"}",
            "{\"name\":\"Fecha\",\"type\":\"EXAMS\",\"startDate\":\"01/08/2031\",\"endDate\":\"2031-08-30\"}",
            "{\"name\":\"Extra\",\"type\":\"EXAMS\",\"startDate\":\"2031-08-01\",\"endDate\":\"2031-08-30\",\"createdBy\":\"x\"}"))
            post(admin, "/api/academic-periods", invalid).andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("Revisa el nombre, el tipo y las fechas del período."));

        JsonNode list = body(get(admin, "/api/academic-periods").andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store, private")));
        List<String> types = list.path("data").findValuesAsText("type");
        assertEquals(List.of("SEMESTER_START", "CLASSES"), types.subList(types.size() - 2, types.size()));
        assertEquals(2, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where id_actor=? and accion='PERIODO_ACADEMICO_REGISTRADO'", Integer.class, admin.id()));
        assertEquals("INICIO_SEMESTRE", migrador.queryForObject("select detalles->>'tipo' from salud_u.evento_auditoria where id_recurso=?", String.class, id));
    }

    @Test
    void initialValuesStartWithDv10DefaultsAndSaveAtomicallyWithAudit() throws Exception {
        Actor admin = actor("ADMINISTRATIVE");
        UUID specialty = specialty(true), inactive = specialty(false);
        JsonNode defaults = body(get(admin, "/api/scheduling/initial-values").andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store, private")));
        List<JsonNode> own = rows(defaults, specialty);
        assertEquals(List.of("SEMESTER_START", "CLASSES", "EXAMS", "VACATION"), own.stream().map(r -> r.path("periodType").asText()).toList());
        for (JsonNode row : own) {
            assertTrue(row.path("isDefault").asBoolean());
            assertTrue(row.path("expectedDailyDemand").isNull(), "La demanda por defecto es la capacidad publicada");
            assertEquals(0.8, row.path("expectedAttendance").asDouble());
            assertEquals(10, row.path("appointmentWeight").asInt());
        }
        assertEquals(4, rows(defaults, null).size(), "El área tiene una fila por tipo de período");
        assertTrue(rows(defaults, inactive).isEmpty(), "Una especialidad inactiva sin valores no se ofrece");

        String save = "{\"values\":[{\"specialtyId\":\"" + specialty + "\",\"periodType\":\"EXAMS\",\"expectedDailyDemand\":12.5,\"expectedAttendance\":0.9,\"appointmentWeight\":10},"
            + "{\"specialtyId\":null,\"periodType\":\"CLASSES\",\"expectedAttendance\":0.75,\"appointmentWeight\":15}]}";
        JsonNode saved = body(put(admin, "/api/scheduling/initial-values", save).andExpect(status().isOk()));
        JsonNode exams = rows(saved, specialty).get(2);
        assertFalse(exams.path("isDefault").asBoolean());
        assertEquals(12.5, exams.path("expectedDailyDemand").asDouble());
        assertEquals(0.9, exams.path("expectedAttendance").asDouble());
        JsonNode areaClasses = rows(saved, null).get(1);
        assertTrue(areaClasses.path("expectedDailyDemand").isNull());
        assertEquals(15, areaClasses.path("appointmentWeight").asInt());
        assertEquals("EXAMENES", migrador.queryForObject("select tipo_periodo from salud_u.valor_inicial_agenda where id_especialidad=?", String.class, specialty));
        assertEquals(2, audits(admin));

        // Repetir lo mismo no reescribe ni audita; cambiar un valor guarda el anterior en la auditoría.
        put(admin, "/api/scheduling/initial-values", save).andExpect(status().isOk());
        assertEquals(2, audits(admin));
        put(admin, "/api/scheduling/initial-values", "{\"values\":[{\"specialtyId\":\"" + specialty + "\",\"periodType\":\"EXAMS\",\"expectedDailyDemand\":null,\"expectedAttendance\":0.85,\"appointmentWeight\":10}]}")
            .andExpect(status().isOk());
        assertEquals(3, audits(admin));
        assertEquals("0.900", migrador.queryForObject("select detalles->'anterior'->>'asistenciaEsperada' from salud_u.evento_auditoria where id_actor=? and accion='VALOR_INICIAL_AGENDA_GUARDADO' order by ocurrido_en desc limit 1", String.class, admin.id()));

        // Una fila inválida anula todo el lote.
        String partial = "{\"values\":[{\"specialtyId\":null,\"periodType\":\"VACATION\",\"expectedAttendance\":0.5,\"appointmentWeight\":10},";
        for (String invalid : List.of(
            partial + "{\"periodType\":\"EXAMS\",\"expectedAttendance\":1,\"appointmentWeight\":10}]}",
            partial + "{\"periodType\":\"EXAMS\",\"expectedAttendance\":0.8125,\"appointmentWeight\":10}]}",
            partial + "{\"periodType\":\"EXAMS\",\"expectedAttendance\":0.8,\"appointmentWeight\":0}]}",
            partial + "{\"periodType\":\"EXAMS\",\"expectedDailyDemand\":-1,\"expectedAttendance\":0.8,\"appointmentWeight\":10}]}",
            partial + "{\"periodType\":\"EXAMENES\",\"expectedAttendance\":0.8,\"appointmentWeight\":10}]}",
            partial + "{\"specialtyId\":\"no-es-uuid\",\"periodType\":\"EXAMS\",\"expectedAttendance\":0.8,\"appointmentWeight\":10}]}",
            partial + "{\"periodType\":\"EXAMS\",\"expectedAttendance\":0.8,\"appointmentWeight\":10,\"registeredBy\":\"x\"}]}",
            partial + "{\"periodType\":\"EXAMS\",\"expectedAttendance\":\"0.8\",\"appointmentWeight\":10}]}",
            "{\"values\":[]}"))
            put(admin, "/api/scheduling/initial-values", invalid).andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("Los valores iniciales no son válidos."));
        put(admin, "/api/scheduling/initial-values", partial + "{\"specialtyId\":null,\"periodType\":\"VACATION\",\"expectedAttendance\":0.6,\"appointmentWeight\":10}]}")
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("Cada especialidad y tipo de período puede aparecer una sola vez."));
        put(admin, "/api/scheduling/initial-values", "{\"values\":[{\"specialtyId\":\"" + inactive + "\",\"periodType\":\"EXAMS\",\"expectedAttendance\":0.8,\"appointmentWeight\":10}]}")
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value("La especialidad no existe o no está habilitada."));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.valor_inicial_agenda where tipo_periodo='VACACIONES'", Integer.class));
        assertEquals(3, audits(admin));
    }

    @Test
    void onlyAdministrationReachesTheEndpointsAndTheRuntimeCannotTouchTheTables() throws Exception {
        for (String role : List.of("STUDENT", "REPORTING_OFFICER", "REVIEW_DOCTOR", "AUDITOR")) {
            Actor other = actor(role);
            get(other, "/api/academic-periods").andExpect(status().isForbidden());
            get(other, "/api/scheduling/initial-values").andExpect(status().isForbidden());
            post(other, "/api/academic-periods", "{\"name\":\"X\",\"type\":\"EXAMS\",\"startDate\":\"2035-01-01\",\"endDate\":\"2035-01-02\"}").andExpect(status().isForbidden());
            put(other, "/api/scheduling/initial-values", "{\"values\":[{\"periodType\":\"EXAMS\",\"expectedAttendance\":0.8,\"appointmentWeight\":10}]}").andExpect(status().isForbidden());
        }
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/academic-periods")).andExpect(status().isUnauthorized());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.periodo_academico where fecha_inicio='2035-01-01'", Integer.class));

        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        for (String sql : List.of("select count(*) from salud_u.periodo_academico", "select count(*) from salud_u.valor_inicial_agenda"))
            assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForObject(sql, Integer.class));
        // Sin contexto de actor administrativo, la función también rechaza.
        assertThrows(org.springframework.dao.DataAccessException.class,
            () -> runtime.queryForList("select * from salud_u.listar_periodos_academicos()"));
    }

    private int audits(Actor actor) {
        return migrador.queryForObject("select count(*) from salud_u.evento_auditoria where id_actor=? and accion='VALOR_INICIAL_AGENDA_GUARDADO'", Integer.class, actor.id());
    }

    private static List<JsonNode> rows(JsonNode response, UUID specialty) {
        String expected = specialty == null ? "null" : specialty.toString();
        List<JsonNode> rows = new java.util.ArrayList<>();
        response.path("data").forEach(row -> { if (row.path("specialtyId").asText("null").equals(expected)) rows.add(row); });
        return rows;
    }

    private UUID specialty(boolean active) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre,activo) values (?,?,?,?)", id, "O01-" + id, "Especialidad O01 " + id, active);
        return id;
    }

    private ResultActions get(Actor actor, String path) throws Exception {
        return mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get(path).with(authentication(actor.auth())));
    }

    private ResultActions post(Actor actor, String path, String content) throws Exception {
        return mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post(path).with(authentication(actor.auth())).with(csrf())
            .contentType("application/json").content(content));
    }

    private ResultActions put(Actor actor, String path, String content) throws Exception {
        return mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put(path).with(authentication(actor.auth())).with(csrf())
            .contentType("application/json").content(content));
    }

    private JsonNode body(ResultActions result) throws Exception {
        return json.readTree(result.andReturn().getResponse().getContentAsByteArray());
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor O01')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor O01", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

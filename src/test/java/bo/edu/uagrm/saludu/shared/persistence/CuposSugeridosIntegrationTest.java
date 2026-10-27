package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

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

/** O-05: cupos sugeridos para una solicitud (UC-07 extendido, RF-40). */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class CuposSugeridosIntegrationTest {
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
        String documents = Files.createTempDirectory("salud-u-o05-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "CuposSugeridosIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O05') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
        // Cada prueba ve solo sus cupos: los publicados por otras se cierran.
        migrador.update("update salud_u.cupo_disponibilidad set estado='CERRADO' where estado='PUBLICADO'");
    }

    private static final java.time.ZoneId BOLIVIA = java.time.ZoneId.of("America/La_Paz");

    @Test
    void urgentReferralGetsTheSoonestCompatibleSlotsAndRoutineTheEmptierDay() throws Exception {
        LocalDate today = LocalDate.now(BOLIVIA), tomorrow = today.plusDays(1), later = today.plusDays(10);
        UUID specialty = specialty("Cardiología O05"), other = specialty("Otra O05"), rivas = staff("Dra. Rivas"), paz = staff("Dr. Paz");
        UUID patient = patient();
        UUID referral = referral(patient, specialty, "URGENTE");
        UUID request = request(patient, "DERIVACION", specialty, referral);
        // Rivas mañana: 4 lugares, 3 ya tomados por otros pacientes; queda libre el de las 09:30.
        List<UUID> rivasSlots = slots(rivas, specialty, tomorrow, 4);
        for (int i = 0; i < 3; i++) booking(patient(), rivasSlots.get(i));
        // Paz en 10 días: 4 lugares libres, pero a las 08:00 el paciente ya tiene otra cita (en un cupo del área); como en
        // la asignación, esa cita ocupa una hora y deja fuera los cupos de las 08:00 y las 08:30.
        List<UUID> pazSlots = slots(paz, specialty, later, 4);
        booking(patient, slots(staff("Dr. Área"), null, later, 1).getFirst());
        slots(rivas, other, tomorrow.plusDays(1), 2);                     // otra especialidad
        slots(staff("Dra. Área"), null, tomorrow, 2);                     // área (revisión inicial)
        UUID past = slot(paz, specialty, OffsetDateTime.now().minusHours(1));  // ya empezó

        Actor admin = actor("ADMINISTRATIVE");
        String before = state();
        JsonNode urgent = suggested(admin, request).path("data");
        assertEquals(before, state(), "Consultar no cambia la agenda ni la solicitud");
        assertEquals("REFERRAL", urgent.path("appointmentType").asText());
        assertEquals("URGENT", urgent.path("priority").asText());
        assertEquals("o05-v1", urgent.path("modelVersion").asText());
        assertEquals(0.9, urgent.path("waitWeight").asDouble());
        assertEquals(0.1, urgent.path("occupancyWeight").asDouble());
        assertEquals(List.of(rivasSlots.get(3), pazSlots.get(2), pazSlots.get(3)), ids(urgent));
        JsonNode first = urgent.path("slots").get(0);
        assertEquals(1, first.path("rank").asInt());
        assertEquals("Dra. Rivas", first.path("staffName").asText());
        assertEquals("Cardiología O05", first.path("specialtyName").asText());
        assertEquals(1, first.path("waitDays").asInt());
        assertEquals(0.8, first.path("expectedOccupancy").asDouble());
        assertEquals(0.8, first.path("estimatedAttendance").asDouble());
        assertEquals("INITIAL_VALUE", first.path("attendanceSource").asText());
        assertEquals(89.0, first.path("score").asDouble());
        assertEquals(68.0, urgent.path("slots").get(1).path("score").asDouble());
        assertTrue(first.path("explanation").asText().contains("Derivación urgente: la espera pesa el 90 %"), first.path("explanation").asText());
        assertFalse(ids(urgent).contains(pazSlots.get(0)) || ids(urgent).contains(pazSlots.get(1)), "Choca con otra cita del paciente");
        assertFalse(ids(urgent).contains(past));

        migrador.update("update salud_u.derivacion set prioridad='RUTINA' where id=?", referral);
        JsonNode routine = suggested(admin, request).path("data");
        assertEquals("ROUTINE", routine.path("priority").asText());
        assertEquals(List.of(pazSlots.get(2), pazSlots.get(3), rivasSlots.get(3)), ids(routine), "Con rutina pesa más la jornada vacía");
        assertEquals(73.3, routine.path("slots").get(0).path("score").asDouble());

        // El mejor cupo se asigna con el endpoint de siempre, y después la solicitud ya no tiene sugerencias.
        mvc.perform(post("/api/appointment-requests/" + request + "/assign").with(authentication(admin.auth())).with(org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf())
                .contentType("application/json").content("{\"slotId\":\"" + pazSlots.get(2) + "\"}"))
            .andExpect(status().isOk());
        mvc.perform(get("/api/appointment-requests/" + request + "/suggested-slots").with(authentication(admin.auth())))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("La solicitud ya no está pendiente."));
    }

    @Test
    void initialRequestsOnlySeeAreaSlotsAndAnEmptyListIsValid() throws Exception {
        LocalDate day = LocalDate.now(BOLIVIA).plusDays(3);
        UUID specialty = specialty("Dermatología O05"), patient = patient();
        UUID request = request(patient, "INICIAL", null, null);
        Actor admin = actor("ADMINISTRATIVE");
        JsonNode empty = suggested(admin, request).path("data");
        assertEquals("INITIAL", empty.path("appointmentType").asText());
        assertTrue(empty.path("priority").isNull());
        assertEquals(0.5, empty.path("waitWeight").asDouble());
        assertEquals(0, empty.path("slots").size());

        slots(staff("Dra. Esp"), specialty, day, 2);
        List<UUID> area = slots(staff("Dr. Revisión"), null, day, 2);
        JsonNode initial = suggested(admin, request).path("data");
        assertEquals(area, ids(initial));
        assertTrue(initial.path("slots").get(0).path("specialtyId").isNull());
        assertTrue(initial.path("slots").get(0).path("explanation").asText().contains("Solicitud sin derivación"));

        UUID direct = request(patient(), "ESPECIALIDAD", specialty, null);
        assertEquals(2, suggested(admin, direct).path("data").path("slots").size());
    }

    @Test
    void onlyAdministrationAndOnlyPendingProgrammableRequests() throws Exception {
        UUID specialty = specialty("Pediatría O05"), patient = patient();
        UUID referral = referral(patient, specialty, "PRIORITARIA");
        UUID request = request(patient, "DERIVACION", specialty, referral);
        for (String role : List.of("STUDENT", "REVIEW_DOCTOR", "SPECIALIST", "AUDITOR"))
            mvc.perform(get("/api/appointment-requests/" + request + "/suggested-slots").with(authentication(actor(role).auth()))).andExpect(status().isForbidden());
        mvc.perform(get("/api/appointment-requests/" + request + "/suggested-slots")).andExpect(status().isUnauthorized());
        Actor admin = actor("ADMINISTRATIVE");
        mvc.perform(get("/api/appointment-requests/" + UUID.randomUUID() + "/suggested-slots").with(authentication(admin.auth())))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("La solicitud no existe."));
        mvc.perform(get("/api/appointment-requests/" + request + "/suggested-slots").with(authentication(admin.auth())))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store, private"))
            .andExpect(jsonPath("$.data.priority").value("PRIORITY"));
        migrador.update("update salud_u.derivacion set estado='CANCELADA' where id=?", referral);
        mvc.perform(get("/api/appointment-requests/" + request + "/suggested-slots").with(authentication(admin.auth())))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.error").value("La derivación ya no está disponible para programar."));
        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForList("select * from salud_u.cupos_para_solicitud(?)", request));
    }

    private JsonNode suggested(Actor actor, UUID request) throws Exception {
        return json.readTree(mvc.perform(get("/api/appointment-requests/" + request + "/suggested-slots").with(authentication(actor.auth())))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray());
    }

    private static List<UUID> ids(JsonNode data) {
        List<UUID> ids = new ArrayList<>();
        data.path("slots").forEach(s -> ids.add(UUID.fromString(s.path("slotId").asText())));
        return ids;
    }

    private String state() {
        return migrador.queryForObject("select (select string_agg(id::text||estado||cantidad_reservada||capacidad, ',' order by id) from salud_u.cupo_disponibilidad)"
            + " || (select string_agg(id::text||estado, ',' order by id) from salud_u.solicitud_cita) || (select count(*) from salud_u.cita)::text", String.class);
    }

    private List<UUID> slots(UUID staff, UUID specialty, LocalDate day, int count) {
        List<UUID> ids = new ArrayList<>();
        for (int i = 0; i < count; i++) ids.add(slot(staff, specialty, day.atTime(8, 0).atZone(BOLIVIA).toOffsetDateTime().plusMinutes(30L * i)));
        return ids;
    }

    private UUID slot(UUID staff, UUID specialty, OffsetDateTime start) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,?,1,'PUBLICADO',now(),?)",
            id, staff, specialty, start, start.plusMinutes(30), DOCTOR);
        return id;
    }

    private void booking(UUID patient, UUID slot) {
        migrador.update("insert into salud_u.cita(id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) select ?, u.id, case when u.id_especialidad is null then 'INICIAL' else 'ESPECIALIDAD' end, u.id_personal, u.inicia_a from salud_u.cupo_disponibilidad u where u.id=?", patient, slot);
        migrador.update("update salud_u.cupo_disponibilidad set cantidad_reservada=cantidad_reservada+1 where id=?", slot);
    }

    private UUID patient() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,'Paciente','O05',?,?)",
            id, "O05-" + id, "O05" + id, "REG-" + id, "REG" + id, DOCTOR, DOCTOR);
        return id;
    }

    private UUID referral(UUID patient, UUID specialty, String priority) {
        UUID staff = staff("Médico de revisión"), slot = UUID.randomUUID(), appointment = UUID.randomUUID(), encounter = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()-interval '3 days',now()-interval '3 days'+interval '30 minutes',1,'CERRADO',now()-interval '4 days',?)", slot, staff, DOCTOR);
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) values (?,?,?,'INICIAL',?,now()-interval '3 days','ATENDIDA')", appointment, patient, slot, staff);
        migrador.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado) values (?,?,?,?,'INICIAL','CERRADA')", encounter, appointment, patient, staff);
        migrador.update("insert into salud_u.derivacion(id,id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por) values (?,?,?,?,?,'Motivo O05','Resumen O05',?)", id, patient, encounter, specialty, priority, DOCTOR);
        return id;
    }

    private UUID request(UUID patient, String type, UUID specialty, UUID referral) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.solicitud_cita(id,id_paciente,tipo_cita,id_especialidad,id_derivacion,origen,estado,solicitado_por) values (?,?,?,?,?,?,'PENDIENTE',?)",
            id, patient, type, specialty, referral, "INICIAL".equals(type) ? "INICIAL" : "DIRECTA_ADMINISTRACION", DOCTOR);
        return id;
    }

    private UUID specialty(String name) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,?,?)", id, "O05-" + id, name);
        return id;
    }

    private UUID staff(String name) {
        UUID principal = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", principal, principal + "@example.invalid", name);
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "O05-" + id);
        return id;
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor O05')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor O05", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

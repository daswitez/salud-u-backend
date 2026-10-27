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

/** O-07: reprogramar citas ante un bloqueo (UC-31, PV-7.6, RN-33). */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class ReprogramacionBloqueoIntegrationTest {
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
        String documents = Files.createTempDirectory("salud-u-o07-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "ReprogramacionBloqueoIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico O07') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
    }

    private static final java.time.ZoneId BOLIVIA = java.time.ZoneId.of("America/La_Paz");

    @Test
    void pv76BlockingADayWithThreeAppointmentsReschedulesEachOneAndThenBlocks() throws Exception {
        LocalDate day = LocalDate.now(BOLIVIA).plusDays(5);
        UUID specialty = specialty(), other = specialty(), rivas = staff("Dra. Rivas"), paz = staff("Dr. Paz");
        List<UUID> rivasSlots = slots(rivas, specialty, day, 8, 4);          // 08:00, 08:30, 09:00, 09:30
        List<UUID> pazSlots = slots(paz, specialty, day, 10, 2);              // 10:00, 10:30
        UUID nextDay = slots(paz, specialty, day.plusDays(1), 8, 1).getFirst();
        slots(staff("Dra. Otra"), other, day, 9, 1);                          // otra especialidad: no sirve
        UUID studentPrincipal = UUID.randomUUID();
        UUID p1 = patient(studentPrincipal), p2 = patient(null), p3 = patient(null);
        UUID referral = referral(p1, specialty, rivas);
        UUID a1 = booking(p1, rivasSlots.get(0), referral), a2 = booking(p2, rivasSlots.get(1), null), a3 = booking(p3, rivasSlots.get(2), null);
        Actor admin = actor("ADMINISTRATIVE");

        JsonNode proposal = propose(admin, rivas, day, "08:00", "10:00", "Congreso").andExpect(status().isCreated()).andReturn().getResponse().getContentAsString().transform(this::read).path("data");
        assertEquals("PENDING", proposal.path("status").asText());
        assertEquals(3, proposal.path("pendingAppointments").asInt());
        assertTrue(proposal.path("blockId").isNull());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.bloqueo_disponibilidad where id_personal=?", Integer.class, rivas), "Todavía no se bloquea");
        JsonNode reschedules = proposal.path("reschedules");
        assertEquals(3, reschedules.size());
        Map<String, JsonNode> byAppointment = new java.util.HashMap<>();
        reschedules.forEach(r -> byAppointment.put(r.at("/suggestedValue/appointmentId").asText(), r));
        // El más cercano sin repetir lugares: 08:00 → 10:00, 08:30 → 10:30, 09:00 → al día siguiente. 09:30 queda dentro del bloqueo.
        assertEquals(pazSlots.get(0).toString(), byAppointment.get(a1.toString()).at("/suggestedValue/slotId").asText());
        assertEquals(pazSlots.get(1).toString(), byAppointment.get(a2.toString()).at("/suggestedValue/slotId").asText());
        assertEquals(nextDay.toString(), byAppointment.get(a3.toString()).at("/suggestedValue/slotId").asText());
        assertEquals(120, byAppointment.get(a1.toString()).at("/suggestedValue/shiftMinutes").asInt());
        assertEquals("Dr. Paz", byAppointment.get(a1.toString()).at("/suggestedValue/staffName").asText());
        assertEquals("PENDING", byAppointment.get(a1.toString()).path("status").asText());
        assertTrue(byAppointment.get(a1.toString()).path("explanation").asText().contains("es el cupo compatible libre más cercano (2 horas después)"),
            byAppointment.get(a1.toString()).path("explanation").asText());
        assertTrue(byAppointment.get(a3.toString()).path("explanation").asText().contains("(23 horas después)"), byAppointment.get(a3.toString()).path("explanation").asText());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.notificacion where tipo_evento='CITA_REPROGRAMADA' and id_cita in (?,?,?)", Integer.class, a1, a2, a3),
            "Proponer no mueve citas (RN-33)");

        decide(admin, id(byAppointment.get(a1.toString())), "{\"decision\":\"ACCEPTED\"}").andExpect(status().isOk())
            .andExpect(jsonPath("$.data.status").value("ACCEPTED"))
            .andExpect(jsonPath("$.data.decision.appliedValue.originalSlotId").value(rivasSlots.get(0).toString()))
            .andExpect(jsonPath("$.data.decision.appliedValue.slotId").value(pazSlots.get(0).toString()));
        assertEquals(pazSlots.get(0), migrador.queryForObject("select id_cupo from salud_u.cita where id=?", UUID.class, a1));
        assertEquals(paz, migrador.queryForObject("select id_personal_asignado from salud_u.cita where id=?", UUID.class, a1));
        assertEquals(paz, migrador.queryForObject("select id_personal_asignado from salud_u.derivacion where id=?", UUID.class, referral), "La derivación sigue al especialista");
        assertEquals(List.of(0, 1), List.of(reserved(rivasSlots.get(0)), reserved(pazSlots.get(0))));
        String message = migrador.queryForObject("select mensaje from salud_u.notificacion where tipo_evento='CITA_REPROGRAMADA' and id_cita=? and id_destinatario=?", String.class, a1, studentPrincipal);
        assertTrue(message.contains(day.toString().substring(8, 10) + "/" + day.toString().substring(5, 7) + "/" + day.getYear() + " 10:00"), message);
        assertEquals("Bloqueo de agenda: Congreso", migrador.queryForObject("select motivo from salud_u.evento_estado_cita where id_cita=? and motivo is not null", String.class, a1));
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where accion='CITA_REPROGRAMADA' and id_recurso=?", Integer.class, a1));

        UUID eleven = slots(paz, specialty, day, 11, 1).getFirst();
        decide(admin, id(byAppointment.get(a2.toString())), "{\"decision\":\"MODIFIED\",\"reason\":\"El paciente prefiere las 11\",\"slots\":[{\"slotId\":\"" + eleven + "\"}]}")
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("MODIFIED"));
        assertEquals(eleven, migrador.queryForObject("select id_cupo from salud_u.cita where id=?", UUID.class, a2));
        assertEquals("PENDING", get(admin, id(proposal)).path("status").asText());
        assertEquals(1, get(admin, id(proposal)).path("pendingAppointments").asInt());

        decide(admin, id(byAppointment.get(a3.toString())), "{\"decision\":\"ACCEPTED\"}").andExpect(status().isOk());
        JsonNode applied = get(admin, id(proposal));
        assertEquals("APPLIED", applied.path("status").asText(), "Sin citas en el horario, el bloqueo se registra");
        assertEquals(0, applied.path("pendingAppointments").asInt());
        assertFalse(applied.path("blockId").isNull());
        assertEquals("Congreso", migrador.queryForObject("select etiqueta from salud_u.bloqueo_disponibilidad where id=?", String.class, UUID.fromString(applied.path("blockId").asText())));
        assertEquals(List.of("BLOQUEADO", "BLOQUEADO", "BLOQUEADO", "BLOQUEADO"), states(rivasSlots));
        assertEquals("PUBLICADO", states(List.of(pazSlots.get(1))).getFirst(), "Los cupos de otros médicos no cambian");
        assertEquals(2, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where accion in ('PROPUESTA_BLOQUEO_REGISTRADA','PROPUESTA_BLOQUEO_APLICADA') and id_recurso=?", Integer.class, id(proposal)));
    }

    @Test
    void aRejectedRescheduleKeepsTheProposalPendingUntilTheDayIsFree() throws Exception {
        LocalDate day = LocalDate.now(BOLIVIA).plusDays(6);
        UUID specialty = specialty(), rivas = staff("Dra. Rechazo");
        List<UUID> rivasSlots = slots(rivas, specialty, day, 8, 2);
        UUID free = slots(staff("Dr. Libre"), specialty, day, 9, 1).getFirst();
        UUID appointment = booking(patient(null), rivasSlots.get(0), null);
        Actor admin = actor("ADMINISTRATIVE");
        JsonNode proposal = read(propose(admin, rivas, day, null, null, "Licencia").andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("data");
        JsonNode reschedule = proposal.path("reschedules").get(0);
        assertEquals(free.toString(), reschedule.at("/suggestedValue/slotId").asText());
        decide(admin, id(reschedule), "{\"decision\":\"REJECTED\",\"reason\":\"Se atenderá igual\"}").andExpect(status().isOk());
        assertEquals(rivasSlots.get(0), migrador.queryForObject("select id_cupo from salud_u.cita where id=?", UUID.class, appointment));
        assertEquals("PENDING", get(admin, id(proposal)).path("status").asText());
        apply(admin, id(proposal)).andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("Todavía hay citas en el horario; reprográmalas o cancélalas antes de bloquear."));
        migrador.update("update salud_u.cita set estado='CANCELADA', cancelada_en=now(), motivo_cancelacion='Prueba O07' where id=?", appointment);
        apply(admin, id(proposal)).andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("APPLIED"));
        apply(admin, id(proposal)).andExpect(status().isOk()).andExpect(jsonPath("$.data.status").value("APPLIED"));
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.bloqueo_disponibilidad where id_personal=?", Integer.class, rivas), "Aplicar dos veces no duplica el bloqueo");
        assertEquals(List.of("BLOQUEADO", "BLOQUEADO"), states(rivasSlots));
    }

    @Test
    void withoutAppointmentsTheBlockIsAppliedAtOnceAndWithoutASlotTheAdminPicksOne() throws Exception {
        LocalDate day = LocalDate.now(BOLIVIA).plusDays(7);
        UUID specialty = specialty(), lonely = staff("Dra. Sola"), empty = staff("Dr. Vacío");
        slots(empty, specialty, day, 8, 2);
        Actor admin = actor("ADMINISTRATIVE");
        JsonNode immediate = read(propose(admin, empty, day, "08:00", "09:00", "Capacitación").andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("data");
        assertEquals("APPLIED", immediate.path("status").asText());
        assertEquals(0, immediate.path("reschedules").size());

        UUID onlySpecialty = specialty();
        UUID appointment = booking(patient(null), slots(lonely, onlySpecialty, day, 8, 1).getFirst(), null);
        JsonNode proposal = read(propose(admin, lonely, day, null, null, "Viaje").andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("data");
        JsonNode reschedule = proposal.path("reschedules").get(0);
        assertTrue(reschedule.at("/suggestedValue/slotId").isNull());
        assertTrue(reschedule.path("explanation").asText().startsWith("No hay un cupo compatible libre"), reschedule.path("explanation").asText());
        decide(admin, id(reschedule), "{\"decision\":\"ACCEPTED\"}").andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("No hay un cupo sugerido; modifica la sugerencia eligiendo otro cupo o recházala."));
        UUID wrong = slots(staff("Dr. Otro"), specialty(), day.plusDays(1), 8, 1).getFirst();
        decide(admin, id(reschedule), "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[{\"slotId\":\"" + wrong + "\"}]}").andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("El cupo no es de la misma especialidad que la cita."));
        UUID later = slots(staff("Dra. Nueva"), onlySpecialty, day.plusDays(2), 8, 1).getFirst();
        decide(admin, id(reschedule), "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[{\"slotId\":\"" + later + "\",\"capacity\":2}]}").andExpect(status().isBadRequest());
        decide(admin, id(reschedule), "{\"decision\":\"MODIFIED\",\"reason\":\"Se publicó otra jornada\",\"slots\":[{\"slotId\":\"" + later + "\"}]}").andExpect(status().isOk());
        assertEquals(later, migrador.queryForObject("select id_cupo from salud_u.cita where id=?", UUID.class, appointment));
        assertEquals("APPLIED", get(admin, id(proposal)).path("status").asText());
    }

    @Test
    void proposalsAreRejectedWhenUnsafeAndTheDoctorsOwnBlockIsUnchanged() throws Exception {
        LocalDate day = LocalDate.now(BOLIVIA).plusDays(8);
        UUID specialty = specialty(), rivas = staff("Dra. Valida");
        List<UUID> rivasSlots = slots(rivas, specialty, day, 8, 3);
        UUID patient = patient(null);
        UUID first = booking(patient, rivasSlots.get(0), null);
        Actor admin = actor("ADMINISTRATIVE");
        for (String role : List.of("STUDENT", "REVIEW_DOCTOR", "SPECIALIST"))
            propose(actor(role), rivas, day, null, null, "x").andExpect(status().isForbidden());
        for (String invalid : List.of("{}", "{\"staffId\":\"" + rivas + "\",\"date\":\"" + day + "\"}",
                "{\"staffId\":\"" + rivas + "\",\"date\":\"" + day + "\",\"label\":\"x\",\"startTime\":\"8\"}",
                "{\"staffId\":\"" + rivas + "\",\"date\":\"" + day + "\",\"label\":\"x\",\"startTime\":\"10:00\",\"endTime\":\"09:00\"}",
                "{\"staffId\":\"" + rivas + "\",\"date\":\"" + day + "\",\"label\":\"x\",\"startTime\":\"10:00\"}",
                "{\"staffId\":\"" + rivas + "\",\"date\":\"2020-01-01\",\"label\":\"x\"}",
                "{\"staffId\":\"" + rivas + "\",\"date\":\"" + day + "\",\"label\":\"x\",\"other\":1}"))
            mvc.perform(MockMvcRequestBuilders.post("/api/scheduling/block-proposals").with(authentication(admin.auth())).with(csrf())
                .contentType("application/json").content(invalid)).andExpect(status().isBadRequest());
        propose(admin, UUID.randomUUID(), day, null, null, "x").andExpect(status().isNotFound());
        mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/block-proposals/" + UUID.randomUUID()).with(authentication(admin.auth()))).andExpect(status().isNotFound());

        migrador.update("update salud_u.cita set estado='LLEGADA', ingreso_registrado_en=now() where id=?", first);
        propose(admin, rivas, day, null, null, "Congreso").andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("El horario tiene una cita que ya empezó o un paciente presente; no se puede reprogramar."));
        migrador.update("update salud_u.cita set estado='PROGRAMADA', ingreso_registrado_en=null where id=?", first);

        // Cupo lleno o choque con otra cita del paciente: la reprogramación se rechaza y no cambia nada.
        UUID full = slots(staff("Dr. Lleno"), specialty, day.plusDays(1), 8, 1).getFirst();
        booking(patient(null), full, null);
        UUID clash = slots(staff("Dr. Choque"), specialty, day.plusDays(2), 8, 1).getFirst();
        booking(patient, slots(staff("Dr. Área"), null, day.plusDays(2), 8, 1).getFirst(), null);
        UUID ok = slots(staff("Dr. Bien"), specialty, day.plusDays(3), 8, 1).getFirst();
        JsonNode proposal = read(propose(admin, rivas, day, null, null, "Congreso").andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("data");
        assertEquals(ok.toString(), proposal.at("/reschedules/0/suggestedValue/slotId").asText(), "Ni el lleno ni el que choca");
        propose(admin, rivas, day, "08:30", "10:00", "Otra").andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("Ya hay una propuesta de bloqueo pendiente para ese horario."));
        UUID suggestion = id(proposal.path("reschedules").get(0));
        decide(admin, suggestion, "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[{\"slotId\":\"" + full + "\"}]}").andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("El cupo ya no está disponible."));
        decide(admin, suggestion, "{\"decision\":\"MODIFIED\",\"reason\":\"x\",\"slots\":[{\"slotId\":\"" + clash + "\"}]}").andExpect(status().isConflict())
            .andExpect(jsonPath("$.error").value("El paciente ya tiene otra cita en ese horario."));
        assertEquals(rivasSlots.get(0), migrador.queryForObject("select id_cupo from salud_u.cita where id=?", UUID.class, first));
        assertEquals("PENDING", get(admin, id(proposal)).path("reschedules").get(0).path("status").asText());

        // El bloqueo del médico (V7) sigue rechazando horarios con citas.
        String own = migrador.queryForObject("select prosrc from pg_proc where proname='crear_mi_bloqueo_disponibilidad' and pronamespace='salud_u'::regnamespace", String.class);
        assertTrue(own.contains("No puedes bloquear un horario que ya tiene una cita asignada"));
        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForObject("select salud_u.reprogramar_cita(?, ?, 'x')", Object.class, first, ok));
        for (String sql : List.of("select count(*) from salud_u.propuesta_bloqueo"))
            assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForObject(sql, Integer.class));
    }

    private org.springframework.test.web.servlet.ResultActions propose(Actor actor, UUID staff, LocalDate day, String start, String end, String label) throws Exception {
        String times = start == null ? "" : ",\"startTime\":\"" + start + "\",\"endTime\":\"" + end + "\"";
        return mvc.perform(MockMvcRequestBuilders.post("/api/scheduling/block-proposals").with(authentication(actor.auth())).with(csrf())
            .contentType("application/json").content("{\"staffId\":\"" + staff + "\",\"date\":\"" + day + "\",\"label\":\"" + label + "\"" + times + "}"));
    }

    private org.springframework.test.web.servlet.ResultActions apply(Actor actor, UUID proposal) throws Exception {
        return mvc.perform(MockMvcRequestBuilders.post("/api/scheduling/block-proposals/" + proposal + "/apply").with(authentication(actor.auth())).with(csrf()));
    }

    private JsonNode get(Actor actor, UUID proposal) throws Exception {
        return read(mvc.perform(MockMvcRequestBuilders.get("/api/scheduling/block-proposals/" + proposal).with(authentication(actor.auth())))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store, private")).andReturn().getResponse().getContentAsString()).path("data");
    }

    private org.springframework.test.web.servlet.ResultActions decide(Actor actor, UUID id, String body) throws Exception {
        return mvc.perform(MockMvcRequestBuilders.post("/api/scheduling/suggestions/" + id + "/decision").with(authentication(actor.auth())).with(csrf())
            .contentType("application/json").content(body));
    }

    private static UUID id(JsonNode node) { return UUID.fromString(node.path("id").asText()); }

    private int reserved(UUID slot) { return migrador.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, slot); }

    private List<String> states(List<UUID> slots) {
        List<String> states = new ArrayList<>();
        for (UUID slot : slots) states.add(migrador.queryForObject("select estado from salud_u.cupo_disponibilidad where id=?", String.class, slot));
        return states;
    }

    private JsonNode read(String body) {
        try { return json.readTree(body); } catch (Exception exception) { throw new IllegalStateException(exception); }
    }

    /** Cupos de 30 minutos desde la hora indicada (hora de Bolivia). */
    private List<UUID> slots(UUID staff, UUID specialty, LocalDate day, int hour, int count) {
        List<UUID> ids = new ArrayList<>();
        for (int i = 0; i < count; i++) {
            UUID id = UUID.randomUUID();
            OffsetDateTime start = day.atTime(hour, 0).atZone(BOLIVIA).toOffsetDateTime().plusMinutes(30L * i);
            migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,?,1,'PUBLICADO',now(),?)",
                id, staff, specialty, start, start.plusMinutes(30), DOCTOR);
            ids.add(id);
        }
        return ids;
    }

    private UUID booking(UUID patient, UUID slot, UUID referral) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,id_derivacion) select ?, ?, u.id, case when u.id_especialidad is null then 'INICIAL' else 'ESPECIALIDAD' end, u.id_personal, u.inicia_a, ? from salud_u.cupo_disponibilidad u where u.id=?",
            id, patient, referral, slot);
        migrador.update("update salud_u.cupo_disponibilidad set cantidad_reservada=cantidad_reservada+1 where id=?", slot);
        return id;
    }

    private UUID patient(UUID principal) {
        UUID id = UUID.randomUUID();
        if (principal != null) migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Estudiante O07')", principal, principal + "@example.invalid");
        migrador.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por,id_principal) values (?,?,?,?,?,'Paciente','O07',?,?,?)",
            id, "O07-" + id, "O07" + id, "REG-" + id, "REG" + id, DOCTOR, DOCTOR, principal);
        return id;
    }

    /** Derivación ya asignada a un especialista, como la deja asignar_solicitud_cita. */
    private UUID referral(UUID patient, UUID specialty, UUID specialist) {
        UUID staff = staff("Médico de revisión"), slot = UUID.randomUUID(), appointment = UUID.randomUUID(), encounter = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()-interval '3 days',now()-interval '3 days'+interval '30 minutes',1,'CERRADO',now()-interval '4 days',?)", slot, staff, DOCTOR);
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) values (?,?,?,'INICIAL',?,now()-interval '3 days','ATENDIDA')", appointment, patient, slot, staff);
        migrador.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado) values (?,?,?,?,'INICIAL','CERRADA')", encounter, appointment, patient, staff);
        migrador.update("insert into salud_u.derivacion(id,id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por,estado,id_personal_asignado,asignada_en) values (?,?,?,?,'RUTINA','Motivo O07','Resumen O07',?,'ASIGNADA',?,now())",
            id, patient, encounter, specialty, DOCTOR, specialist);
        return id;
    }

    private UUID specialty() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,?,?)", id, "O07-" + id, "Especialidad O07 " + id);
        return id;
    }

    private UUID staff(String name) {
        UUID principal = UUID.randomUUID(), id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", principal, principal + "@example.invalid", name);
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "O07-" + id);
        return id;
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor O07')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor O07", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

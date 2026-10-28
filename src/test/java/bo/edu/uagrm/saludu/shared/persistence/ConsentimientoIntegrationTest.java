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

/** A-03: términos de uso y consentimiento para investigación (RN-22, RN-23), con la obligación ya activa (paso 3). */
@SpringBootTest(properties = "salud-u.consents.required=true")
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class ConsentimientoIntegrationTest {
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
        String documents = Files.createTempDirectory("salud-u-a03-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "ConsentimientoIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico A03') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
    }

    private static final String ACEPTA = "{\"termsVersion\":\"1\",\"termsAccepted\":true,\"researchVersion\":\"1\",\"researchAccepted\":true}";
    private static final String RECHAZA = "{\"termsVersion\":\"1\",\"termsAccepted\":true,\"researchVersion\":\"1\",\"researchAccepted\":false}";

    @Test
    void withoutAcceptingTheTermsAndChoosingYesOrNoNothingAdvancesInThePortalOrInAdministration() throws Exception {
        Actor student = actor("STUDENT"), admin = actor("ADMINISTRATIVE");
        UUID own = patient(student.id(), "SIN-RESPUESTA"), other = patient(null, "RECEPCION");
        mvc.perform(get(admin, "/api/consent-texts")).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.pending").value(true))
            .andExpect(jsonPath("$.data.terms.currentVersion").value("1"))
            .andExpect(jsonPath("$.data.research.text").isNotEmpty())
            .andExpect(header().string("Cache-Control", "no-store, private"));
        mvc.perform(get(student, "/api/consent-texts")).andExpect(status().isForbidden());
        mvc.perform(get(student, "/api/me/consents")).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.pending").value(true))
            .andExpect(jsonPath("$.data.terms.currentVersion").value("1"))
            .andExpect(jsonPath("$.data.terms.accepted").value(org.hamcrest.Matchers.nullValue()))
            .andExpect(jsonPath("$.data.research.accepted").value(org.hamcrest.Matchers.nullValue()))
            .andExpect(jsonPath("$.data.research.text").value(org.hamcrest.Matchers.containsString("nunca se incluyen tu nombre, carnet, código de registro, teléfono ni correo")))
            .andExpect(header().string("Cache-Control", "no-store, private"));

        List<String> invalid = List.of(
            "{\"termsVersion\":\"1\",\"termsAccepted\":false,\"researchVersion\":\"1\",\"researchAccepted\":true}",
            "{\"termsVersion\":\"1\",\"researchVersion\":\"1\",\"researchAccepted\":true}",
            "{\"termsVersion\":\"1\",\"termsAccepted\":true,\"researchVersion\":\"1\"}",
            "{\"termsVersion\":\"1\",\"termsAccepted\":true,\"researchVersion\":\"1\",\"researchAccepted\":null}",
            "{\"termsAccepted\":true,\"researchAccepted\":true}");
        for (String body : invalid) {
            mvc.perform(post(student, "/api/me/consents", body)).andExpect(status().isBadRequest());
            mvc.perform(post(admin, "/api/patients/" + other + "/consents", body)).andExpect(status().isBadRequest());
        }
        // Al registrar un paciente: si el bloque está incompleto, no se crea nada.
        String carnet = "A03-" + UUID.randomUUID().toString().substring(0, 8);
        mvc.perform(post(admin, "/api/patients", patientBody(carnet, career(), invalid.get(2))))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").value(org.hamcrest.Matchers.containsString("Sí o No")));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.paciente where carnet=?", Integer.class, carnet));
        // La versión la valida la base después de crear el paciente: la transacción revierte también el alta.
        mvc.perform(post(admin, "/api/patients", patientBody(carnet, career(), ACEPTA.replace("\"termsVersion\":\"1\"", "\"termsVersion\":\"0\""))))
            .andExpect(status().isConflict());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.paciente where carnet=?", Integer.class, carnet));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.consentimiento where id_paciente in (?, ?)", Integer.class, own, other));

        // Respaldo del backend: con la respuesta pendiente no se crea la solicitud, ni desde el portal ni desde recepción.
        mvc.perform(post(student, "/api/appointment-requests", "{\"appointmentType\":\"INITIAL\"}"))
            .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.ok").value(false)).andExpect(jsonPath("$.code").value("CONSENTIMIENTO_PENDIENTE"));
        mvc.perform(post(admin, "/api/appointment-requests", "{\"appointmentType\":\"INITIAL\",\"patientId\":\"" + other + "\"}"))
            .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.code").value("CONSENTIMIENTO_PENDIENTE"));
        mvc.perform(post(admin, "/api/appointment-requests", "{\"appointmentType\":\"INITIAL\",\"patientId\":\"" + other + "\",\"consents\":" + invalid.get(2) + "}"))
            .andExpect(status().isBadRequest());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.solicitud_cita where id_paciente in (?, ?)", Integer.class, own, other));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.consentimiento where id_paciente in (?, ?)", Integer.class, own, other));
    }

    @Test
    void answeringNoStillLetsThePatientRequestAppointmentsByEitherChannel() throws Exception {
        Actor student = actor("STUDENT"), admin = actor("ADMINISTRATIVE");
        UUID own = patient(student.id(), "PORTAL-NO"), reception = patient(null, "RECEPCION-NO");

        mvc.perform(post(student, "/api/me/consents", RECHAZA)).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.pending").value(false)).andExpect(jsonPath("$.data.terms.accepted").value(true))
            .andExpect(jsonPath("$.data.research.accepted").value(false)).andExpect(jsonPath("$.data.research.lastAnswer.channel").value("PORTAL"));
        mvc.perform(post(student, "/api/appointment-requests", "{\"appointmentType\":\"INITIAL\"}")).andExpect(status().isCreated());

        // Recepción: la respuesta viaja con la solicitud y queda registrada con vía ADMINISTRACION.
        mvc.perform(post(admin, "/api/appointment-requests", "{\"appointmentType\":\"INITIAL\",\"patientId\":\"" + reception + "\",\"consents\":" + RECHAZA + "}"))
            .andExpect(status().isCreated());
        mvc.perform(get(admin, "/api/patients/" + reception + "/consents")).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.pending").value(false)).andExpect(jsonPath("$.data.research.accepted").value(false))
            .andExpect(jsonPath("$.data.research.lastAnswer.channel").value("ADMINISTRATION"));

        // Al registrar un paciente con el bloque completo.
        String carnet = "A03-" + UUID.randomUUID().toString().substring(0, 8);
        String created = mvc.perform(post(admin, "/api/patients", patientBody(carnet, career(), ACEPTA)))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        UUID registered = UUID.fromString(json.readTree(created).at("/data/id").asText());
        mvc.perform(get(admin, "/api/patients/" + registered + "/consents")).andExpect(jsonPath("$.data.research.accepted").value(true));

        assertEquals(List.of("USO_SISTEMA|ACEPTA|PORTAL", "INVESTIGACION|RECHAZA|PORTAL"), audit(own));
        assertEquals(List.of("USO_SISTEMA|ACEPTA|ADMINISTRACION", "INVESTIGACION|RECHAZA|ADMINISTRACION"), audit(reception));
        // Repetir la misma respuesta no agrega filas; cambiarla agrega solo la que cambia.
        mvc.perform(post(student, "/api/me/consents", RECHAZA)).andExpect(status().isOk());
        mvc.perform(post(student, "/api/me/consents", ACEPTA)).andExpect(status().isOk());
        assertEquals(List.of("USO_SISTEMA|ACEPTA", "INVESTIGACION|RECHAZA", "INVESTIGACION|ACEPTA"),
            migrador.queryForList("select tipo || '|' || decision from salud_u.consentimiento where id_paciente=? order by registrado_en, id", String.class, own));
    }

    @Test
    void aStudentCannotAnswerForSomeoneElseAndOnlyAdministrationSeesOtherPatients() throws Exception {
        Actor ana = actor("STUDENT"), beto = actor("STUDENT"), reports = actor("REPORTING_OFFICER"), doctor = actor("REVIEW_DOCTOR"), sinFicha = actor("STUDENT");
        UUID anaPatient = patient(ana.id(), "ANA"), betoPatient = patient(beto.id(), "BETO");
        // Un id ajeno en el cuerpo se ignora: la respuesta siempre va a la ficha propia.
        mvc.perform(post(ana, "/api/me/consents", RECHAZA.replace("}", ",\"patientId\":\"" + betoPatient + "\"}"))).andExpect(status().isOk());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.consentimiento where id_paciente=?", Integer.class, betoPatient));
        assertEquals(2, migrador.queryForObject("select count(*) from salud_u.consentimiento where id_paciente=?", Integer.class, anaPatient));
        mvc.perform(get(beto, "/api/me/consents")).andExpect(jsonPath("$.data.pending").value(true));
        mvc.perform(post(ana, "/api/patients/" + betoPatient + "/consents", ACEPTA)).andExpect(status().isForbidden());
        mvc.perform(get(ana, "/api/patients/" + betoPatient + "/consents")).andExpect(status().isForbidden());
        mvc.perform(post(ana, "/api/appointment-requests", "{\"appointmentType\":\"INITIAL\",\"patientId\":\"" + betoPatient + "\",\"consents\":" + ACEPTA + "}"))
            .andExpect(status().isForbidden());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.consentimiento where id_paciente=?", Integer.class, betoPatient));
        for (Actor other : List.of(reports, doctor)) {
            mvc.perform(get(other, "/api/patients/" + anaPatient + "/consents")).andExpect(status().isForbidden());
            mvc.perform(get(other, "/api/me/consents")).andExpect(status().isForbidden());
        }
        mvc.perform(get(sinFicha, "/api/me/consents")).andExpect(status().isNotFound());
        mvc.perform(post(actor("ADMINISTRATIVE"), "/api/patients/" + UUID.randomUUID() + "/consents", ACEPTA)).andExpect(status().isNotFound());

        // En la base: el rol de ejecución no lee las tablas y un estudiante no consulta el estado de otro.
        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForList("select * from salud_u.consentimiento"));
        assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForList("select * from salud_u.texto_consentimiento"));
        var failure = assertThrows(org.springframework.dao.DataAccessException.class, () -> asActor(ana, "ESTUDIANTE",
            () -> runtime.queryForObject("select salud_u.consentimiento_pendiente(?)", Boolean.class, betoPatient)));
        assertTrue(failure.getMostSpecificCause().getMessage().contains("PACIENTE_NO_ENCONTRADO"));
        assertEquals(false, asActor(ana, "ESTUDIANTE", () -> runtime.queryForObject("select salud_u.consentimiento_pendiente(?)", Boolean.class, anaPatient)));

        // Solo inserción, también para el migrador; los términos no se pueden rechazar.
        var immutable = assertThrows(org.springframework.dao.DataAccessException.class, () -> migrador.update("update salud_u.consentimiento set decision='ACEPTA' where id_paciente=?", anaPatient));
        assertTrue(immutable.getMostSpecificCause().getMessage().contains("CONSENTIMIENTO_INMUTABLE"));
        assertThrows(org.springframework.dao.DataAccessException.class, () -> migrador.update("delete from salud_u.consentimiento where id_paciente=?", anaPatient));
        var terms = assertThrows(org.springframework.dao.DataAccessException.class, () -> migrador.update(
            "insert into salud_u.consentimiento(id_paciente,tipo,version,decision,via,registrado_por) values (?,'USO_SISTEMA','1','RECHAZA','PORTAL',?)", anaPatient, ana.id()));
        assertTrue(terms.getMostSpecificCause().getMessage().contains("CONSENTIMIENTO_INVALIDO"));
    }

    @Test
    void theExportOnlyIncludesCurrentAcceptancesCountsTheRestAndNeverCarriesIdentifiers() throws Exception {
        Actor reports = actor("REPORTING_OFFICER"), acepta = actor("STUDENT"), rechaza = actor("STUDENT");
        UUID career = career(), staff = staff(DOCTOR);
        UUID aceptaPatient = patient(acepta.id(), "EXP-SI"), rechazaPatient = patient(rechaza.id(), "EXP-NO"), mudoPatient = patient(null, "EXP-MUDO");
        for (UUID p : List.of(aceptaPatient, rechazaPatient, mudoPatient)) closedEncounter(p, career, staff);
        mvc.perform(post(acepta, "/api/me/consents", ACEPTA)).andExpect(status().isOk());
        mvc.perform(post(rechaza, "/api/me/consents", ACEPTA)).andExpect(status().isOk());

        Export first = export(reports, career);
        assertEquals(2, first.rows().size());
        assertEquals("0", first.declined());
        assertEquals("1", first.unanswered());

        // Quien cambia a No desaparece de la siguiente exportación.
        mvc.perform(post(rechaza, "/api/me/consents", RECHAZA)).andExpect(status().isOk());
        Export second = export(reports, career);
        assertEquals(1, second.rows().size());
        assertEquals("1", second.declined());
        assertEquals("1", second.unanswered());
        mvc.perform(get(reports, "/api/research/exports/" + second.id())).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.excludedDeclined").value(1)).andExpect(jsonPath("$.data.excludedUnanswered").value(1));
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='EXPORTACION_INVESTIGACION_COMPLETADA' and detalles->>'excludedDeclined'='1' and detalles->>'excludedUnanswered'='1'", Integer.class, second.id()));

        // Sin nombre, carnet, registro, teléfono ni correo de ninguno de los tres.
        for (UUID p : List.of(aceptaPatient, rechazaPatient, mudoPatient)) {
            Map<String, Object> identity = migrador.queryForMap("select nombres, apellidos, carnet, codigo_registro, telefono, correo from salud_u.paciente where id=?", p);
            for (Object value : identity.values()) {
                assertFalse(first.csv().contains(String.valueOf(value)), "La exportación contiene " + value);
                assertFalse(second.csv().contains(String.valueOf(value)), "La exportación contiene " + value);
            }
            assertFalse(first.csv().contains(p.toString()));
        }
        assertEquals("research_pseudonym,encounter_month,age_band,sex,career_code,academic_period,encounter_type,specialty_code,diagnosis_count,vaccination_dose_count",
            first.csv().lines().findFirst().orElseThrow().replace("﻿", ""));

        // Una versión nueva de investigación vuelve a dejar pendiente a todos y saca de la exportación a quien aceptó la anterior.
        migrador.update("insert into salud_u.texto_consentimiento(tipo,version,texto,vigente_desde) values ('INVESTIGACION','2','Texto A03 v2',now())");
        try {
            mvc.perform(get(acepta, "/api/me/consents")).andExpect(jsonPath("$.data.pending").value(true))
                .andExpect(jsonPath("$.data.research.currentVersion").value("2")).andExpect(jsonPath("$.data.research.accepted").value(org.hamcrest.Matchers.nullValue()))
                .andExpect(jsonPath("$.data.research.lastAnswer.version").value("1"));
            mvc.perform(post(acepta, "/api/appointment-requests", "{\"appointmentType\":\"INITIAL\"}")).andExpect(status().isUnprocessableEntity());
            mvc.perform(post(acepta, "/api/me/consents", ACEPTA)).andExpect(status().isConflict());
            Export third = export(reports, career);
            assertEquals(0, third.rows().size());
            assertEquals("3", third.unanswered());
            mvc.perform(post(acepta, "/api/me/consents", ACEPTA.replace("\"researchVersion\":\"1\"", "\"researchVersion\":\"2\""))).andExpect(status().isOk())
                .andExpect(jsonPath("$.data.pending").value(false));
            assertEquals(1, export(reports, career).rows().size());
        } finally {
            // Las respuestas a la v2 no se pueden borrar; se aplaza la v2 para que las demás pruebas vean la v1 vigente.
            migrador.update("update salud_u.texto_consentimiento set vigente_desde = now() + interval '100 years' where tipo='INVESTIGACION' and version='2'");
        }
    }

    private static String patientBody(String carnet, UUID career, String consents) {
        return "{\"fullName\":\"Paciente A03\",\"carnet\":\"" + carnet + "\",\"registrationCode\":\"R" + carnet + "\",\"careerId\":\"" + career
            + "\",\"academicPeriod\":\"2026-II\",\"enrollmentStart\":\"2026-07-01\",\"consents\":" + consents + "}";
    }

    private record Export(UUID id, List<String> rows, String csv, String declined, String unanswered) {}

    private Export export(Actor actor, UUID career) throws Exception {
        var response = mvc.perform(post(actor, "/api/research/exports", "{\"purpose\":\"Estudio A03\",\"filters\":{\"careerId\":\"" + career + "\"},\"format\":\"CSV\"}"))
            .andExpect(status().isOk()).andReturn().getResponse();
        String csv = null;
        try (var zip = new java.util.zip.ZipInputStream(new java.io.ByteArrayInputStream(response.getContentAsByteArray()))) {
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry())
                if (entry.getName().equals("research-data.csv")) csv = new String(zip.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        }
        assertNotNull(csv);
        List<String> rows = csv.lines().skip(1).filter(line -> !line.isBlank()).toList();
        assertEquals(Integer.toString(rows.size()), response.getHeader("X-Export-Row-Count"));
        return new Export(UUID.fromString(response.getHeader("X-Export-Id")), rows, csv, response.getHeader("X-Excluded-Declined"), response.getHeader("X-Excluded-Unanswered"));
    }

    private List<String> audit(UUID patient) {
        return migrador.queryForList("select (detalles->>'tipo') || '|' || (detalles->>'decision') || '|' || (detalles->>'via') from salud_u.evento_auditoria where accion='CONSENTIMIENTO_REGISTRADO' and id_recurso=? order by detalles->>'tipo' desc", String.class, patient);
    }

    private <T> T asActor(Actor actor, String dbRole, java.util.function.Supplier<T> work) {
        var transaction = new org.springframework.transaction.support.TransactionTemplate(new org.springframework.jdbc.datasource.DataSourceTransactionManager(runtimeDataSource));
        return transaction.execute(status -> {
            JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
            runtime.queryForObject("select set_config('salud_u.id_actor', ?, true)", String.class, actor.id().toString());
            runtime.queryForObject("select set_config('salud_u.roles_actor', ?, true)", String.class, dbRole);
            return work.get();
        });
    }

    private void closedEncounter(UUID patient, UUID career, UUID staff) {
        UUID slot = UUID.randomUUID(), appointment = UUID.randomUUID();
        migrador.update("insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) values (?, ?, '2026-II', current_date - 30, 'ACTIVA')", patient, career);
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()-interval '2 days',now()-interval '2 days'+interval '30 minutes',1,'CERRADO',now()-interval '3 days',?)", slot, staff, DOCTOR);
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para) values (?,?,?,'INICIAL','ATENDIDA',?,now()-interval '2 days')", appointment, patient, slot, staff);
        migrador.update("insert into salud_u.encuentro_clinico(id_cita,id_paciente,id_personal,tipo_encuentro,estado,cerrado_en,cerrado_por) values (?,?,?,'INICIAL','CERRADA',now()-interval '2 days',?)", appointment, patient, staff, DOCTOR);
    }

    private org.springframework.test.web.servlet.RequestBuilder get(Actor actor, String path) {
        return MockMvcRequestBuilders.get(path).with(authentication(actor.auth()));
    }

    private org.springframework.test.web.servlet.RequestBuilder post(Actor actor, String path, String body) {
        return MockMvcRequestBuilders.post(path).with(authentication(actor.auth())).with(csrf()).contentType("application/json").content(body);
    }

    private UUID career() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.carrera(id,codigo,nombre) values (?,?,?)", id, "A03-" + id.toString().substring(0, 8), "Carrera A03 " + id);
        return id;
    }

    private UUID patient(UUID principal, String label) {
        UUID id = UUID.randomUUID();
        String tag = label + "-" + id.toString().substring(0, 8);
        migrador.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,telefono,correo,fecha_nacimiento,creado_por,actualizado_por,id_principal) values (?,?,?,?,?,?,?,?,?,date '2004-05-01',?,?,?)",
            id, "CI" + tag, "CI" + tag.replace("-", ""), "REG" + tag, "REG" + tag.replace("-", ""), "Nombre" + tag, "Apellido" + tag, "7" + Math.abs(id.hashCode() % 10000000), tag.toLowerCase() + "@correo.invalid", DOCTOR, DOCTOR, principal);
        return id;
    }

    private UUID staff(UUID principal) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?) on conflict do nothing", id, principal, "A03-" + id);
        return migrador.queryForObject("select id from salud_u.personal where id_principal=?", UUID.class, principal);
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor A03')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor A03", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

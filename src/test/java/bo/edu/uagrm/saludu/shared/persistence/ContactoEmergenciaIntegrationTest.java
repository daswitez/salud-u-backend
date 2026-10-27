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

/** A-02: contacto de emergencia del paciente (RF-02). */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class ContactoEmergenciaIntegrationTest {
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
        String documents = Files.createTempDirectory("salud-u-a02-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "ContactoEmergenciaIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico A02') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
    }

    private static final String ROSA = "{\"fullName\":\"Rosa Contacto\",\"relationship\":\"PARENT\",\"phone\":\"70011122\"}";

    @Test
    void administrationCreatesEditsAndDeletesTheContactAtomicallyWithThePatientAndAuditsWithoutPersonalData() throws Exception {
        Actor admin = actor("ADMINISTRATIVE");
        UUID career = career();
        String patient = "{\"fullName\":\"Ana Contacto\",\"carnet\":\"A02-%s\",\"registrationCode\":\"R-A02-%s\",\"careerId\":\"" + career
            + "\",\"academicPeriod\":\"2026-II\",\"enrollmentStart\":\"2026-07-01\"%s}";
        String suffix = UUID.randomUUID().toString().substring(0, 8);

        // Un contacto inválido rechaza todo: tampoco se crea el paciente.
        mvc.perform(post(admin, "/api/patients", String.format(patient, suffix, suffix, ",\"emergencyContact\":{\"fullName\":\"Rosa\",\"relationship\":\"MOTHER\",\"phone\":\"7\"}")))
            .andExpect(status().isBadRequest());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.paciente where carnet=?", Integer.class, "A02-" + suffix));

        String created = mvc.perform(post(admin, "/api/patients", String.format(patient, suffix, suffix, ",\"emergencyContact\":" + ROSA)))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        UUID id = UUID.fromString(json.readTree(created).at("/data/id").asText());
        detail(admin, id).andExpect(jsonPath("$.data.carnet").value("A02-" + suffix))
            .andExpect(jsonPath("$.data.emergencyContact.fullName").value("Rosa Contacto"))
            .andExpect(jsonPath("$.data.emergencyContact.relationship").value("PARENT"))
            .andExpect(jsonPath("$.data.emergencyContact.phone").value("70011122"));
        assertEquals("PADRE_MADRE", migrador.queryForObject("select parentesco from salud_u.contacto_emergencia where id_paciente=?", String.class, id));

        mvc.perform(patch(admin, id, "{\"phone\":\"71111111\"}")).andExpect(status().isOk());
        detail(admin, id).andExpect(jsonPath("$.data.emergencyContact.phone").value("70011122"));
        mvc.perform(patch(admin, id, "{\"emergencyContact\":{\"fullName\":\"Luis Contacto\",\"relationship\":\"SIBLING\",\"phone\":\"72222222\"}}")).andExpect(status().isOk());
        mvc.perform(patch(admin, id, "{\"emergencyContact\":{\"fullName\":\"Luis Contacto\",\"relationship\":\"SIBLING\",\"phone\":\"72222222\"}}")).andExpect(status().isOk());
        detail(admin, id).andExpect(jsonPath("$.data.emergencyContact.relationship").value("SIBLING"));
        mvc.perform(patch(admin, id, "{\"emergencyContact\":null}")).andExpect(status().isOk());
        detail(admin, id).andExpect(jsonPath("$.data.emergencyContact").value(org.hamcrest.Matchers.nullValue()))
            .andExpect(jsonPath("$.data.fullName").value("Ana Contacto"));
        mvc.perform(patch(admin, id, "{\"emergencyContact\":null}")).andExpect(status().isOk());

        // Creado, modificado y eliminado: los cambios sin efecto no se auditan y la auditoría no lleva nombre ni teléfono.
        List<String> operations = migrador.queryForList("select detalles->>'operacion' from salud_u.evento_auditoria where accion='CONTACTO_EMERGENCIA_ACTUALIZADO' and id_recurso=? order by ocurrido_en, id", String.class, id);
        assertEquals(List.of("CREADO", "MODIFICADO", "ELIMINADO"), operations);
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and (detalles::text like '%Rosa%' or detalles::text like '%7001%' or detalles::text like '%Luis%')", Integer.class, id));
        assertEquals(List.of("ADMINISTRACION"), migrador.queryForList("select distinct detalles->>'origen' from salud_u.evento_auditoria where accion='CONTACTO_EMERGENCIA_ACTUALIZADO' and id_recurso=?", String.class, id));

        // Clientes que no conocen el campo: la lista no cambia y el detalle solo agrega emergencyContact.
        mvc.perform(MockMvcRequestBuilders.get("/api/patients").param("query", "A02-" + suffix).with(authentication(admin.auth())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data[0].emergencyContact").doesNotExist());
        mvc.perform(MockMvcRequestBuilders.get("/api/patients/" + UUID.randomUUID()).with(authentication(admin.auth()))).andExpect(status().isNotFound());
    }

    @Test
    void aStudentSeesAndEditsOnlyTheContactOfTheirOwnRecord() throws Exception {
        Actor ana = actor("STUDENT"), beto = actor("STUDENT"), sinFicha = actor("STUDENT");
        UUID anaPatient = patient(ana.id()), betoPatient = patient(beto.id());
        migrador.update("insert into salud_u.contacto_emergencia(id_paciente,nombre_completo,parentesco,telefono,actualizado_por) values (?,'Contacto de Beto','PAREJA','73333333',?)", betoPatient, DOCTOR);

        mine(ana).andExpect(status().isOk()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data").value(org.hamcrest.Matchers.nullValue()))
            .andExpect(header().string("Cache-Control", "no-store, private"));
        mvc.perform(MockMvcRequestBuilders.put("/api/me/emergency-contact").with(authentication(ana.auth())).contentType("application/json").content(ROSA))
            .andExpect(status().isForbidden());
        putMine(ana, ROSA).andExpect(status().isOk()).andExpect(jsonPath("$.data.fullName").value("Rosa Contacto"));
        mine(ana).andExpect(jsonPath("$.data.relationship").value("PARENT"));
        mine(beto).andExpect(jsonPath("$.data.fullName").value("Contacto de Beto")).andExpect(jsonPath("$.data.relationship").value("PARTNER"));
        assertEquals("Contacto de Beto", migrador.queryForObject("select nombre_completo from salud_u.contacto_emergencia where id_paciente=?", String.class, betoPatient), "Ana no pisó el de Beto");
        assertEquals("ESTUDIANTE", migrador.queryForObject("select detalles->>'origen' from salud_u.evento_auditoria where accion='CONTACTO_EMERGENCIA_ACTUALIZADO' and id_recurso=?", String.class, anaPatient));

        for (String invalid : List.of("{}", "{\"fullName\":\"Rosa\",\"relationship\":\"PARENT\"}", "{\"fullName\":\"Rosa\",\"relationship\":\"parent\",\"phone\":\"7\"}",
                "{\"fullName\":\"Rosa\",\"relationship\":\"PARENT\",\"phone\":\"7\",\"patientId\":\"" + betoPatient + "\"}"))
            putMine(ana, invalid).andExpect(status().isBadRequest());
        mine(sinFicha).andExpect(status().isNotFound());
        putMine(sinFicha, ROSA).andExpect(status().isNotFound());
        // El estudiante no tiene acceso a la ficha administrativa de nadie, tampoco la propia.
        detailRequest(ana, betoPatient).andExpect(status().isForbidden());
        detailRequest(ana, anaPatient).andExpect(status().isForbidden());
        for (String role : List.of("ADMINISTRATIVE", "REVIEW_DOCTOR", "REPORTING_OFFICER")) mine(actor(role)).andExpect(status().isForbidden());
    }

    @Test
    void doctorsReadItInThePatientRecordOnlyWithAClinicalRelationshipAndReportsNeverSeeIt() throws Exception {
        Actor admin = actor("ADMINISTRATIVE"), doctor = actor("REVIEW_DOCTOR"), stranger = actor("REVIEW_DOCTOR"), reports = actor("REPORTING_OFFICER");
        UUID staff = staff(doctor.id()), patient = patient(null);
        staff(stranger.id());
        migrador.update("insert into salud_u.contacto_emergencia(id_paciente,nombre_completo,parentesco,telefono,actualizado_por) values (?,'Tutor A02','TUTOR','74444444',?)", patient, DOCTOR);
        UUID slot = UUID.randomUUID();
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '2 days',now()+interval '2 days 30 minutes',1,'PUBLICADO',now(),?)", slot, staff, DOCTOR);
        migrador.update("insert into salud_u.cita(id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,'INICIAL',?,now()+interval '2 days')", patient, slot, staff);

        mvc.perform(MockMvcRequestBuilders.get("/api/medical/patients/" + patient).with(authentication(doctor.auth())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.emergencyContact.fullName").value("Tutor A02"))
            .andExpect(jsonPath("$.data.emergencyContact.relationship").value("GUARDIAN"));
        mvc.perform(MockMvcRequestBuilders.get("/api/medical/patients/" + patient).with(authentication(stranger.auth())))
            .andExpect(status().isNotFound());
        // Solo lectura: el médico no tiene ninguna ruta para cambiarlo.
        mvc.perform(MockMvcRequestBuilders.patch("/api/patients/" + patient).with(authentication(doctor.auth())).with(csrf())
            .contentType("application/json").content("{\"emergencyContact\":null}")).andExpect(status().isForbidden());

        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForList("select * from salud_u.contacto_emergencia"));
        assertEquals(0, migrador.queryForObject("select count(*) from information_schema.role_table_grants where table_schema='salud_u' and table_name='contacto_emergencia' and grantee='salud_u_runtime'", Integer.class));
        // Ninguna función de reportes, exportaciones o investigación lee la tabla: solo las del contacto y la ficha del médico.
        assertEquals(List.of("contacto_emergencia_json", "escribir_contacto_emergencia", "obtener_historia_longitudinal_area"),
            migrador.queryForList("select proname::text from pg_proc where pronamespace='salud_u'::regnamespace and prosrc ~ '(contacto_emergencia_json|salud_u\\.contacto_emergencia[^_])' order by 1", String.class)
                .stream().filter(name -> !name.contains("mi_") && !name.startsWith("guardar_") && !name.startsWith("obtener_contacto") && !name.startsWith("eliminar_")).toList());
        mvc.perform(MockMvcRequestBuilders.get("/api/patients/" + patient).with(authentication(reports.auth()))).andExpect(status().isForbidden());
        migrador.update("update salud_u.paciente set id_principal=null where id=?", patient);
        UUID reportsPrincipal = reports.id();
        var failure = assertThrows(org.springframework.dao.DataAccessException.class, () -> new org.springframework.transaction.support.TransactionTemplate(
            new org.springframework.jdbc.datasource.DataSourceTransactionManager(runtimeDataSource)).executeWithoutResult(status -> {
                runtime.queryForObject("select set_config('salud_u.id_actor', ?, true)", String.class, reportsPrincipal.toString());
                runtime.queryForObject("select set_config('salud_u.roles_actor', 'RESPONSABLE_REPORTES', true)", String.class);
                runtime.queryForObject("select salud_u.obtener_contacto_emergencia(?)::text", String.class, patient);
            }));
        assertTrue(failure.getMostSpecificCause().getMessage().contains("ADMINISTRATIVO"), failure.getMostSpecificCause().getMessage());
        detail(admin, patient).andExpect(jsonPath("$.data.emergencyContact.phone").value("74444444"));
    }

    private org.springframework.test.web.servlet.RequestBuilder post(Actor actor, String path, String body) {
        return MockMvcRequestBuilders.post(path).with(authentication(actor.auth())).with(csrf()).contentType("application/json").content(body);
    }

    private org.springframework.test.web.servlet.RequestBuilder patch(Actor actor, UUID patient, String body) {
        return MockMvcRequestBuilders.patch("/api/patients/" + patient).with(authentication(actor.auth())).with(csrf()).contentType("application/json").content(body);
    }

    private org.springframework.test.web.servlet.ResultActions detail(Actor actor, UUID patient) throws Exception {
        return detailRequest(actor, patient).andExpect(status().isOk());
    }

    private org.springframework.test.web.servlet.ResultActions detailRequest(Actor actor, UUID patient) throws Exception {
        return mvc.perform(MockMvcRequestBuilders.get("/api/patients/" + patient).with(authentication(actor.auth())));
    }

    private org.springframework.test.web.servlet.ResultActions mine(Actor actor) throws Exception {
        return mvc.perform(MockMvcRequestBuilders.get("/api/me/emergency-contact").with(authentication(actor.auth())));
    }

    private org.springframework.test.web.servlet.ResultActions putMine(Actor actor, String body) throws Exception {
        return mvc.perform(MockMvcRequestBuilders.put("/api/me/emergency-contact").with(authentication(actor.auth())).with(csrf()).contentType("application/json").content(body));
    }

    private UUID career() {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.carrera(id,codigo,nombre) values (?,?,?)", id, "A02-" + id.toString().substring(0, 8), "Carrera A02 " + id);
        return id;
    }

    private UUID patient(UUID principal) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por,id_principal) values (?,?,?,?,?,'Paciente','A02',?,?,?)",
            id, "A02-" + id, "A02" + id, "REG-" + id, "REG" + id, DOCTOR, DOCTOR, principal);
        return id;
    }

    private UUID staff(UUID principal) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", id, principal, "A02-" + id);
        return id;
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor A02')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor A02", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

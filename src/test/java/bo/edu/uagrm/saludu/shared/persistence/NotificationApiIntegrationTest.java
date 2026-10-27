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
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
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
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class NotificationApiIntegrationTest {
    @Container static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withInitScript("notificaciones/crear-rol-runtime.sql")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
    private static final UUID DOCTOR = UUID.randomUUID(), PERSONAL = UUID.randomUUID();
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
        String documents = Files.createTempDirectory("salud-u-n02-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "NotificationApiIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico N02') on conflict do nothing", DOCTOR, DOCTOR + "@example.invalid");
        migrador.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'N02-MEDICO') on conflict do nothing", PERSONAL, DOCTOR);
    }

    @Test
    void ownListAndForeignReadAreIsolatedEvenForAdministrationAndWithoutIdentityFilters() throws Exception {
        Actor own = actor("STUDENT"), other = actor("STUDENT"), admin = actor("ADMINISTRATIVE");
        UUID ownId = notice(appointment(own), own, "CITA_ASIGNADA", past(), "ENTREGADA");
        UUID foreign = notice(appointment(other), other, "CITA_ASIGNADA", past(), "ENTREGADA");
        JsonNode page = ok(get("/api/notifications").param("recipientId", other.id().toString()), own);
        assertEquals(1, page.path("data").size());
        assertEquals(ownId.toString(), page.at("/data/0/id").asText());
        assertFalse(page.toString().contains(foreign.toString()));
        assertEquals(1, page.path("unreadCount").asInt());
        assertEquals(0, ok(get("/api/notifications"), admin).path("data").size());
        assertEquals(1, ok(get("/api/notifications"), other).path("data").size());
        String denied = missingRead(ownId, other), absent = missingRead(UUID.randomUUID(), other);
        assertEquals(denied, absent);
        assertEquals(denied, missingRead(ownId, admin));
        assertEquals("ENTREGADA", migrador.queryForObject("select estado from salud_u.notificacion where id=?", String.class, ownId));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where accion='NOTIFICACION_LEIDA' and id_recurso=?", Integer.class, ownId));
    }

    @Test
    void deliveredCursorPreservesMicrosecondsAndStablePagesWhileNewNoticesArrive() throws Exception {
        Actor own = actor("STUDENT");
        UUID appointment = appointment(own);
        var time = past().withNano(123456000);
        UUID first = notice(appointment, own, "CITA_ASIGNADA", time, "ENTREGADA");
        UUID second = notice(appointment, own, "CITA_CANCELADA", time.minusNanos(1000), "ENTREGADA");
        UUID third = notice(appointment, own, "AUSENCIA_REGISTRADA", time.minusNanos(2000), "ENTREGADA");
        JsonNode page = ok(get("/api/notifications").param("limit", "1"), own);
        assertEquals(first.toString(), page.at("/data/0/id").asText());
        assertTrue(page.at("/pagination/hasMore").asBoolean());
        assertTrue(page.at("/pagination/nextCursor").asText().contains(".123456"));
        assertEquals(3, page.path("unreadCount").asInt());
        notice(appointment, own, "CITA_REPROGRAMADA", time.plusSeconds(10), "ENTREGADA");
        JsonNode older = ok(get("/api/notifications").param("limit", "2").param("before", page.at("/pagination/nextCursor").asText()), own);
        assertEquals(List.of(second.toString(), third.toString()), List.of(older.at("/data/0/id").asText(), older.at("/data/1/id").asText()));
        assertFalse(older.at("/pagination/hasMore").asBoolean());
        assertTrue(older.at("/pagination/nextCursor").isNull());
        assertEquals(4, older.path("unreadCount").asInt());
        // Las fechas idénticas se desempatan por UUID, sin perder filas.
        migrador.update("update salud_u.notificacion set entregada_en=? where id in (?,?)", time, second, third);
        var ids = migrador.queryForList("select id::text from salud_u.notificacion where id_destinatario=? order by entregada_en desc,id desc", String.class, own.id());
        JsonNode all = ok(get("/api/notifications").param("limit", "100"), own);
        assertEquals(ids, java.util.stream.StreamSupport.stream(all.path("data").spliterator(), false).map(n -> n.path("id").asText()).toList());
    }

    @Test
    void markingReadIsIdempotentAndQueuesOrFutureDeliveriesStayInvisible() throws Exception {
        Actor own = actor("STUDENT");
        UUID appointment = appointment(own);
        UUID delivered = notice(appointment, own, "CITA_ASIGNADA", past(), "ENTREGADA");
        UUID pending = notice(appointment, own, "CITA_CANCELADA", OffsetDateTime.now().plusDays(1), "PENDIENTE");
        UUID future = notice(appointment, own, "AUSENCIA_REGISTRADA", OffsetDateTime.now().plusDays(1), "ENTREGADA");
        JsonNode first = ok(patch("/api/notifications/{id}/read", delivered).with(csrf()), own);
        JsonNode repeated = ok(patch("/api/notifications/{id}/read", delivered).with(csrf()), own);
        assertEquals("READ", first.at("/data/status").asText());
        assertEquals(first.at("/data/readAt"), repeated.at("/data/readAt"));
        assertFalse(first.at("/data/readAt").isNull());
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where accion='NOTIFICACION_LEIDA' and id_recurso=?", Integer.class, delivered));
        JsonNode page = ok(get("/api/notifications"), own);
        assertEquals(1, page.path("data").size());
        assertEquals(0, page.path("unreadCount").asInt());
        assertEquals(missingRead(pending, own), missingRead(future, own));
        assertEquals("PENDIENTE", migrador.queryForObject("select estado from salud_u.notificacion where id=?", String.class, pending));
    }

    @Test
    void preferenceDefaultsDoNotWriteAndPutOnlyPersistsOwnOptionsWithAudit() throws Exception {
        Actor own = actor("REPORTING_OFFICER"), other = actor("STUDENT");
        JsonNode defaults = ok(get("/api/me/notification-preferences"), own);
        assertTrue(defaults.at("/data/receiveReminders").asBoolean());
        assertTrue(defaults.at("/data/reinforcedReminder").asBoolean());
        assertTrue(defaults.at("/data/updatedAt").isNull());
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.preferencia_notificacion where id_principal=?", Integer.class, own.id()));
        JsonNode saved = ok(put("/api/me/notification-preferences").with(csrf()).contentType("application/json")
            .content("{\"receiveReminders\":false,\"reinforcedReminder\":true}"), own);
        assertFalse(saved.at("/data/receiveReminders").asBoolean());
        assertTrue(saved.at("/data/reinforcedReminder").asBoolean());
        assertFalse(saved.at("/data/updatedAt").isNull());
        assertEquals(saved, ok(get("/api/me/notification-preferences"), own));
        assertTrue(ok(get("/api/me/notification-preferences"), other).at("/data/receiveReminders").asBoolean());
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where id_actor=? and accion='PREFERENCIAS_NOTIFICACION_ACTUALIZADAS'", Integer.class, own.id()));
        mvc.perform(put("/api/me/notification-preferences").with(authentication(own.auth())).with(csrf()).contentType("application/json")
            .content("{\"receiveReminders\":true,\"reinforcedReminder\":false,\"principalId\":\"" + other.id() + "\"}"))
            .andExpect(status().isBadRequest());
        assertFalse(ok(get("/api/me/notification-preferences"), own).at("/data/receiveReminders").asBoolean());
    }

    @Test
    void reprogrammingReusesItsReadNoticeAndMakesItUnreadAndNewestAgain() throws Exception {
        Actor own = actor("STUDENT");
        UUID appointment = appointment(own);
        migrador.update("update salud_u.cita set estado='PROGRAMADA',programada_para=programada_para+interval '1 day' where id=?", appointment);
        UUID id = migrador.queryForObject("select id from salud_u.notificacion where id_cita=? and tipo_evento='CITA_REPROGRAMADA'", UUID.class, appointment);
        ok(patch("/api/notifications/{id}/read", id).with(csrf()), own);
        assertEquals(0, ok(get("/api/notifications"), own).path("unreadCount").asInt());
        migrador.update("update salud_u.cita set programada_para=programada_para+interval '1 day' where id=?", appointment);
        JsonNode page = ok(get("/api/notifications"), own);
        assertEquals(id.toString(), page.at("/data/0/id").asText());
        assertEquals("DELIVERED", page.at("/data/0/status").asText());
        assertEquals(1, page.path("unreadCount").asInt());
        assertTrue(page.at("/data/0/readAt").isNull());
    }

    @Test
    void writeFailureRollsBackReadStateAndReturnsSanitized500() throws Exception {
        Actor own = actor("STUDENT");
        UUID id = notice(appointment(own), own, "CITA_ASIGNADA", past(), "ENTREGADA");
        migrador.execute("create function salud_u.fallo_auditoria_n02() returns trigger language plpgsql as $$ begin if NEW.id_recurso='" + id + "'::uuid and NEW.accion='NOTIFICACION_LEIDA' then raise exception 'DETALLE_PRIVADO_N02'; end if; return NEW; end $$");
        migrador.execute("create trigger fallo_auditoria_n02 after insert on salud_u.evento_auditoria for each row execute function salud_u.fallo_auditoria_n02()");
        try {
            mvc.perform(patch("/api/notifications/{id}/read", id).with(authentication(own.auth())).with(csrf()))
                .andExpect(status().isInternalServerError()).andExpect(jsonPath("$.error").value("No se pudo completar la operación. Inténtalo nuevamente."));
            assertEquals("ENTREGADA", migrador.queryForObject("select estado from salud_u.notificacion where id=?", String.class, id));
            assertNull(migrador.queryForObject("select leida_en from salud_u.notificacion where id=?", OffsetDateTime.class, id));
        } finally {
            migrador.execute("drop trigger fallo_auditoria_n02 on salud_u.evento_auditoria");
            migrador.execute("drop function salud_u.fallo_auditoria_n02()");
        }
    }

    private JsonNode ok(MockHttpServletRequestBuilder request, Actor actor) throws Exception {
        return json.readTree(mvc.perform(request.with(authentication(actor.auth())))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store, private"))
            .andReturn().getResponse().getContentAsByteArray());
    }

    private String missingRead(UUID id, Actor actor) throws Exception {
        return mvc.perform(patch("/api/notifications/{id}/read", id).with(authentication(actor.auth())).with(csrf()))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("Notificación no encontrada."))
            .andReturn().getResponse().getContentAsString();
    }

    private Actor actor(String role) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor N02')", id, id + "@example.invalid");
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Actor(id, role);
    }

    private UUID appointment(Actor actor) {
        UUID patient = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID();
        migrador.update("insert into salud_u.paciente(id,id_principal,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,?,'Paciente','N02',?,?)", patient, actor.id(), "N02-" + patient, "N02" + patient, "REG-" + patient, "REG" + patient, DOCTOR, DOCTOR);
        var time = OffsetDateTime.now().plusDays(10);
        migrador.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,?,1,'PUBLICADO',now(),?)", slot, PERSONAL, time, time.plusMinutes(30), DOCTOR);
        // Los fixtures históricos ATENDIDA no generan el aviso de asignación de N-01.
        migrador.update("insert into salud_u.cita(id,id_paciente,id_cupo,id_personal_asignado,tipo_cita,estado,programada_para) values (?,?,?,?,'INICIAL','ATENDIDA',?)", appointment, patient, slot, PERSONAL, time);
        return appointment;
    }

    private UUID notice(UUID appointment, Actor actor, String type, OffsetDateTime time, String state) {
        UUID id = UUID.randomUUID();
        migrador.update("insert into salud_u.notificacion(id,id_destinatario,id_cita,tipo_evento,asunto,mensaje,estado,programada_para,entregada_en) values (?,?,?,?,'Aviso N02','Mensaje operativo',?,?,?)",
            id, actor.id(), appointment, type, state, time, state.equals("PENDIENTE") ? null : time);
        return id;
    }

    private static OffsetDateTime past() { return OffsetDateTime.now(ZoneOffset.UTC).minusDays(1); }
    private record Actor(UUID id, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, id + "@example.invalid", "Actor N02", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

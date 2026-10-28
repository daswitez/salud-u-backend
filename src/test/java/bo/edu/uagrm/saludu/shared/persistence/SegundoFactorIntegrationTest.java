package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import bo.edu.uagrm.saludu.identity.application.Totp;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.Cookie;
import java.nio.file.Files;
import java.time.Instant;
import java.util.ArrayList;
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
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/** SEG-2FA: segundo factor TOTP para médico de revisión y especialista, de punta a punta por HTTP y contra PostgreSQL. */
@SpringBootTest
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class SegundoFactorIntegrationTest {
    @Container static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u").withUsername("salud_u_migrator").withPassword("migrator-test-password")
        .withInitScript("notificaciones/crear-rol-runtime.sql")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");
    private static final String PASSWORD = "Clave-Sintetica-2FA-2026";
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
        String documents = Files.createTempDirectory("salud-u-2fa-documentos-").toString();
        registry.add("salud-u.documents.root", () -> documents);
    }

    @AfterAll
    static void coverage() {
        if (runtimePool == null) return;
        runtimePool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "SegundoFactorIntegrationTest");
    }

    @BeforeEach
    void fixtures() {
        runtimePool = runtimeDataSource;
        migrador = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password"));
    }

    @Test
    void elMedicoActivaElSegundoFactorYLuegoIngresaConCodigoSinRepetirlo() throws Exception {
        Account doctor = account("REVIEW_DOCTOR");
        // Contraseña correcta: todavía no hay sesión, solo la cookie del desafío.
        MvcResult first = login(doctor).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.secondFactorRequired").value(true))
            .andExpect(jsonPath("$.data.enrollmentRequired").value(true))
            .andExpect(jsonPath("$.data.user").doesNotExist()).andReturn();
        assertNull(first.getResponse().getCookie("SALUD_U_SESSION"));
        String setCookie = String.join(";", first.getResponse().getHeaders("Set-Cookie"));
        assertTrue(setCookie.contains("SALUD_U_2FA=") && setCookie.contains("HttpOnly") && setCookie.contains("SameSite=Strict")
            && setCookie.contains("Max-Age=300") && setCookie.contains("Path=/api/v1/auth"), setCookie);
        Cookie challenge = first.getResponse().getCookie("SALUD_U_2FA");
        assertEquals(0, sessions(doctor));

        // Sin generar el QR no se puede confirmar; luego el secreto llega una sola vez.
        confirm(challenge, "123456").andExpect(status().isConflict());
        JsonNode enrollment = data(mvc.perform(post("/api/v1/auth/second-factor/enrollment").with(csrf()).cookie(challenge)).andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store")).andReturn());
        byte[] secret = base32(enrollment.get("secret").asText());
        assertTrue(enrollment.get("otpauthUri").asText().startsWith("otpauth://totp/Salud-U:" + doctor.email().replace("@", "%40") + "?secret="));
        byte[] stored = migrador.queryForObject("select secreto_cifrado from salud_u.segundo_factor_principal where id_principal=?", byte[].class, doctor.id());
        assertFalse(contains(stored, secret), "el secreto no queda en claro en la base");
        assertNull(migrador.queryForObject("select activado_en from salud_u.segundo_factor_principal where id_principal=?", Instant.class, doctor.id()));

        confirm(challenge, wrong(secret)).andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error.code").value("SECOND_FACTOR_INVALID"));
        long step = Totp.step(Instant.now().getEpochSecond());
        MvcResult activated = confirm(challenge, Totp.code(secret, step)).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.user.clinicalRole").value("REVIEW_DOCTOR"))
            .andExpect(jsonPath("$.data.recoveryCodes.length()").value(10)).andReturn();
        assertNotNull(activated.getResponse().getCookie("SALUD_U_SESSION"));
        assertEquals(0, activated.getResponse().getCookie("SALUD_U_2FA").getMaxAge(), "se borra la cookie del desafío");
        assertEquals(1, sessions(doctor));
        List<String> recovery = new ArrayList<>();
        data(activated).get("recoveryCodes").forEach(code -> recovery.add(code.asText()));
        assertEquals(10, migrador.queryForObject("select count(*) from salud_u.codigo_recuperacion_principal where id_principal=? and usado_en is null and octet_length(hash_codigo)=32", Integer.class, doctor.id()));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.codigo_recuperacion_principal where hash_codigo = sha256(convert_to(?, 'UTF8'))", Integer.class, recovery.getFirst()),
            "se guarda el hash del código normalizado, no el código tal como se muestra");
        // El desafío ya se usó.
        confirm(challenge, Totp.code(secret, step + 1)).andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error.code").value("SECOND_FACTOR_CHALLENGE_INVALID"));

        // Segundo ingreso: el mismo código (mismo paso) no se acepta dos veces; el del paso siguiente, sí.
        Cookie second = challenge(login(doctor).andExpect(jsonPath("$.data.enrollmentRequired").value(false)));
        verify(second, Totp.code(secret, step)).andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error.code").value("SECOND_FACTOR_INVALID"));
        verify(second, Totp.code(secret, step + 1)).andExpect(status().isOk()).andExpect(jsonPath("$.data.user.id").value(doctor.id().toString()))
            .andExpect(jsonPath("$.data.recoveryCodes").doesNotExist());
        assertEquals(step + 1, migrador.queryForObject("select ultimo_paso_usado from salud_u.segundo_factor_principal where id_principal=?", Long.class, doctor.id()));

        // Código de recuperación: sirve una sola vez, escrito en minúsculas y sin guiones.
        Cookie third = challenge(login(doctor));
        recoveryCode(third, recovery.get(3).toLowerCase().replace("-", "")).andExpect(status().isOk());
        recoveryCode(challenge(login(doctor)), recovery.get(3)).andExpect(status().isUnauthorized());

        // Desafío vencido.
        Cookie expired = challenge(login(doctor));
        migrador.update("update salud_u.desafio_segundo_factor set creado_en = now() - interval '10 minutes', vence_en = now() - interval '1 minute' where id_principal=? and usado_en is null", doctor.id());
        verify(expired, Totp.code(secret, step + 1)).andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error.code").value("SECOND_FACTOR_CHALLENGE_INVALID"));

        // Perfil: estado y regeneración de códigos con un código válido; los anteriores dejan de servir.
        mvc.perform(get("/api/v1/profile/second-factor").with(authentication(doctor.auth()))).andExpect(status().isOk())
            .andExpect(jsonPath("$.data.required").value(true)).andExpect(jsonPath("$.data.enabled").value(true))
            .andExpect(jsonPath("$.data.remainingRecoveryCodes").value(9));
        regenerate(doctor, wrong(secret)).andExpect(status().isUnauthorized());
        long regenerationStep = waitForStepAfter(step + 1);
        JsonNode regenerated = data(regenerate(doctor, Totp.code(secret, regenerationStep)).andExpect(status().isOk()).andReturn());
        assertEquals(10, regenerated.get("recoveryCodes").size());
        recoveryCode(challenge(login(doctor)), recovery.get(5)).andExpect(status().isUnauthorized());
        recoveryCode(challenge(login(doctor)), regenerated.get("recoveryCodes").get(0).asText()).andExpect(status().isOk());

        // Auditoría: eventos con resultado y sin secreto, código ni token.
        List<String> events = migrador.queryForList("select accion from salud_u.evento_auditoria where id_recurso=? order by ocurrido_en, id", String.class, doctor.id());
        for (String event : List.of("SEGUNDO_FACTOR_ACTIVADO", "SEGUNDO_FACTOR_VERIFICADO", "SEGUNDO_FACTOR_FALLIDO", "CODIGO_RECUPERACION_USADO", "CODIGOS_RECUPERACION_REGENERADOS")) {
            assertTrue(events.contains(event), event + " en " + events);
        }
        String details = String.join("|", migrador.queryForList("select detalles::text from salud_u.evento_auditoria where id_recurso=?", String.class, doctor.id()));
        assertFalse(details.contains(enrollment.get("secret").asText()));
        for (String code : recovery) assertFalse(details.contains(code) || details.contains(code.replace("-", "")));
        assertFalse(details.matches("(?s).*\\b\\d{6}\\b.*"), "ningún código de 6 dígitos en la auditoría: " + details);
    }

    @Test
    void cincoCodigosFallidosBloqueanQuinceMinutosAunqueSeCambieDeDesafio() throws Exception {
        Account specialist = account("SPECIALIST");
        Cookie challenge = challenge(login(specialist));
        mvc.perform(post("/api/v1/auth/second-factor/enrollment").with(csrf()).cookie(challenge)).andExpect(status().isOk());
        String body = mvc.perform(post("/api/v1/auth/second-factor/enrollment").with(csrf()).cookie(challenge)).andReturn().getResponse().getContentAsString();
        byte[] secret = base32(json.readTree(body).at("/data/secret").asText());
        confirm(challenge, Totp.code(secret, Totp.step(Instant.now().getEpochSecond()))).andExpect(status().isOk());

        Cookie next = challenge(login(specialist));
        for (int attempt = 1; attempt <= 4; attempt++) verify(next, wrong(secret)).andExpect(status().isUnauthorized());
        verify(next, wrong(secret)).andExpect(status().isTooManyRequests()).andExpect(jsonPath("$.error.code").value("SECOND_FACTOR_LOCKED"));
        assertTrue(migrador.queryForObject("select bloqueado_hasta between now() + interval '14 minutes' and now() + interval '16 minutes' from salud_u.segundo_factor_principal where id_principal=?", Boolean.class, specialist.id()));
        // Otro desafío con el código correcto sigue bloqueado y no emite sesión.
        int before = sessions(specialist);
        verify(challenge(login(specialist)), Totp.code(secret, Totp.step(Instant.now().getEpochSecond()) + 1)).andExpect(status().isTooManyRequests());
        assertEquals(before, sessions(specialist));
        List<String> events = migrador.queryForList("select accion from salud_u.evento_auditoria where id_recurso=?", String.class, specialist.id());
        assertEquals(6, events.stream().filter("SEGUNDO_FACTOR_FALLIDO"::equals).count(), "5 fallos y 1 intento durante el bloqueo");
        assertEquals(1, events.stream().filter("SEGUNDO_FACTOR_BLOQUEADO"::equals).count());

        // Pasado el bloqueo vuelve a ingresar y el contador empieza de nuevo.
        migrador.update("update salud_u.segundo_factor_principal set bloqueado_hasta = now() - interval '1 second' where id_principal=?", specialist.id());
        verify(challenge(login(specialist)), wrong(secret)).andExpect(status().isUnauthorized());
        assertEquals(1, migrador.queryForObject("select cantidad_intentos_fallidos from salud_u.segundo_factor_principal where id_principal=?", Integer.class, specialist.id()));
    }

    @Test
    void administracionRestableceElSegundoFactorDeOtraCuentaPeroNoElPropio() throws Exception {
        Account doctor = account("REVIEW_DOCTOR"), admin = account("ADMINISTRATIVE"), auditor = account("AUDITOR");
        Cookie challenge = challenge(login(doctor));
        byte[] secret = base32(data(mvc.perform(post("/api/v1/auth/second-factor/enrollment").with(csrf()).cookie(challenge)).andReturn()).get("secret").asText());
        JsonNode activated = data(confirm(challenge, Totp.code(secret, Totp.step(Instant.now().getEpochSecond()))).andExpect(status().isOk()).andReturn());
        String oldRecovery = activated.get("recoveryCodes").get(0).asText();
        assertEquals(1, sessions(doctor));

        mvc.perform(post("/api/v1/admin/users/" + doctor.id() + "/second-factor/reset").with(authentication(admin.auth()))).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/admin/users/" + doctor.id() + "/second-factor/reset").with(authentication(auditor.auth())).with(csrf())).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/admin/users/" + doctor.id() + "/second-factor/reset").with(authentication(doctor.auth())).with(csrf())).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/admin/users/" + admin.id() + "/second-factor/reset").with(authentication(admin.auth())).with(csrf()))
            .andExpect(status().isForbidden()).andExpect(jsonPath("$.error.code").value("SECOND_FACTOR_SELF_RESET"));
        mvc.perform(post("/api/v1/admin/users/" + UUID.randomUUID() + "/second-factor/reset").with(authentication(admin.auth())).with(csrf())).andExpect(status().isNotFound());
        mvc.perform(post("/api/v1/admin/users/" + doctor.id() + "/second-factor/reset").with(authentication(admin.auth())).with(csrf()))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.reset").value(true));

        // Borrado lógico: sin secreto ni activación, códigos anulados, sesiones revocadas; el próximo ingreso vuelve a activar.
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.segundo_factor_principal where id_principal=? and secreto_cifrado is null and activado_en is null", Integer.class, doctor.id()));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.codigo_recuperacion_principal where id_principal=? and usado_en is null", Integer.class, doctor.id()));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.sesion_autenticacion where id_principal=? and revocado_en is null", Integer.class, doctor.id()));
        Cookie again = challenge(login(doctor).andExpect(jsonPath("$.data.enrollmentRequired").value(true)));
        recoveryCode(again, oldRecovery).andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error.code").value("SECOND_FACTOR_CHALLENGE_INVALID"));
        assertEquals(1, migrador.queryForObject("select count(*) from salud_u.evento_auditoria where accion='SEGUNDO_FACTOR_RESTABLECIDO' and id_recurso=? and id_actor=?", Integer.class, doctor.id(), admin.id()));
    }

    @Test
    void losRolesSinSegundoFactorInicianSesionIgualQueAntes() throws Exception {
        for (String role : List.of("STUDENT", "ADMINISTRATIVE", "AUDITOR", "REPORTING_OFFICER")) {
            Account account = account(role);
            MvcResult result = login(account).andExpect(status().isOk())
                .andExpect(jsonPath("$.data.user.clinicalRole").value(role))
                .andExpect(jsonPath("$.data.secondFactorRequired").doesNotExist())
                .andExpect(jsonPath("$.data.enrollmentRequired").doesNotExist()).andReturn();
            assertNotNull(result.getResponse().getCookie("SALUD_U_SESSION"), role);
            assertNull(result.getResponse().getCookie("SALUD_U_2FA"), role);
            assertEquals(1, sessions(account), role);
            mvc.perform(get("/api/v1/profile/second-factor").with(authentication(account.auth())))
                .andExpect(jsonPath("$.data.required").value(false)).andExpect(jsonPath("$.data.enabled").value(false));
        }
        // La contraseña incorrecta de un médico no crea desafío ni revela que exige segundo factor.
        Account doctor = account("REVIEW_DOCTOR");
        mvc.perform(post("/api/v1/auth/login").with(csrf()).contentType("application/json")
                .content("{\"email\":\"" + doctor.email() + "\",\"password\":\"incorrecta\"}"))
            .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.error.code").value("INVALID_CREDENTIALS"));
        assertEquals(0, migrador.queryForObject("select count(*) from salud_u.desafio_segundo_factor where id_principal=?", Integer.class, doctor.id()));
        // El rol de la aplicación no lee ni escribe las tablas nuevas directamente.
        JdbcTemplate runtime = new JdbcTemplate(runtimeDataSource);
        for (String table : List.of("segundo_factor_principal", "codigo_recuperacion_principal", "desafio_segundo_factor")) {
            assertThrows(org.springframework.dao.DataAccessException.class, () -> runtime.queryForList("select * from salud_u." + table), table);
            assertTrue(migrador.queryForObject("select relforcerowsecurity from pg_class where oid = ('salud_u.' || ?)::regclass", Boolean.class, table), table);
        }
    }

    private ResultActions login(Account account) throws Exception {
        return mvc.perform(post("/api/v1/auth/login").with(csrf()).contentType("application/json")
            .content("{\"email\":\"" + account.email() + "\",\"password\":\"" + PASSWORD + "\"}"));
    }

    private Cookie challenge(ResultActions login) throws Exception {
        Cookie cookie = login.andExpect(status().isOk()).andExpect(jsonPath("$.data.secondFactorRequired").value(true)).andReturn().getResponse().getCookie("SALUD_U_2FA");
        assertNotNull(cookie);
        return cookie;
    }

    private ResultActions verify(Cookie challenge, String code) throws Exception {
        return mvc.perform(post("/api/v1/auth/second-factor").with(csrf()).cookie(challenge).contentType("application/json").content("{\"code\":\"" + code + "\"}"));
    }

    private ResultActions recoveryCode(Cookie challenge, String code) throws Exception {
        return mvc.perform(post("/api/v1/auth/second-factor").with(csrf()).cookie(challenge).contentType("application/json").content("{\"recoveryCode\":\"" + code + "\"}"));
    }

    private ResultActions confirm(Cookie challenge, String code) throws Exception {
        return mvc.perform(post("/api/v1/auth/second-factor/enrollment/confirm").with(csrf()).cookie(challenge).contentType("application/json").content("{\"code\":\"" + code + "\"}"));
    }

    private ResultActions regenerate(Account account, String code) throws Exception {
        return mvc.perform(post("/api/v1/profile/second-factor/recovery-codes").with(authentication(account.auth())).with(csrf())
            .contentType("application/json").content("{\"code\":\"" + code + "\"}"));
    }

    private JsonNode data(MvcResult result) throws Exception {
        return json.readTree(result.getResponse().getContentAsString()).get("data");
    }

    private int sessions(Account account) {
        return migrador.queryForObject("select count(*) from salud_u.sesion_autenticacion where id_principal=? and revocado_en is null", Integer.class, account.id());
    }

    /** Un código que no corresponde a ningún paso de la ventana. */
    private static String wrong(byte[] secret) {
        long step = Totp.step(Instant.now().getEpochSecond());
        for (int candidate = 0; ; candidate++) {
            String code = String.format("%06d", candidate);
            boolean used = false;
            for (long s = step - 2; s <= step + 2; s++) used |= Totp.code(secret, s).equals(code);
            if (!used) return code;
        }
    }

    /** Primer paso mayor que {@code used} que el servidor todavía acepta; espera si hace falta. */
    private static long waitForStepAfter(long used) throws InterruptedException {
        while (Totp.step(Instant.now().getEpochSecond()) + 1 <= used) Thread.sleep(1000);
        return used + 1;
    }

    private Account account(String role) {
        UUID id = UUID.randomUUID();
        String email = "seg2fa-" + id.toString().substring(0, 8) + "@example.invalid";
        migrador.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", id, email, "Cuenta sintética " + role);
        migrador.update("insert into salud_u.credencial_principal(id_principal,hash_contrasena) values (?, salud_u.crypt(?, salud_u.gen_salt('bf', 4)))", id, PASSWORD);
        migrador.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,salud_u.desde_codigo_api('rol',?)::salud_u.codigo_rol_aplicacion)", id, role);
        return new Account(id, email, role);
    }

    private static boolean contains(byte[] haystack, byte[] needle) {
        outer:
        for (int i = 0; i + needle.length <= haystack.length; i++) {
            for (int j = 0; j < needle.length; j++) if (haystack[i + j] != needle[j]) continue outer;
            return true;
        }
        return false;
    }

    private static byte[] base32(String value) {
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        var out = new java.io.ByteArrayOutputStream();
        int buffer = 0, bits = 0;
        for (char c : value.toCharArray()) {
            buffer = (buffer << 5) | alphabet.indexOf(c);
            bits += 5;
            if (bits >= 8) {
                out.write((buffer >> (bits - 8)) & 0xff);
                bits -= 8;
            }
        }
        return out.toByteArray();
    }

    private record Account(UUID id, String email, String role) {
        UsernamePasswordAuthenticationToken auth() {
            return new UsernamePasswordAuthenticationToken(new SessionPrincipal(id, email, "Cuenta sintética", List.of(role)),
                null, List.of(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }
}

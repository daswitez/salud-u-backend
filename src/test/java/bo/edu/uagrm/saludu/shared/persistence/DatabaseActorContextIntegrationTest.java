package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityService;
import bo.edu.uagrm.saludu.identity.application.AuthProperties;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.application.ProfileService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.patients.application.DuplicatePatientIdentifierException;
import bo.edu.uagrm.saludu.patients.application.PatientService;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.util.ArrayList;
import java.time.Duration;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.temporal.TemporalAdjusters;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

@Testcontainers(disabledWithoutDocker = true)
class DatabaseActorContextIntegrationTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u")
        .withUsername("salud_u_migrator")
        .withPassword("migrator-test-password");

    private static HikariDataSource runtimeDataSource;
    private static JdbcTemplate migratorJdbc;
    private static JdbcTemplate runtimeJdbc;
    private static TransactionTemplate transaction;
    private static DatabaseActorContext actorContext;
    private static AuditWriter auditWriter;
    private static AuthenticationService authenticationService;
    private static ProfileService profileService;
    private static PatientService patientService;
    private static AvailabilityService availabilityService;
    private static UUID clinicianId;
    private static UUID auditorId;
    private static UUID studentId;
    private static UUID lockedStudentId;
    private static UUID concurrentStudentId;
    private static UUID administratorId;
    private static UUID profileStudentId;
    private static UUID patientCareerId;
    private static UUID availabilityClinicianId;
    private static UUID availabilityStaffId;

    @BeforeAll
    static void setUp() {
        POSTGRES.start();
        migratorJdbc = new JdbcTemplate(migratorDataSource());
        migratorJdbc.execute("CREATE ROLE salud_u_runtime LOGIN PASSWORD 'runtime-test-password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS");
        Flyway.configure()
            .dataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password")
            .schemas("salud_u")
            .defaultSchema("salud_u")
            .createSchemas(true)
            .placeholders(Map.of("runtime_role", "salud_u_runtime", "migrator_role", "salud_u_migrator"))
            .load()
            .migrate();

        runtimeDataSource = runtimeDataSource();
        runtimeJdbc = new JdbcTemplate(runtimeDataSource);
        transaction = new TransactionTemplate(new DataSourceTransactionManager(runtimeDataSource));
        actorContext = new DatabaseActorContext(runtimeJdbc);
        auditWriter = new AuditWriter(runtimeJdbc, new ObjectMapper());
        var authProperties = new AuthProperties();
        authProperties.setSessionTtl(Duration.ofHours(8));
        authenticationService = new AuthenticationService(runtimeJdbc, authProperties);
        profileService = new ProfileService(runtimeJdbc, actorContext, auditWriter);
        patientService = new PatientService(runtimeJdbc, actorContext, auditWriter);
        availabilityService = new AvailabilityService(runtimeJdbc, actorContext, auditWriter, new ObjectMapper());
        clinicianId = UUID.randomUUID();
        auditorId = UUID.randomUUID();
        studentId = UUID.randomUUID();
        lockedStudentId = UUID.randomUUID();
        concurrentStudentId = UUID.randomUUID();
        administratorId = UUID.randomUUID();
        profileStudentId = UUID.randomUUID();
        patientCareerId = UUID.randomUUID();
        availabilityClinicianId = UUID.randomUUID();
        availabilityStaffId = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.carrera(id, code, name) values (?, ?, ?)", patientCareerId, "MED", "Medicina");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", clinicianId, "clinician@example.invalid", "Clínico sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", auditorId, "auditor@example.invalid", "Auditor sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", studentId, "student@example.invalid", "Estudiante sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", lockedStudentId, "locked@example.invalid", "Estudiante limitado");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", concurrentStudentId, "concurrent@example.invalid", "Estudiante concurrente");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", administratorId, "administrator@example.invalid", "Administrativo sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", profileStudentId, "profile@example.invalid", "Perfil sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, display_name) values (?, ?, ?)", availabilityClinicianId, "availability-doctor@example.invalid", "Médico disponibilidad");
        migratorJdbc.update("insert into salud_u.rol_principal(principal_id, role_code) values (?, cast(? as salud_u.codigo_rol_aplicacion))", studentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(principal_id, role_code) values (?, cast(? as salud_u.codigo_rol_aplicacion))", lockedStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(principal_id, role_code) values (?, cast(? as salud_u.codigo_rol_aplicacion))", concurrentStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(principal_id, role_code) values (?, cast(? as salud_u.codigo_rol_aplicacion))", administratorId, "ADMINISTRATIVE");
        migratorJdbc.update("insert into salud_u.rol_principal(principal_id, role_code) values (?, cast(? as salud_u.codigo_rol_aplicacion))", profileStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(principal_id, role_code) values (?, cast(? as salud_u.codigo_rol_aplicacion))", availabilityClinicianId, "REVIEW_DOCTOR");
        migratorJdbc.update("insert into salud_u.personal(id, principal_id, staff_code) values (?, ?, ?)", availabilityStaffId, availabilityClinicianId, "AVAIL-DOCTOR");
        migratorJdbc.update("insert into salud_u.credencial_principal(principal_id, password_hash) values (?, crypt(?, gen_salt('bf', 10)))", studentId, "student-password");
        migratorJdbc.update("insert into salud_u.credencial_principal(principal_id, password_hash) values (?, crypt(?, gen_salt('bf', 10)))", lockedStudentId, "locked-password");
        migratorJdbc.update("insert into salud_u.credencial_principal(principal_id, password_hash) values (?, crypt(?, gen_salt('bf', 10)))", concurrentStudentId, "concurrent-password");
        migratorJdbc.update("insert into salud_u.credencial_principal(principal_id, password_hash) values (?, crypt(?, gen_salt('bf', 10)))", profileStudentId, "profile-current-password");
    }

    @AfterAll
    static void tearDown() {
        if (runtimeDataSource != null) {
            runtimeDataSource.close();
        }
        POSTGRES.stop();
    }

    @Test
    void runtimeCannotWriteAuditTableDirectlyAndAuditIsVisibleOnlyToAuditor() {
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update(
            "insert into salud_u.evento_auditoria(actor_id, action, resource_type, outcome) values (?, 'DIRECT', 'audit_event', 'SUCCESS')",
            clinicianId
        ));
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            var eventId = auditWriter.append("CLINICAL_RECORD_READ", "patient", UUID.randomUUID(), AuditOutcome.SUCCESS, Map.of("source", "visibility-test"));
            assertNotNull(eventId);
            assertEquals(0, runtimeJdbc.queryForObject("select count(*) from salud_u.evento_auditoria", Integer.class));
        });
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update("update salud_u.evento_auditoria set action = 'ALTERED'"));
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update("delete from salud_u.evento_auditoria"));

        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
            assertEquals(1, runtimeJdbc.queryForObject(
                "select count(*) from salud_u.evento_auditoria where details ->> 'source' = 'visibility-test'", Integer.class
            ));
        });
    }

    @Test
    void concurrentAuditWritesRemainCompleteAndVisibleToAuditor() throws Exception {
        UUID batchId = UUID.randomUUID();
        CountDownLatch ready = new CountDownLatch(4);
        CountDownLatch start = new CountDownLatch(1);
        try (var executor = Executors.newFixedThreadPool(4)) {
            var writes = new ArrayList<java.util.concurrent.Future<UUID>>();
            for (int index = 0; index < 4; index++) {
                final int eventNumber = index;
                writes.add(executor.submit(() -> {
                    ready.countDown();
                    if (!start.await(5, TimeUnit.SECONDS)) {
                        throw new IllegalStateException("No se inició la prueba concurrente.");
                    }
                    return transaction.execute(status -> {
                        actorContext.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
                        return auditWriter.append(
                            "CONCURRENT_AUDIT_" + eventNumber,
                            "test",
                            null,
                            AuditOutcome.SUCCESS,
                            Map.of("batch", batchId.toString())
                        );
                    });
                }));
            }
            assertTrue(ready.await(5, TimeUnit.SECONDS));
            start.countDown();
            for (var write : writes) {
                assertNotNull(write.get(15, TimeUnit.SECONDS));
            }
        }
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
            assertEquals(4, runtimeJdbc.queryForObject(
                "select count(*) from salud_u.evento_auditoria where details ->> 'batch' = ?", Integer.class, batchId.toString()
            ));
        });
    }

    @Test
    void runtimeRoleCannotBypassRlsOrReceiveDirectAuditMutationPrivileges() {
        assertFalse(migratorJdbc.queryForObject(
            "select rolbypassrls from pg_roles where rolname = 'salud_u_runtime'", Boolean.class
        ));
        assertFalse(migratorJdbc.queryForObject(
            "select has_table_privilege('salud_u_runtime', 'salud_u.evento_auditoria', 'INSERT, UPDATE, DELETE')", Boolean.class
        ));
    }

    @Test
    void validCredentialsCreateOpaqueSessionAndRevokedRoleInvalidatesIt() {
        var session = authenticationService.login("student@example.invalid", "student-password");
        assertEquals(studentId, session.principal().id());
        assertEquals(java.util.List.of("STUDENT"), session.principal().roles());
        assertTrue(authenticationService.resolve(session.token()).isPresent());

        migratorJdbc.update(
            "update salud_u.rol_principal set revoked_at = now() where principal_id = ? and role_code = cast(? as salud_u.codigo_rol_aplicacion) and revoked_at is null",
            studentId,
            "STUDENT"
        );

        assertTrue(authenticationService.resolve(session.token()).isEmpty());
    }

    @Test
    void fiveFailedAttemptsLockTheCredentialWithoutCreatingASession() {
        for (int attempt = 0; attempt < 5; attempt++) {
            assertThrows(bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException.class,
                () -> authenticationService.login("locked@example.invalid", "wrong-password"));
        }
        assertThrows(bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException.class,
            () -> authenticationService.login("locked@example.invalid", "locked-password"));
        assertTrue(migratorJdbc.queryForObject(
            "select locked_until > now() from salud_u.credencial_principal where principal_id = ?", Boolean.class, lockedStudentId
        ));
        assertEquals(5, migratorJdbc.queryForObject(
            "select failed_attempt_count from salud_u.credencial_principal where principal_id = ?", Integer.class, lockedStudentId
        ));
    }

    @Test
    void concurrentFailedAttemptsAreSerializedAndStillLockTheCredential() throws Exception {
        CountDownLatch ready = new CountDownLatch(5);
        CountDownLatch start = new CountDownLatch(1);
        try (var executor = Executors.newFixedThreadPool(5)) {
            var attempts = new ArrayList<java.util.concurrent.Future<?>>();
            for (int attempt = 0; attempt < 5; attempt++) {
                attempts.add(executor.submit(() -> {
                    ready.countDown();
                    if (!start.await(5, TimeUnit.SECONDS)) {
                        throw new IllegalStateException("No se inició la prueba concurrente de login.");
                    }
                    assertThrows(bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException.class,
                        () -> authenticationService.login("concurrent@example.invalid", "wrong-password"));
                }));
            }
            assertTrue(ready.await(5, TimeUnit.SECONDS));
            start.countDown();
            for (var attempt : attempts) {
                attempt.get(30, TimeUnit.SECONDS);
            }
        }
        assertEquals(5, migratorJdbc.queryForObject(
            "select failed_attempt_count from salud_u.credencial_principal where principal_id = ?", Integer.class, concurrentStudentId
        ));
        assertThrows(bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException.class,
            () -> authenticationService.login("concurrent@example.invalid", "concurrent-password"));
    }

    @Test
    void profileAndPasswordChangesVerifyCurrentPasswordAndRevokeEverySession() {
        SessionPrincipal profilePrincipal = new SessionPrincipal(profileStudentId, "profile@example.invalid", "Perfil sintético", java.util.List.of("STUDENT"));
        var beforeProfileChange = authenticationService.login("profile@example.invalid", "profile-current-password");
        transaction.executeWithoutResult(status -> profileService.updateProfile(
            profilePrincipal, "Perfil actualizado", "profile-updated@example.invalid", "profile-current-password"
        ));
        assertTrue(authenticationService.resolve(beforeProfileChange.token()).isEmpty());
        assertThrows(bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException.class,
            () -> authenticationService.login("profile@example.invalid", "profile-current-password"));
        var beforePasswordChange = authenticationService.login("profile-updated@example.invalid", "profile-current-password");

        transaction.executeWithoutResult(status -> profileService.changePassword(
            new SessionPrincipal(profileStudentId, "profile-updated@example.invalid", "Perfil actualizado", java.util.List.of("STUDENT")),
            "profile-current-password", "profile-new-password"
        ));
        assertTrue(authenticationService.resolve(beforePasswordChange.token()).isEmpty());
        assertThrows(bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException.class,
            () -> authenticationService.login("profile-updated@example.invalid", "profile-current-password"));
        assertEquals(profileStudentId, authenticationService.login("profile-updated@example.invalid", "profile-new-password").principal().id());

        assertEquals(2, migratorJdbc.queryForObject(
            "select count(*) from salud_u.evento_auditoria where actor_id = ? and action in ('PROFILE_UPDATED', 'PASSWORD_CHANGED')", Integer.class, profileStudentId
        ));
    }

    @Test
    void patientRegistrationNormalizesIdentifiersAndKeepsOneLongitudinalHistory() {
        SessionPrincipal administrator = new SessionPrincipal(administratorId, "administrator@example.invalid", "Administrativo sintético", java.util.List.of("ADMINISTRATIVE"));
        PatientService.PatientCommand first = new PatientService.PatientCommand(
            " 12 34 56 ", " reg 001 ", "Ana", "Mercado", LocalDate.of(2002, 1, 15), "70000000", "ana@example.invalid",
            patientCareerId, "2026-II", LocalDate.of(2026, 7, 1)
        );
        UUID patientId = transaction.execute(status -> patientService.create(administrator, first));
        assertNotNull(patientId);
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.historia_clinica where patient_id = ?", Integer.class, patientId));
        assertEquals("123456", migratorJdbc.queryForObject("select carnet_normalized from salud_u.paciente where id = ?", String.class, patientId));
        assertEquals("REG001", migratorJdbc.queryForObject("select registration_code_normalized from salud_u.paciente where id = ?", String.class, patientId));

        assertThrows(DuplicatePatientIdentifierException.class, () -> transaction.execute(status -> patientService.create(administrator,
            new PatientService.PatientCommand("123456", "OTHER-001", "Ana", "Otra", null, null, null, patientCareerId, "2026-II", LocalDate.of(2026, 7, 1))
        )));
        UUID updatedId = transaction.execute(status -> patientService.update(administrator, patientId,
            new PatientService.PatientCommand("123456", "REG001", "Ana María", "Mercado", LocalDate.of(2002, 1, 15), "71111111", null, patientCareerId, "2027-I", LocalDate.of(2027, 1, 1))
        ));
        assertEquals(patientId, updatedId);
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.historia_clinica where patient_id = ?", Integer.class, patientId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.inscripcion_academica where patient_id = ? and status = 'ACTIVE'", Integer.class, patientId));
        assertFalse(migratorJdbc.queryForObject(
            "select has_table_privilege('salud_u_runtime', 'salud_u.paciente', 'SELECT, INSERT, UPDATE, DELETE')", Boolean.class
        ));
    }

    @Test
    void availabilityGeneratesBoliviaSlotsBlocksThemAndPreservesBookedSlotsOnReplacement() throws Exception {
        SessionPrincipal clinician = new SessionPrincipal(availabilityClinicianId, "availability-doctor@example.invalid", "Médico disponibilidad", java.util.List.of("REVIEW_DOCTOR"));
        LocalDate nextMonday = LocalDate.now(ZoneId.of("America/La_Paz")).with(TemporalAdjusters.nextOrSame(java.time.DayOfWeek.MONDAY));
        var mapper = new ObjectMapper();
        var rules = mapper.readTree("[{\"weekday\":1,\"startsAt\":\"08:00\",\"endsAt\":\"09:00\",\"slotDurationMinutes\":30,\"specialtyId\":null}]");
        transaction.executeWithoutResult(status -> assertTrue(availabilityService.replace(clinician, rules, mapper.createArrayNode()) >= 2));
        assertEquals(2, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where staff_member_id = ? and (starts_at at time zone 'America/La_Paz')::date = ? and status = 'PUBLISHED'", Integer.class, availabilityStaffId, nextMonday
        ));
        transaction.executeWithoutResult(status -> availabilityService.createBlock(clinician, nextMonday, null, null, "Feriado sintético"));
        assertEquals(2, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where staff_member_id = ? and (starts_at at time zone 'America/La_Paz')::date = ? and status = 'BLOCKED'", Integer.class, availabilityStaffId, nextMonday
        ));
        migratorJdbc.update("update salud_u.cupo_disponibilidad set booked_count = 1 where id = (select id from salud_u.cupo_disponibilidad where staff_member_id = ? and status = 'BLOCKED' limit 1)", availabilityStaffId);
        transaction.executeWithoutResult(status -> availabilityService.replace(clinician, rules, mapper.createArrayNode()));
        assertEquals(1, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where staff_member_id = ? and booked_count = 1 and status <> 'CLOSED'", Integer.class, availabilityStaffId
        ));
        assertFalse(migratorJdbc.queryForObject(
            "select has_table_privilege('salud_u_runtime', 'salud_u.cupo_disponibilidad', 'SELECT, INSERT, UPDATE, DELETE')", Boolean.class
        ));
    }

    @Test
    void administrativeCatalogFunctionsRequireActorAndDeactivateWithoutDeletion() {
        assertThrows(DataAccessException.class, () -> runtimeJdbc.queryForObject(
            "select salud_u.guardar_catalogo_administracion('SPECIALTY', null, 'CARDIOLOGY', 'Cardiología', true)", UUID.class
        ));

        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            UUID specialtyId = runtimeJdbc.queryForObject(
                "select salud_u.guardar_catalogo_administracion(?, ?, ?, ?, ?)", UUID.class, "SPECIALTY", null, "CARDIOLOGY", "Cardiología", true
            );
            assertNotNull(specialtyId);
            assertEquals(1, runtimeJdbc.queryForObject(
                "select count(*) from salud_u.listar_catalogo('SPECIALTY') where code = 'CARDIOLOGY'", Integer.class
            ));
            runtimeJdbc.query("select salud_u.guardar_catalogo_administracion(?, ?, ?, ?, ?)", resultSet -> {}, "SPECIALTY", specialtyId, "CARDIOLOGY", "Cardiología", false);
            assertEquals(0, runtimeJdbc.queryForObject(
                "select count(*) from salud_u.listar_catalogo('SPECIALTY') where code = 'CARDIOLOGY'", Integer.class
            ));
        });
        assertFalse(migratorJdbc.queryForObject(
            "select has_table_privilege('salud_u_runtime', 'salud_u.especialidad', 'SELECT, INSERT, UPDATE, DELETE')", Boolean.class
        ));
    }

    @Test
    void actorSettingsAreTransactionLocalWhenConnectionReturnsToPool() {
        try (HikariDataSource oneConnectionPool = dataSource("salud_u_runtime", "runtime-test-password", 1)) {
            var jdbc = new JdbcTemplate(oneConnectionPool);
            var oneConnectionTransaction = new TransactionTemplate(new DataSourceTransactionManager(oneConnectionPool));
            var context = new DatabaseActorContext(jdbc);
            oneConnectionTransaction.executeWithoutResult(status -> {
                context.apply(new DatabaseActor(clinicianId, java.util.Set.of("REVIEW_DOCTOR")));
                assertEquals(clinicianId.toString(), jdbc.queryForObject("select current_setting('salud_u.id_actor', true)", String.class));
            });
            oneConnectionTransaction.executeWithoutResult(status -> assertEquals(
                "",
                jdbc.queryForObject("select coalesce(nullif(current_setting('salud_u.id_actor', true), ''), '')", String.class)
            ));
            oneConnectionTransaction.executeWithoutResult(status -> {
                context.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
                status.setRollbackOnly();
            });
            oneConnectionTransaction.executeWithoutResult(status -> assertEquals(
                "",
                jdbc.queryForObject("select coalesce(nullif(current_setting('salud_u.id_actor', true), ''), '')", String.class)
            ));
        }
    }

    private static DataSource migratorDataSource() {
        return dataSource("salud_u_migrator", "migrator-test-password");
    }

    private static HikariDataSource runtimeDataSource() {
        return dataSource("salud_u_runtime", "runtime-test-password");
    }

    private static HikariDataSource dataSource(String username, String password) {
        return dataSource(username, password, 4);
    }

    private static HikariDataSource dataSource(String username, String password, int maximumPoolSize) {
        var config = new HikariConfig();
        config.setJdbcUrl(POSTGRES.getJdbcUrl());
        config.setUsername(username);
        config.setPassword(password);
        config.setMaximumPoolSize(maximumPoolSize);
        return new HikariDataSource(config);
    }
}

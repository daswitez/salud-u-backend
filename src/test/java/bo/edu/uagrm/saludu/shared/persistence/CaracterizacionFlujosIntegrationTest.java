package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import bo.edu.uagrm.saludu.agenda.api.AppointmentAssignmentController;
import bo.edu.uagrm.saludu.agenda.api.AppointmentRequestController;
import bo.edu.uagrm.saludu.agenda.api.EncounterAmendmentController;
import bo.edu.uagrm.saludu.agenda.api.MedicalAppointmentController;
import bo.edu.uagrm.saludu.agenda.api.MedicalEncounterController;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityService;
import bo.edu.uagrm.saludu.agenda.application.ClinicalBackgroundData;
import bo.edu.uagrm.saludu.catalogs.application.CatalogKind;
import bo.edu.uagrm.saludu.catalogs.application.CatalogService;
import bo.edu.uagrm.saludu.governance.api.AuditEventController;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.application.AuthProperties;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException;
import bo.edu.uagrm.saludu.identity.api.SessionUserResponse;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.referrals.api.AssignedReferralController;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
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

/**
 * Caracterización de los flujos cuyas funciones SQL no ejecutaba ninguna otra prueba de integración (ES-00).
 *
 * <p>Todo pasa por los servicios y controladores reales, y las aserciones miran lo que recibe la API, no los
 * valores guardados. Así estas pruebas siguen siendo válidas cuando la base pase a español con el contrato
 * HTTP en inglés. Los únicos códigos que se escriben directo en la base son los roles de {@link #principal}.
 */
@Testcontainers(disabledWithoutDocker = true)
class CaracterizacionFlujosIntegrationTest {
    private static final ZoneId BOLIVIA = ZoneId.of("America/La_Paz");
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u")
        .withUsername("salud_u_migrator")
        .withPassword("migrator-test-password")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");

    private static HikariDataSource migratorPool;
    private static HikariDataSource runtimePool;
    private static JdbcTemplate migratorJdbc;
    private static TransactionTemplate transaction;
    private static final ObjectMapper JSON = new ObjectMapper();
    private static CatalogService catalogs;
    private static AuthenticationService authentication;
    private static AvailabilityService availability;
    private static AppointmentRequestController requests;
    private static AppointmentAssignmentController assignments;
    private static MedicalAppointmentController medicalAppointments;
    private static MedicalEncounterController encounters;
    private static AssignedReferralController assignedReferrals;
    private static EncounterAmendmentController amendments;
    private static AuditEventController auditEvents;
    private static SessionPrincipal admin;

    @BeforeAll
    static void setUp() {
        POSTGRES.start();
        migratorPool = pool("salud_u_migrator", "migrator-test-password");
        migratorJdbc = new JdbcTemplate(migratorPool);
        migratorJdbc.execute("CREATE ROLE salud_u_runtime LOGIN PASSWORD 'runtime-test-password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS");
        Flyway.configure()
            .dataSource(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password")
            .schemas("salud_u")
            .defaultSchema("salud_u")
            .createSchemas(true)
            .placeholders(Map.of("runtime_role", "salud_u_runtime", "migrator_role", "salud_u_migrator"))
            .load()
            .migrate();
        runtimePool = pool("salud_u_runtime", "runtime-test-password");
        var runtimeJdbc = new JdbcTemplate(runtimePool);
        transaction = new TransactionTemplate(new DataSourceTransactionManager(runtimePool));
        var actors = new DatabaseActorContext(runtimeJdbc);
        var audit = new AuditWriter(runtimeJdbc, JSON);
        var authProperties = new AuthProperties();
        authProperties.setSessionTtl(Duration.ofHours(8));
        catalogs = new CatalogService(runtimeJdbc, actors, audit);
        authentication = new AuthenticationService(runtimeJdbc, authProperties);
        availability = new AvailabilityService(runtimeJdbc, actors, audit, JSON);
        requests = new AppointmentRequestController(runtimeJdbc, actors, audit, new bo.edu.uagrm.saludu.patients.application.ConsentService(runtimeJdbc, actors, JSON, false), JSON);
        assignments = new AppointmentAssignmentController(runtimeJdbc, actors, audit);
        medicalAppointments = new MedicalAppointmentController(runtimeJdbc, actors, audit);
        encounters = new MedicalEncounterController(runtimeJdbc, actors, audit, JSON);
        assignedReferrals = new AssignedReferralController(runtimeJdbc, actors, audit, JSON);
        amendments = new EncounterAmendmentController(runtimeJdbc, actors, audit, JSON);
        auditEvents = new AuditEventController(runtimeJdbc, actors, audit);
        admin = principal("Administración caracterización", "ADMINISTRATIVE");
    }

    @AfterAll
    static void tearDown() {
        if (runtimePool != null) runtimePool.close();
        if (migratorPool != null) migratorPool.close();
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "CaracterizacionFlujosIntegrationTest");
        POSTGRES.stop();
    }

    @Test
    void cuentasRolesPersonalYSesionConservanSusCodigosDeApi() {
        String email = "car-cuentas-" + sufijo() + "@example.invalid";
        UUID doctorId = tx(() -> catalogs.createPrincipal(admin, email, "Doctora caracterización", "Clave-Caracterizacion-2026", List.of("REVIEW_DOCTOR", "SPECIALIST")));
        assertEquals(Set.of("REVIEW_DOCTOR", "SPECIALIST"), Set.copyOf(cuenta(doctorId).roles()));

        UUID specialtyId = tx(() -> catalogs.saveCatalog(admin, CatalogKind.SPECIALTY, null, "CAR_" + sufijo(), "Especialidad caracterización", true));
        UUID staffId = tx(() -> catalogs.upsertStaff(admin, doctorId, "CAR-PERSONAL-" + sufijo(), true));
        tx(() -> { catalogs.assignStaffSpecialty(admin, staffId, specialtyId, LocalDate.now(BOLIVIA), null); return null; });
        assertTrue(tx(() -> catalogs.staff(admin)).stream().anyMatch(member -> member.id().equals(staffId) && member.principalId().equals(doctorId) && member.active()));
        assertTrue(tx(() -> catalogs.list(CatalogKind.SPECIALTY, admin)).stream().anyMatch(item -> item.id().equals(specialtyId) && item.active()));
        var reporting = principal("Reportes caracterización", "REPORTING_OFFICER");
        assertTrue(tx(() -> catalogs.list(CatalogKind.SPECIALTY, reporting)).stream().anyMatch(item -> item.id().equals(specialtyId)));
        var doctor = new SessionPrincipal(doctorId, email, "Doctora caracterización", List.of("REVIEW_DOCTOR", "SPECIALIST"));
        assertTrue(tx(() -> catalogs.mySpecialties(doctor)).stream().anyMatch(item -> item.id().equals(specialtyId)));

        var session = tx(() -> authentication.login(email, "Clave-Caracterizacion-2026"));
        assertEquals(Set.of("REVIEW_DOCTOR", "SPECIALIST"), Set.copyOf(session.principal().roles()));
        tx(() -> { catalogs.setPrincipalRole(admin, doctorId, "SPECIALIST", false); return null; });
        assertEquals(List.of("REVIEW_DOCTOR"), cuenta(doctorId).roles());
        var renewed = tx(() -> authentication.login(email, "Clave-Caracterizacion-2026"));
        assertEquals(List.of("REVIEW_DOCTOR"), tx(() -> authentication.resolve(renewed.token())).orElseThrow().roles());
        tx(() -> { authentication.revoke(renewed.token()); return null; });
        assertTrue(tx(() -> authentication.resolve(renewed.token())).isEmpty());

        tx(() -> { catalogs.setPrincipalActive(admin, doctorId, false); return null; });
        assertFalse(cuenta(doctorId).active());
        assertThrows(InvalidCredentialsException.class, () -> tx(() -> authentication.login(email, "Clave-Caracterizacion-2026")));
    }

    /** ES-02: los roles cambian de nombre en la base; las autoridades, {@code /api/me} y el orden de los roles no. */
    @Test
    void losSeisRolesInicianSesionConLasMismasAutoridadesYElMismoApiMe() {
        String clave = "Clave-Caracterizacion-2026";
        var apiMePorRol = new LinkedHashMap<String, String>();
        apiMePorRol.put("ADMINISTRATIVE", "administrativo");
        apiMePorRol.put("REVIEW_DOCTOR", "medico");
        apiMePorRol.put("SPECIALIST", "medico");
        apiMePorRol.put("STUDENT", "estudiante");
        apiMePorRol.put("AUDITOR", "administrativo");
        apiMePorRol.put("REPORTING_OFFICER", "administrativo");
        apiMePorRol.forEach((rol, rolPantalla) -> {
            String email = "car-rol-" + sufijo() + "@example.invalid";
            UUID id = tx(() -> catalogs.createPrincipal(admin, email, "Rol " + rol, clave, List.of(rol)));
            assertEquals(List.of(rol), cuenta(id).roles());
            var sesion = tx(() -> authentication.login(email, clave));
            assertEquals(List.of(rol), sesion.principal().roles(), rol);
            var resuelta = tx(() -> authentication.resolve(sesion.token())).orElseThrow();
            assertEquals(List.of(rol), resuelta.roles(), rol);
            var me = SessionUserResponse.from(resuelta);
            assertEquals(List.of(rolPantalla, rol), List.of(me.role(), me.clinicalRole()), rol);
        });

        String email = "car-todos-" + sufijo() + "@example.invalid";
        UUID todos = tx(() -> catalogs.createPrincipal(admin, email, "Todos los roles", clave,
            List.of("STUDENT", "AUDITOR", "REPORTING_OFFICER", "SPECIALIST", "REVIEW_DOCTOR", "ADMINISTRATIVE")));
        var ordenSesion = List.of("ADMINISTRATIVE", "REVIEW_DOCTOR", "SPECIALIST", "STUDENT", "AUDITOR", "REPORTING_OFFICER");
        var sesion = tx(() -> authentication.login(email, clave));
        assertEquals(ordenSesion, sesion.principal().roles());
        assertEquals(ordenSesion, tx(() -> authentication.resolve(sesion.token())).orElseThrow().roles());
        assertEquals(ordenSesion, cuenta(todos).roles());
        assertEquals("ADMINISTRATIVE", SessionUserResponse.from(sesion.principal()).clinicalRole());

        tx(() -> catalogs.createPrincipal(sesion.principal(), "car-creada-" + sufijo() + "@example.invalid", "Creada por todos", clave, List.of("STUDENT")));
        var auditor = principal("Auditoría caracterización", "AUDITOR");
        var respuesta = tx(() -> auditEvents.list(null, null, todos, null, "PRINCIPAL_CREATED", null, null, 10, false, null, auditor)).getBody();
        @SuppressWarnings("unchecked") var eventos = (List<Map<String, Object>>) respuesta.get("data");
        assertEquals(1, eventos.size());
        @SuppressWarnings("unchecked") var actor = (Map<String, Object>) eventos.getFirst().get("actor");
        assertEquals(List.of("ADMINISTRATIVE", "AUDITOR", "REPORTING_OFFICER", "REVIEW_DOCTOR", "SPECIALIST", "STUDENT"), Arrays.asList((Object[]) actor.get("roles")));
    }

    @Test
    void bloqueoPropioApareceEnLaDisponibilidadYSePuedeEliminar() {
        var doctor = principal("Disponibilidad caracterización", "REVIEW_DOCTOR");
        personal(doctor);
        LocalDate day = LocalDate.now(BOLIVIA).plusDays(40);
        UUID blockId = tx(() -> availability.createBlock(doctor, day, LocalTime.of(8, 0), LocalTime.of(10, 0), "Congreso caracterización"));
        JsonNode blocks = JSON.valueToTree(tx(() -> availability.management(doctor, day.minusDays(1), day.plusDays(1)))).path("dateBlocks");
        assertTrue(contiene(blocks, blockId), blocks.toString());
        assertEquals("Congreso caracterización", buscar(blocks, blockId).path("label").asText());
        tx(() -> { availability.deleteBlock(doctor, blockId); return null; });
        assertFalse(contiene(JSON.valueToTree(tx(() -> availability.management(doctor, day.minusDays(1), day.plusDays(1)))).path("dateBlocks"), blockId));
    }

    @Test
    void solicitudDeEspecialidadDirectaSeListaConSusCodigosSoloParaQuienCorresponde() {
        var student = principal("Estudiante caracterización", "STUDENT");
        var otherStudent = principal("Otra estudiante caracterización", "STUDENT");
        UUID patient = paciente(student.id());
        UUID specialtyId = tx(() -> catalogs.saveCatalog(admin, CatalogKind.SPECIALTY, null, "CAR_D_" + sufijo(), "Especialidad directa", true));

        assertEquals(403, assertThrows(AvailabilityException.class, () -> tx(() -> requests.create(Map.of("appointmentType", "SPECIALTY", "patientId", patient.toString(), "specialtyId", specialtyId.toString()), student))).status());
        var created = tx(() -> requests.create(Map.of("appointmentType", "SPECIALTY", "patientId", patient.toString(), "specialtyId", specialtyId.toString()), admin));
        assertEquals(201, created.getStatusCode().value());
        UUID requestId = (UUID) ((Map<?, ?>) ((bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse<?>) created.getBody()).data()).get("id");

        Map<String, Object> listed = solicitud(admin, requestId);
        assertEquals("SPECIALTY", listed.get("appointment_type"));
        assertEquals("PENDING", listed.get("status"));
        assertEquals(specialtyId, listed.get("specialty_id"));
        assertNotNull(solicitud(student, requestId));
        assertTrue(tx(() -> requests.list(otherStudent)).data().stream().noneMatch(row -> requestId.equals(row.get("id"))));
    }

    @Test
    void derivacionCompletaLlegaAlEspecialistaConContextoYLaAdendaEsInmutable() {
        var reviewDoctor = principal("Revisión caracterización", "REVIEW_DOCTOR");
        personal(reviewDoctor);
        var specialist = principal("Especialista caracterización", "SPECIALIST");
        UUID specialistStaff = personal(specialist);
        UUID specialtyId = tx(() -> catalogs.saveCatalog(admin, CatalogKind.SPECIALTY, null, "CAR_R_" + sufijo(), "Especialidad derivada", true));
        tx(() -> { catalogs.assignStaffSpecialty(admin, specialistStaff, specialtyId, LocalDate.now(BOLIVIA), null); return null; });
        UUID patient = paciente(null);
        antecedentes(patient, reviewDoctor.id());

        OffsetDateTime reviewStart = LocalDate.now(BOLIVIA).plusDays(20).atTime(9, 0).atZone(BOLIVIA).toOffsetDateTime();
        UUID reviewSlot = tx(() -> availability.publish(reviewDoctor, reviewStart, reviewStart.plusMinutes(30), 1, null));
        UUID reviewAppointment = asignar(crear(Map.of("appointmentType", "INITIAL", "patientId", patient.toString())), reviewSlot);
        UUID reviewEncounter = iniciar(reviewAppointment, reviewDoctor);
        Map<String, Object> closed = tx(() -> encounters.finalizeEncounter(reviewEncounter, Map.of(
            "chiefComplaint", "Motivo caracterización", "assessment", "Evaluación caracterización", "diagnosisText", "Diagnóstico caracterización",
            "reviewHistory", Map.of(), "referralSpecialtyId", specialtyId.toString(), "referralReason", "Motivo de derivación caracterización",
            "referralComment", "Resumen para especialista caracterización", "referralPriority", "PRIORITY"), reviewDoctor)).getBody().data();
        UUID referralId = UUID.fromString(closed.get("referralId").toString());

        OffsetDateTime specialtyStart = LocalDate.now(BOLIVIA).plusDays(21).atTime(9, 0).atZone(BOLIVIA).toOffsetDateTime();
        UUID specialtySlot = tx(() -> availability.publish(specialist, specialtyStart, specialtyStart.plusMinutes(30), 1, specialtyId));
        Map<String, Object> referralRequest = Map.of("appointmentType", "REFERRAL", "referralId", referralId.toString(), "patientId", patient.toString());
        UUID requestId = crear(referralRequest);
        assertEquals("REFERRAL", solicitud(admin, requestId).get("appointment_type"));
        assertEquals(409, assertThrows(AvailabilityException.class, () -> crear(referralRequest)).status());
        UUID specialtyAppointment = asignar(requestId, specialtySlot);

        JsonNode assigned = tx(() -> assignedReferrals.list(specialist)).data();
        assertTrue(contiene(assigned, referralId), assigned.toString());
        assertEquals("ASSIGNED", buscar(assigned, referralId).path("status").asText(), assigned.toString());
        UUID specialtyEncounter = iniciar(specialtyAppointment, specialist);
        JsonNode source = JSON.valueToTree(tx(() -> encounters.sourceContext(specialtyEncounter, specialist)).data());
        assertTrue(source.toString().contains("Motivo de derivación caracterización"), source.toString());
        assertEquals("IN_PROGRESS", buscar(tx(() -> assignedReferrals.list(specialist)).data(), referralId).path("status").asText());

        UUID amendmentId = tx(() -> amendments.add(reviewEncounter, Map.of("reason", "Corrección caracterización", "content", "Texto agregado"), reviewDoctor)).getBody().data().id();
        var error = assertThrows(DataAccessException.class, () -> migratorJdbc.update("update salud_u.adenda_encuentro_clinico set id = id where id = ?", amendmentId));
        assertTrue(String.valueOf(error.getMostSpecificCause().getMessage()).contains("ADENDA_INMUTABLE"));
    }

    private static UUID crear(Map<String, Object> body) {
        var response = tx(() -> requests.create(body, admin));
        return (UUID) ((Map<?, ?>) ((bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse<?>) response.getBody()).data()).get("id");
    }

    private static UUID asignar(UUID requestId, UUID slotId) {
        return tx(() -> assignments.assign(requestId, Map.of("slotId", slotId.toString()), admin)).data().get("appointmentId");
    }

    private static UUID iniciar(UUID appointmentId, SessionPrincipal doctor) {
        return (UUID) tx(() -> medicalAppointments.start(appointmentId, doctor)).getBody().data().get("encounterId");
    }

    private static Map<String, Object> solicitud(SessionPrincipal actor, UUID requestId) {
        return tx(() -> requests.list(actor)).data().stream().filter(row -> requestId.equals(row.get("id"))).findFirst().orElseThrow();
    }

    private static bo.edu.uagrm.saludu.catalogs.application.AdministrativePrincipal cuenta(UUID id) {
        return tx(() -> catalogs.principals(admin)).stream().filter(row -> row.id().equals(id)).findFirst().orElseThrow();
    }

    /** Único lugar donde las pruebas escriben códigos en la base: al traducir los roles (ES-02) se ajusta aquí. */
    private static SessionPrincipal principal(String name, String role) {
        UUID id = UUID.randomUUID();
        String email = "car-" + id + "@example.invalid";
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", id, email, name);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion))", id, role);
        return new SessionPrincipal(id, email, name, List.of(role));
    }

    private static UUID personal(SessionPrincipal doctor) {
        UUID id = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.personal(id, id_principal, codigo_personal) values (?, ?, ?)", id, doctor.id(), "CAR-" + sufijo());
        return id;
    }

    private static UUID paciente(UUID principalId) {
        UUID id = UUID.randomUUID();
        String code = sufijo();
        migratorJdbc.update("insert into salud_u.paciente(id, id_principal, carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, creado_por, actualizado_por) values (?, ?, ?, ?, ?, ?, 'Paciente', 'Caracterización', ?, ?)",
            id, principalId, "CAR-" + code, "CAR" + code, "REG-CAR-" + code, "REGCAR" + code, admin.id(), admin.id());
        return id;
    }

    private static void antecedentes(UUID patient, UUID registeredBy) {
        migratorJdbc.update("insert into salud_u.version_antecedente_clinico(id_paciente, numero_version, datos, registrado_por, motivo_cambio) values (?, 1, cast(? as jsonb), ?, 'Ingreso caracterización')",
            patient, ClinicalBackgroundData.normalize(JSON.createObjectNode()).toString(), registeredBy);
    }

    private static boolean contiene(JsonNode rows, UUID id) {
        return !buscar(rows, id).isMissingNode();
    }

    private static JsonNode buscar(JsonNode rows, UUID id) {
        for (JsonNode row : rows) if (id.toString().equals(row.path("id").asText())) return row;
        return com.fasterxml.jackson.databind.node.MissingNode.getInstance();
    }

    private static <T> T tx(Supplier<T> action) {
        return transaction.execute(status -> action.get());
    }

    private static String sufijo() {
        return UUID.randomUUID().toString().substring(0, 8).toUpperCase();
    }

    private static HikariDataSource pool(String user, String password) {
        var config = new HikariConfig();
        config.setJdbcUrl(POSTGRES.getJdbcUrl());
        config.setUsername(user);
        config.setPassword(password);
        config.setMaximumPoolSize(4);
        return new HikariDataSource(config);
    }
}

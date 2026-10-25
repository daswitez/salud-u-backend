package bo.edu.uagrm.saludu.shared.persistence;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityService;
import bo.edu.uagrm.saludu.documents.application.ClinicalDocumentService;
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
import java.nio.file.Files;
import java.nio.file.Path;
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
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

@Testcontainers(disabledWithoutDocker = true)
class DatabaseActorContextIntegrationTest {
    @Test void reviewReferralIsAtomicSharesOnlyItsOriginAndCanBeReadOnlyByIssuer() throws Exception {
        UUID doctor=UUID.randomUUID(),staff=UUID.randomUUID(),otherDoctor=UUID.randomUUID(),otherStaff=UUID.randomUUID(),patient=UUID.randomUUID(),otherPatient=UUID.randomUUID(),specialty=UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,'fe13-review@example.invalid','Revisión FE13'),(?,'fe13-other@example.invalid','Ajeno FE13')",doctor,otherDoctor);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'REVIEW_DOCTOR'),(?,'REVIEW_DOCTOR')",doctor,otherDoctor);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'FE13-REVIEW'),(?,?,'FE13-OTHER')",staff,doctor,otherStaff,otherDoctor);
        migratorJdbc.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,'FE13-TEST','Especialidad FE13')",specialty);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,'FE13-P','FE13P','REG-FE13-P','REGFE13P','Paciente','FE13',?,?),(?,'FE13-X','FE13X','REG-FE13-X','REGFE13X','Paciente','Ajeno',?,?)",patient,doctor,doctor,otherPatient,doctor,doctor);
        var mapper=new ObjectMapper();
        migratorJdbc.update("insert into salud_u.version_antecedente_clinico(id_paciente,numero_version,datos,registrado_por,motivo_cambio) values (?,1,cast(? as jsonb),?,'Ingreso FE13')",patient,mapper.writeValueAsString(bo.edu.uagrm.saludu.agenda.application.ClinicalBackgroundData.normalize(mapper.createObjectNode())),doctor);
        UUID[] encounters=new UUID[4],appointments=new UUID[4];
        for(int i=0;i<4;i++){
            UUID slot=UUID.randomUUID();appointments[i]=UUID.randomUUID();encounters[i]=UUID.randomUUID();
            migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '10 days',now()+interval '10 days 30 minutes',1,'PUBLISHED',now(),?)",slot,staff,doctor);
            migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INITIAL',?,now()+interval '10 days')",appointments[i],i==2?otherPatient:patient,slot,staff);
            migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro) values (?,?,?,?,'INITIAL')",encounters[i],appointments[i],i==2?otherPatient:patient,staff);
        }
        UUID[] documents={UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID()};
        for(int i=0;i<3;i++)migratorJdbc.update("insert into salud_u.documento_clinico(id,id_paciente,id_encuentro,tipo_documento,estado,ruta_objeto,nombre_original,tipo_mime,tamano_bytes,checksum_sha256,cargado_por,disponible_en) values (?,?,?,'OTHER','AVAILABLE',?,?,'application/pdf',10,?,?,now())",documents[i],i==2?otherPatient:patient,encounters[i],"fe13/"+documents[i],"Documento "+i,"a".repeat(64),doctor);
        migratorJdbc.update("insert into salud_u.documento_clinico(id_paciente,id_encuentro,tipo_documento,ruta_objeto,nombre_original,tipo_mime,cargado_por) values (?,?,'OTHER','fe13/pendiente','No disponible','application/pdf',?)",patient,encounters[0],doctor);
        migratorJdbc.update("insert into salud_u.diagnostico_encuentro(id_encuentro,texto_libre,creado_por) values (?,'Diagnóstico de otra atención',?),(?,'Diagnóstico de otro paciente',?)",encounters[1],doctor,encounters[2],doctor);
        var owner=new SessionPrincipal(doctor,"fe13-review@example.invalid","Revisión FE13",java.util.List.of("REVIEW_DOCTOR"));
        var outsider=new SessionPrincipal(otherDoctor,"fe13-other@example.invalid","Ajeno FE13",java.util.List.of("REVIEW_DOCTOR"));
        var controller=new bo.edu.uagrm.saludu.agenda.api.MedicalEncounterController(runtimeJdbc,actorContext,auditWriter,mapper);
        Map<String,Object> body=Map.of("chiefComplaint","Control FE13","assessment","Evaluación FE13","diagnosisText","Diagnóstico compartido","reviewHistory",Map.of(),"referralSpecialtyId",specialty.toString(),"referralReason","Motivo FE13","referralComment","Resumen FE13","referralPriority","URGENT");
        assertEquals(404,assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.finalizeEncounter(encounters[0],body,outsider))).status());
        var start=new CountDownLatch(1);var accepted=new java.util.concurrent.atomic.AtomicReference<Map<String,Object>>();
        try(var pool=Executors.newFixedThreadPool(2)){
            java.util.concurrent.Callable<Integer> close=()->{start.await();try{var result=transaction.execute(status->controller.finalizeEncounter(encounters[0],body,owner));accepted.set(result.getBody().data());return result.getStatusCode().value();}catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException e){return e.status();}};
            var a=pool.submit(close);var b=pool.submit(close);start.countDown();assertEquals(java.util.Set.of(200,409),java.util.Set.of(a.get(10,TimeUnit.SECONDS),b.get(10,TimeUnit.SECONDS)));
        }
        UUID referral=UUID.fromString(accepted.get().get("referralId").toString());
        var reader=new bo.edu.uagrm.saludu.referrals.api.EmittedReferralController(runtimeJdbc,actorContext,auditWriter,mapper);
        var detail=transaction.execute(status->reader.get(referral,owner).data());
        assertEquals("URGENT",detail.path("priority").asText());assertEquals("CLOSED",detail.path("source").path("status").asText());
        assertTrue(detail.path("source").path("instructions").isNull());assertEquals(1,detail.path("diagnoses").size());assertEquals(1,detail.path("documents").size());assertEquals(documents[0].toString(),detail.path("documents").get(0).path("id").asText());
        assertEquals("Diagnóstico compartido",detail.path("diagnoses").get(0).path("label").asText());
        assertEquals(1,transaction.execute(status->reader.list(owner).data()).size());assertTrue(transaction.execute(status->reader.list(outsider).data()).isEmpty());
        assertEquals(404,assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->reader.get(referral,outsider))).status());
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_derivacion where id_derivacion=? and estado_anterior is null and estado_nuevo='PENDING_ASSIGNMENT' and id_actor=?",Integer.class,referral,doctor));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where accion='DERIVACION_EMITIDA' and id_recurso=? and id_actor=?",Integer.class,referral,doctor));
        Map<String,Object> plain=Map.of("chiefComplaint","Sin derivación","assessment","Control","reviewHistory",Map.of());
        var plainResult=transaction.execute(status->controller.finalizeEncounter(encounters[1],plain,owner)).getBody().data();
        assertTrue(plainResult.containsKey("referralId"));assertEquals(null,plainResult.get("referralId"));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.derivacion where id_paciente=?",Integer.class,patient));
        migratorJdbc.execute("CREATE FUNCTION salud_u.fallo_fe13() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id_encuentro_origen='"+encounters[3]+"'::uuid THEN RAISE EXCEPTION 'FALLO_CONTROLADO_FE13'; END IF; RETURN NEW; END $$");
        migratorJdbc.execute("CREATE TRIGGER fallo_fe13 AFTER INSERT ON salud_u.derivacion FOR EACH ROW EXECUTE FUNCTION salud_u.fallo_fe13()");
        try {
            assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.finalizeEncounter(encounters[3],body,owner)));
            assertEquals("DRAFT",migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id=?",String.class,encounters[3]));
            assertEquals("SCHEDULED",migratorJdbc.queryForObject("select estado from salud_u.cita where id=?",String.class,appointments[3]));
            assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.ficha_revision_version where id_encuentro=?",Integer.class,encounters[3]));
            assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.diagnostico_encuentro where id_encuentro=?",Integer.class,encounters[3]));
            assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='ATTENDED'",Integer.class,appointments[3]));
            assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.derivacion where id_encuentro_origen=?",Integer.class,encounters[3]));
        } finally {migratorJdbc.execute("DROP TRIGGER fallo_fe13 ON salud_u.derivacion");migratorJdbc.execute("DROP FUNCTION salud_u.fallo_fe13()");}
    }
    @Test void clinicalTemplateKeepsJsonSchemaKeywordsAndTranslatesFieldNamesAndOptions() throws Exception {
        var mapper=new ObjectMapper();
        String schema="""
          {"type":"object","required":["habits"],"properties":{"habits":{"type":"object","required":["physicalActivity"],
          "properties":{"physicalActivity":{"type":"string","enum":["YES","NO"]}}},
          "allergies":{"type":"array","items":{"type":"string"}}}}
          """;
        var translated=mapper.readTree(migratorJdbc.queryForObject("select salud_u.traducir_esquema_clinico(cast(? as jsonb))::text",String.class,schema));
        assertEquals("habitos",translated.path("required").get(0).asText());
        assertEquals("actividadFisica",translated.path("properties").path("habitos").path("required").get(0).asText());
        assertEquals(mapper.readTree("[\"SI\",\"NO\"]"),translated.path("properties").path("habitos").path("properties").path("actividadFisica").path("enum"));
        assertEquals("string",translated.path("properties").path("alergias").path("items").path("type").asText());
    }

    @Test void spanishClinicalJsonIsReversibleAndRuntimeCannotRewriteEvidence() throws Exception {
        var mapper = new ObjectMapper();
        String original = """
          {"schemaVersion":1,"allergies":{"status":"PRESENT","items":["YES","Texto libre"]},
           "vitals":{"height":1.7,"weight":null},"gynecology":{"contraceptiveMethods":["IUD","CONDOM"]}}
          """;
        String translated = migratorJdbc.queryForObject("select salud_u.traducir_json_clinico(cast(? as jsonb))::text", String.class, original);
        assertEquals(bo.edu.uagrm.saludu.agenda.application.ClinicalJson.spanish(mapper.readTree(original)), mapper.readTree(translated));
        assertEquals(mapper.readTree(original), mapper.readTree(migratorJdbc.queryForObject("select salud_u.traducir_json_clinico(cast(? as jsonb),true)::text", String.class, translated)));
        assertThrows(DataAccessException.class, () -> migratorJdbc.queryForObject("select salud_u.traducir_json_clinico('{\"vitals\":{},\"signosVitales\":{}}'::jsonb)", String.class));
        assertFalse(runtimeJdbc.queryForObject("select has_table_privilege(current_user,'salud_u.ficha_revision_version','UPDATE')", Boolean.class));
        assertFalse(runtimeJdbc.queryForObject("select has_table_privilege(current_user,'salud_u.version_antecedente_clinico','DELETE')", Boolean.class));
    }

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
        migratorJdbc.update("insert into salud_u.carrera(id, codigo, nombre) values (?, ?, ?)", patientCareerId, "MED", "Medicina");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", clinicianId, "clinician@example.invalid", "Clínico sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", auditorId, "auditor@example.invalid", "Auditor sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", studentId, "student@example.invalid", "Estudiante sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", lockedStudentId, "locked@example.invalid", "Estudiante limitado");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", concurrentStudentId, "concurrent@example.invalid", "Estudiante concurrente");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", administratorId, "administrator@example.invalid", "Administrativo sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", profileStudentId, "profile@example.invalid", "Perfil sintético");
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", availabilityClinicianId, "availability-doctor@example.invalid", "Médico disponibilidad");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(? as salud_u.codigo_rol_aplicacion))", studentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(? as salud_u.codigo_rol_aplicacion))", lockedStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(? as salud_u.codigo_rol_aplicacion))", concurrentStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(? as salud_u.codigo_rol_aplicacion))", administratorId, "ADMINISTRATIVE");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(? as salud_u.codigo_rol_aplicacion))", profileStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(? as salud_u.codigo_rol_aplicacion))", availabilityClinicianId, "REVIEW_DOCTOR");
        migratorJdbc.update("insert into salud_u.personal(id, id_principal, codigo_personal) values (?, ?, ?)", availabilityStaffId, availabilityClinicianId, "AVAIL-DOCTOR");
        migratorJdbc.update("insert into salud_u.credencial_principal(id_principal, hash_contrasena) values (?, salud_u.crypt(?, salud_u.gen_salt('bf', 10)))", studentId, "student-password");
        migratorJdbc.update("insert into salud_u.credencial_principal(id_principal, hash_contrasena) values (?, salud_u.crypt(?, salud_u.gen_salt('bf', 10)))", lockedStudentId, "locked-password");
        migratorJdbc.update("insert into salud_u.credencial_principal(id_principal, hash_contrasena) values (?, salud_u.crypt(?, salud_u.gen_salt('bf', 10)))", concurrentStudentId, "concurrent-password");
        migratorJdbc.update("insert into salud_u.credencial_principal(id_principal, hash_contrasena) values (?, salud_u.crypt(?, salud_u.gen_salt('bf', 10)))", profileStudentId, "profile-current-password");
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
                "select count(*) from salud_u.evento_auditoria where detalles ->> 'source' = 'visibility-test'", Integer.class
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
                "select count(*) from salud_u.evento_auditoria where detalles ->> 'batch' = ?", Integer.class, batchId.toString()
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
            "update salud_u.rol_principal set revocado_en = now() where id_principal = ? and codigo_rol = cast(? as salud_u.codigo_rol_aplicacion) and revocado_en is null",
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
            "select bloqueado_hasta > now() from salud_u.credencial_principal where id_principal = ?", Boolean.class, lockedStudentId
        ));
        assertEquals(5, migratorJdbc.queryForObject(
            "select cantidad_intentos_fallidos from salud_u.credencial_principal where id_principal = ?", Integer.class, lockedStudentId
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
                    try {
                        if (!start.await(5, TimeUnit.SECONDS)) {
                            throw new IllegalStateException("No se inició la prueba concurrente de login.");
                        }
                    } catch (InterruptedException exception) {
                        Thread.currentThread().interrupt();
                        throw new IllegalStateException("La prueba concurrente fue interrumpida.", exception);
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
            "select cantidad_intentos_fallidos from salud_u.credencial_principal where id_principal = ?", Integer.class, concurrentStudentId
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
            "select count(*) from salud_u.evento_auditoria where id_actor = ? and accion in ('PROFILE_UPDATED', 'PASSWORD_CHANGED')", Integer.class, profileStudentId
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
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.historia_clinica where id_paciente = ?", Integer.class, patientId));
        assertEquals("123456", migratorJdbc.queryForObject("select carnet_normalizado from salud_u.paciente where id = ?", String.class, patientId));
        assertEquals("REG001", migratorJdbc.queryForObject("select codigo_registro_normalizado from salud_u.paciente where id = ?", String.class, patientId));
        assertEquals(patientId, transaction.execute(status -> patientService.get(administrator, patientId).orElseThrow().id()));
        assertTrue(transaction.execute(status -> patientService.list(administrator, null)).stream().anyMatch(patient -> patient.id().equals(patientId)));

        assertThrows(DuplicatePatientIdentifierException.class, () -> transaction.execute(status -> patientService.create(administrator,
            new PatientService.PatientCommand("123456", "OTHER-001", "Ana", "Otra", null, null, null, patientCareerId, "2026-II", LocalDate.of(2026, 7, 1))
        )));
        UUID updatedId = transaction.execute(status -> patientService.update(administrator, patientId,
            new PatientService.PatientCommand("123456", "REG001", "Ana María", "Mercado", LocalDate.of(2002, 1, 15), "71111111", null, patientCareerId, "2027-I", LocalDate.of(2027, 1, 1))
        ));
        assertEquals(patientId, updatedId);
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.historia_clinica where id_paciente = ?", Integer.class, patientId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.inscripcion_academica where id_paciente = ? and estado = 'ACTIVE'", Integer.class, patientId));
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
            "select count(*) from salud_u.cupo_disponibilidad where id_personal = ? and (inicia_a at time zone 'America/La_Paz')::date = ? and estado = 'PUBLISHED'", Integer.class, availabilityStaffId, nextMonday
        ));
        transaction.executeWithoutResult(status -> availabilityService.createBlock(clinician, nextMonday, null, null, "Feriado sintético"));
        assertEquals(2, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where id_personal = ? and (inicia_a at time zone 'America/La_Paz')::date = ? and estado = 'BLOCKED'", Integer.class, availabilityStaffId, nextMonday
        ));
        migratorJdbc.update("update salud_u.cupo_disponibilidad set cantidad_reservada = 1 where id = (select id from salud_u.cupo_disponibilidad where id_personal = ? and estado = 'BLOCKED' limit 1)", availabilityStaffId);
        transaction.executeWithoutResult(status -> availabilityService.replace(clinician, rules, mapper.createArrayNode()));
        assertEquals(1, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where id_personal = ? and cantidad_reservada = 1 and estado <> 'CLOSED'", Integer.class, availabilityStaffId
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
                "select count(*) from salud_u.listar_catalogo('SPECIALTY') where codigo = 'CARDIOLOGY'", Integer.class
            ));
            runtimeJdbc.query("select salud_u.guardar_catalogo_administracion(?, ?, ?, ?, ?)", resultSet -> {}, "SPECIALTY", specialtyId, "CARDIOLOGY", "Cardiología", false);
            assertEquals(0, runtimeJdbc.queryForObject(
                "select count(*) from salud_u.listar_catalogo('SPECIALTY') where codigo = 'CARDIOLOGY'", Integer.class
            ));
        });
        assertFalse(migratorJdbc.queryForObject(
            "select has_table_privilege('salud_u_runtime', 'salud_u.especialidad', 'SELECT, INSERT, UPDATE, DELETE')", Boolean.class
        ));
    }

    @Test
    void reviewDoctorFinalizesStructuredRecordPersistsClinicalDataAndCannotCloseItTwice() throws Exception {
        UUID principalId = UUID.randomUUID();
        UUID personalId = UUID.randomUUID();
        UUID patientId = UUID.randomUUID();
        UUID slotId = UUID.randomUUID();
        UUID appointmentId = UUID.randomUUID();
        UUID encounterId = UUID.randomUUID();
        UUID backgroundId = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id, email, nombre_mostrado) values (?, ?, ?)", principalId, "be10-doctor@example.invalid", "Médico BE-10");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, 'REVIEW_DOCTOR')", principalId);
        migratorJdbc.update("insert into salud_u.personal(id, id_principal, codigo_personal) values (?, ?, ?)", personalId, principalId, "BE10-DOCTOR");
        migratorJdbc.update("insert into salud_u.paciente(id, carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, creado_por, actualizado_por) values (?, 'BE10-01', 'BE1001', 'REG-BE10', 'REGBE10', 'Paciente', 'Prueba', ?, ?)", patientId, principalId, principalId);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente, abierta_por) values (?, ?)", patientId, principalId);
        migratorJdbc.update("insert into salud_u.version_antecedente_clinico(id, id_paciente, numero_version, datos, registrado_por, motivo_cambio) values (?, ?, 1, cast(? as jsonb), ?, 'Ingreso inicial')", backgroundId, patientId, "{\"schemaVersion\":1,\"allergies\":[],\"personalConditions\":[],\"surgeries\":[],\"medications\":[],\"familyHistory\":[],\"habits\":{}}", principalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id, id_personal, inicia_a, termina_a, capacidad, estado, publicado_en, creado_por) values (?, ?, now() + interval '1 day', now() + interval '1 day 30 minutes', 1, 'PUBLISHED', now(), ?)", slotId, personalId, principalId);
        migratorJdbc.update("insert into salud_u.cita(id, id_paciente, id_cupo, tipo_cita, id_personal_asignado, programada_para) values (?, ?, ?, 'INITIAL', ?, now() + interval '1 day')", appointmentId, patientId, slotId, personalId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id, id_cita, id_paciente, id_personal, tipo_encuentro, id_version_antecedente_clinico) values (?, ?, ?, ?, 'INITIAL', ?)", encounterId, appointmentId, patientId, personalId, backgroundId);

        String reviewHistory = "{\"schemaVersion\":1,\"personalHistory\":{},\"habits\":{},\"vitals\":{\"bloodPressureSystolic\":\"120\",\"heartRate\":\"72\",\"weight\":\"70.5\"},\"physicalExam\":{},\"laboratory\":{},\"conduct\":{}}";
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(principalId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_revision(?, ?, ?, ?, ?, ?, ?, cast(? as jsonb))", String.class,
                encounterId, "Control clínico", "Evaluación estable", null, null, "ATTACHED", null, reviewHistory);
        }));
        assertEquals("DRAFT", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id = ?", String.class, encounterId));
        assertEquals(0, migratorJdbc.queryForObject("select count(*) from salud_u.ficha_revision_version where id_encuentro = ?", Integer.class, encounterId));
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(principalId, java.util.Set.of("REVIEW_DOCTOR")));
            String result = runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_revision(?, ?, ?, ?, ?, ?, ?, cast(? as jsonb))", String.class,
                encounterId, "Control clínico", "Evaluación estable", "Hidratación", null, "PENDING", "Sin hallazgos agudos", reviewHistory);
            assertTrue(result.contains("\"encounterId\": \"" + encounterId + "\""));
            assertTrue(result.contains("\"referralId\": null"));
            assertTrue(result.contains("\"reviewHistoryVersion\": 1"));
        });

        assertEquals("CLOSED", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id = ?", String.class, encounterId));
        assertEquals("ATTENDED", migratorJdbc.queryForObject("select estado from salud_u.cita where id = ?", String.class, appointmentId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita = ? and estado_nuevo = 'ATTENDED'", Integer.class, appointmentId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.ficha_revision_version where id_encuentro = ?", Integer.class, encounterId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.diagnostico_encuentro where id_encuentro = ?", Integer.class, encounterId));
        assertEquals(3, migratorJdbc.queryForObject("select count(*) from salud_u.medicion_encuentro where id_encuentro = ?", Integer.class, encounterId));
        UUID secondSlot=UUID.randomUUID(),secondAppointment=UUID.randomUUID(),secondEncounter=UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '2 days',now()+interval '2 days 30 minutes',1,'PUBLISHED',now(),?)",secondSlot,personalId,principalId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INITIAL',?,now()+interval '2 days')",secondAppointment,patientId,secondSlot,personalId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro) values (?,?,?,?,'INITIAL')",secondEncounter,secondAppointment,patientId,personalId);
        var controller=new bo.edu.uagrm.saludu.agenda.api.MedicalEncounterController(runtimeJdbc,actorContext,auditWriter,new ObjectMapper());
        var owner=new SessionPrincipal(principalId,"be10-doctor@example.invalid","Médico BE-10",java.util.List.of("REVIEW_DOCTOR"));
        CountDownLatch closeStart=new CountDownLatch(1);
        var completedData=new java.util.concurrent.atomic.AtomicReference<Map<String,Object>>();
        try(var pool=Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<Integer> close=()->{
                closeStart.await();
                try {
                    var response=transaction.execute(status->controller.finalizeEncounter(secondEncounter,Map.of("chiefComplaint","Segundo control","assessment","Estable","diagnosisText","Diagnóstico FE10","reviewHistory",Map.of("signosVitales",Map.of("talla","1.75","peso","70"))),owner));
                    completedData.set(response.getBody().data());return response.getStatusCode().value();
                } catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException conflict) {return conflict.status();}
            };
            var one=pool.submit(close);var two=pool.submit(close);closeStart.countDown();
            assertEquals(java.util.Set.of(200,409),java.util.Set.of(one.get(10,TimeUnit.SECONDS),two.get(10,TimeUnit.SECONDS)));
        }
        assertEquals(2,completedData.get().get("reviewHistoryVersion"));
        assertEquals(new java.math.BigDecimal("175.00"),migratorJdbc.queryForObject("select valor from salud_u.medicion_encuentro where id_encuentro=? and codigo_tipo='TALLA'",java.math.BigDecimal.class,secondEncounter));
        assertEquals(new java.math.BigDecimal("22.86"),migratorJdbc.queryForObject("select valor from salud_u.medicion_encuentro where id_encuentro=? and codigo_tipo='IMC'",java.math.BigDecimal.class,secondEncounter));
        var context=transaction.execute(status->controller.context(secondEncounter,owner).data());
        assertEquals("CLOSED",((com.fasterxml.jackson.databind.JsonNode)context).path("encounter").path("status").asText());
        assertEquals(1,((com.fasterxml.jackson.databind.JsonNode)context).path("diagnoses").size());
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(principalId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_revision(?, ?, ?, ?, ?, ?, ?, cast(? as jsonb))", String.class,
                encounterId, "Cambio", "Cambio", null, null, "PENDING", null, reviewHistory);
        }));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.ficha_revision_version where id_encuentro = ?", Integer.class, encounterId));
    }

    @Test
    void authorizedDoctorUploadsPrivateDocumentWithChecksumAndOneTimeOwnerBoundLink() throws Exception {
        UUID principalId = UUID.randomUUID();
        UUID otherPrincipalId = UUID.randomUUID();
        UUID personalId = UUID.randomUUID();
        UUID otherPersonalId = UUID.randomUUID();
        UUID patientId = UUID.randomUUID();
        UUID slotId = UUID.randomUUID();
        UUID appointmentId = UUID.randomUUID();
        UUID encounterId = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,?,?)", principalId, "be11-owner@example.invalid", "Médico propietario");
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,?,?)", otherPrincipalId, "be11-other@example.invalid", "Médico ajeno");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?, 'REVIEW_DOCTOR'), (?, 'REVIEW_DOCTOR')", principalId, otherPrincipalId);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?), (?,?,?)", personalId, principalId, "BE11-OWNER", otherPersonalId, otherPrincipalId, "BE11-OTHER");
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE11-01','BE1101','REG-BE11','REGBE11','Paciente','Documento',?,?)", patientId, principalId, principalId);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente,abierta_por) values (?,?)", patientId, principalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now()+interval '1 day', now()+interval '1 day 30 minutes',1,'PUBLISHED',now(),?)", slotId, personalId, principalId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?, ?, ?, 'INITIAL', ?, now()+interval '1 day')", appointmentId, patientId, slotId, personalId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro) values (?, ?, ?, ?, 'INITIAL')", encounterId, appointmentId, patientId, personalId);
        Path root = Files.createTempDirectory("salud-u-be11-");
        ClinicalDocumentService documents = new ClinicalDocumentService(runtimeJdbc, actorContext, auditWriter, root.toString());
        SessionPrincipal owner = new SessionPrincipal(principalId, "be11-owner@example.invalid", "Médico propietario", java.util.List.of("REVIEW_DOCTOR"));
        byte[] pdf = "%PDF-1.7\nresultado clínico".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        UUID documentId = transaction.execute(status -> documents.upload(owner, patientId, encounterId, "LAB_RESULT", "Resultado de laboratorio", LocalDate.now(), new MockMultipartFile("file", "resultado.pdf", "application/pdf", pdf)));
        var listed=transaction.execute(status->documents.list(owner,encounterId));
        assertEquals(1,listed.size());assertEquals(documentId,listed.getFirst().id());assertEquals("LAB_RESULT",listed.getFirst().documentType());
        var outsider=new SessionPrincipal(otherPrincipalId,"be11-other@example.invalid","Otro médico",java.util.List.of("REVIEW_DOCTOR"));
        assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->documents.list(outsider,encounterId)));
        assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->documents.upload(outsider,patientId,encounterId,"OTHER",null,null,new MockMultipartFile("file","ajeno.pdf","application/pdf",pdf))));

        assertEquals("AVAILABLE", migratorJdbc.queryForObject("select estado from salud_u.documento_clinico where id=?", String.class, documentId));
        assertEquals(64, migratorJdbc.queryForObject("select length(checksum_sha256) from salud_u.documento_clinico where id=?", Integer.class, documentId));
        String path = migratorJdbc.queryForObject("select ruta_objeto from salud_u.documento_clinico where id=?", String.class, documentId);
        assertTrue(Files.isRegularFile(root.resolve(path)));
        assertEquals("resultado clínico", Files.readString(root.resolve(path), java.nio.charset.StandardCharsets.UTF_8).substring("%PDF-1.7\n".length()));

        String url = transaction.execute(status -> documents.signedUrl(owner, documentId));
        String token = url.substring(url.indexOf("token=") + 6);
        assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class, () -> documents.consume(otherPrincipalId, documentId, token));
        assertEquals(documentId,transaction.execute(status->documents.consume(owner,documentId,token)).id());
        String validUrl = transaction.execute(status -> documents.signedUrl(owner, documentId));
        String validToken = validUrl.substring(validUrl.indexOf("token=") + 6);
        assertEquals(documentId, documents.consume(principalId, documentId, validToken).id());
        assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class, () -> documents.consume(principalId, documentId, validToken));
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(otherPrincipalId, java.util.Set.of("REVIEW_DOCTOR")));
            assertEquals(0, runtimeJdbc.queryForObject("select count(*) from salud_u.obtener_documento_autorizado(?)", Integer.class, documentId));
        });
        assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class, () -> transaction.execute(status ->
            documents.upload(owner, patientId, encounterId, "LAB_RESULT", null, null, new MockMultipartFile("file", "falso.pdf", "application/pdf", "esto no es un PDF".getBytes()))
        ));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.documento_clinico where id_encuentro=?", Integer.class, encounterId));
        try (var files = Files.walk(root)) {
            assertEquals(1L, files.filter(Files::isRegularFile).count());
        }
        assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->documents.upload(owner,patientId,encounterId,"OTHER",null,null,new MockMultipartFile("file","tamano.pdf","application/pdf",pdf){@Override public long getSize(){return pdf.length+1;}})));
        var locked=new CountDownLatch(1);var release=new CountDownLatch(1);var uploading=new CountDownLatch(1);
        var migratorTransaction=new TransactionTemplate(new DataSourceTransactionManager(migratorJdbc.getDataSource()));
        try(var pool=Executors.newFixedThreadPool(2)) {
            var closing=pool.submit(()->migratorTransaction.execute(status->{
                migratorJdbc.update("update salud_u.encuentro_clinico set estado='CLOSED',cerrado_en=now(),cerrado_por=? where id=?",principalId,encounterId);locked.countDown();
                try{assertTrue(release.await(5,TimeUnit.SECONDS));}catch(InterruptedException exception){throw new RuntimeException(exception);}return true;
            }));
            try {
                assertTrue(locked.await(5,TimeUnit.SECONDS));
                var pending=pool.submit(()->{uploading.countDown();try{transaction.execute(status->documents.upload(owner,patientId,encounterId,"OTHER",null,null,new MockMultipartFile("file","tardio.pdf","application/pdf",pdf)));return 201;}catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException exception){return exception.status();}});
                assertTrue(uploading.await(5,TimeUnit.SECONDS));assertThrows(java.util.concurrent.TimeoutException.class,()->pending.get(150,TimeUnit.MILLISECONDS));
                release.countDown();assertTrue(closing.get(5,TimeUnit.SECONDS));assertEquals(403,pending.get(5,TimeUnit.SECONDS));
            } finally {release.countDown();}
        }
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.documento_clinico where id_encuentro=?",Integer.class,encounterId));
    }

    @Test
    void globalBackgroundVersionsAreNormalizedConcurrentAuthorizedAndClosedSnapshotsStayIntact() throws Exception {
        UUID patient=UUID.randomUUID(),slot=UUID.randomUUID(),appointment=UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,'FE03-P','FE03P','FE03-R','FE03R','Paciente','Antecedentes',?,?)",patient,administratorId,administratorId);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente,abierta_por) values (?,?)",patient,administratorId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '100 days',now()+interval '100 days 30 minutes',1,'PUBLISHED',now(),?)",slot,availabilityStaffId,availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INITIAL',?,now()+interval '100 days')",appointment,patient,slot,availabilityStaffId);
        var owner=new SessionPrincipal(availabilityClinicianId,"availability-doctor@example.invalid","Médico disponibilidad",java.util.List.of("REVIEW_DOCTOR"));
        var mapper=new ObjectMapper();
        var controller=new bo.edu.uagrm.saludu.agenda.api.ClinicalBackgroundController(runtimeJdbc,actorContext,auditWriter,mapper);
        UUID encounter=transaction.execute(status->{actorContext.apply(new DatabaseActor(owner.id(),java.util.Set.copyOf(owner.roles())));return runtimeJdbc.queryForObject("select id_encuentro from salud_u.abrir_encuentro_borrador(?)",UUID.class,appointment);});
        var empty=transaction.execute(status->controller.get(patient,encounter,owner).data());
        assertTrue(empty.path("current").isNull()); assertTrue(empty.path("encounter").isNull());
        Map<String,Object> draft=Map.of("allergies",Map.of("status","PRESENT","items",java.util.List.of("  Uno  ","Dos")),"habits",Map.of("diet","REGULAR"));
        var first=transaction.execute(status->controller.save(patient,Map.of("data",draft,"expectedVersion",0,"changeReason","Registro inicial","encounterId",encounter.toString()),owner).getBody().data());
        assertEquals(1,first.get("versionNo"));
        var original=transaction.execute(status->controller.get(patient,encounter,owner).data());
        assertEquals("Uno",original.path("current").path("data").path("alergias").path("elementos").get(0).asText());
        assertEquals("Médico disponibilidad",original.path("current").path("recordedBy").asText());
        assertEquals(original.path("current"),original.path("encounter"));
        String checksum=migratorJdbc.queryForObject("select md5(datos::text) from salud_u.version_antecedente_clinico where id=?",String.class,first.get("id"));
        var stale=assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.save(patient,Map.of("data",draft,"expectedVersion",0,"changeReason","No sobrescribir"),owner)));
        assertEquals(409,stale.status());
        var invalid=assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.save(patient,Map.of("data",Map.of("allergies",Map.of("status","PRESENT","items",java.util.List.of())),"expectedVersion",1,"changeReason","Lista vacía"),owner)));
        assertEquals(400,invalid.status());
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.version_antecedente_clinico where id_paciente=?",Integer.class,patient));
        migratorJdbc.update("update salud_u.encuentro_clinico set estado='CLOSED',cerrado_en=now(),cerrado_por=? where id=?",owner.id(),encounter);
        transaction.execute(status->controller.save(patient,Map.of("data",draft,"expectedVersion",1,"changeReason","Actualización global posterior"),owner));
        var closed=transaction.execute(status->controller.get(patient,encounter,owner).data());
        assertEquals(2,closed.path("current").path("versionNo").asInt());assertEquals(1,closed.path("encounter").path("versionNo").asInt());
        var frozen=assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.save(patient,Map.of("data",draft,"expectedVersion",2,"changeReason","No modificar cerrada","encounterId",encounter.toString()),owner)));
        assertEquals(409,frozen.status());
        CountDownLatch start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<Integer> save=()->{start.await();try{transaction.execute(status->controller.save(patient,Map.of("data",draft,"expectedVersion",2,"changeReason","Concurrencia"),owner));return 200;}catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException ex){return ex.status();}};
            var one=pool.submit(save);var two=pool.submit(save);start.countDown();
            assertEquals(java.util.Set.of(200,409),java.util.Set.of(one.get(10,TimeUnit.SECONDS),two.get(10,TimeUnit.SECONDS)));
        }
        assertEquals(3,migratorJdbc.queryForObject("select count(*) from salud_u.version_antecedente_clinico where id_paciente=?",Integer.class,patient));
        assertEquals(checksum,migratorJdbc.queryForObject("select md5(datos::text) from salud_u.version_antecedente_clinico where id=?",String.class,first.get("id")));
        UUID outsider=UUID.randomUUID(),staff=UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,'fe03-outsider@example.invalid','Ajeno FE03')",outsider);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'REVIEW_DOCTOR')",outsider);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'FE03-AJENO')",staff,outsider);
        var other=new SessionPrincipal(outsider,"fe03-outsider@example.invalid","Ajeno",java.util.List.of("REVIEW_DOCTOR"));
        var denied=assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.get(patient,null,other)));
        assertEquals(404,denied.status());
    }

    @Test
    void administrativeAccountListingMapsActualSqlColumnsAndEmptyRevokedOrMultipleRoles() {
        var service = new bo.edu.uagrm.saludu.catalogs.application.CatalogService(runtimeJdbc, actorContext, auditWriter);
        UUID withoutRoles = UUID.randomUUID(), revoked = UUID.randomUUID(), multiple = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado,activo) values (?,'fecat-empty@example.invalid','FE-CAT A',false),(?,'fecat-revoked@example.invalid','FE-CAT B',true),(?,'fecat-multiple@example.invalid','FE-CAT C',true)", withoutRoles, revoked, multiple);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol,revocado_en) values (?,'STUDENT',now()),(?,'REVIEW_DOCTOR',null),(?,'SPECIALIST',null)", revoked, multiple, multiple);
        var administrator = new SessionPrincipal(administratorId, "administrator@example.invalid", "Admin", java.util.List.of("ADMINISTRATIVE"));
        var accounts = transaction.execute(status -> service.principals(administrator));
        var emptyAccount = accounts.stream().filter(item -> item.id().equals(withoutRoles)).findFirst().orElseThrow();
        assertTrue(emptyAccount.roles().isEmpty());
        assertFalse(emptyAccount.active());
        assertTrue(accounts.stream().filter(item -> item.id().equals(revoked)).findFirst().orElseThrow().roles().isEmpty());
        assertEquals(java.util.List.of("REVIEW_DOCTOR", "SPECIALIST"), accounts.stream().filter(item -> item.id().equals(multiple)).findFirst().orElseThrow().roles());
        assertEquals(java.util.List.of(withoutRoles, revoked, multiple), accounts.stream().filter(item -> item.email().startsWith("fecat-")).map(bo.edu.uagrm.saludu.catalogs.application.AdministrativePrincipal::id).toList());
        var student = new SessionPrincipal(studentId, "student@example.invalid", "Estudiante", java.util.List.of("STUDENT"));
        assertThrows(DataAccessException.class, () -> transaction.execute(status -> service.principals(student)));
    }

    @Test
    void medicalDraftOpeningIsConcurrentIdempotentAndOwnedWithCompleteAgendaContract() throws Exception {
        UUID patient = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID();
        UUID outsider = UUID.randomUUID(), outsiderStaff = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,'fe09-outsider@example.invalid','Médico ajeno')", outsider);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'REVIEW_DOCTOR')", outsider);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'FE09-OUTSIDER')", outsiderStaff, outsider);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,'FE09-OWN','FE09OWN','REG-FE09','REGFE09','Paciente','FE09',?,?)", patient, administratorId, administratorId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por) values (?,?,now()+interval '95 days',now()+interval '95 days 30 minutes',1,1,'PUBLISHED',now(),?)", slot, availabilityStaffId, availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INITIAL',?,now()+interval '95 days')", appointment, patient, slot, availabilityStaffId);
        var principal = new SessionPrincipal(availabilityClinicianId, "availability-doctor@example.invalid", "Médico", java.util.List.of("REVIEW_DOCTOR"));
        var controller = new bo.edu.uagrm.saludu.agenda.api.MedicalAppointmentController(runtimeJdbc, actorContext, auditWriter);
        CountDownLatch start = new CountDownLatch(1);
        try (var workers = Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<Map<String, Object>> open = () -> {
                start.await();
                return transaction.execute(status -> {
                    var result = controller.start(appointment, principal);
                    return Map.of("http", result.getStatusCode().value(), "encounterId", result.getBody().data().get("encounterId"));
                });
            };
            var first = workers.submit(open);
            var second = workers.submit(open);
            start.countDown();
            var left = first.get(10, TimeUnit.SECONDS);
            var right = second.get(10, TimeUnit.SECONDS);
            assertEquals(java.util.Set.of(200, 201), java.util.Set.of(left.get("http"), right.get("http")));
            assertEquals(left.get("encounterId"), right.get("encounterId"));
        }
        UUID encounter = migratorJdbc.queryForObject("select id from salud_u.encuentro_clinico where id_cita=?", UUID.class, appointment);
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='ENCUENTRO_BORRADOR_CREADO'", Integer.class, encounter));
        transaction.executeWithoutResult(status -> {
            var rows = controller.list(principal).data();
            var row = rows.stream().filter(item -> appointment.equals(item.get("id"))).findFirst().orElseThrow();
            assertEquals(Map.of("id", encounter, "status", "DRAFT"), row.get("encounter"));
            assertTrue(row.containsKey("checkedInAt"));
            assertEquals(null, row.get("checkedInAt"));
            var identity = (Map<?, ?>) row.get("patient");
            assertEquals("REG-FE09", identity.get("registrationCode"));
            assertTrue(identity.containsKey("birthDate"));
            assertTrue(identity.containsKey("phone"));
            assertEquals(null, identity.get("phone"));
        });
        var other = new SessionPrincipal(outsider, "fe09-outsider@example.invalid", "Ajeno", java.util.List.of("REVIEW_DOCTOR"));
        transaction.executeWithoutResult(status -> assertTrue(controller.list(other).data().isEmpty()));
        var denied = assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,
            () -> transaction.execute(status -> controller.start(appointment, other)));
        assertEquals(404, denied.status());
        migratorJdbc.update("update salud_u.cita set estado='NO_SHOW' where id=?", appointment);
        var stale = assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,
            () -> transaction.execute(status -> controller.start(appointment, principal)));
        assertEquals(409, stale.status());
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.encuentro_clinico where id_cita=?", Integer.class, appointment));
    }

    @Test
    void attendanceAndStudentCancellationPreserveEventsReservationsAndOwnership() throws Exception {
        UUID patient = UUID.randomUUID(), unlinkedPatient = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.paciente(id,id_principal,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,'FE08-OWN','FE08OWN','FE08-REG','FE08REG','Paciente','FE08',?,?), (?,null,'FE08-OTHER','FE08OTHER','FE08-REG2','FE08REG2','Paciente','Ajeno',?,?)", patient, studentId, administratorId, administratorId, unlinkedPatient, administratorId, administratorId);
        UUID slot = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '90 days',now()+interval '90 days 30 minutes',1,'PUBLISHED',now(),?)", slot, availabilityStaffId, availabilityClinicianId);
        UUID request = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.crear_solicitud_inicial(?)", UUID.class, patient);
        });
        UUID appointment = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.asignar_solicitud_cita(?,?)", UUID.class, request, slot);
        });
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(studentId, java.util.Set.of("STUDENT")));
            runtimeJdbc.queryForObject("select salud_u.cancelar_solicitud_cita(?,?)", Object.class, request, " Motivo FE08 ");
            runtimeJdbc.queryForObject("select salud_u.cancelar_solicitud_cita(?,?)", Object.class, request, "No sobrescribir");
        });
        assertEquals("CANCELLED", migratorJdbc.queryForObject("select estado from salud_u.cita where id=?", String.class, appointment));
        assertNotNull(migratorJdbc.queryForObject("select cancelada_en from salud_u.cita where id=?", java.time.OffsetDateTime.class, appointment));
        assertEquals("Motivo FE08", migratorJdbc.queryForObject("select motivo_cancelacion from salud_u.solicitud_cita where id=?", String.class, request));
        assertEquals(studentId, migratorJdbc.queryForObject("select cancelada_por from salud_u.solicitud_cita where id=?", UUID.class, request));
        assertEquals(0, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, slot));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='CANCELLED'", Integer.class, appointment));

        UUID otherRequest = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.crear_solicitud_inicial(?)", UUID.class, unlinkedPatient);
        });
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(studentId, java.util.Set.of("STUDENT")));
            runtimeJdbc.queryForObject("select salud_u.cancelar_solicitud_cita(?,null)", Object.class, otherRequest);
        }));
        assertEquals("PENDING", migratorJdbc.queryForObject("select estado from salud_u.solicitud_cita where id=?", String.class, otherRequest));
        UUID secondAppointment = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            UUID result = runtimeJdbc.queryForObject("select salud_u.asignar_solicitud_cita(?,?)", UUID.class, otherRequest, slot);
            runtimeJdbc.queryForObject("select salud_u.registrar_llegada_cita(?)", Object.class, result);
            return result;
        });
        assertNotNull(migratorJdbc.queryForObject("select ingreso_registrado_en from salud_u.cita where id=?", java.time.OffsetDateTime.class, secondAppointment));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.cancelar_solicitud_cita(?,null)", Object.class, otherRequest);
        }));
        assertEquals("ASSIGNED", migratorJdbc.queryForObject("select estado from salud_u.solicitud_cita where id=?", String.class, otherRequest));
        CountDownLatch start = new CountDownLatch(1);
        try (var workers = Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<Boolean> markAbsent = () -> {
                start.await();
                try {
                    transaction.executeWithoutResult(status -> {
                        actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
                        runtimeJdbc.queryForObject("select salud_u.registrar_ausencia_cita(?,?)", Object.class, secondAppointment, " Motivo ausencia ");
                    });
                    return true;
                } catch (DataAccessException conflict) { return false; }
            };
            var first = workers.submit(markAbsent);
            var second = workers.submit(markAbsent);
            start.countDown();
            assertEquals(1, (first.get(10, TimeUnit.SECONDS) ? 1 : 0) + (second.get(10, TimeUnit.SECONDS) ? 1 : 0));
        }
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.registrar_ausencia_cita(?,null)", Object.class, secondAppointment);
        }));
        assertEquals("NO_SHOW", migratorJdbc.queryForObject("select estado from salud_u.cita where id=?", String.class, secondAppointment));
        assertEquals(0, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, slot));
        assertEquals("Motivo ausencia", migratorJdbc.queryForObject("select motivo from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='NO_SHOW'", String.class, secondAppointment));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='NO_SHOW'", Integer.class, secondAppointment));
    }

    @Test
    void administrativeReferralSchedulingIsAtomicSpecialtyBoundAndCannotBeAssignedTwice() throws Exception {
        UUID sourcePrincipalId = UUID.randomUUID();
        UUID specialistPrincipalId = UUID.randomUUID();
        UUID sourceStaffId = UUID.randomUUID();
        UUID specialistStaffId = UUID.randomUUID();
        UUID patientId = UUID.randomUUID();
        UUID specialtyId = UUID.randomUUID();
        UUID otherSpecialtyId = UUID.randomUUID();
        UUID sourceSlotId = UUID.randomUUID();
        UUID sourceAppointmentId = UUID.randomUUID();
        UUID sourceEncounterId = UUID.randomUUID();
        UUID referralId = UUID.randomUUID();
        UUID incompatibleSlotId = UUID.randomUUID();
        UUID compatibleSlotId = UUID.randomUUID();

        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,?,?),(?,?,?)", sourcePrincipalId, "be14-source@example.invalid", "Médico origen", specialistPrincipalId, "be14-specialist@example.invalid", "Especialista destino");
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?),(?,?,?)", sourceStaffId, sourcePrincipalId, "BE14-SOURCE", specialistStaffId, specialistPrincipalId, "BE14-SPECIALIST");
        migratorJdbc.update("insert into salud_u.especialidad(id,codigo,nombre,activo) values (?, 'BE14-SPECIALTY', 'Especialidad BE-14', true),(?, 'BE14-OTHER', 'Otra especialidad', true)", specialtyId, otherSpecialtyId);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE14-01','BE1401','REG-BE14','REGBE14','Paciente','Derivación',?,?)", patientId, sourcePrincipalId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente,abierta_por) values (?,?)", patientId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now()+interval '2 days', now()+interval '2 days 30 minutes',1,'PUBLISHED',now(),?)", sourceSlotId, sourceStaffId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) values (?, ?, ?, 'INITIAL', ?, now()+interval '2 days', 'ATTENDED')", sourceAppointmentId, patientId, sourceSlotId, sourceStaffId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado) values (?, ?, ?, ?, 'INITIAL', 'CLOSED')", sourceEncounterId, sourceAppointmentId, patientId, sourceStaffId);
        migratorJdbc.update("insert into salud_u.derivacion(id,id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por) values (?, ?, ?, ?, 'PRIORITY', 'Motivo BE-14', 'Resumen para especialista', ?)", referralId, patientId, sourceEncounterId, specialtyId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, ?, now()+interval '3 days', now()+interval '3 days 30 minutes',1,'PUBLISHED',now(),?),(?, ?, ?, now()+interval '4 days', now()+interval '4 days 30 minutes',1,'PUBLISHED',now(),?)", incompatibleSlotId, specialistStaffId, otherSpecialtyId, specialistPrincipalId, compatibleSlotId, specialistStaffId, specialtyId, specialistPrincipalId);

        String originalSource=migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,sourceEncounterId);
        String originalClinical=migratorJdbc.queryForObject("select (to_jsonb(d)-array['estado','id_personal_asignado','asignada_en'])::text from salud_u.derivacion d where id=?",String.class,referralId);
        var admin=new SessionPrincipal(administratorId,"admin@example.invalid","Administración",java.util.List.of("ADMINISTRATIVE"));
        var creator=new bo.edu.uagrm.saludu.agenda.api.AppointmentRequestController(runtimeJdbc,actorContext,auditWriter);
        Map<String,Object> body=Map.of("patientId",patientId.toString(),"appointmentType","REFERRAL","referralId",referralId.toString());
        var wrongPatient=new java.util.HashMap<String,Object>(body);wrongPatient.put("patientId",UUID.randomUUID().toString());
        assertEquals(409,assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->creator.create(wrongPatient,admin))).status());
        var startRequest=new CountDownLatch(1);var created=new java.util.concurrent.atomic.AtomicReference<UUID>();
        try(var pool=Executors.newFixedThreadPool(2)){
            java.util.concurrent.Callable<Integer> create=()->{startRequest.await();try{var result=transaction.execute(status->creator.create(body,admin));created.set((UUID)((Map<?,?>)((bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse<?>)result.getBody()).data()).get("id"));return result.getStatusCode().value();}catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException exception){return exception.status();}};
            var a=pool.submit(create);var b=pool.submit(create);startRequest.countDown();assertEquals(java.util.Set.of(201,409),java.util.Set.of(a.get(10,TimeUnit.SECONDS),b.get(10,TimeUnit.SECONDS)));
        }
        UUID requestId=created.get();
        assertNotNull(requestId);
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.asignar_solicitud_cita(?,?)", UUID.class, requestId, incompatibleSlotId);
        }));
        assertEquals("PENDING", migratorJdbc.queryForObject("select estado from salud_u.solicitud_cita where id=?", String.class, requestId));
        assertEquals(0, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, incompatibleSlotId));

        var assigner=new bo.edu.uagrm.saludu.agenda.api.AppointmentAssignmentController(runtimeJdbc,actorContext,auditWriter);
        var startAssign=new CountDownLatch(1);var assigned=new java.util.concurrent.atomic.AtomicReference<UUID>();
        try(var pool=Executors.newFixedThreadPool(2)){
            java.util.concurrent.Callable<Integer> assign=()->{startAssign.await();try{var result=transaction.execute(status->assigner.assign(requestId,Map.of("slotId",compatibleSlotId.toString()),admin));assigned.set(result.data().get("appointmentId"));return 200;}catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException exception){return exception.status();}};
            var a=pool.submit(assign);var b=pool.submit(assign);startAssign.countDown();assertEquals(java.util.Set.of(200,409),java.util.Set.of(a.get(10,TimeUnit.SECONDS),b.get(10,TimeUnit.SECONDS)));
        }
        UUID appointmentId=assigned.get();
        assertEquals("ASSIGNED", migratorJdbc.queryForObject("select estado from salud_u.derivacion where id=?", String.class, referralId));
        assertEquals(referralId, migratorJdbc.queryForObject("select id_derivacion from salud_u.cita where id=?", UUID.class, appointmentId));
        assertEquals(originalSource,migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,sourceEncounterId));
        assertEquals(originalClinical,migratorJdbc.queryForObject("select (to_jsonb(d)-array['estado','id_personal_asignado','asignada_en'])::text from salud_u.derivacion d where id=?",String.class,referralId));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_derivacion where id_derivacion=? and estado_nuevo='ASSIGNED' and id_actor=?",Integer.class,referralId,administratorId));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='DERIVACION_PROGRAMADA' and id_actor=?",Integer.class,referralId,administratorId));
        var referrals=new bo.edu.uagrm.saludu.referrals.api.ReferralController(runtimeJdbc,actorContext,auditWriter);
        assertTrue(transaction.execute(status->referrals.inbox(admin)).data().stream().anyMatch(item->item.get("id").equals(referralId)&&item.get("status").equals("ASSIGNED")&&item.get("appointment_id").equals(appointmentId)));
        migratorJdbc.update("update salud_u.derivacion set estado='CLOSED' where id=?",referralId);
        assertEquals(409,assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->creator.create(body,admin))).status());
        assertTrue(transaction.execute(status->referrals.patient(patientId,admin)).data().stream().noneMatch(item->item.get("id").equals(referralId)));
        assertTrue(transaction.execute(status->referrals.inbox(admin)).data().stream().anyMatch(item->item.get("id").equals(referralId)&&item.get("status").equals("CLOSED")));
        migratorJdbc.update("update salud_u.derivacion set estado='ASSIGNED' where id=?",referralId);
        assertEquals("SPECIALTY", migratorJdbc.queryForObject("select tipo_cita from salud_u.cita where id=?", String.class, appointmentId));
        assertEquals(1, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, compatibleSlotId));
        assertEquals("CLOSED", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id=?", String.class, sourceEncounterId));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.asignar_solicitud_cita(?,?)", UUID.class, requestId, compatibleSlotId);
        }));
    }

    @Test
    void specialistClosesOwnDirectEncounterWithImmutableVersionedTemplate() {
        UUID specialist = UUID.randomUUID(), outsider = UUID.randomUUID(), specialistStaff = UUID.randomUUID(), outsiderStaff = UUID.randomUUID();
        UUID patient = UUID.randomUUID(), specialty = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID();
        UUID template = UUID.randomUUID(), replacementTemplate = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,?,?),(?,?,?)", specialist,"be15-specialist@example.invalid","Especialista BE-15",outsider,"be15-outsider@example.invalid","Ajeno BE-15");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'SPECIALIST'),(?,'SPECIALIST')", specialist,outsider);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?),(?,?,?)", specialistStaff,specialist,"BE15-OWN",outsiderStaff,outsider,"BE15-OTHER");
        migratorJdbc.update("insert into salud_u.especialidad(id,codigo,nombre,activo) values (?, 'BE15-CARDIO', 'Cardiología BE-15', true)", specialty);
        migratorJdbc.update("insert into salud_u.especialidad_personal(id_personal,id_especialidad,vigente_desde) values (?,?,current_date),(?,?,current_date)", specialistStaff,specialty,outsiderStaff,specialty);
        migratorJdbc.update("insert into salud_u.plantilla_ficha_especialidad(id,id_especialidad,numero_version,esquema) values (?,?,1,'{}')", template,specialty);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE15-01','BE1501','REG-BE15','REGBE15','Paciente','Especialidad',?,?)", patient,specialist,specialist);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente,abierta_por) values (?,?)", patient,specialist);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, ?, now()+interval '2 days',now()+interval '2 days 30 minutes',1,'PUBLISHED',now(),?)", slot,specialistStaff,specialty,specialist);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?, ?, ?, 'SPECIALTY', ?, now()+interval '2 days')", appointment,patient,slot,specialistStaff);
        UUID encounter = transaction.execute(status -> { actorContext.apply(new DatabaseActor(specialist, java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select id_encuentro from salud_u.abrir_encuentro_borrador(?)", UUID.class, appointment); });
        String history = "{\"schemaVersion\":1,\"specialtyCode\":\"BE15-CARDIO\",\"personalHistory\":{},\"ophthalmology\":{},\"gynecology\":{}}";
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(outsider, java.util.Set.of("SPECIALIST"))); runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))", String.class, encounter,"Motivo","Evaluación",null,null,null,history); }));
        String result = transaction.execute(status -> { actorContext.apply(new DatabaseActor(specialist, java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))", String.class, encounter,"Motivo","Evaluación",null,null,"Diagnóstico",history); });
        assertTrue(result.contains("specialtyHistoryVersion"));
        assertTrue(migratorJdbc.queryForObject("select jsonb_exists(datos,'codigoEspecialidad') AND jsonb_exists(datos,'ginecologia') AND NOT jsonb_exists(datos,'specialtyCode') from salud_u.version_ficha_especialidad where id_encuentro=?",Boolean.class,encounter));
        assertEquals("CLOSED", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id=?", String.class, encounter));
        assertEquals("ATTENDED", migratorJdbc.queryForObject("select estado from salud_u.cita where id=?", String.class, appointment));
        assertEquals(template, migratorJdbc.queryForObject("select id_plantilla from salud_u.version_ficha_especialidad where id_encuentro=?", UUID.class, encounter));
        migratorJdbc.update("update salud_u.plantilla_ficha_especialidad set activa=false where id=?", template);
        migratorJdbc.update("insert into salud_u.plantilla_ficha_especialidad(id,id_especialidad,numero_version,esquema) values (?,?,2,'{}')", replacementTemplate,specialty);
        assertEquals(template, migratorJdbc.queryForObject("select id_plantilla from salud_u.version_ficha_especialidad where id_encuentro=?", UUID.class, encounter));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(specialist, java.util.Set.of("SPECIALIST"))); runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))", String.class, encounter,"Otro","Otro",null,null,null,history); }));
    }

    @Test
    void institutionalComplianceCountsOnlyClosedEncountersInsideAcademicEnrollment() {
        UUID clinician = UUID.randomUUID(), staff = UUID.randomUUID(), reporting = UUID.randomUUID();
        UUID compliant = UUID.randomUUID(), checkedIn = UUID.randomUUID(), absent = UUID.randomUUID();
        UUID slot = UUID.randomUUID(), closedAppointment = UUID.randomUUID(), checkedInAppointment = UUID.randomUUID(), absentAppointment = UUID.randomUUID(), closedEncounter = UUID.randomUUID(), draftEncounter = UUID.randomUUID();
        String period = "BE23-" + UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,?,?),(?,?,?)", clinician,"be23-clinician@example.invalid","Clínico BE-23",reporting,"be23-reports@example.invalid","Reportes BE-23");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'REVIEW_DOCTOR'),(?,'REPORTING_OFFICER')", clinician,reporting);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", staff,clinician,"BE23-STAFF");
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE23-C','BE23C','REG-BE23-C','REGBE23C','Cerrado','Cumple',?,?),(?, 'BE23-I','BE23I','REG-BE23-I','REGBE23I','Llegada','Pendiente',?,?),(?, 'BE23-A','BE23A','REG-BE23-A','REGBE23A','Ausencia','Pendiente',?,?)", compliant,clinician,clinician,checkedIn,clinician,clinician,absent,clinician,clinician);
        migratorJdbc.update("insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) values (?, ?, ?, current_date - 1, 'ACTIVE'), (?, ?, ?, current_date - 1, 'ACTIVE'), (?, ?, ?, current_date - 1, 'ACTIVE')", compliant,patientCareerId,period,checkedIn,patientCareerId,period,absent,patientCareerId,period);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now(), now()+interval '30 minutes',3,'PUBLISHED',now(),?)", slot,staff,clinician);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) values (?, ?, ?, 'INITIAL', ?, now(), 'ATTENDED'), (?, ?, ?, 'INITIAL', ?, now(), 'CHECKED_IN'), (?, ?, ?, 'INITIAL', ?, now(), 'NO_SHOW')", closedAppointment,compliant,slot,staff,checkedInAppointment,checkedIn,slot,staff,absentAppointment,absent,slot,staff);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado,cerrado_en) values (?, ?, ?, ?, 'INITIAL','CLOSED',now()), (?, ?, ?, ?, 'INITIAL','DRAFT',null)", closedEncounter,closedAppointment,compliant,staff,draftEncounter,checkedInAppointment,checkedIn,staff);

        var rows = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(reporting, java.util.Set.of("REPORTING_OFFICER")));
            return runtimeJdbc.queryForList("select * from salud_u.reporte_cumplimiento_institucional(?, ?)", patientCareerId, period);
        });
        assertEquals(3, rows.size());
        assertEquals("COMPLIANT", rows.stream().filter(row -> compliant.equals(row.get("id_paciente"))).findFirst().orElseThrow().get("estado_cumplimiento"));
        assertEquals("PENDING", rows.stream().filter(row -> checkedIn.equals(row.get("id_paciente"))).findFirst().orElseThrow().get("estado_cumplimiento"));
        assertEquals("PENDING", rows.stream().filter(row -> absent.equals(row.get("id_paciente"))).findFirst().orElseThrow().get("estado_cumplimiento"));
        Integer otherCareerRows = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporting, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.reporte_cumplimiento_institucional(?, ?)", UUID.randomUUID(), period).size(); });
        Integer otherPeriodRows = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporting, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.reporte_cumplimiento_institucional(?, ?)", patientCareerId, period + "-otro").size(); });
        Boolean hasClosedActivity = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporting, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.actividad_diaria_atencion(current_date,current_date)").stream().anyMatch(row -> ((Number) row.get("total_cerradas")).longValue() >= 1); });
        assertEquals(0, otherCareerRows.intValue());
        assertEquals(0, otherPeriodRows.intValue());
        assertTrue(hasClosedActivity);
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(clinician, java.util.Set.of("REVIEW_DOCTOR"))); runtimeJdbc.queryForList("select * from salud_u.reporte_cumplimiento_institucional(?, ?)", patientCareerId, period); }));
    }

    @Test
    void auditorCanFilterAppendOnlyEventsWithoutReceivingSensitiveDetails() {
        UUID resourceId = UUID.randomUUID();
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            auditWriter.append("CLINICAL_RECORD_READ", "patient", resourceId, AuditOutcome.SUCCESS, Map.of("source", "history"));
        });
        var events = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
            return runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria(?, ?, ?, ?, ?, ?, ?)", LocalDate.now(), LocalDate.now(), clinicianId, "record_read", "patient", "SUCCESS", 100);
        });
        assertTrue(events.stream().anyMatch(event -> clinicianId.equals(event.get("id_actor")) && resourceId.equals(event.get("id_recurso")) && "CLINICAL_RECORD_READ".equals(event.get("accion"))));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria(null, null, null, null, null, null, 100)");
        }));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            auditWriter.append("UNSAFE", "patient", resourceId, AuditOutcome.SUCCESS, Map.of("token", "never-store-this"));
        }));
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update("update salud_u.evento_auditoria set accion='ALTERED' where id_recurso=?", resourceId));
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update("delete from salud_u.evento_auditoria where id_recurso=?", resourceId));
    }

    @Test
    void administrativeActorVersionsAndDeactivatesVaccineSchedulesWithoutDeletingThem() {
        String code = "BE25-" + UUID.randomUUID().toString().substring(0, 8);
        String twoDoses = "[{\"doseNumber\":1,\"minimumIntervalDays\":0},{\"doseNumber\":2,\"minimumIntervalDays\":28}]";
        UUID vaccineId = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(null, ?, ?, true, cast(? as jsonb))", UUID.class, code, "Vacuna BE-25", twoDoses);
        });
        assertEquals(2, migratorJdbc.queryForObject("select count(*) from salud_u.dosis_esquema_vacuna d join salud_u.esquema_vacuna e on e.id=d.id_esquema_vacuna where e.id_vacuna=?", Integer.class, vaccineId));
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(?, ?, ?, false, cast(? as jsonb))", UUID.class, vaccineId, code, "Vacuna BE-25", twoDoses);
        });
        assertFalse(migratorJdbc.queryForObject("select activo from salud_u.vacuna where id=?", Boolean.class, vaccineId));
        assertEquals(2, migratorJdbc.queryForObject("select count(*) from salud_u.esquema_vacuna where id_vacuna=?", Integer.class, vaccineId));
        assertEquals(4, migratorJdbc.queryForObject("select count(*) from salud_u.dosis_esquema_vacuna d join salud_u.esquema_vacuna e on e.id=d.id_esquema_vacuna where e.id_vacuna=?", Integer.class, vaccineId));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(?, ?, ?, true, cast(? as jsonb))", UUID.class, vaccineId, code, "Vacuna inválida", "[{\"doseNumber\":2,\"minimumIntervalDays\":0}]");
        }));
        assertEquals("Vacuna BE-25", migratorJdbc.queryForObject("select nombre from salud_u.vacuna where id=?", String.class, vaccineId));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(null, ?, ?, true, cast(? as jsonb))", UUID.class, "NO-PE25", "No permitida", twoDoses);
        }));
    }

    @Test
    void vaccinationDosePreservesResponsiblePeopleAndRejectsInvalidOrConcurrentDuplicates() throws Exception {
        UUID patient = UUID.randomUUID();
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, ?, ?, ?, ?, 'Paciente', 'Vacunación', ?, ?)", patient, "VAC-" + suffix, "VAC" + suffix, "REG-VAC-" + suffix, "REGVAC" + suffix, administratorId, administratorId);
        UUID vaccine = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(null, ?, ?, true, cast(? as jsonb))", UUID.class, "VX-" + suffix, "Vacuna BE-26", "[{\"doseNumber\":1,\"minimumIntervalDays\":0},{\"doseNumber\":2,\"minimumIntervalDays\":28}]");
        });
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 2, ?, 'L-2', ?, 'Sin primera dosis')", UUID.class, patient, vaccine, LocalDate.now(), availabilityStaffId);
        }));
        LocalDate firstDate = LocalDate.now().minusDays(2);
        UUID first = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 1, ?, 'L-1', ?, null)", UUID.class, patient, vaccine, firstDate, availabilityStaffId);
        });
        assertNotNull(first);
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 2, ?, 'L-2', null, null)", UUID.class, patient, vaccine, LocalDate.now());
        }));
        UUID second = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            return runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 2, ?, 'L-2', null, 'Aplicación anticipada justificada')", UUID.class, patient, vaccine, LocalDate.now());
        });
        assertEquals(availabilityStaffId, migratorJdbc.queryForObject("select id_personal_aplicador from salud_u.dosis_vacuna_aplicada where id=?", UUID.class, second));
        assertEquals(availabilityClinicianId, migratorJdbc.queryForObject("select id_registrado_por from salud_u.dosis_vacuna_aplicada where id=?", UUID.class, second));
        assertTrue(migratorJdbc.queryForObject("select advertencia_intervalo from salud_u.dosis_vacuna_aplicada where id=?", Boolean.class, second));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 2, ?, 'L-2', ?, 'Duplicada')", UUID.class, patient, vaccine, LocalDate.now(), availabilityStaffId);
        }));

        UUID concurrentPatient = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, ?, ?, ?, ?, 'Paciente', 'Concurrente', ?, ?)", concurrentPatient, "VCC-" + suffix, "VCC" + suffix, "REG-VCC-" + suffix, "REGVCC" + suffix, administratorId, administratorId);
        var gate = new CountDownLatch(1);
        var workers = Executors.newFixedThreadPool(2);
        try {
            var attempts = java.util.List.of(0, 1).stream().map(ignored -> workers.submit(() -> {
                gate.await(5, TimeUnit.SECONDS);
                try {
                    return transaction.execute(status -> {
                        actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
                        runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 1, ?, 'LC-1', ?, null)", UUID.class, concurrentPatient, vaccine, LocalDate.now(), availabilityStaffId);
                        return true;
                    });
                } catch (DataAccessException exception) { return false; }
            })).toList();
            gate.countDown();
            assertEquals(1L, attempts.stream().filter(attempt -> {
                try { return attempt.get(10, TimeUnit.SECONDS); } catch (Exception exception) { return false; }
            }).count());
        } finally { workers.shutdownNow(); }
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.dosis_vacuna_aplicada where id_paciente=? and id_vacuna=? and numero_dosis=1", Integer.class, concurrentPatient, vaccine));
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(?, ?, ?, false, cast(? as jsonb))", UUID.class, vaccine, "VX-" + suffix, "Vacuna BE-26", "[{\"doseNumber\":1,\"minimumIntervalDays\":0},{\"doseNumber\":2,\"minimumIntervalDays\":28}]");
        });
        UUID inactivePatient = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, ?, ?, ?, ?, 'Paciente', 'Inactiva', ?, ?)", inactivePatient, "VXI-" + suffix, "VXI" + suffix, "REG-VXI-" + suffix, "REGVXI" + suffix, administratorId, administratorId);
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 1, ?, 'LI-1', ?, null)", UUID.class, inactivePatient, vaccine, LocalDate.now(), availabilityStaffId);
        }));
    }

    @Test
    void vaccinationCardIsPrivateToStudentAndCoverageCountsEachEnrolledStudentOnce() {
        String suffix = UUID.randomUUID().toString().substring(0, 8), period = "2026-VAC-" + suffix;
        UUID student = UUID.randomUUID(), reporter = UUID.randomUUID(), patient = UUID.randomUUID(), pendingPatient = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,?,?),(?,?,?)", student, "be27-student-" + suffix + "@example.invalid", "Estudiante BE-27", reporter, "be27-report-" + suffix + "@example.invalid", "Reportes BE-27");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'STUDENT'),(?,'REPORTING_OFFICER')", student, reporter);
        migratorJdbc.update("insert into salud_u.paciente(id,id_principal,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?, ?, ?, ?, ?, 'Estudiante','Vacunado',?,?),(?,null, ?, ?, ?, ?, 'Estudiante','Pendiente',?,?)", patient, student, "VC-" + suffix, "VC" + suffix, "REG-VC-" + suffix, "REGVC" + suffix, administratorId, administratorId, pendingPatient, "VP-" + suffix, "VP" + suffix, "REG-VP-" + suffix, "REGVP" + suffix, administratorId, administratorId);
        migratorJdbc.update("insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) values (?, ?, ?, current_date, 'ACTIVE'), (?, ?, ?, current_date, 'ACTIVE')", patient, patientCareerId, period, pendingPatient, patientCareerId, period);
        UUID vaccine = transaction.execute(status -> { actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE"))); return runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(null, ?, ?, true, cast(? as jsonb))", UUID.class, "VC-" + suffix, "Vacuna cobertura", "[{\"doseNumber\":1,\"minimumIntervalDays\":0}]"); });
        transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE"))); runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 1, current_date, 'CARD-1', ?, null)", UUID.class, patient, vaccine, availabilityStaffId); });
        transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE"))); runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(?, ?, ?, true, cast(? as jsonb))", UUID.class, vaccine, "VC-" + suffix, "Vacuna cobertura", "[{\"doseNumber\":1,\"minimumIntervalDays\":0}]"); });
        String ownCard = transaction.execute(status -> { actorContext.apply(new DatabaseActor(student, java.util.Set.of("STUDENT"))); return runtimeJdbc.queryForObject("select salud_u.obtener_carnet_vacunacion(null)::text", String.class); });
        assertTrue(ownCard.contains("\"carnet\": \"VC-" + suffix + "\"") || ownCard.contains("\"carnet\":\"VC-" + suffix + "\""));
        assertTrue(ownCard.contains("\"currentSchemaVersion\": 2") || ownCard.contains("\"currentSchemaVersion\":2"));
        assertTrue(ownCard.contains("\"schemaVersion\": 1") || ownCard.contains("\"schemaVersion\":1"));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(student, java.util.Set.of("STUDENT"))); runtimeJdbc.queryForObject("select salud_u.obtener_carnet_vacunacion(?)::text", String.class, pendingPatient); }));
        var coverage = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.reporte_cobertura_vacunacion(?, ?)", patientCareerId, period); });
        assertEquals(1, coverage.size());
        assertEquals(2L, ((Number) coverage.getFirst().get("total_estudiantes")).longValue());
        assertEquals(1L, ((Number) coverage.getFirst().get("esquemas_completos")).longValue());
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(student, java.util.Set.of("STUDENT"))); runtimeJdbc.queryForList("select * from salud_u.reporte_cobertura_vacunacion(?, ?)", patientCareerId, period); }));
    }

    @Test
    void researchDatasetIsPseudonymizedAuditedAndRestricted() {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID reporter = UUID.randomUUID(), patient = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID(), encounter = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,email,nombre_mostrado) values (?,?,?)", reporter, "research-" + suffix + "@example.invalid", "Reportes investigación");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'REPORTING_OFFICER')", reporter);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,fecha_nacimiento,creado_por,actualizado_por) values (?, 'CARNET-SECRETO', 'CARNETSECRETO" + suffix + "', 'REGISTRO-SECRETO', 'REGISTROSECRETO" + suffix + "', 'Nombre Reservado', 'Apellido Reservado', current_date - interval '22 years', ?, ?)", patient, administratorId, administratorId);
        migratorJdbc.update("insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) values (?, ?, '2026-II', current_date - 1, 'ACTIVE')", patient, patientCareerId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now()-interval '2 days', now()-interval '2 days'+interval '30 minutes', 1, 'CLOSED', now()-interval '3 days', ?)", slot, availabilityStaffId, availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para) values (?, ?, ?, 'INITIAL', 'ATTENDED', ?, now()-interval '2 days')", appointment, patient, slot, availabilityStaffId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado,cerrado_en,cerrado_por) values (?, ?, ?, ?, 'INITIAL', 'CLOSED', now()-interval '2 days', ?)", encounter, appointment, patient, availabilityStaffId, availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.diagnostico_encuentro(id_encuentro,texto_libre,creado_por) values (?, 'Nombre Reservado no debe salir', ?)", encounter, availabilityClinicianId);
        var first = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))", "{}"); });
        var second = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))", "{}"); });
        Map<String, Object> row = first.stream().filter(value -> "INITIAL".equals(value.get("tipo_encuentro"))).findFirst().orElseThrow();
        assertTrue(((String) row.get("seudonimo")).matches("R-[A-F0-9]{20}"));
        assertEquals(row.get("seudonimo"), second.stream().filter(value -> "INITIAL".equals(value.get("tipo_encuentro"))).findFirst().orElseThrow().get("seudonimo"));
        String serialized = row.toString();
        assertFalse(serialized.contains("CARNET-SECRETO") || serialized.contains("REGISTRO-SECRETO") || serialized.contains("Nombre Reservado") || serialized.contains("Apellido Reservado"));
        UUID export = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForObject("select salud_u.registrar_exportacion_investigacion(?, cast(? as jsonb), 'CSV', ?)", UUID.class, "Análisis epidemiológico institucional", "{}", first.size()); });
        assertEquals(reporter, migratorJdbc.queryForObject("select id_solicitante from salud_u.exportacion_investigacion where id=?", UUID.class, export));
        assertTrue(migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='RESEARCH_EXPORT_COMPLETED'", Integer.class, export) == 1);
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(studentId, java.util.Set.of("STUDENT"))); runtimeJdbc.queryForList("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))", "{}"); }));
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

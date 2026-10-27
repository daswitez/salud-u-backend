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
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,'fe13-review@example.invalid','Revisión FE13'),(?,'fe13-other@example.invalid','Ajeno FE13')",doctor,otherDoctor);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'MEDICO_REVISION'),(?,'MEDICO_REVISION')",doctor,otherDoctor);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'FE13-REVIEW'),(?,?,'FE13-OTHER')",staff,doctor,otherStaff,otherDoctor);
        migratorJdbc.update("insert into salud_u.especialidad(id,codigo,nombre) values (?,'FE13-TEST','Especialidad FE13')",specialty);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,'FE13-P','FE13P','REG-FE13-P','REGFE13P','Paciente','FE13',?,?),(?,'FE13-X','FE13X','REG-FE13-X','REGFE13X','Paciente','Ajeno',?,?)",patient,doctor,doctor,otherPatient,doctor,doctor);
        var mapper=new ObjectMapper();
        migratorJdbc.update("insert into salud_u.version_antecedente_clinico(id_paciente,numero_version,datos,registrado_por,motivo_cambio) values (?,1,cast(? as jsonb),?,'Ingreso FE13')",patient,mapper.writeValueAsString(bo.edu.uagrm.saludu.agenda.application.ClinicalBackgroundData.normalize(mapper.createObjectNode())),doctor);
        UUID[] encounters=new UUID[4],appointments=new UUID[4];
        for(int i=0;i<4;i++){
            UUID slot=UUID.randomUUID();appointments[i]=UUID.randomUUID();encounters[i]=UUID.randomUUID();
            migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '10 days',now()+interval '10 days 30 minutes',1,'PUBLICADO',now(),?)",slot,staff,doctor);
            migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INICIAL',?,now()+interval '10 days')",appointments[i],i==2?otherPatient:patient,slot,staff);
            migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro) values (?,?,?,?,'INICIAL')",encounters[i],appointments[i],i==2?otherPatient:patient,staff);
        }
        UUID[] documents={UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID()};
        for(int i=0;i<3;i++)migratorJdbc.update("insert into salud_u.documento_clinico(id,id_paciente,id_encuentro,tipo_documento,estado,ruta_objeto,nombre_original,tipo_mime,tamano_bytes,checksum_sha256,cargado_por,disponible_en) values (?,?,?,'OTRO','DISPONIBLE',?,?,'application/pdf',10,?,?,now())",documents[i],i==2?otherPatient:patient,encounters[i],"fe13/"+documents[i],"Documento "+i,"a".repeat(64),doctor);
        migratorJdbc.update("insert into salud_u.documento_clinico(id_paciente,id_encuentro,tipo_documento,ruta_objeto,nombre_original,tipo_mime,cargado_por) values (?,?,'OTRO','fe13/pendiente','No disponible','application/pdf',?)",patient,encounters[0],doctor);
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
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_derivacion where id_derivacion=? and estado_anterior is null and estado_nuevo='PENDIENTE_ASIGNACION' and id_actor=?",Integer.class,referral,doctor));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where accion='DERIVACION_EMITIDA' and id_recurso=? and id_actor=?",Integer.class,referral,doctor));
        Map<String,Object> plain=Map.of("chiefComplaint","Sin derivación","assessment","Control","reviewHistory",Map.of());
        var plainResult=transaction.execute(status->controller.finalizeEncounter(encounters[1],plain,owner)).getBody().data();
        assertTrue(plainResult.containsKey("referralId"));assertEquals(null,plainResult.get("referralId"));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.derivacion where id_paciente=?",Integer.class,patient));
        migratorJdbc.execute("CREATE FUNCTION salud_u.fallo_fe13() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id_encuentro_origen='"+encounters[3]+"'::uuid THEN RAISE EXCEPTION 'FALLO_CONTROLADO_FE13'; END IF; RETURN NEW; END $$");
        migratorJdbc.execute("CREATE TRIGGER fallo_fe13 AFTER INSERT ON salud_u.derivacion FOR EACH ROW EXECUTE FUNCTION salud_u.fallo_fe13()");
        try {
            assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.finalizeEncounter(encounters[3],body,owner)));
            assertEquals("BORRADOR",migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id=?",String.class,encounters[3]));
            assertEquals("PROGRAMADA",migratorJdbc.queryForObject("select estado from salud_u.cita where id=?",String.class,appointments[3]));
            assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.ficha_revision_version where id_encuentro=?",Integer.class,encounters[3]));
            assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.diagnostico_encuentro where id_encuentro=?",Integer.class,encounters[3]));
            assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='ATENDIDA'",Integer.class,appointments[3]));
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

    // track_functions=all permite informar qué funciones SQL ejecutan estas pruebas (CoberturaFuncionesSql).
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:17-bookworm")
        .withDatabaseName("salud_u")
        .withUsername("salud_u_migrator")
        .withPassword("migrator-test-password")
        .withCommand("postgres", "-c", "fsync=off", "-c", "track_functions=all");

    private static HikariDataSource runtimeDataSource;
    private static HikariDataSource migratorDataSource;
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
        migratorDataSource = migratorDataSource();
        migratorJdbc = new JdbcTemplate(migratorDataSource);
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
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", clinicianId, "clinician@example.invalid", "Clínico sintético");
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", auditorId, "auditor@example.invalid", "Auditor sintético");
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", studentId, "student@example.invalid", "Estudiante sintético");
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", lockedStudentId, "locked@example.invalid", "Estudiante limitado");
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", concurrentStudentId, "concurrent@example.invalid", "Estudiante concurrente");
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", administratorId, "administrator@example.invalid", "Administrativo sintético");
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", profileStudentId, "profile@example.invalid", "Perfil sintético");
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", availabilityClinicianId, "availability-doctor@example.invalid", "Médico disponibilidad");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion))", studentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion))", lockedStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion))", concurrentStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion))", administratorId, "ADMINISTRATIVE");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion))", profileStudentId, "STUDENT");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion))", availabilityClinicianId, "REVIEW_DOCTOR");
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
        if (migratorDataSource != null) {
            migratorDataSource.close();
        }
        CoberturaFuncionesSql.registrar(POSTGRES.getJdbcUrl(), "salud_u_migrator", "migrator-test-password", "DatabaseActorContextIntegrationTest");
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
    void actorContextStoresRolesInSpanishAndRejectsUnknownApiCodes() {
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("STUDENT", "REVIEW_DOCTOR", "AUDITOR")));
            assertEquals("AUDITOR,MEDICO_REVISION,ESTUDIANTE", runtimeJdbc.queryForObject("select current_setting('salud_u.roles_actor')", String.class));
            assertEquals(Boolean.TRUE, runtimeJdbc.queryForObject("select salud_u.tiene_rol_actor('MEDICO_REVISION')", Boolean.class));
        });
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status ->
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("ROOT")))));
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
            "update salud_u.rol_principal set revocado_en = now() where id_principal = ? and codigo_rol = cast(salud_u.desde_codigo_api('rol', ?) as salud_u.codigo_rol_aplicacion) and revocado_en is null",
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
            "select count(*) from salud_u.evento_auditoria where id_actor = ? and accion in ('PERFIL_ACTUALIZADO', 'CONTRASENA_CAMBIADA')", Integer.class, profileStudentId
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
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.inscripcion_academica where id_paciente = ? and estado = 'ACTIVA'", Integer.class, patientId));
        assertFalse(migratorJdbc.queryForObject(
            "select has_table_privilege('salud_u_runtime', 'salud_u.paciente', 'SELECT, INSERT, UPDATE, DELETE')", Boolean.class
        ));
    }

    @Test
    void spanishPatientDomainsKeepApiCodesAndEmailWhilePreservingEnrollmentRules() {
        var administrator = new SessionPrincipal(administratorId, "administrator@example.invalid", "Administrativo", java.util.List.of("ADMINISTRATIVE"));
        String suffix = UUID.randomUUID().toString();
        UUID patient = transaction.execute(status -> patientService.create(administrator,
            new PatientService.PatientCommand("ES07-" + suffix, "REG-ES07-" + suffix, "Paciente", "ES07", null, null,
                "  ES07@EXAMPLE.INVALID  ", patientCareerId, "ES07-2026", LocalDate.now())));
        assertEquals("es07@example.invalid", migratorJdbc.queryForObject("select correo from salud_u.paciente where id=?", String.class, patient));
        assertEquals("ACTIVO", migratorJdbc.queryForObject("select estado_academico from salud_u.paciente where id=?", String.class, patient));
        for (var entry : Map.of("ACTIVO", "ACTIVE", "INACTIVO", "INACTIVE", "EGRESADO", "GRADUATED", "SUSPENDIDO", "SUSPENDED").entrySet()) {
            migratorJdbc.update("update salud_u.paciente set estado_academico=? where id=?", entry.getKey(), patient);
            var detail = transaction.execute(status -> patientService.get(administrator, patient).orElseThrow());
            assertEquals(entry.getValue(), detail.academicStatus());
            assertEquals("es07@example.invalid", detail.email());
            var listed = transaction.execute(status -> patientService.list(administrator, "ES07-" + suffix));
            assertEquals(entry.getValue(), listed.stream().filter(item -> item.id().equals(patient)).findFirst().orElseThrow().academicStatus());
        }
        for (var entry : Map.of("ACTIVA", "ACTIVE", "INACTIVA", "INACTIVE", "COMPLETADA", "COMPLETED").entrySet()) {
            migratorJdbc.update("update salud_u.inscripcion_academica set estado=? where id_paciente=?", entry.getKey(), patient);
            assertEquals(entry.getValue(), transaction.execute(status -> patientService.get(administrator, patient).orElseThrow().enrollment().status()));
        }
        assertThrows(DataAccessException.class, () -> migratorJdbc.update("update salud_u.paciente set estado_academico='ACTIVE' where id=?", patient));
        assertThrows(DataAccessException.class, () -> migratorJdbc.update("update salud_u.inscripcion_academica set estado='ACTIVE' where id_paciente=?", patient));
        transaction.executeWithoutResult(status -> patientService.update(administrator, patient,
            new PatientService.PatientCommand("ES07-" + suffix, "REG-ES07-" + suffix, "Paciente", "ES07", null, null,
                null, patientCareerId, "ES07-2027", LocalDate.now())));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.inscripcion_academica where id_paciente=? and estado='ACTIVA'", Integer.class, patient));
        org.junit.jupiter.api.Assertions.assertNull(transaction.execute(status -> patientService.get(administrator, patient).orElseThrow().email()));
        assertThrows(DataAccessException.class, () -> migratorJdbc.update(
            "insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en) values (?,?,'ES07-duplicada',current_date)", patient, patientCareerId));
        assertEquals(0, migratorJdbc.queryForObject("select count(*) from information_schema.columns where table_schema='salud_u' and table_name in ('paciente','principal') and column_name='email'", Integer.class));
    }

    @Test
    void availabilityGeneratesBoliviaSlotsBlocksThemAndPreservesBookedSlotsOnReplacement() throws Exception {
        SessionPrincipal clinician = new SessionPrincipal(availabilityClinicianId, "availability-doctor@example.invalid", "Médico disponibilidad", java.util.List.of("REVIEW_DOCTOR"));
        LocalDate nextMonday = LocalDate.now(ZoneId.of("America/La_Paz")).with(TemporalAdjusters.nextOrSame(java.time.DayOfWeek.MONDAY));
        var mapper = new ObjectMapper();
        var rules = mapper.readTree("[{\"weekday\":1,\"startsAt\":\"08:00\",\"endsAt\":\"09:00\",\"slotDurationMinutes\":30,\"specialtyId\":null}]");
        transaction.executeWithoutResult(status -> assertTrue(availabilityService.replace(clinician, rules, mapper.createArrayNode()) >= 2));
        assertEquals(2, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where id_personal = ? and (inicia_a at time zone 'America/La_Paz')::date = ? and estado = 'PUBLICADO'", Integer.class, availabilityStaffId, nextMonday
        ));
        transaction.executeWithoutResult(status -> availabilityService.createBlock(clinician, nextMonday, null, null, "Feriado sintético"));
        assertEquals(2, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where id_personal = ? and (inicia_a at time zone 'America/La_Paz')::date = ? and estado = 'BLOQUEADO'", Integer.class, availabilityStaffId, nextMonday
        ));
        migratorJdbc.update("update salud_u.cupo_disponibilidad set cantidad_reservada = 1 where id = (select id from salud_u.cupo_disponibilidad where id_personal = ? and estado = 'BLOQUEADO' limit 1)", availabilityStaffId);
        transaction.executeWithoutResult(status -> availabilityService.replace(clinician, rules, mapper.createArrayNode()));
        assertEquals(1, migratorJdbc.queryForObject(
            "select count(*) from salud_u.cupo_disponibilidad where id_personal = ? and cantidad_reservada = 1 and estado <> 'CERRADO'", Integer.class, availabilityStaffId
        ));
        var startsAt = java.time.OffsetDateTime.now().plusDays(300).withNano(0);
        transaction.executeWithoutResult(status -> availabilityService.publish(clinician, startsAt, startsAt.plusMinutes(30), 1, null));
        var overlap = assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class, () -> transaction.executeWithoutResult(status -> availabilityService.publish(clinician, startsAt.plusMinutes(15), startsAt.plusMinutes(45), 1, null)));
        assertEquals(409, overlap.status());
        assertTrue(overlap.getMessage().startsWith("El cupo se superpone"));
        var past = assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class, () -> transaction.executeWithoutResult(status -> availabilityService.publish(clinician, startsAt.minusDays(400), startsAt.minusDays(400).plusMinutes(30), 1, null)));
        assertEquals(400, past.status());
        var lastStartsAt = startsAt.plusDays(1).plusHours(119);
        transaction.executeWithoutResult(status -> {
            for (int hour = 0; hour < 120; hour++) availabilityService.publish(clinician, startsAt.plusDays(1).plusHours(hour), startsAt.plusDays(1).plusHours(hour).plusMinutes(30), 1, null);
        });
        var published = transaction.execute(status -> availabilityService.published(clinician, false));
        assertTrue(published.size() >= 121, "el listado de cupos publicados no debe cortarse en 100");
        assertTrue(published.stream().anyMatch(slot -> slot.startsAt().toInstant().equals(lastStartsAt.toInstant())));
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
    void documentTypeCatalogStoresKnownApiCodesInSpanishAndKeepsCustomCodes() {
        String save = "select salud_u.guardar_catalogo_administracion(?, ?, ?, ?, ?)";
        UUID[] ids = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return new UUID[] {
                runtimeJdbc.queryForObject(save, UUID.class, "DOCUMENT_TYPE", null, "blood_chemistry", "Química sanguínea", true),
                runtimeJdbc.queryForObject(save, UUID.class, "DOCUMENT_TYPE", null, "ECOGRAFIA", "Ecografía", true)
            };
        });
        try {
            assertEquals("QUIMICA_SANGUINEA", migratorJdbc.queryForObject("select codigo from salud_u.tipo_documento where id=?", String.class, ids[0]));
            assertEquals("ECOGRAFIA", migratorJdbc.queryForObject("select codigo from salud_u.tipo_documento where id=?", String.class, ids[1]));
            transaction.executeWithoutResult(status -> {
                actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
                assertEquals(java.util.List.of("ECOGRAFIA", "BLOOD_CHEMISTRY"), runtimeJdbc.queryForList(
                    "select codigo from salud_u.listar_catalogo('DOCUMENT_TYPE') where id = any(?)", String.class, (Object) ids));
                assertEquals(ids[0], runtimeJdbc.queryForObject(save, UUID.class, "DOCUMENT_TYPE", ids[0], "BLOOD_CHEMISTRY", "Química sanguínea", false));
                assertEquals(java.util.List.of("ECOGRAFIA", "BLOOD_CHEMISTRY"), runtimeJdbc.queryForList(
                    "select codigo from salud_u.listar_catalogo_administracion('DOCUMENT_TYPE') where id = any(?)", String.class, (Object) ids));
            });
            for (String kind : new String[] {"TIPO_DOCUMENTO", "OTRA", ""}) {
                var error = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
                    actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
                    runtimeJdbc.queryForList("select codigo from salud_u.listar_catalogo(?)", String.class, kind);
                }));
                assertTrue(error.getMessage().contains("Tipo de catálogo no válido"), error.getMessage());
            }
        } finally {
            migratorJdbc.update("delete from salud_u.tipo_documento where id = any(?)", (Object) ids);
        }
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
        migratorJdbc.update("insert into salud_u.principal(id, correo, nombre_mostrado) values (?, ?, ?)", principalId, "be10-doctor@example.invalid", "Médico BE-10");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal, codigo_rol) values (?, 'MEDICO_REVISION')", principalId);
        migratorJdbc.update("insert into salud_u.personal(id, id_principal, codigo_personal) values (?, ?, ?)", personalId, principalId, "BE10-DOCTOR");
        migratorJdbc.update("insert into salud_u.paciente(id, carnet, carnet_normalizado, codigo_registro, codigo_registro_normalizado, nombres, apellidos, creado_por, actualizado_por) values (?, 'BE10-01', 'BE1001', 'REG-BE10', 'REGBE10', 'Paciente', 'Prueba', ?, ?)", patientId, principalId, principalId);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente, abierta_por) values (?, ?)", patientId, principalId);
        migratorJdbc.update("insert into salud_u.version_antecedente_clinico(id, id_paciente, numero_version, datos, registrado_por, motivo_cambio) values (?, ?, 1, cast(? as jsonb), ?, 'Ingreso inicial')", backgroundId, patientId, "{\"schemaVersion\":1,\"allergies\":[],\"personalConditions\":[],\"surgeries\":[],\"medications\":[],\"familyHistory\":[],\"habits\":{}}", principalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id, id_personal, inicia_a, termina_a, capacidad, estado, publicado_en, creado_por) values (?, ?, now() + interval '1 day', now() + interval '1 day 30 minutes', 1, 'PUBLICADO', now(), ?)", slotId, personalId, principalId);
        migratorJdbc.update("insert into salud_u.cita(id, id_paciente, id_cupo, tipo_cita, id_personal_asignado, programada_para) values (?, ?, ?, 'INICIAL', ?, now() + interval '1 day')", appointmentId, patientId, slotId, personalId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id, id_cita, id_paciente, id_personal, tipo_encuentro, id_version_antecedente_clinico) values (?, ?, ?, ?, 'INICIAL', ?)", encounterId, appointmentId, patientId, personalId, backgroundId);

        String reviewHistory = "{\"schemaVersion\":1,\"personalHistory\":{},\"habits\":{},\"vitals\":{\"bloodPressureSystolic\":\"120\",\"heartRate\":\"72\",\"weight\":\"70.5\"},\"physicalExam\":{},\"laboratory\":{},\"conduct\":{}}";
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(principalId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_revision(?, ?, ?, ?, ?, ?, ?, cast(? as jsonb))", String.class,
                encounterId, "Control clínico", "Evaluación estable", null, null, "ATTACHED", null, reviewHistory);
        }));
        assertEquals("BORRADOR", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id = ?", String.class, encounterId));
        assertEquals(0, migratorJdbc.queryForObject("select count(*) from salud_u.ficha_revision_version where id_encuentro = ?", Integer.class, encounterId));
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(principalId, java.util.Set.of("REVIEW_DOCTOR")));
            String result = runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_revision(?, ?, ?, ?, ?, ?, ?, cast(? as jsonb))", String.class,
                encounterId, "Control clínico", "Evaluación estable", "Hidratación", null, "PENDING", "Sin hallazgos agudos", reviewHistory);
            assertTrue(result.contains("\"encounterId\": \"" + encounterId + "\""));
            assertTrue(result.contains("\"referralId\": null"));
            assertTrue(result.contains("\"reviewHistoryVersion\": 1"));
        });

        assertEquals("CERRADA", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id = ?", String.class, encounterId));
        assertEquals("ATENDIDA", migratorJdbc.queryForObject("select estado from salud_u.cita where id = ?", String.class, appointmentId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita = ? and estado_nuevo = 'ATENDIDA'", Integer.class, appointmentId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.ficha_revision_version where id_encuentro = ?", Integer.class, encounterId));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.diagnostico_encuentro where id_encuentro = ?", Integer.class, encounterId));
        assertEquals(3, migratorJdbc.queryForObject("select count(*) from salud_u.medicion_encuentro where id_encuentro = ?", Integer.class, encounterId));
        UUID secondSlot=UUID.randomUUID(),secondAppointment=UUID.randomUUID(),secondEncounter=UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '2 days',now()+interval '2 days 30 minutes',1,'PUBLICADO',now(),?)",secondSlot,personalId,principalId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INICIAL',?,now()+interval '2 days')",secondAppointment,patientId,secondSlot,personalId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro) values (?,?,?,?,'INICIAL')",secondEncounter,secondAppointment,patientId,personalId);
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
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", principalId, "be11-owner@example.invalid", "Médico propietario");
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", otherPrincipalId, "be11-other@example.invalid", "Médico ajeno");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?, 'MEDICO_REVISION'), (?, 'MEDICO_REVISION')", principalId, otherPrincipalId);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?), (?,?,?)", personalId, principalId, "BE11-OWNER", otherPersonalId, otherPrincipalId, "BE11-OTHER");
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE11-01','BE1101','REG-BE11','REGBE11','Paciente','Documento',?,?)", patientId, principalId, principalId);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente,abierta_por) values (?,?)", patientId, principalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now()+interval '1 day', now()+interval '1 day 30 minutes',1,'PUBLICADO',now(),?)", slotId, personalId, principalId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?, ?, ?, 'INICIAL', ?, now()+interval '1 day')", appointmentId, patientId, slotId, personalId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro) values (?, ?, ?, ?, 'INICIAL')", encounterId, appointmentId, patientId, personalId);
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

        assertEquals("DISPONIBLE", migratorJdbc.queryForObject("select estado from salud_u.documento_clinico where id=?", String.class, documentId));
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
        // Commit fallido después de mover el archivo: ni fila ni archivo (sin escritura partida).
        UUID rolledBack = transaction.execute(status -> { UUID id = documents.upload(owner, patientId, encounterId, "LAB_RESULT", null, null, new MockMultipartFile("file", "revertido.pdf", "application/pdf", pdf)); status.setRollbackOnly(); return id; });
        assertEquals(0, migratorJdbc.queryForObject("select count(*) from salud_u.documento_clinico where id=?", Integer.class, rolledBack));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.documento_clinico where id_encuentro=?", Integer.class, encounterId));
        try (var files = Files.walk(root)) {
            assertEquals(1L, files.filter(Files::isRegularFile).count());
        }
        assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->documents.upload(owner,patientId,encounterId,"OTHER",null,null,new MockMultipartFile("file","tamano.pdf","application/pdf",pdf){@Override public long getSize(){return pdf.length+1;}})));
        var locked=new CountDownLatch(1);var release=new CountDownLatch(1);var uploading=new CountDownLatch(1);
        var migratorTransaction=new TransactionTemplate(new DataSourceTransactionManager(migratorJdbc.getDataSource()));
        try(var pool=Executors.newFixedThreadPool(2)) {
            var closing=pool.submit(()->migratorTransaction.execute(status->{
                migratorJdbc.update("update salud_u.encuentro_clinico set estado='CERRADA',cerrado_en=now(),cerrado_por=? where id=?",principalId,encounterId);locked.countDown();
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
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '100 days',now()+interval '100 days 30 minutes',1,'PUBLICADO',now(),?)",slot,availabilityStaffId,availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INICIAL',?,now()+interval '100 days')",appointment,patient,slot,availabilityStaffId);
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
        migratorJdbc.update("update salud_u.encuentro_clinico set estado='CERRADA',cerrado_en=now(),cerrado_por=? where id=?",owner.id(),encounter);
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
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,'fe03-outsider@example.invalid','Ajeno FE03')",outsider);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'MEDICO_REVISION')",outsider);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'FE03-AJENO')",staff,outsider);
        var other=new SessionPrincipal(outsider,"fe03-outsider@example.invalid","Ajeno",java.util.List.of("REVIEW_DOCTOR"));
        var denied=assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->controller.get(patient,null,other)));
        assertEquals(404,denied.status());
    }

    @Test
    void administrativeAccountListingMapsActualSqlColumnsAndEmptyRevokedOrMultipleRoles() {
        var service = new bo.edu.uagrm.saludu.catalogs.application.CatalogService(runtimeJdbc, actorContext, auditWriter);
        UUID withoutRoles = UUID.randomUUID(), revoked = UUID.randomUUID(), multiple = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado,activo) values (?,'fecat-empty@example.invalid','FE-CAT A',false),(?,'fecat-revoked@example.invalid','FE-CAT B',true),(?,'fecat-multiple@example.invalid','FE-CAT C',true)", withoutRoles, revoked, multiple);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol,revocado_en) values (?,'ESTUDIANTE',now()),(?,'MEDICO_REVISION',null),(?,'ESPECIALISTA',null)", revoked, multiple, multiple);
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
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,'fe09-outsider@example.invalid','Médico ajeno')", outsider);
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'MEDICO_REVISION')", outsider);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,'FE09-OUTSIDER')", outsiderStaff, outsider);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,'FE09-OWN','FE09OWN','REG-FE09','REGFE09','Paciente','FE09',?,?)", patient, administratorId, administratorId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por) values (?,?,now()+interval '95 days',now()+interval '95 days 30 minutes',1,1,'PUBLICADO',now(),?)", slot, availabilityStaffId, availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INICIAL',?,now()+interval '95 days')", appointment, patient, slot, availabilityStaffId);
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
        migratorJdbc.update("update salud_u.cita set estado='AUSENTE' where id=?", appointment);
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
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '90 days',now()+interval '90 days 30 minutes',1,'PUBLICADO',now(),?)", slot, availabilityStaffId, availabilityClinicianId);
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
        assertEquals("CANCELADA", migratorJdbc.queryForObject("select estado from salud_u.cita where id=?", String.class, appointment));
        assertNotNull(migratorJdbc.queryForObject("select cancelada_en from salud_u.cita where id=?", java.time.OffsetDateTime.class, appointment));
        assertEquals("Motivo FE08", migratorJdbc.queryForObject("select motivo_cancelacion from salud_u.solicitud_cita where id=?", String.class, request));
        assertEquals(studentId, migratorJdbc.queryForObject("select cancelada_por from salud_u.solicitud_cita where id=?", UUID.class, request));
        assertEquals(0, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, slot));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='CANCELADA'", Integer.class, appointment));

        UUID otherRequest = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.crear_solicitud_inicial(?)", UUID.class, unlinkedPatient);
        });
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(studentId, java.util.Set.of("STUDENT")));
            runtimeJdbc.queryForObject("select salud_u.cancelar_solicitud_cita(?,null)", Object.class, otherRequest);
        }));
        assertEquals("PENDIENTE", migratorJdbc.queryForObject("select estado from salud_u.solicitud_cita where id=?", String.class, otherRequest));
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
        assertEquals("ASIGNADA", migratorJdbc.queryForObject("select estado from salud_u.solicitud_cita where id=?", String.class, otherRequest));
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
        assertEquals("AUSENTE", migratorJdbc.queryForObject("select estado from salud_u.cita where id=?", String.class, secondAppointment));
        assertEquals(0, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, slot));
        assertEquals("Motivo ausencia", migratorJdbc.queryForObject("select motivo from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='AUSENTE'", String.class, secondAppointment));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_cita where id_cita=? and estado_nuevo='AUSENTE'", Integer.class, secondAppointment));
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

        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?),(?,?,?)", sourcePrincipalId, "be14-source@example.invalid", "Médico origen", specialistPrincipalId, "be14-specialist@example.invalid", "Especialista destino");
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?),(?,?,?)", sourceStaffId, sourcePrincipalId, "BE14-SOURCE", specialistStaffId, specialistPrincipalId, "BE14-SPECIALIST");
        migratorJdbc.update("insert into salud_u.especialidad(id,codigo,nombre,activo) values (?, 'BE14-SPECIALTY', 'Especialidad BE-14', true),(?, 'BE14-OTHER', 'Otra especialidad', true)", specialtyId, otherSpecialtyId);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE14-01','BE1401','REG-BE14','REGBE14','Paciente','Derivación',?,?)", patientId, sourcePrincipalId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente,abierta_por) values (?,?)", patientId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now()+interval '2 days', now()+interval '2 days 30 minutes',1,'PUBLICADO',now(),?)", sourceSlotId, sourceStaffId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) values (?, ?, ?, 'INICIAL', ?, now()+interval '2 days', 'ATENDIDA')", sourceAppointmentId, patientId, sourceSlotId, sourceStaffId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado) values (?, ?, ?, ?, 'INICIAL', 'CERRADA')", sourceEncounterId, sourceAppointmentId, patientId, sourceStaffId);
        migratorJdbc.update("insert into salud_u.derivacion(id,id_paciente,id_encuentro_origen,id_especialidad,prioridad,motivo,resumen_para_especialista,creada_por) values (?, ?, ?, ?, 'PRIORITARIA', 'Motivo BE-14', 'Resumen para especialista', ?)", referralId, patientId, sourceEncounterId, specialtyId, sourcePrincipalId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, ?, now()+interval '3 days', now()+interval '3 days 30 minutes',1,'PUBLICADO',now(),?),(?, ?, ?, now()+interval '4 days', now()+interval '4 days 30 minutes',1,'PUBLICADO',now(),?)", incompatibleSlotId, specialistStaffId, otherSpecialtyId, specialistPrincipalId, compatibleSlotId, specialistStaffId, specialtyId, specialistPrincipalId);

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
        assertEquals("PENDIENTE", migratorJdbc.queryForObject("select estado from salud_u.solicitud_cita where id=?", String.class, requestId));
        assertEquals(0, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, incompatibleSlotId));

        var assigner=new bo.edu.uagrm.saludu.agenda.api.AppointmentAssignmentController(runtimeJdbc,actorContext,auditWriter);
        var startAssign=new CountDownLatch(1);var assigned=new java.util.concurrent.atomic.AtomicReference<UUID>();
        try(var pool=Executors.newFixedThreadPool(2)){
            java.util.concurrent.Callable<Integer> assign=()->{startAssign.await();try{var result=transaction.execute(status->assigner.assign(requestId,Map.of("slotId",compatibleSlotId.toString()),admin));assigned.set(result.data().get("appointmentId"));return 200;}catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException exception){return exception.status();}};
            var a=pool.submit(assign);var b=pool.submit(assign);startAssign.countDown();assertEquals(java.util.Set.of(200,409),java.util.Set.of(a.get(10,TimeUnit.SECONDS),b.get(10,TimeUnit.SECONDS)));
        }
        UUID appointmentId=assigned.get();
        assertEquals("ASIGNADA", migratorJdbc.queryForObject("select estado from salud_u.derivacion where id=?", String.class, referralId));
        assertEquals(referralId, migratorJdbc.queryForObject("select id_derivacion from salud_u.cita where id=?", UUID.class, appointmentId));
        assertEquals(originalSource,migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,sourceEncounterId));
        assertEquals(originalClinical,migratorJdbc.queryForObject("select (to_jsonb(d)-array['estado','id_personal_asignado','asignada_en'])::text from salud_u.derivacion d where id=?",String.class,referralId));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_derivacion where id_derivacion=? and estado_nuevo='ASIGNADA' and id_actor=?",Integer.class,referralId,administratorId));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='DERIVACION_PROGRAMADA' and id_actor=?",Integer.class,referralId,administratorId));
        var referrals=new bo.edu.uagrm.saludu.referrals.api.ReferralController(runtimeJdbc,actorContext,auditWriter);
        assertTrue(transaction.execute(status->referrals.inbox(admin)).data().stream().anyMatch(item->item.get("id").equals(referralId)&&item.get("status").equals("ASSIGNED")&&item.get("appointment_id").equals(appointmentId)));
        migratorJdbc.update("update salud_u.derivacion set estado='CERRADA' where id=?",referralId);
        assertEquals(409,assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->creator.create(body,admin))).status());
        assertTrue(transaction.execute(status->referrals.patient(patientId,admin)).data().stream().noneMatch(item->item.get("id").equals(referralId)));
        assertTrue(transaction.execute(status->referrals.inbox(admin)).data().stream().anyMatch(item->item.get("id").equals(referralId)&&item.get("status").equals("CLOSED")));
        migratorJdbc.update("update salud_u.derivacion set estado='ASIGNADA' where id=?",referralId);
        assertEquals("ESPECIALIDAD", migratorJdbc.queryForObject("select tipo_cita from salud_u.cita where id=?", String.class, appointmentId));
        assertEquals(1, migratorJdbc.queryForObject("select cantidad_reservada from salud_u.cupo_disponibilidad where id=?", Integer.class, compatibleSlotId));
        assertEquals("CERRADA", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id=?", String.class, sourceEncounterId));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.asignar_solicitud_cita(?,?)", UUID.class, requestId, compatibleSlotId);
        }));
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'ESPECIALISTA')",specialistPrincipalId);
        migratorJdbc.update("insert into salud_u.especialidad_personal(id_personal,id_especialidad,vigente_desde) values (?,?,current_date)",specialistStaffId,specialtyId);
        UUID specialized=transaction.execute(status -> { actorContext.apply(new DatabaseActor(specialistPrincipalId,java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select id_encuentro from salud_u.abrir_encuentro_borrador(?)",UUID.class,appointmentId); });
        assertEquals(specialized,transaction.execute(status -> { actorContext.apply(new DatabaseActor(specialistPrincipalId,java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select id_encuentro from salud_u.abrir_encuentro_borrador(?)",UUID.class,appointmentId); }));
        assertEquals("EN_CURSO",migratorJdbc.queryForObject("select estado from salud_u.derivacion where id=?",String.class,referralId));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_derivacion where id_derivacion=? and estado_nuevo='EN_CURSO'",Integer.class,referralId));
        var specialistSession=new SessionPrincipal(specialistPrincipalId,"be14-specialist@example.invalid","Especialista destino",java.util.List.of("SPECIALIST"));
        assertEquals(409,assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->referrals.resolve(referralId,Map.of("action","RESOLVE"),specialistSession))).status());
        var returnedBody=Map.<String,Object>of("action","RETURN","reason","Motivo de devolución","followUpText","Seguimiento");
        migratorJdbc.update("update salud_u.especialidad set activo=false where id=?",specialtyId);
        assertEquals(403,assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class,()->transaction.execute(status->referrals.resolve(referralId,returnedBody,specialistSession))).status());
        migratorJdbc.update("update salud_u.especialidad set activo=true where id=?",specialtyId);
        assertThrows(IllegalStateException.class,()->transaction.executeWithoutResult(status->{referrals.resolve(referralId,returnedBody,specialistSession);throw new IllegalStateException("Fallo posterior para comprobar rollback");}));
        assertEquals("EN_CURSO",migratorJdbc.queryForObject("select estado from salud_u.derivacion where id=?",String.class,referralId));
        assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='DERIVACION_DEVUELTA'",Integer.class,referralId));
        var startReturn=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)){
            java.util.concurrent.Callable<Integer> change=()->{startReturn.await();try{transaction.execute(status->referrals.resolve(referralId,returnedBody,specialistSession));return 200;}catch(bo.edu.uagrm.saludu.agenda.application.AvailabilityException exception){return exception.status();}};
            var a=pool.submit(change);var b=pool.submit(change);startReturn.countDown();assertEquals(java.util.Set.of(200,403),java.util.Set.of(a.get(10,TimeUnit.SECONDS),b.get(10,TimeUnit.SECONDS)));
        }
        assertEquals("DEVUELTA",migratorJdbc.queryForObject("select estado from salud_u.derivacion where id=?",String.class,referralId));
        assertEquals("Motivo de devolución",migratorJdbc.queryForObject("select motivo_devolucion from salud_u.derivacion where id=?",String.class,referralId));
        assertEquals("Seguimiento",migratorJdbc.queryForObject("select seguimiento from salud_u.derivacion where id=?",String.class,referralId));
        assertEquals(specialistPrincipalId,migratorJdbc.queryForObject("select devuelta_por from salud_u.derivacion where id=?",UUID.class,referralId));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_estado_derivacion where id_derivacion=? and estado_nuevo='DEVUELTA' and id_actor=?",Integer.class,referralId,specialistPrincipalId));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='DERIVACION_DEVUELTA' and id_actor=?",Integer.class,referralId,specialistPrincipalId));
        assertEquals(originalSource,migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,sourceEncounterId));
    }

    @Test
    void specialistClosesOwnDirectEncounterWithImmutableVersionedTemplate() {
        UUID specialist = UUID.randomUUID(), outsider = UUID.randomUUID(), specialistStaff = UUID.randomUUID(), outsiderStaff = UUID.randomUUID();
        UUID patient = UUID.randomUUID(), specialty = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID();
        UUID template = UUID.randomUUID(), replacementTemplate = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?),(?,?,?)", specialist,"be15-specialist@example.invalid","Especialista BE-15",outsider,"be15-outsider@example.invalid","Ajeno BE-15");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'ESPECIALISTA'),(?,'ESPECIALISTA')", specialist,outsider);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?),(?,?,?)", specialistStaff,specialist,"BE15-OWN",outsiderStaff,outsider,"BE15-OTHER");
        migratorJdbc.update("insert into salud_u.especialidad(id,codigo,nombre,activo) values (?, 'BE15-CARDIO', 'Cardiología BE-15', true)", specialty);
        migratorJdbc.update("insert into salud_u.especialidad_personal(id_personal,id_especialidad,vigente_desde) values (?,?,current_date),(?,?,current_date)", specialistStaff,specialty,outsiderStaff,specialty);
        migratorJdbc.update("insert into salud_u.plantilla_ficha_especialidad(id,id_especialidad,numero_version,esquema) values (?,?,1,'{}')", template,specialty);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE15-01','BE1501','REG-BE15','REGBE15','Paciente','Especialidad',?,?)", patient,specialist,specialist);
        migratorJdbc.update("insert into salud_u.historia_clinica(id_paciente,abierta_por) values (?,?)", patient,specialist);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, ?, now()+interval '2 days',now()+interval '2 days 30 minutes',1,'PUBLICADO',now(),?)", slot,specialistStaff,specialty,specialist);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?, ?, ?, 'ESPECIALIDAD', ?, now()+interval '2 days')", appointment,patient,slot,specialistStaff);
        UUID encounter = transaction.execute(status -> { actorContext.apply(new DatabaseActor(specialist, java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select id_encuentro from salud_u.abrir_encuentro_borrador(?)", UUID.class, appointment); });
        migratorJdbc.update("update salud_u.encuentro_clinico set ocurrido_en='2026-10-25T02:30:00Z' where id=?",encounter);
        String history = "{\"schemaVersion\":1,\"specialtyCode\":\"BE15-CARDIO\",\"personalHistory\":{},\"ophthalmology\":{},\"gynecology\":{}}";
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(outsider, java.util.Set.of("SPECIALIST"))); runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))", String.class, encounter,"Motivo","Evaluación",null,null,null,history); }));
        assertTrue(transaction.<Boolean>execute(status -> { actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select salud_u.verificar_plantilla_encuentro(?,?)",Boolean.class,encounter,template); }));
        assertFalse(transaction.<Boolean>execute(status -> { actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select salud_u.verificar_plantilla_encuentro(?,?)",Boolean.class,encounter,UUID.randomUUID()); }));
        migratorJdbc.update("update salud_u.cita set estado='AUSENTE' where id=?",appointment);
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST"))); runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))",String.class,encounter,"Motivo","Evaluación","Plan","Control","Diagnóstico",history); }));
        assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.version_ficha_especialidad where id_encuentro=?",Integer.class,encounter));
        assertEquals("BORRADOR",migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id=?",String.class,encounter));
        assertEquals(0,migratorJdbc.queryForObject("select count(*) from salud_u.diagnostico_encuentro where id_encuentro=?",Integer.class,encounter));
        migratorJdbc.update("update salud_u.cita set estado='PROGRAMADA' where id=?",appointment);
        migratorJdbc.update("update salud_u.especialidad set activo=false where id=?",specialty);
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST"))); runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))",String.class,encounter,"Motivo","Evaluación",null,null,null,history); }));
        migratorJdbc.update("update salud_u.especialidad set activo=true where id=?",specialty);
        String result = transaction.execute(status -> { actorContext.apply(new DatabaseActor(specialist, java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))", String.class, encounter,"Motivo","Evaluación","Plan","Control","Diagnóstico",history); });
        assertEquals("Motivo",migratorJdbc.queryForObject("select motivo_consulta from salud_u.encuentro_clinico where id=?",String.class,encounter));
        assertEquals("Evaluación",migratorJdbc.queryForObject("select evaluacion from salud_u.encuentro_clinico where id=?",String.class,encounter));
        assertEquals("Plan",migratorJdbc.queryForObject("select indicaciones from salud_u.encuentro_clinico where id=?",String.class,encounter));
        assertEquals("Control",migratorJdbc.queryForObject("select seguimiento from salud_u.encuentro_clinico where id=?",String.class,encounter));
        assertEquals(specialist,migratorJdbc.queryForObject("select cerrado_por from salud_u.encuentro_clinico where id=?",UUID.class,encounter));
        assertTrue(result.contains("specialtyHistoryVersion"));
        assertTrue(migratorJdbc.queryForObject("select jsonb_exists(datos,'codigoEspecialidad') AND jsonb_exists(datos,'ginecologia') AND NOT jsonb_exists(datos,'specialtyCode') from salud_u.version_ficha_especialidad where id_encuentro=?",Boolean.class,encounter));
        assertEquals("CERRADA", migratorJdbc.queryForObject("select estado from salud_u.encuentro_clinico where id=?", String.class, encounter));
        assertEquals("ATENDIDA", migratorJdbc.queryForObject("select estado from salud_u.cita where id=?", String.class, appointment));
        assertEquals(template, migratorJdbc.queryForObject("select id_plantilla from salud_u.version_ficha_especialidad where id_encuentro=?", UUID.class, encounter));
        migratorJdbc.update("update salud_u.plantilla_ficha_especialidad set activa=false where id=?", template);
        migratorJdbc.update("insert into salud_u.plantilla_ficha_especialidad(id,id_especialidad,numero_version,esquema) values (?,?,2,'{}')", replacementTemplate,specialty);
        String storedContext=transaction.execute(status -> { actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST"))); return runtimeJdbc.queryForObject("select salud_u.obtener_contexto_encuentro_propio(?)::text",String.class,encounter); });
        assertTrue(storedContext.contains(template.toString()));
        assertFalse(storedContext.contains(replacementTemplate.toString()));
        assertTrue(storedContext.contains("specialtyHistoryVersion"));
        assertEquals(template, migratorJdbc.queryForObject("select id_plantilla from salud_u.version_ficha_especialidad where id_encuentro=?", UUID.class, encounter));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(specialist, java.util.Set.of("SPECIALIST"))); runtimeJdbc.queryForObject("select salud_u.finalizar_encuentro_especialidad(?,?,?,?,?,?,cast(? as jsonb))", String.class, encounter,"Otro","Otro",null,null,null,history); }));
        String longitudinal=transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select salud_u.obtener_historia_longitudinal_area(?)::text",String.class,patient);});
        assertTrue(longitudinal.contains(template.toString()));
        for(String text:java.util.List.of(" EVALUACION ","evaluacio\u0301n","diagNOSTICO","control")){
            var found=transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForList("select id from salud_u.buscar_historia_autorizada(?,?,?,?)",UUID.class,patient,java.time.LocalDate.parse("2026-10-24"),java.time.LocalDate.parse("2026-10-24"),text);});
            assertEquals(java.util.List.of(encounter),found);
        }
        assertEquals(java.util.List.of(),transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForList("select id from salud_u.buscar_historia_autorizada(?,?,?,?)",UUID.class,patient,java.time.LocalDate.parse("2026-10-25"),java.time.LocalDate.parse("2026-10-25"),"evaluacion");}));
        assertEquals(java.util.List.of(),transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForList("select id from salud_u.buscar_historia_autorizada(?,NULL,NULL,?)",UUID.class,patient,"%");}));
        assertFalse(longitudinal.contains(replacementTemplate.toString()));
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(outsider,java.util.Set.of("SPECIALIST")));runtimeJdbc.queryForObject("select salud_u.obtener_historia_longitudinal_area(?)::text",String.class,patient);}));
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(outsider,java.util.Set.of("SPECIALIST")));runtimeJdbc.query("select * from salud_u.buscar_historia_autorizada(?,NULL,NULL,NULL)",r->{},patient);}));
        UUID peerSlot=UUID.randomUUID(),peerAppointment=UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,id_especialidad,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,?,now()+interval '10 days',now()+interval '10 days 30 minutes',1,'PUBLICADO',now(),?)",peerSlot,outsiderStaff,specialty,outsider);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'ESPECIALIDAD',?,now()+interval '10 days')",peerAppointment,patient,peerSlot,outsiderStaff);
        String peerHistory=transaction.execute(status->{actorContext.apply(new DatabaseActor(outsider,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select salud_u.obtener_historia_longitudinal_area(?)::text",String.class,patient);});
        assertTrue(peerHistory.contains(encounter.toString()));
        assertTrue(peerHistory.contains("specialtyHistoryVersion"));
        UUID doc=UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.documento_clinico(id,id_paciente,id_encuentro,tipo_documento,estado,ruta_objeto,nombre_original,tipo_mime,tamano_bytes,checksum_sha256,cargado_por,disponible_en) values (?,?,?,'OTRO','DISPONIBLE','be17/doc','Documento de área','application/pdf',10,?,?,now())",doc,patient,encounter,"a".repeat(64),specialist);
        assertEquals("Documento de área",transaction.execute(status->{actorContext.apply(new DatabaseActor(outsider,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select nombre_original from salud_u.obtener_documento_autorizado(?)",String.class,doc);}));
        migratorJdbc.update("with nuevas as (insert into salud_u.cita(id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) select ?,?,'ESPECIALIDAD',?,now(),'ATENDIDA' from generate_series(1,1000) returning id) insert into salud_u.encuentro_clinico(id_cita,id_paciente,id_personal,tipo_encuentro,id_especialidad,estado,motivo_consulta,evaluacion) select id,?,?,'ESPECIALIDAD',?,'CERRADA','Registro sintético de búsqueda','Evaluación de prueba' from nuevas",patient,slot,specialistStaff,patient,specialistStaff,specialty);
        String originalClinical=migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,encounter);
        UUID requestKey=UUID.randomUUID();
        var gate=new CountDownLatch(1);var amendmentIds=new java.util.ArrayList<UUID>();
        try(var pool=Executors.newFixedThreadPool(2)){
            java.util.concurrent.Callable<UUID> create=()->{gate.await();return transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select id from salud_u.agregar_adenda_encuentro(?,?,?,?)",UUID.class,encounter,"Aclaración de registro","Corrección auditable",requestKey);});};
            var a=pool.submit(create);var b=pool.submit(create);gate.countDown();try{amendmentIds.add(a.get(10,TimeUnit.SECONDS));amendmentIds.add(b.get(10,TimeUnit.SECONDS));}catch(Exception exception){throw new AssertionError(exception);}
        }
        assertEquals(amendmentIds.get(0),amendmentIds.get(1));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.adenda_encuentro_clinico where id_encuentro=?",Integer.class,encounter));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='ADENDA_ENCUENTRO_AGREGADA' and id_actor=?",Integer.class,amendmentIds.get(0),specialist));
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));runtimeJdbc.queryForObject("select id from salud_u.agregar_adenda_encuentro(?,?,?,?)",UUID.class,encounter,"Otro motivo","Otro contenido",requestKey);}));
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(outsider,java.util.Set.of("SPECIALIST")));runtimeJdbc.queryForObject("select id from salud_u.agregar_adenda_encuentro(?,?,?,?)",UUID.class,encounter,"Ajeno","Ajeno",UUID.randomUUID());}));
        String peerAmendments=transaction.execute(status->{actorContext.apply(new DatabaseActor(outsider,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select salud_u.obtener_adendas_autorizadas(?)::text",String.class,encounter);});
        assertTrue(peerAmendments.contains("Corrección auditable"));assertTrue(peerAmendments.contains("\"canAdd\": false"));
        assertThrows(IllegalStateException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));runtimeJdbc.queryForObject("select id from salud_u.agregar_adenda_encuentro(?,?,?,?)",UUID.class,encounter,"Rollback","No debe persistir",UUID.randomUUID());throw new IllegalStateException("Fallo posterior");}));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.adenda_encuentro_clinico where id_encuentro=?",Integer.class,encounter));
        assertEquals(originalClinical,migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,encounter));
        assertThrows(DataAccessException.class,()->migratorJdbc.update("update salud_u.adenda_encuentro_clinico set contenido='Alterado' where id=?",amendmentIds.get(0)));
        assertThrows(DataAccessException.class,()->migratorJdbc.update("delete from salud_u.adenda_encuentro_clinico where id=?",amendmentIds.get(0)));
        assertFalse(runtimeJdbc.queryForObject("select has_table_privilege(current_user,'salud_u.adenda_encuentro_clinico','DELETE')",Boolean.class));
        assertEquals(java.util.List.of(encounter),transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForList("select id from salud_u.buscar_historia_autorizada(?,NULL,NULL,?)",UUID.class,patient,"correccion auditable");}));
        assertEquals(Integer.valueOf(2),transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select numero_adenda from salud_u.agregar_adenda_encuentro(?,?,?)",Integer.class,encounter,"Compatibilidad","Adenda del contrato anterior");}));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.adenda_encuentro_clinico where id_encuentro=? and id_solicitud_cliente is null",Integer.class,encounter));
        assertEquals(originalClinical,migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,encounter));
        String exportSnapshot=transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select salud_u.obtener_ficha_exportable(?)::text",String.class,encounter);});
        assertTrue(exportSnapshot.contains("Corrección auditable"));assertTrue(exportSnapshot.contains("Adenda del contrato anterior"));assertTrue(exportSnapshot.contains(template.toString()));assertFalse(exportSnapshot.contains(replacementTemplate.toString()));
        String peerExport=transaction.execute(status->{actorContext.apply(new DatabaseActor(outsider,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForObject("select salud_u.obtener_ficha_exportable(?)::text",String.class,encounter);});
        assertEquals(exportSnapshot,peerExport);
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(studentId,java.util.Set.of("STUDENT")));runtimeJdbc.queryForObject("select salud_u.obtener_ficha_exportable(?)::text",String.class,encounter);}));
        assertEquals(originalClinical,migratorJdbc.queryForObject("select to_jsonb(e)::text from salud_u.encuentro_clinico e where id=?",String.class,encounter));
        var timings=new java.util.ArrayList<Double>();
        for(int i=0;i<10;i++){
            long began=System.nanoTime();
            var found=transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForList("select id from salud_u.buscar_historia_autorizada(?,NULL,NULL,?)",UUID.class,patient,"registro sintetico");});
            assertEquals(1000,found.size());timings.add((System.nanoTime()-began)/1000000.0);
        }
        timings.sort(Double::compareTo);System.out.println("FE18_BENCHMARK syntheticEncounters=1001 samples=10 p95Ms="+timings.get(9));
        var peak=new java.util.ArrayList<Double>();
        try(var workers=Executors.newFixedThreadPool(10)){
            var tasks=new java.util.ArrayList<java.util.concurrent.Future<Double>>();
            for(int i=0;i<20;i++)tasks.add(workers.submit(()->{long began=System.nanoTime();var found=transaction.execute(status->{actorContext.apply(new DatabaseActor(specialist,java.util.Set.of("SPECIALIST")));return runtimeJdbc.queryForList("select id from salud_u.buscar_historia_autorizada(?,NULL,NULL,?)",UUID.class,patient,"registro sintetico");});assertEquals(1000,found.size());return (System.nanoTime()-began)/1000000.0;}));
            for(var task:tasks)try{peak.add(task.get(30,TimeUnit.SECONDS));}catch(Exception exception){throw new AssertionError(exception);}
        }
        peak.sort(Double::compareTo);System.out.println("FE18_PEAK_BENCHMARK syntheticEncounters=1001 concurrency=10 samples=20 p95Ms="+peak.get(18));
    }

    @Test
    void clinicalReportCombinesListsHistoricalSnapshotsAndBoliviaDatesWithRoleScope() throws Exception {
        UUID doctor=UUID.randomUUID(),peer=UUID.randomUUID(),reporter=UUID.randomUUID(),staff=UUID.randomUUID(),peerStaff=UUID.randomUUID(),patient=UUID.randomUUID(),slot=UUID.randomUUID(),background=UUID.randomUUID();
        String seed=UUID.randomUUID().toString().substring(0,8);
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?),(?,?,?),(?,?,?)",doctor,"fe21."+seed+"@example.invalid","Revisión FE21",peer,"fe21.peer."+seed+"@example.invalid","Colega FE21",reporter,"fe21.reports."+seed+"@example.invalid","Reportes FE21");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'MEDICO_REVISION'),(?,'MEDICO_REVISION'),(?,'RESPONSABLE_REPORTES')",doctor,peer,reporter);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?),(?,?,?)",staff,doctor,"FE21-"+seed,peerStaff,peer,"FE21-P-"+seed);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,'Paciente','FE21',?,?)",patient,"FE21-"+seed,"FE21"+seed,"REGFE21"+seed,"REGFE21"+seed,doctor,doctor);
        String data="{\"versionEsquema\":1,\"alergias\":{\"estado\":\"PRESENTE\",\"elementos\":[\"Penicilína\",\"Látex\"]},\"enfermedadesPersonales\":{\"estado\":\"PRESENTE\",\"elementos\":[\"Asma\"]},\"habitos\":{\"tabaco\":\"SI\",\"alcohol\":\"NO\",\"actividadFisica\":\"SI\",\"alimentacion\":\"ADECUADA\"}}";
        migratorJdbc.update("insert into salud_u.version_antecedente_clinico(id,id_paciente,numero_version,datos,registrado_por,motivo_cambio) values (?,?,1,cast(? as jsonb),?,'Semilla FE21')",background,patient,data,doctor);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?,?,now()+interval '600 days',now()+interval '600 days 1 hour',10,'PUBLICADO',now(),?)",slot,staff,doctor);
        var ids=new java.util.ArrayList<UUID>();String[] dates={"2055-01-15T03:59:59Z","2055-01-15T04:00:00Z","2055-01-16T03:59:59Z","2055-01-16T04:00:00Z"};
        for(int i=0;i<4;i++){UUID appointment=UUID.randomUUID(),encounter=UUID.randomUUID();ids.add(encounter);
            migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) values (?,?,?,'INICIAL',?,now(),'ATENDIDA')",appointment,patient,slot,i==3?peerStaff:staff);
            migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado,cerrado_en,motivo_consulta,evaluacion,seguimiento,id_version_antecedente_clinico) values (?,?,?,?,'INICIAL','CERRADA',cast(? as timestamptz),'Síntoma FE21','Evaluación FE21','Seguimiento exclusivo FE21',?)",encounter,appointment,patient,i==3?peerStaff:staff,dates[i],background);
            migratorJdbc.update("insert into salud_u.diagnostico_encuentro(id_encuentro,texto_libre,creado_por) values (?,'Diagnóstico Ácido FE21',?)",encounter,doctor);
        }
        var filters=Map.of("from","2055-01-15","to","2055-01-15","allergies",java.util.List.of("  penicilina  ","latex"),"histories",java.util.List.of("ASMA"),"positiveHabits",java.util.List.of("tobacco","physicalActivity"),"habitTerms",java.util.List.of("alimentacion: adecuada"),"diagnosis","acido","search","seguimiento exclusivo");
        var objectMapper=new ObjectMapper();String query=objectMapper.writeValueAsString(filters);
        var rows=transaction.execute(status->{actorContext.apply(new DatabaseActor(doctor,java.util.Set.of("REVIEW_DOCTOR")));return runtimeJdbc.queryForList("select * from salud_u.reporte_clinico_detallado(cast(? as jsonb))",query);});
        assertEquals(java.util.List.of(ids.get(2),ids.get(1)),rows.stream().map(r->r.get("id_encuentro")).toList());assertEquals("Penicilína · Látex",rows.getFirst().get("alergias"));assertTrue(rows.getFirst().get("resumen_antecedentes").toString().contains("Antecedentes personales: Asma"));assertEquals(null,rows.getFirst().get("ficha_especialidad"));
        String global="{\"from\":\"2055-01-14\",\"to\":\"2055-01-17\"}";
        assertEquals(4,transaction.<Integer>execute(status->{actorContext.apply(new DatabaseActor(reporter,java.util.Set.of("REPORTING_OFFICER")));return runtimeJdbc.queryForList("select * from salud_u.reporte_clinico_detallado(cast(? as jsonb))",global).size();}));
        assertEquals(1,transaction.<Integer>execute(status->{actorContext.apply(new DatabaseActor(peer,java.util.Set.of("REVIEW_DOCTOR")));return runtimeJdbc.queryForList("select * from salud_u.reporte_clinico_detallado(cast(? as jsonb))",global).size();}));
        assertEquals(0,transaction.<Integer>execute(status->{actorContext.apply(new DatabaseActor(doctor,java.util.Set.of("REVIEW_DOCTOR")));return runtimeJdbc.queryForList("select * from salud_u.reporte_clinico_detallado(cast(? as jsonb))",query.replace("latex","inexistente")).size();}));
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(studentId,java.util.Set.of("STUDENT")));runtimeJdbc.queryForList("select * from salud_u.reporte_clinico_detallado(cast(? as jsonb))",global);}));
        assertEquals(2,transaction.<Integer>execute(status->{actorContext.apply(new DatabaseActor(doctor,java.util.Set.of("REVIEW_DOCTOR")));return runtimeJdbc.queryForList("select * from salud_u.reporte_clinico(cast(? as jsonb))",query).size();}));
        var request=bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportRequest.parse(Map.of("format","CSV","purpose","Ensayo FE22","filters",filters,"columns",java.util.List.of("patient_name","diagnoses")),objectMapper);
        var history=new bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportHistory(runtimeJdbc,objectMapper,actorContext);
        var service=new bo.edu.uagrm.saludu.agenda.application.ClinicalReportExportService(runtimeJdbc,objectMapper,actorContext,new bo.edu.uagrm.saludu.agenda.application.ClinicalReportFiles(objectMapper),history);
        var principal=new SessionPrincipal(doctor,"fe22@example.invalid","Revisión FE22",java.util.List.of("REVIEW_DOCTOR"));
        var file=transaction.execute(status->{try{return service.export(request,principal);}catch(java.io.IOException exception){throw new AssertionError(exception);}});
        assertEquals(2,file.rowCount());assertEquals(64,file.sha256().length());assertEquals(doctor,migratorJdbc.queryForObject("select id_solicitante from salud_u.exportacion_reporte_clinico where id=?",UUID.class,file.id()));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='REPORTE_CLINICO_EXPORTADO'",Integer.class,file.id()));
        String receipt=transaction.execute(status->{actorContext.apply(new DatabaseActor(doctor,java.util.Set.of("REVIEW_DOCTOR")));return runtimeJdbc.queryForObject("select salud_u.obtener_exportacion_reporte(?)::text",String.class,file.id());});assertTrue(receipt.contains("COMPLETED"));assertTrue(receipt.contains("penicilina"));
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(peer,java.util.Set.of("REVIEW_DOCTOR")));runtimeJdbc.queryForObject("select salud_u.obtener_exportacion_reporte(?)::text",String.class,file.id());}));
        assertFalse(runtimeJdbc.queryForObject("select has_table_privilege(current_user,'salud_u.exportacion_reporte_clinico','SELECT')",Boolean.class));
        assertThrows(IllegalStateException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(doctor,java.util.Set.of("REVIEW_DOCTOR")));history.record(request,"COMPLETED",2,"a".repeat(64));throw new IllegalStateException("Rollback FE22");}));
        assertEquals(1,migratorJdbc.queryForObject("select count(*) from salud_u.exportacion_reporte_clinico where id_solicitante=?",Integer.class,doctor));

    }

    @Test
    void institutionalComplianceCountsOnlyClosedEncountersInsideAcademicEnrollment() {
        UUID clinician = UUID.randomUUID(), staff = UUID.randomUUID(), reporting = UUID.randomUUID();
        UUID compliant = UUID.randomUUID(), checkedIn = UUID.randomUUID(), absent = UUID.randomUUID();
        UUID slot = UUID.randomUUID(), closedAppointment = UUID.randomUUID(), checkedInAppointment = UUID.randomUUID(), absentAppointment = UUID.randomUUID(), closedEncounter = UUID.randomUUID(), draftEncounter = UUID.randomUUID();
        String period = "BE23-" + UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?),(?,?,?)", clinician,"be23-clinician@example.invalid","Clínico BE-23",reporting,"be23-reports@example.invalid","Reportes BE-23");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'MEDICO_REVISION'),(?,'RESPONSABLE_REPORTES')", clinician,reporting);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", staff,clinician,"BE23-STAFF");
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, 'BE23-C','BE23C','REG-BE23-C','REGBE23C','Cerrado','Cumple',?,?),(?, 'BE23-I','BE23I','REG-BE23-I','REGBE23I','Llegada','Pendiente',?,?),(?, 'BE23-A','BE23A','REG-BE23-A','REGBE23A','Ausencia','Pendiente',?,?)", compliant,clinician,clinician,checkedIn,clinician,clinician,absent,clinician,clinician);
        migratorJdbc.update("insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) values (?, ?, ?, current_date - 1, 'ACTIVA'), (?, ?, ?, current_date - 1, 'ACTIVA'), (?, ?, ?, current_date - 1, 'ACTIVA')", compliant,patientCareerId,period,checkedIn,patientCareerId,period,absent,patientCareerId,period);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now(), now()+interval '30 minutes',3,'PUBLICADO',now(),?)", slot,staff,clinician);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para,estado) values (?, ?, ?, 'INICIAL', ?, now(), 'ATENDIDA'), (?, ?, ?, 'INICIAL', ?, now(), 'LLEGADA'), (?, ?, ?, 'INICIAL', ?, now(), 'AUSENTE')", closedAppointment,compliant,slot,staff,checkedInAppointment,checkedIn,slot,staff,absentAppointment,absent,slot,staff);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado,cerrado_en) values (?, ?, ?, ?, 'INICIAL','CERRADA',now()), (?, ?, ?, ?, 'INICIAL','BORRADOR',null)", closedEncounter,closedAppointment,compliant,staff,draftEncounter,checkedInAppointment,checkedIn,staff);

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
        migratorJdbc.update("update salud_u.inscripcion_academica set iniciado_en='2026-10-26',finalizado_en='2026-10-26',estado='INACTIVA' where id_paciente=?",compliant);
        migratorJdbc.update("update salud_u.encuentro_clinico set cerrado_en='2026-10-27T03:59:59Z' where id=?",closedEncounter);
        var boundary=transaction.execute(status->{actorContext.apply(new DatabaseActor(reporting,java.util.Set.of("REPORTING_OFFICER")));return runtimeJdbc.queryForList("select * from salud_u.reporte_cumplimiento_institucional(?,?)",patientCareerId,period);});
        assertEquals("COMPLIANT",boundary.stream().filter(row->compliant.equals(row.get("id_paciente"))).findFirst().orElseThrow().get("estado_cumplimiento"));
        migratorJdbc.update("update salud_u.encuentro_clinico set cerrado_en='2026-10-27T04:00:00Z' where id=?",closedEncounter);
        var outside=transaction.execute(status->{actorContext.apply(new DatabaseActor(reporting,java.util.Set.of("REPORTING_OFFICER")));return runtimeJdbc.queryForList("select * from salud_u.reporte_cumplimiento_institucional(?,?)",patientCareerId,period);});
        assertEquals("PENDING",outside.stream().filter(row->compliant.equals(row.get("id_paciente"))).findFirst().orElseThrow().get("estado_cumplimiento"));
        var summary=transaction.execute(status->{actorContext.apply(new DatabaseActor(administratorId,java.util.Set.of("ADMINISTRATIVE")));return runtimeJdbc.queryForObject("select salud_u.resumen_administrativo()::text",String.class);});assertTrue(summary.contains("closedToday"));assertFalse(summary.contains("evaluacion"));
        assertThrows(DataAccessException.class,()->transaction.executeWithoutResult(status->{actorContext.apply(new DatabaseActor(reporting,java.util.Set.of("REPORTING_OFFICER")));runtimeJdbc.queryForObject("select salud_u.resumen_administrativo()::text",String.class);}));

        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(clinician, java.util.Set.of("REVIEW_DOCTOR"))); runtimeJdbc.queryForList("select * from salud_u.reporte_cumplimiento_institucional(?, ?)", patientCareerId, period); }));
    }

    @Test
    void spanishAuditCodesNormalizeHistoricalReadsAndFiltersWithoutChangingStoredEvidence() {
        UUID actor = UUID.randomUUID(), resource = UUID.randomUUID(), historical = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Actor ES08')", actor, "es08-" + actor + "@example.invalid");
        migratorJdbc.update("insert into salud_u.evento_auditoria(id,id_actor,accion,tipo_recurso,id_recurso,resultado,detalles) values (?,?,'PATIENT_CREATED','patient',?,'EXITO','{}')", historical, actor, resource);
        for (var outcome : AuditOutcome.values()) {
            UUID id = transaction.execute(status -> {
                actorContext.apply(new DatabaseActor(actor, java.util.Set.of("ADMINISTRATIVE")));
                return auditWriter.append("PACIENTE_CREADO", "paciente", resource, outcome, Map.of());
            });
            String stored = switch (outcome) { case SUCCESS -> "EXITO"; case DENIED -> "DENEGADO"; case FAILURE -> "FALLO"; };
            assertEquals(stored, migratorJdbc.queryForObject("select resultado::text from salud_u.evento_auditoria where id=?", String.class, id));
        }
        for (String action : java.util.List.of("PATIENT_CREATED", "PACIENTE_CREADO", "PATIENT_", "PACIENTE_")) {
            for (String kind : java.util.List.of("patient", "paciente")) {
                var rows = transaction.execute(status -> {
                    actorContext.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
                    return runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria(null,null,?,?,?,null,100)", actor, action, kind);
                });
                assertEquals(4, rows.size(), action + "/" + kind);
                assertTrue(rows.stream().allMatch(row -> "PACIENTE_CREADO".equals(row.get("accion")) && "paciente".equals(row.get("tipo_recurso"))));
                assertEquals(java.util.Set.of("SUCCESS", "DENIED", "FAILURE"), rows.stream().map(row -> row.get("resultado")).collect(java.util.stream.Collectors.toSet()));
            }
        }
        for (var outcome : AuditOutcome.values()) {
            var rows = transaction.execute(status -> {
                actorContext.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
                return runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria(null,null,?,null,null,?,100)", actor, outcome.name());
            });
            assertEquals(outcome == AuditOutcome.SUCCESS ? 2 : 1, rows.size());
        }
        assertEquals("PATIENT_CREATED/patient", migratorJdbc.queryForObject("select accion||'/'||tipo_recurso from salud_u.evento_auditoria where id=?", String.class, historical));
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update("update salud_u.evento_auditoria set accion='CAMBIADO' where id=?", historical));
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update("delete from salud_u.evento_auditoria where id=?", historical));
        assertThrows(DataAccessException.class, () -> runtimeJdbc.queryForList("select * from salud_u.equivalencia_codigo_auditoria"));
        assertThrows(DataAccessException.class, () -> runtimeJdbc.update("insert into salud_u.equivalencia_codigo_auditoria values ('X','Y')"));
        UUID unknown = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(actor, java.util.Set.of("ADMINISTRATIVE")));
            return auditWriter.append("ACCION_PROPIA_ES08", "recurso_propio", resource, AuditOutcome.SUCCESS, Map.of());
        });
        var unchanged = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(auditorId, java.util.Set.of("AUDITOR")));
            return runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria(null,null,?,'ACCION_PROPIA_ES08','recurso_propio',null,100)", actor);
        });
        assertEquals(unknown, unchanged.getFirst().get("id"));
        assertEquals("ACCION_PROPIA_ES08", unchanged.getFirst().get("accion"));
    }

    @Test
    void failedReportExportStoresSpanishStateAndOutcomeWhileReceiptKeepsApiCode() throws Exception {
        UUID id = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.registrar_exportacion_reporte('Prueba ES08','{}','[]','[]','CSV','FAILED',0,null)", UUID.class);
        });
        assertEquals("FALLIDA", migratorJdbc.queryForObject("select estado from salud_u.exportacion_reporte_clinico where id=?", String.class, id));
        assertEquals("EXPORTACION_REPORTE_CLINICO_FALLIDA/FALLO", migratorJdbc.queryForObject("select accion||'/'||resultado::text from salud_u.evento_auditoria where id_recurso=?", String.class, id));
        String receipt = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.obtener_exportacion_reporte(?)::text", String.class, id);
        });
        assertEquals("FAILED", new ObjectMapper().readTree(receipt).path("state").asText());
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject("select salud_u.registrar_exportacion_reporte('Prueba ES08','{}','[]','[]','CSV','COMPLETED',0,null)", UUID.class);
        }));
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
        assertTrue(events.stream().anyMatch(event -> clinicianId.equals(event.get("id_actor")) && resourceId.equals(event.get("id_recurso")) && "HISTORIA_CLINICA_CONSULTADA".equals(event.get("accion"))));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria(null, null, null, null, null, null, 100)");
        }));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(clinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            auditWriter.append("UNSAFE", "patient", resourceId, AuditOutcome.SUCCESS, Map.of("token", "never-store-this"));
        }));
        UUID boundary=UUID.randomUUID();migratorJdbc.update("insert into salud_u.evento_auditoria(id,ocurrido_en,id_actor,accion,tipo_recurso,resultado,detalles) values (?,'2026-10-26T03:59:59Z',?,'FE24_BOUNDARY','audit_fixture','EXITO','{}')",boundary,clinicianId);
        var dated=transaction.execute(status->{actorContext.apply(new DatabaseActor(auditorId,java.util.Set.of("AUDITOR")));return runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria_paginados(?,?,?,?,?,?,?,?,?,?)",LocalDate.parse("2026-10-25"),LocalDate.parse("2026-10-25"),clinicianId,"FE24_BOUNDARY",null,null,100,null,null,null);});assertEquals(java.util.List.of(boundary),dated.stream().map(r->r.get("id")).toList());
        var next=transaction.execute(status->{actorContext.apply(new DatabaseActor(auditorId,java.util.Set.of("AUDITOR")));return runtimeJdbc.queryForList("select * from salud_u.listar_eventos_auditoria_paginados(?,?,?,?,?,?,?,?,?,?)",(Object)null,null,clinicianId,"FE24_BOUNDARY",null,null,100,java.time.OffsetDateTime.parse("2026-10-26T03:59:59Z"),boundary,null);});assertTrue(next.isEmpty());
        assertFalse(runtimeJdbc.queryForObject("select has_table_privilege(current_user,'salud_u.evento_auditoria','UPDATE')",Boolean.class));assertFalse(runtimeJdbc.queryForObject("select has_table_privilege(current_user,'salud_u.evento_auditoria','DELETE')",Boolean.class));
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
    void staleVaccineFormCannotReplaceNewerScheduleAndDuplicateCodeIsDistinguished() {
        String code = "FE25-" + UUID.randomUUID().toString().substring(0, 8), oneDose = "[{\"doseNumber\":1,\"minimumIntervalDays\":0}]";
        String save = "select salud_u.guardar_vacuna_y_esquema(?, ?, ?, ?, cast(? as jsonb), ?)";
        UUID vaccineId = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject(save, UUID.class, null, code, "Vacuna FE-25", true, oneDose, null);
        });
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject(save, UUID.class, vaccineId, code, "Vacuna FE-25 v2", true, oneDose, 1);
        });
        DataAccessException stale = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject(save, UUID.class, vaccineId, code, "Formulario antiguo", false, oneDose, 1);
        }));
        assertTrue(stale.getMostSpecificCause().getMessage().contains("VACUNA_VERSION_DESACTUALIZADA"));
        assertEquals("Vacuna FE-25 v2", migratorJdbc.queryForObject("select nombre from salud_u.vacuna where id=?", String.class, vaccineId));
        assertEquals(2, migratorJdbc.queryForObject("select count(*) from salud_u.esquema_vacuna where id_vacuna=?", Integer.class, vaccineId));
        DataAccessException duplicate = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject(save, UUID.class, null, code.toLowerCase(), "Duplicada", true, oneDose, null);
        }));
        assertTrue(duplicate.getMostSpecificCause().getMessage().contains("VACUNA_CODIGO_DUPLICADO"));
        DataAccessException missing = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            runtimeJdbc.queryForObject(save, UUID.class, UUID.randomUUID(), code + "X", "Inexistente", true, oneDose, 1);
        }));
        assertTrue(missing.getMostSpecificCause().getMessage().contains("VACUNA_NO_ENCONTRADA"));
    }

    @Test
    void reviewDoctorRegistersDosesOnlyForOwnPatientsAndContextShowsResponsiblePeople() throws Exception {
        UUID own = UUID.randomUUID(), foreign = UUID.randomUUID();
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, ?, ?, ?, ?, 'Paciente', 'Propio', ?, ?),(?, ?, ?, ?, ?, 'Paciente', 'Ajeno', ?, ?)", own, "VO-" + suffix, "VO" + suffix, "REG-VO-" + suffix, "REGVO" + suffix, administratorId, administratorId, foreign, "VF-" + suffix, "VF" + suffix, "REG-VF-" + suffix, "REGVF" + suffix, administratorId, administratorId);
        assignInitialAppointment(own, availabilityStaffId);
        UUID vaccine = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(null, ?, ?, true, cast(? as jsonb))", UUID.class, "VD-" + suffix, "Vacuna FE-26", "[{\"doseNumber\":1,\"minimumIntervalDays\":0},{\"doseNumber\":2,\"minimumIntervalDays\":28}]");
        });
        DataAccessException foreignDose = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 1, ?, 'L-F', null, null)", UUID.class, foreign, vaccine, LocalDate.now());
        }));
        assertTrue(foreignDose.getMostSpecificCause().getMessage().contains("PACIENTE_AJENO_O_INEXISTENTE"));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select salud_u.contexto_registro_vacunacion(?)::text", String.class, foreign);
        }));
        DataAccessException future = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 1, (now() at time zone 'America/La_Paz')::date + 1, 'L-1', null, null)", UUID.class, own, vaccine);
        }));
        assertTrue(future.getMostSpecificCause().getMessage().contains("FECHA_DOSIS_FUTURA"));
        transaction.executeWithoutResult(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            runtimeJdbc.queryForObject("select id from salud_u.registrar_dosis_vacuna(?, ?, 1, (now() at time zone 'America/La_Paz')::date - 3, ' L-1 ', null, null)", UUID.class, own, vaccine);
        });
        String doctorView = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(availabilityClinicianId, java.util.Set.of("REVIEW_DOCTOR")));
            return runtimeJdbc.queryForObject("select salud_u.contexto_registro_vacunacion(?)::text", String.class, own);
        });
        String adminView = transaction.execute(status -> {
            actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE")));
            return runtimeJdbc.queryForObject("select salud_u.contexto_registro_vacunacion(?)::text", String.class, own);
        });
        var reader = new com.fasterxml.jackson.databind.ObjectMapper();
        var doctorContext = reader.readTree(doctorView);
        assertEquals(availabilityStaffId.toString(), doctorContext.get("ownApplicatorStaffId").asText());
        assertEquals(1, doctorContext.get("applicators").size());
        var vaccineView = java.util.stream.StreamSupport.stream(doctorContext.get("vaccines").spliterator(), false).filter(v -> v.get("vaccineId").asText().equals(vaccine.toString())).findFirst().orElseThrow();
        assertEquals(2, vaccineView.get("nextDoseNumber").asInt());
        var applied = vaccineView.get("appliedDoses").get(0);
        assertEquals("L-1", applied.get("lot").asText());
        assertEquals(availabilityStaffId.toString(), applied.get("applicator").get("staffId").asText());
        assertEquals(availabilityClinicianId.toString(), applied.get("registeredBy").get("id").asText());
        assertTrue(applied.get("intervalJustification").isNull());
        assertTrue(reader.readTree(adminView).get("ownApplicatorStaffId").isNull());
        assertTrue(reader.readTree(adminView).get("applicators").size() >= 1);
        assertEquals(2, migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where accion='REGISTRO_VACUNACION_CONSULTADO' and id_recurso=?", Integer.class, own));
    }

    @Test
    void medicalAgendaKeepsActiveAppointmentsBeyondTwoHundredAndGetsOneById() {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID doctor = UUID.randomUUID(), staff = UUID.randomUUID(), patient = UUID.randomUUID(), upcoming = UUID.randomUUID(), upcomingSlot = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,'Médico con agenda larga')", doctor, "agenda-" + suffix + "@example.invalid");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'MEDICO_REVISION')", doctor);
        migratorJdbc.update("insert into salud_u.personal(id,id_principal,codigo_personal) values (?,?,?)", staff, doctor, "AGENDA-" + suffix);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?,?,?,?,'Paciente','Agenda',?,?)", patient, "AG-" + suffix, "AG" + suffix, "REG-AG-" + suffix, "REGAG" + suffix, administratorId, administratorId);
        // 205 citas atendidas anteriores ocupan más que el antiguo tope de 200.
        migratorJdbc.update("with cupos as (insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por) select gen_random_uuid(),?,now()-make_interval(days=>n+1),now()-make_interval(days=>n+1)+interval '30 minutes',1,1,'CERRADO',now()-make_interval(days=>n+2),? from generate_series(1,205) n returning id,inicia_a) insert into salud_u.cita(id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para) select ?,id,'INICIAL','ATENDIDA',?,inicia_a from cupos", staff, administratorId, patient, staff);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,cantidad_reservada,estado,publicado_en,creado_por) values (?,?,now()+interval '400 days',now()+interval '400 days 30 minutes',1,1,'PUBLICADO',now(),?)", upcomingSlot, staff, administratorId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,id_personal_asignado,programada_para) values (?,?,?,'INICIAL',?,now()+interval '400 days')", upcoming, patient, upcomingSlot, staff);
        UUID oldest = migratorJdbc.queryForObject("select id from salud_u.cita where id_personal_asignado=? order by programada_para asc limit 1", UUID.class, staff);
        var principal = new SessionPrincipal(doctor, "agenda-" + suffix + "@example.invalid", "Médico", java.util.List.of("REVIEW_DOCTOR"));
        var controller = new bo.edu.uagrm.saludu.agenda.api.MedicalAppointmentController(runtimeJdbc, actorContext, auditWriter);
        var agenda = transaction.execute(status -> controller.list(principal).data());
        assertEquals(201, agenda.size());
        assertEquals(upcoming, agenda.get(agenda.size() - 1).get("id"));
        assertFalse(agenda.stream().anyMatch(item -> oldest.equals(item.get("id"))));
        assertEquals(oldest, transaction.execute(status -> controller.get(oldest, principal).data().get("id")));
        var outsider = new SessionPrincipal(availabilityClinicianId, "availability-doctor@example.invalid", "Médico", java.util.List.of("REVIEW_DOCTOR"));
        var missing = assertThrows(bo.edu.uagrm.saludu.agenda.application.AvailabilityException.class, () -> transaction.execute(status -> controller.get(upcoming, outsider)));
        assertTrue(missing.getMessage().contains("No se encontró"));
    }

    private void assignInitialAppointment(UUID patient, UUID staff) {
        UUID slot = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id, id_personal, inicia_a, termina_a, capacidad, estado, publicado_en, creado_por) values (?, ?, now() + interval '3 days', now() + interval '3 days 30 minutes', 1, 'PUBLICADO', now(), ?)", slot, staff, administratorId);
        migratorJdbc.update("insert into salud_u.cita(id, id_paciente, id_cupo, tipo_cita, id_personal_asignado, programada_para) values (?, ?, ?, 'INICIAL', ?, now() + interval '3 days')", UUID.randomUUID(), patient, slot, staff);
    }

    @Test
    void vaccinationDosePreservesResponsiblePeopleAndRejectsInvalidOrConcurrentDuplicates() throws Exception {
        UUID patient = UUID.randomUUID();
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?, ?, ?, ?, ?, 'Paciente', 'Vacunación', ?, ?)", patient, "VAC-" + suffix, "VAC" + suffix, "REG-VAC-" + suffix, "REGVAC" + suffix, administratorId, administratorId);
        assignInitialAppointment(patient, availabilityStaffId);
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
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?),(?,?,?)", student, "be27-student-" + suffix + "@example.invalid", "Estudiante BE-27", reporter, "be27-report-" + suffix + "@example.invalid", "Reportes BE-27");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'ESTUDIANTE'),(?,'RESPONSABLE_REPORTES')", student, reporter);
        migratorJdbc.update("insert into salud_u.paciente(id,id_principal,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,creado_por,actualizado_por) values (?,?, ?, ?, ?, ?, 'Estudiante','Vacunado',?,?),(?,null, ?, ?, ?, ?, 'Estudiante','Pendiente',?,?)", patient, student, "VC-" + suffix, "VC" + suffix, "REG-VC-" + suffix, "REGVC" + suffix, administratorId, administratorId, pendingPatient, "VP-" + suffix, "VP" + suffix, "REG-VP-" + suffix, "REGVP" + suffix, administratorId, administratorId);
        migratorJdbc.update("insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) values (?, ?, ?, current_date, 'ACTIVA'), (?, ?, ?, current_date, 'ACTIVA')", patient, patientCareerId, period, pendingPatient, patientCareerId, period);
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
        assertTrue(ownCard.contains("CARD-1"));
        UUID unused = transaction.execute(status -> { actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE"))); return runtimeJdbc.queryForObject("select salud_u.guardar_vacuna_y_esquema(null, ?, ?, false, cast(? as jsonb))", UUID.class, "VU-" + suffix, "Vacuna retirada sin dosis", "[{\"doseNumber\":1,\"minimumIntervalDays\":0}]"); });
        String adminCard = transaction.execute(status -> { actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE"))); return runtimeJdbc.queryForObject("select salud_u.obtener_carnet_vacunacion(?)::text", String.class, patient); });
        assertTrue(adminCard.contains("CARD-1") && adminCard.contains("applicatorName"));
        assertFalse(adminCard.contains(unused.toString()));
        DataAccessException missing = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE"))); runtimeJdbc.queryForObject("select salud_u.obtener_carnet_vacunacion(null)::text", String.class); }));
        assertTrue(missing.getMostSpecificCause().getMessage().contains("PACIENTE_REQUERIDO"));
        assertEquals(2, migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where accion='CARNET_VACUNACION_CONSULTADO' and id_recurso=?", Integer.class, patient));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where accion='COBERTURA_VACUNACION_CONSULTADA' and id_actor=?", Integer.class, reporter));
    }

    @Test
    void researchDatasetIsPseudonymizedAuditedAndRestricted() {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID reporter = UUID.randomUUID(), patient = UUID.randomUUID(), slot = UUID.randomUUID(), appointment = UUID.randomUUID(), encounter = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.principal(id,correo,nombre_mostrado) values (?,?,?)", reporter, "research-" + suffix + "@example.invalid", "Reportes investigación");
        migratorJdbc.update("insert into salud_u.rol_principal(id_principal,codigo_rol) values (?,'RESPONSABLE_REPORTES')", reporter);
        migratorJdbc.update("insert into salud_u.paciente(id,carnet,carnet_normalizado,codigo_registro,codigo_registro_normalizado,nombres,apellidos,fecha_nacimiento,creado_por,actualizado_por) values (?, 'CARNET-SECRETO', 'CARNETSECRETO" + suffix + "', 'REGISTRO-SECRETO', 'REGISTROSECRETO" + suffix + "', 'Nombre Reservado', 'Apellido Reservado', current_date - interval '22 years', ?, ?)", patient, administratorId, administratorId);
        migratorJdbc.update("insert into salud_u.inscripcion_academica(id_paciente,id_carrera,periodo_academico,iniciado_en,estado) values (?, ?, '2026-II', current_date - 1, 'ACTIVA')", patient, patientCareerId);
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, now()-interval '2 days', now()-interval '2 days'+interval '30 minutes', 1, 'CERRADO', now()-interval '3 days', ?)", slot, availabilityStaffId, availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para) values (?, ?, ?, 'INICIAL', 'ATENDIDA', ?, now()-interval '2 days')", appointment, patient, slot, availabilityStaffId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado,cerrado_en,cerrado_por) values (?, ?, ?, ?, 'INICIAL', 'CERRADA', now()-interval '2 days', ?)", encounter, appointment, patient, availabilityStaffId, availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.diagnostico_encuentro(id_encuentro,texto_libre,creado_por) values (?, 'Nombre Reservado no debe salir', ?)", encounter, availabilityClinicianId);
        var first = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))", "{}"); });
        var second = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))", "{}"); });
        Map<String, Object> row = first.stream().filter(value -> "INITIAL".equals(value.get("tipo_encuentro"))).findFirst().orElseThrow();
        assertTrue(((String) row.get("seudonimo")).matches("R-[A-F0-9]{20}"));
        assertEquals(row.get("seudonimo"), second.stream().filter(value -> "INITIAL".equals(value.get("tipo_encuentro"))).findFirst().orElseThrow().get("seudonimo"));
        String serialized = row.toString();
        assertFalse(serialized.contains("CARNET-SECRETO") || serialized.contains("REGISTRO-SECRETO") || serialized.contains("Nombre Reservado") || serialized.contains("Apellido Reservado"));
        UUID export = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForObject("select salud_u.registrar_exportacion_investigacion(?, cast(? as jsonb), 'CSV', ?, ?)", UUID.class, "Análisis epidemiológico institucional", "{\"careerId\":\"" + patientCareerId + "\"}", first.size(), "a".repeat(64)); });
        assertEquals(reporter, migratorJdbc.queryForObject("select id_solicitante from salud_u.exportacion_investigacion where id=?", UUID.class, export));
        assertEquals(1, migratorJdbc.queryForObject("select count(*) from salud_u.evento_auditoria where id_recurso=? and accion='EXPORTACION_INVESTIGACION_COMPLETADA' and detalles->>'purpose'='Análisis epidemiológico institucional' and detalles->'filterFields'='[\"careerId\"]'::jsonb", Integer.class, export));
        var provenance = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForObject("select salud_u.obtener_exportacion_investigacion(?)::text", String.class, export); });
        assertTrue(provenance.contains("\"purpose\": \"Análisis epidemiológico institucional\"") && provenance.contains("\"policyVersion\": \"MONTHLY-V1\"") && provenance.contains("\"sha256\": \"" + "a".repeat(64)));
        assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(administratorId, java.util.Set.of("ADMINISTRATIVE"))); runtimeJdbc.queryForObject("select salud_u.obtener_exportacion_investigacion(?)::text", String.class, export); }));
        for (String invalid : java.util.List.of("{\"patientId\":\"x\"}", "{\"from\":\"2026-02-30\"}", "{\"from\":\"2026-10-02\",\"to\":\"2026-10-01\"}", "{\"careerId\":\"no-uuid\"}", "{\"from\":20261001}")) {
            var failure = assertThrows(DataAccessException.class, () -> transaction.executeWithoutResult(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); runtimeJdbc.queryForList("select * from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb))", invalid); }));
            assertTrue(failure.getMostSpecificCause().getMessage().contains("FILTROS_INVESTIGACION_INVALIDOS"), invalid);
        }
        // 2026-09-01 02:00 UTC es todavía 31 de agosto en Bolivia: mes y filtros usan el día local.
        UUID lateSlot = UUID.randomUUID(), lateAppointment = UUID.randomUUID(), lateEncounter = UUID.randomUUID();
        migratorJdbc.update("insert into salud_u.cupo_disponibilidad(id,id_personal,inicia_a,termina_a,capacidad,estado,publicado_en,creado_por) values (?, ?, timestamptz '2026-08-31 20:00:00+00', timestamptz '2026-08-31 20:30:00+00', 1, 'CERRADO', timestamptz '2026-08-30 12:00:00+00', ?)", lateSlot, availabilityStaffId, availabilityClinicianId);
        migratorJdbc.update("insert into salud_u.cita(id,id_paciente,id_cupo,tipo_cita,estado,id_personal_asignado,programada_para) values (?, ?, ?, 'INICIAL', 'ATENDIDA', ?, timestamptz '2026-08-31 20:00:00+00')", lateAppointment, patient, lateSlot, availabilityStaffId);
        migratorJdbc.update("insert into salud_u.encuentro_clinico(id,id_cita,id_paciente,id_personal,tipo_encuentro,estado,cerrado_en,cerrado_por) values (?, ?, ?, ?, 'INICIAL', 'CERRADA', timestamptz '2026-09-01 02:00:00+00', ?)", lateEncounter, lateAppointment, patient, availabilityStaffId, availabilityClinicianId);
        var august = transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select mes_atencion::text as mes from salud_u.conjunto_investigacion_seudonimizado(cast(? as jsonb)) where seudonimo = ?", "{\"from\":\"2026-08-31\",\"to\":\"2026-08-31\"}", row.get("seudonimo")); });
        assertEquals(java.util.List.of(Map.of("mes", "2026-08-01")), august);
        assertFalse(transaction.execute(status -> { actorContext.apply(new DatabaseActor(reporter, java.util.Set.of("REPORTING_OFFICER"))); return runtimeJdbc.queryForList("select * from salud_u.listar_vacunas(true)"); }) == null);
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

    private static HikariDataSource migratorDataSource() {
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

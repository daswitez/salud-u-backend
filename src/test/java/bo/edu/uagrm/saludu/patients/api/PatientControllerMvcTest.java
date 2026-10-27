package bo.edu.uagrm.saludu.patients.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.patients.application.DuplicatePatientIdentifierException;
import bo.edu.uagrm.saludu.patients.application.EmergencyContact;
import bo.edu.uagrm.saludu.patients.application.PatientDetail;
import bo.edu.uagrm.saludu.patients.application.PatientService;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.patients.application.PatientSummary;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(PatientController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class PatientControllerMvcTest {
    private static final UUID ADMIN_ID = UUID.fromString("00000000-0000-4000-8000-000000000010");
    private static final UUID PATIENT_ID = UUID.fromString("00000000-0000-4000-8000-000000000020");
    private static final UUID CAREER_ID = UUID.fromString("00000000-0000-4000-8000-000000000030");

    @Autowired MockMvc mvc;
    @MockBean PatientService patientService;
    @MockBean bo.edu.uagrm.saludu.patients.application.ConsentService consentService;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void administrativeListPreservesLegacyPatientFieldsAndOrder() throws Exception {
        when(patientService.list(eq(administrator()), eq("mer"))).thenReturn(List.of(summary()));

        mvc.perform(get("/api/patients").param("query", "mer").with(authentication(adminAuthentication())))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data[0].id").value(PATIENT_ID.toString()))
            .andExpect(jsonPath("$.data[0].registrationCode").value("REG-001"))
            .andExpect(jsonPath("$.data[0].career.name").value("Medicina"))
            .andExpect(jsonPath("$.data[0].enrollment.academicPeriod").value("2026-II"));
    }

    @Test
    void sexIsOptionalValidatedAndKeptWhenAnUpdateOmitsIt() throws Exception {
        when(patientService.create(eq(administrator()), any(), any())).thenReturn(PATIENT_ID);
        when(patientService.get(eq(administrator()), eq(PATIENT_ID))).thenReturn(java.util.Optional.of(summary()));
        when(patientService.detail(eq(administrator()), eq(PATIENT_ID))).thenReturn(java.util.Optional.of(new PatientDetail(summary(), null)));
        when(patientService.update(eq(administrator()), eq(PATIENT_ID), any(), any())).thenReturn(PATIENT_ID);
        var commands = org.mockito.ArgumentCaptor.forClass(PatientService.PatientCommand.class);

        mvc.perform(get("/api/patients/" + PATIENT_ID).with(authentication(adminAuthentication())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.sex").value("FEMALE"));
        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(createBody().replace("}", ",\"sex\":\"MALE\"}")))
            .andExpect(status().isCreated());
        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(createBody()))
            .andExpect(status().isCreated());
        verify(patientService, org.mockito.Mockito.times(2)).create(eq(administrator()), commands.capture(), any());
        assertEquals("MALE", commands.getAllValues().get(0).sex());
        assertNull(commands.getAllValues().get(1).sex(), "Sin sex, el paciente queda sin registrar");

        for (String invalid : List.of("F", "female", "OTHER"))
            mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
                    .contentType(MediaType.APPLICATION_JSON).content(createBody().replace("}", ",\"sex\":\"" + invalid + "\"}")))
                .andExpect(status().isBadRequest());

        mvc.perform(patch("/api/patients/" + PATIENT_ID).with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content("{\"phone\":\"71111111\"}"))
            .andExpect(status().isOk());
        mvc.perform(patch("/api/patients/" + PATIENT_ID).with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content("{\"sex\":\"NOT_RECORDED\"}"))
            .andExpect(status().isOk());
        verify(patientService, org.mockito.Mockito.times(2)).update(eq(administrator()), eq(PATIENT_ID), commands.capture(), any());
        assertEquals("FEMALE", commands.getAllValues().get(2).sex(), "PATCH sin sex conserva el actual");
        assertEquals("NOT_RECORDED", commands.getAllValues().get(3).sex());
    }

    @Test
    void creationRequiresCsrfBeforePersistence() throws Exception {
        mvc.perform(post("/api/patients").with(authentication(adminAuthentication()))
                .contentType(MediaType.APPLICATION_JSON).content(createBody()))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.error").value("forbidden"));
    }

    @Test
    void administrativeCreationReturns201AndPatientId() throws Exception {
        when(patientService.create(eq(administrator()), any(), any())).thenReturn(PATIENT_ID);

        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(createBody()))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.id").value(PATIENT_ID.toString()));
        verify(patientService).create(eq(administrator()), any(), any());
    }

    @Test
    void duplicateNormalizedIdentifierReturns409() throws Exception {
        when(patientService.create(eq(administrator()), any(), any())).thenThrow(new DuplicatePatientIdentifierException());

        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(createBody()))
            .andExpect(status().isConflict())
            .andExpect(jsonPath("$.ok").value(false))
            .andExpect(jsonPath("$.error").value("El carnet o código de registro ya existe."));
    }

    @Test
    void nonAdministrativeActorCannotWrite() throws Exception {
        mvc.perform(post("/api/patients").with(authentication(studentAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(createBody()))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.error").value("forbidden"));
    }

    @Test
    void emergencyContactIsOptionalAbsentMeansUntouchedAndNullDeletesIt() throws Exception {
        when(patientService.create(eq(administrator()), any(), any())).thenReturn(PATIENT_ID);
        when(patientService.get(eq(administrator()), eq(PATIENT_ID))).thenReturn(java.util.Optional.of(summary()));
        when(patientService.update(eq(administrator()), eq(PATIENT_ID), any(), any())).thenReturn(PATIENT_ID);
        when(patientService.detail(eq(administrator()), eq(PATIENT_ID))).thenReturn(java.util.Optional.of(
            new PatientDetail(summary(), new EmergencyContact("Rosa Mercado", "PARENT", "70011122"))));
        var changes = org.mockito.ArgumentCaptor.forClass(PatientService.ContactChange.class);
        String contact = "\"emergencyContact\":{\"fullName\":\" Rosa Mercado \",\"relationship\":\"PARENT\",\"phone\":\"70011122\"}";

        mvc.perform(get("/api/patients/" + PATIENT_ID).with(authentication(adminAuthentication())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.fullName").value("Ana Mercado"))
            .andExpect(jsonPath("$.data.emergencyContact.relationship").value("PARENT"))
            .andExpect(jsonPath("$.data.emergencyContact.phone").value("70011122"));

        for (String body : List.of(createBody(), createBody().replace("}", "," + contact + "}"), createBody().replace("}", ",\"emergencyContact\":null}")))
            mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isCreated());
        verify(patientService, org.mockito.Mockito.times(3)).create(eq(administrator()), any(), changes.capture());
        assertEquals(PatientService.ContactChange.UNCHANGED, changes.getAllValues().get(0));
        assertEquals(new PatientService.ContactChange(true, new EmergencyContact("Rosa Mercado", "PARENT", "70011122")), changes.getAllValues().get(1));
        assertEquals(PatientService.ContactChange.UNCHANGED, changes.getAllValues().get(2), "Al crear, null es no tener contacto");

        for (String body : List.of("{\"phone\":\"7\"}", "{\"emergencyContact\":null}", "{" + contact + "}"))
            mvc.perform(patch("/api/patients/" + PATIENT_ID).with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isOk());
        verify(patientService, org.mockito.Mockito.times(3)).update(eq(administrator()), eq(PATIENT_ID), any(), changes.capture());
        assertEquals(PatientService.ContactChange.UNCHANGED, changes.getAllValues().get(3), "Sin el campo no se toca");
        assertEquals(new PatientService.ContactChange(true, null), changes.getAllValues().get(4), "null en PATCH elimina");
        assertEquals("PARENT", changes.getAllValues().get(5).value().relationship());

        for (String invalid : List.of("{\"emergencyContact\":{\"fullName\":\"Rosa\",\"relationship\":\"MOTHER\",\"phone\":\"7\"}}",
                "{\"emergencyContact\":{\"fullName\":\" \",\"relationship\":\"PARENT\",\"phone\":\"7\"}}",
                "{\"emergencyContact\":{\"fullName\":\"Rosa\",\"relationship\":\"PARENT\"}}",
                "{\"emergencyContact\":{\"fullName\":\"Rosa\",\"relationship\":\"PARENT\",\"phone\":\"7\",\"email\":\"x\"}}",
                "{\"emergencyContact\":\"Rosa\"}"))
            mvc.perform(patch("/api/patients/" + PATIENT_ID).with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(invalid)).andExpect(status().isBadRequest());
    }

    @Test
    void consentsAreOptionalDuringTheRolloutAndRegisteredOnlyWhenSent() throws Exception {
        when(patientService.create(eq(administrator()), any(), any())).thenReturn(PATIENT_ID);
        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content(createBody())).andExpect(status().isCreated());
        org.mockito.Mockito.verifyNoInteractions(consentService);

        String answer = "{\"termsVersion\":\"1\",\"termsAccepted\":true,\"researchVersion\":\"1\",\"researchAccepted\":false}";
        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content(createBody().replace("}", ",\"consents\":" + answer + "}"))).andExpect(status().isCreated());
        verify(consentService).saveForPatient(eq(administrator()), eq(PATIENT_ID),
            eq(new bo.edu.uagrm.saludu.patients.application.ConsentAnswer("1", true, "1", false)));

        // Sin elegir Sí o No: 400 antes de crear nada.
        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content(createBody().replace("}", ",\"consents\":" + answer.replace(",\"researchAccepted\":false", "") + "}")))
            .andExpect(status().isBadRequest());
        verify(patientService, org.mockito.Mockito.times(2)).create(eq(administrator()), any(), any());
    }

    private static String createBody() {
        return "{\"fullName\":\"Ana Mercado\",\"carnet\":\"123 456\",\"registrationCode\":\"REG-001\",\"birthDate\":\"2002-01-15\",\"careerId\":\"" + CAREER_ID + "\",\"academicPeriod\":\"2026-II\",\"enrollmentStart\":\"2026-07-01\",\"email\":\"ana@example.invalid\",\"phone\":\"70000000\"}";
    }

    private static PatientSummary summary() {
        return new PatientSummary(PATIENT_ID, "123456", "REG-001", "Ana Mercado", LocalDate.of(2002, 1, 15), "70000000", "ana@example.invalid", "ACTIVE", Instant.parse("2026-01-01T00:00:00Z"), Instant.parse("2026-01-02T00:00:00Z"), new PatientSummary.Career(CAREER_ID, "MED", "Medicina"), new PatientSummary.Enrollment(UUID.randomUUID(), "2026-II", LocalDate.of(2026, 7, 1), "ACTIVE"), "FEMALE");
    }

    private static SessionPrincipal administrator() {
        return new SessionPrincipal(ADMIN_ID, "admin@example.invalid", "Administración", List.of("ADMINISTRATIVE"));
    }

    private static UsernamePasswordAuthenticationToken adminAuthentication() {
        return new UsernamePasswordAuthenticationToken(administrator(), null, List.of(new SimpleGrantedAuthority("ROLE_ADMINISTRATIVE")));
    }

    private static UsernamePasswordAuthenticationToken studentAuthentication() {
        SessionPrincipal student = new SessionPrincipal(UUID.randomUUID(), "student@example.invalid", "Estudiante", List.of("STUDENT"));
        return new UsernamePasswordAuthenticationToken(student, null, List.of(new SimpleGrantedAuthority("ROLE_STUDENT")));
    }
}

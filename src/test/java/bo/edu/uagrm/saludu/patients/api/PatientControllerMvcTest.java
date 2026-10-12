package bo.edu.uagrm.saludu.patients.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.patients.application.DuplicatePatientIdentifierException;
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
    void creationRequiresCsrfBeforePersistence() throws Exception {
        mvc.perform(post("/api/patients").with(authentication(adminAuthentication()))
                .contentType(MediaType.APPLICATION_JSON).content(createBody()))
            .andExpect(status().isForbidden())
            .andExpect(jsonPath("$.error").value("forbidden"));
    }

    @Test
    void administrativeCreationReturns201AndPatientId() throws Exception {
        when(patientService.create(eq(administrator()), any())).thenReturn(PATIENT_ID);

        mvc.perform(post("/api/patients").with(authentication(adminAuthentication())).with(csrf())
                .contentType(MediaType.APPLICATION_JSON).content(createBody()))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.ok").value(true))
            .andExpect(jsonPath("$.data.id").value(PATIENT_ID.toString()));
        verify(patientService).create(eq(administrator()), any());
    }

    @Test
    void duplicateNormalizedIdentifierReturns409() throws Exception {
        when(patientService.create(eq(administrator()), any())).thenThrow(new DuplicatePatientIdentifierException());

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

    private static String createBody() {
        return "{\"fullName\":\"Ana Mercado\",\"carnet\":\"123 456\",\"registrationCode\":\"REG-001\",\"birthDate\":\"2002-01-15\",\"careerId\":\"" + CAREER_ID + "\",\"academicPeriod\":\"2026-II\",\"enrollmentStart\":\"2026-07-01\",\"email\":\"ana@example.invalid\",\"phone\":\"70000000\"}";
    }

    private static PatientSummary summary() {
        return new PatientSummary(PATIENT_ID, "123456", "REG-001", "Ana Mercado", LocalDate.of(2002, 1, 15), "70000000", "ana@example.invalid", "ACTIVE", Instant.parse("2026-01-01T00:00:00Z"), Instant.parse("2026-01-02T00:00:00Z"), new PatientSummary.Career(CAREER_ID, "MED", "Medicina"), new PatientSummary.Enrollment(UUID.randomUUID(), "2026-II", LocalDate.of(2026, 7, 1), "ACTIVE"));
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

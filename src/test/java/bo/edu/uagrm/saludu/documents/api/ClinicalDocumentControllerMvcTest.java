package bo.edu.uagrm.saludu.documents.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import bo.edu.uagrm.saludu.documents.application.ClinicalDocumentService;
import bo.edu.uagrm.saludu.identity.application.AuthenticationService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiExceptionHandler;
import bo.edu.uagrm.saludu.shared.api.ApiSecurityErrorWriter;
import bo.edu.uagrm.saludu.shared.api.RequestIdFilter;
import bo.edu.uagrm.saludu.shared.security.SecurityConfig;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(ClinicalDocumentController.class)
@Import({SecurityConfig.class, ApiSecurityErrorWriter.class, RequestIdFilter.class, ApiExceptionHandler.class})
class ClinicalDocumentControllerMvcTest {
    @Autowired MockMvc mvc;
    @MockBean ClinicalDocumentService service;
    @MockBean AuthenticationService authenticationService;
    @MockBean SessionCookieService sessionCookieService;

    @Test
    void authorizedDoctorUploadsWithLegacy201Contract() throws Exception {
        UUID id = UUID.randomUUID();
        when(service.upload(any(), any(), any(), any(), any(), any(), any())).thenReturn(id);
        mvc.perform(multipart("/api/medical/documents")
                .file(new MockMultipartFile("file", "resultado.pdf", "application/pdf", "%PDF-1.7".getBytes()))
                .param("patientId", UUID.randomUUID().toString()).param("encounterId", UUID.randomUUID().toString())
                .param("documentType", "LAB_RESULT").with(authentication(doctor())).with(csrf()))
            .andExpect(status().isCreated()).andExpect(jsonPath("$.ok").value(true)).andExpect(jsonPath("$.data.id").value(id.toString()));
    }

    @Test
    void anonymousUploadIsRejected() throws Exception {
        mvc.perform(multipart("/api/medical/documents")
                .file(new MockMultipartFile("file", "resultado.pdf", MediaType.APPLICATION_PDF_VALUE, "%PDF".getBytes()))
                .param("patientId", UUID.randomUUID().toString()).param("encounterId", UUID.randomUUID().toString()).param("documentType", "LAB_RESULT").with(csrf()))
            .andExpect(status().isUnauthorized());
    }

    private static UsernamePasswordAuthenticationToken doctor() {
        SessionPrincipal doctor = new SessionPrincipal(UUID.randomUUID(), "doctor@example.invalid", "Médico", List.of("REVIEW_DOCTOR"));
        return new UsernamePasswordAuthenticationToken(doctor, null, List.of(new SimpleGrantedAuthority("ROLE_REVIEW_DOCTOR")));
    }
}

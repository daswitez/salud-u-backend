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
    @Test void listKeepsNullMetadataAndForeignEncounterIsHidden() throws Exception {
        UUID encounter=UUID.randomUUID(),id=UUID.randomUUID();
        when(service.list(any(),any())).thenReturn(List.of(new ClinicalDocumentService.DocumentMetadata(id,"LAB_RESULT","resultado.pdf","application/pdf",12,null,null,java.time.OffsetDateTime.now())));
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/medical/documents").param("encounterId",encounter.toString()).with(authentication(doctor())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data[0].id").value(id.toString())).andExpect(jsonPath("$.data[0].studyDate").isEmpty())
            .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.header().string("Cache-Control","no-store, private"));
        when(service.list(any(),any())).thenThrow(new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(404,"No se encontró una atención accesible para consultar documentos."));
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/medical/documents").param("encounterId",encounter.toString()).with(authentication(doctor())))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").isString()).andExpect(jsonPath("$.data").doesNotExist());
    }
    @Test void studentCannotListAndExpiredContentKeepsTextErrorContract() throws Exception {
        var student=new SessionPrincipal(UUID.randomUUID(),"student@example.invalid","Estudiante",List.of("STUDENT"));
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/medical/documents").param("encounterId",UUID.randomUUID().toString()).with(authentication(new UsernamePasswordAuthenticationToken(student,null,List.of(new SimpleGrantedAuthority("ROLE_STUDENT")))))).andExpect(status().isForbidden());
        when(service.consume(any(SessionPrincipal.class),any(),any())).thenThrow(new bo.edu.uagrm.saludu.agenda.application.AvailabilityException(404,"El enlace del archivo expiró."));
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/medical/documents/"+UUID.randomUUID()+"/content").param("token","expired").with(authentication(doctor())))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.error").value("El enlace del archivo expiró."));
    }
    @Test void downloadUsesRelativePrivateLinkAndBadStudyDateIs400() throws Exception {
        UUID id=UUID.randomUUID();String url="/api/medical/documents/"+id+"/content?token=test";
        when(service.signedUrl(any(),any())).thenReturn(url);
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/medical/documents/"+id+"/download").with(authentication(doctor())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.data.url").value(url));
        mvc.perform(multipart("/api/medical/documents").file(new MockMultipartFile("file","file.pdf","application/pdf","%PDF".getBytes()))
            .param("patientId",UUID.randomUUID().toString()).param("encounterId",UUID.randomUUID().toString()).param("documentType","OTHER").param("studyDate","2026-02-30").with(authentication(doctor())).with(csrf()))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.error").isString());
    }
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

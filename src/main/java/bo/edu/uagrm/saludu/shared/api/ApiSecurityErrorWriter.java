package bo.edu.uagrm.saludu.shared.api;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Map;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;

@Component
public class ApiSecurityErrorWriter {
    private final ObjectMapper objectMapper;

    public ApiSecurityErrorWriter(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public void write(HttpServletRequest request, HttpServletResponse response, int status, String code, String message)
        throws IOException {
        response.setStatus(status);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        String path = request.getRequestURI();
        if ("/api/me".equals(path) || "/api/specialties".equals(path) || "/api/my-specialties".equals(path) || path.startsWith("/api/patients") || path.startsWith("/api/availability-slots")) {
            String legacyError = status == HttpServletResponse.SC_UNAUTHORIZED ? "unauthenticated" : "forbidden";
            objectMapper.writeValue(response.getOutputStream(), Map.of("ok", false, "error", legacyError));
            return;
        }
        objectMapper.writeValue(response.getOutputStream(), ApiEnvelope.failure(code, message, RequestIdFilter.from(request)));
    }
}

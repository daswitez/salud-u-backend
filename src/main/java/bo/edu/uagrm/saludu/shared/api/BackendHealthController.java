package bo.edu.uagrm.saludu.shared.api;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.actuate.health.HealthEndpoint;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Public, dependency-neutral probe for the Next integration. */
@RestController
public class BackendHealthController {
    private final HealthEndpoint healthEndpoint;

    public BackendHealthController(HealthEndpoint healthEndpoint) {
        this.healthEndpoint = healthEndpoint;
    }

    @GetMapping("/api/health")
    public ResponseEntity<Map<String, Object>> health() {
        String status = healthEndpoint.health().getStatus().getCode();
        boolean up = "UP".equals(status);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("ok", up);
        body.put("service", "backend");
        body.put("status", status);
        body.put("error", up ? null : "backend_unavailable");
        return ResponseEntity.status(up ? HttpStatus.OK : HttpStatus.SERVICE_UNAVAILABLE).body(body);
    }
}

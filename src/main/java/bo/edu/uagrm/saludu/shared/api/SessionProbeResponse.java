package bo.edu.uagrm.saludu.shared.api;

import java.util.List;

public record SessionProbeResponse(String subject, List<String> authorities) {
}

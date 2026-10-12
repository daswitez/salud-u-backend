package bo.edu.uagrm.saludu.shared.api;

import java.util.Map;

public record ApiError(String code, String message, Map<String, ?> details, String requestId) {
}

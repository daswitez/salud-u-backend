package bo.edu.uagrm.saludu.shared.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.Map;

/**
 * JSON envelope used only by the versioned Spring API. It preserves the
 * ok/data/error convention observed in the Next API without altering it.
 */
@JsonInclude(JsonInclude.Include.ALWAYS)
public record ApiEnvelope<T>(boolean ok, T data, ApiError error) {
    public static <T> ApiEnvelope<T> success(T data) {
        return new ApiEnvelope<>(true, data, null);
    }

    public static ApiEnvelope<Void> failure(String code, String message, String requestId) {
        return failure(code, message, Map.of(), requestId);
    }

    public static ApiEnvelope<Void> failure(String code, String message, Map<String, ?> details, String requestId) {
        return new ApiEnvelope<>(false, null, new ApiError(code, message, details, requestId));
    }
}

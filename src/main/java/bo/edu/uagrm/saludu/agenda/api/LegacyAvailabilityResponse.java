package bo.edu.uagrm.saludu.agenda.api;

import com.fasterxml.jackson.annotation.JsonInclude;

@JsonInclude(JsonInclude.Include.NON_NULL)
public record LegacyAvailabilityResponse<T>(boolean ok, T data, String error) {
    public static <T> LegacyAvailabilityResponse<T> success(T data) {
        return new LegacyAvailabilityResponse<>(true, data, null);
    }

    public static LegacyAvailabilityResponse<Void> failure(String error) {
        return new LegacyAvailabilityResponse<>(false, null, error);
    }
}

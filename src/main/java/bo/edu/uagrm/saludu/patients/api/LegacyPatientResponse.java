package bo.edu.uagrm.saludu.patients.api;

import com.fasterxml.jackson.annotation.JsonInclude;

@JsonInclude(JsonInclude.Include.NON_NULL)
public record LegacyPatientResponse<T>(boolean ok, T data, String error) {
    public static <T> LegacyPatientResponse<T> success(T data) {
        return new LegacyPatientResponse<>(true, data, null);
    }

    public static LegacyPatientResponse<Void> failure(String error) {
        return new LegacyPatientResponse<>(false, null, error);
    }
}

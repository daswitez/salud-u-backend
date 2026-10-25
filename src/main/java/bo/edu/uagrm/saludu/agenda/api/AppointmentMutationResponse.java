package bo.edu.uagrm.saludu.agenda.api;

import com.fasterxml.jackson.annotation.JsonInclude;

/** Legacy appointment mutations explicitly return data:null. */
@JsonInclude(JsonInclude.Include.ALWAYS)
public record AppointmentMutationResponse(boolean ok, Object data) {
    public static AppointmentMutationResponse success() {
        return new AppointmentMutationResponse(true, null);
    }
}

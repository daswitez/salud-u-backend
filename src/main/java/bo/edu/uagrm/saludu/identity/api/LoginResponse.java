package bo.edu.uagrm.saludu.identity.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;

/** Sin segundo factor la respuesta sigue siendo solo {@code user}; los demás campos se omiten cuando son null. */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record LoginResponse(SessionUserResponse user, Boolean secondFactorRequired, Boolean enrollmentRequired, List<String> recoveryCodes) {
    public LoginResponse(SessionUserResponse user) {
        this(user, null, null, null);
    }

    public static LoginResponse secondFactor(boolean enrollmentRequired) {
        return new LoginResponse(null, true, enrollmentRequired, null);
    }
}

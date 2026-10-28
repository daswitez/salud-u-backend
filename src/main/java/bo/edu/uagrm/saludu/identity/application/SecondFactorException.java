package bo.edu.uagrm.saludu.identity.application;

import org.springframework.http.HttpStatus;

/** SEG-2FA: error del segundo paso con su estado HTTP y código de API. Nunca incluye el código ni el secreto. */
public class SecondFactorException extends RuntimeException {
    private final HttpStatus status;
    private final String code;

    public SecondFactorException(HttpStatus status, String code, String message) {
        super(message);
        this.status = status;
        this.code = code;
    }

    public HttpStatus status() {
        return status;
    }

    public String code() {
        return code;
    }
}

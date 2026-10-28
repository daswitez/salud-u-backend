package bo.edu.uagrm.saludu.shared.api;

import bo.edu.uagrm.saludu.identity.application.InvalidCredentialsException;
import bo.edu.uagrm.saludu.identity.application.EmailAlreadyUsedException;
import bo.edu.uagrm.saludu.patients.api.LegacyPatientResponse;
import bo.edu.uagrm.saludu.patients.application.DuplicatePatientIdentifierException;
import bo.edu.uagrm.saludu.patients.application.InvalidPatientException;
import bo.edu.uagrm.saludu.patients.application.PatientNotFoundException;
import bo.edu.uagrm.saludu.agenda.api.LegacyAvailabilityResponse;
import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import jakarta.servlet.http.HttpServletRequest;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.dao.DataAccessException;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class ApiExceptionHandler {
    @ExceptionHandler(org.springframework.web.multipart.MaxUploadSizeExceededException.class)
    ResponseEntity<?> uploadTooLarge(Exception exception,HttpServletRequest request) {
        return error(HttpStatus.PAYLOAD_TOO_LARGE,"UPLOAD_TOO_LARGE","El archivo debe pesar hasta 15 MiB.",Map.of(),request);
    }
    @ExceptionHandler(org.springframework.web.HttpRequestMethodNotSupportedException.class)
    ResponseEntity<?> unsupportedMethod(org.springframework.web.HttpRequestMethodNotSupportedException exception, HttpServletRequest request) {
        var response = error(HttpStatus.METHOD_NOT_ALLOWED, "METHOD_NOT_ALLOWED", "Este recurso no admite esa operación.", Map.of(), request);
        var headers = new org.springframework.http.HttpHeaders();
        if (exception.getSupportedHttpMethods() != null) headers.setAllow(exception.getSupportedHttpMethods());
        return new ResponseEntity<>(response.getBody(), headers, HttpStatus.METHOD_NOT_ALLOWED);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    ResponseEntity<?> validation(MethodArgumentNotValidException exception, HttpServletRequest request) {
        Map<String, String> violations = new LinkedHashMap<>();
        for (FieldError error : exception.getBindingResult().getFieldErrors()) {
            violations.putIfAbsent(error.getField(), error.getDefaultMessage());
        }
        return error(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", "La solicitud contiene campos inválidos.", violations, request);
    }

    @ExceptionHandler({HttpMessageNotReadableException.class, IllegalArgumentException.class, org.springframework.web.method.annotation.MethodArgumentTypeMismatchException.class})
    ResponseEntity<?> invalidRequest(Exception exception, HttpServletRequest request) {
        return error(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", "La solicitud no tiene un formato válido.", Map.of(), request);
    }

    @ExceptionHandler(InvalidCredentialsException.class)
    ResponseEntity<?> invalidCredentials(InvalidCredentialsException exception, HttpServletRequest request) {
        return error(HttpStatus.UNAUTHORIZED, "INVALID_CREDENTIALS", "Las credenciales no son válidas.", Map.of(), request);
    }

    @ExceptionHandler(bo.edu.uagrm.saludu.identity.application.SecondFactorException.class)
    ResponseEntity<?> secondFactor(bo.edu.uagrm.saludu.identity.application.SecondFactorException exception, HttpServletRequest request) {
        return error(exception.status(), exception.code(), exception.getMessage(), Map.of(), request);
    }

    @ExceptionHandler(EmailAlreadyUsedException.class)
    ResponseEntity<?> emailAlreadyUsed(EmailAlreadyUsedException exception, HttpServletRequest request) {
        return error(HttpStatus.CONFLICT, "EMAIL_ALREADY_USED", "El correo ya está asociado a otra cuenta.", Map.of(), request);
    }

    @ExceptionHandler(PatientNotFoundException.class)
    ResponseEntity<LegacyPatientResponse<Void>> patientNotFound(PatientNotFoundException exception) {
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(LegacyPatientResponse.failure("Estudiante no encontrado."));
    }

    @ExceptionHandler(DuplicatePatientIdentifierException.class)
    ResponseEntity<LegacyPatientResponse<Void>> duplicatePatientIdentifier(DuplicatePatientIdentifierException exception) {
        return ResponseEntity.status(HttpStatus.CONFLICT).body(LegacyPatientResponse.failure("El carnet o código de registro ya existe."));
    }

    @ExceptionHandler(InvalidPatientException.class)
    ResponseEntity<LegacyPatientResponse<Void>> invalidPatient(InvalidPatientException exception) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(LegacyPatientResponse.failure(exception.getMessage()));
    }

    /** A-03: misma forma {ok, error} con un código estable para que la pantalla abra el diálogo de consentimiento. */
    @ExceptionHandler(bo.edu.uagrm.saludu.patients.application.ConsentPendingException.class)
    ResponseEntity<Map<String, Object>> consentPending(bo.edu.uagrm.saludu.patients.application.ConsentPendingException exception) {
        return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY).body(Map.of("ok", false, "error", exception.getMessage(),
            "code", bo.edu.uagrm.saludu.patients.application.ConsentPendingException.CODE));
    }

    @ExceptionHandler(AvailabilityException.class)
    ResponseEntity<LegacyAvailabilityResponse<Void>> availability(AvailabilityException exception) {
        return ResponseEntity.status(exception.status()).body(LegacyAvailabilityResponse.failure(exception.getMessage()));
    }

    @ExceptionHandler(DataAccessException.class)
    ResponseEntity<?> persistenceFailure(DataAccessException exception, HttpServletRequest request) {
        // Un fallo interno de persistencia no invalida la sesión. No exponer SQL
        // ni detalles de conexión en la respuesta enviada al navegador.
        return error(HttpStatus.INTERNAL_SERVER_ERROR, "PERSISTENCE_FAILURE",
            "No se pudo completar la operación. Inténtalo nuevamente.", Map.of(), request);
    }

    private ResponseEntity<?> error(
        HttpStatus status, String code, String message, Map<String, ?> details, HttpServletRequest request
    ) {
        if (ApiSecurityErrorWriter.isLegacyApi(request.getRequestURI())) {
            return ResponseEntity.status(status).body(LegacyAvailabilityResponse.failure(message));
        }
        return ResponseEntity.status(status).body(ApiEnvelope.failure(code, message, details, RequestIdFilter.from(request)));
    }
}

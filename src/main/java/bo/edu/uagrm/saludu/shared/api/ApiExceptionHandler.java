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
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class ApiExceptionHandler {
    @ExceptionHandler(MethodArgumentNotValidException.class)
    ResponseEntity<ApiEnvelope<Void>> validation(MethodArgumentNotValidException exception, HttpServletRequest request) {
        Map<String, String> violations = new LinkedHashMap<>();
        for (FieldError error : exception.getBindingResult().getFieldErrors()) {
            violations.putIfAbsent(error.getField(), error.getDefaultMessage());
        }
        return error(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", "La solicitud contiene campos inválidos.", violations, request);
    }

    @ExceptionHandler({HttpMessageNotReadableException.class, IllegalArgumentException.class})
    ResponseEntity<ApiEnvelope<Void>> invalidRequest(Exception exception, HttpServletRequest request) {
        return error(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", "La solicitud no tiene un formato válido.", Map.of(), request);
    }

    @ExceptionHandler(InvalidCredentialsException.class)
    ResponseEntity<ApiEnvelope<Void>> invalidCredentials(InvalidCredentialsException exception, HttpServletRequest request) {
        return error(HttpStatus.UNAUTHORIZED, "INVALID_CREDENTIALS", "Las credenciales no son válidas.", Map.of(), request);
    }

    @ExceptionHandler(EmailAlreadyUsedException.class)
    ResponseEntity<ApiEnvelope<Void>> emailAlreadyUsed(EmailAlreadyUsedException exception, HttpServletRequest request) {
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

    @ExceptionHandler(AvailabilityException.class)
    ResponseEntity<LegacyAvailabilityResponse<Void>> availability(AvailabilityException exception) {
        return ResponseEntity.status(exception.status()).body(LegacyAvailabilityResponse.failure(exception.getMessage()));
    }

    private ResponseEntity<ApiEnvelope<Void>> error(
        HttpStatus status, String code, String message, Map<String, ?> details, HttpServletRequest request
    ) {
        return ResponseEntity.status(status).body(ApiEnvelope.failure(code, message, details, RequestIdFilter.from(request)));
    }
}

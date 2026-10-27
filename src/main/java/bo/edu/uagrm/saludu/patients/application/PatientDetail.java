package bo.edu.uagrm.saludu.patients.application;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonUnwrapped;

/** A-02: GET /api/patients/{id} conserva los campos de siempre y agrega emergencyContact (null si no hay). */
public record PatientDetail(@JsonUnwrapped PatientSummary patient, @JsonInclude(JsonInclude.Include.ALWAYS) EmergencyContact emergencyContact) {}

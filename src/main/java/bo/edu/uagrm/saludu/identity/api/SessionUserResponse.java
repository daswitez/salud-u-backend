package bo.edu.uagrm.saludu.identity.api;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import java.util.List;
import java.util.UUID;

public record SessionUserResponse(UUID id, String email, String name, String role, String clinicalRole) {
    private static final List<String> PRIORITY = List.of("ADMINISTRATIVE", "REVIEW_DOCTOR", "SPECIALIST", "STUDENT", "AUDITOR");

    public static SessionUserResponse from(SessionPrincipal principal) {
        String clinicalRole = PRIORITY.stream().filter(principal.roles()::contains).findFirst()
            .orElseThrow(() -> new IllegalStateException("La sesión no tiene un rol clínico activo."));
        String role = switch (clinicalRole) {
            case "STUDENT" -> "estudiante";
            case "ADMINISTRATIVE", "AUDITOR" -> "administrativo";
            default -> "medico";
        };
        return new SessionUserResponse(principal.id(), principal.email(), principal.displayName(), role, clinicalRole);
    }
}

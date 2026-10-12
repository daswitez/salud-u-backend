package bo.edu.uagrm.saludu.identity.application;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.util.Map;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class ProfileService {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;

    public ProfileService(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
    }

    @Transactional
    public void updateProfile(SessionPrincipal principal, String displayName, String email, String currentPassword) {
        apply(principal);
        String result = jdbcTemplate.queryForObject(
            "select salud_u.actualizar_mi_perfil(?, ?, ?)", String.class, displayName, email, currentPassword
        );
        if ("INVALID_CURRENT_PASSWORD".equals(result)) {
            throw new InvalidCredentialsException();
        }
        if ("EMAIL_ALREADY_USED".equals(result)) {
            throw new EmailAlreadyUsedException();
        }
        if (!"UPDATED".equals(result)) {
            throw new IllegalStateException("Resultado de perfil no reconocido.");
        }
        auditWriter.append("PROFILE_UPDATED", "principal", principal.id(), AuditOutcome.SUCCESS, Map.of("sessionsRevoked", true));
    }

    @Transactional
    public void changePassword(SessionPrincipal principal, String currentPassword, String newPassword) {
        apply(principal);
        String result = jdbcTemplate.queryForObject(
            "select salud_u.cambiar_mi_contrasena(?, ?)", String.class, currentPassword, newPassword
        );
        if ("INVALID_CURRENT_PASSWORD".equals(result)) {
            throw new InvalidCredentialsException();
        }
        if (!"UPDATED".equals(result)) {
            throw new IllegalStateException("Resultado de contraseña no reconocido.");
        }
        auditWriter.append("PASSWORD_CHANGED", "principal", principal.id(), AuditOutcome.SUCCESS, Map.of("sessionsRevoked", true));
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), java.util.Set.copyOf(principal.roles())));
    }
}

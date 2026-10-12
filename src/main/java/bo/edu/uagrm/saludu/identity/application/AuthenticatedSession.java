package bo.edu.uagrm.saludu.identity.application;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;

public record AuthenticatedSession(SessionPrincipal principal, String token) {
}

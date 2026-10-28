package bo.edu.uagrm.saludu.identity.application;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;

/**
 * Resultado de la contraseña correcta. Sin {@code challenge}, {@code token} es la sesión. Con {@code challenge}
 * (SEG-2FA), todavía no hay sesión: {@code principal} es null y el token es el del desafío de segundo factor.
 */
public record AuthenticatedSession(SessionPrincipal principal, String token, SecondFactorChallenge challenge) {
    public AuthenticatedSession(SessionPrincipal principal, String token) {
        this(principal, token, null);
    }

    public static AuthenticatedSession secondFactor(String challengeToken, boolean enrollmentRequired) {
        return new AuthenticatedSession(null, challengeToken, new SecondFactorChallenge(enrollmentRequired));
    }

    public record SecondFactorChallenge(boolean enrollmentRequired) {
    }
}

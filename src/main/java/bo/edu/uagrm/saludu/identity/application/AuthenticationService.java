package bo.edu.uagrm.saludu.identity.application;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
public class AuthenticationService {
    private static final SecureRandom TOKEN_RANDOM = new SecureRandom();
    private final JdbcTemplate jdbcTemplate;
    private final AuthProperties properties;

    public AuthenticationService(JdbcTemplate jdbcTemplate, AuthProperties properties) {
        this.jdbcTemplate = jdbcTemplate;
        this.properties = properties;
    }

    /**
     * Contraseña correcta: emite la sesión, salvo que algún rol esté en {@code salud-u.auth.second-factor-roles}
     * (SEG-2FA). En ese caso no hay sesión todavía: se devuelve un desafío de segundo factor de 5 minutos.
     */
    public AuthenticatedSession login(String email, String password) {
        String token = newToken();
        String challenge = newToken();
        Instant now = Instant.now();
        List<String> secondFactorRoles = properties.getSecondFactorRoles();
        List<AuthenticationRow> rows = jdbcTemplate.query(
            "select * from salud_u.iniciar_sesion_principal(?, ?, ?, ?, cast(? as text[]), ?, ?)",
            (resultSet, rowNumber) -> authenticationRow(resultSet),
            email,
            password,
            sha256(token),
            OffsetDateTime.ofInstant(now.plus(properties.getSessionTtl()), ZoneOffset.UTC),
            textArray(secondFactorRoles),
            secondFactorRoles.isEmpty() ? null : sha256(challenge),
            secondFactorRoles.isEmpty() ? null : OffsetDateTime.ofInstant(now.plus(properties.getSecondFactorChallengeTtl()), ZoneOffset.UTC)
        );
        if (rows.size() == 1 && "SEGUNDO_FACTOR".equals(rows.getFirst().status())) {
            return AuthenticatedSession.secondFactor(challenge, rows.getFirst().enrollmentRequired());
        }
        if (rows.size() != 1 || !"AUTENTICADO".equals(rows.getFirst().status())) {
            throw new InvalidCredentialsException();
        }
        AuthenticationRow row = rows.getFirst();
        return new AuthenticatedSession(new SessionPrincipal(row.id(), row.email(), row.displayName(), row.roles()), token);
    }

    public Optional<SessionPrincipal> resolve(String token) {
        if (token == null || token.isBlank()) {
            return Optional.empty();
        }
        List<SessionPrincipal> rows = jdbcTemplate.query(
            "select * from salud_u.resolver_sesion_autenticacion(?)",
            (resultSet, rowNumber) -> new SessionPrincipal(
                resultSet.getObject("id_principal", UUID.class),
                resultSet.getString("correo"),
                resultSet.getString("nombre_mostrado"),
                roles(resultSet)
            ),
            sha256(token)
        );
        return rows.stream().findFirst();
    }

    public void revoke(String token) {
        if (token != null && !token.isBlank()) {
            jdbcTemplate.queryForObject("select salud_u.revocar_sesion_autenticacion(?)", Void.class, sha256(token));
        }
    }

    private static AuthenticationRow authenticationRow(ResultSet resultSet) throws SQLException {
        return new AuthenticationRow(
            resultSet.getString("estado_autenticacion"),
            resultSet.getObject("id_principal", UUID.class),
            resultSet.getString("correo"),
            resultSet.getString("nombre_mostrado"),
            roles(resultSet),
            resultSet.getBoolean("requiere_activacion")
        );
    }

    /** Literal de arreglo de PostgreSQL; los roles ya vienen validados como [A-Z_]. */
    static String textArray(List<String> values) {
        if (values.stream().anyMatch(value -> !value.matches("[A-Z_]{2,64}"))) {
            throw new IllegalStateException("salud-u.auth.second-factor-roles contiene un rol inválido.");
        }
        return "{" + String.join(",", values) + "}";
    }

    static List<String> roles(ResultSet resultSet) throws SQLException {
        java.sql.Array array = resultSet.getArray("roles");
        if (array == null) {
            return List.of();
        }
        Object values = array.getArray();
        if (values instanceof String[] roles) {
            return List.of(roles);
        }
        return List.of();
    }

    static String newToken() {
        byte[] bytes = new byte[32];
        TOKEN_RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    static byte[] sha256(String value) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 no está disponible en la JVM.", exception);
        }
    }

    private record AuthenticationRow(String status, UUID id, String email, String displayName, List<String> roles, boolean enrollmentRequired) {
    }
}

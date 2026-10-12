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

    public AuthenticatedSession login(String email, String password) {
        String token = newToken();
        Instant expiresAt = Instant.now().plus(properties.getSessionTtl());
        List<AuthenticationRow> rows = jdbcTemplate.query(
            "select * from salud_u.autenticar_principal(?, ?, ?, ?)",
            (resultSet, rowNumber) -> authenticationRow(resultSet),
            email,
            password,
            sha256(token),
            OffsetDateTime.ofInstant(expiresAt, ZoneOffset.UTC)
        );
        if (rows.size() != 1 || !"AUTHENTICATED".equals(rows.getFirst().status())) {
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
                resultSet.getString("email"),
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
            resultSet.getString("auth_status"),
            resultSet.getObject("id_principal", UUID.class),
            resultSet.getString("email"),
            resultSet.getString("nombre_mostrado"),
            roles(resultSet)
        );
    }

    private static List<String> roles(ResultSet resultSet) throws SQLException {
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

    private static String newToken() {
        byte[] bytes = new byte[32];
        TOKEN_RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private static byte[] sha256(String value) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 no está disponible en la JVM.", exception);
        }
    }

    private record AuthenticationRow(String status, UUID id, String email, String displayName, List<String> roles) {
    }
}

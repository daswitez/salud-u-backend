package bo.edu.uagrm.saludu.identity.application;

import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.OptionalLong;
import java.util.Set;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * SEG-2FA: segundo paso del inicio de sesión, activación, códigos de recuperación y restablecimiento.
 *
 * <p>El código TOTP se valida aquí (la base no conoce la clave); la base aplica la anti-repetición, el bloqueo tras 5
 * fallos, el uso único de los códigos de recuperación y la emisión de la sesión, todo en la misma transacción que la
 * auditoría. Los fallos no lanzan excepción dentro de la transacción, para que el contador de intentos se confirme.
 * Ni el secreto, ni el código, ni el token llegan a la auditoría o a los logs.
 */
@Service
public class SecondFactorService {
    public static final String ISSUER = "Salud-U";
    public static final int RECOVERY_CODES = 10;
    private final JdbcTemplate jdbc;
    private final AuthProperties properties;
    private final SecondFactorCipher cipher;
    private final DatabaseActorContext actorContext;
    private final AuditWriter audit;
    private final Clock clock;

    @Autowired
    public SecondFactorService(JdbcTemplate jdbc, AuthProperties properties, SecondFactorCipher cipher, DatabaseActorContext actorContext, AuditWriter audit) {
        this(jdbc, properties, cipher, actorContext, audit, Clock.systemUTC());
    }

    public SecondFactorService(JdbcTemplate jdbc, AuthProperties properties, SecondFactorCipher cipher, DatabaseActorContext actorContext, AuditWriter audit, Clock clock) {
        this.jdbc = jdbc;
        this.properties = properties;
        this.cipher = cipher;
        this.actorContext = actorContext;
        this.audit = audit;
        this.clock = clock;
    }

    public enum Status { AUTHENTICATED, FAILED, LOCKED, CHALLENGE_INVALID, WRONG_STEP }

    /** Resultado de cerrar un desafío: con AUTHENTICATED trae la sesión y, en una activación, los códigos de recuperación. */
    public record Outcome(Status status, AuthenticatedSession session, List<String> recoveryCodes) {
        static Outcome of(Status status) {
            return new Outcome(status, null, List.of());
        }
    }

    public record Enrollment(String otpauthUri, String secret) {
    }

    public record ProfileStatus(boolean required, boolean enabled, Instant activatedAt, int remainingRecoveryCodes) {
    }

    public record Regeneration(Status status, List<String> recoveryCodes) {
    }

    /** Genera el secreto de una activación pendiente y lo devuelve una sola vez (URI otpauth y base32). */
    @Transactional
    public Enrollment enroll(String challengeToken) {
        Challenge challenge = challenge(challengeToken);
        if (challenge == null || !"ENROLLMENT".equals(challenge.purpose())) return null;
        byte[] secret = Totp.newSecret();
        String result = jdbc.queryForObject("select salud_u.preparar_activacion_segundo_factor(?, ?)", String.class,
            AuthenticationService.sha256(challengeToken), cipher.encrypt(challenge.principalId(), secret));
        if (!"PREPARADO".equals(result)) return null;
        return new Enrollment(Totp.otpauthUri(ISSUER, challenge.email(), secret), Totp.base32(secret));
    }

    /** Confirma la activación con un código válido: activa el factor, emite 10 códigos de recuperación y la sesión. */
    @Transactional
    public Outcome confirmEnrollment(String challengeToken, String code) {
        Challenge challenge = challenge(challengeToken);
        if (challenge == null || !"ENROLLMENT".equals(challenge.purpose())) return Outcome.of(Status.CHALLENGE_INVALID);
        if (challenge.encryptedSecret() == null) return Outcome.of(Status.WRONG_STEP);
        var secret = cipher.decrypt(challenge.principalId(), challenge.encryptedSecret());
        OptionalLong step = Totp.matchingStep(secret.secret(), code, clock.instant().getEpochSecond());
        List<String> codes = newRecoveryCodes();
        Completion completion = complete(challengeToken, step, null, hashes(codes), null);
        if (completion.status() != Status.AUTHENTICATED) return failure(completion, challenge);
        apply(completion.session().principal());
        audit.append("SEGUNDO_FACTOR_ACTIVADO", "principal", challenge.principalId(), AuditOutcome.SUCCESS, Map.of("recoveryCodesIssued", RECOVERY_CODES));
        return new Outcome(Status.AUTHENTICATED, completion.session(), codes);
    }

    /** Segundo paso del ingreso con el código de la aplicación o con un código de recuperación (de un solo uso). */
    @Transactional
    public Outcome verify(String challengeToken, String code, String recoveryCode) {
        Challenge challenge = challenge(challengeToken);
        if (challenge == null || !"VERIFICATION".equals(challenge.purpose())) return Outcome.of(Status.CHALLENGE_INVALID);
        Completion completion;
        if (recoveryCode != null && !recoveryCode.isBlank()) {
            completion = complete(challengeToken, OptionalLong.empty(), recoveryHash(recoveryCode), null, null);
        } else {
            var secret = cipher.decrypt(challenge.principalId(), challenge.encryptedSecret());
            OptionalLong step = Totp.matchingStep(secret.secret(), code, clock.instant().getEpochSecond());
            byte[] reencrypted = secret.needsReencryption() && step.isPresent() ? cipher.encrypt(challenge.principalId(), secret.secret()) : null;
            completion = complete(challengeToken, step, null, null, reencrypted);
        }
        if (completion.status() != Status.AUTHENTICATED) return failure(completion, challenge);
        apply(completion.session().principal());
        boolean recovery = "RECUPERACION".equals(completion.method());
        audit.append(recovery ? "CODIGO_RECUPERACION_USADO" : "SEGUNDO_FACTOR_VERIFICADO", "principal", challenge.principalId(), AuditOutcome.SUCCESS,
            recovery ? Map.of("remainingRecoveryCodes", remainingRecoveryCodes()) : Map.of("method", "TOTP"));
        return new Outcome(Status.AUTHENTICATED, completion.session(), List.of());
    }

    @Transactional(readOnly = true)
    public ProfileStatus status(SessionPrincipal principal) {
        apply(principal);
        boolean required = principal.roles().stream().anyMatch(properties.getSecondFactorRoles()::contains);
        var rows = jdbc.query("select activado_en, codigos_disponibles from salud_u.consultar_mi_segundo_factor()",
            (rs, i) -> new ProfileStatus(required, true, rs.getTimestamp("activado_en").toInstant(), rs.getInt("codigos_disponibles")));
        return rows.isEmpty() ? new ProfileStatus(required, false, null, 0) : rows.getFirst();
    }

    /** Reemplaza los códigos de recuperación de la persona, que confirma con un código TOTP válido. */
    @Transactional
    public Regeneration regenerateRecoveryCodes(SessionPrincipal principal, String code) {
        apply(principal);
        var rows = jdbc.query("select secreto_cifrado from salud_u.consultar_mi_segundo_factor()",
            (rs, i) -> rs.getBytes("secreto_cifrado"));
        if (rows.isEmpty()) return new Regeneration(Status.WRONG_STEP, List.of());
        byte[] secret = cipher.decrypt(principal.id(), rows.getFirst()).secret();
        OptionalLong step = Totp.matchingStep(secret, code, clock.instant().getEpochSecond());
        List<String> codes = newRecoveryCodes();
        String result = jdbc.queryForObject("select salud_u.regenerar_mis_codigos_recuperacion(?, ?)", String.class,
            step.isPresent() ? step.getAsLong() : null, hashes(codes));
        switch (result) {
            case "REGENERADO" -> {
                audit.append("CODIGOS_RECUPERACION_REGENERADOS", "principal", principal.id(), AuditOutcome.SUCCESS, Map.of("recoveryCodesIssued", RECOVERY_CODES));
                return new Regeneration(Status.AUTHENTICATED, codes);
            }
            case "FALLIDO", "BLOQUEADO", "EN_BLOQUEO" -> {
                auditFailure(principal.id(), result, "REGENERAR_CODIGOS");
                return new Regeneration("FALLIDO".equals(result) ? Status.FAILED : Status.LOCKED, List.of());
            }
            default -> {
                return new Regeneration(Status.WRONG_STEP, List.of());
            }
        }
    }

    /** Administración anula el segundo factor de otra cuenta; la cuenta lo vuelve a activar en su próximo ingreso. */
    @Transactional
    public boolean reset(SessionPrincipal administrator, UUID principalId) {
        apply(administrator);
        String result;
        try {
            result = jdbc.queryForObject("select salud_u.restablecer_segundo_factor(?)", String.class, principalId);
        } catch (DataAccessException exception) {
            if (String.valueOf(exception.getMostSpecificCause().getMessage()).contains("SEGUNDO_FACTOR_PROPIO")) throw new SelfResetException();
            throw exception;
        }
        if (!"RESTABLECIDO".equals(result)) return false;
        audit.append("SEGUNDO_FACTOR_RESTABLECIDO", "principal", principalId, AuditOutcome.SUCCESS, Map.of("sessionsRevoked", true));
        return true;
    }

    public static final class SelfResetException extends RuntimeException {
        public SelfResetException() {
            super("No puedes restablecer tu propio segundo factor.");
        }
    }

    private Outcome failure(Completion completion, Challenge challenge) {
        if (completion.status() == Status.FAILED || completion.status() == Status.LOCKED) {
            auditFailure(challenge.principalId(), completion.rawStatus(), "INICIO_SESION");
        }
        return Outcome.of(completion.status());
    }

    private void auditFailure(UUID principalId, String rawStatus, String stage) {
        actorContext.apply(new DatabaseActor(principalId, Set.of()));
        switch (rawStatus) {
            case "BLOQUEADO" -> {
                audit.append("SEGUNDO_FACTOR_FALLIDO", "principal", principalId, AuditOutcome.DENIED, Map.of("stage", stage));
                audit.append("SEGUNDO_FACTOR_BLOQUEADO", "principal", principalId, AuditOutcome.DENIED, Map.of("stage", stage, "lockMinutes", 15));
            }
            case "EN_BLOQUEO" -> audit.append("SEGUNDO_FACTOR_FALLIDO", "principal", principalId, AuditOutcome.DENIED, Map.of("stage", stage, "cause", "LOCK_ACTIVE"));
            default -> audit.append("SEGUNDO_FACTOR_FALLIDO", "principal", principalId, AuditOutcome.DENIED, Map.of("stage", stage));
        }
    }

    private Challenge challenge(String token) {
        if (token == null || token.isBlank()) return null;
        var rows = jdbc.query("select * from salud_u.consultar_desafio_segundo_factor(?)", (rs, i) -> new Challenge(
            rs.getObject("id_principal", UUID.class), rs.getString("correo"), rs.getString("proposito"), rs.getBytes("secreto_cifrado")),
            AuthenticationService.sha256(token));
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private Completion complete(String challengeToken, OptionalLong step, byte[] recoveryHash, byte[][] newHashes, byte[] reencrypted) {
        String sessionToken = AuthenticationService.newToken();
        Instant expiresAt = clock.instant().plus(properties.getSessionTtl());
        var rows = jdbc.query(
            "select * from salud_u.completar_desafio_segundo_factor(?, ?, ?, ?, ?, ?, ?)",
            ps -> {
                ps.setBytes(1, AuthenticationService.sha256(challengeToken));
                if (step.isPresent()) ps.setLong(2, step.getAsLong()); else ps.setNull(2, java.sql.Types.BIGINT);
                ps.setBytes(3, recoveryHash);
                if (newHashes == null) ps.setNull(4, java.sql.Types.ARRAY); else ps.setArray(4, ps.getConnection().createArrayOf("bytea", newHashes));
                ps.setBytes(5, AuthenticationService.sha256(sessionToken));
                ps.setObject(6, OffsetDateTime.ofInstant(expiresAt, ZoneOffset.UTC));
                ps.setBytes(7, reencrypted);
            },
            (rs, i) -> {
                String raw = rs.getString("estado");
                SessionPrincipal principal = "AUTENTICADO".equals(raw)
                    ? new SessionPrincipal(rs.getObject("id_principal", UUID.class), rs.getString("correo"), rs.getString("nombre_mostrado"), AuthenticationService.roles(rs))
                    : null;
                return new Completion(raw, principal == null ? null : new AuthenticatedSession(principal, sessionToken), rs.getString("metodo"));
            });
        return rows.isEmpty() ? new Completion("DESAFIO_INVALIDO", null, null) : rows.getFirst();
    }

    private record Challenge(UUID principalId, String email, String purpose, byte[] encryptedSecret) {
    }

    private record Completion(String rawStatus, AuthenticatedSession session, String method) {
        Status status() {
            return switch (rawStatus) {
                case "AUTENTICADO" -> Status.AUTHENTICATED;
                case "FALLIDO" -> Status.FAILED;
                case "BLOQUEADO", "EN_BLOQUEO" -> Status.LOCKED;
                default -> Status.CHALLENGE_INVALID;
            };
        }
    }

    private int remainingRecoveryCodes() {
        return jdbc.query("select codigos_disponibles from salud_u.consultar_mi_segundo_factor()", (rs, i) -> rs.getInt(1)).stream().findFirst().orElse(0);
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    private static List<String> newRecoveryCodes() {
        List<String> codes = new ArrayList<>(RECOVERY_CODES);
        for (int i = 0; i < RECOVERY_CODES; i++) codes.add(Totp.newRecoveryCode());
        return List.copyOf(codes);
    }

    private static byte[][] hashes(List<String> codes) {
        return codes.stream().map(SecondFactorService::recoveryHash).toArray(byte[][]::new);
    }

    /** SHA-256 del código normalizado: cada código tiene 120 bits aleatorios (ASVS 2.6.2 no exige sal por encima de 112). */
    static byte[] recoveryHash(String code) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(Totp.normalizeRecoveryCode(code).getBytes(StandardCharsets.US_ASCII));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 no está disponible en la JVM.", exception);
        }
    }
}

package bo.edu.uagrm.saludu.identity.application;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.OptionalLong;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * SEG-2FA: TOTP de la RFC 6238 con los parámetros que aceptan Google Authenticator, Microsoft Authenticator y FreeOTP:
 * HMAC-SHA1, 6 dígitos, paso de 30 segundos y ventana de ±1 paso. Solo javax.crypto.
 */
public final class Totp {
    public static final int DIGITS = 6;
    public static final long STEP_SECONDS = 30;
    public static final int WINDOW = 1;
    public static final int SECRET_BYTES = 20;
    private static final String BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    private static final SecureRandom RANDOM = new SecureRandom();

    private Totp() {
    }

    /** 160 bits aleatorios, el tamaño que recomienda la RFC 4226 para HMAC-SHA1. */
    public static byte[] newSecret() {
        byte[] secret = new byte[SECRET_BYTES];
        RANDOM.nextBytes(secret);
        return secret;
    }

    public static long step(long epochSeconds) {
        return Math.floorDiv(epochSeconds, STEP_SECONDS);
    }

    /** Código de {@code digits} dígitos del paso dado (truncamiento dinámico de la RFC 4226). */
    public static String code(byte[] secret, long step, int digits) {
        try {
            Mac mac = Mac.getInstance("HmacSHA1");
            mac.init(new SecretKeySpec(secret, "HmacSHA1"));
            byte[] hash = mac.doFinal(java.nio.ByteBuffer.allocate(8).putLong(step).array());
            int offset = hash[hash.length - 1] & 0x0f;
            int binary = ((hash[offset] & 0x7f) << 24) | ((hash[offset + 1] & 0xff) << 16) | ((hash[offset + 2] & 0xff) << 8) | (hash[offset + 3] & 0xff);
            int modulo = (int) Math.pow(10, digits);
            return String.format("%0" + digits + "d", binary % modulo);
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("HMAC-SHA1 no está disponible en la JVM.", exception);
        }
    }

    public static String code(byte[] secret, long step) {
        return code(secret, step, DIGITS);
    }

    /**
     * Paso que corresponde al código dentro de la ventana, o vacío. Compara en tiempo constante y revisa los tres pasos
     * siempre, para no revelar cuál coincidió. La anti-repetición (último paso usado) la aplica la base.
     */
    public static OptionalLong matchingStep(byte[] secret, String code, long epochSeconds) {
        if (code == null || !code.matches("\\d{" + DIGITS + "}")) {
            return OptionalLong.empty();
        }
        long current = step(epochSeconds);
        long found = -1;
        for (long candidate = current - WINDOW; candidate <= current + WINDOW; candidate++) {
            boolean equal = MessageDigest.isEqual(code(secret, candidate).getBytes(StandardCharsets.US_ASCII), code.getBytes(StandardCharsets.US_ASCII));
            if (equal && found < 0) {
                found = candidate;
            }
        }
        return found < 0 ? OptionalLong.empty() : OptionalLong.of(found);
    }

    /** Base32 de la RFC 4648 sin relleno, como lo esperan las aplicaciones de autenticación. */
    public static String base32(byte[] data) {
        StringBuilder result = new StringBuilder((data.length * 8 + 4) / 5);
        int buffer = 0, bits = 0;
        for (byte value : data) {
            buffer = (buffer << 8) | (value & 0xff);
            bits += 8;
            while (bits >= 5) {
                result.append(BASE32.charAt((buffer >> (bits - 5)) & 31));
                bits -= 5;
            }
        }
        if (bits > 0) {
            result.append(BASE32.charAt((buffer << (5 - bits)) & 31));
        }
        return result.toString();
    }

    public static String otpauthUri(String issuer, String account, byte[] secret) {
        String label = encode(issuer) + ":" + encode(account);
        return "otpauth://totp/" + label + "?secret=" + base32(secret) + "&issuer=" + encode(issuer)
            + "&algorithm=SHA1&digits=" + DIGITS + "&period=" + STEP_SECONDS;
    }

    /** Código de recuperación de 24 caracteres base32 (120 bits), en grupos de 4: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX. */
    public static String newRecoveryCode() {
        byte[] bytes = new byte[15];
        RANDOM.nextBytes(bytes);
        String raw = base32(bytes);
        return String.join("-", raw.substring(0, 4), raw.substring(4, 8), raw.substring(8, 12), raw.substring(12, 16), raw.substring(16, 20), raw.substring(20, 24));
    }

    /** Normaliza lo que escribe la persona (minúsculas, espacios o guiones) antes de calcular el hash. */
    public static String normalizeRecoveryCode(String value) {
        return value == null ? "" : value.toUpperCase(java.util.Locale.ROOT).replaceAll("[\\s-]", "");
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
    }
}

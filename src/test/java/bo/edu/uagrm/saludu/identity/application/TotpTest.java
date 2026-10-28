package bo.edu.uagrm.saludu.identity.application;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

/** SEG-2FA: TOTP contra los vectores del apéndice B de la RFC 6238 (SHA-1, secreto ASCII "12345678901234567890"). */
class TotpTest {
    private static final byte[] RFC_SECRET = "12345678901234567890".getBytes(StandardCharsets.US_ASCII);

    @ParameterizedTest(name = "T={0}s -> {1}")
    @CsvSource({
        "59, 94287082", "1111111109, 07081804", "1111111111, 14050471",
        "1234567890, 89005924", "2000000000, 69279037", "20000000000, 65353130"})
    void reproduceLosVectoresDeLaRfc6238ConOchoYConSeisDigitos(long seconds, String eightDigits) {
        assertEquals(eightDigits, Totp.code(RFC_SECRET, Totp.step(seconds), 8));
        // Con 6 dígitos el truncamiento es el mismo módulo 10^6: los últimos seis del vector.
        assertEquals(eightDigits.substring(2), Totp.code(RFC_SECRET, Totp.step(seconds)));
        assertEquals(Totp.step(seconds), Totp.matchingStep(RFC_SECRET, eightDigits.substring(2), seconds).orElseThrow());
    }

    @Test
    void aceptaUnPasoAntesYUnoDespuesPeroNoDos() {
        long now = 1_793_160_000L, step = Totp.step(now);
        for (long delta = -1; delta <= 1; delta++) {
            assertEquals(step + delta, Totp.matchingStep(RFC_SECRET, Totp.code(RFC_SECRET, step + delta), now).orElseThrow(), "delta " + delta);
        }
        assertTrue(Totp.matchingStep(RFC_SECRET, Totp.code(RFC_SECRET, step - 2), now).isEmpty());
        assertTrue(Totp.matchingStep(RFC_SECRET, Totp.code(RFC_SECRET, step + 2), now).isEmpty());
    }

    @Test
    void rechazaCodigosMalFormados() {
        for (String code : new String[] {null, "", "12345", "1234567", "12a456", " 287082"}) {
            assertTrue(Totp.matchingStep(RFC_SECRET, code, 59).isEmpty(), String.valueOf(code));
        }
    }

    @Test
    void base32SigueLaRfc4648YLaUriEsCompatibleConLasAplicaciones() {
        assertEquals("MZXW6YTBOI", Totp.base32("foobar".getBytes(StandardCharsets.US_ASCII)));
        assertEquals("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", Totp.base32(RFC_SECRET));
        assertEquals("otpauth://totp/Salud-U:medica%40demo.invalid?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Salud-U&algorithm=SHA1&digits=6&period=30",
            Totp.otpauthUri("Salud-U", "medica@demo.invalid", RFC_SECRET));
        assertEquals(20, Totp.newSecret().length);
    }

    @Test
    void losCodigosDeRecuperacionTienen120BitsYSeNormalizan() {
        String code = Totp.newRecoveryCode();
        assertTrue(code.matches("[A-Z2-7]{4}(-[A-Z2-7]{4}){5}"), code);
        assertEquals(code.replace("-", ""), Totp.normalizeRecoveryCode(" " + code.toLowerCase().replace("-", " ") + " "));
        assertNotEquals(Totp.newRecoveryCode(), Totp.newRecoveryCode());
    }
}

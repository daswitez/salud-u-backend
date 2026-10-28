package bo.edu.uagrm.saludu.identity.application;

import static org.junit.jupiter.api.Assertions.*;

import java.util.Base64;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

/** SEG-2FA: el secreto se guarda cifrado con AES-GCM, ligado a su cuenta, y se puede rotar la clave. */
class SecondFactorCipherTest {
    private static String key(int seed) {
        byte[] bytes = new byte[32];
        java.util.Arrays.fill(bytes, (byte) seed);
        return Base64.getEncoder().encodeToString(bytes);
    }

    private static SecondFactorCipher cipher(String current, String previous) {
        var properties = new AuthProperties();
        properties.setTotpKey(current);
        properties.setTotpPreviousKey(previous);
        return new SecondFactorCipher(properties);
    }

    @Test
    void cifraSinDejarElSecretoEnClaroYSoloLoDescifraParaLaMismaCuenta() {
        var cipher = cipher(key(1), null);
        UUID owner = UUID.randomUUID();
        byte[] secret = Totp.newSecret();
        byte[] stored = cipher.encrypt(owner, secret);
        assertEquals(1 + 12 + 20 + 16, stored.length);
        assertFalse(Base64.getEncoder().encodeToString(stored).contains(Base64.getEncoder().encodeToString(secret)));
        assertArrayEquals(secret, cipher.decrypt(owner, stored).secret());
        assertFalse(cipher.decrypt(owner, stored).needsReencryption());
        assertFalse(java.util.Arrays.equals(stored, cipher.encrypt(owner, secret)), "IV aleatorio en cada cifrado");
        assertThrows(IllegalStateException.class, () -> cipher.decrypt(UUID.randomUUID(), stored));
        stored[20] ^= 1;
        assertThrows(IllegalStateException.class, () -> cipher.decrypt(owner, stored), "GCM detecta la alteración");
    }

    @Test
    void conLaClaveAnteriorDescifraYPideVolverACifrar() {
        UUID owner = UUID.randomUUID();
        byte[] secret = Totp.newSecret();
        byte[] old = cipher(key(1), null).encrypt(owner, secret);
        var rotated = cipher(key(2), key(1));
        var decrypted = rotated.decrypt(owner, old);
        assertArrayEquals(secret, decrypted.secret());
        assertTrue(decrypted.needsReencryption());
        assertThrows(IllegalStateException.class, () -> cipher(key(2), null).decrypt(owner, old));
    }

    @Test
    void sinClaveNoArrancaSiHayRolesConSegundoFactorYRechazaClavesInvalidas() {
        var properties = new AuthProperties();
        properties.setSecondFactorRoles(List.of("REVIEW_DOCTOR"));
        assertThrows(IllegalStateException.class, () -> new SecondFactorCipher(properties));
        assertDoesNotThrow(() -> new SecondFactorCipher(new AuthProperties()));
        assertThrows(IllegalStateException.class, () -> cipher("no-es-base64!", null));
        assertThrows(IllegalStateException.class, () -> cipher(Base64.getEncoder().encodeToString(new byte[16]), null));
    }
}

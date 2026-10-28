package bo.edu.uagrm.saludu.identity.application;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.UUID;
import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.stereotype.Component;

/**
 * SEG-2FA: cifra el secreto TOTP con AES-256-GCM. La clave llega en SALUD_U_TOTP_KEY (Base64 de 32 bytes) y nunca está
 * en el repositorio ni en la base. Formato guardado: [huella de la clave (1 byte)][IV (12)][cifrado + etiqueta (36)].
 * El identificador del principal va como dato asociado: un secreto copiado a otra cuenta no se descifra.
 *
 * <p>Rotación: con SALUD_U_TOTP_KEY_ANTERIOR también se descifra lo cifrado con la clave anterior; el servicio lo vuelve a
 * cifrar con la vigente en el siguiente ingreso correcto.
 */
@Component
public class SecondFactorCipher {
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;
    private final Key current;
    private final Key previous;

    public SecondFactorCipher(AuthProperties properties) {
        this.current = Key.parse(properties.getTotpKey(), "SALUD_U_TOTP_KEY");
        this.previous = Key.parse(properties.getTotpPreviousKey(), "SALUD_U_TOTP_KEY_ANTERIOR");
        if (current == null && !properties.getSecondFactorRoles().isEmpty()) {
            throw new IllegalStateException("Define SALUD_U_TOTP_KEY (Base64 de 32 bytes): hay roles que exigen segundo factor.");
        }
    }

    public byte[] encrypt(UUID principalId, byte[] secret) {
        Key key = requireCurrent();
        byte[] iv = new byte[IV_BYTES];
        RANDOM.nextBytes(iv);
        try {
            Cipher cipher = cipher(Cipher.ENCRYPT_MODE, key, iv, principalId);
            byte[] encrypted = cipher.doFinal(secret);
            return ByteBuffer.allocate(1 + IV_BYTES + encrypted.length).put(key.fingerprint()).put(iv).put(encrypted).array();
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("No se pudo cifrar el secreto del segundo factor.", exception);
        }
    }

    /** Secreto en claro y si se descifró con la clave anterior (hay que volver a cifrarlo). */
    public Decrypted decrypt(UUID principalId, byte[] stored) {
        if (stored == null || stored.length < 1 + IV_BYTES + 16) {
            throw new IllegalStateException("El secreto del segundo factor no tiene un formato válido.");
        }
        byte[] iv = java.util.Arrays.copyOfRange(stored, 1, 1 + IV_BYTES);
        byte[] encrypted = java.util.Arrays.copyOfRange(stored, 1 + IV_BYTES, stored.length);
        List<Key> candidates = new ArrayList<>();
        for (Key key : new Key[] {current, previous}) {
            if (key != null && key.fingerprint() == stored[0]) candidates.add(key);
        }
        for (Key key : new Key[] {current, previous}) {
            if (key != null && !candidates.contains(key)) candidates.add(key);
        }
        for (Key key : candidates) {
            try {
                byte[] secret = cipher(Cipher.DECRYPT_MODE, key, iv, principalId).doFinal(encrypted);
                return new Decrypted(secret, key != current);
            } catch (AEADBadTagException wrongKey) {
                // Otra clave o dato alterado: se prueba la siguiente.
            } catch (GeneralSecurityException exception) {
                throw new IllegalStateException("No se pudo descifrar el secreto del segundo factor.", exception);
            }
        }
        throw new IllegalStateException("Ninguna clave configurada descifra el secreto del segundo factor.");
    }

    private Key requireCurrent() {
        if (current == null) throw new IllegalStateException("Falta SALUD_U_TOTP_KEY.");
        return current;
    }

    private static Cipher cipher(int mode, Key key, byte[] iv, UUID principalId) throws GeneralSecurityException {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, new SecretKeySpec(key.bytes(), "AES"), new GCMParameterSpec(TAG_BITS, iv));
        cipher.updateAAD(principalId.toString().getBytes(StandardCharsets.US_ASCII));
        return cipher;
    }

    public record Decrypted(byte[] secret, boolean needsReencryption) {
    }

    private record Key(byte[] bytes, byte fingerprint) {
        static Key parse(String base64, String name) {
            if (base64 == null || base64.isBlank()) return null;
            byte[] bytes;
            try {
                bytes = Base64.getDecoder().decode(base64.trim());
            } catch (IllegalArgumentException exception) {
                throw new IllegalStateException(name + " debe estar en Base64.");
            }
            if (bytes.length != 32) throw new IllegalStateException(name + " debe tener 32 bytes (AES-256).");
            try {
                return new Key(bytes, MessageDigest.getInstance("SHA-256").digest(bytes)[0]);
            } catch (GeneralSecurityException exception) {
                throw new IllegalStateException("SHA-256 no está disponible en la JVM.", exception);
            }
        }
    }
}

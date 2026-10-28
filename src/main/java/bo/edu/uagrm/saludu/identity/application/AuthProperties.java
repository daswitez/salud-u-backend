package bo.edu.uagrm.saludu.identity.application;

import java.time.Duration;
import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "salud-u.auth")
public class AuthProperties {
    private Duration sessionTtl = Duration.ofHours(8);
    private boolean cookieSecure = true;
    /** SEG-2FA: roles (códigos de API) que deben verificar un segundo factor. Vacío por defecto; application.yml lo define. */
    private List<String> secondFactorRoles = List.of();
    private Duration secondFactorChallengeTtl = Duration.ofMinutes(5);
    private String totpKey;
    private String totpPreviousKey;

    public Duration getSessionTtl() {
        return sessionTtl;
    }

    public void setSessionTtl(Duration sessionTtl) {
        this.sessionTtl = sessionTtl;
    }

    public boolean isCookieSecure() {
        return cookieSecure;
    }

    public void setCookieSecure(boolean cookieSecure) {
        this.cookieSecure = cookieSecure;
    }

    public List<String> getSecondFactorRoles() {
        return secondFactorRoles;
    }

    public void setSecondFactorRoles(List<String> secondFactorRoles) {
        this.secondFactorRoles = secondFactorRoles == null ? List.of() : secondFactorRoles.stream().map(String::trim).filter(role -> !role.isEmpty()).toList();
    }

    public Duration getSecondFactorChallengeTtl() {
        return secondFactorChallengeTtl;
    }

    public void setSecondFactorChallengeTtl(Duration secondFactorChallengeTtl) {
        this.secondFactorChallengeTtl = secondFactorChallengeTtl;
    }

    public String getTotpKey() {
        return totpKey;
    }

    public void setTotpKey(String totpKey) {
        this.totpKey = totpKey;
    }

    public String getTotpPreviousKey() {
        return totpPreviousKey;
    }

    public void setTotpPreviousKey(String totpPreviousKey) {
        this.totpPreviousKey = totpPreviousKey;
    }
}

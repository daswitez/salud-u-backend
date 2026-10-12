package bo.edu.uagrm.saludu.identity.api;

import bo.edu.uagrm.saludu.identity.application.ProfileService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionCookieService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/profile")
@PreAuthorize("isAuthenticated()")
public class ProfileController {
    private final ProfileService profileService;
    private final SessionCookieService cookies;

    public ProfileController(ProfileService profileService, SessionCookieService cookies) {
        this.profileService = profileService;
        this.cookies = cookies;
    }

    @PatchMapping
    public ResponseEntity<Void> update(
        @Valid @RequestBody ProfileUpdateRequest request,
        @AuthenticationPrincipal SessionPrincipal principal,
        HttpServletResponse response
    ) {
        profileService.updateProfile(principal, request.displayName(), request.email(), request.currentPassword());
        cookies.clear(response);
        return ResponseEntity.noContent().cacheControl(CacheControl.noStore()).build();
    }

    @PostMapping("/password")
    public ResponseEntity<Void> changePassword(
        @Valid @RequestBody PasswordChangeRequest request,
        @AuthenticationPrincipal SessionPrincipal principal,
        HttpServletResponse response
    ) {
        profileService.changePassword(principal, request.currentPassword(), request.newPassword());
        cookies.clear(response);
        return ResponseEntity.noContent().cacheControl(CacheControl.noStore()).build();
    }
}

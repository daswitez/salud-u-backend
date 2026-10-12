package bo.edu.uagrm.saludu.catalogs.api;

import bo.edu.uagrm.saludu.catalogs.application.CatalogService;
import bo.edu.uagrm.saludu.catalogs.application.AdministrativePrincipal;
import bo.edu.uagrm.saludu.catalogs.application.StaffMember;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiEnvelope;
import jakarta.validation.Valid;
import java.util.Map;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/admin")
@PreAuthorize("hasRole('ADMINISTRATIVE')")
public class AdministrationController {
    private final CatalogService catalogService;

    public AdministrationController(CatalogService catalogService) {
        this.catalogService = catalogService;
    }

    @org.springframework.web.bind.annotation.GetMapping("/principals")
    public ApiEnvelope<List<AdministrativePrincipal>> principals(@AuthenticationPrincipal SessionPrincipal principal) {
        return ApiEnvelope.success(catalogService.principals(principal));
    }

    @org.springframework.web.bind.annotation.GetMapping("/staff")
    public ApiEnvelope<List<StaffMember>> staff(@AuthenticationPrincipal SessionPrincipal principal) {
        return ApiEnvelope.success(catalogService.staff(principal));
    }

    @PostMapping("/principals")
    public ResponseEntity<ApiEnvelope<Map<String, UUID>>> createPrincipal(
        @Valid @RequestBody PrincipalCreateRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        UUID id = catalogService.createPrincipal(principal, request.email(), request.displayName(), request.password(), request.roles());
        return ResponseEntity.status(201).body(ApiEnvelope.success(Map.of("id", id)));
    }

    @PatchMapping("/principals/{principalId}/role")
    public ApiEnvelope<Void> setRole(
        @PathVariable UUID principalId, @Valid @RequestBody PrincipalRoleRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        catalogService.setPrincipalRole(principal, principalId, request.role(), request.active());
        return ApiEnvelope.success(null);
    }

    @PatchMapping("/principals/{principalId}/active")
    public ApiEnvelope<Void> setPrincipalActive(
        @PathVariable UUID principalId, @RequestBody PrincipalActiveRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        catalogService.setPrincipalActive(principal, principalId, request.active());
        return ApiEnvelope.success(null);
    }

    @PostMapping("/staff")
    public ResponseEntity<ApiEnvelope<Map<String, UUID>>> upsertStaff(
        @Valid @RequestBody StaffRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        UUID id = catalogService.upsertStaff(principal, request.principalId(), request.staffCode(), request.active());
        return ResponseEntity.ok(ApiEnvelope.success(Map.of("id", id)));
    }

    @PostMapping("/staff/specialties")
    public ApiEnvelope<Void> assignStaffSpecialty(
        @Valid @RequestBody StaffSpecialtyRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        catalogService.assignStaffSpecialty(principal, request.staffMemberId(), request.specialtyId(), request.activeFrom(), request.activeTo());
        return ApiEnvelope.success(null);
    }
}

package bo.edu.uagrm.saludu.catalogs.api;

import bo.edu.uagrm.saludu.catalogs.application.CatalogItem;
import bo.edu.uagrm.saludu.catalogs.application.CatalogKind;
import bo.edu.uagrm.saludu.catalogs.application.CatalogService;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.api.ApiEnvelope;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class CatalogController {
    private final CatalogService catalogService;

    public CatalogController(CatalogService catalogService) {
        this.catalogService = catalogService;
    }

    @GetMapping("/api/careers")
    public LegacyCatalogResponse careers() {
        return new LegacyCatalogResponse(true, catalogService.list(CatalogKind.CAREER, null));
    }

    @GetMapping("/api/specialties")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR', 'SPECIALIST', 'ADMINISTRATIVE')")
    public LegacyCatalogResponse specialties(@AuthenticationPrincipal SessionPrincipal principal) {
        return new LegacyCatalogResponse(true, catalogService.list(CatalogKind.SPECIALTY, principal));
    }

    @GetMapping("/api/my-specialties")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR', 'SPECIALIST')")
    public LegacyCatalogResponse mySpecialties(@AuthenticationPrincipal SessionPrincipal principal) {
        return new LegacyCatalogResponse(true, catalogService.mySpecialties(principal));
    }

    @GetMapping("/api/v1/catalogs/{kind}")
    @PreAuthorize("hasAnyRole('REVIEW_DOCTOR', 'SPECIALIST', 'ADMINISTRATIVE')")
    public ApiEnvelope<List<CatalogItem>> list(@PathVariable CatalogKind kind, @AuthenticationPrincipal SessionPrincipal principal) {
        return ApiEnvelope.success(catalogService.list(kind, principal));
    }

    @PostMapping("/api/v1/admin/catalogs/{kind}")
    @PreAuthorize("hasRole('ADMINISTRATIVE')")
    public ResponseEntity<ApiEnvelope<CatalogItem>> save(
        @PathVariable CatalogKind kind, @Valid @RequestBody CatalogSaveRequest request, @AuthenticationPrincipal SessionPrincipal principal
    ) {
        UUID id = catalogService.saveCatalog(principal, kind, request.id(), request.code(), request.name(), request.active());
        return ResponseEntity.ok(ApiEnvelope.success(new CatalogItem(id, request.code().toUpperCase(), request.name().trim())));
    }
}

package bo.edu.uagrm.saludu.catalogs.application;

import java.util.UUID;

public record StaffMember(UUID id, UUID principalId, String email, String displayName, String staffCode, boolean active) {
}

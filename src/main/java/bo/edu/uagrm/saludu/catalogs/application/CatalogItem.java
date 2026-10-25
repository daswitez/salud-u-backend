package bo.edu.uagrm.saludu.catalogs.application;

import java.util.UUID;

public record CatalogItem(UUID id, String code, String name, boolean active) {
}

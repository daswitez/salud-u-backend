package bo.edu.uagrm.saludu.catalogs.api;

import bo.edu.uagrm.saludu.catalogs.application.CatalogItem;
import java.util.List;

public record LegacyCatalogResponse(boolean ok, List<CatalogItem> data) {
}

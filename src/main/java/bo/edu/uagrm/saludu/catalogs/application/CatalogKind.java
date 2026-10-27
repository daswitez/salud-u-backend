package bo.edu.uagrm.saludu.catalogs.application;

public enum CatalogKind {
    CAREER, SPECIALTY, CONDITION, MEASUREMENT, TAG, DOCUMENT_TYPE;

    public String auditResourceType() {
        return switch (this) {
            case CAREER -> "carrera";
            case SPECIALTY -> "especialidad";
            case CONDITION -> "condicion";
            case MEASUREMENT -> "tipo_medicion";
            case TAG -> "etiqueta";
            case DOCUMENT_TYPE -> "tipo_documento";
        };
    }
}

package bo.edu.uagrm.saludu.agenda.application;
/** Carries only a count; clinical rows and renderer details never enter the error contract. */
public class ClinicalReportGenerationFailure extends RuntimeException {
    private final int rowCount;
    public ClinicalReportGenerationFailure(int rowCount){super("No se pudo generar el archivo completo.");this.rowCount=rowCount;}
    public int rowCount(){return rowCount;}
}

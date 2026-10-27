package bo.edu.uagrm.saludu.agenda.application;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
public record ClinicalReportExportRequest(String format,String purpose,ClinicalReportQuery query) {
    public static ClinicalReportExportRequest parse(Map<String,Object> body,ObjectMapper json){
        if(!Set.of("format","purpose","filters","columns","groupBy").containsAll(body.keySet()))throw invalid("La exportación solo admite finalidad, formato, filtros, columnas y agrupaciones.");
        if(!(body.get("format") instanceof String format)||!Set.of("CSV","XLSX","PDF").contains(format)||!(body.get("purpose") instanceof String purpose)||purpose.trim().isEmpty()||purpose.trim().length()>300)throw invalid("Indica un formato válido y una finalidad de entre 1 y 300 caracteres.");
        if(!(body.get("filters") instanceof Map<?,?> filters))throw invalid("Filtros inválidos.");
        Set<String> listFields=Set.of("allergies","histories","habitTerms","positiveHabits");
        Set<String> scalars=Set.of("from","to","specialtyId","encounterType","diagnosis","search");
        Map<String,String> query=new LinkedHashMap<>();
        try{
            for(var entry:filters.entrySet()){
                if(!(entry.getKey() instanceof String key)||!listFields.contains(key)&&!scalars.contains(key))throw invalid("Filtros inválidos.");
                Object value=entry.getValue();if(value==null)continue;
                if(listFields.contains(key)){if(!(value instanceof List<?>))throw invalid("Lista de filtros inválida.");query.put(key,json.writeValueAsString(value));}
                else{if(!(value instanceof String text))throw invalid("Filtro inválido.");query.put(key,text);}
            }
            for(String field:List.of("columns","groupBy"))if(body.containsKey(field)){if(!(body.get(field) instanceof List<?>))throw invalid("Columnas o agrupaciones inválidas.");query.put(field,json.writeValueAsString(body.get(field)));}
        }catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw invalid("Solicitud de exportación inválida.");}
        return new ClinicalReportExportRequest(format,purpose.trim(),ClinicalReportQuery.parse(query,json));
    }
    private static AvailabilityException invalid(String text){return new AvailabilityException(400,text);}
}

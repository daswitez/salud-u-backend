package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;

public record ClinicalReportQuery(Map<String,Object> filters,List<String> columns,List<String> groupBy,boolean presentation) {
    public static final List<String> COLUMNS=List.of("closed_at","patient_name","carnet","encounter_type","specialty_name","diagnoses","allergies","background_summary","habits","chief_complaint","assessment","instructions","follow_up_text","birth_date","specialty_history","sex");
    public static ClinicalReportQuery parse(Map<String,String> q,ObjectMapper json){
        var filters=new LinkedHashMap<String,Object>();
        for(String field:List.of("from","to")){String value=q.get(field);try{filters.put(field,value==null||value.isBlank()?null:LocalDate.parse(value).toString());}catch(java.time.DateTimeException e){throw invalid("El período no es válido.");}}
        if(filters.get("from")!=null&&filters.get("to")!=null&&filters.get("from").toString().compareTo(filters.get("to").toString())>0)throw invalid("El período no es válido.");
        String area=text(q.get("specialtyId"),50);if(area!=null)try{UUID.fromString(area);}catch(IllegalArgumentException ex){throw invalid("Especialidad inválida.");}filters.put("specialtyId",area);
        String type=text(q.get("encounterType"),20);if(type!=null&&!Set.of("INITIAL","SPECIALTY").contains(type))throw invalid("Tipo de atención inválido.");filters.put("encounterType",type);
        String sex=text(q.get("sex"),20);if(sex!=null&&!Set.of("FEMALE","MALE","NOT_RECORDED").contains(sex))throw invalid("Sexo inválido.");filters.put("sex",sex);
        filters.put("diagnosis",text(q.get("diagnosis"),200));
        for(String field:List.of("allergies","histories","habitTerms","positiveHabits"))filters.put(field,list(q.get(field),15,json));
        if(((List<?>)filters.get("positiveHabits")).stream().anyMatch(h->!List.of("tobacco","alcohol","physicalActivity").contains(h)))throw invalid("Hábito inválido.");
        filters.put("search",text(q.get("search"),200));
        List<String> columns=q.containsKey("columns")?list(q.get("columns"),COLUMNS.size(),json):COLUMNS,group=list(q.get("groupBy"),2,json);
        if(columns.isEmpty()||!COLUMNS.containsAll(columns))throw invalid("Selecciona columnas válidas.");
        if(!List.of("day","month","encounterType","specialty","sex").containsAll(group)||group.contains("day")&&group.contains("month"))throw invalid("Agrupación inválida.");
        return new ClinicalReportQuery(filters,columns,group,q.containsKey("columns")||q.containsKey("groupBy"));
    }
    private static String text(String value,int max){if(value==null||value.isBlank())return null;String v=value.trim();if(v.length()>max)throw invalid("El filtro supera el límite permitido.");return v;}
    private static List<String> list(String source,int max,ObjectMapper json){
        if(source==null||source.isBlank())return List.of();
        try{var node=json.readTree(source);if(!node.isArray()||node.size()>max)throw invalid("Lista de filtros inválida.");var list=new LinkedHashSet<String>();for(var value:node){if(!value.isTextual())throw invalid("Lista de filtros inválida.");String v=text(value.asText(),200);if(v!=null)list.add(v);}return List.copyOf(list);}catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw invalid("Lista de filtros inválida.");}
    }
    public Map<String,Object> presentation(List<Map<String,Object>> rows){
        var grouped=new LinkedHashMap<List<Object>,List<UUID>>();
        for(var row:rows){List<Object> key=new ArrayList<>();for(String dimension:groupBy){var closed=((OffsetDateTime)row.get("closed_at")).atZoneSameInstant(ZoneId.of("America/La_Paz"));key.add(switch(dimension){case "day"->closed.toLocalDate().toString();case "month"->YearMonth.from(closed).toString();case "encounterType"->row.get("encounter_type");case "sex"->row.get("sex");default->row.get("specialty_name");});}if(!groupBy.isEmpty())grouped.computeIfAbsent(key,k->new ArrayList<>()).add((UUID)row.get("encounter_id"));}
        var groups=new ArrayList<Map<String,Object>>();grouped.forEach((key,ids)->groups.add(Map.of("key",key,"count",ids.size(),"encounterIds",ids)));
        return Map.of("columns",columns,"groupBy",groupBy,"groups",groups);
    }
    private static AvailabilityException invalid(String message){return new AvailabilityException(400,message);}
}

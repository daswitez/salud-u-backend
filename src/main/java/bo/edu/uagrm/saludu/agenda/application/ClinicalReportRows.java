package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.*;
import java.time.*;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;

/** One mapping for the report screen and the export recalculated by PostgreSQL. */
public final class ClinicalReportRows {
    private ClinicalReportRows() {}
    public static List<Map<String,Object>> load(JdbcTemplate jdbc,ObjectMapper json,Map<String,Object> filters,int limit) throws com.fasterxml.jackson.core.JsonProcessingException {
        return jdbc.query("select * from salud_u.reporte_clinico_detallado(cast(? as jsonb))"+(limit>0?" limit "+limit:""),(r,n)->map(r,json),json.writeValueAsString(filters));
    }
    private static Map<String,Object> map(ResultSet r,ObjectMapper json) throws SQLException {
        Map<String,Object> row=new LinkedHashMap<>();row.put("encounter_id",r.getObject("id_encuentro",UUID.class));row.put("closed_at",r.getObject("cerrado_en",OffsetDateTime.class));row.put("patient_id",r.getObject("id_paciente",UUID.class));row.put("birth_date",r.getObject("fecha_nacimiento",LocalDate.class));
        Map<String,String> columns=Map.ofEntries(Map.entry("encounter_type","tipo_encuentro"), Map.entry("specialty_name","nombre_especialidad"), Map.entry("carnet","carnet"), Map.entry("patient_name","nombre_paciente"), Map.entry("chief_complaint","motivo_consulta"), Map.entry("assessment","evaluacion"), Map.entry("instructions","indicaciones"), Map.entry("follow_up_text","seguimiento"), Map.entry("diagnoses","diagnosticos"), Map.entry("allergies","alergias"), Map.entry("background_summary","resumen_antecedentes"), Map.entry("sex","sexo"));
        for(var column:columns.entrySet())row.put(column.getKey(),r.getString(column.getValue()));
        try{row.put("habits",json.readTree(r.getString("habitos")));String specific=r.getString("ficha_especialidad");row.put("specialty_history",specific==null?null:json.readTree(specific));}catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new IllegalStateException(ex);}return row;
    }
}

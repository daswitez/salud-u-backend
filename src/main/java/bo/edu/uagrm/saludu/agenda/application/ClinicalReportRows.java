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
        Map<String,Object> row=new LinkedHashMap<>();row.put("encounter_id",r.getObject("encounter_id",UUID.class));row.put("closed_at",r.getObject("closed_at",OffsetDateTime.class));row.put("patient_id",r.getObject("patient_id",UUID.class));row.put("birth_date",r.getObject("birth_date",LocalDate.class));
        for(String key:List.of("encounter_type","specialty_name","carnet","patient_name","chief_complaint","assessment","instructions","follow_up_text","diagnoses","allergies","background_summary"))row.put(key,r.getString(key));
        try{row.put("habits",json.readTree(r.getString("habits")));String specific=r.getString("specialty_history");row.put("specialty_history",specific==null?null:json.readTree(specific));}catch(com.fasterxml.jackson.core.JsonProcessingException ex){throw new IllegalStateException(ex);}return row;
    }
}

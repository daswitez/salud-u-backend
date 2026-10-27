package bo.edu.uagrm.saludu.agenda.application;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import java.time.OffsetDateTime;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
class ClinicalReportQueryTest {
 @Test void groupsUseBoliviaDatesNullAndStableRowOrder(){
  var q=ClinicalReportQuery.parse(Map.of("columns","[\"patient_name\"]","groupBy","[\"day\",\"specialty\"]"),new ObjectMapper());
  UUID first=UUID.randomUUID(),second=UUID.randomUUID(),third=UUID.randomUUID();
  var rows=new ArrayList<Map<String,Object>>();for(var id:List.of(first,second,third)){Map<String,Object> row=new HashMap<>();row.put("encounter_id",id);row.put("closed_at",OffsetDateTime.parse(id.equals(third)?"2026-10-26T04:00:00Z":"2026-10-26T03:59:59Z"));row.put("specialty_name",null);rows.add(row);}
  var presentation=q.presentation(rows);var groups=(List<Map<String,Object>>)presentation.get("groups");assertEquals(2,groups.size());assertEquals(Arrays.asList("2026-10-25",null),groups.getFirst().get("key"));assertEquals(List.of(first,second),groups.getFirst().get("encounterIds"));assertEquals(2,groups.getFirst().get("count"));
 }
 @Test void listsAreTypedTrimmedAndCanonical(){var q=ClinicalReportQuery.parse(Map.of("allergies","[\"  asma \",\"asma\",\"\"]"),new ObjectMapper());assertEquals(List.of("asma"),q.filters().get("allergies"));assertNull(q.filters().get("specialtyId"));assertFalse(q.presentation());}
}

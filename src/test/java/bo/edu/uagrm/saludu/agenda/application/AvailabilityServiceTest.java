package bo.edu.uagrm.saludu.agenda.application;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import com.fasterxml.jackson.databind.*;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowCallbackHandler;

class AvailabilityServiceTest {
 @Test void persistedSpanishScheduleIsReturnedInTheLegacyManagementContract() throws Exception {
  var jdbc=mock(JdbcTemplate.class);var mapper=new ObjectMapper();var actor=mock(DatabaseActorContext.class);
  doAnswer(call->{RowCallbackHandler handler=call.getArgument(1);
   for(var row:Map.of("horarios","[{\"dia_semana\":1,\"id_especialidad\":null,\"inicia_a\":\"08:00:00\",\"termina_a\":\"09:00:00\",\"duracion_cupo_minutos\":30}]","recurrenteBlocks","[{\"dia_semana\":1,\"etiqueta\":\"Pausa\"}]","dateBlocks","[{\"fecha_bloqueo\":\"2026-10-26\",\"inicia_a\":null}]","cupos","[{\"estado\":\"PUBLISHED\",\"capacidad\":1,\"cantidad_reservada\":0}]").entrySet()) {
    var rs=mock(ResultSet.class);when(rs.getString("kind")).thenReturn(row.getKey());when(rs.getString("payload")).thenReturn(row.getValue());handler.processRow(rs);
   }return null;
  }).when(jdbc).query(anyString(),any(RowCallbackHandler.class),any(LocalDate.class),any(LocalDate.class));
  var service=new AvailabilityService(jdbc,actor,mock(AuditWriter.class),mapper);
  var principal=mock(SessionPrincipal.class);when(principal.id()).thenReturn(UUID.randomUUID());when(principal.roles()).thenReturn(List.of("REVIEW_DOCTOR"));
  var result=service.management(principal,LocalDate.parse("2026-10-26"),LocalDate.parse("2026-10-26"));
  assertEquals(Set.of("schedules","recurringBlocks","dateBlocks","slots","appointments"),result.keySet());
  var schedule=((JsonNode)result.get("schedules")).get(0);assertEquals(1,schedule.path("weekday").asInt());assertEquals("08:00:00",schedule.path("starts_at").asText());assertEquals(30,schedule.path("slot_duration_minutes").asInt());assertTrue(schedule.path("specialty_id").isNull());assertFalse(schedule.has("dia_semana"));
  assertEquals("Pausa",((JsonNode)result.get("recurringBlocks")).get(0).path("label").asText());
  assertEquals("2026-10-26",((JsonNode)result.get("dateBlocks")).get(0).path("block_date").asText());
  var slot=((JsonNode)result.get("slots")).get(0);assertEquals("PUBLISHED",slot.path("status").asText());assertEquals(0,slot.path("booked_count").asInt());
 }
}

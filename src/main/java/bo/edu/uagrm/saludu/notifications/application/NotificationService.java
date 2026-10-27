package bo.edu.uagrm.saludu.notifications.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

@Service
public class NotificationService {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;

    public NotificationService(JdbcTemplate jdbc, DatabaseActorContext actorContext) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public NotificationPage list(SessionPrincipal principal, int limit, OffsetDateTime before, UUID beforeId) {
        apply(principal);
        List<Notification> rows = jdbc.query("select * from salud_u.listar_mis_notificaciones(?,?,?)",
            (rs, n) -> notification(rs), limit + 1, before, beforeId);
        boolean hasMore = rows.size() > limit;
        if (hasMore) rows = List.copyOf(rows.subList(0, limit));
        String cursor = hasMore ? rows.getLast().deliveredAt() + "|" + rows.getLast().id() : null;
        long unread = jdbc.queryForObject("select salud_u.contar_mis_notificaciones_no_leidas()", Long.class);
        return new NotificationPage(true, rows, new NotificationPage.Pagination(hasMore, cursor), unread);
    }

    @Transactional
    public Notification markRead(SessionPrincipal principal, UUID id) {
        apply(principal);
        return jdbc.query("select * from salud_u.marcar_mi_notificacion_leida(?)", (rs, n) -> notification(rs), id)
            .stream().findFirst().orElseThrow(() -> new AvailabilityException(404, "Notificación no encontrada."));
    }

    @Transactional(readOnly = true)
    public NotificationPreferences preferences(SessionPrincipal principal) {
        apply(principal);
        return jdbc.queryForObject("select * from salud_u.obtener_mis_preferencias_notificacion()", (rs, n) -> preferences(rs));
    }

    @Transactional
    public NotificationPreferences savePreferences(SessionPrincipal principal, boolean receiveReminders, boolean reinforcedReminder) {
        apply(principal);
        return jdbc.queryForObject("select * from salud_u.guardar_mis_preferencias_notificacion(?,?)",
            (rs, n) -> preferences(rs), receiveReminders, reinforcedReminder);
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    private static Notification notification(ResultSet rs) throws SQLException {
        return new Notification(rs.getObject("id", UUID.class), rs.getObject("id_cita", UUID.class),
            rs.getString("tipo_evento"), rs.getString("canal"), rs.getString("asunto"), rs.getString("mensaje"),
            rs.getString("estado"), rs.getObject("programada_para", OffsetDateTime.class),
            rs.getObject("entregada_en", OffsetDateTime.class), rs.getObject("leida_en", OffsetDateTime.class),
            rs.getObject("creado_en", OffsetDateTime.class));
    }

    private static NotificationPreferences preferences(ResultSet rs) throws SQLException {
        return new NotificationPreferences(rs.getBoolean("recibir_recordatorios"), rs.getBoolean("recordatorio_reforzado"),
            rs.getObject("actualizado_en", OffsetDateTime.class));
    }
}

package bo.edu.uagrm.saludu.scheduling.application;

import bo.edu.uagrm.saludu.agenda.application.AvailabilityException;
import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** O-01: calendario académico y valores iniciales de la agenda. Las funciones SQL exigen el rol ADMINISTRATIVO. */
@Service
public class SchedulingSetupService {
    private final JdbcTemplate jdbc;
    private final DatabaseActorContext actorContext;

    public SchedulingSetupService(JdbcTemplate jdbc, DatabaseActorContext actorContext) {
        this.jdbc = jdbc;
        this.actorContext = actorContext;
    }

    @Transactional(readOnly = true)
    public List<AcademicPeriod> periods(SessionPrincipal principal) {
        apply(principal);
        return guarded(() -> jdbc.query("select * from salud_u.listar_periodos_academicos()", (rs, n) -> period(rs)));
    }

    @Transactional
    public AcademicPeriod registerPeriod(SessionPrincipal principal, String name, String type, LocalDate startDate, LocalDate endDate) {
        apply(principal);
        return guarded(() -> jdbc.queryForObject("select * from salud_u.registrar_periodo_academico(?,?,?,?)",
            (rs, n) -> period(rs), name, type, startDate, endDate));
    }

    @Transactional(readOnly = true)
    public List<InitialSchedulingValue> initialValues(SessionPrincipal principal) {
        apply(principal);
        return guarded(this::listValues);
    }

    /** valuesJson es el arreglo con claves internas que arma el controlador; se guarda todo o nada. */
    @Transactional
    public List<InitialSchedulingValue> saveInitialValues(SessionPrincipal principal, String valuesJson) {
        apply(principal);
        return guarded(() -> {
            jdbc.queryForObject("select salud_u.guardar_valores_iniciales_agenda(cast(? as jsonb))", Integer.class, valuesJson);
            return listValues();
        });
    }

    private List<InitialSchedulingValue> listValues() {
        return jdbc.query("select * from salud_u.listar_valores_iniciales_agenda()", (rs, n) -> new InitialSchedulingValue(
            rs.getObject("id_especialidad", UUID.class), rs.getString("nombre_especialidad"), rs.getString("tipo_periodo"),
            rs.getBigDecimal("demanda_diaria_esperada"), rs.getBigDecimal("asistencia_esperada"), rs.getInt("peso_citas"),
            rs.getBoolean("predeterminado"), rs.getObject("actualizado_en", OffsetDateTime.class)));
    }

    private void apply(SessionPrincipal principal) {
        actorContext.apply(new DatabaseActor(principal.id(), Set.copyOf(principal.roles())));
    }

    private static <T> T guarded(java.util.function.Supplier<T> query) {
        try { return query.get(); }
        catch (DataAccessException exception) { throw translate(exception); }
    }

    private static RuntimeException translate(DataAccessException exception) {
        String message = String.valueOf(exception.getMostSpecificCause().getMessage());
        if (message.contains("Se requiere el rol ADMINISTRATIVO")) return new AvailabilityException(403, "Solo Administración puede configurar el calendario y los valores iniciales.");
        if (message.contains("PERIODO_ACADEMICO_SOLAPADO")) return new AvailabilityException(409, "El período se superpone con otro ya registrado.");
        if (message.contains("PERIODO_ACADEMICO_INVALIDO")) return new AvailabilityException(400, "Revisa el nombre, el tipo y las fechas del período.");
        if (message.contains("VALORES_INICIALES_DUPLICADOS")) return new AvailabilityException(400, "Cada especialidad y tipo de período puede aparecer una sola vez.");
        if (message.contains("ESPECIALIDAD_NO_HABILITADA")) return new AvailabilityException(400, "La especialidad no existe o no está habilitada.");
        if (message.contains("VALORES_INICIALES_INVALIDOS")) return new AvailabilityException(400, "Los valores iniciales no son válidos.");
        return exception;
    }

    private static AcademicPeriod period(ResultSet rs) throws SQLException {
        return new AcademicPeriod(rs.getObject("id", UUID.class), rs.getString("nombre"), rs.getString("tipo"),
            rs.getObject("fecha_inicio", LocalDate.class), rs.getObject("fecha_fin", LocalDate.class),
            rs.getObject("creado_en", OffsetDateTime.class));
    }
}

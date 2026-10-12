package bo.edu.uagrm.saludu.catalogs.application;

import bo.edu.uagrm.saludu.identity.infrastructure.SessionPrincipal;
import bo.edu.uagrm.saludu.governance.application.AuditWriter;
import bo.edu.uagrm.saludu.governance.domain.AuditOutcome;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActor;
import bo.edu.uagrm.saludu.shared.persistence.DatabaseActorContext;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class CatalogService {
    private final JdbcTemplate jdbcTemplate;
    private final DatabaseActorContext actorContext;
    private final AuditWriter auditWriter;

    public CatalogService(JdbcTemplate jdbcTemplate, DatabaseActorContext actorContext, AuditWriter auditWriter) {
        this.jdbcTemplate = jdbcTemplate;
        this.actorContext = actorContext;
        this.auditWriter = auditWriter;
    }

    @Transactional(readOnly = true)
    public List<CatalogItem> list(CatalogKind kind, SessionPrincipal principal) {
        apply(principal);
        return jdbcTemplate.query("select * from salud_u.listar_catalogo(?)", (resultSet, rowNumber) ->
            new CatalogItem(resultSet.getObject("id", UUID.class), resultSet.getString("codigo"), resultSet.getString("nombre")), kind.name());
    }

    @Transactional(readOnly = true)
    public List<CatalogItem> mySpecialties(SessionPrincipal principal) {
        apply(principal);
        return jdbcTemplate.query("select * from salud_u.listar_mis_especialidades()", (resultSet, rowNumber) ->
            new CatalogItem(resultSet.getObject("id", UUID.class), resultSet.getString("codigo"), resultSet.getString("nombre")));
    }

    @Transactional
    public UUID saveCatalog(SessionPrincipal principal, CatalogKind kind, UUID id, String code, String name, boolean active) {
        apply(principal);
        UUID savedId = jdbcTemplate.queryForObject("select salud_u.guardar_catalogo_administracion(?, ?, ?, ?, ?)", UUID.class, kind.name(), id, code, name, active);
        auditWriter.append("CATALOG_SAVED", kind.name(), savedId, AuditOutcome.SUCCESS, Map.of("active", active, "code", code));
        return savedId;
    }

    @Transactional
    public UUID createPrincipal(SessionPrincipal principal, String email, String displayName, String password, List<String> roles) {
        apply(principal);
        UUID savedId = jdbcTemplate.queryForObject(
            "select salud_u.crear_principal_administrativo(?, ?, ?, ?)", UUID.class, email, displayName, password,
            String.join(",", roles.stream().distinct().toList())
        );
        auditWriter.append("PRINCIPAL_CREATED", "principal", savedId, AuditOutcome.SUCCESS, Map.of("roles", roles.stream().distinct().toList()));
        return savedId;
    }

    @Transactional
    public void setPrincipalRole(SessionPrincipal principal, UUID principalId, String role, boolean active) {
        apply(principal);
        jdbcTemplate.query("select salud_u.establecer_rol_principal(?, ?, ?)", resultSet -> {}, principalId, role, active);
        auditWriter.append("PRINCIPAL_ROLE_CHANGED", "principal", principalId, AuditOutcome.SUCCESS, Map.of("role", role, "active", active));
    }

    @Transactional
    public void setPrincipalActive(SessionPrincipal principal, UUID principalId, boolean active) {
        apply(principal);
        jdbcTemplate.query("select salud_u.establecer_principal_activo(?, ?)", resultSet -> {}, principalId, active);
        auditWriter.append("PRINCIPAL_ACTIVE_CHANGED", "principal", principalId, AuditOutcome.SUCCESS, Map.of("active", active));
    }

    @Transactional
    public UUID upsertStaff(SessionPrincipal principal, UUID principalId, String staffCode, boolean active) {
        apply(principal);
        UUID savedId = jdbcTemplate.queryForObject("select salud_u.guardar_personal(?, ?, ?)", UUID.class, principalId, staffCode, active);
        auditWriter.append("STAFF_SAVED", "staff_member", savedId, AuditOutcome.SUCCESS, Map.of("active", active));
        return savedId;
    }

    @Transactional
    public void assignStaffSpecialty(SessionPrincipal principal, UUID staffMemberId, UUID specialtyId, LocalDate activeFrom, LocalDate activeTo) {
        apply(principal);
        jdbcTemplate.query("select salud_u.asignar_especialidad_personal(?, ?, ?, ?)", resultSet -> {}, staffMemberId, specialtyId, activeFrom, activeTo);
        auditWriter.append("STAFF_SPECIALTY_ASSIGNED", "staff_member", staffMemberId, AuditOutcome.SUCCESS, Map.of("specialtyId", specialtyId.toString()));
    }

    @Transactional(readOnly = true)
    public List<AdministrativePrincipal> principals(SessionPrincipal principal) {
        apply(principal);
        return jdbcTemplate.query("select * from salud_u.listar_principales_administracion()", (resultSet, rowNumber) -> {
            java.sql.Array roles = resultSet.getArray("roles");
            String[] values = roles == null ? new String[0] : (String[]) roles.getArray();
            return new AdministrativePrincipal(resultSet.getObject("id", UUID.class), resultSet.getString("email"), resultSet.getString("nombre_mostrado"), resultSet.getBoolean("activo"), List.of(values));
        });
    }

    @Transactional(readOnly = true)
    public List<StaffMember> staff(SessionPrincipal principal) {
        apply(principal);
        return jdbcTemplate.query("select * from salud_u.listar_personal_administracion()", (resultSet, rowNumber) ->
            new StaffMember(resultSet.getObject("id", UUID.class), resultSet.getObject("id_principal", UUID.class), resultSet.getString("email"), resultSet.getString("nombre_mostrado"), resultSet.getString("codigo_personal"), resultSet.getBoolean("activo")));
    }

    private void apply(SessionPrincipal principal) {
        if (principal != null) {
            actorContext.apply(new DatabaseActor(principal.id(), java.util.Set.copyOf(principal.roles())));
        }
    }
}

package bo.edu.uagrm.saludu.shared.persistence;

import java.util.Comparator;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@Component
public class DatabaseActorContext {
    private final JdbcTemplate jdbcTemplate;

    public DatabaseActorContext(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Stores the authenticated actor only for the current PostgreSQL transaction.
     * SET LOCAL is cleared at commit or rollback, including when a pooled connection
     * is returned to Hikari.
     */
    public void apply(DatabaseActor actor) {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) {
            throw new IllegalStateException("El contexto de actor requiere una transacción activa.");
        }
        var roles = actor.roles().stream().sorted(Comparator.naturalOrder()).reduce((left, right) -> left + "," + right).orElse("");
        jdbcTemplate.queryForObject("select set_config('salud_u.id_actor', ?, true)", String.class, actor.id().toString());
        jdbcTemplate.queryForObject("select set_config('salud_u.roles_actor', ?, true)", String.class, roles);
    }
}

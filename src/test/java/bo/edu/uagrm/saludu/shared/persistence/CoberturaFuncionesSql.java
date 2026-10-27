package bo.edu.uagrm.saludu.shared.persistence;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * Informe de qué funciones de salud_u ejecutan las pruebas de integración (ES-00).
 *
 * <p>Cada clase de integración arranca su contenedor con track_functions=all y, al terminar, llama a
 * {@link #registrar}. El resultado combinado de todas las clases queda en
 * target/cobertura-funciones-sql.txt. Es informativo: no falla ninguna prueba. Las funciones SQL que
 * PostgreSQL integra en la consulta que las llama no se cuentan y pueden aparecer como no ejecutadas.
 */
final class CoberturaFuncionesSql {
    private static final Path CARPETA = Path.of("target/cobertura-sql");
    private static final Path INFORME = Path.of("target/cobertura-funciones-sql.txt");

    private CoberturaFuncionesSql() {
    }

    /** Debe llamarse con los pools de las pruebas ya cerrados: cada conexión envía sus estadísticas al cerrarse. */
    static void registrar(String jdbcUrl, String usuario, String clave, String clase) {
        var config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(usuario);
        config.setPassword(clave);
        config.setMaximumPoolSize(1);
        try (var pool = new HikariDataSource(config)) {
            var jdbc = new JdbcTemplate(pool);
            for (int i = 0; i < 50 && jdbc.queryForObject("select count(*) from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid()", Integer.class) > 0; i++) {
                Thread.sleep(100);
            }
            var filas = jdbc.query("""
                select p.oid::regprocedure::text as funcion, coalesce(s.calls, 0) > 0 as ejecutada
                from pg_proc p left join pg_stat_user_functions s on s.funcid = p.oid
                where p.pronamespace = 'salud_u'::regnamespace
                  and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
                order by 1
                """, (rs, n) -> (rs.getBoolean("ejecutada") ? "+ " : "- ") + rs.getString("funcion"));
            Files.createDirectories(CARPETA);
            Files.write(CARPETA.resolve(clase + ".txt"), filas);
            combinar();
        } catch (Exception e) {
            System.err.println("No se pudo registrar la cobertura de funciones SQL de " + clase + ": " + e.getMessage());
        }
    }

    private static void combinar() throws java.io.IOException {
        var todas = new TreeSet<String>();
        var ejecutadas = new TreeSet<String>();
        var clases = new ArrayList<String>();
        try (var archivos = Files.list(CARPETA)) {
            for (Path archivo : archivos.sorted().toList()) {
                clases.add(archivo.getFileName().toString().replace(".txt", ""));
                for (String linea : Files.readAllLines(archivo)) {
                    todas.add(linea.substring(2));
                    if (linea.startsWith("+ ")) ejecutadas.add(linea.substring(2));
                }
            }
        }
        List<String> informe = new ArrayList<>();
        informe.add("Funciones de salud_u ejecutadas por las pruebas de integración: " + ejecutadas.size() + " de " + todas.size());
        informe.add("Clases incluidas: " + String.join(", ", clases));
        informe.add("No ejecutadas:");
        todas.stream().filter(f -> !ejecutadas.contains(f)).forEach(f -> informe.add("  " + f));
        Files.write(INFORME, informe);
    }
}

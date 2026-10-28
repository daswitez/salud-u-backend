package bo.edu.uagrm.saludu.scheduling.simulacion;

import bo.edu.uagrm.saludu.scheduling.application.EstimadorAgenda;
import bo.edu.uagrm.saludu.scheduling.application.SugeridorAgenda;
import bo.edu.uagrm.saludu.scheduling.simulacion.SimuladorAgenda.Fila;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Function;

/**
 * O-09: lee los escenarios y escribe los CSV del Apéndice A.6. Cada fila dice que es una simulación y lleva la fecha,
 * las versiones del modelo, la semilla y los parámetros, para poder repetirla.
 */
public final class InformeSimulacion {
    public static final String ORIGEN = "SIMULACION";
    private static final String[] CABECERA_COMUN = {"origen", "fecha_ejecucion", "version_simulador", "version_estimador",
        "version_sugeridor", "semilla", "replicas", "parametros"};

    public record Archivos(Path detalle, Path resumen, Path indicadores) {}

    public static List<SimuladorAgenda.Tramo> leerEscenarios(InputStream entrada) throws IOException {
        List<SimuladorAgenda.Tramo> tramos = new ArrayList<>();
        List<String> lineas = new String(entrada.readAllBytes(), StandardCharsets.UTF_8).lines()
            .filter(l -> !l.isBlank() && !l.startsWith("#")).toList();
        for (String linea : lineas.subList(1, lineas.size())) {
            String[] c = linea.split(",", -1);
            if (c.length != 10 && c.length != 11) throw new IllegalArgumentException("Escenario con " + c.length + " columnas: " + linea);
            tramos.add(new SimuladorAgenda.Tramo(c[0].trim(), Integer.parseInt(c[1].trim()), Integer.parseInt(c[2].trim()), c[3].trim(),
                c[4].trim(), Integer.parseInt(c[5].trim()), Double.parseDouble(c[6].trim()), Double.parseDouble(c[7].trim()),
                Integer.parseInt(c[8].trim()), Double.parseDouble(c[9].trim()),
                c.length == 10 || c[10].isBlank() ? null : java.util.Arrays.stream(c[10].trim().split(";", -1)).map(v -> Double.valueOf(v.trim())).toList()));
        }
        return tramos;
    }

    public static Archivos escribir(List<Fila> filas, SimuladorAgenda.Parametros p, OffsetDateTime fecha, Path carpeta) throws IOException {
        Files.createDirectories(carpeta);
        String sello = fecha.format(DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmm"));
        List<String> comun = List.of(ORIGEN, fecha.toString(), SimuladorAgenda.VERSION, EstimadorAgenda.VERSION_MODELO,
            SugeridorAgenda.VERSION_MODELO, String.valueOf(p.semilla()), String.valueOf(p.replicas()), p.descripcion());

        Map<String, Function<Fila, Object>> columnas = new LinkedHashMap<>();
        columnas.put("replica", Fila::replica);
        columnas.put("especialidad", Fila::especialidad);
        columnas.put("tipo_periodo", Fila::tipoPeriodo);
        columnas.put("temporada", Fila::temporada);
        columnas.put("desde", Fila::desde);
        columnas.put("hasta", Fila::hasta);
        columnas.put("politica", Fila::politica);
        columnas.put("solicitudes", Fila::solicitudes);
        columnas.put("jornadas", Fila::jornadas);
        columnas.put("lugares_publicados", Fila::lugaresPublicados);
        columnas.put("lugares_ociosos", Fila::lugaresOciosos);
        columnas.put("tasa_ociosos", Fila::tasaOciosos);
        columnas.put("dias_saturados", Fila::diasSaturados);
        columnas.put("solicitudes_asignadas", Fila::solicitudesAsignadas);
        columnas.put("espera_promedio_dias", Fila::esperaPromedio);
        columnas.put("espera_mediana_dias", Fila::esperaMediana);
        columnas.put("espera_p90_dias", Fila::esperaP90);
        columnas.put("jornadas_sobrecargadas", Fila::jornadasSobrecargadas);
        columnas.put("tasa_sobrecarga", Fila::tasaSobrecarga);
        columnas.put("sobrecupo_maximo", Fila::sobrecupoMaximo);
        columnas.put("citas_evaluadas", Fila::citasEvaluadas);
        columnas.put("brier", Fila::brier);
        columnas.put("brier_base", Fila::brierBase);
        columnas.put("dias_demanda", Fila::diasDemanda);
        columnas.put("error_demanda", Fila::errorDemanda);
        columnas.put("error_demanda_base", Fila::errorDemandaBase);
        columnas.put("sugerencias_emitidas", Fila::sugerenciasEmitidas);
        columnas.put("sugerencias_aceptadas", Fila::sugerenciasAceptadas);
        columnas.put("jornadas_adicionales", Fila::jornadasAdicionales);
        columnas.put("jornadas_liberadas", Fila::jornadasLiberadas);
        columnas.put("pendientes_al_final", Fila::pendientesAlFinal);
        List<String> detalle = new ArrayList<>();
        detalle.add(linea(cabecera(new ArrayList<>(columnas.keySet()))));
        for (Fila f : filas) {
            List<String> valores = new ArrayList<>(comun);
            columnas.values().forEach(c -> valores.add(texto(c.apply(f))));
            detalle.add(linea(valores));
        }
        Path archivoDetalle = carpeta.resolve("simulacion-o09-detalle-" + sello + ".csv");
        Files.write(archivoDetalle, detalle, StandardCharsets.UTF_8);

        List<String> resumen = new ArrayList<>();
        resumen.add(linea(cabecera(List.of("especialidad", "tipo_periodo", "temporada", "desde", "hasta", "politica",
            "solicitudes", "tasa_ociosos", "dias_saturados", "espera_promedio_dias", "espera_p90_dias", "tasa_sobrecarga", "brier", "brier_base",
            "error_demanda", "error_demanda_base", "sugerencias_emitidas", "sugerencias_aceptadas", "jornadas_adicionales",
            "jornadas_liberadas", "pendientes_al_final", "diferencia_ociosos", "diferencia_ociosos_ic95", "diferencia_espera_dias",
            "diferencia_espera_ic95", "criterio", "cumple"))));
        for (Resumen r : resumir(filas)) {
            List<String> valores = new ArrayList<>(comun);
            Fila f = r.ejemplo();
            for (Object v : List.of(f.especialidad(), f.tipoPeriodo(), f.temporada(), f.desde(), f.hasta(), f.politica())) valores.add(texto(v));
            for (Object v : r.promedios()) valores.add(texto(v));
            valores.add(texto(r.ociosos() == null ? null : r.ociosos().media()));
            valores.add(r.ociosos() == null ? "" : r.ociosos().intervalo());
            valores.add(texto(r.espera() == null ? null : r.espera().media()));
            valores.add(r.espera() == null ? "" : r.espera().intervalo());
            valores.add(r.criterio());
            valores.add(r.cumple());
            resumen.add(linea(valores));
        }
        Path archivoResumen = carpeta.resolve("simulacion-o09-resumen-" + sello + ".csv");
        Files.write(archivoResumen, resumen, StandardCharsets.UTF_8);
        Path archivoIndicadores = carpeta.resolve("simulacion-o09-indicadores-" + sello + ".csv");
        escribirIndicadores(filas, comun, archivoIndicadores);
        return new Archivos(archivoDetalle, archivoResumen, archivoIndicadores);
    }

    private record Indicador(String nombre, Function<Fila, Double> valor, Function<Fila, Double> base) {}

    /** IC95 por réplica y comparación pareada; Brier/MAE se comparan con su línea base, saturación/espera/ociosidad con la política fija. */
    private static void escribirIndicadores(List<Fila> filas, List<String> comun, Path archivo) throws IOException {
        List<Indicador> indicadores = List.of(
            new Indicador("tasa_ociosos", Fila::tasaOciosos, null),
            new Indicador("espera_promedio_dias", Fila::esperaPromedio, null),
            new Indicador("dias_saturados", f -> (double) f.diasSaturados(), null),
            new Indicador("tasa_sobrecarga", Fila::tasaSobrecarga, null),
            new Indicador("brier", Fila::brier, Fila::brierBase),
            new Indicador("mae_demanda", Fila::errorDemanda, Fila::errorDemandaBase));
        Map<String, List<Fila>> grupos = new LinkedHashMap<>();
        for (Fila f : filas) grupos.computeIfAbsent(f.especialidad() + "|" + f.desde() + "|" + f.politica(), k -> new ArrayList<>()).add(f);
        List<String> salida = new ArrayList<>();
        salida.add(linea(cabecera(List.of("especialidad", "tipo_periodo", "temporada", "politica", "indicador", "media", "ic95", "n", "referencia", "diferencia", "diferencia_ic95", "veredicto"))));
        for (List<Fila> grupo : grupos.values()) {
            Fila f = grupo.getFirst();
            List<Fila> fija = filas.stream().filter(x -> x.especialidad().equals(f.especialidad()) && x.desde().equals(f.desde())
                && SimuladorAgenda.AGENDA_FIJA.equals(x.politica())).toList();
            for (Indicador indicador : indicadores) {
                Diferencia promedio = intervalo(grupo.stream().map(indicador.valor()).filter(java.util.Objects::nonNull).toList());
                Diferencia comparacion;
                String referencia;
                if (indicador.base() != null) {
                    List<Double> diferencias = new ArrayList<>();
                    for (Fila fila : grupo) {
                        Double a = indicador.valor().apply(fila), b = indicador.base().apply(fila);
                        if (a != null && b != null) diferencias.add(a - b);
                    }
                    comparacion = intervalo(diferencias);
                    referencia = indicador.nombre().equals("brier") ? "asistencia_inicial" : "semana_anterior";
                } else {
                    comparacion = SimuladorAgenda.CON_SUGERENCIAS.equals(f.politica()) ? diferencia(grupo, fija, indicador.valor()) : null;
                    referencia = indicador.nombre().equals("tasa_sobrecarga") ? "limite_0.20" : "agenda_fija";
                }
                String veredicto;
                if (promedio == null || promedio.n() < 2) veredicto = "SIN_DATOS";
                else if (indicador.nombre().equals("tasa_sobrecarga"))
                    veredicto = promedio.superior() <= SugeridorAgenda.RIESGO_MAXIMO ? "SI" : promedio.inferior() > SugeridorAgenda.RIESGO_MAXIMO ? "NO" : "NO_CONCLUYENTE";
                else if (comparacion == null && indicador.base() == null) veredicto = "REFERENCIA";
                else veredicto = veredicto(comparacion, true);
                List<String> valores = new ArrayList<>(comun);
                for (Object valor : List.of(f.especialidad(), f.tipoPeriodo(), f.temporada(), f.politica(), indicador.nombre())) valores.add(texto(valor));
                valores.add(texto(promedio == null ? null : promedio.media()));
                valores.add(promedio == null ? "" : promedio.intervalo());
                valores.add(texto(promedio == null ? 0 : promedio.n()));
                valores.add(referencia);
                valores.add(texto(comparacion == null ? null : comparacion.media()));
                valores.add(comparacion == null ? "" : comparacion.intervalo());
                valores.add(veredicto);
                salida.add(linea(valores));
            }
        }
        Files.write(archivo, salida, StandardCharsets.UTF_8);
    }

    private static Diferencia intervalo(List<Double> valores) {
        if (valores.isEmpty()) return null;
        int n = valores.size();
        double media = valores.stream().mapToDouble(Double::doubleValue).average().orElseThrow();
        if (n < 2) return new Diferencia(media, media, media, n);
        double varianza = valores.stream().mapToDouble(v -> (v - media) * (v - media)).sum() / (n - 1);
        double margen = cuantilT(n - 1) * Math.sqrt(varianza / n);
        return new Diferencia(media, media - margen, media + margen, n);
    }

    /** Media de la diferencia pareada (con sugerencias − agenda fija) por réplica y su intervalo t del 95 %. */
    record Diferencia(double media, double inferior, double superior, int n) {
        String intervalo() { return n < 2 ? "" : "[" + texto(inferior) + "; " + texto(superior) + "]"; }
    }

    record Resumen(Fila ejemplo, List<Object> promedios, Diferencia ociosos, Diferencia espera, String criterio, String cumple) {}

    static List<Resumen> resumir(List<Fila> filas) {
        Map<String, List<Fila>> grupos = new LinkedHashMap<>();
        for (Fila f : filas) grupos.computeIfAbsent(f.especialidad() + "|" + f.desde() + "|" + f.politica(), k -> new ArrayList<>()).add(f);
        List<Resumen> resultado = new ArrayList<>();
        for (List<Fila> grupo : grupos.values()) {
            Fila ejemplo = grupo.getFirst();
            List<Object> promedios = java.util.Arrays.asList(media(grupo, f -> (double) f.solicitudes()), media(grupo, Fila::tasaOciosos),
                media(grupo, f -> (double) f.diasSaturados()), media(grupo, Fila::esperaPromedio), media(grupo, Fila::esperaP90), media(grupo, Fila::tasaSobrecarga), media(grupo, Fila::brier),
                media(grupo, Fila::brierBase), media(grupo, Fila::errorDemanda), media(grupo, Fila::errorDemandaBase),
                media(grupo, f -> (double) f.sugerenciasEmitidas()), media(grupo, f -> (double) f.sugerenciasAceptadas()),
                media(grupo, f -> (double) f.jornadasAdicionales()), media(grupo, f -> (double) f.jornadasLiberadas()),
                media(grupo, f -> (double) f.pendientesAlFinal()));
            if (!SimuladorAgenda.CON_SUGERENCIAS.equals(ejemplo.politica())) {
                resultado.add(new Resumen(ejemplo, promedios, null, null, "Referencia", ""));
                continue;
            }
            List<Fila> fija = filas.stream().filter(f -> SimuladorAgenda.AGENDA_FIJA.equals(f.politica())
                && f.especialidad().equals(ejemplo.especialidad()) && f.desde().equals(ejemplo.desde())).toList();
            Diferencia ociosos = diferencia(grupo, fija, Fila::tasaOciosos), espera = diferencia(grupo, fija, Fila::esperaPromedio);
            Double sobrecarga = (Double) promedios.get(5);
            boolean sobrecargaOk = sobrecarga == null || sobrecarga <= SugeridorAgenda.RIESGO_MAXIMO;
            String criterio, cumple;
            switch (ejemplo.temporada()) {
                case "BAJA" -> {
                    criterio = "Temporada baja: cupos ociosos menores que con la agenda fija; sobrecarga no mayor al riesgo máximo";
                    cumple = veredicto(ociosos, sobrecargaOk);
                }
                case "ALTA" -> {
                    criterio = "Temporada alta: espera menor que con la agenda fija; sobrecarga no mayor al riesgo máximo";
                    cumple = veredicto(espera, sobrecargaOk);
                }
                default -> {
                    criterio = "Sobrecarga no mayor al riesgo máximo";
                    cumple = sobrecargaOk ? "SI" : "NO";
                }
            }
            resultado.add(new Resumen(ejemplo, promedios, ociosos, espera, criterio, cumple));
        }
        return resultado;
    }

    /** SI si todo el intervalo está bajo cero; NO si está sobre cero; NO_CONCLUYENTE si incluye el cero. */
    private static String veredicto(Diferencia d, boolean sobrecargaOk) {
        if (!sobrecargaOk) return "NO";
        if (d == null || d.n() < 2) return "SIN_DATOS";
        return d.superior() < 0 ? "SI" : d.inferior() > 0 ? "NO" : "NO_CONCLUYENTE";
    }

    static Diferencia diferencia(List<Fila> sugerencias, List<Fila> fija, Function<Fila, Double> metrica) {
        List<Double> diferencias = new ArrayList<>();
        for (Fila s : sugerencias)
            for (Fila f : fija)
                if (f.replica() == s.replica() && metrica.apply(s) != null && metrica.apply(f) != null)
                    diferencias.add(metrica.apply(s) - metrica.apply(f));
        if (diferencias.isEmpty()) return null;
        int n = diferencias.size();
        double media = diferencias.stream().mapToDouble(Double::doubleValue).average().orElseThrow();
        if (n < 2) return new Diferencia(media, media, media, n);
        double varianza = diferencias.stream().mapToDouble(d -> (d - media) * (d - media)).sum() / (n - 1);
        double margen = cuantilT(n - 1) * Math.sqrt(varianza / n);
        return new Diferencia(media, media - margen, media + margen, n);
    }

    /** Cuantil 0,975 de la t de Student; desde 30 grados de libertad se usa 1,96. */
    static double cuantilT(int gl) {
        double[] tabla = {12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131,
            2.120, 2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045};
        return gl < 30 ? tabla[gl - 1] : 1.96;
    }

    private static Double media(List<Fila> filas, Function<Fila, Double> metrica) {
        return filas.stream().map(metrica).filter(v -> v != null).mapToDouble(Double::doubleValue).average().stream().boxed().findFirst().orElse(null);
    }

    private static List<String> cabecera(List<String> resto) {
        List<String> todo = new ArrayList<>(List.of(CABECERA_COMUN));
        todo.addAll(resto);
        return todo;
    }

    static String texto(Object valor) {
        if (valor == null) return "";
        if (valor instanceof Double d) {
            String resultado = String.format(Locale.ROOT, "%.8f", d).replaceAll("0+$", "").replaceAll("\\.$", "");
            if (d != 0 && (resultado.equals("0") || resultado.equals("-0"))) return String.format(Locale.ROOT, "%.8g", d);
            return resultado;
        }
        return valor.toString();
    }

    private static String linea(List<String> valores) {
        List<String> celdas = new ArrayList<>();
        for (String v : valores) celdas.add(v.contains(",") || v.contains("\"") || v.contains(";") ? "\"" + v.replace("\"", "\"\"") + "\"" : v);
        return String.join(",", celdas);
    }

    public static OffsetDateTime ahora() { return OffsetDateTime.now(ZoneId.of("America/La_Paz")); }
}

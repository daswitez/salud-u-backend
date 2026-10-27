package bo.edu.uagrm.saludu.scheduling.application;

import java.time.LocalDate;
import java.util.List;

/** O-08: indicadores del cuadro 3.70 para un período (contrato HTTP en inglés). Un valor null significa sin datos. */
public record SchedulingMetrics(LocalDate from, LocalDate to, String modelVersion, IdlePlaces idlePlaces, Wait waitTime,
    Overload overload, AttendanceCalibration attendanceCalibration, DemandError demandError, Suggestions suggestions,
    Notifications notifications) {

    /** Lugares publicados sin paciente atendido sobre lugares publicados, en jornadas cerradas. */
    public record IdlePlaces(int days, int publishedPlaces, int idlePlaces, Double rate) {}

    /** Días entre el ingreso de la solicitud y la cita asignada, para solicitudes asignadas en el período. */
    public record Wait(int assignedRequests, Double averageDays, Double medianDays, Double p90Days) {}

    /** Jornadas en que llegaron más pacientes que la capacidad definida por el médico (sin el sobrecupo aplicado). */
    public record Overload(int days, int overloadedDays, Double rate, double maxRisk, int daysWithOverbooking) {}

    /** skill = 1 − brier / línea base: positivo si el modelo calibra mejor que la asistencia constante inicial. */
    public record AttendanceCalibration(int appointments, Double brierScore, Double baselineBrierScore, Double skill) {}

    public record DemandError(int days, Double meanAbsoluteError, int comparableDays, Double comparableMeanAbsoluteError,
        Double baselineMeanAbsoluteError) {}

    public record Suggestions(int issued, int accepted, int modified, int rejected, int expired, int pending, Double acceptanceRate,
        List<SuggestionsByType> byType) {}

    public record SuggestionsByType(String type, int issued, int accepted, int modified, int rejected, int expired, int pending) {}

    public record Notifications(int registered, int delivered, int read, Double readRate, List<NotificationsByType> byType) {}

    public record NotificationsByType(String eventType, int registered, int delivered, int read) {}
}

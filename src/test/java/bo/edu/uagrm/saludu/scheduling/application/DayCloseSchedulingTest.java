package bo.edu.uagrm.saludu.scheduling.application;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import bo.edu.uagrm.saludu.shared.scheduling.SchedulingConfiguration;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.scheduling.annotation.ScheduledAnnotationBeanPostProcessor;
import org.springframework.scheduling.config.CronTask;

class DayCloseSchedulingTest {
    private final ScheduleEstimationService estimations = mock(ScheduleEstimationService.class);
    private final ScheduleSuggestionService suggestions = mock(ScheduleSuggestionService.class);

    private ApplicationContextRunner context(DayCloseService service) {
        return new ApplicationContextRunner().withUserConfiguration(SchedulingConfiguration.class, DayCloseJob.class)
            .withBean(DayCloseService.class, () -> service).withBean(ScheduleEstimationService.class, () -> estimations)
            .withBean(ScheduleSuggestionService.class, () -> suggestions);
    }

    @Test
    void noBackgroundTaskExistsUnlessThePropertyIsTrue() {
        var service = mock(DayCloseService.class);
        for (String[] properties : new String[][] { {}, {"salud-u.scheduling.enabled=false"} }) {
            context(service).withPropertyValues(properties).run(ctx -> {
                assertTrue(ctx.getBeansOfType(DayCloseJob.class).isEmpty());
                assertTrue(ctx.getBeansOfType(ScheduledAnnotationBeanPostProcessor.class).isEmpty());
            });
        }
        verifyNoInteractions(service, estimations, suggestions);
    }

    @Test
    void enabledSchedulingRunsNightlyByDefaultAndAcceptsAConfiguredCron() {
        var service = mock(DayCloseService.class);
        context(service).withPropertyValues("salud-u.scheduling.enabled=true").run(ctx -> assertEquals("0 30 0 * * *", cron(ctx)));
        context(service).withPropertyValues("salud-u.scheduling.enabled=true", "salud-u.scheduling.day-close-cron=0 0 2 * * *")
            .run(ctx -> assertEquals("0 0 2 * * *", cron(ctx)));
    }

    @Test
    void scheduledExecutionClosesTheDaysThenEstimatesThenSuggests() {
        var service = mock(DayCloseService.class);
        var called = new CompletableFuture<Boolean>();
        when(suggestions.generate(any())).thenAnswer(invocation -> { called.complete(true); return 0; });
        context(service).withPropertyValues("salud-u.scheduling.enabled=true", "salud-u.scheduling.day-close-cron=*/1 * * * * *").run(ctx -> {
            assertTrue(called.get(5, TimeUnit.SECONDS));
            var order = inOrder(service, estimations, suggestions);
            order.verify(service).closeRecentDays();
            order.verify(estimations).recompute();
            order.verify(suggestions).expire();
            order.verify(suggestions).generate(java.time.LocalDate.now(java.time.ZoneId.of("America/La_Paz")));
        });
    }

    @Test
    void aFailedStepDoesNotPreventTheNextStepsNorTheNextAttempt() {
        var service = mock(DayCloseService.class);
        when(service.closeRecentDays()).thenThrow(new DataAccessResourceFailureException("FALLO_CONTROLADO_O02")).thenReturn(1);
        when(estimations.recompute()).thenThrow(new DataAccessResourceFailureException("FALLO_CONTROLADO_O03")).thenReturn(1);
        when(suggestions.generate(any())).thenThrow(new DataAccessResourceFailureException("FALLO_CONTROLADO_O04")).thenReturn(1);
        var job = new DayCloseJob(service, estimations, suggestions);
        assertDoesNotThrow(job::close);
        assertDoesNotThrow(job::close);
        verify(service, times(2)).closeRecentDays();
        verify(estimations, times(2)).recompute();
        verify(suggestions, times(2)).expire();
        verify(suggestions, times(2)).generate(any());
    }

    private static String cron(org.springframework.context.ApplicationContext ctx) {
        var tasks = ctx.getBean(ScheduledAnnotationBeanPostProcessor.class).getScheduledTasks();
        assertEquals(1, tasks.size());
        return ((CronTask) tasks.iterator().next().getTask()).getExpression();
    }
}

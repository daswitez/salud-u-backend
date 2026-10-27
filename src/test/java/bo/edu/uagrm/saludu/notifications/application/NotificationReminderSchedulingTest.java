package bo.edu.uagrm.saludu.notifications.application;

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

class NotificationReminderSchedulingTest {
    private ApplicationContextRunner context(NotificationReminderService service) {
        return new ApplicationContextRunner().withUserConfiguration(SchedulingConfiguration.class, NotificationReminderJob.class)
            .withBean(NotificationReminderService.class, () -> service);
    }

    @Test
    void noBackgroundTaskExistsUnlessThePropertyIsTrue() {
        var service = mock(NotificationReminderService.class);
        for (String[] properties : new String[][] { {}, {"salud-u.scheduling.enabled=false"} }) {
            context(service).withPropertyValues(properties).run(ctx -> {
                assertTrue(ctx.getBeansOfType(NotificationReminderJob.class).isEmpty());
                assertTrue(ctx.getBeansOfType(ScheduledAnnotationBeanPostProcessor.class).isEmpty());
            });
        }
        verifyNoInteractions(service);
    }

    @Test
    void enabledSchedulingUsesTheConfiguredCron() {
        var service = mock(NotificationReminderService.class);
        String cron = "0 0 0 1 1 *";
        context(service).withPropertyValues("salud-u.scheduling.enabled=true", "salud-u.scheduling.reminder-cron=" + cron).run(ctx -> {
            assertEquals(1, ctx.getBeansOfType(NotificationReminderJob.class).size());
            var tasks = ctx.getBean(ScheduledAnnotationBeanPostProcessor.class).getScheduledTasks();
            assertEquals(1, tasks.size());
            assertEquals(cron, ((CronTask) tasks.iterator().next().getTask()).getExpression());
        });
    }

    @Test
    void scheduledExecutionActuallyCallsTheReminderService() {
        var service = mock(NotificationReminderService.class);
        var called = new CompletableFuture<Boolean>();
        when(service.generateTomorrowReminders()).thenAnswer(invocation -> { called.complete(true); return 0; });
        context(service).withPropertyValues("salud-u.scheduling.enabled=true", "salud-u.scheduling.reminder-cron=*/1 * * * * *").run(ctx -> {
            assertTrue(called.get(5, TimeUnit.SECONDS));
            verify(service, atLeastOnce()).generateTomorrowReminders();
        });
    }

    @Test
    void aFailedExecutionDoesNotPreventTheNextAttempt() {
        var service = mock(NotificationReminderService.class);
        when(service.generateTomorrowReminders()).thenThrow(new DataAccessResourceFailureException("FALLO_CONTROLADO_N03")).thenReturn(1);
        var job = new NotificationReminderJob(service);
        assertDoesNotThrow(job::generate);
        assertDoesNotThrow(job::generate);
        verify(service, times(2)).generateTomorrowReminders();
    }
}

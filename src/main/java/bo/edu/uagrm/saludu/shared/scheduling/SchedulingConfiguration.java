package bo.edu.uagrm.saludu.shared.scheduling;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "salud-u.scheduling.enabled", havingValue = "true")
@EnableScheduling
public class SchedulingConfiguration {}

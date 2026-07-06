package fr.k8sschool.reviews;

import io.opentelemetry.sdk.autoconfigure.spi.AutoConfigurationCustomizerProvider;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Lab 8 — plugs the PII masking exporter into the OpenTelemetry SDK managed
 * by the Spring Boot Starter.
 *
 * Activation: MASK_PII=true environment variable (relaxed binding to the
 * 'mask.pii' property). No effect with the Java agent: the agent runs its
 * own SDK and does not invoke Spring beans (agent-side masking requires an
 * agent extension, or masking at the collector level - see Lab 8).
 */
@Configuration
@ConditionalOnProperty(name = "mask.pii", havingValue = "true")
public class PiiMaskingConfiguration {

    @Bean
    public AutoConfigurationCustomizerProvider piiMasking() {
        return customizer -> customizer.addLogRecordExporterCustomizer(
                (exporter, config) -> new PiiRedactingLogRecordExporter(exporter));
    }
}

package fr.k8sschool.reviews;

import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.Value;
import io.opentelemetry.api.logs.Severity;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.common.InstrumentationScopeInfo;
import io.opentelemetry.sdk.logs.data.Body;
import io.opentelemetry.sdk.logs.data.LogRecordData;
import io.opentelemetry.sdk.logs.export.LogRecordExporter;
import io.opentelemetry.sdk.resources.Resource;

import java.util.Collection;
import java.util.List;
import java.util.regex.Pattern;

/**
 * Lab 8 — SDK-level masking: a LogRecordExporter decorator that redacts
 * email addresses from log bodies before they leave the process.
 *
 * Why an exporter decorator and not a LogRecordProcessor? In the stable SDK
 * API a LogRecordProcessor can mutate log ATTRIBUTES (setAttribute) but not
 * the BODY. Rewriting the body is done either here (exporter wrapper) or at
 * the collector level (OTTL replace_pattern - also shown in Lab 8).
 *
 * Only active with the 'starter' profile and MASK_PII=true
 * (see PiiMaskingConfiguration).
 */
public class PiiRedactingLogRecordExporter implements LogRecordExporter {

    private static final Pattern EMAIL = Pattern.compile("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");

    private final LogRecordExporter delegate;

    public PiiRedactingLogRecordExporter(LogRecordExporter delegate) {
        this.delegate = delegate;
    }

    @Override
    public CompletableResultCode export(Collection<LogRecordData> logs) {
        return delegate.export(logs.stream().map(this::redact).map(LogRecordData.class::cast).toList());
    }

    private LogRecordData redact(LogRecordData log) {
        String body = log.getBodyValue() == null ? null : log.getBodyValue().asString();
        if (body == null || !EMAIL.matcher(body).find()) {
            return log;
        }
        String masked = EMAIL.matcher(body).replaceAll("***@***");
        return new DelegatingLogRecordData(log) {
            @Override
            @SuppressWarnings("deprecation")
            public Body getBody() {
                return Body.string(masked);
            }

            @Override
            public Value<?> getBodyValue() {
                return Value.of(masked);
            }
        };
    }

    @Override
    public CompletableResultCode flush() {
        return delegate.flush();
    }

    @Override
    public CompletableResultCode shutdown() {
        return delegate.shutdown();
    }

    /** Forwards every LogRecordData accessor to the wrapped record. */
    private abstract static class DelegatingLogRecordData implements LogRecordData {

        private final LogRecordData delegate;

        DelegatingLogRecordData(LogRecordData delegate) {
            this.delegate = delegate;
        }

        @Override
        public Resource getResource() {
            return delegate.getResource();
        }

        @Override
        public InstrumentationScopeInfo getInstrumentationScopeInfo() {
            return delegate.getInstrumentationScopeInfo();
        }

        @Override
        public long getTimestampEpochNanos() {
            return delegate.getTimestampEpochNanos();
        }

        @Override
        public long getObservedTimestampEpochNanos() {
            return delegate.getObservedTimestampEpochNanos();
        }

        @Override
        public SpanContext getSpanContext() {
            return delegate.getSpanContext();
        }

        @Override
        public Severity getSeverity() {
            return delegate.getSeverity();
        }

        @Override
        public String getSeverityText() {
            return delegate.getSeverityText();
        }

        @Override
        public Attributes getAttributes() {
            return delegate.getAttributes();
        }

        @Override
        public int getTotalAttributeCount() {
            return delegate.getTotalAttributeCount();
        }
    }
}

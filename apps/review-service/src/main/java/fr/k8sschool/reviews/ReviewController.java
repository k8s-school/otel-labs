package fr.k8sschool.reviews;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.context.Scope;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequestMapping("/api/reviews")
public class ReviewController {

    private static final Logger logger = LoggerFactory.getLogger(ReviewController.class);

    // A rating is a small integer (1..5): a safe metric dimension. An e-mail
    // or a product id would create one time series per value (Lab 6).
    private static final AttributeKey<Long> RATING = AttributeKey.longKey("app.review.rating");

    private final ReviewRepository repository;
    private final ProductCatalogClient catalog;

    // Lab 6 part 1: business metrics written with the OpenTelemetry API.
    private final LongCounter reviewsCreated;
    private final DoubleHistogram reviewCreationDuration;

    // Lab 6 part 2: the Micrometer meter this application already had. The
    // Java agent exports it too, once its Micrometer bridge is enabled.
    private final Timer reviewCreationTimer;

    public ReviewController(ReviewRepository repository, ProductCatalogClient catalog,
                            MeterRegistry registry) {
        this.repository = repository;
        this.catalog = catalog;

        // The API alone is a no-op: it only produces data once an SDK is
        // installed in the JVM (the Java agent, or the Spring Boot Starter).
        // The instrumentation scope name below ends up in otel.scope.name.
        Meter meter = GlobalOpenTelemetry.getMeter("fr.k8sschool.reviews");
        this.reviewsCreated = meter.counterBuilder("reviews.created")
                .setDescription("Number of product reviews created")
                .setUnit("{review}")
                .build();
        this.reviewCreationDuration = meter.histogramBuilder("reviews.creation.duration")
                .setDescription("Time spent creating a review (catalog check + insert)")
                .setUnit("ms")
                .build();

        this.reviewCreationTimer = Timer.builder("reviews.creation.time")
                .description("Time spent creating a review, measured by Micrometer")
                .publishPercentileHistogram()
                .register(registry);
    }

    @GetMapping
    public List<Review> all() {
        logger.info("Listing all reviews");
        return repository.findAll();
    }

    @GetMapping("/{id}")
    public Review byId(@PathVariable Long id) {
        return repository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "review not found"));
    }

    @GetMapping("/product/{productId}")
    public List<Review> byProduct(@PathVariable String productId) {
        logger.info("Listing reviews for product {}", productId);
        return repository.findByProductId(productId);
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Review create(@RequestBody Review review,
                         @RequestHeader(value = "Authorization", required = false) String authorization) {
        if (review.getRating() < 1 || review.getRating() > 5) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "rating must be between 1 and 5");
        }

        // NOTE: deliberate mistakes, studied (and fixed) in the
        // "Security & compliance" module (Lab 8):
        // 1. PII (email) copied into span attributes
        // 2. Authorization header (credentials!) copied into span attributes
        // 3. PII (name + email) written into the log message below
        Span span = Span.current();
        span.setAttribute("user.email", String.valueOf(review.getUserEmail()));
        if (authorization != null) {
            span.setAttribute("http.request.header.authorization", authorization);
        }
        logger.info("Creating review for product {} by {} <{}>",
                review.getProductId(), review.getUserName(), review.getUserEmail());

        // Lab 7: baggage travels with the trace context to downstream services
        Baggage baggage = Baggage.current().toBuilder()
                .put("app.review.channel", "web")
                .build();
        try (Scope ignored = baggage.makeCurrent()) {
            long startNanos = System.nanoTime();
            // Both APIs instrument the very same block, side by side.
            Review saved = reviewCreationTimer.record(() -> {
                catalog.checkProductExists(review.getProductId());
                return repository.save(review);
            });
            Attributes attributes = Attributes.of(RATING, (long) review.getRating());
            reviewsCreated.add(1, attributes);
            reviewCreationDuration.record((System.nanoTime() - startNanos) / 1_000_000.0, attributes);
            return saved;
        }
    }
}

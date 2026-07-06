package fr.k8sschool.reviews;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import io.opentelemetry.api.baggage.Baggage;
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

    private final ReviewRepository repository;
    private final ProductCatalogClient catalog;

    // Lab 6: business metrics (Micrometer). Exported to OpenTelemetry by the
    // Java agent (Micrometer bridge) or by the Spring Boot Starter.
    private final Counter reviewsCreated;
    private final Timer reviewCreationTimer;

    public ReviewController(ReviewRepository repository, ProductCatalogClient catalog,
                            MeterRegistry registry) {
        this.repository = repository;
        this.catalog = catalog;
        this.reviewsCreated = Counter.builder("reviews.created")
                .description("Number of product reviews created")
                .register(registry);
        this.reviewCreationTimer = Timer.builder("reviews.creation.time")
                .description("Time spent creating a review (catalog check + insert)")
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
            return reviewCreationTimer.record(() -> {
                catalog.checkProductExists(review.getProductId());
                Review saved = repository.save(review);
                reviewsCreated.increment();
                return saved;
            });
        }
    }
}

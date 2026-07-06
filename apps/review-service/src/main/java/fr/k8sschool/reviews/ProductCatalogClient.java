package fr.k8sschool.reviews;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.instrumentation.annotations.SpanAttribute;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.client.ClientHttpRequestFactories;
import org.springframework.boot.web.client.ClientHttpRequestFactorySettings;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.time.Duration;

/**
 * Checks that a product exists in the Astronomy Shop catalog by calling the
 * demo frontend HTTP API (http://frontend:8080/api/products/{id}).
 *
 * Lab 7: the HTTP call is auto-instrumented (client span) and the trace
 * context is propagated to the frontend service, producing a multi-service
 * trace. @WithSpan adds a manual parent span around the lookup.
 */
@Service
public class ProductCatalogClient {

    private static final Logger logger = LoggerFactory.getLogger(ProductCatalogClient.class);

    private final RestClient restClient;

    public ProductCatalogClient(@Value("${catalog.url:http://frontend:8080}") String catalogUrl) {
        this.restClient = RestClient.builder()
                .baseUrl(catalogUrl)
                .requestFactory(ClientHttpRequestFactories.get(ClientHttpRequestFactorySettings.DEFAULTS
                        .withConnectTimeout(Duration.ofSeconds(3))
                        .withReadTimeout(Duration.ofSeconds(3))))
                .build();
    }

    @WithSpan("product-catalog.lookup")
    public void checkProductExists(@SpanAttribute("app.product.id") String productId) {
        logger.info("Checking product {} in the catalog", productId);
        try {
            restClient.get()
                    .uri("/api/products/{id}", productId)
                    .retrieve()
                    .toBodilessEntity();
            Span.current().setAttribute("app.product.found", true);
        } catch (Exception e) {
            Span.current().setAttribute("app.product.found", false);
            throw new IllegalStateException("product catalog lookup failed for " + productId, e);
        }
    }
}

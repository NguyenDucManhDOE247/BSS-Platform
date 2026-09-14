package com.bss.order.client;

import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import io.github.resilience4j.retry.annotation.Retry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.client.ClientHttpRequestFactories;
import org.springframework.boot.web.client.ClientHttpRequestFactorySettings;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.UUID;

/**
 * B-13 fix: order-management used to trust whatever {@code unitPrice} the HTTP caller sent in
 * {@code CreateOrderRequest} — anyone could buy a 199,000₫ plan for 1₫. Price (and the
 * offering's name + lifecycle status) must come from product-catalog, the system of record.
 *
 * <p>Resilience: product-catalog being briefly slow or down should not crash every order.
 *   - Timeout: a short connect/read timeout on the underlying HTTP client, so one stuck call
 *     doesn't tie up a request thread forever.
 *   - Retry: transient failures (network blip, one slow instance) get 2 extra attempts with a
 *     short wait — see {@code resilience4j.retry.instances.productCatalog} in application.yml.
 *   - Circuit breaker: once failures cross a threshold, stop calling product-catalog for a
 *     while (fail fast) instead of piling up more slow/failing requests on top of a service
 *     that's already struggling — see {@code resilience4j.circuitbreaker.instances.productCatalog}.
 *
 * A real 404 (offering doesn't exist) is a client error, not a transient fault — it's declared
 * `ignore-exceptions` in application.yml so Resilience4j doesn't retry it or count it against
 * the circuit breaker; it becomes a 422 in {@link com.bss.order.exception.GlobalExceptionHandler}.
 */
@Component
public class ProductCatalogClient {

    private static final Logger log = LoggerFactory.getLogger(ProductCatalogClient.class);

    private final RestClient restClient;

    public ProductCatalogClient(RestClient.Builder builder,
                                @Value("${bss.clients.product-catalog.base-url}") String baseUrl) {
        var timeouts = ClientHttpRequestFactorySettings.DEFAULTS
                .withConnectTimeout(Duration.ofSeconds(1))
                .withReadTimeout(Duration.ofSeconds(2));
        this.restClient = builder
                .baseUrl(baseUrl)
                .requestFactory(ClientHttpRequestFactories.get(timeouts))
                .build();
    }

    @CircuitBreaker(name = "productCatalog")
    @Retry(name = "productCatalog")
    public OfferingSnapshot getOffering(UUID offeringId) {
        try {
            return restClient.get()
                    .uri("/tmf-api/productCatalog/v4/productOffering/{id}", offeringId)
                    .retrieve()
                    .body(OfferingSnapshot.class);
        } catch (HttpClientErrorException.NotFound e) {
            throw new UnknownOfferingException(offeringId);
        }
    }
}

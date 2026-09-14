package com.bss.order.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;
import software.amazon.awssdk.services.eventbridge.EventBridgeClientBuilder;

import java.net.URI;
import java.time.Duration;

@Configuration
public class AwsConfig {

    @Value("${aws.region:ap-southeast-1}")
    private String region;

    /** Set to http://localhost:4566 for LocalStack; leave empty in real AWS for IRSA. */
    @Value("${aws.endpoint-url:}")
    private String endpointOverride;

    @Bean
    public EventBridgeClient eventBridgeClient() {
        EventBridgeClientBuilder builder = EventBridgeClient.builder()
                .region(Region.of(region))
                // Found by actually killing LocalStack mid-test (Giai đoạn 1 resilience check):
                // with no timeout configured, the SDK's default is effectively "wait
                // indefinitely" for a response. OrderEventPublisher.drain() runs on Spring's
                // default @Scheduled thread pool, which has exactly ONE thread unless
                // configured otherwise — one hung putEvents() call there doesn't just fail
                // slowly, it permanently stops every future scheduled drain (and everything
                // else scheduled) from ever running again, because `fixedDelay` scheduling
                // waits for the previous execution to finish before queuing the next. A
                // bounded apiCallTimeout turns "hangs forever" into "fails after 5s, logged,
                // retried on the next tick" — the difference between a blip and an outage.
                .overrideConfiguration(ClientOverrideConfiguration.builder()
                        .apiCallTimeout(Duration.ofSeconds(5))
                        .apiCallAttemptTimeout(Duration.ofSeconds(3))
                        .build());
        if (endpointOverride != null && !endpointOverride.isBlank()) {
            builder.endpointOverride(URI.create(endpointOverride))
                    .credentialsProvider(StaticCredentialsProvider.create(
                            AwsBasicCredentials.create("test", "test")));
        } else {
            builder.credentialsProvider(DefaultCredentialsProvider.create());
        }
        return builder.build();
    }
}

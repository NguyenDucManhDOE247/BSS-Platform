package com.bss.billing.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.SqsClientBuilder;

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
    public SqsClient sqsClient() {
        // See the identical note in order-management's AwsConfig: without a bounded timeout,
        // one hung receiveMessage() call (e.g. right after LocalStack/SQS restarts) can
        // permanently stall the single-threaded @Scheduled pool that OrderEventListener.poll()
        // runs on. waitTimeSeconds(10) on the long-poll request itself means the attempt
        // timeout needs to be a bit more than that, not less.
        SqsClientBuilder builder = SqsClient.builder()
                .region(Region.of(region))
                .overrideConfiguration(ClientOverrideConfiguration.builder()
                        .apiCallTimeout(Duration.ofSeconds(15))
                        .apiCallAttemptTimeout(Duration.ofSeconds(13))
                        .build());
        if (endpointOverride != null && !endpointOverride.isBlank()) {
            // LocalStack path — static dummy credentials, override endpoint.
            builder.endpointOverride(URI.create(endpointOverride))
                    .credentialsProvider(StaticCredentialsProvider.create(
                            AwsBasicCredentials.create("test", "test")));
        } else {
            // Real AWS — DefaultCredentialsProvider picks up IRSA on EKS.
            // .create() still works but is deprecated as of AWS SDK 2.5x -- .builder().build()
            // is the replacement (see order-management's AwsConfig for how this was found).
            builder.credentialsProvider(DefaultCredentialsProvider.builder().build());
        }
        return builder.build();
    }
}

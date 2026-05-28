package com.bss.billing.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.SqsClientBuilder;

import java.net.URI;

@Configuration
public class AwsConfig {

    @Value("${aws.region:ap-southeast-1}")
    private String region;

    /** Set to http://localhost:4566 for LocalStack; leave empty in real AWS for IRSA. */
    @Value("${aws.endpoint-url:}")
    private String endpointOverride;

    @Bean
    public SqsClient sqsClient() {
        SqsClientBuilder builder = SqsClient.builder().region(Region.of(region));
        if (endpointOverride != null && !endpointOverride.isBlank()) {
            // LocalStack path — static dummy credentials, override endpoint.
            builder.endpointOverride(URI.create(endpointOverride))
                    .credentialsProvider(StaticCredentialsProvider.create(
                            AwsBasicCredentials.create("test", "test")));
        } else {
            // Real AWS — DefaultCredentialsProvider picks up IRSA on EKS.
            builder.credentialsProvider(DefaultCredentialsProvider.create());
        }
        return builder.build();
    }
}

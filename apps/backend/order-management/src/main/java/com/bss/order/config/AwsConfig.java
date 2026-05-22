package com.bss.order.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;

@Configuration
public class AwsConfig {

    @Bean
    public EventBridgeClient eventBridgeClient() {
        // DefaultCredentialsProvider picks up IRSA credentials automatically
        // when running on EKS — no static keys anywhere.
        return EventBridgeClient.builder()
                .region(Region.of(System.getenv().getOrDefault("AWS_REGION", "ap-southeast-1")))
                .credentialsProvider(DefaultCredentialsProvider.create())
                .build();
    }
}

package com.bss.billing.exception;

public class NotFoundException extends RuntimeException {
    public NotFoundException(String resource, String id) {
        super("%s not found: %s".formatted(resource, id));
    }
}

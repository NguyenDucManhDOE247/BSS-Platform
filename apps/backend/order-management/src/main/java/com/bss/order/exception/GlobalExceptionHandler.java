package com.bss.order.exception;

import com.bss.order.client.OfferingNotOrderableException;
import com.bss.order.client.UnknownOfferingException;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.client.RestClientException;

@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(NotFoundException.class)
    public ProblemDetail handleNotFound(NotFoundException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.getMessage());
    }

    @ExceptionHandler(UnknownOfferingException.class)
    public ProblemDetail handleUnknownOffering(UnknownOfferingException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.UNPROCESSABLE_ENTITY, ex.getMessage());
    }

    @ExceptionHandler(OfferingNotOrderableException.class)
    public ProblemDetail handleNotOrderable(OfferingNotOrderableException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.UNPROCESSABLE_ENTITY, ex.getMessage());
    }

    /**
     * B-13: product-catalog is down/slow and Resilience4j has either exhausted retries or
     * opened the circuit breaker (CallNotPermittedException, thrown instead of even trying
     * once the circuit is OPEN). Either way this is "try again shortly", not "your request is
     * broken" — 503, not 500.
     */
    @ExceptionHandler({CallNotPermittedException.class, RestClientException.class})
    public ProblemDetail handleCatalogUnavailable(Exception ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.SERVICE_UNAVAILABLE,
                "product-catalog is temporarily unavailable — please retry shortly");
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ProblemDetail handleValidation(MethodArgumentNotValidException ex) {
        var detail = ex.getBindingResult().getFieldErrors().stream()
                .findFirst()
                .map(e -> e.getField() + ": " + e.getDefaultMessage())
                .orElse("Validation failed");
        return ProblemDetail.forStatusAndDetail(HttpStatus.UNPROCESSABLE_ENTITY, detail);
    }
}

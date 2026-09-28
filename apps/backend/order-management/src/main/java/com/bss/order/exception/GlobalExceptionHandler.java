package com.bss.order.exception;

import com.bss.order.client.CustomerServiceUnavailableException;
import com.bss.order.client.NoCustomerProfileException;
import com.bss.order.client.OfferingNotOrderableException;
import com.bss.order.client.UnknownOfferingException;
import com.bss.order.service.CustomerNotActiveException;
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
     * B-13: product-catalog is down/slow and Resilience4j has exhausted retries (RestClientException).
     * This is "try again shortly", not "your request is broken" — 503, not 500.
     */
    @ExceptionHandler(RestClientException.class)
    public ProblemDetail handleCatalogUnavailable(Exception ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.SERVICE_UNAVAILABLE,
                "product-catalog is temporarily unavailable — please retry shortly");
    }

    /**
     * Circuit breaker đang OPEN — không gọi thử nữa. GĐ9 có 2 circuit breaker (productCatalog,
     * customerService): nói đúng TÊN cái đang mở, trước đây luôn báo "product-catalog" dù cái mở có
     * thể là customer-service → debug sai hướng.
     */
    @ExceptionHandler(CallNotPermittedException.class)
    public ProblemDetail handleCircuitOpen(CallNotPermittedException ex) {
        String which = "customerService".equals(ex.getCausingCircuitBreakerName())
                ? "customer-service" : "product-catalog";
        return ProblemDetail.forStatusAndDetail(HttpStatus.SERVICE_UNAVAILABLE,
                which + " is temporarily unavailable — please retry shortly");
    }

    // ---------- Giai đoạn 9 (ADR-008) ----------

    @ExceptionHandler(CustomerServiceUnavailableException.class)
    public ProblemDetail handleCustomerServiceUnavailable(CustomerServiceUnavailableException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.SERVICE_UNAVAILABLE,
                "customer-service is temporarily unavailable — please retry shortly");
    }

    @ExceptionHandler({NoCustomerProfileException.class, CustomerNotActiveException.class})
    public ProblemDetail handleCustomerNotReady(RuntimeException ex) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.UNPROCESSABLE_ENTITY, ex.getMessage());
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

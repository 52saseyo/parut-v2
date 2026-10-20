package com.parut.product.timedeal.presentation;

import com.parut.product.global.common.ApiResponse;
import com.parut.product.global.constant.HeaderConstants;
import com.parut.product.global.logging.TraceIdContext;
import com.parut.product.timedeal.application.dto.timedeal.TimeDealDetailResult;
import com.parut.product.timedeal.application.dto.timedealpurchase.TimeDealPurchaseConfirmCommand;
import com.parut.product.timedeal.application.metrics.timedeal.TimeDealPerformanceMetrics;
import com.parut.product.timedeal.application.port.in.timedeal.TimeDealQueryUseCase;
import com.parut.product.timedeal.application.port.in.timedealpurchase.TimeDealPurchaseCommandUseCase;
import com.parut.product.timedeal.presentation.dto.timedeal.response.TimeDealDetailResponse;
import com.parut.product.timedeal.presentation.dto.timedeal.request.TimeDealBulkDetailRequest;
import com.parut.product.timedeal.presentation.dto.timedealpurchase.request.TimeDealPurchaseCancelRequest;
import com.parut.product.timedeal.presentation.dto.timedealpurchase.request.TimeDealPurchaseReserveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;
import java.util.List;


@RestController
@RequestMapping("/api/v1/internal")
@RequiredArgsConstructor
public class InternalTimeDealController {

    private final TimeDealPurchaseCommandUseCase timeDealPurchaseCommandUseCase;
    private final TimeDealQueryUseCase timeDealQueryUseCase;
    private final TimeDealPerformanceMetrics performanceMetrics;


    // NOTE: 표시 정보가 전부 타임딜 자기 컬럼(스냅샷)이라 상품 조회 없이 한 번에 내려간다.
    @GetMapping("/time-deals/{timeDealId}")
    public ResponseEntity<ApiResponse<TimeDealDetailResponse>> getDetail(
            @PathVariable UUID timeDealId
    ) {
        TimeDealDetailResult timeDealDetailResult = timeDealQueryUseCase.getDetail(timeDealId);
        return ResponseEntity.ok(
                ApiResponse.success(
                        TimeDealDetailResponse.from(timeDealDetailResult), TraceIdContext.currentTraceId()));
    }

    @PostMapping("/time-deals/bulk")
    public ResponseEntity<ApiResponse<List<TimeDealDetailResponse>>> getDetailsByIds(
            @Valid @RequestBody TimeDealBulkDetailRequest request
    ) {
        List<TimeDealDetailResponse> response = timeDealQueryUseCase.getDetailsByIds(request.timeDealIds())
                .stream()
                .map(TimeDealDetailResponse::from)
                .toList();
        return ResponseEntity.ok(
                ApiResponse.success(response, TraceIdContext.currentTraceId()));
    }


    @PostMapping("/time-deals/{timeDealId}/purchases")
    public ResponseEntity<Void> reserve(
            @PathVariable UUID timeDealId,
            @RequestHeader(HeaderConstants.USER_ID) UUID userId,
            @Valid @RequestBody TimeDealPurchaseReserveRequest timeDealPurchaseReserveRequest
    ) {
        performanceMetrics.record(
                "timedeal.controller.reserve",
                () -> timeDealPurchaseCommandUseCase.reserve(
                        timeDealPurchaseReserveRequest.toCommand(timeDealId, userId)
                )
        );
        return ResponseEntity.status(HttpStatus.CREATED).build();
    }


    @PostMapping("/time-deal-purchases/{orderId}/confirm")
    public ResponseEntity<Void> confirm(
            @PathVariable UUID orderId
    ) {
        timeDealPurchaseCommandUseCase.confirm(new TimeDealPurchaseConfirmCommand(orderId));
        return ResponseEntity.noContent().build();
    }


    // NOTE: 배송 시작 전 주문 취소에서만 호출한다 — 환불 흐름은 재고를 복구하지 않으므로 대상이 아니다. 또한 그러한 요청을 검증할수있는게 타임딜쪽에서 알수없다.
    @PostMapping("/time-deal-purchases/{orderId}/cancel")
    public ResponseEntity<Void> cancel(
            @PathVariable UUID orderId,
            @RequestBody TimeDealPurchaseCancelRequest timeDealPurchaseCancelRequest
    ) {
        timeDealPurchaseCommandUseCase.cancel(timeDealPurchaseCancelRequest.toCommand(orderId));
        return ResponseEntity.noContent().build();
    }
}

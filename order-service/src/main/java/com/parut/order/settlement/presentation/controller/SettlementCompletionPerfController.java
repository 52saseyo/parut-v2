package com.parut.order.settlement.presentation.controller;

import java.util.UUID;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.parut.order.global.auth.RequireRole;
import com.parut.order.global.auth.UserRole;
import com.parut.order.global.common.ApiResponse;
import com.parut.order.settlement.application.SettlementCompletionJob;
import com.parut.order.settlement.presentation.dto.request.CompleteSettlementPerfRequest;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;

/** 정기 실행 시각을 기다리지 않고 정산 완료 작업을 검증하는 perf 전용 진입점이다. */
@Profile("perf")
@RestController
@RequestMapping("/api/v1/perf/settlements")
@RequiredArgsConstructor
public class SettlementCompletionPerfController {

    private final SettlementCompletionJob completionJob;

    @Value("${app.system-account-id}")
    private UUID systemUserId;

    // sellerId로 실험 대상을 한정하며 실제 정기 실행과 같은 Job을 호출한다.
    @PostMapping("/complete")
    @RequireRole(UserRole.ADMIN)
    public ApiResponse<SettlementCompletionJob.CompletionRun> completeSettlements(
            @Valid @RequestBody CompleteSettlementPerfRequest request
    ) {
        return ApiResponse.success(completionJob.run(request.cutoff(), systemUserId, request.sellerId()));
    }
}

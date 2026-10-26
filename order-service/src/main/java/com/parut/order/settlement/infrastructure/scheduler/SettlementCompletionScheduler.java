package com.parut.order.settlement.infrastructure.scheduler;

import java.time.Instant;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.parut.order.settlement.application.SettlementCompletionJob;

/** 공통 시스템 처리자로 정산을 완료하며, settlement.completion.cron 주기로 실행한다. */
@Component
public class SettlementCompletionScheduler {

    private final SettlementCompletionJob completionJob;
    private final UUID systemUserId;

    public SettlementCompletionScheduler(SettlementCompletionJob completionJob,
            @Value("${app.system-account-id}") UUID systemUserId) {
        this.completionJob = completionJob;
        this.systemUserId = systemUserId;
    }

    @Scheduled(cron = "${settlement.completion.cron}", zone = "Asia/Seoul")
    public void completeSettlements() {
        completionJob.run(Instant.now(), systemUserId, null);
    }
}

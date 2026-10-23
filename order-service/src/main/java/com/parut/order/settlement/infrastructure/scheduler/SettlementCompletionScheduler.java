package com.parut.order.settlement.infrastructure.scheduler;

import java.time.Instant;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.parut.order.settlement.application.SettlementCompletionJob;

/** 공통 시스템 처리자로 정산을 완료하며, cron을 설정한 일반 환경에서 정기 실행한다. */
@Component
@Profile("!perf")
public class SettlementCompletionScheduler {

    private final SettlementCompletionJob completionJob;
    private final UUID systemUserId;

    public SettlementCompletionScheduler(SettlementCompletionJob completionJob,
            @Value("${app.system-account-id}") UUID systemUserId) {
        this.completionJob = completionJob;
        this.systemUserId = systemUserId;
    }

    // cron 미설정 시 비활성이다. perf에서는 이 스케줄러 대신 테스트 API로 같은 Job을 호출한다.
    @Scheduled(cron = "${settlement.completion.cron:-}", zone = "Asia/Seoul")
    public void completeSettlements() {
        completionJob.run(Instant.now(), systemUserId, null);
    }
}

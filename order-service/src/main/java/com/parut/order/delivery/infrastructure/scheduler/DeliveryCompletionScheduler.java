package com.parut.order.delivery.infrastructure.scheduler;

import java.time.DateTimeException;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.parut.order.delivery.application.DeliveryService;
import com.parut.order.delivery.domain.DeliveryStatus;
import com.parut.order.delivery.infrastructure.persistence.DeliveryRepository;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 배송 자동완료 작업을 주기적으로 실행한다.
 *
 * <p>실행 간격은 {@code delivery.completion.fixed-delay}로 조정하며,
 * 잘못된 간격은 기본 60초로 대체한다. 완료 대기 시간은 실행 시 검증한다.
 */
@Component
@ConditionalOnProperty(name = "delivery.completion.enabled", havingValue = "true", matchIfMissing = true)
@RequiredArgsConstructor
@Slf4j
public class DeliveryCompletionScheduler {

    private static final int BATCH_SIZE = 100;

    private final DeliveryRepository deliveryRepository;
    private final DeliveryService deliveryService;

    /** 시연 기본값은 배송 시작 60초 후 자동완료이다. */
    @Value("${delivery.completion.delay-seconds:60}")
    private String completionDelaySeconds;

    @Scheduled(fixedDelayString = "#{@deliveryCompletionFixedDelay}")
    public void runDeliveryCompletion() {
        Instant completionTime = Instant.now();
        Instant completionThreshold;
        try {
            long delaySeconds = Long.parseLong(completionDelaySeconds.trim());
            if (delaySeconds < 0) {
                log.error("배송 자동완료 실패: 완료 대기 시간이 음수입니다. delaySeconds={}", delaySeconds);
                return;
            }
            completionThreshold = completionTime.minusSeconds(delaySeconds);
        } catch (NumberFormatException | DateTimeException e) {
            log.error("배송 자동완료 기준 시각 계산 실패 delaySeconds={}", completionDelaySeconds, e);
            return;
        }
        UUID cursorId = new UUID(0L, 0L);
        Pageable pageable = PageRequest.of(0, BATCH_SIZE);
        List<UUID> deliveryIds;
        do {
            deliveryIds = deliveryRepository.findEligibleIds(
                    DeliveryStatus.SHIPPED, completionThreshold, cursorId, pageable);
            for (UUID deliveryId : deliveryIds) {
                try {
                    deliveryService.completeEligibleDelivery(deliveryId, completionTime, completionThreshold);
                } catch (RuntimeException e) {
                    log.error("배송 자동완료 실패 deliveryId={}", deliveryId, e);
                }
            }
            if (!deliveryIds.isEmpty()) {
                cursorId = deliveryIds.get(deliveryIds.size() - 1);
            }
        } while (deliveryIds.size() == BATCH_SIZE);
    }
}

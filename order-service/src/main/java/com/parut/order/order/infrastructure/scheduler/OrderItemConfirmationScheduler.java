package com.parut.order.order.infrastructure.scheduler;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.data.domain.PageRequest;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.parut.order.order.application.OrderItemConfirmationService;
import com.parut.order.order.domain.OrderItemStatus;
import com.parut.order.order.infrastructure.persistence.OrderItemRepository;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 배송 완료 후 7일이 지난 ORDERED 주문상품의 자동 구매확정을 실행한다.
 *
 * <p>Repository 조회는 후보 선별이며 실제 배송 완료 시각은 건별로 재검증한다.
 * 한 상품의 실패는 다음 상품 처리를 막지 않는다. 현재는 100건 UUID 커서 조회와 건별 배송 조회를 사용하며,
 * 벌크 조회와 분산 락은 데이터 규모 또는 다중 인스턴스 경합이 문제가 될 때 재검토한다.
 */
@Component
@ConditionalOnProperty(name = "order.auto-confirmation.enabled", havingValue = "true", matchIfMissing = true)
@RequiredArgsConstructor
@Slf4j
public class OrderItemConfirmationScheduler {

    private static final int BATCH_SIZE = 100;
    private static final Duration CONFIRMATION_DELAY = Duration.ofDays(7);

    private final OrderItemRepository orderItemRepository;
    private final OrderItemConfirmationService orderItemConfirmationService;

    @Scheduled(fixedDelayString = "${order.auto-confirmation.fixed-delay:60000}")
    public void runOrderItemConfirmation() {
        Instant confirmationTime = Instant.now();
        Instant confirmationThreshold = confirmationTime.minus(CONFIRMATION_DELAY);
        UUID cursorId = new UUID(0L, 0L);
        List<UUID> orderItemIds;

        do {
            orderItemIds = orderItemRepository.findAutoConfirmationCandidateIds(
                    OrderItemStatus.ORDERED, cursorId, PageRequest.of(0, BATCH_SIZE));
            for (UUID orderItemId : orderItemIds) {
                try {
                    orderItemConfirmationService.confirmEligibleOrderItem(
                            orderItemId, confirmationTime, confirmationThreshold);
                } catch (RuntimeException e) {
                    log.error("자동 구매확정 실패 orderItemId={}", orderItemId, e);
                }
            }
            if (!orderItemIds.isEmpty()) {
                cursorId = orderItemIds.get(orderItemIds.size() - 1);
            }
        } while (orderItemIds.size() == BATCH_SIZE);
    }
}

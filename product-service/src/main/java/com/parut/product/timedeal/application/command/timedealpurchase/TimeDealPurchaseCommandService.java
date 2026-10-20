package com.parut.product.timedeal.application.command.timedealpurchase;

import com.parut.product.global.exception.BusinessException;
import com.parut.product.global.exception.ErrorCode;
import com.parut.product.global.common.AuditorContext;
import com.parut.product.global.constant.AuditorConstants;
import com.parut.product.timedeal.application.dto.timedealpurchase.TimeDealPurchaseCancelCommand;
import com.parut.product.timedeal.application.dto.timedealpurchase.TimeDealPurchaseConfirmCommand;
import com.parut.product.timedeal.application.dto.timedealpurchase.TimeDealPurchaseReserveCommand;
import com.parut.product.timedeal.application.exception.TimeDealReservationExpiredException;
import com.parut.product.timedeal.application.metrics.timedeal.TimeDealPerformanceMetrics;
import com.parut.product.timedeal.application.port.in.timedealpurchase.TimeDealPurchaseCommandUseCase;
import com.parut.product.timedeal.application.port.out.timedeal.TimeDealRepository;
import com.parut.product.timedeal.application.port.out.timedealpurchase.TimeDealPurchaseRepository;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockCompensationResult;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockRepository;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockReservationPort;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockReservationResult;
import com.parut.product.timedeal.domain.common.TimeDealPolicy;
import com.parut.product.timedeal.domain.common.TimeDealPurchaseConfirmResult;
import com.parut.product.timedeal.domain.timedeal.TimeDeal;
import com.parut.product.timedeal.domain.timedealpurchase.TimeDealPurchase;
import com.parut.product.timedeal.domain.timedealpurchase.TimeDealPurchaseStatus;
import com.parut.product.timedeal.domain.timedealstock.TimeDealStock;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.UUID;


@Slf4j
@Service
@RequiredArgsConstructor
public class TimeDealPurchaseCommandService implements TimeDealPurchaseCommandUseCase {

    private final TimeDealRepository timeDealRepository;
    private final TimeDealStockRepository timeDealStockRepository;
    private final TimeDealPurchaseRepository timeDealPurchaseRepository;
    private final TimeDealPolicy timeDealPolicy;
    private final TimeDealStockReservationPort timeDealStockReservationPort;
    private final TimeDealStockRestoreOutbox stockRestoreOutbox;
    private final TimeDealPurchaseExpirationProcessor timeDealPurchaseExpirationProcessor;
    private final TimeDealPerformanceMetrics performanceMetrics;


    // NOTE: 애그리거트 조율은 전부 TimeDealPolicy를 경유한다. 여기 남는 것은 조회·저장·트랜잭션 경계와
    // 저장소 조회가 필요해 도메인이 지킬 수 없는 검증(orderId 중복, 누적 구매 수량 집계)뿐이다.
    @Override
    @Transactional
    public void reserve(TimeDealPurchaseReserveCommand timeDealPurchaseReserveCommand) {
        performanceMetrics.recordUntilTransactionCompletion("timedeal.transaction.total");
        performanceMetrics.record("timedeal.reserve.total", () -> reserveInternal(timeDealPurchaseReserveCommand));
    }

    private void reserveInternal(TimeDealPurchaseReserveCommand timeDealPurchaseReserveCommand) {
        // NOTE: 같은 orderId가 이미 있으면, 내용이 원본과 같고 아직 RESERVED일 때만 재시도로 보고
        // 재고를 다시 선점하지 않고 성공시킨다(멱등). 하나라도 다르면 orderId 충돌이라 409.
        // order_id unique 제약이 최종 방어선이고, 이 검사는 제약 위반(500)을 409로 바꿔준다.
        TimeDealPurchase existingTimeDealPurchase = performanceMetrics.record(
                "timedeal.db.purchase-by-order-query",
                () -> timeDealPurchaseRepository.findByOrderId(timeDealPurchaseReserveCommand.orderId())
        ).orElse(null);
        if (existingTimeDealPurchase != null) {
            boolean sameRequest = existingTimeDealPurchase.isReserved() && existingTimeDealPurchase.isSameReservationRequest(timeDealPurchaseReserveCommand.timeDealId(), timeDealPurchaseReserveCommand.userId(), timeDealPurchaseReserveCommand.quantity());
            if (!sameRequest) {
                throw new BusinessException(ErrorCode.TIME_DEAL_PURCHASE_ALREADY_EXISTS);
            }
            log.warn("[TimeDealPurchase] 이미 선점된 주문에 동일 예약 요청이 재도착. orderId={}", timeDealPurchaseReserveCommand.orderId());
            return;
        }

        // 재고 동시성은 추후 Redis 원자적 연산으로 제어하므로 타임딜 행은 일반 조회한다.
        TimeDeal timeDeal = performanceMetrics.record(
                "timedeal.db.time-deal-query",
                () -> timeDealRepository.findById(timeDealPurchaseReserveCommand.timeDealId())
        ).orElseThrow(() -> new BusinessException(ErrorCode.TIME_DEAL_NOT_FOUND));
        TimeDealStock timeDealStock = performanceMetrics.record(
                "timedeal.db.stock-query",
                () -> timeDealStockRepository.findByTimeDealId(timeDealPurchaseReserveCommand.timeDealId())
        ).orElseThrow(() -> new BusinessException(ErrorCode.TIME_DEAL_STOCK_NOT_FOUND));

        // NOTE: 합산 대상이 RESERVED + CONFIRMED이고 CANCELLED가 빠지는 것은 어댑터가 보장한다.
        int alreadyPurchasedQuantity = performanceMetrics.record(
                "timedeal.db.active-purchase-query",
                () -> timeDealPurchaseRepository.sumActiveQuantity(
                        timeDealPurchaseReserveCommand.timeDealId(),
                        timeDealPurchaseReserveCommand.userId()
                )
        );

        // 잠금과 조회를 마친 시각으로 한 번 판정한다. 대기 전 시각을 쓰면 종료 후에도 선점될 수 있다.
        Instant now = Instant.now();
        // Redis 선점 전에 타임딜 기간·수량·1인당 한도만 검증한다. 이 단계에서는 DB 재고를 변경하지 않는다.
        timeDealPolicy.validateReservation(timeDeal, timeDealStock, timeDealPurchaseReserveCommand.quantity(), alreadyPurchasedQuantity, now);

        TimeDealStockReservationResult reservationResult;
        try {
            reservationResult = timeDealStockReservationPort.reserve(timeDealPurchaseReserveCommand.timeDealId(), timeDealStock.getId(), timeDealPurchaseReserveCommand.orderId(), timeDealPurchaseReserveCommand.quantity());
        } catch (RuntimeException redisFailure) {
            log.error("[TimeDealPurchase] Redis 선점 요청 실패. timeDealId={}, stockId={}, orderId={}, quantity={}", timeDealPurchaseReserveCommand.timeDealId(), timeDealStock.getId(), timeDealPurchaseReserveCommand.orderId(), timeDealPurchaseReserveCommand.quantity(), redisFailure);
            throw redisFailure;
        }

        log.debug("[TimeDealPurchase] Redis 선점 결과. timeDealId={}, stockId={}, orderId={}, quantity={}, result={}", timeDealPurchaseReserveCommand.timeDealId(), timeDealStock.getId(), timeDealPurchaseReserveCommand.orderId(), timeDealPurchaseReserveCommand.quantity(), reservationResult);

        switch (reservationResult) {
            case RESERVED -> {
                // Redis 선점과 DB 구매 이력 저장을 함께 완료한다.
            }
            case DUPLICATE_ORDER -> {
                log.warn("[TimeDealPurchase] Redis 중복 주문 선점 요청. timeDealId={}, orderId={}", timeDealPurchaseReserveCommand.timeDealId(), timeDealPurchaseReserveCommand.orderId());
                throw new BusinessException(ErrorCode.TIME_DEAL_PURCHASE_ALREADY_EXISTS);
            }
            case SOLD_OUT, INSUFFICIENT_STOCK -> throw new BusinessException(ErrorCode.TIME_DEAL_STOCK_INSUFFICIENT);
            case INVALID_QUANTITY -> throw new BusinessException(ErrorCode.TIME_DEAL_INVALID_PURCHASE_QUANTITY);
            case STOCK_NOT_INITIALIZED -> {
                log.error("[TimeDealPurchase] Redis 재고 Key가 초기화되지 않음. timeDealId={}, stockId={}", timeDealPurchaseReserveCommand.timeDealId(), timeDealStock.getId());
                throw new IllegalStateException("Redis stock key is not initialized");
            }
        }

        // Redis 선점 성공 이후 DB 재고 상태를 조건부 원자적 UPDATE로 반영한다.
        // 조회한 TimeDealStock 엔티티를 수정·저장하지 않아 동시 요청의 lost update를 방지한다.
        try {
            performanceMetrics.record("timedeal.db.stock-update", () -> {
                boolean stockUpdated = timeDealStockRepository.reserveQuantityAtomically(
                        timeDealPurchaseReserveCommand.timeDealId(),
                        timeDealPurchaseReserveCommand.quantity()
                );
                if (!stockUpdated) {
                    throw new IllegalStateException("DB stock update failed");
                }
            });

            TimeDealPurchase timeDealPurchase = timeDealPolicy.createReservedPurchase(
                    timeDeal,
                    timeDealStock,
                    timeDealPurchaseReserveCommand.orderId(),
                    timeDealPurchaseReserveCommand.userId(),
                    timeDealPurchaseReserveCommand.quantity(),
                    alreadyPurchasedQuantity,
                    now
            );

            performanceMetrics.record("timedeal.db.purchase-save", () -> {
                // save만 사용하면 DB 오류가 트랜잭션 커밋 시점에 발생해 이 catch를 지나칠 수 있으므로
                // 보상 판단을 위해 flush까지 이곳에서 수행한다.
                timeDealPurchaseRepository.saveAndFlush(timeDealPurchase);
            });
            log.debug("[TimeDealPurchase] Redis 선점 및 DB 구매 저장 성공. timeDealId={}, stockId={}, orderId={}, quantity={}", timeDealPurchaseReserveCommand.timeDealId(), timeDealStock.getId(), timeDealPurchaseReserveCommand.orderId(), timeDealPurchaseReserveCommand.quantity());
        } catch (RuntimeException databaseFailure) {
            log.error("[TimeDealPurchase] Redis 선점 후 DB 구매 저장 실패. 보상을 시도한다. timeDealId={}, stockId={}, orderId={}, quantity={}", timeDealPurchaseReserveCommand.timeDealId(), timeDealStock.getId(), timeDealPurchaseReserveCommand.orderId(), timeDealPurchaseReserveCommand.quantity(), databaseFailure);
            compensateRedisReservation(timeDealPurchaseReserveCommand, timeDealStock, databaseFailure);
            throw databaseFailure;
        }
    }

    private void compensateRedisReservation(TimeDealPurchaseReserveCommand command, TimeDealStock stock, RuntimeException databaseFailure) {
        try {
            TimeDealStockCompensationResult result = timeDealStockReservationPort.compensate(command.timeDealId(), stock.getId(), command.orderId());
            if (result == TimeDealStockCompensationResult.STOCK_NOT_INITIALIZED) {
                throw new IllegalStateException("Redis stock key is not initialized during compensation");
            }
            log.warn("[TimeDealPurchase] DB 저장 실패 후 Redis 선점 보상 완료. timeDealId={}, stockId={}, orderId={}, result={}", command.timeDealId(), stock.getId(), command.orderId(), result);
        } catch (RuntimeException compensationFailure) {
            databaseFailure.addSuppressed(compensationFailure);
            log.error("[TimeDealPurchase] DB 저장 실패 후 Redis 선점 보상도 실패. 수동 또는 재처리가 필요하다. " + "timeDealId={}, stockId={}, orderId={}", command.timeDealId(), stock.getId(), command.orderId(), compensationFailure);
        }
    }


    // NOTE: noRollbackFor가 필요한 이유는 만료 정리(구매 이력 취소 + 재고 복구)를 커밋시켜야 하는데
    // BusinessException이 RuntimeException이라 그냥 던지면 그 정리까지 롤백되기 때문이다.
    @Override
    @Transactional(noRollbackFor = TimeDealReservationExpiredException.class)
    public void confirm(TimeDealPurchaseConfirmCommand timeDealPurchaseConfirmCommand) {
        Instant now = Instant.now();

        // confirm/cancel은 동일 구매에 대한 상태 전이를 직렬화해야 하므로 구매 행을 먼저 잠근다.
        TimeDealPurchase timeDealPurchase = timeDealPurchaseRepository.findByOrderIdForUpdate(timeDealPurchaseConfirmCommand.orderId()).orElseThrow(() -> new BusinessException(ErrorCode.TIME_DEAL_PURCHASE_NOT_FOUND));
        TimeDeal timeDeal = timeDealRepository.findById(timeDealPurchase.getTimeDealId()).orElseThrow(() -> new BusinessException(ErrorCode.TIME_DEAL_NOT_FOUND));
        TimeDealStock timeDealStock = timeDealStockRepository.findByTimeDealIdForUpdate(timeDealPurchase.getTimeDealId()).orElseThrow(() -> new BusinessException(ErrorCode.TIME_DEAL_STOCK_NOT_FOUND));

        TimeDealPurchaseConfirmResult timeDealPurchaseConfirmResult = timeDealPolicy.confirmSale(timeDeal, timeDealPurchase, timeDealStock, now);

        // NOTE: 이 예외만 noRollbackFor에 지정되어 있어, 위 정리는 커밋되고 응답은 409가 나간다.
        if (timeDealPurchaseConfirmResult == TimeDealPurchaseConfirmResult.CANCELLED) {
            publishReservationReleasedEvent(timeDealPurchase, timeDealStock);
            throw new TimeDealReservationExpiredException();
        }
    }


    @Override
    @Transactional
    public void cancel(TimeDealPurchaseCancelCommand timeDealPurchaseCancelCommand) {
        // confirm과 같은 순서(구매 행 -> 재고 행)로 잠가 교차 잠금에 의한 deadlock을 피한다.
        TimeDealPurchase timeDealPurchase = timeDealPurchaseRepository.findByOrderIdForUpdate(timeDealPurchaseCancelCommand.orderId()).orElseThrow(() -> new BusinessException(ErrorCode.TIME_DEAL_PURCHASE_NOT_FOUND));

        // NOTE: 멱등 처리 자체는 TimeDealPolicy가 하고, 여기서는 관측을 위해 로그만 남긴다.
        if (timeDealPurchase.getStatus() == TimeDealPurchaseStatus.CANCELLED) {
            log.warn("[TimeDealPurchase] 이미 취소된 구매에 대한 취소 요청. orderId={}, reason={}", timeDealPurchaseCancelCommand.orderId(), timeDealPurchaseCancelCommand.reason());
        }

        TimeDealStock timeDealStock = timeDealStockRepository.findByTimeDealIdForUpdate(timeDealPurchase.getTimeDealId()).orElseThrow(() -> new BusinessException(ErrorCode.TIME_DEAL_STOCK_NOT_FOUND));

        boolean reservationReleased = timeDealPurchase.getStatus() != TimeDealPurchaseStatus.CANCELLED;
        timeDealPolicy.cancelPurchase(timeDealPurchase, timeDealStock, timeDealPurchaseCancelCommand.reason());
        if (reservationReleased) {
            publishReservationReleasedEvent(timeDealPurchase, timeDealStock);
        }
    }

    @Override
    public void expireReservations() {
        Instant cutoff = Instant.now();
        Instant cursorExpiresAt = null;
        UUID cursorId = null;
        int processedCount = 0;
        int failedCount = 0;
        long startedAtNanos = System.nanoTime();

        log.info("[TimeDealPurchase] 선점 만료 배치 시작: cutoff={}", cutoff);

        while (true) {
            List<TimeDealPurchase> purchases = (cursorExpiresAt == null)
                    ? timeDealPurchaseRepository.findFirstExpiredReservationBatch(cutoff, 100)
                    : timeDealPurchaseRepository.findNextExpiredReservationBatchByCursor(
                            cutoff, cursorExpiresAt, cursorId, 100);

            if (purchases.isEmpty()) {
                log.info("[TimeDealPurchase] 선점 만료 배치 완료: processedCount={}, failedCount={}, elapsedMillis={}",
                        processedCount, failedCount, elapsedMillis(startedAtNanos));
                return;
            }

            for (TimeDealPurchase purchase : purchases) {
                try {
                    // NOTE: 스케쥴러/배치 등에서 항상 auditor를 설정해주고 clear해준다. 이를 안하면 createdBy, updatedBy 등 null 문제 생김
                    AuditorContext.set(AuditorConstants.BATCH_SYSTEM_USER_ID);
                    timeDealPurchaseExpirationProcessor.expireOneReservation(purchase.getId());
                    processedCount++;
                } catch (Exception exception) {
                    failedCount++;
                    log.error("[TimeDealPurchase] 선점 만료 처리 실패: purchaseId={}", purchase.getId(), exception);
                } finally {
                    AuditorContext.clear();
                }
            }

            TimeDealPurchase lastPurchase = purchases.getLast();
            cursorExpiresAt = lastPurchase.getExpiresAt();
            cursorId = lastPurchase.getId();
        }
    }

    private long elapsedMillis(long startedAtNanos) {
        return (System.nanoTime() - startedAtNanos) / 1_000_000;
    }

    private void publishReservationReleasedEvent(TimeDealPurchase purchase, TimeDealStock stock) {
        stockRestoreOutbox.enqueue(purchase, stock);
    }
}

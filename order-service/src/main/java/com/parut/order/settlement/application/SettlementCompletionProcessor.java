package com.parut.order.settlement.application;

import java.time.Instant;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

import org.springframework.data.domain.AuditorAware;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import com.parut.order.global.exception.BusinessException;
import com.parut.order.global.exception.ErrorCode;
import com.parut.order.settlement.domain.Settlement;
import com.parut.order.settlement.domain.SettlementStatus;
import com.parut.order.settlement.infrastructure.persistence.SettlementRepository;

import lombok.RequiredArgsConstructor;

/**
 * 수동 경로는 건별로, 자동 경로는 청크별로 독립된 트랜잭션에서 완료한다.
 *
 * <p>REQUIRES_NEW로 커밋 단위를 격리하며, 실패해도 앞서 커밋한 정산은 되돌리지 않는다.
 * 새 트랜잭션은 프록시를 거칠 때만 적용되므로 반드시 별도 Bean으로 호출한다.
 */
@Service
@RequiredArgsConstructor
public class SettlementCompletionProcessor {

    private final SettlementRepository settlementRepository;
    private final AuditorAware<String> auditorProvider;

    /**
     * 관리자 요청의 정산 한 건을 조회하고 완료한다. 커밋은 메서드 반환 과정에서 프록시가 수행한다.
     *
     * <p>항목 실패는 호출자가 결과로 변환할 수 있도록 {@link BusinessException}으로 던지고 여기서 삼키지 않는다.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public Settlement completeOne(UUID settlementId, UUID processedBy, Instant completionTime) {
        Settlement settlement = settlementRepository.findById(settlementId)
                .orElseThrow(() -> new BusinessException(ErrorCode.SETTLEMENT_NOT_FOUND));

        if (settlement.getStatus() != SettlementStatus.PENDING) {
            throw new BusinessException(ErrorCode.SETTLEMENT_ALREADY_COMPLETED);
        }
        if (completionTime.isBefore(settlement.getEligibleAt())) {
            throw new BusinessException(ErrorCode.INVALID_STATE_TRANSITION);
        }

        // 변경 감지로 반영되므로 별도 save는 호출하지 않는다.
        settlement.complete(completionTime, processedBy);
        return settlement;
    }

    /**
     * 자동 작업의 한 청크를 공통 완료 시각과 조건부 UPDATE로 처리한다.
     *
     * <p>별도 Bean의 프록시가 청크 전체를 커밋한 뒤 호출자에게 결과를 반환한다.
     * DB 오류는 청크 전체를 롤백하고 전파하며, 이전 청크의 커밋에는 영향을 주지 않는다.
     * 완료 자격 정책을 바꾸면 수동 검증/엔티티 메서드와 자동 후보/UPDATE 조건을 함께 확인한다.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public ChunkCompletion completeChunk(List<UUID> settlementIds, UUID processedBy, Instant cutoff) {
        if (settlementIds == null || settlementIds.isEmpty()
                || settlementIds.stream().anyMatch(Objects::isNull)
                || settlementIds.stream().distinct().count() != settlementIds.size()
                || processedBy == null || cutoff == null) {
            throw new BusinessException(ErrorCode.INVALID_INPUT_VALUE);
        }
        Instant completedAt = Instant.now();
        long mutationStarted = System.nanoTime();
        int updated = settlementRepository.completePendingChunk(
                settlementIds, SettlementStatus.PENDING, SettlementStatus.COMPLETED,
                cutoff, completedAt, processedBy, auditorProvider.getCurrentAuditor().orElse(null));
        // 후보 조회 뒤 완료된 항목 등은 조건에서 제외되므로 건수 차이만으로 롤백하지 않는다.
        return new ChunkCompletion(updated, System.nanoTime() - mutationStarted);
    }

    public record ChunkCompletion(int updated, long mutationNanos) {
    }
}

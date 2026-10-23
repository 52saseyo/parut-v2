package com.parut.order.settlement.infrastructure.persistence;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import com.parut.order.settlement.domain.Settlement;
import com.parut.order.settlement.domain.SettlementStatus;

/**
 * 정산 조회와 자동 완료 대상 선정, 조건부 완료 갱신을 제공한다.
 *
 * <p>판매자 목록은 생성 시각이 같은 정산에 ID 내림차순을 보조 기준으로 사용해 Cursor 경계를 고정한다.
 * 관리자 목록은 정렬을 {@link Pageable}로 받아 오프셋 페이지로 조회한다.
 */
public interface SettlementRepository extends JpaRepository<Settlement, UUID> {

    /**
     * 갱신 시점에도 대기 상태와 cutoff 자격을 만족하는 정산 묶음만 완료한다.
     *
     * <p>엔티티 메서드와 JPA 감사/버전 자동 처리를 우회하므로 감사 필드와 version 증가를 명시한다.
     * version 증가는 먼저 읽은 수동 요청의 오래된 엔티티 갱신도 충돌시키기 위해 유지한다.
     * 반환값은 갱신 건수이며, 조건에 맞지 않아 제외된 항목의 상세 사유는 조회하지 않는다.
     */
    @Modifying
    @Query("""
            UPDATE Settlement s
            SET s.status = :completed, s.settledAt = :completedAt, s.processedBy = :processedBy,
                s.updatedAt = :completedAt, s.updatedBy = :auditor, s.version = s.version + 1
            WHERE s.id IN :ids AND s.status = :pending AND s.eligibleAt <= :cutoff
            """)
    int completePendingChunk(
            @Param("ids") List<UUID> ids,
            @Param("pending") SettlementStatus pending,
            @Param("completed") SettlementStatus completed,
            @Param("cutoff") Instant cutoff,
            @Param("completedAt") Instant completedAt,
            @Param("processedBy") UUID processedBy,
            @Param("auditor") String auditor
    );

    // 후보 조회 뒤 상태가 바뀔 수 있으므로 완료 자격은 completePendingChunk의 WHERE에서도 확인한다.
    @Query("""
            SELECT s.id FROM Settlement s
            WHERE s.status = :status AND s.eligibleAt <= :cutoff
              AND s.id > :cursorId
              AND (cast(:sellerId as uuid) IS NULL OR s.sellerId = :sellerId)
            ORDER BY s.id
            """)
    List<UUID> findCompletionCandidateIds(
            @Param("status") SettlementStatus status,
            @Param("cutoff") Instant cutoff,
            @Param("cursorId") UUID cursorId,
            @Param("sellerId") UUID sellerId,
            Pageable pageable
    );

    @Query("""
            SELECT settlement FROM Settlement settlement
            WHERE settlement.sellerId = :sellerId
              AND settlement.status = :status
              AND (cast(:cursor as timestamp) IS NULL OR settlement.createdAt < :cursor
                   OR (settlement.createdAt = :cursor AND settlement.id < :cursorId))
            ORDER BY settlement.createdAt DESC, settlement.id DESC
            """)
    List<Settlement> findSellerSettlements(
            @Param("sellerId") UUID sellerId,
            @Param("status") SettlementStatus status,
            @Param("cursor") Instant cursor,
            @Param("cursorId") UUID cursorId,
            Pageable pageable
    );

    @Query("""
            SELECT settlement FROM Settlement settlement
            WHERE settlement.status = :status
              AND (cast(:sellerId as uuid) IS NULL OR settlement.sellerId = :sellerId)
            """)
    Page<Settlement> findAdminSettlements(
            @Param("sellerId") UUID sellerId,
            @Param("status") SettlementStatus status,
            Pageable pageable
    );
}

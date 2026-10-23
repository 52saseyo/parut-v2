package com.parut.order.settlement.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.stream.IntStream;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;
import org.springframework.context.annotation.Import;
import org.springframework.data.domain.PageRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import com.parut.order.global.config.JpaAuditingConfig;
import com.parut.order.global.exception.ErrorCode;
import com.parut.order.order.application.port.in.OrderItemQueryUseCase;
import com.parut.order.settlement.domain.Settlement;
import com.parut.order.settlement.domain.SettlementStatus;
import com.parut.order.settlement.infrastructure.persistence.SettlementRepository;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;

@DataJpaTest(properties = {
        "spring.flyway.enabled=false",
        "spring.jpa.hibernate.ddl-auto=create-drop"
})
@ActiveProfiles("test")
@Import({
        SettlementService.class,
        SettlementCompletionProcessor.class,
        SettlementCompletionJob.class,
        SettlementCompletionMetrics.class,
        SimpleMeterRegistry.class,
        JpaAuditingConfig.class
})
// 완료 처리의 커밋 경계를 확인하므로 테스트 전체를 트랜잭션으로 감싸지 않는다.
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class SettlementCompletionTransactionTest {

    private static final UUID ADMIN_ID = UUID.fromString("33333333-3333-3333-3333-333333333333");
    private static final UUID SELLER_ID = UUID.fromString("22222222-2222-2222-2222-222222222222");
    private static final Instant ELIGIBLE_AT = Instant.parse("2026-09-19T00:00:00Z");
    private static final Instant COMPLETION_TIME = Instant.parse("2026-09-20T00:00:00Z");
    private static final Instant ALREADY_SETTLED_AT = Instant.parse("2026-09-19T12:00:00Z");

    @Autowired
    private SettlementService settlementService;

    @Autowired
    private SettlementRepository settlementRepository;

    @Autowired
    private SettlementCompletionJob completionJob;

    @Autowired
    private SimpleMeterRegistry meterRegistry;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @MockitoBean
    private OrderItemQueryUseCase orderItemQueryUseCase;

    @Test
    @DisplayName("항목 실패 앞뒤의 정산을 각각 독립된 트랜잭션으로 커밋한다")
    void 항목_실패_앞뒤_정산_독립_커밋() {
        Settlement first = settlementRepository.save(pendingSettlement());
        Settlement completed = settlementRepository.save(completedSettlement());
        Settlement third = settlementRepository.save(pendingSettlement());

        List<SettlementCompletionResult> results = settlementService.completeSettlements(
                List.of(first.getId(), completed.getId(), third.getId()), ADMIN_ID, COMPLETION_TIME);

        // 결과는 요청 순서를 유지하고 실패 항목도 같은 목록에 담긴다.
        assertThat(results).extracting(SettlementCompletionResult::settlementId)
                .containsExactly(first.getId(), completed.getId(), third.getId());
        assertThat(results).extracting(SettlementCompletionResult::isSuccess)
                .containsExactly(true, false, true);
        assertThat(results.get(1).errorCode()).isEqualTo(ErrorCode.SETTLEMENT_ALREADY_COMPLETED);

        // 조율 트랜잭션이 없으므로 아래 조회는 커밋된 상태를 다시 읽는다.
        Settlement reloadedFirst = settlementRepository.findById(first.getId()).orElseThrow();
        assertThat(reloadedFirst.getStatus()).isEqualTo(SettlementStatus.COMPLETED);
        assertThat(reloadedFirst.getSettledAt()).isEqualTo(COMPLETION_TIME);
        assertThat(reloadedFirst.getProcessedBy()).isEqualTo(ADMIN_ID);

        Settlement reloadedThird = settlementRepository.findById(third.getId()).orElseThrow();
        assertThat(reloadedThird.getStatus()).isEqualTo(SettlementStatus.COMPLETED);
        assertThat(reloadedThird.getSettledAt()).isEqualTo(COMPLETION_TIME);
        assertThat(reloadedThird.getProcessedBy()).isEqualTo(ADMIN_ID);

        Settlement reloadedCompleted = settlementRepository.findById(completed.getId()).orElseThrow();
        assertThat(reloadedCompleted.getStatus()).isEqualTo(SettlementStatus.COMPLETED);
        assertThat(reloadedCompleted.getSettledAt()).isEqualTo(ALREADY_SETTLED_AT);
        assertThat(reloadedCompleted.getProcessedBy()).isEqualTo(ADMIN_ID);
    }

    @Test
    @DisplayName("자동 완료 건수는 청크 커밋 후 누적하고 재실행에서는 증가하지 않는다")
    void 자동_완료_건수와_재실행_메트릭() {
        UUID sellerId = UUID.randomUUID();
        savePendingSettlements(sellerId, 103);
        settlementRepository.save(Settlement.create(
                UUID.randomUUID(), sellerId, 10_000L, 10_000L, COMPLETION_TIME.plusSeconds(1)));
        double countBefore = completedRecordCount();

        SettlementCompletionJob.CompletionRun result = completionJob.run(COMPLETION_TIME, ADMIN_ID, sellerId);

        assertThat(result.succeeded()).isEqualTo(103);
        assertThat(result.committedChunks()).isEqualTo(2);
        assertThat(meterRegistry.find("settlement.completion.records.completed").counter()).isNotNull();
        assertThat(completedRecordCount() - countBefore).isEqualTo(103);
        assertThat(meterRegistry.get("settlement.completion.job").timer().count()).isPositive();
        assertThat(meterRegistry.get("settlement.completion.chunk").timer().count()).isGreaterThanOrEqualTo(2);
        assertThat(meterRegistry.get("settlement.completion.selection").timer().count()).isPositive();
        assertThat(meterRegistry.get("settlement.completion.update").timer().count()).isGreaterThanOrEqualTo(2);

        SettlementCompletionJob.CompletionRun rerun = completionJob.run(COMPLETION_TIME, ADMIN_ID, sellerId);

        assertThat(rerun.succeeded()).isZero();
        assertThat(completedRecordCount() - countBefore).isEqualTo(103);
        assertThat(jdbcTemplate.queryForObject(
                "SELECT count(*) FROM p_settlements WHERE seller_id = ? AND status = 'COMPLETED'",
                Integer.class, sellerId)).isEqualTo(103);
    }

    @Test
    @DisplayName("뒤 청크가 롤백되어도 앞선 커밋 건수는 Counter에 유지한다")
    void 뒤_청크_실패에도_완료_건수_유지() {
        UUID sellerId = UUID.randomUUID();
        savePendingSettlements(sellerId, 210);
        List<UUID> ids = settlementRepository.findCompletionCandidateIds(
                SettlementStatus.PENDING, COMPLETION_TIME, new UUID(0, 0), sellerId, PageRequest.of(0, 101));
        UUID blockedId = ids.get(100);
        double countBefore = completedRecordCount();
        jdbcTemplate.execute("ALTER TABLE p_settlements ADD CONSTRAINT block_completion_metrics "
                + "CHECK (id <> '" + blockedId + "' OR status = 'PENDING')");
        try {
            assertThatThrownBy(() -> completionJob.run(COMPLETION_TIME, ADMIN_ID, sellerId))
                    .isInstanceOf(RuntimeException.class);

            assertThat(meterRegistry.find("settlement.completion.records.completed").counter()).isNotNull();
            assertThat(completedRecordCount() - countBefore).isEqualTo(100);
            assertThat(jdbcTemplate.queryForObject(
                    "SELECT count(*) FROM p_settlements WHERE seller_id = ? AND status = 'COMPLETED'",
                    Integer.class, sellerId)).isEqualTo(100);
            assertThat(jdbcTemplate.queryForObject(
                    "SELECT count(*) FROM p_settlements WHERE seller_id = ? AND status = 'PENDING'",
                    Integer.class, sellerId)).isEqualTo(110);
        } finally {
            jdbcTemplate.execute("ALTER TABLE p_settlements DROP CONSTRAINT block_completion_metrics");
        }
    }

    private void savePendingSettlements(UUID sellerId, int count) {
        settlementRepository.saveAll(IntStream.range(0, count)
                .mapToObj(i -> Settlement.create(UUID.randomUUID(), sellerId, 10_000L, 10_000L, ELIGIBLE_AT))
                .toList());
    }

    private double completedRecordCount() {
        var counter = meterRegistry.find("settlement.completion.records.completed").counter();
        return counter == null ? 0 : counter.count();
    }

    private Settlement pendingSettlement() {
        return Settlement.create(UUID.randomUUID(), SELLER_ID, 10_000L, 10_000L, ELIGIBLE_AT);
    }

    private Settlement completedSettlement() {
        Settlement settlement = pendingSettlement();
        settlement.complete(ALREADY_SETTLED_AT, ADMIN_ID);
        return settlement;
    }
}

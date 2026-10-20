package com.parut.order.settlement.application;

import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import com.parut.order.settlement.domain.SettlementStatus;
import com.parut.order.settlement.infrastructure.persistence.SettlementRepository;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * 정산 가능 시각이 cutoff 이하인 대기 정산을 자동 완료한다. 실제 송금은 수행하지 않는다.
 *
 * <p>대상 ID 커서 조회 → 설정한 청크 크기의 조건부 갱신과 독립 커밋 → 결과 집계 순서로 반복한다.
 * DB 오류가 나면 해당 청크를 롤백하고 중단하며, 앞선 커밋은 유지한다.
 * 재실행은 같은 cutoff로 남은 대상을 재조회하며 최초 명단이나 청크 경계를 복원하지 않는다.
 */
@Service
@RequiredArgsConstructor
@Slf4j
public class SettlementCompletionJob {

    @Value("${settlement.completion.chunk-size:100}")
    private int chunkSize = 100;

    private final SettlementRepository settlementRepository;
    private final SettlementCompletionProcessor completionProcessor;
    private final SettlementCompletionMetrics metrics;
    private final AtomicBoolean running = new AtomicBoolean();

    /**
     * cutoff까지 정산 가능한 후보를 처리한다. sellerId가 없으면 전체 판매자가 대상이다.
     *
     * <p>조율 작업은 트랜잭션을 열지 않고, 별도 Processor Bean을 호출해 청크별 커밋을 완료한다.
     * 조회 크기와 커밋 단위를 같게 유지하며, cutoff는 실행 중 변경하지 않는 대상 선정 기준이다.
     */
    @Transactional(propagation = Propagation.NOT_SUPPORTED)
    public CompletionRun run(Instant cutoff, UUID processedBy, UUID sellerId) {
        if (cutoff == null || cutoff.isAfter(Instant.now()) || processedBy == null || chunkSize <= 0) {
            throw new IllegalArgumentException("기준 시각, 자동 처리자와 청크 크기 설정을 확인해주세요.");
        }
        // 같은 JVM의 작업 중복만 차단한다. 여러 서버의 작업을 하나로 묶는 분산 락은 아니다.
        if (!running.compareAndSet(false, true)) {
            throw new IllegalStateException("정산 완료 작업이 실행 중입니다.");
        }
        UUID runId = UUID.randomUUID();
        SettlementCompletionMetrics.Measurement measurement = metrics.start();
        int candidates = 0;
        int succeeded = 0;
        int skipped = 0;
        int committedChunks = 0;
        int chunkNumber = 0;
        int pages = 0;
        UUID cursor = new UUID(0, 0);
        log.info("정산 자동완료 시작 runId={}, cutoff={}, sellerId={}", runId, cutoff, sellerId);
        try {
            List<UUID> ids;
            do {
                long selected = System.nanoTime();
                ids = settlementRepository.findCompletionCandidateIds(
                        SettlementStatus.PENDING, cutoff, cursor, sellerId, PageRequest.of(0, chunkSize));
                measurement.recordSelection(selected);
                pages++;
                if (!ids.isEmpty()) {
                    chunkNumber++;
                    candidates += ids.size();
                    long chunkStarted = System.nanoTime();
                    try {
                        SettlementCompletionProcessor.ChunkCompletion result =
                                completionProcessor.completeChunk(ids, processedBy, cutoff);
                        // 정상 반환은 프록시의 커밋까지 성공한 뒤이므로 그때만 집계와 커서를 진행한다.
                        succeeded += result.updated();
                        skipped += ids.size() - result.updated();
                        committedChunks++;
                        measurement.recordMutation(result.mutationNanos());
                        cursor = ids.get(ids.size() - 1);
                    } catch (RuntimeException e) {
                        log.error("정산 자동완료 청크 실패 runId={}, chunk={}, firstId={}, lastId={}, count={}",
                                runId, chunkNumber, ids.get(0), ids.get(ids.size() - 1), ids.size());
                        throw e;
                    } finally {
                        measurement.recordChunk(chunkStarted);
                    }
                }
            } while (ids.size() == chunkSize);
            CompletionRun result = new CompletionRun(runId, cutoff, candidates, succeeded, skipped, pages,
                    committedChunks, measurement.totalMillis(), measurement.selectionMillis(),
                    measurement.chunkMillis(), measurement.mutationMillis(), measurement.boundaryMillis());
            measurement.recordTotal();
            log.info("정산 자동완료 종료 result={}", result);
            return result;
        } catch (RuntimeException e) {
            // 시스템 오류는 작업을 중단하되 앞선 커밋은 유지한다. 재실행은 남은 후보를 다시 선정한다.
            log.error("정산 자동완료 중단 runId={}, cutoff={}, cursor={}, succeeded={}, skipped={}, committedChunks={}",
                    runId, cutoff, cursor, succeeded, skipped, committedChunks, e);
            throw e;
        } finally {
            running.set(false);
        }
    }

    /**
     * 정상 종료한 실행의 결과와 누적시간이다. 중단 실행은 성공 응답 대신 오류와 로그로 남긴다.
     * mutation은 chunkTransactionMs에 포함되며, transactionBoundaryMs는 순수 커밋 시간이 아니다.
     */
    public record CompletionRun(UUID runId, Instant cutoff, int candidates, int succeeded, int skipped,
                                int pages, int committedChunks, double totalMs,
                                double selectionMs, double chunkTransactionMs, double mutationMs,
                                double transactionBoundaryMs) {
    }
}

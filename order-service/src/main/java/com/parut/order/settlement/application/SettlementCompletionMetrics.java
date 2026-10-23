package com.parut.order.settlement.application;

import java.util.concurrent.TimeUnit;

import org.springframework.stereotype.Component;

import io.micrometer.core.instrument.MeterRegistry;
import lombok.RequiredArgsConstructor;

/** 정산 완료 작업의 구간별 누적시간과 메트릭을 기록한다. */
@Component
@RequiredArgsConstructor
public class SettlementCompletionMetrics {

    private final MeterRegistry meterRegistry;

    public Measurement start() {
        return new Measurement();
    }

    /** 커밋된 정산 건수만 누적한다. Job/청크 실행 횟수와 구분한다. */
    public void recordCompleted(int count) {
        if (count > 0) {
            meterRegistry.counter("settlement.completion.records.completed").increment(count);
        }
    }

    /** 실행마다 생성한다. 싱글턴 컴포넌트에 누적값을 공유하지 않는다. */
    public class Measurement {

        private final long started = System.nanoTime();
        private long selectionNanos;
        private long chunkNanos;
        private long mutationNanos;

        private Measurement() {
        }

        public void recordSelection(long startedAt) {
            long duration = System.nanoTime() - startedAt;
            selectionNanos += duration;
            record("settlement.completion.selection", duration);
        }

        /** Processor 프록시 호출부터 커밋 후 반환과 집계까지 측정하며 실패 청크도 기록한다. */
        public void recordChunk(long startedAt) {
            long duration = System.nanoTime() - startedAt;
            chunkNanos += duration;
            record("settlement.completion.chunk", duration);
        }

        public void recordMutation(long nanos) {
            mutationNanos += nanos;
            record("settlement.completion.update", nanos);
        }

        /** 정상 종료한 Job의 전체 시간만 기록한다. */
        public void recordTotal() {
            record("settlement.completion.job", System.nanoTime() - started);
        }

        public double totalMillis() {
            return millis(System.nanoTime() - started);
        }

        public double selectionMillis() {
            return millis(selectionNanos);
        }

        public double chunkMillis() {
            return millis(chunkNanos);
        }

        public double mutationMillis() {
            return millis(mutationNanos);
        }

        /** 트랜잭션 시작과 계측 등도 포함하므로 순수 커밋 시간으로 해석하지 않는다. */
        public double boundaryMillis() {
            return millis(chunkNanos - mutationNanos);
        }
    }

    private void record(String metricName, long nanos) {
        meterRegistry.timer(metricName)
                .record(nanos, TimeUnit.NANOSECONDS);
    }

    private static double millis(long nanos) {
        return nanos / 1_000_000.0;
    }
}

package com.parut.product.timedeal.application.metrics.timedeal;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.function.Supplier;

/**
 * 타임딜 성능 분석용 공통 Timer 실행기
 * <p>측정 대상 코드는 Supplier/Runnable로 전달하고, 이 클래스가
 * 시작·종료·예외 발생 시 종료 처리를 공통으로 담당한다</p>
 */
@Component
@RequiredArgsConstructor
public class TimeDealPerformanceMetrics {

    private final MeterRegistry meterRegistry;

    public <T> T record(String name, Supplier<T> action) {
        return Timer.builder(name)
                .register(meterRegistry)
                .record(action);
    }

    public void record(String name, Runnable action) {
        Timer.builder(name)
                .register(meterRegistry)
                .record(action);
    }

    /**
     * 현재 트랜잭션이 commit 또는 rollback으로 완료되는 시점까지 측정한다.
     *
     * <p>호출 시점에 시작한 Timer.Sample을 현재 트랜잭션의 완료 콜백에
     * 등록하므로, 호출부의 비즈니스 로직이 끝난 뒤 실행되는 commit/rollback
     * 구간까지 포함할 수 있다.</p>
     */
    public void recordUntilTransactionCompletion(String name) {
        Timer.Sample sample = Timer.start(meterRegistry);

        if (!TransactionSynchronizationManager.isSynchronizationActive()) {
            sample.stop(meterRegistry.timer(name));
            return;
        }

        TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCompletion(int status) {
                        sample.stop(meterRegistry.timer(name));
                    }
                }
        );
    }
}

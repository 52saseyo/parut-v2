package com.parut.product.timedeal.application.metrics.timedeal;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

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
}

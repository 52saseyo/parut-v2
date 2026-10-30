package com.parut.product.timedeal.application.metrics.timedeal;

import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockCompensationResult;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockReservationResult;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * JMeter의 HTTP 지표와 별도로 Redis 선점 내부 결과와 Script 처리시간을 기록한다.
 * orderId 같은 고유값은 태그로 사용하지 않아 시계열이 무한히 늘어나지 않도록 한다.
 */
@Component
@RequiredArgsConstructor
public class TimeDealRedisMetrics {

    private static final String RESERVATION_METRIC = "timedeal.redis.reservation";
    private static final String COMPENSATION_METRIC = "timedeal.redis.compensation";

    private final MeterRegistry meterRegistry;

    public void recordReservationResult(TimeDealStockReservationResult result) {
        meterRegistry.counter(RESERVATION_METRIC, "result", result.name()).increment(); // NOTE: 선점 횟수, 매진 횟수를 각각 result 로 증가 (increment()) 시키는 메서드
    }

    public void recordCompensationResult(TimeDealStockCompensationResult result) {
        meterRegistry.counter(COMPENSATION_METRIC, "result", result.name()).increment();
    }

    public Timer.Sample startReservationScript() {
        return Timer.start(meterRegistry);
    }

    public void stopReservationScript(Timer.Sample sample) {
        sample.stop(meterRegistry.timer("timedeal.redis.reservation.time"));
    }

    public Timer.Sample startCompensationScript() {
        return Timer.start(meterRegistry);
    }

    public void stopCompensationScript(Timer.Sample sample) {
        sample.stop(meterRegistry.timer("timedeal.redis.compensation.time"));
    }
}

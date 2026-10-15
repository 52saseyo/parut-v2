package com.parut.notification.notification.application.metrics;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.function.Supplier;

@Component
@RequiredArgsConstructor
public class NotificationFanoutMetrics {
    private static final String TYPE = "TIME_DEAL_OPENING_SOON";

    private static final String RESULT_FAILURE = "failure";

    private static final String METRIC_TOTAL = "notification.fanout.total";
    private static final String METRIC_SUBSCRIBER_LOOKUP = "notification.fanout.subscriber.lookup";
    private static final String METRIC_EXISTING_LOOKUP = "notification.fanout.existing.lookup";
    private static final String METRIC_BUILD = "notification.fanout.build";
    private static final String METRIC_SUBSCRIBERS = "notification.fanout.subscribers";
    private static final String METRIC_NOTIFICATIONS = "notification.fanout.notifications";
    private static final String METRIC_SAVE = "notification.fanout.save";
    private static final String METRIC_FLUSH = "notification.fanout.flush";

    private final MeterRegistry meterRegistry;

    public Timer.Sample startTotal() {
        return Timer.start(meterRegistry);
    }

    public void completeAfterTransaction(
            Timer.Sample sample,
            String result,
            int createdCount
    ) {
        boolean transactionActive =
                TransactionSynchronizationManager.isActualTransactionActive();

        boolean synchronizationActive =
                TransactionSynchronizationManager.isSynchronizationActive();

        if (!transactionActive || !synchronizationActive) {
            recordCompletion(sample, result, createdCount);
            return;
        }

        TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCompletion(int status) {
                        if (status == STATUS_COMMITTED) {
                            recordCompletion(
                                    sample,
                                    result,
                                    createdCount
                            );
                            return;
                        }

                        recordCompletion(
                                sample,
                                RESULT_FAILURE,
                                0
                        );
                    }
                }
        );
    }

    private void recordCompletion(
            Timer.Sample sample,
            String result,
            int createdCount
    ) {
        sample.stop(
                Timer.builder(METRIC_TOTAL)
                        .tag("type", TYPE)
                        .tag("result", result)
                        .register(meterRegistry)
        );

        meterRegistry.counter(
                METRIC_NOTIFICATIONS,
                "type", TYPE,
                "result", result
        ).increment(createdCount);
    }

    public <T> T recordSubscriberLookup(Supplier<T> supplier) {
        return Timer.builder(METRIC_SUBSCRIBER_LOOKUP)
                .tag("type", TYPE)
                .register(meterRegistry)
                .record(supplier);
    }

    public <T> T recordExistingLookup(Supplier<T> supplier) {
        return Timer.builder(METRIC_EXISTING_LOOKUP)
                .tag("type", TYPE)
                .register(meterRegistry)
                .record(supplier);
    }

    public <T> T recordBuild(Supplier<T> supplier) {
        return Timer.builder(METRIC_BUILD)
                .tag("type", TYPE)
                .register(meterRegistry)
                .record(supplier);
    }

    public void incrementSubscribers(int count) {
        meterRegistry.counter(
                METRIC_SUBSCRIBERS,
                "type", TYPE
        ).increment(count);
    }

    /**
     * 엔티티를 영속성 컨텍스트에 등록하는 시간을 측정한다.
     */
    public <T> T recordSave(Supplier<T> supplier) {
        return Timer.builder(METRIC_SAVE)
                .tag("type", TYPE)
                .register(meterRegistry)
                .record(supplier);
    }

    /**
     * Hibernate가 실제 INSERT SQL을 실행하는 시간을 측정한다.
     */
    public void recordFlush(Runnable runnable) {
        Timer.builder(METRIC_FLUSH)
                .tag("type", TYPE)
                .register(meterRegistry)
                .record(runnable);
    }
}

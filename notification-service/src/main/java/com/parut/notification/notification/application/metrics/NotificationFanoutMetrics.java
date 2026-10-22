package com.parut.notification.notification.application.metrics;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

@Slf4j
@Component
public class NotificationFanoutMetrics {

    private static final String TYPE = "TIME_DEAL_OPENING_SOON";

    private static final String RESULT_SUCCESS = "success";
    private static final String RESULT_FAILURE = "failure";

    private static final String METRIC_TOTAL = "notification.fanout.total";
    private static final String METRIC_SUBSCRIBER_LOOKUP = "notification.fanout.subscriber.lookup";
    private static final String METRIC_EXISTING_LOOKUP = "notification.fanout.existing.lookup";
    private static final String METRIC_NOTIFICATIONS = "notification.fanout.notifications";
    private static final String METRIC_SAVE = "notification.fanout.save";
    private static final String METRIC_FLUSH = "notification.fanout.flush";

    private final MeterRegistry meterRegistry;

    public NotificationFanoutMetrics(MeterRegistry meterRegistry) {
        this.meterRegistry = meterRegistry;
        registerMeters();
    }

    private void registerMeters() {
        totalTimer(RESULT_SUCCESS);
        totalTimer(RESULT_FAILURE);

        List.of(
                METRIC_SUBSCRIBER_LOOKUP,
                METRIC_EXISTING_LOOKUP,
                METRIC_SAVE,
                METRIC_FLUSH
        ).forEach(this::phaseTimer);

        notificationsCounter();
    }

    public void recordFanout(UUID eventId, Runnable action) {
        long consumerReceivedEpochMs = System.currentTimeMillis();
        Timer.Sample sample = Timer.start(meterRegistry);

        try {
            action.run();
            recordFanoutCompletion(
                    eventId,
                    consumerReceivedEpochMs,
                    sample,
                    RESULT_SUCCESS
            );
        } catch (RuntimeException exception) {
            recordFanoutCompletion(
                    eventId,
                    consumerReceivedEpochMs,
                    sample,
                    RESULT_FAILURE
            );
            throw exception;
        }
    }

    private void recordFanoutCompletion(
            UUID eventId,
            long consumerReceivedEpochMs,
            Timer.Sample sample,
            String result
    ) {
        long transactionCompletedEpochMs = System.currentTimeMillis();
        sample.stop(totalTimer(result));

        log.info(
                "FANOUT_MEASUREMENT eventId={}, consumerReceivedEpochMs={}, "
                        + "transactionCompletedEpochMs={}, durationMs={}, result={}",
                eventId,
                consumerReceivedEpochMs,
                transactionCompletedEpochMs,
                transactionCompletedEpochMs - consumerReceivedEpochMs,
                result
        );
    }

    public void recordCreatedAfterCommit(int count) {
        if (count <= 0) {
            return;
        }

        if (!isTransactionSynchronizationActive()) {
            notificationsCounter().increment(count);
            return;
        }

        TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCompletion(int status) {
                        if (status == STATUS_COMMITTED) {
                            notificationsCounter().increment(count);
                        }
                    }
                }
        );
    }

    public <T> T recordSubscriberLookup(Supplier<T> action) {
        return phaseTimer(METRIC_SUBSCRIBER_LOOKUP).record(action);
    }

    public <T> T recordExistingLookup(Supplier<T> action) {
        return phaseTimer(METRIC_EXISTING_LOOKUP).record(action);
    }

    /**
     * 엔티티를 JPA 영속성 컨텍스트에 등록하는 시간을 측정한다.
     */
    public <T> T recordSave(Supplier<T> action) {
        return phaseTimer(METRIC_SAVE).record(action);
    }

    /**
     * Hibernate가 실제 INSERT SQL을 실행하는 시간을 측정한다.
     */
    public void recordFlush(Runnable action) {
        phaseTimer(METRIC_FLUSH).record(action);
    }

    private boolean isTransactionSynchronizationActive() {
        return TransactionSynchronizationManager.isActualTransactionActive()
                && TransactionSynchronizationManager.isSynchronizationActive();
    }

    private Timer totalTimer(String result) {
        return Timer.builder(METRIC_TOTAL)
                .tag("type", TYPE)
                .tag("result", result)
                .register(meterRegistry);
    }

    private Timer phaseTimer(String metricName) {
        return Timer.builder(metricName)
                .tag("type", TYPE)
                .register(meterRegistry);
    }

    private Counter notificationsCounter() {
        return meterRegistry.counter(METRIC_NOTIFICATIONS, "type", TYPE);
    }
}

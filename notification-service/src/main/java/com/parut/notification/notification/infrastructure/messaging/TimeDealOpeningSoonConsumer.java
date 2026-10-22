package com.parut.notification.notification.infrastructure.messaging;

import com.parut.notification.global.constant.HeaderConstants;
import com.parut.notification.global.logging.TraceIdContext;
import com.parut.notification.notification.application.metrics.NotificationFanoutMetrics;
import com.parut.notification.notification.application.port.in.TimeDealOpeningSoonNotificationUseCase;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class TimeDealOpeningSoonConsumer {
    private final TimeDealOpeningSoonNotificationUseCase timeDealOpeningSoonNotificationUseCase;
    private final NotificationFanoutMetrics fanoutMetrics;

    @KafkaListener(
            topics = "time-deal.opening-soon",
            groupId = "notification-time-deal-opening-soon",
            containerFactory = "kafkaListenerContainerFactory"
    )
    public void consume(
            TimeDealOpeningSoonEvent event,
            @Header(name = HeaderConstants.TRACE_ID, required = false)
            String traceId
    ) {
        try {
            TraceIdContext.set(traceId);
            fanoutMetrics.recordFanout(
                    event.eventId(),
                    () -> {
                        log.info(
                                "타임딜 임박 이벤트 수신 "
                                        + "eventId={}, timeDealId={}",
                                event.eventId(),
                                event.timeDealId()
                        );
                        timeDealOpeningSoonNotificationUseCase.createNotifications(
                                event.toCommand(traceId)
                        );
                    }
            );
        } finally {
            TraceIdContext.clear();
        }
    }
}

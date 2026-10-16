package com.parut.notification.notification.application;

import com.parut.notification.notification.application.dto.TimeDealOpeningSoonCommand;
import com.parut.notification.notification.application.metrics.NotificationFanoutMetrics;
import com.parut.notification.notification.application.port.in.TimeDealOpeningSoonNotificationUseCase;
import com.parut.notification.notification.domain.Notification;
import com.parut.notification.notification.domain.NotificationType;
import com.parut.notification.notification.domain.ReferenceType;
import com.parut.notification.notification.infrastructure.persistence.NotificationRepository;
import com.parut.notification.subscription.application.port.in.TimeDealSubscriptionQueryUseCase;
import io.micrometer.core.instrument.Timer;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Set;
import java.util.UUID;

@Slf4j
@Service
@RequiredArgsConstructor
public class TimeDealOpeningSoonNotificationService implements TimeDealOpeningSoonNotificationUseCase {

    private static final ZoneId SERVICE_ZONE =  ZoneId.of("Asia/Seoul");
    private static final DateTimeFormatter START_AT_FORMATTER = DateTimeFormatter.ofPattern("M월 d일 HH:mm");

    private static final String NOTIFICATION_TITLE = "타임딜 오픈 임박";
    private static final String CONTENT_FORMAT = "%s 타임딜이 %s에 시작됩니다.";

    private static final String RESULT_SUCCESS = "success";
    private static final String RESULT_EMPTY_SUBSCRIBER = "empty_subscriber";
    private static final String RESULT_DUPLICATE = "duplicate";
    private static final String RESULT_FAILURE = "failure";

    private final TimeDealSubscriptionQueryUseCase subscriptionQueryUseCase;
    private final NotificationRepository notificationRepository;
    private final NotificationFanoutMetrics fanoutMetrics;


    @Override
    @Transactional
    public void createNotifications(TimeDealOpeningSoonCommand command) {
        Timer.Sample totalSample = fanoutMetrics.startTotal();

        String result = RESULT_SUCCESS;
        int createdCount = 0;

        try {
            List<UUID> subscriberIds =
                    fanoutMetrics.recordSubscriberLookup(
                            () -> subscriptionQueryUseCase
                                    .getActiveSubscriberIds(command.timeDealId())
                    );

            fanoutMetrics.incrementSubscribers(subscriberIds.size());

            if (subscriberIds.isEmpty()) {
                result = RESULT_EMPTY_SUBSCRIBER;

                log.info(
                        "[TimeDealOpeningSoonNotificationService] 활성 구독자 없음 "
                                + "eventId={}, timeDealId={}",
                        command.eventId(),
                        command.timeDealId()
                );
                return;
            }

            Set<UUID> existingUserIds = fanoutMetrics.recordExistingLookup(
                            () -> notificationRepository.findExistingUserIds(
                                    command.eventId(),
                                    subscriberIds
                            )
                    );

            List<Notification> notifications = fanoutMetrics.recordBuild(
                            () -> buildNotifications(
                                    command,
                                    subscriberIds,
                                    existingUserIds
                            )
                    );

            if (notifications.isEmpty()) {
                result = RESULT_DUPLICATE;

                log.info(
                        "[TimeDealOpeningSoonNotificationService] "
                                + "생성할 신규 알림 없음 "
                                + "eventId={}, timeDealId={}",
                        command.eventId(),
                        command.timeDealId()
                );
                return;
            }

            // 엔티티를 JPA 영속성 컨텍스트에 등록하는 시간을 측정한다.
            fanoutMetrics.recordSave(() -> notificationRepository.saveAll(notifications));

            // 영속성 컨텍스트에 쌓인 변경을 실제 DB에 반영하는 시간을 측정한다.
            fanoutMetrics.recordFlush(notificationRepository::flush);

            createdCount = notifications.size();

            log.info(
                    "[TimeDealOpeningSoonNotificationService] "
                            + "알림 저장 요청 완료 "
                            + "eventId={}, timeDealId={}, count={}",
                    command.eventId(),
                    command.timeDealId(),
                    createdCount
            );

        } catch (RuntimeException e) {
            result = RESULT_FAILURE;
            throw e;

        } finally {
            fanoutMetrics.completeAfterTransaction(
                    totalSample,
                    result,
                    createdCount
            );
        }
    }

    private List<Notification> buildNotifications(
            TimeDealOpeningSoonCommand command,
            List<UUID> subscriberIds,
            Set<UUID> existingUserIds
    ) {
        return subscriberIds.stream()
                .filter(userId -> !existingUserIds.contains(userId))
                .map(userId -> createNotification(command, userId))
                .toList();
    }

    private Notification createNotification(TimeDealOpeningSoonCommand command, UUID userId) {
        String formattedStartAt = command
                .timeDealStartAt()
                .atZone(SERVICE_ZONE)
                .format(START_AT_FORMATTER);

        String content = CONTENT_FORMAT.formatted(command.timeDealName(), formattedStartAt);

        return Notification.create(
                command.eventId(),
                command.traceId(),
                userId,
                NotificationType.TIME_DEAL_OPENING_SOON,
                NOTIFICATION_TITLE,
                content,
                ReferenceType.TIME_DEAL,
                command.timeDealId()
        );
    }
}

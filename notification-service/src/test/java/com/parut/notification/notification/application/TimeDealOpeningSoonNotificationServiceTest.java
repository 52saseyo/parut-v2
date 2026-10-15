package com.parut.notification.notification.application;

import com.parut.notification.notification.application.dto.TimeDealOpeningSoonCommand;
import com.parut.notification.notification.application.metrics.NotificationFanoutMetrics;
import com.parut.notification.notification.domain.Notification;
import com.parut.notification.notification.domain.NotificationType;
import com.parut.notification.notification.domain.ReferenceType;
import com.parut.notification.notification.infrastructure.persistence.NotificationRepository;
import com.parut.notification.subscription.application.port.in.TimeDealSubscriptionQueryUseCase;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class TimeDealOpeningSoonNotificationServiceTest {

    private TimeDealSubscriptionQueryUseCase subscriptions;
    private NotificationRepository notifications;
    private TimeDealOpeningSoonNotificationService service;

    private final UUID eventId = UUID.randomUUID();
    private final UUID timeDealId = UUID.randomUUID();
    private final TimeDealOpeningSoonCommand command = new TimeDealOpeningSoonCommand(
            eventId, "trace-123", timeDealId, "못난이 감자", Instant.parse("2026-09-22T01:00:00Z"));

    @BeforeEach
    void setUp() {
        subscriptions = mock(TimeDealSubscriptionQueryUseCase.class);
        notifications = mock(NotificationRepository.class);
        SimpleMeterRegistry meterRegistry = new SimpleMeterRegistry();

        NotificationFanoutMetrics fanoutMetrics =
                new NotificationFanoutMetrics(meterRegistry);

        service = new TimeDealOpeningSoonNotificationService(
                subscriptions,
                notifications,
                fanoutMetrics
        );
    }

    @Test
    void createsOnlyMissingSubscriberNotifications() {
        UUID existingUser = UUID.randomUUID();
        UUID newUser = UUID.randomUUID();
        when(subscriptions.getActiveSubscriberIds(timeDealId)).thenReturn(List.of(existingUser, newUser));
        when(notifications.findExistingUserIds(eventId, List.of(existingUser, newUser)))
                .thenReturn(Set.of(existingUser));

        service.createNotifications(command);

        @SuppressWarnings("unchecked")
        ArgumentCaptor<Iterable<Notification>> captor = ArgumentCaptor.forClass(Iterable.class);
        verify(notifications).saveAll(captor.capture());
        List<Notification> saved = (List<Notification>) captor.getValue();
        assertEquals(1, saved.size());
        Notification notification = saved.getFirst();
        assertEquals(newUser, notification.getUserId());
        assertEquals(eventId, notification.getEventId());
        assertEquals("trace-123", notification.getTraceId());
        assertEquals(NotificationType.TIME_DEAL_OPENING_SOON, notification.getType());
        assertEquals(ReferenceType.TIME_DEAL, notification.getReferenceType());
        assertEquals(timeDealId, notification.getReferenceId());
        assertEquals("못난이 감자 타임딜이 9월 22일 10:00에 시작됩니다.", notification.getContent());
    }

    @Test
    void skipsSaveWhenThereAreNoSubscribers() {
        when(subscriptions.getActiveSubscriberIds(timeDealId)).thenReturn(List.of());

        service.createNotifications(command);

        verifyNoInteractions(notifications);
    }

    @Test
    void skipsSaveWhenEventWasAlreadyProcessedForEverySubscriber() {
        UUID userId = UUID.randomUUID();
        when(subscriptions.getActiveSubscriberIds(timeDealId)).thenReturn(List.of(userId));
        when(notifications.findExistingUserIds(eventId, List.of(userId))).thenReturn(Set.of(userId));

        service.createNotifications(command);

        verify(notifications, never()).saveAll(any());
    }
}

package com.parut.notification.subscription.application;

import com.parut.notification.global.exception.BusinessException;
import com.parut.notification.global.exception.ErrorCode;
import com.parut.notification.subscription.application.authorization.TimeDealSubscriptionAuthorizationChecker;
import com.parut.notification.subscription.application.dto.SubscribeTimeDealCommand;
import com.parut.notification.subscription.domain.TimeDealNotificationSubscription;
import com.parut.notification.subscription.infrastructure.persistence.TimeDealSubscriptionRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class TimeDealSubscriptionServiceTest {

    private TimeDealSubscriptionRepository repository;
    private TimeDealSubscriptionService service;

    private final UUID userId = UUID.randomUUID();
    private final UUID timeDealId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        repository = mock(TimeDealSubscriptionRepository.class);
        service = new TimeDealSubscriptionService(repository, new TimeDealSubscriptionAuthorizationChecker());
    }

    @Test
    void subscribeCreatesSubscriptionWhenMissing() {
        var subscription = TimeDealNotificationSubscription.subscribe(userId, timeDealId);
        when(repository.findByUserIdAndTimeDealId(userId, timeDealId)).thenReturn(Optional.of(subscription));

        var result = service.subscribe(new SubscribeTimeDealCommand(userId, "CUSTOMER", timeDealId));

        assertEquals(timeDealId, result.timeDealId());
        assertTrue(result.subscribed());
        verify(repository).upsertSubscription(any(UUID.class), eq(userId), eq(timeDealId));
        verify(repository, never()).save(any(TimeDealNotificationSubscription.class));
    }

    @Test
    void repeatedSubscribeReusesExistingSubscription() {
        var existing = TimeDealNotificationSubscription.subscribe(userId, timeDealId);
        when(repository.findByUserIdAndTimeDealId(userId, timeDealId)).thenReturn(Optional.of(existing));

        var result = service.subscribe(new SubscribeTimeDealCommand(userId, "CUSTOMER", timeDealId));

        assertTrue(result.subscribed());
        verify(repository).upsertSubscription(any(UUID.class), eq(userId), eq(timeDealId));
        verify(repository, never()).save(any());
    }

    @Test
    void cancelledSubscriptionCanBeReactivated() {
        var reactivated = TimeDealNotificationSubscription.subscribe(userId, timeDealId);
        when(repository.findByUserIdAndTimeDealId(userId, timeDealId)).thenReturn(Optional.of(reactivated));

        var result = service.subscribe(new SubscribeTimeDealCommand(userId, "CUSTOMER", timeDealId));

        assertTrue(result.subscribed());
        verify(repository).upsertSubscription(any(UUID.class), eq(userId), eq(timeDealId));
        verify(repository, never()).save(any());
    }

    @Test
    void unsubscribeIsIdempotentForExistingSubscription() {
        var existing = TimeDealNotificationSubscription.subscribe(userId, timeDealId);
        when(repository.findByUserIdAndTimeDealId(userId, timeDealId)).thenReturn(Optional.of(existing));

        service.unsubscribe(userId, "CUSTOMER", timeDealId);
        Instant firstDeletedAt = existing.getDeletedAt();
        service.unsubscribe(userId, "CUSTOMER", timeDealId);

        assertNotNull(firstDeletedAt);
        assertEquals(firstDeletedAt, existing.getDeletedAt());
    }

    @Test
    void sellerCannotSubscribe() {
        var error = assertThrows(BusinessException.class,
                () -> service.subscribe(new SubscribeTimeDealCommand(userId, "SELLER", timeDealId)));

        assertEquals(ErrorCode.TIME_DEAL_SUBSCRIPTION_ACCESS_DENIED, error.getErrorCode());
        verifyNoInteractions(repository);
    }
}

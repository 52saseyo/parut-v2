package com.parut.notification.subscription.application;

import com.parut.notification.global.exception.BusinessException;
import com.parut.notification.global.exception.ErrorCode;
import com.parut.notification.subscription.application.authorization.TimeDealSubscriptionAuthorizationChecker;
import com.parut.notification.subscription.application.dto.SubscribeTimeDealCommand;
import com.parut.notification.subscription.application.dto.TimeDealSubscriptionResult;
import com.parut.notification.subscription.application.port.in.TimeDealSubscriptionCommandUseCase;
import com.parut.notification.subscription.application.port.in.TimeDealSubscriptionQueryUseCase;
import com.parut.notification.subscription.domain.TimeDealNotificationSubscription;
import com.parut.notification.subscription.infrastructure.persistence.TimeDealSubscriptionRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class TimeDealSubscriptionService
        implements TimeDealSubscriptionCommandUseCase, TimeDealSubscriptionQueryUseCase {

    private final TimeDealSubscriptionRepository timeDealSubscriptionRepository;
    private final TimeDealSubscriptionAuthorizationChecker authorizationChecker;

    @Transactional
    @Override
    public TimeDealSubscriptionResult subscribe(SubscribeTimeDealCommand command){
        authorizationChecker.requireCustomer(command.requesterRole());

        timeDealSubscriptionRepository.upsertSubscription(
                UUID.randomUUID(),
                command.userId(),
                command.timeDealId()
        );

        TimeDealNotificationSubscription subscription =
                timeDealSubscriptionRepository
                        .findByUserIdAndTimeDealId(command.userId(), command.timeDealId())
                        .orElseThrow(() -> new BusinessException(
                                ErrorCode.TIME_DEAL_SUBSCRIPTION_NOT_FOUND
                        ));

        return new TimeDealSubscriptionResult(
                subscription.getTimeDealId(),
                subscription.isSubscribed()
        );

    }


    @Transactional
    @Override
    public void unsubscribe(UUID userId, String requesterRole, UUID timeDealId){
        authorizationChecker.requireCustomer(requesterRole);
        TimeDealNotificationSubscription subscription =
                timeDealSubscriptionRepository
                        .findByUserIdAndTimeDealId(userId, timeDealId)
                        .orElseThrow(()-> new BusinessException(
                                ErrorCode.TIME_DEAL_SUBSCRIPTION_NOT_FOUND
                        ));

        subscription.cancel(Instant.now());
    }


    @Transactional(readOnly = true)
    @Override
    public TimeDealSubscriptionResult getSubscriptionStatus(UUID userId, String requesterRole, UUID timeDealId){
        authorizationChecker.requireCustomer(requesterRole);

        boolean subscribed =
                timeDealSubscriptionRepository.existsByUserIdAndTimeDealIdAndDeletedAtIsNull(userId, timeDealId);

        return new TimeDealSubscriptionResult(
                timeDealId,
                subscribed
        );
    }

    @Transactional(readOnly = true)
    @Override
    public List<UUID> getActiveSubscriberIds(UUID timeDealId) {
        if(timeDealId == null){
            throw new BusinessException(ErrorCode.NOTIFICATION_SUBSCRIPTION_TIME_DEAL_ID_REQUIRED);
        }
        return timeDealSubscriptionRepository.findActiveSubscriberIds(timeDealId);
    }
}

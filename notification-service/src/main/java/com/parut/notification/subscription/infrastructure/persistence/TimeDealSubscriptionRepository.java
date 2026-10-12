package com.parut.notification.subscription.infrastructure.persistence;

import com.parut.notification.subscription.domain.TimeDealNotificationSubscription;

import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface TimeDealSubscriptionRepository extends JpaRepository<TimeDealNotificationSubscription, UUID> {

    //신청, 취소, 재신청 처리 시 기존 신청 내역 조회
    Optional<TimeDealNotificationSubscription> findByUserIdAndTimeDealId(UUID userId, UUID timeDealId);

    //현재 활성화된 신청인지 조회
    boolean existsByUserIdAndTimeDealIdAndDeletedAtIsNull(UUID userId, UUID timeDealId);


    //해당 타임딜 알림 구독한 회원을 조회
    @Query("""
        select subscription.userId
          from TimeDealNotificationSubscription subscription
         where subscription.timeDealId = :timeDealId
           and subscription.deletedAt is null
        """)
    List<UUID> findActiveSubscriberIds(
            @Param("timeDealId") UUID timeDealId
    );


    @Modifying
    @Query(value = """
    insert into notification_schema.p_time_deal_notification_subscriptions (
        id,
        user_id,
        time_deal_id,
        created_at,
        updated_at,
        deleted_at
    )
    values (
        :id,
        :userId,
        :timeDealId,
        current_timestamp,
        current_timestamp,
        null
    )
    on conflict on constraint uk_time_deal_subscriptions_user_deal
    do update set
        deleted_at = null,
        updated_at = current_timestamp
    """, nativeQuery = true)
    void upsertSubscription(
            @Param("id") UUID id,
            @Param("userId") UUID userId,
            @Param("timeDealId") UUID timeDealId
    );

}

package com.parut.order.delivery.infrastructure.scheduler;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.stream.LongStream;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.domain.Pageable;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.core.env.MapPropertySource;
import org.springframework.scheduling.annotation.ScheduledAnnotationBeanPostProcessor;
import org.springframework.test.util.ReflectionTestUtils;

import com.parut.order.delivery.application.DeliveryService;
import com.parut.order.delivery.domain.DeliveryStatus;
import com.parut.order.delivery.infrastructure.persistence.DeliveryRepository;
import com.parut.order.delivery.infrastructure.config.DeliverySchedulingConfig;
import com.parut.order.global.config.SchedulingConfig;

@ExtendWith(MockitoExtension.class)
class DeliveryCompletionSchedulerTest {

    private static final long COMPLETION_DELAY_SECONDS = 60L;
    private static final UUID INITIAL_CURSOR_ID = new UUID(0, 0);

    @Mock
    private DeliveryRepository deliveryRepository;

    @Mock
    private DeliveryService deliveryService;

    @InjectMocks
    private DeliveryCompletionScheduler scheduler;

    @BeforeEach
    void setUp() {
        ReflectionTestUtils.setField(scheduler, "completionDelaySeconds", Long.toString(COMPLETION_DELAY_SECONDS));
    }

    @Test
    @DisplayName("101건을 100건씩 같은 기준 시각과 마지막 ID 커서로 처리한다")
    void 마지막_ID로_다음_페이지를_조회한다() {
        List<UUID> firstPage = LongStream.rangeClosed(1, 100)
                .mapToObj(id -> new UUID(0, id)).toList();
        UUID lastId = new UUID(0, 101);
        when(deliveryRepository.findEligibleIds(any(), any(), any(), any()))
                .thenReturn(firstPage).thenReturn(List.of(lastId));

        scheduler.runDeliveryCompletion();

        ArgumentCaptor<Instant> thresholdCaptor = ArgumentCaptor.forClass(Instant.class);
        ArgumentCaptor<UUID> cursorCaptor = ArgumentCaptor.forClass(UUID.class);
        ArgumentCaptor<Pageable> pageableCaptor = ArgumentCaptor.forClass(Pageable.class);
        verify(deliveryRepository, times(2)).findEligibleIds(
                eq(DeliveryStatus.SHIPPED), thresholdCaptor.capture(), cursorCaptor.capture(), pageableCaptor.capture());
        assertThat(cursorCaptor.getAllValues()).containsExactly(INITIAL_CURSOR_ID, firstPage.getLast());
        assertThat(thresholdCaptor.getAllValues()).containsOnly(thresholdCaptor.getValue());
        assertThat(pageableCaptor.getAllValues()).allSatisfy(page -> {
            assertThat(page.getPageSize()).isEqualTo(100);
            assertThat(page.getPageNumber()).isZero();
        });

        ArgumentCaptor<Instant> completionTimeCaptor = ArgumentCaptor.forClass(Instant.class);
        ArgumentCaptor<UUID> deliveryIdCaptor = ArgumentCaptor.forClass(UUID.class);
        verify(deliveryService, times(101)).completeEligibleDelivery(
                deliveryIdCaptor.capture(), completionTimeCaptor.capture(), eq(thresholdCaptor.getValue()));
        assertThat(deliveryIdCaptor.getAllValues()).containsExactlyElementsOf(
                LongStream.rangeClosed(1, 101).mapToObj(id -> new UUID(0, id)).toList());
        assertThat(completionTimeCaptor.getAllValues()).containsOnly(thresholdCaptor.getValue().plusSeconds(COMPLETION_DELAY_SECONDS));
    }

    @Test
    @DisplayName("중간 배송이 실패해도 다음 배송을 처리한다")
    void 실패_후_계속_처리() {
        List<UUID> ids = List.of(new UUID(0, 1), new UUID(0, 2), new UUID(0, 3));
        when(deliveryRepository.findEligibleIds(any(), any(), any(), any())).thenReturn(ids);
        doThrow(new IllegalStateException("배송그룹 상태 불일치"))
                .when(deliveryService).completeEligibleDelivery(eq(ids.get(1)), any(), any());

        assertThatCode(scheduler::runDeliveryCompletion).doesNotThrowAnyException();

        for (UUID id : ids) {
            verify(deliveryService).completeEligibleDelivery(eq(id), any(), any());
        }
    }

    @Test
    @DisplayName("음수나 문자로 설정된 완료 대기 시간이면 배치를 건너뛴다")
    void 잘못된_대기_시간이면_처리하지_않는다() {
        for (String delaySeconds : List.of("-1", "abc")) {
            ReflectionTestUtils.setField(scheduler, "completionDelaySeconds", delaySeconds);
            assertThatCode(scheduler::runDeliveryCompletion).doesNotThrowAnyException();
        }
        verifyNoInteractions(deliveryRepository, deliveryService);
    }

    @Test
    @DisplayName("잘못된 설정으로도 초기화에 성공하고 기본 간격으로 등록한다")
    void 잘못된_실행_간격이면_기본값으로_등록한다() {
        try (AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext()) {
            context.getEnvironment().getPropertySources().addFirst(new MapPropertySource("test",
                    java.util.Map.of("delivery.completion.delay-seconds", "abc",
                            "delivery.completion.fixed-delay", "invalid")));
            context.registerBean(DeliveryRepository.class, () -> deliveryRepository);
            context.registerBean(DeliveryService.class, () -> deliveryService);
            context.register(DeliveryCompletionScheduler.class, DeliverySchedulingConfig.class, SchedulingConfig.class);

            assertThatCode(context::refresh).doesNotThrowAnyException();

            assertThat(context.getBean(ScheduledAnnotationBeanPostProcessor.class).getScheduledTasks()).hasSize(1);
            var scheduledTask = context.getBean(ScheduledAnnotationBeanPostProcessor.class)
                    .getScheduledTasks().iterator().next().getTask();
            assertThat(((org.springframework.scheduling.config.FixedDelayTask) scheduledTask).getIntervalDuration())
                    .isEqualTo(java.time.Duration.ofSeconds(60));
        }
        verifyNoInteractions(deliveryRepository, deliveryService);
    }
}

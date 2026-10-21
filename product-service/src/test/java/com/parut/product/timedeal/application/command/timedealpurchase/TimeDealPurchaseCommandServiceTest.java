package com.parut.product.timedeal.application.command.timedealpurchase;

import com.parut.product.global.exception.BusinessException;
import com.parut.product.global.exception.ErrorCode;
import com.parut.product.timedeal.application.dto.timedealpurchase.TimeDealPurchaseCancelCommand;
import com.parut.product.timedeal.application.dto.timedealpurchase.TimeDealPurchaseConfirmCommand;
import com.parut.product.timedeal.application.dto.timedealpurchase.TimeDealPurchaseReserveCommand;
import com.parut.product.timedeal.application.exception.TimeDealReservationExpiredException;
import com.parut.product.timedeal.application.metrics.timedeal.TimeDealPerformanceMetrics;
import com.parut.product.timedeal.application.port.out.timedeal.TimeDealRepository;
import com.parut.product.timedeal.application.port.out.timedealpurchase.TimeDealPurchaseRepository;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockRepository;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockReservationPort;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockReservationResult;
import com.parut.product.timedeal.application.port.out.timedealstock.TimeDealStockCompensationResult;
import com.parut.product.timedeal.domain.common.TimeDealPolicy;
import com.parut.product.timedeal.domain.timedeal.TimeDeal;
import com.parut.product.timedeal.domain.timedeal.TimeDealProductGrade;
import com.parut.product.timedeal.domain.timedealpurchase.TimeDealPurchase;
import com.parut.product.timedeal.domain.timedealpurchase.TimeDealPurchaseCancelReason;
import com.parut.product.timedeal.domain.timedealpurchase.TimeDealPurchaseStatus;
import com.parut.product.timedeal.domain.timedealstock.TimeDealStock;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.test.util.ReflectionTestUtils;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.Optional;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

// NOTE: Repository만 mock하고 TimeDealPolicy는 실물을 쓴다 — Policy를 mock하면 "서비스가 policy를 불렀다"만
// 검증되고 정작 확인해야 하는 애그리거트 상태 결과가 가려진다.
// NOTE: @Transactional / noRollbackFor는 Spring 프록시가 실행하므로 이 테스트에서는 동작하지 않는다.
// "만료 정리가 커밋되는가"는 통합 테스트 영역이다.
@ExtendWith(MockitoExtension.class)
class TimeDealPurchaseCommandServiceTest {

    private static final LocalDate HARVESTED_DATE = LocalDate.of(2026, 9, 1);

    private static final Instant START_AT = Instant.parse("2026-09-04T11:00:00Z");
    private static final Instant END_AT = Instant.parse("2099-09-04T12:00:00Z");
    private static final int INITIAL_QUANTITY = 100;
    private static final int MAX_PURCHASE_QUANTITY = 10;

    @Mock
    private TimeDealRepository timeDealRepository;

    @Mock
    private TimeDealStockRepository timeDealStockRepository;

    @Mock
    private TimeDealPurchaseRepository timeDealPurchaseRepository;

    @Mock
    private TimeDealStockReservationPort timeDealStockReservationPort;

    @Mock
    private TimeDealStockRestoreOutbox stockRestoreOutbox;

    @Mock
    private TimeDealPurchaseExpirationProcessor timeDealPurchaseExpirationProcessor;

    private TimeDealPurchaseCommandService timeDealPurchaseCommandService;

    private TimeDeal timeDeal;
    private TimeDealStock timeDealStock;

    @BeforeEach
    void setUp() {
        // NOTE: TimeDealPolicy는 실물을 쓰므로 @InjectMocks 대신 직접 조립한다.
        timeDealPurchaseCommandService = new TimeDealPurchaseCommandService(
                timeDealRepository,
                timeDealStockRepository,
                timeDealPurchaseRepository,
                new TimeDealPolicy(),
                timeDealStockReservationPort,
                stockRestoreOutbox,
                timeDealPurchaseExpirationProcessor,
                new TimeDealPerformanceMetrics(new SimpleMeterRegistry())
        );

        // NOTE: endAt을 먼 미래로 두어 Instant.now()를 쓰는 서비스에서도 판매 기간 안에 들도록 한다.
        timeDeal = TimeDeal.create(
                UUID.randomUUID(), UUID.randomUUID(),
                "산지직송 사과 5kg", null, TimeDealProductGrade.NORMAL, "경북 안동", HARVESTED_DATE,
                10_000L, BigDecimal.valueOf(30),
                START_AT, END_AT, MAX_PURCHASE_QUANTITY, START_AT);
        // NOTE: id는 @GeneratedValue라 저장 없이는 null이고, 그러면 짝 검증이 통과할 수 없다.
        ReflectionTestUtils.setField(timeDeal, "id", UUID.randomUUID());
        timeDeal.activate(START_AT);

        timeDealStock = TimeDealStock.create(timeDeal.getId(), INITIAL_QUANTITY, 10);
    }

    private TimeDealPurchaseReserveCommand reserveCommand(int quantity) {
        return new TimeDealPurchaseReserveCommand(
                timeDeal.getId(), UUID.randomUUID(), UUID.randomUUID(), quantity);
    }

    private void givenTimeDealAndStockFound() {
        when(timeDealRepository.findById(timeDeal.getId())).thenReturn(Optional.of(timeDeal));
        when(timeDealStockRepository.findByTimeDealId(timeDeal.getId()))
                .thenReturn(Optional.of(timeDealStock));
    }


    @Nested
    @DisplayName("구매 예약")
    class Reserve {

        @Test
        @DisplayName("구매 이력을 저장하고 재고를 선점한다")
        void 예약_성공() {
            givenTimeDealAndStockFound();
            when(timeDealPurchaseRepository.findByOrderId(any())).thenReturn(Optional.empty());
            when(timeDealPurchaseRepository.sumActiveQuantity(any(), any())).thenReturn(0);
            when(timeDealStockReservationPort.reserve(any(), any(), any(), anyInt()))
                    .thenReturn(TimeDealStockReservationResult.RESERVED);
            when(timeDealStockRepository.reserveQuantityAtomically(any(), anyInt())).thenReturn(true);

            timeDealPurchaseCommandService.reserve(reserveCommand(5));

            verify(timeDealPurchaseRepository).saveAndFlush(any(TimeDealPurchase.class));
            verify(timeDealStockRepository).reserveQuantityAtomically(timeDeal.getId(), 5);
        }

        @Test
        @DisplayName("Redis에서 재고 부족이면 DB 재고와 구매 이력을 변경하지 않는다")
        void 예약_재고부족() {
            givenTimeDealAndStockFound();
            when(timeDealPurchaseRepository.findByOrderId(any())).thenReturn(Optional.empty());
            when(timeDealPurchaseRepository.sumActiveQuantity(any(), any())).thenReturn(0);
            when(timeDealStockReservationPort.reserve(any(), any(), any(), anyInt()))
                    .thenReturn(TimeDealStockReservationResult.INSUFFICIENT_STOCK);

            assertThatThrownBy(() -> timeDealPurchaseCommandService.reserve(reserveCommand(5)))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_STOCK_INSUFFICIENT);

            verify(timeDealPurchaseRepository, never()).saveAndFlush(any());
            assertThat(timeDealStock.getReservedQuantity()).isZero();
            assertThat(timeDealStock.getAvailableQuantity()).isEqualTo(INITIAL_QUANTITY);
        }

        @Test
        @DisplayName("DB 구매 저장이 실패하면 Redis 선점을 보상한다")
        void 예약_DB저장실패_보상() {
            givenTimeDealAndStockFound();
            TimeDealPurchaseReserveCommand command = reserveCommand(5);
            when(timeDealPurchaseRepository.findByOrderId(command.orderId())).thenReturn(Optional.empty());
            when(timeDealPurchaseRepository.sumActiveQuantity(any(), any())).thenReturn(0);
            when(timeDealStockReservationPort.reserve(any(), any(), any(), anyInt()))
                    .thenReturn(TimeDealStockReservationResult.RESERVED);
            when(timeDealStockRepository.reserveQuantityAtomically(any(), anyInt())).thenReturn(true);
            when(timeDealStockReservationPort.compensate(any(), any(), any()))
                    .thenReturn(TimeDealStockCompensationResult.COMPENSATED);
            doThrow(new IllegalStateException("database failure"))
                    .when(timeDealPurchaseRepository).saveAndFlush(any(TimeDealPurchase.class));

            assertThatThrownBy(() -> timeDealPurchaseCommandService.reserve(command))
                    .isInstanceOf(IllegalStateException.class)
                    .hasMessage("database failure");

            verify(timeDealStockReservationPort).compensate(
                    command.timeDealId(), timeDealStock.getId(), command.orderId());
        }

        @Test
        @DisplayName("같은 주문의 동일 예약 요청이 다시 오면 재고를 다시 선점하지 않고 그대로 성공한다")
        void 예약_멱등() {
            TimeDealPurchaseReserveCommand command = reserveCommand(5);
            TimeDealPurchase reserved = TimeDealPurchase.create(
                    timeDeal, command.orderId(), command.userId(), command.quantity(), START_AT);
            when(timeDealPurchaseRepository.findByOrderId(command.orderId()))
                    .thenReturn(Optional.of(reserved));

            timeDealPurchaseCommandService.reserve(command);

            verify(timeDealPurchaseRepository, never()).saveAndFlush(any());
            verify(timeDealRepository, never()).findById(any());
            assertThat(timeDealStock.getReservedQuantity()).isZero();
            assertThat(timeDealStock.getAvailableQuantity()).isEqualTo(INITIAL_QUANTITY);
        }

        @Test
        @DisplayName("같은 주문인데 수량이 다르면 재시도가 아니라 충돌이므로 409")
        void 예약_내용불일치() {
            TimeDealPurchaseReserveCommand command = reserveCommand(5);
            TimeDealPurchase reserved = TimeDealPurchase.create(
                    timeDeal, command.orderId(), command.userId(), 3, START_AT);
            when(timeDealPurchaseRepository.findByOrderId(command.orderId()))
                    .thenReturn(Optional.of(reserved));

            assertThatThrownBy(() -> timeDealPurchaseCommandService.reserve(command))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_PURCHASE_ALREADY_EXISTS);

            verify(timeDealRepository, never()).findById(any());
            verify(timeDealPurchaseRepository, never()).saveAndFlush(any());
        }

        @Test
        @DisplayName("같은 주문이 이미 확정·취소됐으면 재시도로 인정하지 않고 409")
        void 예약_이미_후속처리됨() {
            TimeDealPurchaseReserveCommand command = reserveCommand(5);
            TimeDealPurchase reserved = TimeDealPurchase.create(
                    timeDeal, command.orderId(), command.userId(), command.quantity(), START_AT);
            reserved.cancel(TimeDealPurchaseCancelReason.ORDER_CANCELED.name());
            when(timeDealPurchaseRepository.findByOrderId(command.orderId()))
                    .thenReturn(Optional.of(reserved));

            assertThatThrownBy(() -> timeDealPurchaseCommandService.reserve(command))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_PURCHASE_ALREADY_EXISTS);

            verify(timeDealPurchaseRepository, never()).saveAndFlush(any());
        }

        @Test
        @DisplayName("타임딜이 없으면 404")
        void 타임딜_없음() {
            when(timeDealPurchaseRepository.findByOrderId(any())).thenReturn(Optional.empty());
            when(timeDealRepository.findById(any())).thenReturn(Optional.empty());

            assertThatThrownBy(() -> timeDealPurchaseCommandService.reserve(reserveCommand(5)))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_NOT_FOUND);
        }

        @Test
        @DisplayName("재고 정보가 없으면 404")
        void 재고_없음() {
            when(timeDealPurchaseRepository.findByOrderId(any())).thenReturn(Optional.empty());
            when(timeDealRepository.findById(any())).thenReturn(Optional.of(timeDeal));
            when(timeDealStockRepository.findByTimeDealId(any())).thenReturn(Optional.empty());

            assertThatThrownBy(() -> timeDealPurchaseCommandService.reserve(reserveCommand(5)))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_STOCK_NOT_FOUND);
        }

        @Test
        @DisplayName("집계된 누적 수량이 실제로 1인당 제한에 반영된다")
        void 누적수량_전달() {
            givenTimeDealAndStockFound();
            when(timeDealPurchaseRepository.findByOrderId(any())).thenReturn(Optional.empty());
            // 이미 6개를 확보한 사용자가 5개를 더 요청하면 한도 10개를 넘는다.
            when(timeDealPurchaseRepository.sumActiveQuantity(any(), any())).thenReturn(6);

            assertThatThrownBy(() -> timeDealPurchaseCommandService.reserve(reserveCommand(5)))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_EXCEEDS_MAX_PURCHASE_QUANTITY);

            verify(timeDealPurchaseRepository, never()).saveAndFlush(any());
            assertThat(timeDealStock.getReservedQuantity()).isZero();
        }
    }


    @Nested
    @DisplayName("판매 확정")
    class Confirm {

        private TimeDealPurchase reservedPurchase(Instant reservedAt) {
            when(timeDealRepository.findById(timeDeal.getId())).thenReturn(Optional.of(timeDeal));
            return TimeDealPurchase.create(
                    timeDeal, UUID.randomUUID(), UUID.randomUUID(), 5, reservedAt);
        }

        @Test
        @DisplayName("확정되면 선점 수량이 판매 수량으로 이동한다")
        void 확정_성공() {
            TimeDealPurchase purchase = reservedPurchase(Instant.now());
            timeDealStock.reserve(5);
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.of(purchase));
            when(timeDealStockRepository.findByTimeDealIdForUpdate(any())).thenReturn(Optional.of(timeDealStock));

            timeDealPurchaseCommandService.confirm(new TimeDealPurchaseConfirmCommand(UUID.randomUUID()));

            assertThat(purchase.getStatus()).isEqualTo(TimeDealPurchaseStatus.CONFIRMED);
            assertThat(timeDealStock.getSoldQuantity()).isEqualTo(5);
        }

        @Test
        @DisplayName("선점이 만료됐으면 전용 예외를 던지고, 그 전에 정리는 이미 끝나 있다")
        void 만료_확정실패() {
            // NOTE: 선점 TTL 10분을 넘긴 시점을 만들기 위해 reservedAt을 과거로 준다.
            TimeDealPurchase purchase = reservedPurchase(Instant.now().minusSeconds(3600));
            timeDealStock.reserve(5);
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.of(purchase));
            when(timeDealStockRepository.findByTimeDealIdForUpdate(any())).thenReturn(Optional.of(timeDealStock));

            assertThatThrownBy(() -> timeDealPurchaseCommandService.confirm(
                    new TimeDealPurchaseConfirmCommand(UUID.randomUUID())))
                    .isInstanceOf(TimeDealReservationExpiredException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_RESERVATION_EXPIRED);

            // 예외를 던지기 전에 정리가 끝나 있어야 한다 — 커밋 여부는 통합 테스트가 확인한다.
            assertThat(purchase.getStatus()).isEqualTo(TimeDealPurchaseStatus.CANCELLED);
            assertThat(timeDealStock.getAvailableQuantity()).isEqualTo(INITIAL_QUANTITY);
            assertThat(timeDealStock.getReservedQuantity()).isZero();
        }

        @Test
        @DisplayName("구매 이력이 없으면 404")
        void 구매이력_없음() {
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.empty());

            assertThatThrownBy(() -> timeDealPurchaseCommandService.confirm(
                    new TimeDealPurchaseConfirmCommand(UUID.randomUUID())))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_PURCHASE_NOT_FOUND);
        }
    }


    @Nested
    @DisplayName("구매 취소")
    class Cancel {

        @Test
        void 확정취소는_재고복구작업을_한번만_저장한다() {
            TimeDealPurchase purchase = reservedPurchase();
            timeDealStock.reserve(5);
            purchase.confirm(Instant.now());
            timeDealStock.confirmSale(5);
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.of(purchase));
            when(timeDealStockRepository.findByTimeDealIdForUpdate(any())).thenReturn(Optional.of(timeDealStock));
            TimeDealPurchaseCancelCommand command = new TimeDealPurchaseCancelCommand(purchase.getOrderId(), "취소");

            timeDealPurchaseCommandService.cancel(command);
            timeDealPurchaseCommandService.cancel(command);

            assertThat(timeDealStock.getAvailableQuantity()).isEqualTo(INITIAL_QUANTITY);
            assertThat(timeDealStock.getSoldQuantity()).isZero();
            verify(stockRestoreOutbox, org.mockito.Mockito.times(1)).enqueue(purchase, timeDealStock);
        }

        private TimeDealPurchase reservedPurchase() {
            return TimeDealPurchase.create(
                    timeDeal, UUID.randomUUID(), UUID.randomUUID(), 5, Instant.now());
        }

        @Test
        @DisplayName("취소 사유 문구가 그대로 기록되고 재고가 복구된다")
        void 취소_성공() {
            TimeDealPurchase purchase = reservedPurchase();
            timeDealStock.reserve(5);
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.of(purchase));
            when(timeDealStockRepository.findByTimeDealIdForUpdate(any())).thenReturn(Optional.of(timeDealStock));

            timeDealPurchaseCommandService.cancel(new TimeDealPurchaseCancelCommand(
                    UUID.randomUUID(), TimeDealPurchaseCancelReason.ORDER_CANCELED.name()));

            assertThat(purchase.getStatus()).isEqualTo(TimeDealPurchaseStatus.CANCELLED);
            assertThat(purchase.getCancelReason())
                    .isEqualTo(TimeDealPurchaseCancelReason.ORDER_CANCELED.name());
            assertThat(timeDealStock.getAvailableQuantity()).isEqualTo(INITIAL_QUANTITY);
        }

        @Test
        @DisplayName("카탈로그에 없는 자유 문구도 사유로 쓸 수 있다")
        void 자유문구_사유() {
            TimeDealPurchase purchase = reservedPurchase();
            timeDealStock.reserve(5);
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.of(purchase));
            when(timeDealStockRepository.findByTimeDealIdForUpdate(any())).thenReturn(Optional.of(timeDealStock));

            timeDealPurchaseCommandService.cancel(
                    new TimeDealPurchaseCancelCommand(UUID.randomUUID(), "판매자 요청으로 취소"));

            assertThat(purchase.getCancelReason()).isEqualTo("판매자 요청으로 취소");
        }

        @Test
        @DisplayName("이미 취소된 건에 다시 취소가 와도 예외 없이 재고가 이중 복구되지 않는다")
        void 취소_멱등() {
            TimeDealPurchase purchase = reservedPurchase();
            timeDealStock.reserve(5);
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.of(purchase));
            when(timeDealStockRepository.findByTimeDealIdForUpdate(any())).thenReturn(Optional.of(timeDealStock));
            TimeDealPurchaseCancelCommand command = new TimeDealPurchaseCancelCommand(
                    UUID.randomUUID(), TimeDealPurchaseCancelReason.ORDER_CANCELED.name());

            timeDealPurchaseCommandService.cancel(command);
            timeDealPurchaseCommandService.cancel(command);

            assertThat(timeDealStock.getAvailableQuantity()).isEqualTo(INITIAL_QUANTITY);
            assertThat(timeDealStock.getSoldQuantity()).isZero();
        }

        @Test
        @DisplayName("구매 이력이 없으면 404")
        void 구매이력_없음() {
            when(timeDealPurchaseRepository.findByOrderIdForUpdate(any())).thenReturn(Optional.empty());

            assertThatThrownBy(() -> timeDealPurchaseCommandService.cancel(
                    new TimeDealPurchaseCancelCommand(UUID.randomUUID(), null)))
                    .isInstanceOf(BusinessException.class)
                    .extracting("errorCode")
                    .isEqualTo(ErrorCode.TIME_DEAL_PURCHASE_NOT_FOUND);
        }
    }

    @Nested
    @DisplayName("구매 선점 만료 배치")
    class ExpireReservations {

        @Test
        @DisplayName("후보를 페이지 단위로 조회하고 건별 Processor에 위임한다")
        void 만료_후보_페이지_처리() {
            TimeDealPurchase firstPurchase = org.mockito.Mockito.mock(TimeDealPurchase.class);
            TimeDealPurchase secondPurchase = org.mockito.Mockito.mock(TimeDealPurchase.class);
            Instant firstExpiresAt = Instant.parse("2026-09-04T11:10:00Z");
            Instant secondExpiresAt = Instant.parse("2026-09-04T11:11:00Z");
            UUID firstId = UUID.randomUUID();
            UUID secondId = UUID.randomUUID();
            when(firstPurchase.getId()).thenReturn(firstId);
            when(secondPurchase.getId()).thenReturn(secondId);
            when(secondPurchase.getExpiresAt()).thenReturn(secondExpiresAt);
            when(timeDealPurchaseRepository.findFirstExpiredReservationBatch(any(), anyInt()))
                    .thenReturn(List.of(firstPurchase, secondPurchase));
            when(timeDealPurchaseRepository.findNextExpiredReservationBatchByCursor(
                    any(), any(), any(), anyInt()))
                    .thenReturn(List.of());

            timeDealPurchaseCommandService.expireReservations();

            verify(timeDealPurchaseExpirationProcessor).expireOneReservation(firstId);
            verify(timeDealPurchaseExpirationProcessor).expireOneReservation(secondId);
            verify(timeDealPurchaseRepository).findNextExpiredReservationBatchByCursor(
                    any(), org.mockito.ArgumentMatchers.eq(secondExpiresAt),
                    org.mockito.ArgumentMatchers.eq(secondId), anyInt());
        }

        @Test
        @DisplayName("한 건의 실패가 다음 건 처리를 중단시키지 않는다")
        void 만료_처리_실패_격리() {
            TimeDealPurchase firstPurchase = org.mockito.Mockito.mock(TimeDealPurchase.class);
            TimeDealPurchase secondPurchase = org.mockito.Mockito.mock(TimeDealPurchase.class);
            UUID firstId = UUID.randomUUID();
            UUID secondId = UUID.randomUUID();
            when(firstPurchase.getId()).thenReturn(firstId);
            when(secondPurchase.getId()).thenReturn(secondId);
            when(secondPurchase.getExpiresAt()).thenReturn(Instant.parse("2026-09-04T11:11:00Z"));
            when(timeDealPurchaseRepository.findFirstExpiredReservationBatch(any(), anyInt()))
                    .thenReturn(List.of(firstPurchase, secondPurchase));
            when(timeDealPurchaseRepository.findNextExpiredReservationBatchByCursor(
                    any(), any(), any(), anyInt()))
                    .thenReturn(List.of());
            doThrow(new IllegalStateException("processing failure"))
                    .when(timeDealPurchaseExpirationProcessor).expireOneReservation(firstId);

            timeDealPurchaseCommandService.expireReservations();

            verify(timeDealPurchaseExpirationProcessor).expireOneReservation(firstId);
            verify(timeDealPurchaseExpirationProcessor).expireOneReservation(secondId);
        }
    }
}

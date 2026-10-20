package com.parut.order.delivery.infrastructure.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.convert.DurationStyle;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.EnableScheduling;

import lombok.extern.slf4j.Slf4j;

@Configuration
@Profile("!perf")
@EnableScheduling
@Slf4j
public class DeliverySchedulingConfig {

    @Bean
    public long deliveryCompletionFixedDelay(
            @Value("${delivery.completion.fixed-delay:60000}") String fixedDelay
    ) {
        try {
            long delayMillis = DurationStyle.detectAndParse(fixedDelay.trim()).toMillis();
            if (delayMillis > 0) {
                return delayMillis;
            }
            log.error("배송 자동완료 실행 간격은 양수여야 합니다. fixedDelay={}, 기본값 60000ms 적용", fixedDelay);
        } catch (IllegalArgumentException | ArithmeticException e) {
            log.error("배송 자동완료 실행 간격 해석 실패 fixedDelay={}, 기본값 60000ms 적용", fixedDelay, e);
        }
        return 60_000L;
    }
}

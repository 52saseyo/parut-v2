package com.parut.order.global.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

/** order-service의 정기 작업을 활성화하며, 환경별 실행 여부는 각 스케줄러에서 정한다. */
@Configuration
@EnableScheduling
public class SchedulingConfig {
}

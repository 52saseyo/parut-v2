package com.parut.product.global.config;

import com.parut.product.global.constant.KafkaTopicConstants;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.config.TopicBuilder;
import org.apache.kafka.clients.admin.NewTopic;

@Configuration
public class KafkaTopicConfig {

    @Bean
    public NewTopic timeDealOpeningSoonTopic() {
        return TopicBuilder.name(KafkaTopicConstants.TIME_DEAL_OPENING_SOON)
                .partitions(1)
                .replicas(1)
                .build(); // NOTE : 테스트
    }
}

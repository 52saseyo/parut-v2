# Notification Performance Test

## 환경

- Java 21
- PostgreSQL
- Kafka
- JMeter
- 테스트 대상 commit/tag

## 데이터 준비

- 테스트는 전용 UUID 대역을 사용한다.
- JMeter 요청은 실제 DB 트랜잭션을 수행하므로 테스트 후 자동 롤백되지 않는다.
- 테스트 전용 데이터와 결과 데이터는 seed 재실행 또는 별도 정리 SQL로 초기화한다.
- 대량 Fan-out 테스트 전에는 SQL debug/bind 로그를 비활성화하는 것을 권장한다.

모든 명령은 `notification-service` 디렉터리를 현재 작업 디렉터리로 두고 실행한다.

```bash
cd notification-service
mkdir -p test-results
```

필요한 테스트 데이터 파일은 아래 기준으로 준비한다.

| 파일 | 용도 |
|---|---|
| `performance-test/data/subscription-concurrency-seed.sql` | 구독 중복 요청 테스트용 사용자/타임딜 구독 초기화 |
| `performance-test/data/kafka-fanout-subscription-seed.sql` | Kafka Fan-out 정확성/Stress 테스트용 구독자 데이터 생성 |
| `performance-test/data/notification-read-load-seed.sql` | 알림 조회 Load Test용 알림 데이터 생성 |
| `performance-test/data/notification-users.csv` | 알림 조회 Load Test에서 순환할 사용자 ID 목록 |
| `performance-test/data/kafka-events.json` | Kafka 발행 이벤트 예시 |

## 1. 구독 중복 요청 Concurrency Test

`jmeter/subscription-concurrency-test.jmx`

- Threads: 100
- Ramp-up: 1초
- Loop Count: 1
- Synchronizing Timer: 100개 Thread
- 요청 조건: 동일 `userId`, 동일 `timeDealId`
- 총 요청 수: 100회

요청 대상:

`POST http://localhost:8084/api/v1/notification-subscriptions/time-deals`

헤더:

- `Content-Type: application/json`
- `X-User-Id: ${userId}`

본문:

`{"timeDealId":"${timeDealId}"}`

실행 예시:

```bash
psql "$NOTIFICATION_DATABASE_URL" \
  -f performance-test/data/subscription-concurrency-seed.sql

jmeter -n -t performance-test/jmeter/subscription-concurrency-test.jmx \
  -JnotificationPort=8084 \
  -JuserId=90000000-0000-4000-8000-000000000001 \
  -JtimeDealId=91000000-0000-4000-8000-000000000001 \
  -l test-results/subscription-concurrency.jtl \
  -j test-results/subscription-concurrency.log
```

목적:

같은 사용자와 같은 타임딜에 동시에 구독 요청이 들어와도 active 구독이 1건만 유지되는지 확인한다.

확인 기준:

- 최종 구독 row 1건
- `deleted_at is null` active 구독 1건
- 중복 row 0건
- 서버 5xx 0건
- deadlock / lock timeout 0건

검증 SQL 예시:

```sql
select
  count(*) as total_rows,
  count(*) filter (where deleted_at is null) as active_rows
from p_time_deal_notification_subscriptions
where user_id = '90000000-0000-4000-8000-000000000001'
  and time_deal_id = '91000000-0000-4000-8000-000000000001';
```

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/subscription-concurrency.jtl \
  -o test-results/subscription-concurrency-report
```

생성된 Report에서 응답 코드, Error Rate, P95/P99를 확인한다. 이 테스트는 성능보다 정합성과 5xx 여부가 핵심이다.

## 2. Kafka Fan-out 정확성 테스트

Kafka 이벤트가 발행됐을 때 구독자 수만큼 알림이 정확히 생성되는지 확인한다.

대상:

- Kafka topic: `time-deal.opening-soon`
- Consumer group: `notification-time-deal-opening-soon`
- 결과 테이블: `p_notifications`

테스트 단계:

| 단계 | 이벤트 수 | 이벤트당 구독자 수 | 예상 알림 수 | 목적 |
|---|---:|---:|---:|---|
| Medium | 1 | 1,000 | 1,000 | 기본 Fan-out 정확성 확인 |
| Large | 1 | 10,000 | 10,000 | 단일 이벤트 대량 생성 정확성 확인 |
| Multiple Event | 20 | 2,000 | 40,000 | 여러 이벤트 연속 유입 시 정확성 확인 |
| Duplicate | 같은 eventId 재발행 | 10,000 | 신규 0 | 중복 이벤트 멱등성 확인 |

데이터 준비:

```bash
psql "$NOTIFICATION_DATABASE_URL" \
  -f performance-test/data/kafka-fanout-subscription-seed.sql
```

이벤트 발행 예시:

```bash
docker exec -i kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic time-deal.opening-soon < performance-test/data/kafka-events.json
```

확인 기준:

- 이벤트별 알림 수가 active 구독자 수와 동일
- Multiple Event 전체 알림 수가 `이벤트 수 * 이벤트당 구독자 수`와 동일
- Duplicate 재발행 시 신규 알림 0건
- `(event_id, user_id)` 중복 row 0건
- Kafka lag가 테스트 종료 후 수분 내 0으로 회복
- 서버 예외 0건

검증 SQL 예시:

```sql
select event_id, count(*) as notification_count
from p_notifications
where event_id in (
  '96000000-0000-4000-8000-000000001000',
  '96000000-0000-4000-8000-000000010000'
)
group by event_id
order by event_id;
```

중복 알림 검증:

```sql
select event_id, user_id, count(*) as duplicate_count
from p_notifications
group by event_id, user_id
having count(*) > 1;
```

Kafka lag 확인:

```bash
docker exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group notification-time-deal-opening-soon
```

목적:

정확성 테스트는 처리 한계보다 "정확히 생성되는가"가 목적이다. 따라서 Stress Test보다 작은 수치로 이벤트별 생성 수, 중복 방지, Kafka 재처리 안정성을 먼저 검증한다.

## 3. Kafka Fan-out Stress Test

구독자가 매우 많거나 이벤트가 많이 몰릴 때 알림서비스가 어느 수준까지 안정적으로 처리할 수 있는지 확인한다.

테스트 단계:

| 단계 | 이벤트 수 | 이벤트당 구독자 수 | 예상 알림 수 | 목적 |
|---|---:|---:|---:|---|
| Stress 50K | 1 | 50,000 | 50,000 | 단일 이벤트 대량 구독자 처리 기준선 확인 |
| Stress 100K | 1 | 100,000 | 100,000 | 단일 이벤트 대규모 Fan-out 처리 확인 |
| Multi Stress 250K | 10 | 25,000 | 250,000 | 여러 이벤트 누적 처리 시 DB insert/Kafka lag 확인 |
| Peak Stress 500K | 20 | 25,000 | 500,000 | 피크 시간대 다중 이벤트 처리 한계 확인 |
| Limit Stress 1M | 50 | 20,000 | 1,000,000 | 최대 처리 한계와 장애 지점 탐색 |

단계별 판단 기준:

| 단계 | 판단 기준 |
|---|---|
| Stress 50K | 반드시 성공해야 하는 기준 |
| Stress 100K | 목표 성공 기준 |
| Multi Stress 250K | 목표 성공 기준 또는 병목 확인 기준 |
| Peak Stress 500K | 한계 검증 기준 |
| Limit Stress 1M | 탐색 기준. 실패해도 병목 분석이 목적 |

측정:

- 알림 생성 수
- 이벤트 발행부터 알림 생성 완료까지의 처리 시간
- Kafka consumer group lag 및 회복 시간
- DB slow query, CPU, insert 지연
- Hikari active / idle / pending
- JVM GC, heap 사용량, OOM 여부
- application log의 exception / timeout

성공 기준:

- 예상 알림 수와 실제 생성 수가 동일
- 중복 row 0건
- 알림 생성 실패 0건
- Kafka lag가 테스트 종료 후 수분 내 0으로 회복
- Hikari pending 지속 누적 없음
- DB timeout 0건
- OOM / 서버 장애 0건

참고:

`50K -> 100K -> 250K -> 500K -> 1M` 순서로 수치를 올리면 Kafka lag, DB insert 지연, 커넥션 풀 고갈, JVM 메모리 문제를 단계별로 확인할 수 있다. `1M`은 필수 성공 기준이 아니라 최대 처리 한계와 복구 가능성을 확인하기 위한 탐색 기준으로 본다.

## 4. 알림 조회 Load Test

`jmeter/notification-read-load-test.jmx`

생성된 알림을 사용자가 조회할 때 안정적인 응답 시간을 유지하는지 확인한다.

대상 API:

```text
GET /api/v1/notifications/unread-count
GET /api/v1/notifications?size=20
GET /api/v1/notifications?cursor={createdAt}&cursorId={notificationId}&size=20
```

데이터 준비:

- 사용자 1,000명
- 일반 사용자 알림: 사용자당 100건
- 헤비 유저 알림: 특정 사용자 1명에게 100,000건
- 읽음 상태: read 70%, unread 30%
- 생성 시간: cursor 조회가 가능하도록 `created_at` 분산

```bash
psql "$NOTIFICATION_DATABASE_URL" \
  -f performance-test/data/notification-read-load-seed.sql
```

요청 비율:

| 요청 | 비율 |
|---|---:|
| 미읽음 수 조회 | 30% |
| 알림 목록 첫 페이지 조회 | 50% |
| 알림 목록 다음 페이지 조회 | 20% |

Load 단계:

| 단계 | RPS | 지속 시간 | 목적 |
|---|---:|---:|---|
| Load 30 | 30 | 10분 | 기본 조회 성능 확인 |
| Load 50 | 50 | 10분 | 일반 부하 성능 확인 |
| Load 100 | 100 | 10분 | 피크 조회 부하 확인 |

실행 예시:

```bash
jmeter -n -t performance-test/jmeter/notification-read-load-test.jmx \
  -JnotificationPort=8084 \
  -JtargetRps=30 \
  -Jduration=600 \
  -JuserCsv=../data/notification-users.csv \
  -l test-results/notification-read-load-30.jtl \
  -j test-results/notification-read-load-30.log
```

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/notification-read-load-30.jtl \
  -Jjmeter.reportgenerator.overall_granularity=5000 \
  -o test-results/notification-read-load-30-report
```

확인 기준:

- 에러율 0%
- 알림 목록 P95 300ms 이하
- 미읽음 수 P95 200ms 이하
- P99 1초 이하
- Hikari pending 지속 누적 없음
- 반복 slow query 없음
- 일반 사용자와 헤비 유저 응답 시간이 과도하게 벌어지지 않을 것

## 최소 성공 기준 요약

| 영역 | 최소 성공 기준 |
|---|---|
| 구독 정합성 | 동일 사용자/타임딜 active 구독 1건 |
| 구독 API 안정성 | 5xx 0건 |
| Fan-out 정확성 | 구독자 수만큼 알림 생성 |
| 중복 이벤트 | 신규 알림 0건 |
| Stress 처리 | 예상 알림 수 생성, 서버 장애 없음 |
| Kafka | lag 수분 내 0 회복 |
| 조회 성능 | 목록 P95 300ms 이하 |
| 미읽음 수 | P95 200ms 이하 |
| DB 커넥션 | Hikari pending 지속 누적 없음 |
| 안정성 | deadlock, timeout, OOM 0건 |

## 내부 병목 관찰

현재 테스트만으로 정확히 확인 가능한 항목:

- 최종 알림 생성 수
- 중복 알림 여부
- Kafka lag
- 서버 에러
- DB 최종 정합성

아래 항목은 별도 계측이 있어야 정확히 확인할 수 있다.

| 추가 계측 필요 항목 | 이유 |
|---|---|
| 구독자 조회 시간 | Fan-out 내부에서 구독자 조회가 얼마나 걸리는지 분리 측정 필요 |
| 기존 알림 조회 시간 | 중복 방지를 위한 기존 알림 조회 비용 측정 필요 |
| 알림 객체 생성 시간 | 애플리케이션 내부 객체 생성 비용 측정 필요 |
| 알림 저장 시간 | DB insert/saveAll 구간만 별도 측정 필요 |
| 전체 Fan-out 처리 시간 | 이벤트 1건 처리의 end-to-end 내부 시간 측정 필요 |

권장 Micrometer Timer:

| Timer 이름 | 측정 구간 |
|---|---|
| `notification.fanout.total` | 이벤트 1건 전체 처리 시간 |
| `notification.fanout.subscriber.lookup` | active 구독자 조회 시간 |
| `notification.fanout.existing.lookup` | 기존 알림 조회 시간 |
| `notification.fanout.build` | 알림 객체 생성 시간 |
| `notification.fanout.save` | 알림 저장 시간 |

`eventId`, `timeDealId`, `userId`처럼 값이 계속 늘어나는 항목은 metric tag로 넣지 않는다. 대신 `type=TIME_DEAL_OPENING_SOON`, `result=success|duplicate|error` 정도의 낮은 cardinality tag만 사용한다.

# Notification Performance Test

## 환경

- Java 21
- PostgreSQL
- Kafka
- JMeter
- Prometheus
- Grafana
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
| `performance-test/data/kafka-fanout-workload-seed.sql` | Sequential/Spike 공통 구독 관계 생성 |
| `performance-test/data/kafka-workload-sequential-events.csv` | Sequential 이벤트와 발행 대기시간 |
| `performance-test/data/kafka-workload-spike-events.csv` | Spike 집중 발행 이벤트 |
| `performance-test/data/kafka-fanout-sequential-verify.sql` | Sequential 정합성 검증 |
| `performance-test/data/kafka-fanout-spike-verify.sql` | Spike 전후 및 집중 구간 정합성 검증 |
| `performance-test/data/kafka-fanout-stress-seed.sql` | 단일 이벤트의 구독자 규모별 Stress 구독 관계 생성 및 이전 실행 데이터 정리 |
| `performance-test/data/kafka-fanout-stress-verify.sql` | Stress 이벤트의 저장 수, 중복, 누락 및 예상 외 알림 검증 |
| `performance-test/jmeter/kafka-fanout-stress-test.jmx` | 구독자 규모별 단일 Kafka 이벤트 발행 |
| `performance-test/scripts/run-kafka-fanout-stress.sh` | Stress 데이터 준비, 실행, 모니터링 및 검증 자동화 |
| `src/main/java/com/parut/notification/notification/application/metrics/NotificationFanoutMetrics.java` | Fan-out 전체·단계별 Timer와 Counter 기록 |
| `src/main/resources/application-docker.yml` | Histogram/SLO 및 대량 테스트용 로그 레벨 설정 |
| `../infra/grafana/dashboards/Kafka Fan-out Performance Dashboard.json` | Fan-out 요약·단계별·DB Flush 대시보드 |
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

## 2. Single Event Test

Kafka 이벤트 한 건을 수신했을 때 구독자 수만큼 알림을 정확하고 빠르게 생성하는지
확인한다. 1K 이벤트로 기본 동작을 검증하고 10K 이벤트로 단일 인기 타임딜의 기준 성능을
측정한다.

대상:

- Kafka topic: `time-deal.opening-soon`
- Consumer group: `notification-time-deal-opening-soon`
- 결과 테이블: `p_notifications`

Single Event 시나리오:

| 단계 | 이벤트 수 | 이벤트당 구독자 수 | 예상 알림 수 | 목적 |
|---|---:|---:|---:|---|
| Medium | 1 | 1,000 | 1,000 | 기본 Fan-out 정확성 확인 |
| Large | 1 | 10,000 | 10,000 | 단일 이벤트 기준 성능과 정확성 확인 |

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

Kafka lag 확인:

```bash
docker exec kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group notification-time-deal-opening-soon
```

Single Event 주요 측정값:

- Fan-out Latency
- Notification Throughput
- Subscriber Lookup, Existing Lookup, Save, DB Flush 시간
- 예상 알림 수와 실제 Commit 알림 수
- Kafka Lag, CPU, JVM, GC, HikariCP 상태

10K 초기 기준:

| 항목 | 목표 | 허용 상한 |
|---|---:|---:|
| 알림 생성 | 10,000/10,000 | 반드시 일치 |
| Fan-out Latency | 2초 이하 | 5초 |
| Notification Throughput | 5,000 notifications/s 이상 | 2,000 notifications/s 이상 |
| 누락·중복 | 0건 | 0건 |
| Consumer·DB 오류 | 0건 | 0건 |
| 최종 Kafka Lag | 0 | 0 |

Single Event Test는 단일 이벤트의 기준 성능과 정확성을 측정하며, 이후 테스트 결과를
비교하기 위한 기준선으로 사용한다. Sequential Event Test에서는 시간차를 둔 연속 유입에도
기준 성능이 유지되는지, Spike Test에서는 동시 유입으로 증가한 지연이 허용 범위 안에서
회복되는지, Stress Test에서는 구독자 증가에 따라 처리시간과 자원 사용량이 어느 지점부터
급격히 증가하거나 실패하는지 판단한다.

## 3. Sequential Event Test

### 목적과 시나리오

서로 다른 규모의 타임딜 알림이 일정 시간 동안 불규칙한 간격으로 유입되는 정상 운영형
워크로드를 검증한다. 인기 타임딜을 중간에 배치해 이전 상태, 10K 처리, 회복 및 후속
이벤트 처리를 한 실행에서 관찰한다.

| 상대 시점 | 이벤트 | 구독자 수 | 이전 이벤트와 간격 |
|---:|---|---:|---:|
| T+1분 | Event 1 | 500명 | 기준 구간 1분 |
| T+3분 | Event 2 | 1,500명 | 2분 |
| T+7분 | Event 3 | 10,000명 | 4분 |
| T+10분 | Event 4 | 2,000명 | 3분 |
| T+14분 | Event 5 | 4,000명 | 4분 |
| T+16분 | 관찰 종료 | - | 회복 관찰 2분 |

약 16분은 운영 트래픽에서 도출된 고정값이 아니라 이벤트 전후 상태를 분리해 관찰하기
위한 최초 엔지니어링 조건이다. 이 테스트는 최대 처리량이나 장시간 Soak 안정성을
입증하지 않는다.

### 목표

- 서로 다른 규모의 이벤트가 시간차를 두고 유입될 때 안정적으로 처리하는지 확인
- 대규모 이벤트 처리 이후에도 후속 이벤트의 Fan-out 성능과 Kafka Lag 회복 여부 확인
- 알림 정합성, Fan-out Latency, Notification Throughput, CPU, JVM, GC, Connection Pool 안정성 확인



### Sequential Event 실행


```bash
cd /Users/hongtaegyu/IdeaProjects/parut-v2/notification-service
./performance-test/scripts/run-kafka-fanout-sequential.sh 1
```

스크립트는 다음 작업을 순서대로 수행한다.

1. 전용 UUID 대역의 기존 알림·구독을 정리하고 Seed를 생성한다.
2. Consumer 할당과 시작 Kafka Lag 0을 확인한다.
3. Kafka Lag과 Docker 자원 수집을 시작한다.
4. CSV의 대기시간에 따라 5개 이벤트를 발행한다.
5. 알림 18,000건 및 Lag 0이 연속 확인될 때까지 기다린다.
6. 이벤트별 Fan-out Latency와 Notification Throughput을 계산한다.
7. JMeter·Consumer 오류를 수집하고 정합성 SQL을 실행한다.

JMeter 발행이 약 14분 동안 실행된 후 기본 180초 동안 완료를 기다린다. 필요하면 다음처럼
완료 대기시간만 변경한다.

```bash
WAIT_TIMEOUT_SECONDS=300 ./performance-test/scripts/run-kafka-fanout-sequential.sh 1
```

## 4. Spike Test

### 목적과 시나리오

정상 상태에서 2,000명 Baseline 이벤트를 먼저 처리한 뒤 서로 다른 규모의 이벤트 5건을
1초 이내에 집중 발행한다. 이후 동일한 2,000명 규모의 Recovery 이벤트를 처리해 순간 적체가
생기더라도 알림 유실 없이 처리하고 Kafka Lag과 자원이 정상 상태로 회복되는지 확인한다.

| 상대 시점 | 구간 | 이벤트 수 | 이벤트별 구독자 수 | 예상 알림 수 |
|---:|---|---:|---|---:|
| T+1분 | Baseline | 1건 | 2,000명 | 2,000건 |
| T+3분 | Spike | 5건 | 1,000/2,000/3,000/4,000/10,000명 | 20,000건 |
| T+5분 | Recovery | 1건 | 2,000명 | 2,000건 |
| T+7분 | 관찰 종료 | - | - | 총 24,000건 |

```text
T+0~1분  Grafana 기본 상태 확인
T+1분    Baseline 이벤트 1건 발행
T+3분    혼합 규모 이벤트 5건 집중 발행
T+5분    Recovery 이벤트 1건 발행
T+5~7분  Kafka Lag과 CPU, JVM, GC, HikariCP 회복 상태 관찰
```

### 목표

- 여러 이벤트가 동시에 유입되는 순간 부하를 안정적으로 처리하는지 확인
- 집중 부하 이후 Fan-out 성능과 Kafka Lag, 시스템 자원이 정상 상태로 회복되는지 확인
- 알림 정합성, Fan-out TPS, Notification Throughput, CPU, JVM, GC, Connection Pool 안정성 확인

### Spike 실행

실행 전 Grafana에서 약 1분간 기본 상태를 확인한 다음 명령을 실행한다.

```bash
cd /Users/hongtaegyu/IdeaProjects/parut-v2/notification-service
./performance-test/scripts/run-kafka-fanout-spike.sh 1
```

Spike 스크립트는 Baseline, Spike, Recovery 이벤트를 각각 T+1분, T+3분, T+5분에 발행한다.
전체 알림 생성과 Lag 0을 확인한 뒤 기본 120초 동안 자원 회복 상태를 추가로 수집한다.
추가 관찰시간은 다음과 같이 변경할 수 있다.

```bash
RECOVERY_OBSERVATION_SECONDS=60 ./performance-test/scripts/run-kafka-fanout-spike.sh 1
```

### 공통 결과 파일

각 실행은 `test-results`에 다음 파일을 만든다. `<type>`은 `sequential` 또는 `spike`다.

```text
kafka-fanout-<type>-run-1-seed.txt
kafka-fanout-<type>-run-1.jtl
kafka-fanout-<type>-run-1.log
kafka-fanout-<type>-run-1-verification.txt
kafka-consumer-<type>-run-1.txt
kafka-lag-<type>-run-1.csv
container-stats-<type>-run-1.csv
kafka-publish-count-<type>-run-1.txt
fanout-measurements-<type>-run-1.csv
fanout-throughput-<type>-run-1-summary.txt
errors-<type>-run-1.txt
```

`fanout-measurements-<type>-run-1.csv`는 이벤트별로 다음 값을 기록한다.

```text
event_id
expected_count
committed_count
consumer_received_epoch_ms
transaction_completed_epoch_ms
fanout_ms
result
notifications_per_second
```

이벤트별 Notification Throughput은 `committed_count / fanout_ms`로 계산한다. Sequential Event Test에서는
이벤트별 Fan-out Latency와 이 처리율을 주 성능값으로 사용한다.

`fanout-throughput-<type>-run-1-summary.txt`는 다음 값을 기록한다.

```text
Fan-out 처리 구간 = 마지막 Commit 시각 - 첫 Consumer 수신 시각
Fan-out TPS = Commit 성공 이벤트 수 / Fan-out 처리 구간
Notification Throughput = Commit 알림 수 / Fan-out 처리 구간
Fan-out Average/Max = 성공한 이벤트별 Fan-out 시간의 평균/최댓값
```

Spike에서는 Fan-out TPS와 전체 Notification Throughput을 적체 해소 성능값으로 사용한다.
이때 계산 대상은 집중 발행된 5건과 20,000개 알림이며 Baseline, Recovery 및 대기시간은
제외한다. Baseline과 Recovery Fan-out Latency는 순간 부하 이후 성능 회복을 비교하는 값이다.
Sequential Event Test의 전체 TPS는 이벤트 사이의 의도적인 유휴 시간에 영향을 받으므로
참고값으로만 본다.

JMeter의 응답시간은 Kafka broker가 발행을 승인할 때까지의 시간이며 알림 생성 완료시간이
아니다. 상세 Fan-out은 Grafana의 `notification.fanout.total`, 단계별 Timer와 DB Commit
완료 후 증가한 알림 수를 함께 사용해 판단한다. `created_at` 범위는 INSERT 시간 분포를
보는 보조값이며 E2E 시간이나 DB TPS로 표현하지 않는다.

Grafana 대시보드:

```text
http://localhost:3000/d/kafka-fanout-performance/kafka-fan-out-performance
```

처음에는 각 시나리오를 한 번 실행해 데이터와 수집 과정부터 검증한다. 구성이 정상이라면
Seed부터 다시 시작해 독립 3회 실행하고 정합성은 3회 모두 통과해야 한다. 시간과 회복값은
중앙값과 최악값을 함께 기록한다.

## 5. Stress Test

### 목적과 범위

인기 타임딜 한 건의 구독자 수를 단계적으로 증가시켜 단일 이벤트의 최대 안정 처리 규모,
최초 성능 한계 및 실제 병목 구간을 확인한다. Sequential Event Test와 Spike Test가 여러
이벤트의 유입 패턴을 검증한다면, Stress Test는 이벤트 수를 한 건으로 고정하고 해당 이벤트가
생성해야 하는 알림 수만 증가시킨다.

각 규모의 Fan-out Latency, Notification Throughput, Kafka Lag 및 자원 사용량 변화로 한계 지점을 찾고, 결과는 운영 SLA가
아닌 동일한 로컬 환경에서의 성능 비교 기준으로 사용한다.

### 측정 항목

| 측정값 | 의미 |
|---|---|
| Fan-out Latency | Consumer 수신부터 알림 저장 트랜잭션 완료까지 걸린 시간 |
| Notification Throughput | Commit된 알림 수를 Fan-out Latency로 나눈 초당 알림 처리량 |
| 단계별 Timer | Subscriber Lookup, Existing Lookup, Save, DB Flush 처리시간 |
| Kafka Lag | 처리 중 최대 Lag과 테스트 완료 후 최종 Lag |
| 정합성 | 예상 저장 수, 실제 저장 수, 중복, 누락 및 예상 외 알림 |
| 시스템 자원 | notification-service와 PostgreSQL의 CPU, 메모리 및 Block I/O |
| JVM·DB 상태 | Heap, Old Gen, GC Pause, HikariCP Pending 및 Timeout |

단일 이벤트만 발행하므로 events/s 단위의 Fan-out TPS는 주요 지표로 사용하지 않는다. JMeter
결과는 이벤트 발행 성공 여부만 확인하며, 처리시간과 처리량은 `FANOUT_MEASUREMENT` 로그의
Consumer 수신 시각과 트랜잭션 완료 시각을 기준으로 계산한다.

### 단계별 시나리오

| 구간 | 구독자 수 | 반복 | 목적 |
|---|---:|---:|---|
| Warm-up | 1K | 1회 | 최초 실행에 따른 초기화 영향 제거 및 실행 환경 확인 |
| Baseline | 10K | 3회 | Single Event 기준 성능 재현 |
| 초기 탐색 | 30K·50K·70K·100K·150K·200K | 각 1회 | 규모 증가에 따른 처리시간과 자원 변화 확인 |
| 확장 탐색 | 300K·500K·750K·1M | 각 1회 | 초기 탐색이 안정적일 때 처리 한계 탐색 |
| 경계 재측정 | 최대 안정 후보·최초 불안정 규모 | 각 3회 | 일시적 변동과 반복 가능한 한계 구분 |

다음 규모는 이전 실행의 최종 Kafka Lag이 0이고 서비스와 DB 자원이 안정된 후 진행한다.
실패가 발생하면 더 큰 규모로 진행하지 않고 마지막 정상 규모와 최초 실패 규모 사이를
세분화한다. 1M까지 안정적으로 처리되면 최대 처리 규모를 1M으로 단정하지 않고, 로컬 테스트
범위인 1M까지 한계를 발견하지 못한 것으로 기록한다.

초기 탐색은 각 실행 후 최소 3분, 확장 탐색은 최소 5분의 간격을 둔다. 대기시간이 지나도
Kafka Lag, CPU, DB I/O, GC 또는 HikariCP가 안정되지 않았다면 다음 규모를 실행하지 않는다.
기존 10K 기준이 안정적으로 재현되면 초기 탐색은 30K부터 시작한다. 처리시간 급증이나
오류가 발생한 경우 사이의 변화 구간을 확인한다.



```bash
cd /Users/hongtaegyu/IdeaProjects/parut-v2
docker compose ps

cd notification-service
jmeter -v
psql --version
```

스크립트 실행 형식:

```bash
./performance-test/scripts/run-kafka-fanout-stress.sh <subscriber-count> <run-number>
```

스크립트는 Stress 전용 UUID 대역의 이전 알림과 현재 규모가 아닌 구독 데이터를 정리하고,
Seed 생성과 `ANALYZE`를 완료한 후 측정을 시작한다. 같은 규모를 반복할 때는 활성 구독 관계를
재사용한다. 실행 중에는 Kafka Lag과 컨테이너 자원을 수집하고, 완료 후 저장 정합성과 오류를
검증한다.

### 실행 순서

Warm-up과 Baseline:

```bash
./performance-test/scripts/run-kafka-fanout-stress.sh 1000 1

./performance-test/scripts/run-kafka-fanout-stress.sh 10000 1
./performance-test/scripts/run-kafka-fanout-stress.sh 10000 2
./performance-test/scripts/run-kafka-fanout-stress.sh 10000 3
```

초기 탐색:

```bash
./performance-test/scripts/run-kafka-fanout-stress.sh 30000 1
./performance-test/scripts/run-kafka-fanout-stress.sh 50000 1
./performance-test/scripts/run-kafka-fanout-stress.sh 70000 1
./performance-test/scripts/run-kafka-fanout-stress.sh 100000 1
./performance-test/scripts/run-kafka-fanout-stress.sh 150000 1
./performance-test/scripts/run-kafka-fanout-stress.sh 200000 1
```

초기 탐색이 안정적일 때 확장:

```bash
./performance-test/scripts/run-kafka-fanout-stress.sh 300000 1

WAIT_TIMEOUT_SECONDS=900 \
  ./performance-test/scripts/run-kafka-fanout-stress.sh 500000 1

WAIT_TIMEOUT_SECONDS=1200 \
  ./performance-test/scripts/run-kafka-fanout-stress.sh 750000 1

WAIT_TIMEOUT_SECONDS=1200 \
  ./performance-test/scripts/run-kafka-fanout-stress.sh 1000000 1
```

`WAIT_TIMEOUT_SECONDS`는 성능 목표가 아니라 테스트가 무한히 대기하지 않도록 하는 안전장치다.
같은 규모와 실행 번호의 결과 파일이 이미 있으면 덮어쓰지 않고 종료하므로 재실행할 때는 새로운
실행 번호를 사용한다.

### 결과 파일

100K Run 1을 실행하면 `test-results`에 다음 파일을 만든다.

```text
kafka-fanout-stress-100000-run-1-seed.txt
kafka-fanout-stress-100000-run-1.jtl
kafka-fanout-stress-100000-run-1.log
kafka-fanout-stress-100000-run-1-verification.txt
kafka-consumer-stress-100000-run-1.txt
kafka-lag-stress-100000-run-1.csv
container-stats-stress-100000-run-1.csv
kafka-publish-count-stress-100000-run-1.txt
fanout-measurements-stress-100000-run-1.csv
fanout-throughput-stress-100000-run-1-summary.txt
errors-stress-100000-run-1.txt
```

주요 결과 확인:

```bash
cat test-results/fanout-throughput-stress-100000-run-1-summary.txt
cat test-results/kafka-fanout-stress-100000-run-1-verification.txt
cat test-results/errors-stress-100000-run-1.txt
```

### 안정 처리 및 중단 기준

아래 조건을 모두 만족한 규모를 안정 처리 후보로 본다.

- 예상 알림 수와 Commit된 알림 수 일치
- 누락, 중복, 예상 외 알림 및 처리 실패 0건
- 최종 Kafka Lag 0 회복
- OOM, Rollback, Timeout 및 서비스 재시작 없음
- 동일 규모 반복 실행에서 처리시간과 자원 사용량이 재현 가능한 범위 유지

다음 중 하나가 발생하면 더 큰 규모로 진행하지 않고 현재 결과를 보존한 뒤 원인을 분석한다.

- 대기시간 안에 알림 저장과 Kafka Lag 회복이 완료되지 않음
- 알림 누락, 중복 또는 예상 외 저장 발생
- Kafka Lag이 지속적으로 증가하거나 0으로 회복되지 않음
- OOM, DB Connection Timeout, Rollback 또는 Consumer 반복 예외 발생
- notification-service 또는 PostgreSQL 컨테이너 재시작
- Fan-out Latency, DB Flush 또는 자원 사용량이 직전 규모보다 급격히 증가

경계 구간에서는 최대 안정 규모 후보와 최초 불안정 규모를 각각 3회 실행한다. 각 실행의
Fan-out Latency, Notification Throughput, 최대·최종 Kafka Lag, 단계별 Timer, 정합성과 오류를
기록하고 중앙값과 최악값을 함께 비교한다.




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
| 알림 저장 시간 | DB insert/saveAll 구간만 별도 측정 필요 |
| DB Flush 시간 | 실제 INSERT SQL 실행 구간을 분리 측정할 필요 |
| 전체 Fan-out 처리 시간 | 이벤트 1건 처리의 end-to-end 내부 시간 측정 필요 |

Micrometer Timer:

| Timer 이름 | 측정 구간 |
|---|---|
| `notification.fanout.total` | Consumer Listener 진입부터 트랜잭션 Commit 또는 실패까지 |
| `notification.fanout.subscriber.lookup` | active 구독자 조회 시간 |
| `notification.fanout.existing.lookup` | 기존 알림 조회 시간 |
| `notification.fanout.save` | 알림 저장 시간 |
| `notification.fanout.flush` | 실제 INSERT SQL 실행 시간 |

`eventId`, `timeDealId`, `userId`처럼 값이 계속 늘어나는 항목은 metric tag로 넣지 않는다. 대신 `type=TIME_DEAL_OPENING_SOON`, `result=success|failure` 정도의 낮은 cardinality tag만 사용한다. 빈 구독자와 이미 처리된 이벤트는 정상적으로 종료된 처리로 보고 별도 결과 태그를 만들지 않는다.

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

- 모든 테스트는 전용 UUID 대역을 사용한다.
- JMeter와 Kafka Consumer는 실제 DB 트랜잭션을 수행하므로 자동 롤백되지 않는다.
- Load와 Spike Test 모두 기준 작업량으로 이벤트 1건당 서로 다른 active 구독자 10,000명을 준비한다.
- Load Test는 약 5분 동안 합성 이벤트 60건을 5초 간격으로 발행해 지속 처리 안정성을 확인한다.
- Spike Test는 이벤트 10건 또는 20건을 1초 안에 집중 발행한다.
- 각 시나리오는 Seed부터 다시 시작해 3회 반복하고 Median과 최악값을 함께 기록한다.
- 재실행 전 Seed SQL을 다시 실행하고 이전 테스트의 Kafka lag가 0인지 확인한다.
- 대량 Fan-out 테스트에서는 SQL debug/bind 로그를 비활성화한다.

아래 명령은 `notification-service` 디렉터리를 현재 작업 디렉터리로 두고 실행한다.

```bash
cd /Users/hongtaegyu/IdeaProjects/parut-v2/notification-service
mkdir -p test-results
```

전체 인프라와 서비스를 실행한다.

```bash
cd /Users/hongtaegyu/IdeaProjects/parut-v2
docker compose up -d
docker compose ps
```

notification-service 코드나 Micrometer 설정을 변경했다면 이미지를 다시 빌드한다.

```bash
docker compose up -d --build notification-service
```

DB 접속 URL:

```text
postgresql://parut:parut123@localhost:5433/parut
```

주요 테스트 파일:

| 파일 | 용도 |
|---|---|
| `data/subscription-concurrency-seed.sql` | 구독 동시성 데이터 초기화 |
| `jmeter/subscription-concurrency-test.jmx` | 구독 동시성 시나리오 |
| `data/kafka-fanout-subscription-seed.sql` | Fan-out 정합성 구독자 생성 |
| `data/kafka-events.jsonl` | Fan-out 정합성 Kafka 이벤트 |
| `data/kafka-fanout-verify.sql` | Fan-out 정합성 검증 |
| `data/kafka-fanout-load-seed.sql` | Load/Spike 구독자 생성 |
| `data/kafka-load-events.csv` | Load/Spike 이벤트 목록 |
| `data/kafka-fanout-load-verify.sql` | Load 결과 검증 |
| `data/kafka-fanout-scenario-verify.sql` | Spike 결과 검증 |
| `jmeter/kafka-fanout-load-test.jmx` | Fan-out Load 시나리오 |
| `jmeter/kafka-fanout-spike-test.jmx` | Fan-out Spike 시나리오 |
| `jmeter/kafka-fanout-stress-test.jmx` | 단일 인기 타임딜 Fan-out Stress 시나리오 |
| `LOAD_SPIKE_RESULT_TEMPLATE.md` | 3회 반복 결과와 판정을 기록하는 템플릿 |

## 1. Concurrency Test

`performance-test/jmeter/subscription-concurrency-test.jmx`

- 요청 수: 100회
- Threads: 100
- Ramp-up: 1초
- 요청 조건: 동일 `userId`, 동일 `timeDealId`
- 목적: 동시 요청에도 active 구독이 1건만 유지되는지 확인

요청 대상:

`POST http://localhost:8084/api/v1/notification-subscriptions/time-deals`

실행 예시:

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -f performance-test/data/subscription-concurrency-seed.sql

jmeter -n -t performance-test/jmeter/subscription-concurrency-test.jmx \
  -JnotificationPort=8084 \
  -JuserRole=CUSTOMER \
  -JuserId=90000000-0000-4000-8000-000000000001 \
  -JtimeDealId=91000000-0000-4000-8000-000000000001 \
  -l test-results/subscription-concurrency.jtl \
  -j test-results/subscription-concurrency.log
```

실행 결과:

```text
test-results/subscription-concurrency.jtl
test-results/subscription-concurrency.log
```

응답 코드 확인:

```bash
awk -F',' 'NR > 1 {count[$4]++} END {for (code in count) print code, count[code]}' \
  test-results/subscription-concurrency.jtl
```

DB 정합성 확인:

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -c "select count(*) as total_rows,
             count(*) filter (where deleted_at is null) as active_rows
      from notification_schema.p_time_deal_notification_subscriptions
      where user_id = '90000000-0000-4000-8000-000000000001'
        and time_deal_id = '91000000-0000-4000-8000-000000000001';"
```

확인 기준:

- active 구독 1건
- 서버 5xx 0건
- deadlock과 lock timeout 0건

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/subscription-concurrency.jtl \
  -o test-results/subscription-concurrency-report
```

## 2. Kafka Fan-out Correctness Test

Kafka 이벤트 발행 시 active 구독자 수만큼 알림이 생성되고, 동일한 `eventId`가
재발행되어도 중복 알림이 생기지 않는지 확인한다.

| 구분 | 이벤트 수 | 이벤트당 구독자 | 예상 알림 |
|---|---:|---:|---:|
| Medium | 1 | 1,000 | 1,000 |
| Large | 1 | 10,000 | 10,000 |
| Multiple Event | 20 | 2,000 | 40,000 |

대상:

- Kafka topic: `time-deal.opening-soon`
- Consumer group: `notification-time-deal-opening-soon`
- 결과 테이블: `notification_schema.p_notifications`

실행 예시:

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -f performance-test/data/kafka-fanout-subscription-seed.sql

docker exec -i kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic time-deal.opening-soon \
  < performance-test/data/kafka-events.jsonl
```

Large 이벤트 중복 발행:

```bash
grep '96000000-0000-4000-8000-000000010000' \
  performance-test/data/kafka-events.jsonl | \
docker exec -i kafka /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic time-deal.opening-soon
```

결과 확인:

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -f performance-test/data/kafka-fanout-verify.sql
```

확인 기준:

- 이벤트별 예상 알림 수와 실제 알림 수가 동일
- `(event_id, user_id)` 중복 row 0건
- 동일 `eventId` 재발행으로 생성된 신규 알림 0건
- Kafka lag 최종 0
- Consumer와 DB 오류 0건

## 3. Kafka Fan-out Load Test

### 시나리오와 목적

타임딜 알림 이벤트가 일정 시간 동안 계속 유입되는 상황을 가정한다. 이벤트마다 서로 다른
10,000명의 구독자를 준비하고, 이벤트를 5초 간격으로 약 5분 동안 발행한다. 이 테스트는
운영 중 타임딜 60개가 동시에 존재하는 상황을 재현하는 것이 아니라, 기준 입력률을 일정
시간 유지했을 때 lag, Fan-out 지연과 자원 사용량이 계속 증가하는지 확인한다.

설정값은 다음 순서로 결정했다.

1. Spike와 구분되는 일정한 유입을 만들기 위한 초기 발행 간격을 5초로 설정한다.
2. 짧은 실행으로 확인하기 어려운 lag·처리시간·자원 사용량의 누적 추세를 보기 위해 관찰
   시간을 약 5분으로 설정한다.
3. 약 300초 동안 5초 간격을 유지하는 데 필요한 합성 이벤트 수를 60건으로 계산한다
   (`300초 / 5초 = 60건`).

5초 간격과 약 5분의 관찰 시간은 운영 통계나 사용자 알림 SLA에서 도출한 값이 아니라 최초
기준선을 확보하기 위한 초기 엔지니어링 조건이다. 60건은 이 조건으로부터 계산된 테스트
데이터 수이며 실제 운영 타임딜 개수에 대한 추정치가 아니다.

| 항목 | 설정 |
|---|---:|
| 이벤트 발행 간격 | 5초 |
| Kafka 이벤트 입력률 | 약 0.2 event/s(`1 / 5초`) |
| 관찰 시간 | 약 5분 |
| 이벤트 | 60건(`300초 / 5초`, 지속성 관찰을 위한 합성 이벤트) |
| 이벤트당 구독자 | 10,000명 |
| 예상 알림 | 600,000건 |
| 환산 입력 작업량 | 평균 2,000 notifications/s(`0.2 event/s * 10,000명`) |
| 발행 구간 | 약 295초(첫 발행부터 마지막 발행까지) |
| 반복 | 독립 3회 |

### 성공 기준과 측정값

다음 항목은 테스트 전에 고정하는 성공 기준이다.

- 이벤트 60건 발행 성공, 발행 오류 0건
- 이벤트별 알림 10,000건, 전체 알림 600,000건
- 누락·중복·Consumer 오류·DB 오류 0건
- 관측 구간에서 Kafka lag가 지속적으로 우상향하지 않음
- 테스트 종료 후 Kafka lag 0, Hikari pending·timeout 0
- Fan-out/DB Flush 지연과 Heap·DB 메모리가 실행 내내 계속 악화하지 않고 종료 후 안정 구간으로 복귀

Fan-out Average/P95/P99/Max, DB Flush, Created-at Window Notification Rate, CPU·메모리와
GC는 기준선 수립을 위한 측정값이다. 최초 3회 결과의 Median과 최악값을 기준으로 성능
목표를 확정한 뒤 동일 조건으로 재검증한다. 이 테스트는 약 5분간의 지속 처리 안정성을
확인하며 최대 처리량이나 장시간 Soak 안정성을 입증하지 않는다. 환산 입력 작업량은 발행
조건을 설명하기 위한 값이며 실제 DB Notification TPS가 아니다. 실제 처리 성능은 Fan-out
시간, DB Flush, Kafka lag와 정합성 결과를 함께 사용해 판단한다.

### 실행 순서

1. Kafka lag가 0인지 확인한다.
2. Seed SQL로 이벤트 60개와 이벤트별 구독자 10,000명을 생성한다.
3. Kafka lag, 컨테이너 자원과 Grafana 모니터링을 시작한다.
4. JMeter를 실행한다.
5. 마지막 이벤트 처리 후 lag가 0이 될 때까지 모니터링한다.
6. 검증 SQL과 로그를 확인한다.
7. Seed부터 다시 시작해 총 3회 실행한다.

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -v event_count=60 \
  -v subscriber_count=10000 \
  -f performance-test/data/kafka-fanout-load-seed.sql

jmeter -n -f \
  -Jsearch_paths=/Users/hongtaegyu/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar \
  -t performance-test/jmeter/kafka-fanout-load-test.jmx \
  -JbootstrapServers=localhost:9092 \
  -Jtopic=time-deal.opening-soon \
  -JeventCsv=performance-test/data/kafka-load-events.csv \
  -JeventCount=60 \
  -JeventsPerMinute=12 \
  -Jthreads=1 \
  -JrampUp=1 \
  -l test-results/kafka-fanout-load-run-1.jtl \
  -j test-results/kafka-fanout-load-run-1.log
```

JMeter 결과의 `Kafka opening-soon 이벤트 발행`은 Kafka broker가 발행을 승인할 때까지의
시간이다. 알림 생성 완료시간으로 해석하지 않는다.

```bash
awk -F',' 'NR > 1 && $3 == "Kafka opening-soon 이벤트 발행" {
  count[$4]++
} END {
  for (code in count) print code, count[code]
}' test-results/kafka-fanout-load-run-1.jtl

sed -n 's/.*producerAckEpochMs=\([0-9][0-9]*\).*/\1/p' \
  test-results/kafka-fanout-load-run-1.jtl | sort -n | \
awk 'NR == 1 { first = $1 } { last = $1; count++ } END {
  span = (last - first) / 1000
  rate = span > 0 ? count / span : 0
  printf "producer_ack_count=%d, producer_ack_span_seconds=%.3f, kafka_event_rate=%.3f event/s\n", count, span, rate
}'

psql "postgresql://parut:parut123@localhost:5433/parut" \
  -v event_count=60 \
  -v subscriber_count=10000 \
  -f performance-test/data/kafka-fanout-load-verify.sql
```

`notification_created_at_span_seconds`는 첫 알림과 마지막 알림 row의 `created_at` 차이다.
이벤트 발행부터 마지막 트랜잭션 완료까지의 E2E 시간이 아니므로 `알림 생성 E2E`로
표기하지 않는다. `created_at_window_notification_rate`는
`생성 알림 수 / created_at 범위(초)`이며 Load에서는 이벤트 사이의 5초 대기시간까지
포함한다. Commit 처리율이나 순간 DB 처리용량을 뜻하지 않으므로 TPS로 표기하지 않는다.

## 4. Kafka Fan-out Spike Test

### 시나리오와 목적

타임딜 오픈 시각이 겹쳐 10건 또는 20건의 알림 이벤트가 1초 안에 몰리는 상황을
가정한다. 순간 유입으로 쌓인 Kafka lag의 크기, 회복시간, 처리시간과 자원 포화 여부를
확인한다. 10건과 20건은 실제 운영 최대 타임딜 개수의 추정치가 아니라 Burst에 대한
반응과 작업량 증가 추세를 비교하기 위한 탐색 단계다.

Spike 10은 순간 유입에 대한 기준선이며, Spike 20은 이벤트 수와 총 Fan-out 작업량을
2배로 증가시켜 lag와 처리시간의 증가 추세를 확인하는 피크 시나리오다. Load Test는
60건을 약 5분간 분산 발행하므로 Spike 10·20과 총 작업량이 다르다. 따라서 Load와
Spike 결과를 발행 패턴만의 차이로 직접 비교하지 않고, 각 테스트의 목적에 따라 별도로
판정한다. 10건과 20건은 운영 트래픽 통계로 확정한 최대치가 아니라, Burst에 대한 반응을
탐색하기 위한 초기 엔지니어링 부하 기준이다.

| 단계 | 이벤트 | Ramp-up | 이벤트당 구독자 | 예상 알림 | 반복 |
|---|---:|---:|---:|---:|---:|
| Spike 10 | 10건 | 1초 | 10,000명 | 100,000건 | 3회 |
| Spike 20 | 20건 | 1초 | 10,000명 | 200,000건 | 3회 |

Spike Test는 Throughput Timer를 사용하지 않는다. JMeter Thread 하나가 이벤트 하나를
발행하며, SetUp Thread Group이 Kafka Producer를 먼저 생성한다.

### 성공 기준과 측정값

다음 항목은 두 단계에 공통으로 적용한다.

- 모든 이벤트 발행 성공, 발행 오류 0건
- 이벤트별 알림 10,000건, 전체 예상 알림과 실제 알림 일치
- 누락·중복·Consumer 오류·DB 오류·OOM 0건
- 발행 종료 후 lag가 계속 감소하고 최종 0으로 회복
- Hikari pending·timeout 0, Heap과 DB 메모리가 안정 구간으로 복귀

실제 Producer 승인 구간, 최대 lag, lag 0 회복시간, Fan-out Average/P95/P99/Max,
DB Flush Average/P95/P99/Max, CPU·메모리와 GC는 3회 측정해 Median과 최악값을 기록한다.
Spike 10을 기준선으로 삼고 Spike 20에서 증가율을 비교한다. 업무 SLA가 정해지지 않은
상태에서는 임의의 초 단위를 합격 기준으로 만들지 않고, 이 기준선과 타임딜 스케줄
여유시간을 바탕으로 후속 목표를 확정한다.

테스트 전 `kafka-consumer-groups.sh --describe --group notification-time-deal-opening-soon`으로
실제 Consumer 수와 partition 할당을 결과에 기록한다. Topic partition 수만으로 동시에
처리되는 Consumer 수를 추정하지 않는다.

### 실행 순서

Spike 10과 Spike 20은 서로 독립적으로 실행한다. 한 단계가 끝나면 lag 0과 자원 회복을
확인한 뒤 Seed SQL을 다시 실행한다.

```bash
# Spike 10: run-1
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -v event_count=10 \
  -v subscriber_count=10000 \
  -f performance-test/data/kafka-fanout-load-seed.sql

jmeter -n -f \
  -Jsearch_paths=/Users/hongtaegyu/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar \
  -t performance-test/jmeter/kafka-fanout-spike-test.jmx \
  -JbootstrapServers=localhost:9092 \
  -Jtopic=time-deal.opening-soon \
  -JeventCsv=performance-test/data/kafka-load-events.csv \
  -JeventCount=10 \
  -JrampUp=1 \
  -l test-results/kafka-fanout-spike-10-run-1.jtl \
  -j test-results/kafka-fanout-spike-10-run-1.log
```

Spike 20은 Seed와 JMeter의 `event_count`/`eventCount`를 20으로, 결과 파일명을
`spike-20-run-1`로 변경한다. `run-2`, `run-3`도 항상 Seed부터 다시 실행한다.

```bash
awk -F',' 'NR > 1 && $3 == "Kafka opening-soon Spike 이벤트 발행" {
  count[$4]++
} END {
  for (code in count) print code, count[code]
}' test-results/kafka-fanout-spike-10-run-1.jtl

psql "postgresql://parut:parut123@localhost:5433/parut" \
  -v event_count=10 \
  -v subscriber_count=10000 \
  -f performance-test/data/kafka-fanout-scenario-verify.sql
```

### 공통 모니터링

JMeter 실행 전 별도 터미널에서 시작하고, lag가 0으로 회복된 후 중단한다. 파일명은
`load-run-1`, `spike-10-run-1`, `spike-20-run-1`처럼 시나리오와 반복 번호를 남긴다.

```bash
SCENARIO=spike-10-run-1

while true; do
  TEST_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  TEST_LAG=$(docker exec kafka \
    /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --describe \
    --group notification-time-deal-opening-soon 2>/dev/null | \
    awk 'NR > 1 && $6 ~ /^[0-9]+$/ {sum += $6; found=1}
         END {if (found) print sum; else print "NA"}')
  echo "${TEST_TIME},${TEST_LAG}"
  sleep 1
done | tee "test-results/kafka-lag-${SCENARIO}.csv"
```

`kafka-consumer-groups.sh` 실행 자체에 시간이 걸리므로 CSV 간격은 정확히 1초가 아닐 수
있다. 최대 lag와 회복시간은 샘플 간격만큼 오차가 있는 근사값으로 기록한다.

```bash
SCENARIO=spike-10-run-1

while true; do
  TEST_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  docker stats --no-stream \
    --format "${TEST_TIME},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.BlockIO}}" \
    postgres notification-service
  sleep 1
done | tee "test-results/container-stats-${SCENARIO}.csv"
```

## 5. Kafka Fan-out Stress Test

### 목적과 진행 근거

Stress Test는 **인기 타임딜 1건의 구독자 수가 증가할 때 정합성을 유지할 수 있는 검증
범위와, 알림 Fan-out 성능이 급격히 저하되기 시작하는 지점**을 찾는 것이 목적이다. 단순히
많은 알림을 생성하는 테스트가 아니라, 하나의 이벤트가 만드는 작업량만 단계적으로 높여
성능 변화의 원인을 분리한다.

#### 기존 테스트에서 확인한 범위

Load와 Spike는 이벤트당 구독자 수를 10,000명으로 고정하고 이벤트의 유입 패턴을 변경했다.
저장된 3회 검증 결과는 모두 예상 알림 수와 실제 알림 수가 일치했고 누락과 예상하지 않은
알림이 없었다. Kafka Lag 결과는 다음과 같다.

| 테스트 | 작업량 | 3회 최대 Lag | 3회 최종 Lag | 확인한 내용 |
|---|---:|---:|---:|---|
| Load | `60건 x 10K = 600K` | 모두 1 | 모두 0 | 5초 간격의 약 5분 지속 유입을 처리하고 회복 |
| Spike 10 | `10건 x 10K = 100K` | 7, 9, 10 | 모두 0 | 10건 동시 유입의 적체와 회복 |
| Spike 20 | `20건 x 10K = 200K` | 19, 18, 17 | 모두 0 | 더 큰 동시 유입에서 증가한 적체와 회복 |

따라서 현재 결과로는 **이벤트당 10,000명 조건에서 지속 유입과 10·20건 Burst를 정합성
오류 없이 처리했다**고 말할 수 있다. 반면 다음 항목은 아직 확인하지 못했다.

- 인기 타임딜 한 건에 30K, 50K 이상이 구독했을 때의 처리시간과 정합성
- 하나의 트랜잭션이 처리할 수 있는 구독자 수의 검증 범위
- 구독자 수 증가에 따른 Fan-out 시간과 구독자당 처리 비용 변화
- 대량 조회, 알림 객체 생성, 영속성 컨텍스트와 DB Flush의 증가 양상
- 단일 대형 Fan-out에서 Heap, GC, HikariCP 및 PostgreSQL에 나타나는 한계 징후

#### `20건 x 10K`와 `1건 x 200K`가 다른 이유

두 조건은 총 알림 수가 같더라도 처리 구조가 다르다.

| `20건 x 10K` | `1건 x 200K` |
|---|---|
| 여러 Consumer 처리와 여러 트랜잭션으로 분리될 수 있음 | 하나의 Consumer 처리와 하나의 큰 트랜잭션에 집중됨 |
| 이벤트별 조회 결과와 객체 컬렉션이 상대적으로 작음 | 한 번에 조회·생성·보관하는 객체 수가 큼 |
| 이벤트별 Flush와 Commit으로 작업이 나뉨 | 대량 SQL Batch, Flush와 Commit 비용이 한 번에 집중됨 |
| 일부 이벤트가 느려도 다른 이벤트와 표본이 분리됨 | 실패 시 해당 인기 타임딜 알림 전체가 롤백될 수 있음 |

현재 대표 Grafana 캡처에서는 DB Flush가 Fan-out 단계 중 가장 큰 비중을 차지했다. 이것만으로
PostgreSQL 내부 병목을 확정할 수는 없지만, 단일 이벤트의 구독자 수가 증가할 때 Flush와
전체 트랜잭션 시간이 선형적으로 증가하는지 확인해야 할 근거는 된다.

#### 이 Stress Test에서 결정할 것

이벤트 수를 1건으로 고정하고 구독자 수만 늘리는 **Single Event Fan-out Size Stress
Test**를 통해 다음 결과를 얻는다.

1. **정합성 검증 범위**: 누락·중복·롤백 없이 처리한 최대 실측 구독자 수
2. **성능 저하 시작점**: Fan-out 시간이 구독자 증가율보다 빠르게 증가하거나 실효 처리율이 연속으로 감소하는 구간
3. **병목 후보**: Subscriber Lookup, Existing Lookup, Build, Save, DB Flush 중 증가 폭이 가장 큰 단계
4. **자원 한계 징후**: Heap/Old Gen 미회복, GC Pause 급증, Hikari 대기, PostgreSQL CPU 지속 포화 여부
5. **운영 안전 범위의 근거**: 최초 저하·실패 단계보다 낮고 반복 실행에서도 안정적인 구독자 범위

이 테스트는 처음부터 이론적인 최대치를 증명하거나 임의의 TPS 목표를 통과시키는 시험이
아니다. 단계별 탐색으로 최초 저하 구간을 찾고, 해당 구간과 직전 정상 구간을 반복해 재현성을
확인한다. 특정 단계가 성공하면 **“해당 구독자 수까지 현재 환경에서 검증됨”**으로 기록한다.
사용자 기기까지의 알림 전달시간과 여러 인기 타임딜의 동시 유입은 각각 별도 E2E Test와
필요 시 추가하는 복합 Stress Test의 범위다.

### 단계별 시나리오

| 단계 | 이벤트 수 | 이벤트당 구독자 수 | 예상 알림 수 | 목적 |
|---|---:|---:|---:|---|
| 기준선 | 1건 | 10,000명 | 10,000건 | 기존 조건의 단일 이벤트 기준값 확보 |
| 1단계 | 1건 | 30,000명 | 30,000건 | 조회·생성·저장 비용 증가 확인 |
| 2단계 | 1건 | 50,000명 | 50,000건 | 처리율 저하와 자원 압박 확인 |
| 3단계 | 1건 | 75,000명 | 75,000건 | 성능 저하 지점 탐색 |
| 4단계 | 1건 | 100,000명 | 100,000건 | 대규모 인기 타임딜 처리 가능 범위 확인 |
| 조건부 확장 | 1건 | 150,000명 → 200,000명 | 동일 | 실제 한계 탐색이 필요할 때만 수행 |

위 구독자 수는 실제 인기 타임딜의 최대치를 단정한 값이 아니라 성능 변화 지점을 찾기 위한
탐색 구간이다. 100,000명 조건이 성공하더라도 결과는 **“100,000명까지 검증됨”**으로
기록하며 시스템의 최대 한계라고 표현하지 않는다.

### 데이터 준비 원칙

각 단계는 이전 실행의 영향을 받지 않도록 독립적으로 준비한다.

1. 운영 데이터와 겹치지 않는 테스트 전용 `time_deal_id`와 이벤트 UUID 대역을 사용한다.
2. 목표 수만큼 서로 다른 활성 사용자와 구독 데이터를 생성한다.
3. Seed SQL로 전용 UUID 대역의 이전 알림·구독 데이터를 정리하고 다시 생성한다.
4. Kafka Consumer Lag이 0인지 확인한다.
5. 애플리케이션 재시작 여부, JVM 워밍업 여부 및 Docker 자원 조건을 모든 실행에서 동일하게 유지한다.
6. 이벤트 발행 전 Kafka Lag, 컨테이너 자원 사용량, Grafana 캡처 구간을 먼저 준비한다.

### 실행 예시: 30,000명 1회차

아래 예시에서 `SUBSCRIBER_COUNT`와 `SCENARIO`만 단계 및 회차에 맞게 변경한다.

```bash
cd notification-service

SUBSCRIBER_COUNT=30000
SCENARIO=stress-30k-run-1

psql "postgresql://parut:parut123@localhost:5433/parut" \
  -v subscriber_count="${SUBSCRIBER_COUNT}" \
  -v event_count=1 \
  -f performance-test/data/kafka-fanout-load-seed.sql
```

별도 터미널에서 위의 **공통 모니터링** 명령을 `SCENARIO=stress-30k-run-1`로 실행한 뒤
JMeter를 실행한다.

```bash
jmeter -n -f \
  -Jsearch_paths=/Users/hongtaegyu/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar \
  -t performance-test/jmeter/kafka-fanout-stress-test.jmx \
  -JbootstrapServers=localhost:9092 \
  -Jtopic=time-deal.opening-soon \
  -JeventCsv=performance-test/data/kafka-load-events.csv \
  -JeventCount=1 \
  -JrampUp=1 \
  -l "test-results/kafka-fanout-${SCENARIO}.jtl" \
  -j "test-results/kafka-fanout-${SCENARIO}.log"
```

Lag이 다시 0이 되고 Fan-out 처리가 끝난 후 정합성과 `created_at` 기반 보조 처리율을
파일로 저장한다.

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -v subscriber_count="${SUBSCRIBER_COUNT}" \
  -v event_count=1 \
  -f performance-test/data/kafka-fanout-scenario-verify.sql \
  | tee "test-results/kafka-fanout-${SCENARIO}-verification.txt"
```

### 측정 지표

| 구분 | 측정 항목 | 해석 |
|---|---|---|
| 정합성 | 예상/실제 알림 수, 누락, 중복 | 하나라도 불일치하면 해당 단계 실패 |
| 완료 시간 | `notification.fanout.total` | 트랜잭션 완료 후 기록되는 실제 Fan-out 시간 |
| 실효 처리율 | 실제 생성 알림 수 ÷ Fan-out 완료 시간 | 해당 이벤트의 트랜잭션 완료 기준 처리량 |
| 보조 처리율 | `created_at` 범위 기반 Notification Rate | INSERT 시간 분포 비교용이며 Commit TPS가 아님 |
| 단계별 시간 | Subscriber Lookup, Existing Lookup, Build, Save, DB Flush | 구독자 수 증가 시 크게 증가하는 단계 확인 |
| Kafka | 최대 Lag, Lag 0 회복 여부 | 소비 적체와 최종 회복 여부 확인 |
| JVM | Heap, Old Gen, GC 횟수와 Pause | 메모리 압박과 회수 가능 여부 확인 |
| DB 연결 | Active, Idle, Pending, Timeout | 커넥션 풀 대기 또는 고갈 여부 확인 |
| 시스템 | 애플리케이션/PostgreSQL CPU·메모리 | 병목 후보와 자원 포화 징후 확인 |
| 오류 | 예외, 롤백, OOM, DB 오류 | 처리 실패 여부 확인 |

단일 이벤트 단계에는 Fan-out Timer 표본이 1개뿐이므로 P95/P99는 한계 판단의 주 지표로
사용하지 않는다. `Fan-out Total`, `DB Flush`, 실효 처리율, 정합성 및 자원 사용량을 우선
비교한다.

### 판정 기준

다음 중 하나라도 발생하면 해당 단계는 **명확한 실패 조건**으로 기록하고 상위 부하 실행을
중단한다.

- 실제 알림 수 불일치, 누락 또는 중복 발생
- 트랜잭션 롤백, OOM, DB 오류 또는 애플리케이션 중단
- HikariCP Pending/Timeout 발생
- 처리가 끝난 뒤에도 Kafka Lag이 0으로 회복되지 않음

다음 현상은 즉시 실패로 단정하지 않고 **성능 저하 후보**로 기록한 뒤 인접 단계를 반복
측정한다.

- 구독자 증가 비율보다 Fan-out 시간이 더 빠르게 증가
- 구독자당 처리 시간이 연속 단계에서 증가
- 실효 처리율이 연속 단계에서 감소
- DB Flush 시간 또는 전체 시간 대비 Flush 비중이 크게 증가
- Old Gen이 실행 후 회복되지 않거나 GC Pause가 급증
- PostgreSQL CPU가 처리 구간 동안 지속적으로 높은 상태를 유지

요구사항으로 합의되지 않은 임의의 TPS나 완료 시간은 공식 실패 기준으로 사용하지 않는다.
최초 성능 저하 구간은 절대 수치뿐 아니라 이전 단계 대비 증가율로 판단한다.

### 반복 및 후속 테스트

1. `10K → 30K → 50K → 75K → 100K`를 먼저 각 1회 탐색한다.
2. 최초 성능 저하 또는 오류가 발견된 단계와 바로 이전 정상 단계를 각각 3회 반복한다.
3. 100K까지 안정적이면 필요할 때만 150K, 200K로 확장한다.
4. 단일 이벤트의 안정 범위를 확인한 뒤, 실제로 여러 인기 타임딜이 동시에 열리는 요구사항이 있다면 안전 구간의 구독자 수로 `3건 x N명` 복합 Stress Test를 추가한다.

복합 Stress Test는 첫 단계가 아니다. 기존 Spike Test가 다중 이벤트 동시 유입을 이미
검증하므로 먼저 아직 검증하지 않은 단일 이벤트 Fan-out 크기의 한계를 확인한다.


## Grafana 모니터링

전용 대시보드:

```text
http://localhost:3000/d/kafka-fanout-performance/kafka-fan-out-performance
```

대시보드 파일:

```text
../infra/grafana/dashboards/Kafka Fan-out Performance.json
```

같은 Absolute time range로 다음 패널을 캡처한다.

- `Fan-out Total Duration`: Average, P95, P99
- `Fan-out Phase Average`: Subscriber Lookup, Existing Lookup, Build, Save, Flush
- `DB Flush Duration`: Average, P95, P99
- notification-service JVM CPU·Heap·GC
- Hikari Active·Pending·Timeout

Timer 의미:

| Timer | 측정 구간 |
|---|---|
| `notification.fanout.total` | 이벤트 1건의 전체 Fan-out 트랜잭션 처리시간 |
| `notification.fanout.subscriber.lookup` | active 구독자 조회시간 |
| `notification.fanout.existing.lookup` | 기존 알림 조회시간 |
| `notification.fanout.build` | 알림 객체 생성시간 |
| `notification.fanout.save` | JPA 영속성 컨텍스트 등록시간 |
| `notification.fanout.flush` | SQL Batch를 DB에 실행하는 시간 |

`save`가 짧고 `flush`가 길다면 객체 등록보다 실제 INSERT Batch 실행 구간의 비용이 큰 것으로
해석한다. flush만으로 INSERT, 인덱스, WAL, 디스크 I/O 중 정확한 원인까지 확정할 수는 없다.

현재 Prometheus에는 별도 데이터 볼륨이 없으므로 컨테이너를 제거하거나 재생성하면 과거
시계열이 사라질 수 있다. 캡처 전에는 `docker compose down`, `down -v`,
`up --force-recreate`를 실행하지 않는다. JTL, CSV와 SQL 결과도 별도로 보관한다.

## 측정 수치 정의

같은 TPS나 P95라도 측정 대상에 따라 의미가 다르다. 결과표에는 수치만 쓰지 않고 아래의
지표 이름과 단위를 함께 기록한다.

| 지표 | 계산·측정 대상 | 의미와 해석 |
|---|---|---|
| Kafka Event Rate | 발행 이벤트 수 / 첫 Producer 승인부터 마지막 Producer 승인까지의 구간(초) | JMeter가 Kafka에 이벤트를 발행한 실제 속도다. Load 설정값은 5초당 1건, 즉 약 0.2 event/s다. |
| JMeter Response Average/P95/P99 | Kafka `send().get()` 응답시간 | Broker가 발행을 승인하기까지 걸린 시간이다. 알림 생성시간이 아니다. |
| Created-at Window Notification Rate | 생성 알림 수 / 전체 `created_at` 범위(초) | DB row 타임스탬프 범위에서 계산한 참고 생성률이다. Commit TPS나 정확한 E2E 처리율이 아니다. |
| Transaction-complete Fan-out Throughput | 실제 생성 알림 수 / `notification.fanout.total`(초) | 단일 이벤트 Stress Test에서 트랜잭션 완료까지 포함한 실효 처리율이다. DB 엔진 자체 TPS와는 구분한다. |
| Fan-out Average | `notification.fanout.total`의 평균 | Consumer가 이벤트 한 건을 받아 트랜잭션을 마친 뒤 기록한 Fan-out 시간의 평균이다. |
| Fan-out P95 | `notification.fanout.total`의 95번째 백분위 | 이벤트 처리시간의 95%가 이 값 이하라는 뜻이다. 느린 상위 5%를 제외한 지연 수준을 본다. |
| Fan-out P99 | `notification.fanout.total`의 99번째 백분위 | 이벤트 처리시간의 99%가 이 값 이하라는 뜻이다. 꼬리 지연과 최악 구간에 더 민감하다. |
| DB Flush Average/P95/P99 | `notification.fanout.flush` | 영속성 컨텍스트의 변경을 SQL Batch로 DB에 반영하는 구간의 평균과 백분위다. 전체 Fan-out 시간과 별도로 본다. |
| Maximum Kafka Lag | 관측 구간의 lag 최댓값 | Consumer가 아직 처리하지 못하고 가장 많이 쌓였던 이벤트 수다. |
| Lag Recovery Time | 마지막 이벤트 발행부터 lag 0 관측까지 | Burst 이후 Consumer가 backlog를 모두 처리하는 데 걸린 시간이다. 수집 주기만큼 오차가 있을 수 있다. |
| Hikari Active/Pending/Timeout | Connection Pool 메트릭 | DB 연결 사용량, 연결 대기 수와 timeout 발생 여부다. Pending이나 Timeout이 발생하면 DB 연결 포화 가능성을 확인한다. |

예를 들어 `Fan-out P95 = 2초`는 전체 알림의 95%가 2초 안에 생성됐다는 의미가 아니다.
측정 단위는 **알림 row가 아니라 Kafka 이벤트 한 건의 Fan-out 처리시간**이다. 이벤트당
구독자가 10,000명이면 해당 이벤트가 만드는 10,000개 알림 묶음의 처리시간 표본 하나가
Timer에 기록된다.

Prometheus의 P95/P99는 Histogram bucket으로 계산한 근사값이다. Spike 10·20은 한 번의
실행에서 표본이 각각 10개·20개뿐이므로 P95/P99가 Max에 가까워지고 변동성이 크다. 따라서
3회 반복 결과의 P95/P99만 단독으로 판단하지 않고 Average, Max, 개별 Fan-out 시간과 lag
회복시간을 함께 기록한다.

Grafana 범례의 `Mean`과 `Max`는 선택한 시간 범위에서 계산된 **그래프 시계열 표본의 통계**다.
전체 이벤트 원본 표본의 평균·최댓값과 정확히 같다고 가정하지 않는다. 최종 이벤트 수와
알림 수는 JTL과 검증 SQL을 기준으로 판정한다.

JMeter 응답시간은 Kafka Producer의 이벤트 발행 승인시간이다. 이벤트 한 건의 Fan-out
처리시간은 Micrometer Timer로 판단한다. DB `created_at` 범위는 전체 시나리오가 알림 row를
만든 구간을 보여주지만, 정확한 발행-to-commit E2E 시간은 아니다.

각 Producer 응답 메시지에는 `producerAckEpochMs`가 포함된다. 첫 승인과 마지막 승인의
차이를 실제 발행 구간으로 기록한다. 이는 Broker 승인 시각이며 Consumer 처리 완료 시각은
아니다. 정확한 이벤트별 발행-to-commit E2E가 필요하면 별도의 eventId별 완료 시각 계측을
추가해야 한다.

현재 Load/Spike Test의 검증 범위는 Kafka 이벤트 발행 이후 알림 DB row 생성까지다.
타임딜 시작 10분 전에 스케줄러가 이벤트를 발행하는지와 사용자 기기까지 실제 알림이
전달되는지는 별도의 Scheduler/E2E 테스트로 검증한다.

실행 명령의 `-f`는 같은 경로에 남아 있는 JTL과 Report를 실행 전에 삭제해 이전 샘플이
이어 붙는 것을 방지한다. 결과를 보존하려면 `run-2`처럼 매 실행마다 다른 이름을 사용한다.

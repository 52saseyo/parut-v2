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
- Load와 Spike Test는 이벤트 1건당 active 구독자 10,000명을 준비한다.
- Load Test는 이벤트 100건을 약 1건/초로 발행한다.
- Spike Test는 이벤트 50건 또는 100건을 1초 안에 집중 발행한다.
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

`performance-test/jmeter/kafka-fanout-load-test.jmx`

- 이벤트 수: 100건
- 이벤트당 구독자: 10,000명
- 예상 알림: 1,000,000건
- Threads: 1
- 발행 속도: 60 events/minute, 약 1 event/sec
- 예상 발행 시간: 약 100초
- 목적: 목표 부하를 유지할 때 정합성, 처리시간, lag와 자원 안정성 확인

`약 10,000 notifications/sec`는 `1 event/sec * 10,000 subscribers`로 계산한 목표
부하다. 실제 알림 TPS는 생성된 알림 수를 DB 생성 시간으로 나눠 별도 계산한다.

### 모니터링 준비

테스트 전에 별도 터미널에서 Kafka lag를 기록한다.

```bash
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
done | tee test-results/kafka-lag-load-final.csv
```

다른 터미널에서 컨테이너 자원을 기록한다.

```bash
while true; do
  TEST_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  docker stats --no-stream \
    --format "${TEST_TIME},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.BlockIO}}" \
    postgres notification-service
  sleep 1
done | tee test-results/container-stats-load-final.csv
```

모니터링은 JMeter 종료 직후 중단하지 않고 Kafka lag가 0으로 회복된 후 종료한다.

### 실행

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -f performance-test/data/kafka-fanout-load-seed.sql

jmeter -n \
  -Jsearch_paths=/Users/hongtaegyu/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar \
  -t performance-test/jmeter/kafka-fanout-load-test.jmx \
  -JbootstrapServers=localhost:9092 \
  -Jtopic=time-deal.opening-soon \
  -JeventCsv=performance-test/data/kafka-load-events.csv \
  -JeventCount=100 \
  -Jthreads=1 \
  -JrampUp=1 \
  -l test-results/kafka-fanout-load-final.jtl \
  -j test-results/kafka-fanout-load-final.log
```

실행 결과:

```text
test-results/kafka-fanout-load-final.jtl
test-results/kafka-fanout-load-final.log
test-results/kafka-lag-load-final.csv
test-results/container-stats-load-final.csv
```

JMeter 콘솔에는 Producer 종료 샘플을 포함해 101건이 표시될 수 있다. 실제 Kafka 이벤트
발행 건수는 `Kafka opening-soon 이벤트 발행` 샘플 100건이다.

```bash
awk -F',' 'NR > 1 && $3 == "Kafka opening-soon 이벤트 발행" {
  count[$4]++
} END {
  for (code in count) print code, count[code]
}' test-results/kafka-fanout-load-final.jtl
```

DB 결과 확인:

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -f performance-test/data/kafka-fanout-load-verify.sql
```

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/kafka-fanout-load-final.jtl \
  -o test-results/kafka-fanout-load-final-report
```

확인 항목:

- Kafka 이벤트 발행 성공 수와 오류율
- 예상 알림 1,000,000건과 실제 알림 수
- 누락과 중복 알림 여부
- 알림 생성 시작·종료 시각과 notification TPS
- 최대 Kafka lag와 lag 0 회복 시간
- Fan-out Average/P95/P99/Max
- 구독자 조회, 기존 알림 조회, 객체 생성, save, flush 처리시간
- PostgreSQL과 notification-service CPU·메모리
- JVM Heap·GC와 Hikari active·pending·timeout

## 4. Kafka Fan-out Spike Test

`performance-test/jmeter/kafka-fanout-spike-test.jmx`

Spike Test는 Throughput Timer 없이 각 Thread가 이벤트를 한 건씩 발행한다. SetUp Thread
Group에서 Kafka Producer를 먼저 생성한다.

| 단계 | Threads | Ramp-up | 이벤트당 구독자 | 예상 알림 |
|---|---:|---:|---:|---:|
| Spike 50 | 50 | 1초 | 10,000 | 500,000 |
| Spike 100 | 100 | 1초 | 10,000 | 1,000,000 |

목적:

- 이벤트 집중 시 최대 Kafka lag 확인
- 이벤트 발행 종료 후 lag가 0으로 회복되는 시간 확인
- Burst 상황의 Fan-out 처리시간과 DB flush 지연 확인
- 오류, OOM, Hikari pending·timeout과 자원 포화 여부 확인

### 모니터링 준비

Load Test의 Kafka lag와 컨테이너 자원 측정 명령을 그대로 사용하고 출력 파일명만 실행
단계에 맞게 변경한다.

```text
test-results/kafka-lag-spike-50.csv
test-results/container-stats-spike-50.csv
test-results/kafka-lag-spike-100.csv
test-results/container-stats-spike-100.csv
```

### Spike 50 실행

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -f performance-test/data/kafka-fanout-load-seed.sql

jmeter -n \
  -Jsearch_paths=/Users/hongtaegyu/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar \
  -t performance-test/jmeter/kafka-fanout-spike-test.jmx \
  -JbootstrapServers=localhost:9092 \
  -Jtopic=time-deal.opening-soon \
  -JeventCsv=performance-test/data/kafka-load-events.csv \
  -JeventCount=50 \
  -JrampUp=1 \
  -l test-results/kafka-fanout-spike-50.jtl \
  -j test-results/kafka-fanout-spike-50.log
```

### Spike 100 실행

Spike 50의 lag가 0으로 회복된 후 Seed SQL을 다시 실행한다.

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -f performance-test/data/kafka-fanout-load-seed.sql

jmeter -n \
  -Jsearch_paths=/Users/hongtaegyu/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar \
  -t performance-test/jmeter/kafka-fanout-spike-test.jmx \
  -JbootstrapServers=localhost:9092 \
  -Jtopic=time-deal.opening-soon \
  -JeventCsv=performance-test/data/kafka-load-events.csv \
  -JeventCount=100 \
  -JrampUp=1 \
  -l test-results/kafka-fanout-spike-100.jtl \
  -j test-results/kafka-fanout-spike-100.log
```

발행 성공 수 확인:

```bash
awk -F',' 'NR > 1 && $3 == "Kafka opening-soon Spike 이벤트 발행" {
  count[$4]++
} END {
  for (code in count) print code, count[code]
}' test-results/kafka-fanout-spike-50.jtl
```

DB 결과 확인:

```bash
psql "postgresql://parut:parut123@localhost:5433/parut" \
  -v event_count=50 \
  -f performance-test/data/kafka-fanout-scenario-verify.sql
```

Spike 100은 JTL 파일명과 `event_count`를 100으로 변경한다.

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/kafka-fanout-spike-50.jtl \
  -o test-results/kafka-fanout-spike-50-report

jmeter -g test-results/kafka-fanout-spike-100.jtl \
  -o test-results/kafka-fanout-spike-100-report
```

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

Grafana 범례의 `Mean`과 `Max`는 선택한 시간 범위의 시계열 표본 통계다. 정확한 이벤트와
알림 개수는 JMeter와 DB 검증 SQL을 기준으로 판단한다.

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

## 결과 해석 기준

- Kafka event TPS: 초당 발행하거나 처리한 이벤트 수
- Notification TPS: DB에 생성된 알림 수를 알림 생성 시간으로 나눈 평균 처리량
- Fan-out Average: Consumer가 이벤트 한 건의 알림을 생성하는 평균 시간
- Kafka lag: 아직 Consumer가 처리하지 못한 이벤트 수
- Lag 회복 시간: 이벤트 발행 종료 후 lag가 0이 될 때까지 걸린 시간

JMeter 응답시간은 Kafka Producer의 이벤트 발행시간이다. 실제 알림 생성시간은 Micrometer
Fan-out Timer와 DB 생성 시각으로 판단한다.

현재 Load/Spike Test의 검증 범위는 Kafka 이벤트 발행 이후 알림 DB row 생성까지다.
타임딜 시작 10분 전에 스케줄러가 이벤트를 발행하는지와 사용자 기기까지 실제 알림이
전달되는지는 별도의 Scheduler/E2E 테스트로 검증한다.

JTL 파일이나 HTML Report 디렉터리가 이미 존재하면 JMeter가 덮어쓰지 않고 실패할 수 있다.
재실행 시 `run-2`처럼 다른 이름을 사용하거나 기존 결과를 보관한 뒤 실행한다.

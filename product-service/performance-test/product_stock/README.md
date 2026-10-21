# Product Stock Performance Test

일반 재고(주문 시 선점 → 결제 시 확정 → 취소 시 복구)의 동시성, 성능, 한계를 검증한다.

| 테스트 | 파일 | 확인하는 것 |
| --- | --- | --- |
| 1. Concurrency | `jmeter/concurrency-test.jmx` | 단일 상품 동시 선점 시 재고 정합성 |
| 2. UpdateStock Conflict | `jmeter/update-stock-conflict-test.jmx` | 재고 수정 동시 요청 시 버전 충돌 처리 |
| 3. Load | `jmeter/load-test.jmx` | 평상시 피크 부하에서 합격선 충족 여부 |
| 4. Spike | `jmeter/spike-test.jmx` | 이벤트로 갑자기 몰릴 때 버티는지, 끝난 뒤 회복하는지 |
| 5. Stress | `jmeter/stress-test.jmx` | 처리 한계와 병목 지점 |
| 6. 만료 스케줄러 대량 처리 | `data/product-stock-scheduler-*.sql` | 이벤트 때 쌓인 만료를 주기 안에 처리하는지, 이벤트 로그가 쌓이면 얼마나 느려지는지 |
| 7. 만료 스케줄러 간섭 | `data/product-stock-scheduler-interference-*.sql` + `jmeter/spike-test.jmx` | 주문 피크와 겹쳐도 주문이 느려지지 않고 만료도 실패하지 않는지 |

## 환경

- Java 21
- PostgreSQL
- JMeter 5.6.3
- 로컬 Docker 환경, product-service 단일 인스턴스 (JMeter는 같은 PC에서 실행)
- product-service 포트: `8082` (루트 `docker-compose.yml` 기준)

### 3~5번 측정 조건

- 로그 레벨 INFO (prod 프로필과 동일하게 Actuator로 변경)
  ```bash
  curl -X POST http://localhost:8082/actuator/loggers/org.hibernate.SQL -H "Content-Type: application/json" -d "{\"configuredLevel\":\"INFO\"}"
  ```
  `com.parut.product`, `org.hibernate.orm.jdbc.bind`도 같은 방식으로 변경한다. `docker restart product-service`로 원복된다.
- 테스트 DB만 `synchronous_commit = off`
  - 로컬 Docker 데이터가 HDD에 있어 커밋 시 디스크 기록(WAL fsync)이 1회 약 180ms 걸리고, 이 대기로 커넥션 풀이 고갈된다.
  - 디스크 영향을 빼고 애플리케이션 성능을 보기 위한 테스트 전용 설정이다. 운영에는 적용하지 않는다.
  ```bash
  docker exec postgres psql -U parut -d parut -c "ALTER DATABASE parut SET synchronous_commit = off"
  docker restart product-service

  # 테스트 후 원복
  docker exec postgres psql -U parut -d parut -c "ALTER DATABASE parut RESET synchronous_commit"
  docker restart product-service
  ```
- 예약 유효시간(TTL) 15분 (로컬 기본 5분)
  - reserve만 보내므로 모든 예약이 방치된다. 테스트 도중 만료 스케줄러가 끼어들지 않도록 TTL을 가장 긴 테스트(10분)보다 길게 잡는다.
  - `.env`의 `PRODUCT_STOCK_RESERVATION_TTL`을 `15m`으로 바꾸고 product-service 컨테이너를 다시 만든다. (`docker restart`는 `.env`를 다시 읽지 않는다. 저장소 루트에서 실행하고, 로그 레벨은 다시 INFO로 바꾼다)
  ```bash
  docker compose up -d product-service

  # 테스트 후 .env를 5m으로 되돌리고 같은 명령으로 원복
  ```

## 테스트 기준 (3~5번)

### 서비스 규모

실제 트래픽 데이터가 없으므로 서비스 규모를 가정했다. 신선식품 커머스는 타임딜이 있어도 티켓팅처럼 극단적으로 몰리지 않으므로 **하루 사용자(DAU) 10만 명**을 기준으로 한다.

| 단계 | 계산 | 결과 |
| --- | --- | ---: |
| 하루 주문 | 10만 명 × 구매 전환율 5% | 5,000건 |
| 저녁 피크 1시간 | 하루 주문의 20% | 1,000건 |
| 피크 1시간 평균 | 1,000 ÷ 3,600초 | 0.28 TPS |
| **평상시 피크** | 순간 몰림 10배 반영 | **3 TPS** |
| **이벤트 피크** | 타임딜·할인 오픈 시 평상시의 10배 | **30 TPS** |

- TPS는 **주문 기준**(초당 reserve 요청 수)이다.
- reserve만 보내므로 Grafana 처리량 패널(HTTP req/s)이 곧 reserve TPS다.

### 합격선

- reserve 응답 시간 **P95 200ms 이하** (100건 중 95건이 0.2초 안에 처리)
- **에러율 0%** (재고 부족 `PRODUCT_STOCK_SHORTAGE` 409는 정상 응답이므로 제외)
- **정합성 mismatch 0건** (테스트 후 재고 숫자와 예약 기록이 일치)

| 테스트 | 부하 | 확인할 것 |
| --- | --- | --- |
| Load | 3 TPS, 10분 | 평상시 피크에서 합격선 충족 |
| Spike | 3 TPS → 30 TPS(1분) → 3 TPS | 이벤트 피크에서 합격선 유지, 종료 후 회복 |
| Stress | 제한 없이 증가 | 합격선이 깨지는 처리량, 병목, 목표 대비 여유 배수 |

## 데이터 준비

모든 명령은 `product-service` 디렉터리에서 실행한다. JMeter 요청은 실제 DB 트랜잭션을 수행해 자동 롤백되지 않으므로, 테스트마다 seed를 다시 실행해 초기화한다. (seed는 실행 전에 이전 결과를 먼저 삭제한다.)

```bash
cd product-service
mkdir -p test-results/product_stock
```

| seed | 테스트 | 데이터 |
| --- | --- | --- |
| `data/product-stock-seed.sql` | 1, 2 | Concurrency 상품 `33333333-3333-4333-8333-333333333333` (재고 100개)<br>UpdateStock 상품 `44444444-4444-4444-8444-444444444444` / 판매자 `dddddddd-dddd-4ddd-8ddd-dddddddddddd` (재고 1,000개, 예약 없음) |
| `data/product-stock-load-seed.sql` | 3, 4, 5 | 분산 상품 200개 `66666666-6666-4666-8666-000000000001` ~ `...000000000200` (각 재고 100,000개, `data/load-products.csv`)<br>핫 상품 1개 `55555555-5555-4555-8555-555555555555` (재고 1,000,000개) |

```bash
docker exec -i postgres psql -U parut -d parut < performance-test/product_stock/data/product-stock-seed.sql
docker exec -i postgres psql -U parut -d parut < performance-test/product_stock/data/product-stock-load-seed.sql
```

3~5번은 재고를 넉넉하게 잡아 재고 부족 응답이 섞이지 않고 처리 성능만 관찰되도록 했다.

seed 실행 시 주의:

- 이전 테스트가 끝나면 verify 후 **바로** 실행한다. TTL(15분)이 지나 만료 스케줄러가 남은 예약을 처리하기 시작한 뒤에 실행하면 외래키 에러로 seed 전체가 롤백된다. 이미 만료가 시작됐다면 끝날 때까지 기다린다.
- Stress처럼 예약이 수십만 건 쌓인 뒤에는 seed가 매우 느려진다. (이벤트 로그 `reservation_id`에 인덱스가 없어 예약 삭제 1건마다 로그 전체를 확인한다.) 이벤트 로그를 먼저 지우고 정리한 뒤 seed를 실행한다. V152 인덱스 추가 후에는 이 정리가 필요 없다. ([6번](#6-만료-스케줄러-대량-처리-테스트) 참고)
  ```bash
  docker exec postgres psql -U parut -d parut -c "DELETE FROM product_schema.p_product_stock_event_logs WHERE reservation_id IN (SELECT id FROM product_schema.p_product_stock_reservations WHERE stock_id::text LIKE '77777777-7777-4777-8777-%' OR stock_id = '55555555-5555-4555-8555-555555555556')" -c "VACUUM ANALYZE product_schema.p_product_stock_event_logs"
  ```

## 1. Concurrency Test
`jmeter/concurrency-test.jmx`

- 초기 재고: 100개
- 요청당 수량: 1개
- Threads: 50
- Ramp-up: 5초
- Loop: 10회
- 총 요청 수: 500회

요청 대상:

`POST http://localhost:8082/api/v1/internal/stocks/reserve`

헤더:

- `Content-Type: application/json`
- `X-Service-Key: local-dev-key`

본문:

`{"orderId":"${__UUID()}","items":[{"productId":"${productId}","orderItemId":"${__UUID()}","quantity":1}]}`

실행 예시:

```bash
jmeter -n -t performance-test/product_stock/jmeter/concurrency-test.jmx -JproductId=33333333-3333-4333-8333-333333333333 -JproductPort=8082 -l test-results/product_stock/concurrency.jtl -j test-results/product_stock/concurrency.log
```

jmx 기본 포트는 8080이므로 `-JproductPort=8082`를 꼭 넘긴다.

목적:

- 성공한 선점 건수가 초기 재고 100건을 넘지 않는지 (초과 판매 없음)
- 재고 row 잠금 방식에 따른 충돌·대기 처리 확인
  - 개선 전: 낙관적 락(`version`) + `@Retryable`(최대 3회) → 충돌 실패 발생
  - 개선 후: 비관적 락(`SELECT ... FOR UPDATE`) → 충돌 대신 순서대로 대기

응답 코드가 샘플러 라벨에 붙으므로(`reserve [PRODUCT_STOCK_CONFLICT]` 등) Summary Report에서 결과별 비율을 바로 확인할 수 있다.

## 2. UpdateStock Conflict Test
`jmeter/update-stock-conflict-test.jmx`

- Threads: 10
- Ramp-up: 1초
- Loop: 10회
- 총 요청 수: 100회
- Synchronizing Timer: 10개 Thread, timeout 5초 (루프마다 동기화)

요청 대상:

`PATCH http://localhost:8082/api/v1/stocks/{productId}`

헤더:

- `Content-Type: application/json`
- `X-User-Id: ${sellerId}`
- `X-User-Role: SELLER`

본문:

`{"totalQuantity":150}`

실행 예시:

```bash
jmeter -n -t performance-test/product_stock/jmeter/update-stock-conflict-test.jmx -JproductId=44444444-4444-4444-8444-444444444444 -JsellerId=dddddddd-dddd-4ddd-8ddd-dddddddddddd -JproductPort=8082 -l test-results/product_stock/update-conflict.jtl -j test-results/product_stock/update-conflict.log
```

목적:

- 같은 재고 row에 재고 수정 요청이 동시에 들어올 때 낙관적 락 충돌이 재현되는지
- `@Retryable`(최대 3회)이 충돌을 얼마나 흡수하는지

예약이 없는 재고라 수량 검증에 걸리지 않고 버전 충돌만 관찰할 수 있다.

## 3~5번 공통

### 요청 흐름

JMeter 1회 반복 = 주문 1건 = `POST /api/v1/internal/stocks/reserve` (재고 1개 선점)

**주문이 몰리는 순간의 트래픽**을 보기 위해 reserve만 측정한다. (타임딜 성능 테스트도 구매 선점 API만 측정한다.)

- confirm·restore를 함께 보내면 같은 커넥션 풀과 재고 row 락을 나눠 써서, reserve 결과에 다른 API의 영향이 섞인다.
- 필요하면 `confirmRatio` / `restoreRatio` 옵션으로 결제·취소를 섞은 혼합 부하도 실행할 수 있다. (예: `-JconfirmRatio=70 -JrestoreRatio=20`)

### 분산 상품과 핫 상품

| 대상 | 옵션 | 보는 것 |
| --- | --- | --- |
| 분산 상품 200개 | `distributed` (기본) | 서버·DB 전체 처리 능력 (커넥션 풀, CPU) |
| 핫 상품 1개 | `hot` | 같은 재고 row에 몰릴 때의 락 대기 |

reserve는 비관적 락이라 같은 상품에 몰리면 실패하기보다 **줄을 서서 기다린다.** 그래서 핫 상품은 에러율보다 응답 시간과 커넥션 대기(pending)를 중점적으로 본다.

### 실행 옵션 (`-J`)

| 옵션 | 기본값 | 설명 |
| --- | --- | --- |
| `productHost` / `productPort` | `localhost` / `8082` | product-service 주소 |
| `serviceKey` | `local-dev-key` | `X-Service-Key` |
| `productCsv` | `../data/load-products.csv` | 분산 상품 목록 (jmx 위치 기준) |
| `hotProductId` | `55555555-5555-4555-8555-555555555555` | 핫 상품 |
| `confirmRatio` / `restoreRatio` | `0` / `0` | reserve 후 결제 / 취소 비율(%). 기본은 reserve 단독 |

### 리포트와 정합성 검증

HTML 리포트는 기본 60초 단위로 묶이므로 5초 단위 옵션을 넣어 생성한다. 출력 폴더가 이미 있으면 실패하므로 이름을 바꾸거나 지운다.

```bash
jmeter -g test-results/product_stock/load.jtl -Jjmeter.reportgenerator.overall_granularity=5000 -o test-results/product_stock/load-report
```

테스트가 끝나면 정합성을 확인한다.

```bash
docker exec -i postgres psql -U parut -d parut < performance-test/product_stock/data/product-stock-load-verify.sql
```

- `held_mismatch_rows`, `confirmed_mismatch_rows`가 모두 0이면 정상
  - `total - available` = 선점 중(`RESERVED`, `EXPIRATION_FAILED`) 수량 합
  - `초기 재고 - total` = 확정(`CONFIRMED`) 수량 합
- reserve 단독이면 성공한 reserve 건수가 모두 `reserved`로 남아 있어야 한다. (TTL 15분이 지나기 전)

## 3. Load Test
`jmeter/load-test.jmx`

- 대상: 분산 상품 200개
- 목표 부하: `targetRps` 3 TPS (평상시 피크)
- Threads: `threads` 10
- Ramp-up: `rampUp` 60초
- Duration: `duration` 600초

실제 부하는 Thread 수가 아니라 `targetRps`(Constant Throughput Timer)로 고정한다.

실행 예시:

```bash
jmeter -n -t performance-test/product_stock/jmeter/load-test.jmx -JtargetRps=3 -Jduration=600 -l test-results/product_stock/load.jtl -j test-results/product_stock/load.log
```

목적:

- 평상시 피크에서 합격선(P95 200ms, 에러 0%, 정합성 0건)을 충족하는지
- 실제 처리량이 `targetRps`에 도달하는지 (도달하지 못하면 이미 한계 근처)
- 분산 상품이므로 `PRODUCT_STOCK_CONFLICT`가 0건인지

## 4. Spike Test
`jmeter/spike-test.jmx`

Thread Group 두 개가 동시에 돈다.

| 구간 | 시간 | 부하 | 옵션 (기본값) |
| --- | --- | --- | --- |
| 기준선 | 0 ~ 7분 계속 | 3 TPS | `baseRps`(3), `baseThreads`(10), `duration`(420초) |
| 피크 | 3분 시점부터 1분간 | 기준선 + 27 = **30 TPS** | `spikeRps`(27), `spikeThreads`(50), `spikeDelay`(180초), `spikeDuration`(60초) |
| 회복 | 4 ~ 7분 | 3 TPS | |

- 피크 대상: `spikeTarget` (`distributed` 기본 / `hot`)

실행 예시:

```bash
# 분산 상품
jmeter -n -t performance-test/product_stock/jmeter/spike-test.jmx -JbaseRps=3 -JspikeRps=27 -JspikeTarget=distributed -l test-results/product_stock/spike-distributed.jtl -j test-results/product_stock/spike-distributed.log

# 핫 상품 (seed 재실행 후)
jmeter -n -t performance-test/product_stock/jmeter/spike-test.jmx -JbaseRps=3 -JspikeRps=27 -JspikeTarget=hot -l test-results/product_stock/spike-hot.jtl -j test-results/product_stock/spike-hot.log
```

목적:

- 피크 구간에도 합격선을 유지하는지
- **회복 시간**: 피크가 끝난 뒤 응답 시간이 기준선 수준으로 돌아오기까지 걸린 시간
- 핫 상품 피크가 다른 상품(기준선) 요청까지 느려지게 만드는지
- 정합성 mismatch 0건 (과다 선점 없음)

## 5. Stress Test
`jmeter/stress-test.jmx`

- Threads: `maxThreads` 200까지 `rampUp` 300초 동안 선형 증가
- Duration: `duration` 420초 (마지막 2분은 최대 부하 유지)
- 처리량 제한 없음 (응답을 받는 즉시 다음 요청)
- 대상: `stressTarget` (`distributed` 기본 / `hot`)

`maxThreads`를 Tomcat 기본 요청 스레드 수(200)로 둔다. 그 이상의 Thread는 Tomcat 앞에서 대기만 늘린다.

실행 예시:

```bash
# 서버·DB 처리 한계
jmeter -n -t performance-test/product_stock/jmeter/stress-test.jmx -JstressTarget=distributed -l test-results/product_stock/stress-distributed.jtl -j test-results/product_stock/stress-distributed.log

# 단일 재고 락 대기 한계 (seed 재실행 후)
jmeter -n -t performance-test/product_stock/jmeter/stress-test.jmx -JstressTarget=hot -l test-results/product_stock/stress-hot.jtl -j test-results/product_stock/stress-hot.log
```

목적:

- 합격선(P95 200ms)이 깨지는 처리량(용량)과, 목표(3 TPS) 대비 몇 배 여유가 있는지
- 먼저 한계에 닿는 병목 확인

분석 방법:

- HTML 리포트의 `Transactions Per Second`와 `Response Time vs Threads`를 함께 본다. **처리량은 더 오르지 않고 응답 시간만 늘어나는 지점**이 한계다.
- 같은 시간대 Grafana로 병목을 구분한다.

| Grafana에서 보이는 것 | 병목 |
| --- | --- |
| 커넥션 풀 active가 최대치, pending > 0 | DB 커넥션 풀 고갈 |
| CPU, GC 증가 | 애플리케이션 서버 자원 |
| `hot`에서만 응답 시간 급증 | 단일 재고 row 락 대기 |

## 3~5번 결과

측정일 2026-10-15, 위 측정 조건(reserve 단독, 로그 INFO, `synchronous_commit = off`, TTL 15분)에서 실행했다. 모든 테스트에서 응답은 전부 200이었다.

### 요약

| 테스트 | reserve 처리량 (Grafana) | 평균 응답시간 (Grafana) | reserve P95 (JMeter) | 에러 | 정합성 mismatch | 판정 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Load | 약 3.3 req/s | 약 8~13ms | 26ms | 0% | 0건 | 합격 |
| Spike (distributed) | 피크 약 30 req/s | 약 6~8ms | 19ms (피크 1분 17ms) | 0% | 0건 | 합격 |
| Spike (hot) | 피크 약 30 req/s | 약 5~6ms | 15ms (피크 1분 14ms) | 0% | 0건 | 합격 |
| Stress (distributed) | 최대 약 **660** req/s | 약 300~360ms | 0.8~1.1초 (한계 초과, 대기 포함) | 0% | 0건 | 이벤트 피크 대비 약 22배 |
| Stress (hot) | 최대 약 **390** req/s | 약 500~510ms | 0.8~1.0초 (한계 초과, 대기 포함) | 0% | 0건 | 이벤트 피크 대비 약 13배 |

- 처리량·평균 응답시간은 Grafana(서버 기준), P95는 JMeter(클라이언트 기준, Tomcat 대기 포함) 값이다.
- Stress의 응답시간은 200 Threads 유지 구간 값이다. 실제 처리 시간(커넥션 사용 시간)은 약 14~26ms이고, 한계를 넘은 요청이 커넥션 앞에서 대기해 응답시간이 늘어난다.
- P95 200ms 이내로 처리되는 구간은 distributed 약 60 Threads(약 670 TPS), hot 약 40 Threads(약 330 TPS)까지다.

### 3. Load

| 항목 | 결과 |
| --- | --- |
| reserve 처리량 | 3.01 TPS (1,804건) |
| reserve 평균 / P95 / P99 | 14ms / 26ms / 55ms |
| product 커넥션 풀 | active 최대 1 / 10, pending 0 |
| verify | reserved 1,804 (reserve 성공 건수와 일치) |

시작 직후 약 1분 동안 평균 응답시간이 약 30ms까지 오른 뒤 약 10ms로 안정됐다. (컨테이너 재생성 직후 워밍업) 평상시 피크에서 커넥션 풀이 거의 비어 있을 만큼 여유가 있다.

### 4. Spike

| 구간 | distributed (TPS / P95) | hot (TPS / P95) |
| --- | --- | --- |
| 기준선 (0~3분) | 3.0 / 17~30ms | 3.0 / 16~20ms |
| 피크 (3~4분) | 30.2 / 17ms | 30.1 / 14ms |
| 회복 (4~7분) | 3.0 / 17~20ms | 3.0 / 15~18ms |

- 처리량이 10배로 뛰어도 응답 시간은 기준선과 차이가 없고, 피크 직후 바로 기준선으로 돌아왔다. (회복 시간 사실상 0)
- 핫 상품 피크 중에도 기준선(분산 상품) 요청이 느려지지 않았다.
- product 커넥션 풀 active 최대 1, pending 0
- verify: distributed 2,935건, hot 2,935건(분산 1,266 + 핫 1,669) 모두 reserve 성공 건수와 일치

### 5. Stress

| 항목 | distributed | hot |
| --- | --- | --- |
| 최대 처리량 (reserve) | 약 690 TPS (Threads 약 80) | 약 390 TPS (Threads 약 60부터 정체) |
| P95 200ms를 넘는 시점 | Threads 약 60 (약 670 TPS) | Threads 약 40 (약 330 TPS) |
| 200 Threads 유지 구간 | 540~650 TPS / P95 0.8~1.1초 | 380~400 TPS / P95 0.8~1.0초 |
| 전체 요청 / 에러 | 242,549건 / 0건 | 157,274건 / 0건 |
| verify | 242,549건 일치 | 157,274건 일치 |

한계 시점 지표 (Prometheus, 200 Threads 구간):

| 지표 | distributed | hot |
| --- | ---: | ---: |
| 커넥션 1회 사용 시간 | 약 13~16ms | 약 25~28ms |
| 커넥션 획득 대기 시간 | 약 320ms | 약 490ms |
| 커넥션 풀 | active 10/10, pending 약 190 | active 10/10, pending 약 190 |
| CPU (Docker 4코어 전체) | 92~94% | 약 62% |
| CPU (product-service 프로세스) | 41~45% | 23~25% |

- 최대 처리량은 `커넥션 수 ÷ 커넥션 1회 사용 시간`과 일치한다. (distributed 10 ÷ 0.014초 ≈ 710, hot 10 ÷ 0.026초 ≈ 385)
- **distributed**: 한계 이후 Threads가 늘어도 처리량은 그대로이고 커넥션 대기만 쌓였다. 다만 같은 시점에 CPU도 94%에 가까웠다. (Postgres, 서비스 5개, JMeter가 같은 PC에서 실행) 커넥션 풀 크기(10)와 로컬 PC 자원 중 무엇이 원인인지는 **풀 크기를 늘린 재측정으로 확인**한다.
- **hot**: CPU에 여유가 있는데도 한계가 분산의 약 57%이고 커넥션 사용 시간이 약 2배다. 커넥션을 잡은 채 **같은 재고 row 락을 기다리는 것**이 원인이다.
- pending이 약 190에서 멈춘 것은 Tomcat 기본 요청 스레드 200개 중 10개가 커넥션을 쓰고 나머지가 대기하기 때문이다.
- 한계를 넘어도 에러 없이 대기 후 처리됐고, 수십만 건에서도 정합성이 유지됐다.

### 결론

- 이벤트 피크(30 TPS)까지 합격선을 여유 있게 충족한다.
- reserve 처리 한계는 분산 약 690 TPS, 핫 상품 약 390 TPS로 이벤트 피크 대비 각각 약 22배, 13배 여유가 있다.
- 현재 서비스 규모에서는 Redis 등 추가 구성 없이 DB 비관적 락으로 충분하다.
- 참고: 이전에 confirm 70% / restore 20%를 섞어 측정했을 때 reserve 한계는 분산 약 300, 핫 약 200 TPS였다. 결제·취소 요청이 같은 커넥션 풀과 재고 row 락을 나눠 쓰기 때문이다.

### 개선 후보

- ~~**이벤트 로그 `reservation_id` 인덱스 추가**~~ → 6번에서 측정 후 V152로 적용 완료
- **distributed 병목 확정**: 커넥션 풀을 20으로 늘려 Stress(distributed)를 재측정한다. 처리량이 오르면 커넥션 풀, 그대로면 CPU(로컬 PC 자원)가 병목이다. 현재 규모(30 TPS)에서는 조정이 필요 없다.

## 6~7번 공통 (만료 스케줄러)

### 왜 테스트하는가

3~5번은 주문 경로(reserve)만 검증했다. 결제하지 않고 이탈한 주문의 재고를 돌려주는 만료 스케줄러는 검증하지 않았고, 아래 두 가지가 의심됐다.

- **인덱스 없음**: 스케줄러는 예약 1건마다 `reservation_id`로 RESERVE 로그를 조회한다. (`findByReservationIdAndEventType`) 이 컬럼에 인덱스가 없어 로그가 쌓일수록 느려질 수 있다.
- **락 방식 차이** (7번 개선 전): reserve / confirm / restore는 재고를 비관적 락으로 조회하지만, 스케줄러만 락 없이 조회한 뒤 `@Version`(낙관적 락)으로 저장한다. 인기 상품에 주문이 몰리는 중에 만료가 실행되면 충돌로 실패하고, 3회 실패하면 재고가 복구되지 않고 격리(`EXPIRATION_FAILED`)될 수 있다.

스케줄러 동작:

- 주기마다 유효시간이 지난 RESERVED 예약을 100건씩 커서 방식으로 조회
- 예약 1건마다 별도 트랜잭션(`REQUIRES_NEW`)으로, 한 스레드에서 순서대로 처리
- 1건당 (개선 전): 예약 조회 → RESERVE 로그 조회 → RESTORE 로그 조회 → 예약 저장 → 재고 조회(락 없음) → 재고 저장(`@Version`) → RESTORE 로그 저장
- 1건당 (7번 개선 후): 예약 조회 → RESERVE 로그 조회 → RESTORE 로그 조회 → **재고 잠금(비관적 락)** → 예약 저장 → 재고 저장 → RESTORE 로그 저장
- 실패하면 `failure_count`를 올리고 다음 주기에 다시 시도, 3회 실패하면 격리

### 기준

| 값 | 기준 | 근거 |
| --- | --- | --- |
| 만료 예약 3,600건 | 이벤트 피크 30 TPS × 주기 600초 × 결제 이탈률 20% | 30 TPS는 3~5번 기준, 주기 10분은 `application-prod.yml`, 이탈률 20%는 실제 데이터가 없어 보수적으로 잡은 **가정**. 30 TPS가 주기 내내 유지된다고 본 상한값 |
| 이벤트 로그 4만 / 40만 / 400만 건 | 10배씩 증가 | 아래 참고 |

이벤트 로그 양을 이렇게 잡은 이유:

- 인덱스가 없으면 스케줄러가 1건마다 로그 전체를 읽으므로, 처리 시간은 **로그 양에 따라 달라진다.** 한 지점이 아니라 로그가 쌓일 때의 변화를 봐야 해서 여러 지점을 측정했다.
- 이벤트 로그는 보관 정책이 없어 지우지 않고 계속 쌓인다. "1년 운영" 같은 기간을 고를 근거가 없어, 기간 대신 **10배씩** 늘리는 규칙으로 정했다. 세 지점으로 서비스 초기부터 1년 이상까지를 덮는다.
- 운영 기간은 해석용 참고값이다.

  ```
  하루 주문 5,000건 (서비스 규모 기준) × 주문 1건당 로그 약 2건 (RESERVE + CONFIRM 또는 RESTORE) = 하루 약 1만 건
  ```

  | 이벤트 로그 | 운영 기간 환산 | 의미 |
  | ---: | ---: | --- |
  | 4만 건 | 약 4일 | 서비스 오픈 직후 |
  | 40만 건 | 약 40일 | 1~2개월 운영 |
  | 400만 건 | 약 400일 | 1년 이상 운영 |

- 만료 예약은 3,600건으로 고정해, 바뀌는 값을 로그 양 하나로만 둔다.

합격선:

- 3,600건을 운영 주기(**10분**) 안에 처리
- 인덱스 추가 후 로그가 늘어도 건당 처리 시간이 거의 같음
- 간섭 중 reserve P95 200ms 이하, 에러 0% (3~5번 합격선)
- 정합성 mismatch 0건, `EXPIRATION_FAILED` 0건

### 측정 조건

3~5번 측정 조건(로그 INFO, `synchronous_commit = off`, TTL 15분)에 아래를 더한다.

- 스케줄러 주기 1분 (`.env`의 `PRODUCT_STOCK_RATE=1m`, 로컬 기본 5분, 운영 10분). 바꾼 뒤 `docker compose up -d product-service`로 컨테이너를 다시 만든다.
- 만료 대상 예약은 JMeter가 아니라 **seed SQL로 직접 넣는다.** 스케줄러는 HTTP 요청이 아니라 주기마다 DB를 읽어 동작하므로, 부하를 처리할 데이터 양으로 정의했다.
  - 예약(RESERVED, 만료 시각 지정), RESERVE 로그, 줄어든 재고 수량을 함께 맞춰 넣어 처리 후 verify가 맞아떨어지게 한다.
  - 이벤트 로그 양은 과거 이력(CONFIRMED 예약 + RESERVE / CONFIRM 로그)으로 맞추고, 별도 재고(`88888888-...`)에 붙여 정합성 검증과 섞이지 않게 한다.
- 선행 조건: `product-stock-load-seed.sql`을 한 번 실행해 분산 상품 200개, 핫 상품 1개 재고가 있어야 한다.

## 6. 만료 스케줄러 대량 처리 테스트

| 파일 | 역할 |
| --- | --- |
| `data/product-stock-scheduler-seed.sql` | 이전 데이터 정리 → 과거 이력 생성 → 만료 대상 예약(분산 상품 200개에 골고루) + RESERVE 로그 생성 → 재고 맞춤 |
| `data/product-stock-scheduler-explain.sql` | RESERVE 로그 조회의 실행 계획 (Seq Scan / Index Scan 확인) |
| `data/product-stock-scheduler-verify.sql` | 정합성, 처리 결과, 총 처리 시간, 건당 처리 시간 |

실행 예시 (`history_logs`를 40000 → 400000 → 4000000으로 바꿔 반복):

```bash
# 1) seed (커밋 즉시 다음 주기에 스케줄러가 처리 시작)
docker exec -i postgres psql -U parut -d parut -v expired_count=3600 -v history_logs=40000 < performance-test/product_stock/data/product-stock-scheduler-seed.sql

# 2) 실행 계획 (seed 직후, 스케줄러가 처리하기 전)
docker exec -i postgres psql -U parut -d parut < performance-test/product_stock/data/product-stock-scheduler-explain.sql

# 3) 처리가 끝난 뒤(reserved = 0) 결과 확인
docker exec -i postgres psql -U parut -d parut < performance-test/product_stock/data/product-stock-scheduler-verify.sql
```

Grafana에서는 **product-service 커넥션 풀**의 active 1 구간 길이가 처리 시간이다. (스케줄러가 한 스레드에서 순서대로 처리하므로 커넥션을 1개만 쓴다)

### 개선: 이벤트 로그 인덱스 추가

Before 측정 후 `(reservation_id, event_type)` 인덱스를 추가했다.

`src/main/resources/db/migration/product/stock/V152__add_product_stock_event_log_reservation_index.sql`

```sql
CREATE INDEX idx_event_logs_reservation_type
    ON product_schema.p_product_stock_event_logs (reservation_id, event_type);
```

- Java 코드는 바꾸지 않았다. 같은 쿼리가 Seq Scan 대신 Index Scan으로 실행된다.
- 엔티티에 `@Index`는 붙이지 않았다. `ddl-auto: validate`라 동작 차이가 없고, 인덱스 정의를 Flyway 한 곳에서만 관리한다.

### 결과

측정일 2026-10-20 ~ 21. 모든 케이스에서 3,600건 모두 EXPIRED, 정합성 mismatch 0건, 격리 0건이었다.

| 이벤트 로그 | Before 총 시간 (건당) | After 총 시간 (건당) | 감소율 | RESERVE 로그 조회 (Before → After) |
| ---: | ---: | ---: | ---: | --- |
| 4만 건 (약 4일분) | 52.3초 (14.54ms) | 18.4초 (5.12ms) | 약 65% | Seq Scan 약 8ms → Index Scan 약 0.07ms |
| 40만 건 (약 40일분) | 91.8초 (25.52ms) | 12.7초 (3.54ms) | 약 86% | Parallel Seq Scan 약 48ms → Index Scan 약 0.08ms |
| 400만 건 (약 400일분) | **515.5초 (143.22ms)** | **27.9초 (7.76ms)** | **약 95%** | Parallel Seq Scan 약 470ms → Index Scan 약 0.07ms |

- **Before**: 1건을 찾으려고 로그 전체를 읽어, 로그가 4만 → 400만 건으로 늘자 건당 시간이 약 10배 늘었다. 400만 건에서는 10분 주기의 **약 86%** 에 도달해, 로그가 조금 더 쌓이면 만료 처리가 주기를 넘긴다.
  - 4만 → 40만: 건당 1.8배 (로그가 메모리 안에 있음)
  - 40만 → 400만: 건당 약 5.6배 (로그가 메모리에 다 들어가지 않아 디스크 읽기 발생, 실행 계획 `read=60,761` 페이지)
- **After**: 로그 양과 관계없이 약 4페이지만 읽고, 건당 3~8ms로 거의 일정하다. 400만 건에서도 주기의 약 5%다.
- 남은 건당 시간은 나머지 쿼리 6개와 건별 커밋 시간이다.
- 처리 중 커넥션 풀은 Before / After 모두 active 1, pending 0이다. 병목은 커넥션 풀이 아니라 커넥션 안에서 실행되는 로그 전체 조회였다.

## 7. 만료 스케줄러 간섭 테스트

| 파일 | 역할 |
| --- | --- |
| `data/product-stock-scheduler-interference-seed.sql` | 대량 처리 seed와 같은 구조. 만료 시각을 "seed 종료 + `expire_after_seconds`"로 넣어 Spike 피크와 겹치게 한다. 만료 예약은 `created_by = 'performance-test'`로 JMeter 예약과 구분 |
| `data/product-stock-scheduler-interference-verify.sql` | 정합성, seed 만료 예약의 처리 결과와 실패 횟수 분포, 처리 시각, 분당 처리 건수, JMeter 예약 수 |

조건:

- **hot만 진행한다.** 확인할 의심(낙관적 락 충돌)은 같은 재고 row를 두고 경쟁하는 hot에서만 드러난다. distributed는 6번에서 스케줄러가 커넥션 1개로 짧게 처리하고, 3~5번 Spike에서도 reserve가 커넥션을 최대 1개만 써서 결과가 예측되므로 생략했다.
- **인덱스 추가 후** 실행한다. 인덱스 영향을 빼고 락 문제만 본다.
- 핫 상품 만료 예약 3,600건, 이벤트 로그 40만 건(6번의 중간값)
- 배경 트래픽은 4번 Spike(hot) 그대로: 0~3분 3 TPS → 3~4분 30 TPS → 4~7분 3 TPS
- 격리가 발생하면 스케줄러 재고 조회를 비관적 락으로 바꾸고 재측정한다. (사전 결정)

실행 예시 (seed가 끝나면 바로 JMeter가 시작되도록 `&&`로 잇는다):

```bash
docker exec -i postgres psql -U parut -d parut -v target=hot -v expire_after_seconds=185 < performance-test/product_stock/data/product-stock-scheduler-interference-seed.sql && jmeter -n -t performance-test/product_stock/jmeter/spike-test.jmx -JbaseRps=3 -JspikeRps=27 -JspikeTarget=hot -l test-results/product_stock/interference-hot.jtl -j test-results/product_stock/interference-hot.log

# seed 만료 예약 처리가 끝난 뒤(seed_reserved = 0) 결과 확인. 실패한 예약은 다음 주기에 재시도되므로 기다린다.
docker exec -i postgres psql -U parut -d parut < performance-test/product_stock/data/product-stock-scheduler-interference-verify.sql
```

`expire_after_seconds`(기본 185초)는 JMeter 시작 후 피크(3분) 시점에 만료되도록 잡는다. seed가 끝난 뒤 JMeter가 시작되기까지 약 2초가 걸려, 180초로 두면 피크 시작 직전에 만료된다. (실측: seed 종료 03:27:44, JMeter 시작 03:27:46, 만료 03:30:49, 피크 시작 03:30:46)

### 결과

측정일 2026-10-21.

| 항목 | 결과 |
| --- | --- |
| 스케줄러 첫 주기 | 피크 중 시작해 약 13초 처리, **전체가 피크(30 TPS) 안** |
| 만료 처리 | 3,600건 모두 EXPIRED |
| 실패 / 격리 | 1회 실패 후 재시도 성공 **241건 (6.7%)**, 2회 이상 실패 0건, **격리 0건** |
| 실패 원인 | 전부 `PRODUCT_STOCK_CONFLICT` (낙관적 락 충돌, Loki WARN 241건 / ERROR 0건) |
| 재시도 | 다음 주기(약 61초 뒤)에 241건 모두 성공 (약 1초) |
| reserve P95 | 피크 1분 15ms (스케줄러 실행 13초만 보면 26ms, 실행 전 13ms) |
| 에러 / 정합성 | 0% (2,935건) / mismatch 0건 |
| product 커넥션 풀 | active 최대 1, pending 0 |

- **충돌 구조**: 스케줄러가 재고를 락 없이 읽고 저장하는 수 ms 사이에 reserve(비관적 락)가 같은 row의 version을 올리면 실패한다. 첫 주기 13초 동안 hot reserve 351건(초당 약 27건)이 들어왔고, 충돌은 초당 약 20건으로 고르게 발생했다.
- **정합성 유지**: 충돌하면 `REQUIRES_NEW` 트랜잭션이 예약 상태 변경과 재고 복구를 함께 롤백하므로, 예약은 RESERVED로 남고 다음 주기에 다시 처리된다.
- **재시도가 모두 성공한 이유**: 재시도 시점에는 피크가 끝나 hot 재고 경쟁이 없었다. 격리되려면 같은 예약이 3주기 연속 충돌해야 한다.
- **주문 영향**: 스케줄러와 겹친 13초 동안 같은 row 락을 번갈아 잡아 P95가 13 → 26ms로 늘었지만 합격선의 약 13%이고, 스케줄러가 끝나자 바로 돌아왔다. 커넥션 경쟁은 없었다.

### 결정

격리가 발생하지 않아 사전 결정(격리 발생 시 락 변경)에는 해당하지 않았다. 다만 아래 한계 때문에 별도 개선으로 비관적 락 전환을 진행했다.

- 충돌한 예약은 재고 복구가 한 주기 늦어진다. 테스트(1분 주기)에서는 약 1분이지만 운영(10분 주기)에서는 **최대 10분**이고, 재고가 적은 인기 상품이라면 그동안 품절처럼 보일 수 있다.
- restore(주문 취소)는 "재고 잠금 → 예약 변경", 스케줄러는 "예약 변경 → 재고 저장"으로 **잠그는 순서가 반대**였다. 같은 예약을 동시에 취소·만료하면 데드락이 생길 수 있다.
- 스케줄러도 재고 UPDATE 시점에 row 락을 잡고 커밋까지 유지하므로, 읽는 시점부터 잠가도 reserve에 추가되는 대기는 작다고 판단했다.

### 개선: 스케줄러 재고 조회 비관적 락 전환

`ProductStockReservationExpirationProcessor.expireOneReservation`

| | 개선 전 | 개선 후 |
| --- | --- | --- |
| 재고 조회 | `findById` (락 없음) → 저장 시 `@Version` 확인 | `findAllByIdForUpdate` (비관적 락, confirm / restore와 같은 쿼리) |
| 순서 | 예약 저장 → 재고 조회 → 재고 저장 | **재고 잠금** → 예약 저장 → 재고 저장 (restore와 같은 순서) |

- 잠금을 `reservation.expire()`보다 먼저 둔다. 예약을 먼저 바꾼 뒤 잠금 쿼리를 실행하면 Hibernate가 예약 변경을 먼저 반영(auto flush)해 순서가 다시 뒤집힐 수 있다.
- 예약 쪽 낙관적 락(`@Version`)은 유지한다. 예약 row는 잠그지 않으므로 사용자 취소와 동시에 처리되는 경우를 막는 장치다.
- 단위 테스트에 잠금 순서 검증(`InOrder`: 재고 잠금 → 예약 저장 → 재고 저장)을 추가했다.

같은 조건(위 실행 예시, 결과 파일만 `interference-hot-after`)으로 재측정했다. 측정일 2026-10-21.

| 항목 | 개선 전 | 개선 후 |
| --- | ---: | ---: |
| 충돌 실패 (`failure_count > 0`) | 241건 (6.7%) | **0건** |
| 스케줄러 WARN / ERROR | 241 / 0 | **0 / 0** |
| 격리 | 0건 | 0건 |
| 처리 완료 | 첫 주기 3,359 + 다음 주기 241 | **첫 주기 3,600** |
| 만료 → 마지막 복구 | 약 97초 | **약 49초** |
| 첫 주기 처리 시간 | 약 13초 | 19.2초 |
| 스케줄러 실행 중 reserve P95 (실행 전 대비) | 13 → 26ms (2.0배) | 28 → 56ms (2.0배) |
| 에러 / 정합성 | 0% / 0건 | 0% / 0건 |

- 첫 주기 처리 구간(19초)이 전부 피크 안에 들어갔고, 같은 구간 hot reserve는 초당 약 27건으로 개선 전과 같은 경쟁 조건이다.
- **충돌이 없어지고 모든 예약이 첫 주기에 복구됐다.** 대가는 스케줄러가 reserve의 락을 기다리면서 처리 시간이 약 1.5배(13 → 19초) 늘어난 것으로, 10분 주기의 약 3%다.
- reserve 응답 시간은 **같은 실행 안의 상대 비교**로 본다. 개선 후는 재빌드 직후라 JVM 워밍업이 덜 돼, 스케줄러와 무관한 피크 전 기준선 P95부터 18 → 44ms로 높았다. (첫 요청 1,557ms, 기준선 P95가 분마다 52 → 41 → 34ms로 감소) 스케줄러 실행 전 대비 실행 중 증가 비율은 개선 전과 같은 2.0배라, 비관적 락으로 인한 추가 부담은 없었다. 스케줄러 실행 중 P95 56ms, Max 209ms(1건)로 합격선 안이다.

## 6~7번 결론

- 이벤트 로그 인덱스가 없으면 로그가 쌓일수록 만료 처리가 느려져, 운영 약 400일분에서 10분 주기의 86%에 도달한다. `(reservation_id, event_type)` 인덱스로 515.5초 → 27.9초(약 95% 감소)가 됐고, 로그 양과 관계없이 처리 시간이 일정해졌다.
- 인기 상품 주문 피크와 겹치면 만료의 약 7%가 낙관적 락 충돌로 실패했다. 정합성은 유지되고 다음 주기에 복구됐지만, 복구 지연과 restore와의 잠금 순서 차이를 없애기 위해 스케줄러도 비관적 락으로 바꿨다. 충돌 0건, 첫 주기 전부 복구, 주문 쪽 추가 부담 없음을 확인했다.

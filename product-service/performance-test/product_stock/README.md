# Product Stock Performance Test

일반 재고(주문 시 선점 → 결제 시 확정 → 취소 시 복구)의 동시성, 성능, 한계를 검증한다.

| 테스트 | 파일 | 확인하는 것 |
| --- | --- | --- |
| 1. Concurrency | `jmeter/concurrency-test.jmx` | 단일 상품 동시 선점 시 재고 정합성 |
| 2. UpdateStock Conflict | `jmeter/update-stock-conflict-test.jmx` | 재고 수정 동시 요청 시 버전 충돌 처리 |
| 3. Load | `jmeter/load-test.jmx` | 평상시 피크 부하에서 합격선 충족 여부 |
| 4. Spike | `jmeter/spike-test.jmx` | 이벤트로 갑자기 몰릴 때 버티는지, 끝난 뒤 회복하는지 |
| 5. Stress | `jmeter/stress-test.jmx` | 처리 한계와 병목 지점 |

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
- Stress처럼 예약이 수십만 건 쌓인 뒤에는 seed가 매우 느려진다. (이벤트 로그 `reservation_id`에 인덱스가 없어 예약 삭제 1건마다 로그 전체를 확인한다.) 이벤트 로그를 먼저 지우고 정리한 뒤 seed를 실행한다.
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

- **이벤트 로그 `reservation_id` 인덱스 추가**: 만료 스케줄러(`findByReservationIdAndEventType`)와 재고 이력 조회가 이 컬럼으로 조회하는데 인덱스가 없어 로그 전체를 읽는다. 로그가 쌓일수록 느려지며, Stress 직후 대량 예약의 만료 처리와 seed(예약 삭제)가 오래 걸린 것도 이 영향이다.
- **distributed 병목 확정**: 커넥션 풀을 20으로 늘려 Stress(distributed)를 재측정한다. 처리량이 오르면 커넥션 풀, 그대로면 CPU(로컬 PC 자원)가 병목이다. 현재 규모(30 TPS)에서는 조정이 필요 없다.

# Product Stock Performance Test

## 환경
- Java 21
- PostgreSQL
- JMeter ...
- 테스트 대상 commit/tag

## 데이터 준비

- `data/product-stock-seed.sql`을 product-service DB에서 실행하면 테스트 전용 상품과 재고가 생성된다.
- Concurrency Test fixture `productId`: `33333333-3333-4333-8333-333333333333` (초기 재고 100개)
- UpdateStock Conflict Test fixture `productId`: `44444444-4444-4444-8444-444444444444` / `sellerId`: `dddddddd-dddd-4ddd-8ddd-dddddddddddd` (초기 재고 1,000개, 예약 없음)
- 두 JMeter 테스트 모두 요청마다 `orderId`/`orderItemId`를 JMeter `__UUID()` 함수로 생성한다.
- JMeter 요청은 실제 DB 트랜잭션을 수행하므로 테스트 후 자동 롤백되지 않는다. 전용 상품·DB를 사용하고 성공한 예약과 재고 변동은 seed 재실행으로 정리한다(seed는 실행 전 이전 결과를 먼저 삭제한다).

모든 명령은 `product-service` 디렉터리를 현재 작업 디렉터리로 두고 실행한다.

```bash
cd product-service
mkdir -p test-results/product_stock
psql "$PRODUCT_DATABASE_URL" \
  -f performance-test/product_stock/data/product-stock-seed.sql
```

## 1. Concurrency Test (reserve)
`jmeter/concurrency-test.jmx`

일반재고 `reserve`는 타임딜과 달리 Redis 원자적 연산이 없고 JPA 낙관적 락(`version`) + `@Retryable`(최대 3회, 50ms 배수 백오프)만으로 동시성을 제어한다. 타임딜의 SyncTimer 500명 동시 발사 패턴을 그대로 가져오면 낙관적 락이 못 버티는 게 당연한 결과라 확인 실익이 없어, 기존에 측정하던 동시성 수준(50 Thread, 5초 Ramp-up)을 유지해 이전 측정치와 비교 가능하게 한다.

- 초기 재고: 100개
- 요청당 예약 수량: 1개
- Threads: 50
- Ramp-up: 5초
- Loop Count: 10
- 총 요청 수: 500회

요청 대상:

`POST http://localhost:8082/api/v1/internal/stocks/reserve`

(포트는 실행 환경에 맞게 `-JproductPort`로 넘긴다. 루트 `docker-compose.yml`로 전체 스택을 띄우면 product-service는 `${PRODUCT_PORT:-8082}`로 매핑되어 8082가 기본값이다. jmx 자체 기본값은 8080이므로 이 스택 기준으로 테스트할 때는 반드시 `-JproductPort=8082`를 넘긴다.)

헤더:

- `Content-Type: application/json`
- `X-Service-Key: local-dev-key`

본문:

`{"orderId":"${__UUID()}","items":[{"productId":"${productId}","orderItemId":"${__UUID()}","quantity":1}]}`

실행 예시:

```bash
jmeter -n -t performance-test/product_stock/jmeter/concurrency-test.jmx \
  -JproductId=33333333-3333-4333-8333-333333333333 \
  -JproductPort=8082 \
  -l test-results/product_stock/concurrency.jtl \
  -j test-results/product_stock/concurrency.log
```

목적:

재고 정합성 검증(성공 예약 건수는 초기 재고 100건을 넘을 수 없다) 및 `reserve`의 낙관적 락 재시도(`@Retryable`, `PRODUCT_STOCK_CONFLICT`) 동작 확인.

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/product_stock/concurrency.jtl \
  -o test-results/product_stock/concurrency-report
```

`errorCode 라벨링` PostProcessor가 응답 코드(`PRODUCT_STOCK_CONFLICT`, `PRODUCT_STOCK_NOT_FOUND` 등)를 샘플러 라벨에 붙여주므로, Summary Report에서 요청 라벨별로 충돌/성공 비율을 바로 확인할 수 있다.

## 2. UpdateStock Conflict Test
`jmeter/update-stock-conflict-test.jmx`

- Threads: 10
- Ramp-up: 1초
- Loop: 10회
- 총 요청 수: 100회
- Synchronizing Timer: 10개 Thread, timeout 5초 (루프마다 반복 동기화)

요청 대상:

`PATCH http://localhost:8082/api/v1/stocks/{productId}`

(위 Concurrency Test와 동일하게, 루트 `docker-compose.yml`로 전체 스택을 띄운 환경에서는 `-JproductPort=8082`를 넘긴다.)

헤더:

- `Content-Type: application/json`
- `X-User-Id: ${sellerId}`
- `X-User-Role: SELLER`

본문:

`{"totalQuantity":150}`

실행 예시:

```bash
jmeter -n -t performance-test/product_stock/jmeter/update-stock-conflict-test.jmx \
  -JproductId=44444444-4444-4444-8444-444444444444 \
  -JsellerId=dddddddd-dddd-4ddd-8ddd-dddddddddddd \
  -JproductPort=8082 \
  -l test-results/product_stock/update-conflict.jtl \
  -j test-results/product_stock/update-conflict.log
```

목적:

동일 재고 row에 대한 동시 `updateStock` 요청에서 낙관적 락(version) 충돌이 재현되는지, `@Retryable`(`PRODUCT_STOCK_CONFLICT`, 최대 3회 재시도)이 충돌을 얼마나 흡수하는지 확인한다. fixture 재고는 예약이 없는 상태(`reservedQuantity = 0`)라 `totalQuantity` 값 자체의 유효성 검증에는 걸리지 않고, 순수하게 버전 충돌만 관찰할 수 있다.

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/product_stock/update-conflict.jtl \
  -o test-results/product_stock/update-conflict-report
```

Report 출력 디렉터리는 기존에 존재하면 안 되므로 재생성할 때는 기존 Report 디렉터리를 비우거나 다른 이름을 사용한다.

---

## Load / Spike / Stress Test 공통

위 1·2번이 "단일 상품 row에서 정합성과 충돌이 어떻게 처리되는가"를 본다면, 3~5번은 실제 주문 흐름에 가까운 부하에서 **처리 성능과 한계**를 본다.

### 데이터 준비

`data/product-stock-load-seed.sql`이 아래 fixture를 만든다. 기존 `product-stock-seed.sql`과 ID 대역이 겹치지 않아 각각 따로 재실행할 수 있고, 실행 전에 이전 결과(예약·이벤트 로그·재고)를 먼저 삭제한다.

| 구분 | productId | 재고 | 용도 |
| --- | --- | ---: | --- |
| 분산 상품 200개 | `66666666-6666-4666-8666-000000000001` ~ `...000000000200` | 상품당 100,000 | Load, Spike/Stress 기본값 (`data/load-products.csv`) |
| 핫 상품 1개 | `55555555-5555-4555-8555-555555555555` | 1,000,000 | Spike/Stress에서 `hot` 대상으로 지정 시 |

재고를 넉넉하게 잡아 `PRODUCT_STOCK_SHORTAGE`가 섞이지 않고 순수하게 처리 성능만 관찰되도록 했다.

```bash
cd product-service
mkdir -p test-results/product_stock
psql "$PRODUCT_DATABASE_URL" \
  -f performance-test/product_stock/data/product-stock-load-seed.sql
```

### 요청 흐름

주문 1건(= JMeter 1 iteration)은 다음과 같이 진행한다.

1. `POST /api/v1/internal/stocks/reserve`: 수량 1개 선점
2. reserve가 성공했을 때만 아래 중 하나를 실행한다.
   - `confirmRatio`%(기본 70): `POST /api/v1/internal/stocks/confirm` (결제 완료)
   - `restoreRatio`%(기본 20): `POST /api/v1/internal/stocks/restore` (주문 취소)
   - 나머지(기본 10%): 아무것도 하지 않고 방치한다. `reservation-ttl`(local/docker 기본 5분)이 지나면 `ProductStockReservationExpirationScheduler`가 만료 처리하므로, **테스트 중 만료 스케줄러와 선점 요청이 같은 재고 row를 동시에 다루는 상황**도 함께 재현된다.

`orderId`/`orderItemId`는 iteration마다 JSR223 PreProcessor가 새 UUID로 만들고, confirm/restore는 같은 값을 재사용한다. 기존 테스트와 같은 `errorCode 라벨링`을 적용해 Summary/HTML Report에서 `reserve [SUCCESS]`, `reserve [PRODUCT_STOCK_CONFLICT]`처럼 응답 코드별로 나뉘어 보인다.

### 참고: 현재 reserve의 락 방식

`reserve`는 개선 후 `findByProductIdInForUpdate`(비관적 락, `SELECT ... FOR UPDATE`, id 순 정렬)로 재고 row를 잠근다. 따라서 같은 상품에 요청이 몰리면 **충돌로 실패하기보다 락을 기다리며 줄을 선다**. 그만큼 응답 시간이 늘고, 기다리는 동안 DB 커넥션도 계속 점유한다. 핫 상품 시나리오에서는 에러율보다 **응답 시간과 Hikari 커넥션 대기(pending)**를 중점적으로 본다.

### 공통 실행 옵션 (`-J`)

| 속성 | 기본값 | 설명 |
| --- | --- | --- |
| `productHost` | `localhost` | product-service 호스트 |
| `productPort` | `8082` | 루트 `docker-compose.yml` 기준 포트 (1·2번 jmx와 달리 기본값이 8082) |
| `serviceKey` | `local-dev-key` | `X-Service-Key` |
| `productCsv` | `../data/load-products.csv` | 분산 상품 CSV (jmx 파일 위치 기준 상대경로) |
| `hotProductId` | `55555555-5555-4555-8555-555555555555` | 핫 상품 |
| `confirmRatio` / `restoreRatio` | `70` / `20` | 후속 동작 비율(%) |

### 시간 단위 그래프 해상도

HTML Report의 시간축 그래프는 기본 60초 단위로 묶인다. 스파이크·단계 변화가 뭉개지지 않도록 Report를 생성할 때 `-Jjmeter.reportgenerator.overall_granularity=5000`(5초)을 넘기는 것을 권장한다.

### 정합성 검증

테스트가 끝나면 `data/product-stock-load-verify.sql`을 실행한다.

```bash
psql "$PRODUCT_DATABASE_URL" \
  -f performance-test/product_stock/data/product-stock-load-verify.sql
```

재고 row마다 아래 두 식이 성립하는지 확인한다. `held_mismatch_rows`와 `confirmed_mismatch_rows`가 모두 0이면 정합성이 유지된 것이다.

- `total - available` = `RESERVED` + `EXPIRATION_FAILED` 예약 수량 합
- `초기 재고 - total` = `CONFIRMED` 예약 수량 합

방치된 예약이 만료 처리되는 것까지 확인하려면 `reservation-ttl` + 스케줄러 주기만큼 기다린 뒤 다시 실행한다. `reserved` 건수가 0으로 줄고 `expired` 건수가 그만큼 늘어야 하며, `expiration_failed`는 0이어야 한다.

## 3. Load Test
`jmeter/load-test.jmx`

평상시 부하에서 정상 수치가 나오는지 확인하고, Spike/Stress의 **기준선**을 확보한다.

- 대상: 분산 상품 200개 (CSV 순환)
- Threads: `threads` (기본 50)
- Ramp-up: `rampUp` (기본 60초)
- Duration: `duration` (기본 600초)
- 목표 처리량: `targetRps` (기본 30 req/s, reserve 기준, Constant Throughput Timer)

Thread 수는 목표 처리량을 낼 수 있을 만큼 넉넉하게 두고, 실제 부하는 `targetRps`로 고정한다. 목표 처리량을 바꿔가며 여러 번 실행해 기준선을 정한다.

```bash
jmeter -n -t performance-test/product_stock/jmeter/load-test.jmx \
  -JtargetRps=30 -Jduration=600 \
  -l test-results/product_stock/load.jtl \
  -j test-results/product_stock/load.log

jmeter -g test-results/product_stock/load.jtl \
  -Jjmeter.reportgenerator.overall_granularity=5000 \
  -o test-results/product_stock/load-report
```

확인 기준:

- 에러율 0%
- `PRODUCT_STOCK_CONFLICT` 0건 (상품이 분산되어 있으므로 충돌이 없어야 한다)
- reserve P95 응답 시간이 테스트 내내 안정적으로 유지될 것
- 실제 처리량이 `targetRps`에 도달할 것 (도달하지 못하면 이미 한계 근처라는 뜻)
- 정합성 검증 SQL mismatch 0건

### 기준선 (Baseline)

Spike / Stress Test는 아래 기준선을 출발점으로 삼는다.

측정 조건

- 로컬 Docker 환경, product-service 단일 인스턴스 (JMeter는 같은 PC에서 실행)
- 상품 200개 분산 (`product-stock-load-seed.sql`)
- 로그 레벨 INFO (Actuator로 변경, prod 프로필과 동일)
- 테스트 DB만 `synchronous_commit = off`
  - 로컬 Docker 데이터가 HDD에 있어 WAL fsync가 1회 약 180ms 걸렸고, 이 때문에 커밋 대기로 커넥션 풀이 고갈됐다.
  - 디스크 영향을 빼고 애플리케이션 성능을 보기 위한 테스트 전용 설정이다. 테스트 후 `ALTER DATABASE parut RESET synchronous_commit`으로 원복한다.

기준선 수치 (Load Test, `targetRps=30`, 10분)

| 지표 | 값 |
| --- | ---: |
| reserve 처리량 | 29.9 req/s |
| reserve 평균 / P95 / P99 | 12ms / 42ms / 119ms |
| 에러율 | 0% |
| Hikari pending | 0 |
| 정합성 mismatch | 0 |

참고: 같은 조건에서 `synchronous_commit = on`(기본값)일 때는 reserve 약 20 req/s, P95 1,928ms, Hikari pending 약 40으로 목표 처리량에 도달하지 못했다.

## 4. Spike Test
`jmeter/spike-test.jmx`

기준선 부하를 유지하는 중에 순간적으로 요청이 몰렸을 때 실패율과 회복 시간에 문제가 없는지 확인한다. Thread Group 두 개가 동시에 돈다.

| Thread Group | 속성 (기본값) | 동작 |
| --- | --- | --- |
| 기준선 | `baseThreads`(30), `baseRampUp`(30초), `baseRps`(30), `duration`(420초) | 분산 상품에 고정 처리량 유지 |
| 피크 | `spikeThreads`(300), `spikeRampUp`(5초), `spikeDelay`(180초), `spikeDuration`(60초), `spikeTarget`(`distributed`) | 시작 180초 뒤 60초 동안 처리량 제한 없이 요청 |

기본 타임라인: 0~180초 기준선 → 180~240초 피크 → 240~420초 회복 관찰

`baseRps`는 Load Test에서 정한 기준선 값을 넣는다. `spikeTarget`으로 두 가지 경우를 나눠 실행한다.

- `distributed`: 분산 상품에 몰림. DB 커넥션 풀, Tomcat 스레드가 버티는지 확인
- `hot`: 핫 상품 하나에 몰림. 비관적 락 대기가 응답 시간과 커넥션 점유로 번져 **다른 상품(기준선) 요청까지 느려지는지** 확인

```bash
# 분산 상품 스파이크
jmeter -n -t performance-test/product_stock/jmeter/spike-test.jmx \
  -JbaseRps=30 -JspikeThreads=300 -JspikeTarget=distributed \
  -l test-results/product_stock/spike-distributed.jtl \
  -j test-results/product_stock/spike-distributed.log

# 핫 상품 스파이크 (seed 재실행 후)
jmeter -n -t performance-test/product_stock/jmeter/spike-test.jmx \
  -JbaseRps=30 -JspikeThreads=300 -JspikeTarget=hot \
  -l test-results/product_stock/spike-hot.jtl \
  -j test-results/product_stock/spike-hot.log

jmeter -g test-results/product_stock/spike-hot.jtl \
  -Jjmeter.reportgenerator.overall_granularity=5000 \
  -o test-results/product_stock/spike-hot-report
```

확인 기준:

- 스파이크 구간 에러율 (특히 5xx, 타임아웃)
- **회복 시간**: 스파이크 종료(240초) 뒤 reserve 응답 시간이 기준선 P95로 돌아오기까지 걸린 시간
- 실패가 있더라도 정합성 검증 SQL mismatch 0건 (과다 선점 없음)
- `hot`에서는 실패가 나는 것 자체보다, 실패율과 회복 시간을 기록하는 것이 목적이다

## 5. Stress Test
`jmeter/stress-test.jmx`

Load Test 기준선에서 시작해 부하를 점차 늘려 재고 선점의 한계와 병목 지점을 찾는다.

- Threads: `maxThreads` (기본 300)까지 `rampUp`(기본 600초) 동안 선형으로 증가
- Duration: `duration` (기본 720초). 마지막 120초는 최대 부하를 유지한다
- 처리량 제한 없음: 각 Thread가 응답을 받는 즉시 다음 요청을 보낸다
- 대상: `stressTarget` (`distributed` 기본 / `hot`)

```bash
# 서버/DB 처리 한계
jmeter -n -t performance-test/product_stock/jmeter/stress-test.jmx \
  -JmaxThreads=300 -JstressTarget=distributed \
  -l test-results/product_stock/stress-distributed.jtl \
  -j test-results/product_stock/stress-distributed.log

# 단일 row 락 대기 한계 (seed 재실행 후)
jmeter -n -t performance-test/product_stock/jmeter/stress-test.jmx \
  -JmaxThreads=300 -JstressTarget=hot \
  -l test-results/product_stock/stress-hot.jtl \
  -j test-results/product_stock/stress-hot.log

jmeter -g test-results/product_stock/stress-distributed.jtl \
  -Jjmeter.reportgenerator.overall_granularity=5000 \
  -o test-results/product_stock/stress-distributed-report
```

분석 방법:

- HTML Report의 `Transactions Per Second`와 `Response Time vs Threads`를 같이 본다. **TPS가 더 이상 오르지 않는데 응답 시간만 늘어나기 시작하는 Thread 수**가 한계 지점이다.
- 같은 시간대의 Grafana 지표로 병목을 구분한다.
  - `hikaricp_connections_pending` > 0, `active`가 최대치에 붙음: DB 커넥션 풀 고갈
  - CPU 사용률, GC pause 증가: 애플리케이션 서버 자원 한계
  - Tomcat busy threads가 최대치에 붙음: 요청 처리 스레드 고갈
  - `hot`에서만 응답 시간이 급증: 단일 row 비관적 락 대기
- 결과는 "N Thread / N TPS부터 X가 병목"으로 정리한다. 이 결과는 Hikari 풀 크기, 락 전략, 캐시나 Redis 도입을 검토하는 근거가 된다.

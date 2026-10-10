# TimeDeal Performance Test

## 환경
- Java 21
- PostgreSQL
- Redis
- JMeter ...
- 테스트 대상 commit/tag

## 데이터 준비

- 테스트 대상 타임딜을 ACTIVE 상태로 준비한다.
- Concurrency Test 대상은 초기 판매 가능 재고 100개로 설정한다.
- Load Test 대상은 총 1,000건의 요청보다 충분히 큰 재고를 별도로 설정한다.
- `data/time-deal-seed.sql`을 product-service DB에서 실행하면 테스트 전용 타임딜과 재고가 생성된다.
- Concurrency fixture `timeDealId`: `11111111-1111-4111-8111-111111111111` (초기 재고 100개)
- Load fixture `timeDealId`: `22222222-2222-4222-8222-222222222222` (초기 재고 100,000개)
- 두 테스트 모두 요청마다 `userId`와 `orderId`를 JMeter `__UUID()` 함수로 생성한다. CSV EOF나 사용자별 최대 구매 수량에 걸리지 않도록 고정 사용자·주문 데이터를 사용하지 않는다.
- JMeter 요청은 실제 DB 트랜잭션을 수행하므로 테스트 후 자동 롤백되지 않는다. 전용 타임딜·DB를 사용하고 성공한 구매와 차감 재고를 별도 정리한다.

아래 명령은 `product-service` 디렉터리를 현재 작업 디렉터리로 두고 실행한다.

```bash
# 저장소 루트에서 실행하는 경우 product-service 디렉터리로 이동한다.
cd product-service
mkdir -p test-results
psql "$PRODUCT_DATABASE_URL" \
  -f performance-test/timedeal/data/time-deal-seed.sql
```

## 1. Concurrency Test
jmeter/concurrency-test.jmx

- 초기 타임딜 재고: 100개
- 요청당 구매 수량: 1개
- Threads: 500
- Ramp-up: 1초
- Loop Count: 1
- Synchronizing Timer: 500개 Thread, timeout 10초
- 총 요청 수: 500회

요청 대상:

`POST http://localhost:8080/api/v1/internal/time-deals/{timeDealId}/purchases`

헤더:

- `Content-Type: application/json`
- `X-Service-Key: local-dev-key`
- `X-User-Id: ${__UUID()}`

본문:

`{"orderId":"${__UUID()}","quantity":1}`

실행 예시:

```bash
jmeter -n -t performance-test/timedeal/jmeter/concurrency-test.jmx \
  -JtimeDealId=11111111-1111-4111-8111-111111111111 \
  -l test-results/concurrency-before.jtl \
  -j test-results/concurrency-before.log
```

Windows PowerShell에서 루트 `docker-compose.yml`로 전체 MSA를 실행한 경우에는
`product-service`가 호스트의 `8082` 포트로 노출되므로 다음 명령을 사용한다.
`-e`와 `-o`를 함께 지정하면 테스트 종료 후 HTML 리포트도 자동 생성된다.

```powershell
# product-service 디렉터리에서 실행한다.

New-Item -ItemType Directory -Force test-results | Out-Null

jmeter -n `
  -t performance-test/timedeal/jmeter/concurrency-test.jmx `
  -JproductHost=localhost `
  -JproductPort=8082 `
  -JtimeDealId=11111111-1111-4111-8111-111111111111 `
  -l test-results/concurrency-before.jtl `
  -j test-results/concurrency-before.log `
  -e `
  -o test-results/concurrency-before-report
```

실행 결과:

```text
test-results/concurrency-before.jtl
test-results/concurrency-before.log
test-results/concurrency-before-report/index.html
```

`-l`로 지정한 JTL 파일과 `-o`로 지정한 리포트 폴더가 이미 존재하면
JMeter가 덮어쓰지 않고 실패할 수 있다. 재실행할 때는
`concurrency-run-2.jtl`, `concurrency-run-2-report`처럼 다른 이름을 사용한다.

동일한 동시성 테스트를 다시 실행하려면 DB 시드뿐 아니라 Redis stock key도
초기화해야 한다. 루트 프로젝트에서 시드를 실행한 후 기존 Redis key를 삭제하고
`product-service`를 재시작한다.

```powershell
# 저장소 루트에서 실행한다.

docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' `
  < product-service/performance-test/timedeal/data/time-deal-seed.sql

docker compose exec redis redis-cli DEL `
  timedeal:stock:11111111-1111-4111-8111-111111111111:11111111-1111-4111-8111-111111111112

docker compose restart product-service
```

Redis key 삭제 명령은 실제 stock ID에 맞춰 사용한다. 동시성 fixture의 stock ID는
`11111111-1111-4111-8111-111111111112`이다.

목적:
재고 정합성 및 초과 판매 검증

JTL 기반 HTML Report 생성:

```bash
jmeter -g test-results/concurrency-before.jtl \
  -o test-results/concurrency-before-report
```

생성된 `test-results/concurrency-before-report/index.html`에서 Response Time Percentiles의 P95/P99를 확인한다. `jmeter.log`는 실행 과정 로그이므로 P95/P99 산출용 결과 파일로 사용하지 않는다.

## 2. Load Test
`performance-test/timedeal/jmeter/load-test.jmx`

- Threads: 100
- Ramp-up: 60초
- Loop: Forever
- Duration: 360초
- Constant Throughput Timer: 3,000 samples/minute = 50 RPS
- 측정 구간: Ramp-up 이후 약 5분
- 사용자 ID: 요청마다 `__UUID()`로 새로 생성
- 주문 ID: 요청마다 `__UUID()`로 새로 생성

요청 대상:

`POST http://localhost:8080/api/v1/internal/time-deals/{timeDealId}/purchases`

측정:

- Throughput (TPS)
- Average response time
- P95 / P99
- Error Rate

목표:

- 예상 피크 부하인 50 RPS를 일정하게 처리하는지 확인
- Average, P95/P99, 기술 오류율, CPU, DB·Redis, Connection Pool의 안정성 확인
- 목표 부하에서 문제가 발생하면 병목을 분석하고 동일 조건으로 재측정

재고 설정:

- 약 18,000건의 요청을 성공시키려면 초기 재고가 전체 예상 요청 수보다 충분히 커야 한다. 현재 seed는 여유를 두고 100,000개를 설정한다.
- 초기 재고를 100개로 두면 약 100건 성공 후 대부분의 요청이 재고 부족으로 실패하므로 Avg/Throughput/Success Rate 측정이 왜곡된다. 재고 정합성 검증은 별도의 동시성 테스트에서 수행한다.
- 재고 정합성과 초과 판매 검증은 `concurrency-test.jmx`에서 초기 재고 100개로 별도 수행한다.

100개의 Thread가 60초에 걸쳐 투입되고, Timer가 전체 Thread Group의 처리량을 분당 3,000건으로 조절한다. 전체 실행 중 약 18,000건이 처리되며, 실제 완료 건수는 응답시간과 실행 경계에 따라 달라질 수 있다. 요청마다 사용자 UUID를 새로 생성하므로 이를 실제 사용자 100명의 누적 구매량으로 해석하지 않는다.

실행 예시:

```bash
jmeter -n -t performance-test/timedeal/jmeter/load-test.jmx \
  -JproductHost=localhost \
  -JproductPort=8082 \
  -JtimeDealId=22222222-2222-4222-8222-222222222222 \
  -l test-results/load-50rps-baseline.jtl \
  -j test-results/load-50rps-baseline.log \
  -e \
  -o test-results/load-50rps-baseline-report
```

목적:

정합성 검증보다 예상 피크 부하인 50 RPS를 360초 동안 유지할 때의 Average Response Time, Throughput, Success Rate, P95/P99를 측정한다. 측정 결과로 병목을 찾고 개선한 뒤 동일 조건으로 재측정한다.

실행 결과:

```text
test-results/load-50rps-baseline.jtl
test-results/load-50rps-baseline.log
test-results/load-50rps-baseline-report/index.html
```

생성된 HTML Report에서 Average, Throughput, Success/Errors, P95/P99를 확인한다. JTL 파일과 Report 출력 디렉터리가 이미 존재하면 다른 실행 이름을 사용한다.

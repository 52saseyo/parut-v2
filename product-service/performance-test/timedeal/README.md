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

### Redis 재고 초기화

`time-deal-seed.sql`은 PostgreSQL만 초기화한다. Redis 재고 키는 별도로
초기화해야 하며, product-service가 실행 중이어도 아래 명령으로 처리할 수 있다.
Redis의 stock key가 없으면 재고 선점 Lua Script가
`STOCK_NOT_INITIALIZED`를 반환하므로, `SET`까지 실행해야 한다.

아래 명령은 로컬에서 Redis를 product-service 성능 테스트 전용으로 사용하는
경우에만 실행한다. `FLUSHDB`는 현재 Redis 논리 DB의 모든 키를 삭제하므로
예약 키, restore 멱등성 키, 스케줄 키도 함께 삭제된다.

```powershell
# 저장소 루트에서 실행한다.

# 1) DB fixture를 초기화한다.
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' `
  < product-service/performance-test/timedeal/data/time-deal-seed.sql

# 2) 로컬 테스트용 Redis의 기존 키를 모두 삭제한다.
docker compose exec redis redis-cli FLUSHDB

# 3) Load/Stress Test 대상 재고를 DB seed 값과 동일하게 설정한다.
docker compose exec redis redis-cli SET `
  timedeal:stock:22222222-2222-4222-8222-222222222222:22222222-2222-4222-8222-222222222223 `
  100000

# 4) Redis 재고 값을 확인한다. 100000이 출력되어야 한다.
docker compose exec redis redis-cli GET `
  timedeal:stock:22222222-2222-4222-8222-222222222222:22222222-2222-4222-8222-222222222223
```

동시성 테스트를 초기화할 때는 마지막 두 명령의 ID와 수량을 다음 값으로
바꾼다.

```text
timeDealId: 11111111-1111-4111-8111-111111111111
stockId:    11111111-1111-4111-8111-111111111112
quantity:   100
```

`FLUSHDB`를 사용할 수 없는 공유 Redis라면 전체 삭제 대신 대상 stock key만
`SET`으로 덮어쓰고, 테스트 전용 Redis DB 또는 별도 key prefix를 사용하는 것이
안전하다. Redis 또는 product-service를 매번 재시작할 필요는 없다. 다만
애플리케이션의 시작 시 초기화 로직은 누락된 키를 애플리케이션 기동 시점에만
보정하므로, 실행 중인 애플리케이션에서 `FLUSHDB` 후에는 위의 `SET` 명령을
직접 실행해야 한다.

### 초기화와 애플리케이션 재시작을 분리하는 이유

DB와 Redis를 초기화하는 목적은 이전 테스트의 구매 이력, 차감 재고, 예약 키,
restore 멱등성 키가 다음 테스트 결과에 섞이지 않도록 모든 테스트를 동일한
데이터 상태에서 시작하기 위해서다. 반면 product-service를 매번 재시작하지
않는 것은 애플리케이션을 반드시 Hot 상태로 유지해야 한다는 뜻이 아니라,
JVM 클래스 로딩·JIT 컴파일·Hikari 커넥션 생성 등 시작 직후의 Cold 상태를
실제 측정값에 섞지 않기 위해서다.

따라서 기본 측정 절차는 다음과 같다.

```text
애플리케이션 실행 및 정상 상태 확인
→ 필요하면 짧은 워밍업
→ DB seed로 구매·재고 상태 초기화
→ Redis key 및 테스트 부가 키 초기화
→ 동일한 애플리케이션 상태에서 성능 테스트 실행
```

이 방식은 데이터는 매번 동일하게 만들면서도 런타임 상태는 일관되게 유지한다.
Cold Start 성능 자체를 측정하려는 테스트라면 별도 시나리오로 애플리케이션을
재시작하고, 모든 실행에서 동일한 재시작·대기 조건을 적용해야 한다.

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

### Load Test에서 Threads를 100개로 설정한 이유

`Threads: 100`은 실제 사용자 100명을 의미하는 고정된 요구사항이 아니라,
JMeter가 목표 처리량 50 RPS를 안정적으로 발생시키기 위한 가상 작업자 수다.
Constant Throughput Timer의 `3,000 samples/minute`는 100개 Thread 전체의 합산
목표이며, Thread 하나마다 3,000건을 보내는 설정이 아니다.

필요한 최소 동시 작업자 수는 대략 다음과 같이 계산할 수 있다.

```text
필요 Thread 수 ≈ 목표 RPS × 예상 응답시간(초)
```

예를 들어 50 RPS에서 평균 응답시간이 0.5초라면 이론적으로 약 25개,
P99가 0.8초라면 약 40개의 동시 작업자가 필요하다. 100개는 응답시간이
일시적으로 증가하거나 요청이 겹치는 상황에서도 JMeter Thread 부족으로
실제 처리량이 낮아지는 것을 방지하기 위한 여유값이다.

따라서 100개는 서버의 Tomcat Thread 수나 DB 커넥션 수가 아니며, 반드시
100이어야 하는 값도 아니다. 실제 목표 50 RPS가 달성되고 JMeter 자체가
병목이 아니라면 유지할 수 있다. 반대로 Thread 수가 부족해 목표 처리량에
도달하지 못하면 더 늘려야 한다. Thread 수를 늘려도 Timer의 전체 목표는
3,000 samples/minute로 유지되므로, 충분한 Thread가 있는 범위에서는
실제 목표 RPS가 바뀌지 않는다.

이 Load Test는 3,000명의 서로 다른 사용자를 직접 재현하는 테스트가 아니다.
100개 Thread가 반복 요청하여 50 RPS를 360초 동안 유지하는 처리 용량 검증이다.
3,000명의 사용자가 1분 안에 각각 한 번 요청하는 사용자 피크 시나리오는
별도의 `3,000 Threads / Loop 1` 테스트로 분리해야 한다.

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

## 3. Stress Test

최종 Stress Test는 Thread 기반 최대 처리량 측정 방식으로 진행한다. RPS를 일정하게
주입하는 것이 아니라 동시 Thread를 단계적으로 늘리면서 실제 처리량이 증가하는지,
어느 시점부터 P95/P99·Hikari Pending이 악화되는지를 확인한다.

### 최종 채택 방식: Thread 기반 최대 처리량 테스트

- JMX: `performance-test/timedeal/jmeter/stress/stress-max-throughput-10threads.jmx`
- 비교 대상: `stress-max-throughput-10threads.jmx`, `stress-max-throughput-25threads.jmx`, `stress-max-throughput-50threads.jmx`, `stress-max-throughput-100threads.jmx`
- 설정: 10초 Ramp-up, 90초 실행, Loop Forever
- Constant Throughput Timer: 사용하지 않음
- 측정값: 실제 Throughput, 평균 응답시간, P95/P99, 오류율, CPU·JVM·Hikari 지표
- 실행 전 DB seed와 Redis 재고 키를 초기화하고, 애플리케이션은 재시작하지 않는다.

상세 실행 방법과 명령어는 아래 `Thread 기반 최대 처리량 테스트` 절에 정리했다.

### 실험 기록: RPS 기반 Stress Test (experimental)

아래 JMX들은 RPS 기반 Stress 방식을 검토하며 사용한 실험용 파일이다. 최종
Stress Test에는 사용하지 않고, 지정 도착률 주입 방식과 부하 생성기 한계를 비교할
필요가 있을 때 참고용으로 보관한다.

`performance-test/timedeal/jmeter/stress/experimental/rps-based/stress-discovery.jmx`

> `stress/experimental/rps-based`에는 RPS 기반 Stress 방식을 검토하며 사용한 실험용 JMX를 보관한다. 최종 Stress Test는 `stress-max-throughput-*threads.jmx`를 사용하는 Thread 기반 방식으로 진행한다.

RPS 기반 실험에서는 목표 도착률을 단계적으로 높여 현재 환경의 처리량과
부하 생성기 측정 한계를 확인했다.

| 단계 | 목표 처리량 | 유지 시간 | 시작 시점 |
|---|---:|---:|---:|
| 기준 | 50 RPS | 90초 | 0초 |
| 1단계 | 75 RPS | 90초 | 90초 |
| 2단계 | 100 RPS | 90초 | 180초 |
| 3단계 | 150 RPS | 90초 | 270초 |
| 4단계 | 200 RPS | 90초 | 360초 |

각 단계는 10초 Ramp-up으로 시작하고, 전체 실행 시간은 약 7분 30초다. 단계별 목표값은 Constant Throughput Timer의 samples/minute로 변환되어 JMX에 저장되어 있다.

- 50 RPS: 3,000 samples/minute
- 75 RPS: 4,500 samples/minute
- 100 RPS: 6,000 samples/minute
- 150 RPS: 9,000 samples/minute
- 200 RPS: 12,000 samples/minute

각 단계에 500 Thread를 둔 것은 JMeter 부하 발생기가 먼저 한계에 도달하지 않도록 여유를 둔 것이다. 서버의 Tomcat Thread나 Hikari 커넥션 수를 500개로 변경하는 설정이 아니다.

실행 전에는 기존 Load Test와 동일하게 `time-deal-seed.sql`을 실행하고, `22222222-2222-4222-8222-222222222222`의 Redis stock key를 초기화한다. 전체 단계에서 약 51,750건의 요청이 발생하므로 초기 재고 100,000개를 사용한다.

Windows PowerShell 실행 예시:

```powershell
jmeter -n `
  -t performance-test/timedeal/jmeter/stress/experimental/rps-based/stress-discovery.jmx `
  -JproductHost=localhost `
  -JproductPort=8082 `
  -JtimeDealId=22222222-2222-4222-8222-222222222222 `
  -l test-results/stress-discovery-baseline.jtl `
  -j test-results/stress-discovery-baseline.log `
  -e `
  -o test-results/stress-discovery-baseline-report
```

결과는 한 개의 JTL에 저장되므로 Grafana 시간대와 JMeter 시작 시각을 기준으로 단계별로 나누어 분석한다. 각 단계에서 실제 처리량, 평균·P95·P99, 기술 오류율, CPU·JVM·Hikari Pending, DB·Redis 대기를 기록한다. 처리량이 더 이상 증가하지 않거나 P99·오류율·Pending이 지속적으로 악화되면 해당 단계에서 테스트를 종료해도 된다.

### RPS 기반 Stress 독립 재측정 파일

Discovery 실행에서 병목 구간을 확인한 뒤, 특정 RPS만 동일 조건으로 다시 측정할 때 사용한다. 각 파일은 500 Thread, 10초 Ramp-up, 90초 유지 조건으로 해당 RPS 하나만 실행한다.

독립 재측정 파일은 실행마다 DB seed와 Redis 초기화를 먼저 수행한다. 이전
실행의 재고 차감이나 예약 상태가 남아 있으면 같은 150 RPS라도 재고 부족,
Redis 키 누락, 만료·복구 작업의 영향을 받아 결과를 공정하게 비교할 수 없기
때문이다. 이때 애플리케이션과 Redis 컨테이너는 재시작하지 않고, 위 초기화
명령으로 데이터 상태만 되돌린다.

| 목표 부하 | 독립 실행 파일 |
|---:|---|
| 50 RPS | `jmeter/stress/experimental/rps-based/stress-50rps.jmx` |
| 100 RPS | `jmeter/stress/experimental/rps-based/stress-100rps.jmx` |
| 150 RPS | `jmeter/stress/experimental/rps-based/stress-150rps.jmx` |
| 200 RPS | `jmeter/stress/experimental/rps-based/stress-200rps.jmx` |
| 250 RPS | `jmeter/stress/experimental/rps-based/stress-250rps.jmx` |
| 300 RPS | `jmeter/stress/experimental/rps-based/stress-300rps.jmx` |
| 400 RPS | `jmeter/stress/experimental/rps-based/stress-400rps.jmx` |

예를 들어 Discovery에서 150 RPS까지 안정적이고 200 RPS에서 P99가 급증했다면,
`stress-150rps.jmx`와 `stress-200rps.jmx`를 각각 초기화 후 실행해 독립 결과로
비교한다. Discovery용 JMX와 독립 측정용 JMX의 결과 파일·HTML 리포트도 서로
다른 이름을 사용한다.

독립 실행 예시는 다음과 같다. 아래 명령은 `product-service` 디렉터리에서
PowerShell로 실행한다.

```powershell
# 250 RPS
jmeter -n `
  -t performance-test/timedeal/jmeter/stress/experimental/rps-based/stress-250rps.jmx `
  -JproductHost=localhost `
  -JproductPort=8082 `
  -JtimeDealId=22222222-2222-4222-8222-222222222222 `
  -l test-results/stress-250rps-run1.jtl `
  -j test-results/stress-250rps-run1.log `
  -e `
  -o test-results/stress-250rps-run1-report
```

300·400 RPS는 다음처럼 파일명과 결과명만 바꿔 실행한다.

```powershell
# 300 RPS
jmeter -n `
  -t performance-test/timedeal/jmeter/stress/experimental/rps-based/stress-300rps.jmx `
  -JproductHost=localhost `
  -JproductPort=8082 `
  -JtimeDealId=22222222-2222-4222-8222-222222222222 `
  -l test-results/stress-300rps-run1.jtl `
  -j test-results/stress-300rps-run1.log `
  -e `
  -o test-results/stress-300rps-run1-report

# 400 RPS
jmeter -n `
  -t performance-test/timedeal/jmeter/stress/experimental/rps-based/stress-400rps.jmx `
  -JproductHost=localhost `
  -JproductPort=8082 `
  -JtimeDealId=22222222-2222-4222-8222-222222222222 `
  -l test-results/stress-400rps-run2.jtl `
  -j test-results/stress-400rps-run2.log `
  -e `
  -o test-results/stress-400rps-run2-report
```

각 독립 실행 전에는 반드시 DB와 Redis를 초기화하고, 기존 JTL 파일과 HTML
리포트 폴더가 있으면 `run2`, `run3`처럼 다른 결과명을 사용한다.

### 400 RPS 실행 판단 기준

현재 300 RPS 독립 실행에서 오류율 0%, P99 약 56ms로 확인되어 다음 단계로
400 RPS를 실행한다. `stress-400rps.jmx`는 500 Thread, 10초 Ramp-up, 300초
유지, 목표 처리량 400 RPS로 구성되어 있다. 90초 실행에서 실제 처리량이
약 333 RPS로 제한된 원인이 짧은 실행 구간인지 부하 생성기 한계인지 구분하기
위해 400 RPS만 300초로 확장했다.

400 RPS 실행 결과는 다음 순서로 판단한다.

1. JMeter HTML Report에서 실제 처리량, 평균 응답시간, P95, P99, 최대 응답시간,
   오류율을 확인한다.
2. Grafana에서 실행 시간대의 product-service Hikari Active/Pending/Timeout,
   Tomcat Busy Thread, JVM Heap·GC, Process CPU를 함께 확인한다.
3. 5xx·timeout이 지속되거나 Hikari Pending·Tomcat Busy Thread가 계속
   누적되면 400 RPS를 해당 환경의 병목 후보 구간으로 기록한다.
4. 오류 없이 지표가 회복되면 400 RPS까지는 안정적으로 처리한 것으로 기록하고,
   필요할 때 450 또는 500 RPS를 다음 독립 단계로 추가한다.

JMeter의 실제 처리량은 Constant Throughput Timer의 목표값과 실행 경계·Ramp-up
영향 때문에 목표값보다 높거나 낮게 측정될 수 있다. 따라서 결과 기록에는 목표
처리량과 실제 Report 처리량을 구분해서 작성한다.

### Thread 기반 최대 처리량 테스트 상세 설정 및 실행 방법: 10 → 25 → 50 → 100 Thread

RPS 목표를 정확하게 주입하는 테스트와 별도로, Constant Throughput Timer를
제거하고 가상 Thread가 응답을 받는 즉시 다음 요청을 보내도록 하여
실제 처리량을 측정한다. 이 테스트는 “400 RPS를 정확히 발생시킬 수 있는가?”가
아니라 “동시성을 늘릴 때 서비스가 실제로 어느 정도 처리량을 내는가?”를 확인한다.

10 Thread는 낮은 동시성의 기준값으로 사용하고, 이후 25·50·100 Thread를 별도 실행한다.
각 단계에서 Thread 증가에 따른 처리량 증가, 정체, P95/P99 악화,
오류율 변화를 비교할 수 있다. Thread 수가 많다고 항상 처리량이 증가하는 것은
아니며, DB·Redis·CPU·커넥션 풀이 포화되면 처리량은 정체되거나 오히려 감소할 수
있다.

설정:

- JMX: `jmeter/stress/stress-max-throughput-{10,25,50,100}threads.jmx`
- Threads: 10, 25, 50, 100
- Ramp-up: 10초
- Duration: 90초
- Loop: Forever
- Constant Throughput Timer: 사용하지 않음
- 측정값: 실제 Throughput, 평균 응답시간, P95/P99, 오류율, CPU·JVM·Hikari 지표

실행 전에는 Load/Stress Test와 동일하게 DB seed와 Redis stock key를 초기화한다.
초기화는 이전 실행의 구매 이력과 차감 재고가 다음 결과에 섞이지 않게 하기 위한
것이며, 애플리케이션을 재시작하지 않는 것은 Cold Start 영향을 측정값에 섞지
않기 위해서다.

```powershell
jmeter -n `
  -t performance-test/timedeal/jmeter/stress/stress-max-throughput-10threads.jmx `
  -JproductHost=localhost `
  -JproductPort=8082 `
  -JtimeDealId=22222222-2222-4222-8222-222222222222 `
  -l test-results/stress-max-throughput-10threads-run1.jtl `
  -j test-results/stress-max-throughput-10threads-run1.log `
  -e `
  -o test-results/stress-max-throughput-10threads-run1-report
```

10·25·50·100 Thread 결과는 기존 RPS 기반 Stress Test를 대체하지 않는다. RPS 기반 테스트는
지정 도착률을 검증하고, Thread 기반 테스트는 동시성 증가에 따른 최대 처리량과
포화 지점을 탐색한다. 두 결과를 구분해서 기록해야 JMeter의 요청 생성 한계와
product-service의 실제 처리 한계를 혼동하지 않을 수 있다.

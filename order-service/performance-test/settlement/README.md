# Settlement Performance Test

## 시나리오 안내

| 목적 | 진입점과 환경 | 파일 |
| --- | --- | --- |
| 관리자 완료의 처리시간, 부분 성공과 동시성 | 기존 관리자 API, 개발용 DB | 아래 시나리오와 `data/settlement-seed.sql` |
| 자동 완료의 청크 처리와 성능 비교 | perf 스케줄러 매분 실행, 전용 DB | [실행법과 결과](SETTLEMENT_COMPLETION.md) |

각 SQL은 해당 시나리오의 데이터를 변경한다. 아래 개발용 환경 설정과 perf 전용 환경 설정을 구분해서 사용한다.

## 환경

- Java 21
- PostgreSQL 17
- JMeter 5.6.3 설치
- 기존 로컬 Docker의 `postgres`, `order-service` 실행 및 Flyway 적용 완료
- 테스트 대상 commit/tag

## 공통 준비

아래 명령은 저장소 루트에서 시작해 순서대로 실행한다. 첫 명령이 `order-service` 디렉터리로 이동한다. 로컬 DB는 `parut`, API 포트는 `8083`, DB 포트는 `5433`이다.

본인 PC의 개발용 Docker 환경에서 실행한다. 중요한 데이터가 있거나 다른 사람이 함께 사용하는 DB에서는 실행하지 않는다. `postgres`와 `order-service`가 모두 healthy여야 진행한다.

```bash
cd order-service
docker ps --filter name=postgres --filter name=order-service
```

- API: `PATCH http://localhost:8083/api/v1/settlements/complete` (Order 직접 호출, Gateway 제외)
- `data/settlement-seed.sql`은 테스트 전용 `created_by`와 `seller_id`가 모두 일치하는 정산만 초기화한다.
- 시드는 두 테스트의 데이터를 함께 초기화한다. 완료 요청은 DB 상태를 변경하므로 각 테스트 실행 직전에 다시 적용하고, 실행 중에는 적용하지 않는다.
- SQL은 컨테이너의 psql로 실행한다. 시드 결과가 아래 기대값과 다르면 진행하지 않는다.

| 테스트 | 시드 컬럼별 기대값 |
|---|---|
| 처리시간 | `fixture_count=1891`, `ready_pending_count=1891`, `mismatch_count=0` |
| 정합성 | `total=945`, `ready=920`, `future=25`, `mismatch_count=0` |

결과는 Git에서 제외되는 `test-results/settlement` 아래에 실행 시각별로 저장한다.

```bash
run_dir="test-results/settlement/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_dir"
```

## 1. 요청 크기별 처리시간

`jmeter/settlement-completion-test.jmx`

### 시나리오와 설정

- Threads: 1
- 요청 크기: 1건, 10건, 50건
- 워밍업: 크기별 1회
- 측정: 크기별 30회
- 총 요청 수: 93회, JTL 표본 수: 93개
- 데이터: 서로 다른 완료 가능한 PENDING 정산 1,891건

### 실행 예시

```bash
docker exec -i postgres sh -c \
  'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d parut' \
  < performance-test/settlement/data/settlement-seed.sql

jmeter -n -t performance-test/settlement/jmeter/settlement-completion-test.jmx \
  -JorderHost=localhost -JorderPort=8083 \
  -l "$run_dir/completion.jtl" \
  -j "$run_dir/completion.log"
```

### DB 확인

```bash
docker exec -i postgres sh -c \
  'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d parut' <<'SQL'
-- 기대값: 전체/완료 1891건, 대기/불일치 0건. 불일치가 있으면 검증 실패다.
SELECT COUNT(*) AS fixture_count,
       COUNT(*) FILTER (WHERE status = 'COMPLETED') AS completed_count,
       COUNT(*) FILTER (WHERE status = 'PENDING') AS pending_count,
       COUNT(*) FILTER (WHERE
           status IS DISTINCT FROM 'COMPLETED'
           OR version IS DISTINCT FROM 1
           OR settled_at IS NULL OR eligible_at IS NULL
           OR settled_at < eligible_at
           OR processed_by IS DISTINCT FROM '00000000-0000-4000-8000-000000000099'::uuid
       ) AS mismatch_count
FROM order_schema.p_settlements
WHERE created_by = 'performance-test'
  AND seller_id = '00000000-0000-4000-8000-000000000001';
SQL
```

| fixture_count | completed_count | pending_count | mismatch_count |
|---|---|---|---|
| 1891 | 1891 | 0 | 0 |

### 확인 기준

- 응답은 전체 SUCCESS, JTL은 모든 표본이 `success=true`여야 한다. DB 조회 결과는 위 기대값과 일치해야 한다.
- 워밍업을 제외한 측정 라벨별 30개 표본의 평균, 중앙값, p95와 오류율을 비교한다.
- 탐색 측정이며 워밍업 1회로 안정 상태를 보장하지 않는다. p95는 참고값이고 운영 합격 기준은 아니다.

## 2. 부분 성공 및 동시성

`jmeter/settlement-integrity-test.jmx`

### 시나리오와 설정

| 시나리오 | Threads × Loop | 요청 수 |
|---|---|---|
| 부분 성공: 정상 25건 + 시각 미도래 25건 (partial) | 1 × 1 | 1 |
| 관리자 2명: 동일한 50건 (same2) | 2 × 5 | 10 |
| 관리자 2명: 1~50번 / 30~79번 (overlap2) | 2 × 5 | 10 |
| 관리자 10명: 동일한 50건 (same10) | 10 × 5 | 50 |

- 총 요청 수: 71회, JTL 표본 수: 71개
- 데이터: 고유 정산 945건
- 네 그룹은 순차 실행하고, 동시성 그룹 내부는 Synchronizing Timer로 함께 출발한다.
- 그룹 이름과 설정을 유지하고 전체 그룹을 실행한다. 타이머 대기 만료 경고가 발생하면 동시 출발 검증 결과로 사용하지 않는다.

### 실행 예시

```bash
docker exec -i postgres sh -c \
  'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d parut' \
  < performance-test/settlement/data/settlement-seed.sql

jmeter -n -t performance-test/settlement/jmeter/settlement-integrity-test.jmx \
  -JorderHost=localhost -JorderPort=8083 \
  -JintegrityResponseFile="$run_dir/integrity-responses.xml" \
  -l "$run_dir/integrity.jtl" \
  -j "$run_dir/integrity.log"
```

### DB 확인

```bash
docker exec -i postgres sh -c \
  'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d parut' <<'SQL'
-- 기대값: partial 50/25/25, same2 250/250/0,
-- overlap2 395/395/0, same10 250/250/0. mismatch_count는 모두 0.
WITH results AS (
    SELECT *, CASE
        WHEN id BETWEEN 'a0000000-0000-4000-8000-000000000001'::uuid AND 'a0000000-0000-4000-8000-000000000050'::uuid THEN 'partial'
        WHEN id BETWEEN 'a0000000-0000-4000-8000-000000001001'::uuid AND 'a0000000-0000-4000-8000-000000001250'::uuid THEN 'same2'
        WHEN id BETWEEN 'a0000000-0000-4000-8000-000000002001'::uuid AND 'a0000000-0000-4000-8000-000000002395'::uuid THEN 'overlap2'
        WHEN id BETWEEN 'a0000000-0000-4000-8000-000000003001'::uuid AND 'a0000000-0000-4000-8000-000000003250'::uuid THEN 'same10'
        ELSE 'unexpected' END AS scenario
    FROM order_schema.p_settlements
    WHERE created_by = 'settlement-jmeter-integrity'
      AND seller_id = '00000000-0000-4000-8000-000000000002'
)
SELECT scenario, COUNT(*) AS total,
       COUNT(*) FILTER (WHERE status = 'COMPLETED') AS completed_count,
       COUNT(*) FILTER (WHERE status = 'PENDING') AS pending_count,
       COUNT(*) FILTER (WHERE CASE
           WHEN scenario = 'partial' AND right(id::text, 1) IN ('0', '2', '4', '6', '8')
           THEN status IS DISTINCT FROM 'PENDING' OR version IS DISTINCT FROM 0
                OR settled_at IS NOT NULL OR processed_by IS NOT NULL
                OR eligible_at IS NULL OR eligible_at <= CURRENT_TIMESTAMP
           ELSE status IS DISTINCT FROM 'COMPLETED' OR version IS DISTINCT FROM 1
                OR settled_at IS NULL OR processed_by IS NULL OR eligible_at IS NULL
                OR settled_at < eligible_at OR scenario = 'unexpected'
           END) AS mismatch_count
FROM results
GROUP BY scenario ORDER BY scenario;

-- 응답의 ID별 성공/실패와 실제 DB 상태를 대조할 목록이다.
SELECT id, status, version, order_item_id, processed_by, settled_at
FROM order_schema.p_settlements
WHERE created_by = 'settlement-jmeter-integrity'
  AND seller_id = '00000000-0000-4000-8000-000000000002'
ORDER BY id;
SQL
```

| scenario | total | completed_count | pending_count | mismatch_count |
|---|---|---|---|---|
| partial | 50 | 25 | 25 | 0 |
| same2 | 250 | 250 | 0 | 0 |
| overlap2 | 395 | 395 | 0 | 0 |
| same10 | 250 | 250 | 0 | 0 |

### 확인 기준

- JTL은 라벨별 요청 수가 위 시나리오 표와 같고, 모든 표본이 `success=true`여야 한다. DB 조회 결과는 위 기대값과 일치해야 한다.
- HTTP 응답 검사는 항목 수/ID, 성공 정보와 부분 성공 대상을 확인한다. 예상된 항목별 FAILED는 테스트 오류가 아니다.
- 응답 XML은 수동 대조용이다. JMeter GUI의 View Results Tree에 `integrity-responses.xml`을 불러와 요청별 응답과 `X-User-Id` 헤더를 확인한다.
- 부분 성공은 성공한 25개 ID가 COMPLETED/version=1, 실패한 25개 ID가 PENDING/version=0인지 DB 목록과 대조한다.
- 동시 요청은 같은 ID가 SUCCESS로 두 번 반환되지 않았는지 확인하고, 성공 응답의 ID/주문상품/관리자/완료 시각을 DB 목록과 대조한다. DB 완료 건수와 version만으로 성공 응답의 중복 여부를 판단하지 않는다.
- 수동 대조한 ID와 범위를 남기고, 표본만 확인했다면 전수 검증으로 기록하지 않는다.
- 실제 낙관적 락 충돌은 Order 로그에서, 데드락은 DB 카운터의 실행 전후 차이로 별도 확인한다.

## 공통 확인 사항

- 측정 환경과 실행 구간을 기록하고, 측정 중에는 다른 API 호출과 개발 작업을 줄인다. 공유/운영 서비스로 접속 대상을 변경하지 않는다.
- Grafana는 기존 SpringBoot APM Dashboard에서 Application=`order`, Instance=`order-service:8080`을 선택한다. 5초 수집 간격 때문에 짧은 연결 사용은 관측하지 못할 수 있다.
- 정확한 요청 수와 처리시간은 JMeter, 업무 결과는 SQL 조회와 응답/DB 수동 대조로 확인한다. SQL 결과는 JTL에 반영되지 않으며, 기대값과 다르거나 응답/DB 불일치가 있으면 검증 실패로 기록한다.
- 재실행할 때는 새 결과 폴더를 만들고 시드를 다시 적용한다. 명령이나 검증이 실패하면 다음 단계로 진행하지 않는다.

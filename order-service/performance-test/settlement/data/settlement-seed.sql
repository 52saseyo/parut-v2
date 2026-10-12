-- Settlement performance-test fixtures
-- 실행 대상: 로컬 PostgreSQL parut의 order_schema, Flyway 적용 완료 후 실행한다.
-- 두 시나리오의 전용 데이터를 함께 초기화한다. 테스트 실행 중에는 재실행하지 않는다.
-- 정산 생성 흐름은 포함하지 않는다.

BEGIN;

-- 1. 요청 크기별 처리시간: 워밍업 포함 93회 요청, 완료 가능한 정산 1,891건
-- 이전 실행에서 남은 테스트 정산을 먼저 정리한다.
DELETE FROM order_schema.p_settlements
WHERE created_by = 'performance-test'
  AND seller_id = '00000000-0000-4000-8000-000000000001';

INSERT INTO order_schema.p_settlements (
    id, order_item_id, seller_id, status, sales_amount, settlement_amount,
    eligible_at, settled_at, processed_by, version, created_at, created_by, updated_at, updated_by
)
SELECT ('00000000-0000-4000-8000-' || lpad(fixture_no::text, 12, '0'))::uuid,
       gen_random_uuid(), '00000000-0000-4000-8000-000000000001', 'PENDING', 10000, 10000,
       CURRENT_TIMESTAMP - INTERVAL '1 minute', NULL, NULL, 0,
       CURRENT_TIMESTAMP, 'performance-test', NULL, NULL
FROM generate_series(1, 1891) AS fixtures(fixture_no);

-- 2. 부분 성공 및 동시성: 정산 945건, 시각 미도래 25건
DELETE FROM order_schema.p_settlements
WHERE created_by = 'settlement-jmeter-integrity'
  AND seller_id = '00000000-0000-4000-8000-000000000002';

WITH fixtures AS (
    -- partial 50건, same2 250건, overlap2 395건, same10 250건
    SELECT n AS fixture_no FROM generate_series(1, 50) AS s(n)
    UNION ALL SELECT n FROM generate_series(1001, 1250) AS s(n)
    UNION ALL SELECT n FROM generate_series(2001, 2395) AS s(n)
    UNION ALL SELECT n FROM generate_series(3001, 3250) AS s(n)
)
INSERT INTO order_schema.p_settlements (
    id, order_item_id, seller_id, status, sales_amount, settlement_amount,
    eligible_at, settled_at, processed_by, version, created_at, created_by, updated_at, updated_by
)
SELECT ('a0000000-0000-4000-8000-' || lpad(fixture_no::text, 12, '0'))::uuid,
       gen_random_uuid(), '00000000-0000-4000-8000-000000000002', 'PENDING', 10000, 10000,
       -- 부분 성공 대상의 짝수 ID 25건만 미래 시각으로 두어 업무 실패를 유도한다.
       CASE WHEN fixture_no BETWEEN 1 AND 50 AND fixture_no % 2 = 0
            THEN CURRENT_TIMESTAMP + INTERVAL '1 day'
            ELSE CURRENT_TIMESTAMP - INTERVAL '1 minute' END,
       NULL, NULL, 0, CURRENT_TIMESTAMP, 'settlement-jmeter-integrity', NULL, NULL
FROM fixtures;

COMMIT;

-- 준비 결과: fixture_count=1891, ready_pending_count=1891, mismatch_count=0.
-- 상태/version/완료 정보가 초기값과 다르면 불일치로 표시한다. 결과값으로 통과 여부를 판단한다.
SELECT COUNT(*) AS fixture_count,
       COUNT(*) FILTER (WHERE status = 'PENDING' AND eligible_at <= CURRENT_TIMESTAMP) AS ready_pending_count,
       COUNT(*) FILTER (WHERE
           status IS DISTINCT FROM 'PENDING' OR version IS DISTINCT FROM 0
           OR eligible_at IS NULL OR eligible_at > CURRENT_TIMESTAMP
           OR settled_at IS NOT NULL OR processed_by IS NOT NULL
       ) AS mismatch_count
FROM order_schema.p_settlements
WHERE created_by = 'performance-test'
  AND seller_id = '00000000-0000-4000-8000-000000000001';

-- 준비 결과: total=945, ready=920, future=25, mismatch_count=0.
-- 시각 미도래 25건도 PENDING/version=0이어야 하며, 완료 정보는 없어야 한다.
SELECT COUNT(*) AS total,
       COUNT(*) FILTER (WHERE eligible_at <= CURRENT_TIMESTAMP) AS ready,
       COUNT(*) FILTER (WHERE eligible_at > CURRENT_TIMESTAMP) AS future,
       COUNT(*) FILTER (WHERE
           status IS DISTINCT FROM 'PENDING' OR version IS DISTINCT FROM 0
           OR eligible_at IS NULL OR settled_at IS NOT NULL OR processed_by IS NOT NULL
           OR sales_amount IS DISTINCT FROM 10000 OR settlement_amount IS DISTINCT FROM 10000
       ) AS mismatch_count
FROM order_schema.p_settlements
WHERE created_by = 'settlement-jmeter-integrity'
  AND seller_id = '00000000-0000-4000-8000-000000000002';

-- Product Stock 만료 스케줄러 간섭 테스트 fixture
-- 실행 대상: product-service DB / PostgreSQL
-- 선행 조건: product-stock-load-seed.sql을 한 번 실행해 분산 상품 200개, 핫 상품 1개 재고가 있어야 한다.
--
-- 실행 예시 (product-service 디렉터리, cmd):
--   docker exec -i postgres psql -U parut -d parut -v target=distributed < performance-test\product_stock\data\product-stock-scheduler-interference-seed.sql
--   docker exec -i postgres psql -U parut -d parut -v target=hot < performance-test\product_stock\data\product-stock-scheduler-interference-seed.sql
-- seed가 끝나면 바로 spike-test.jmx를 같은 대상(-JspikeTarget)으로 시작한다.
--
-- 변수
--   target               : distributed(기본) = 분산 상품 200개에 골고루 / hot = 핫 상품 1개에 모두
--   expired_count        : 만료 대상 예약 수 (기본 3,600 = 이벤트 피크 30 TPS × 600초 × 이탈률 20%)
--   history_logs         : 과거 이력 이벤트 로그 수 (기본 400,000)
--   expire_after_seconds : seed가 끝난 시점부터 만료까지 걸리는 시간 (기본 180초)
--                          JMeter를 바로 시작하면 Spike 피크(3~4분)에 만료되고, 1분 주기 스케줄러가 피크 중에 처리를 시작한다.
--
-- 만료 대상 예약은 created_by = 'performance-test'로 넣어 JMeter가 만든 예약과 구분한다.

\set ON_ERROR_STOP on
\if :{?target}
\else
\set target distributed
\endif
\if :{?expired_count}
\else
\set expired_count 3600
\endif
\if :{?history_logs}
\else
\set history_logs 400000
\endif
\if :{?expire_after_seconds}
\else
\set expire_after_seconds 180
\endif

\echo 'target =' :target ', expired_count =' :expired_count ', history_logs =' :history_logs ', expire_after_seconds =' :expire_after_seconds

SELECT :'target' IN ('distributed', 'hot') AS valid_target \gset
\if :valid_target
\else
\echo 'target은 distributed 또는 hot 이어야 합니다.'
\quit
\endif

-- 1. 이전 성능 테스트 데이터 정리 (분산 상품, 핫 상품, 이력 재고)
--    참조하는 로그를 먼저 지운 뒤 이 세션만 외래키 트리거를 끄고 예약을 지운다. (superuser 필요)
BEGIN;
SET LOCAL session_replication_role = replica;

CREATE TEMP TABLE perf_stock_ids ON COMMIT DROP AS
SELECT id
FROM product_schema.p_product_stocks
WHERE id::text LIKE '77777777-7777-4777-8777-%'
   OR id = '55555555-5555-4555-8555-555555555556'
   OR id = '88888888-8888-4888-8888-888888888888';

DELETE FROM product_schema.p_product_stock_event_logs e
USING product_schema.p_product_stock_reservations r
WHERE e.reservation_id = r.id
  AND r.stock_id IN (SELECT id FROM perf_stock_ids);

DELETE FROM product_schema.p_product_stock_reservations
WHERE stock_id IN (SELECT id FROM perf_stock_ids);

DELETE FROM product_schema.p_product_stocks
WHERE id = '88888888-8888-4888-8888-888888888888';

COMMIT;

VACUUM FULL ANALYZE product_schema.p_product_stock_event_logs;
VACUUM FULL ANALYZE product_schema.p_product_stock_reservations;

-- 2. 테스트 데이터 생성
BEGIN;

-- 2-1. 과거 이력: CONFIRMED 예약 + RESERVE / CONFIRM 로그 (이력 재고 88888888-...)
INSERT INTO product_schema.p_product_stocks (
    id, product_id, total_quantity, available_quantity,
    low_stock_threshold, status, version, created_at, created_by
)
VALUES (
    '88888888-8888-4888-8888-888888888888',
    '88888888-8888-4888-8888-888888888887',
    1000000000, 1000000000, 10, 'AVAILABLE', 0, CURRENT_TIMESTAMP, 'performance-test'
);

CREATE TEMP TABLE history ON COMMIT DROP AS
SELECT gen_random_uuid() AS reservation_id,
       gen_random_uuid() AS order_item_id,
       CURRENT_TIMESTAMP - (n || ' seconds')::interval AS created_at
FROM generate_series(1, :history_logs / 2) AS n;

INSERT INTO product_schema.p_product_stock_reservations (
    id, stock_id, order_id, quantity, status, expires_at,
    version, failure_count, created_at, created_by
)
SELECT reservation_id, '88888888-8888-4888-8888-888888888888', gen_random_uuid(), 1, 'CONFIRMED',
       created_at + INTERVAL '30 minutes', 1, 0, created_at, 'performance-test'
FROM history;

INSERT INTO product_schema.p_product_stock_event_logs (
    id, reservation_id, order_item_id, event_type, processed_at, created_at, created_by
)
SELECT gen_random_uuid(), reservation_id, order_item_id, event_type, created_at, created_at, 'performance-test'
FROM history
CROSS JOIN (VALUES ('RESERVE'), ('CONFIRM')) AS t(event_type);

-- 2-2. 만료 대상: RESERVED 예약 + RESERVE 로그
--      만료 시각은 일단 1시간 뒤로 넣어 두고, 마지막 단계에서 "seed 종료 시점 + expire_after_seconds"로 바꾼다.
CREATE TEMP TABLE expired ON COMMIT DROP AS
SELECT gen_random_uuid() AS reservation_id,
       gen_random_uuid() AS order_item_id,
       CASE
           WHEN :'target' = 'hot' THEN '55555555-5555-4555-8555-555555555556'::uuid
           ELSE ('77777777-7777-4777-8777-' || lpad((((n - 1) % 200) + 1)::text, 12, '0'))::uuid
       END AS stock_id
FROM generate_series(1, :expired_count) AS n;

INSERT INTO product_schema.p_product_stock_reservations (
    id, stock_id, order_id, quantity, status, expires_at,
    version, failure_count, created_at, created_by
)
SELECT reservation_id, stock_id, gen_random_uuid(), 1, 'RESERVED',
       CURRENT_TIMESTAMP + INTERVAL '1 hour', 0, 0,
       CURRENT_TIMESTAMP - INTERVAL '30 minutes', 'performance-test'
FROM expired;

INSERT INTO product_schema.p_product_stock_event_logs (
    id, reservation_id, order_item_id, event_type, processed_at, created_at, created_by
)
SELECT gen_random_uuid(), reservation_id, order_item_id, 'RESERVE',
       CURRENT_TIMESTAMP - INTERVAL '30 minutes', CURRENT_TIMESTAMP - INTERVAL '30 minutes', 'performance-test'
FROM expired;

-- 2-3. 재고 초기화: 분산 상품 초기 100,000개, 핫 상품 초기 1,000,000개에서 만료 대상 선점 수량만큼 available을 줄인다.
UPDATE product_schema.p_product_stocks s
SET total_quantity     = e.initial_total,
    available_quantity = e.initial_total - e.cnt,
    status             = 'AVAILABLE',
    version            = 0,
    updated_at         = CURRENT_TIMESTAMP,
    updated_by         = 'performance-test'
FROM (
    SELECT st.id,
           CASE WHEN st.id = '55555555-5555-4555-8555-555555555556' THEN 1000000 ELSE 100000 END AS initial_total,
           (SELECT COUNT(*) FROM expired x WHERE x.stock_id = st.id) AS cnt
    FROM product_schema.p_product_stocks st
    WHERE st.id::text LIKE '77777777-7777-4777-8777-%'
       OR st.id = '55555555-5555-4555-8555-555555555556'
) e
WHERE s.id = e.id;

COMMIT;

ANALYZE product_schema.p_product_stock_event_logs;
ANALYZE product_schema.p_product_stock_reservations;

-- 3. 만료 시각 확정: 지금부터 expire_after_seconds 뒤
UPDATE product_schema.p_product_stock_reservations
SET expires_at = clock_timestamp() + (:expire_after_seconds || ' seconds')::interval
WHERE created_by = 'performance-test'
  AND status = 'RESERVED'
  AND stock_id <> '88888888-8888-4888-8888-888888888888';

SELECT :'target'                                                          AS target,
       COUNT(*)                                                           AS expired_reservations,
       to_char(MIN(expires_at) AT TIME ZONE 'Asia/Seoul', 'HH24:MI:SS')   AS expires_at_kst,
       (SELECT COUNT(*) FROM product_schema.p_product_stock_event_logs)   AS event_logs_total
FROM product_schema.p_product_stock_reservations
WHERE created_by = 'performance-test'
  AND status = 'RESERVED'
  AND stock_id <> '88888888-8888-4888-8888-888888888888';

\echo '>>> 지금 바로 spike-test.jmx를 같은 대상(-JspikeTarget)으로 시작하세요.'

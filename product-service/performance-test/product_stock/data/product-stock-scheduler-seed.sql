-- Product Stock 만료 스케줄러 대량 처리 테스트 fixture
-- 실행 대상: product-service DB / PostgreSQL
-- 선행 조건: product-stock-load-seed.sql을 한 번 실행해 분산 상품 200개 재고가 있어야 한다.
--
-- 실행 예시 (product-service 디렉터리, cmd):
--   docker exec -i postgres psql -U parut -d parut -v expired_count=3600 -v history_logs=400000 < performance-test\product_stock\data\product-stock-scheduler-seed.sql
--
-- 변수
--   expired_count : 만료 대상 예약 수 (기본 3,600 = 이벤트 피크 30 TPS × 600초 × 이탈률 20%)
--                   분산 상품 200개에 골고루 나눈다. 상태 RESERVED, expires_at은 과거 시각
--   history_logs  : 과거 이력 이벤트 로그 수 (기본 40,000)
--                   CONFIRMED 예약 history_logs / 2건과 RESERVE + CONFIRM 로그를 만든다.
--                   이력은 별도 재고(88888888-...)에 붙여 분산 상품 정합성 검증과 섞이지 않게 한다.
--
-- 스케줄러는 seed가 커밋되는 즉시 다음 주기에 만료 예약을 처리하기 시작한다.
-- 이전 실행의 만료 처리가 끝난 뒤(verify의 reserved = 0) 다시 실행한다.

\set ON_ERROR_STOP on
\if :{?expired_count}
\else
\set expired_count 3600
\endif
\if :{?history_logs}
\else
\set history_logs 40000
\endif

\echo 'expired_count =' :expired_count ', history_logs =' :history_logs

-- 1. 이전 성능 테스트 데이터 정리
--    분산 상품, 핫 상품, 이력 재고에 걸린 이벤트 로그·예약을 지운다.
--    이벤트 로그 reservation_id에 인덱스가 없으면 예약 1건 삭제마다 외래키 확인으로 로그 전체를 읽어
--    매우 느려진다. 참조하는 로그를 먼저 지운 뒤 이 세션만 외래키 트리거를 끄고 예약을 지운다. (superuser 필요)
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

-- 지운 행이 테이블에 남아 있으면 Seq Scan이 빈 공간까지 읽어 측정이 부풀려지므로 테이블을 다시 쓴다.
VACUUM FULL ANALYZE product_schema.p_product_stock_event_logs;
VACUUM FULL ANALYZE product_schema.p_product_stock_reservations;

-- 2. 테스트 데이터 생성
BEGIN;

-- 2-1. 과거 이력: CONFIRMED 예약 + RESERVE / CONFIRM 로그
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

-- 2-2. 만료 대상: 분산 상품 200개에 골고루 나눈 RESERVED 예약 + RESERVE 로그
CREATE TEMP TABLE expired ON COMMIT DROP AS
SELECT gen_random_uuid() AS reservation_id,
       gen_random_uuid() AS order_item_id,
       ('77777777-7777-4777-8777-' || lpad((((n - 1) % 200) + 1)::text, 12, '0'))::uuid AS stock_id
FROM generate_series(1, :expired_count) AS n;

INSERT INTO product_schema.p_product_stock_reservations (
    id, stock_id, order_id, quantity, status, expires_at,
    version, failure_count, created_at, created_by
)
SELECT reservation_id, stock_id, gen_random_uuid(), 1, 'RESERVED',
       CURRENT_TIMESTAMP - INTERVAL '1 minute', 0, 0,
       CURRENT_TIMESTAMP - INTERVAL '31 minutes', 'performance-test'
FROM expired;

INSERT INTO product_schema.p_product_stock_event_logs (
    id, reservation_id, order_item_id, event_type, processed_at, created_at, created_by
)
SELECT gen_random_uuid(), reservation_id, order_item_id, 'RESERVE',
       CURRENT_TIMESTAMP - INTERVAL '31 minutes', CURRENT_TIMESTAMP - INTERVAL '31 minutes', 'performance-test'
FROM expired;

-- 2-3. 분산 상품 재고: 초기 100,000개에서 만료 대상 선점 수량만큼 available을 줄인다.
UPDATE product_schema.p_product_stocks s
SET total_quantity     = 100000,
    available_quantity = 100000 - COALESCE(e.cnt, 0),
    status             = 'AVAILABLE',
    version            = 0,
    updated_at         = CURRENT_TIMESTAMP,
    updated_by         = 'performance-test'
FROM (
    SELECT id, (SELECT COUNT(*) FROM expired x WHERE x.stock_id = st.id) AS cnt
    FROM product_schema.p_product_stocks st
    WHERE st.id::text LIKE '77777777-7777-4777-8777-%'
) e
WHERE s.id = e.id;

COMMIT;

ANALYZE product_schema.p_product_stock_event_logs;
ANALYZE product_schema.p_product_stock_reservations;

SELECT (SELECT COUNT(*) FROM product_schema.p_product_stock_event_logs) AS event_logs_total,
       (SELECT COUNT(*) FROM product_schema.p_product_stock_reservations
        WHERE status = 'RESERVED' AND expires_at < CURRENT_TIMESTAMP)  AS expired_reserved;

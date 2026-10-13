-- Product Stock Load / Spike / Stress test fixtures
-- 실행 대상: product-service DB / PostgreSQL
-- Flyway migration이 완료된 뒤 실행한다.
-- 기존 product-stock-seed.sql(Concurrency / UpdateStock Conflict fixture)과 ID 대역이 겹치지 않으므로 서로 독립적으로 재실행할 수 있다.
--
-- 분산 상품: 200개 (productId 66666666-6666-4666-8666-000000000001 ~ 000000000200), 상품당 재고 100,000개
--            → data/load-products.csv와 같은 ID 목록이다.
-- 핫 상품  : 1개 (productId 55555555-5555-4555-8555-555555555555), 재고 1,000,000개
-- 재고를 넉넉하게 잡아 PRODUCT_STOCK_SHORTAGE가 섞이지 않고 순수하게 처리 성능만 관찰되도록 한다.

BEGIN;

-- 이전 실행에서 남은 예약·이벤트로그·재고 변동 로그를 먼저 정리한다.
CREATE TEMP TABLE perf_load_stock_ids ON COMMIT DROP AS
SELECT id
FROM product_schema.p_product_stocks
WHERE id::text LIKE '77777777-7777-4777-8777-%'
   OR id = '55555555-5555-4555-8555-555555555556';

DELETE FROM product_schema.p_product_stock_event_logs
WHERE reservation_id IN (
    SELECT id FROM product_schema.p_product_stock_reservations
    WHERE stock_id IN (SELECT id FROM perf_load_stock_ids)
);

DELETE FROM product_schema.p_product_stock_allocation_logs
WHERE stock_id IN (SELECT id FROM perf_load_stock_ids);

DELETE FROM product_schema.p_product_stock_reservations
WHERE stock_id IN (SELECT id FROM perf_load_stock_ids);

DELETE FROM product_schema.p_product_stocks
WHERE id IN (SELECT id FROM perf_load_stock_ids);

DELETE FROM product_schema.p_products
WHERE id::text LIKE '66666666-6666-4666-8666-%'
   OR id = '55555555-5555-4555-8555-555555555555';

-- 분산 상품 200개
INSERT INTO product_schema.p_products (
    id, seller_id, category, name, description, price, appearance_type,
    origin, harvest_date, sale_unit, unit_quantity, status,
    created_at, created_by
)
SELECT
    ('66666666-6666-4666-8666-' || lpad(n::text, 12, '0'))::uuid,
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
    'VEGETABLE',
    'Load Test Product ' || n,
    'JMeter Load/Spike/Stress 분산 상품 fixture',
    10000, 'NORMAL',
    '국내산', CURRENT_DATE, 'EA', 1,
    'ON_SALE',
    CURRENT_TIMESTAMP, 'performance-test'
FROM generate_series(1, 200) AS n;

INSERT INTO product_schema.p_product_stocks (
    id, product_id, total_quantity, available_quantity,
    low_stock_threshold, status, version, created_at, created_by
)
SELECT
    ('77777777-7777-4777-8777-' || lpad(n::text, 12, '0'))::uuid,
    ('66666666-6666-4666-8666-' || lpad(n::text, 12, '0'))::uuid,
    100000, 100000, 10, 'AVAILABLE', 0, CURRENT_TIMESTAMP, 'performance-test'
FROM generate_series(1, 200) AS n;

-- 핫 상품 1개 (Spike/Stress에서 -JspikeTarget=hot / -JstressTarget=hot 으로 사용)
INSERT INTO product_schema.p_products (
    id, seller_id, category, name, description, price, appearance_type,
    origin, harvest_date, sale_unit, unit_quantity, status,
    created_at, created_by
)
VALUES (
    '55555555-5555-4555-8555-555555555555',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
    'VEGETABLE',
    'Hot Product',
    'JMeter Spike/Stress 단일 row 집중 fixture',
    10000, 'NORMAL',
    '국내산', CURRENT_DATE, 'EA', 1,
    'ON_SALE',
    CURRENT_TIMESTAMP, 'performance-test'
);

INSERT INTO product_schema.p_product_stocks (
    id, product_id, total_quantity, available_quantity,
    low_stock_threshold, status, version, created_at, created_by
)
VALUES (
    '55555555-5555-4555-8555-555555555556',
    '55555555-5555-4555-8555-555555555555',
    1000000, 1000000, 10, 'AVAILABLE', 0, CURRENT_TIMESTAMP, 'performance-test'
);

COMMIT;

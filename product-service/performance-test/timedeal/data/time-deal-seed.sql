-- TimeDeal performance-test fixtures
-- 실행 대상: product-service DB / PostgreSQL
-- Flyway migration이 완료된 뒤 실행한다.
-- 두 fixture는 성능 테스트 전용 ID를 사용하므로 다른 타임딜 데이터와 분리한다.

BEGIN;

DELETE FROM product_schema.p_outbox_events;

-- 이전 실행에서 남은 구매 이력과 재고를 먼저 정리한다.
DELETE FROM product_schema.p_time_deal_purchases
WHERE time_deal_id IN (
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
);

DELETE FROM product_schema.p_time_deal_stocks
WHERE time_deal_id IN (
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
);

DELETE FROM product_schema.p_time_deals
WHERE id IN (
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
);

-- Concurrency Test fixture
-- 초기 재고 100개, 500개 요청 중 재고 정합성만 검증한다.
INSERT INTO product_schema.p_time_deals (
    id, seller_id, product_id, original_price, deal_price, discount_rate,
    start_at, end_at, max_purchase_quantity, status, name, description,
    product_grade, origin, harvested_date, created_at, created_by
)
VALUES (
    '11111111-1111-4111-8111-111111111111',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    NULL,
    10000, 9000, 10.00,
    CURRENT_TIMESTAMP - INTERVAL '1 hour',
    CURRENT_TIMESTAMP + INTERVAL '1 day',
    100, 'ACTIVE',
    'Concurrency Test TimeDeal',
    'JMeter 500개 동시 구매 선점 검증용 fixture',
    'NORMAL', '국내산', CURRENT_DATE,
    CURRENT_TIMESTAMP, 'performance-test'
);

INSERT INTO product_schema.p_time_deal_stocks (
    id, time_deal_id, available_quantity, reserved_quantity, sold_quantity,
    low_stock_threshold, created_at, created_by
)
VALUES (
    '11111111-1111-4111-8111-111111111112',
    '11111111-1111-4111-8111-111111111111',
    100, 0, 0, 10, CURRENT_TIMESTAMP, 'performance-test'
);

-- Load Test fixture
-- 1,000개 배치 요청을 재고 부족 없이 측정할 수 있도록 여유 재고를 준비한다.
INSERT INTO product_schema.p_time_deals (
    id, seller_id, product_id, original_price, deal_price, discount_rate,
    start_at, end_at, max_purchase_quantity, status, name, description,
    product_grade, origin, harvested_date, created_at, created_by
)
VALUES (
    '22222222-2222-4222-8222-222222222222',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    NULL,
    10000, 9000, 10.00,
    CURRENT_TIMESTAMP - INTERVAL '1 hour',
    CURRENT_TIMESTAMP + INTERVAL '1 day',
    100000, 'ACTIVE',
    'Load Test TimeDeal',
    'JMeter 100 Thread 5분 부하 검증용 fixture',
    'NORMAL', '국내산', CURRENT_DATE,
    CURRENT_TIMESTAMP, 'performance-test'
);

INSERT INTO product_schema.p_time_deal_stocks (
    id, time_deal_id, available_quantity, reserved_quantity, sold_quantity,
    low_stock_threshold, created_at, created_by
)
VALUES (
    '22222222-2222-4222-8222-222222222223',
    '22222222-2222-4222-8222-222222222222',
    100000, 0, 0, 1000, CURRENT_TIMESTAMP, 'performance-test'
);

COMMIT;

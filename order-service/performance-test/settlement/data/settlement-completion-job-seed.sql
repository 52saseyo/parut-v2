-- 정산 자동 완료 측정용 데이터. 로컬 docker 공용 DB(parut)에서 실행하며 실험 데이터는 ID 규칙과 created_by로 구분한다.
-- 측정 한 회차마다 한 번 실행한다. 이전 실험 정산을 모두 지우고 완료 대기(PENDING) 정산 10,000건을 한꺼번에 새로 만든다.
-- 건수를 바꾸려면 generate_series의 10000 네 곳을 함께 바꾼다.
-- 스케줄러의 "정산 자동완료 종료" 로그를 확인한 직후에 실행한다.
-- CLI(저장소 루트): docker exec -i postgres psql -X -v ON_ERROR_STOP=1 -U parut -d parut < order-service/performance-test/settlement/data/settlement-completion-job-seed.sql

-- 실행 전 확인: 로컬 parut DB가 아니면 실행하지 않는다.
SELECT current_database();

BEGIN;

-- 이전 실험의 정산을 상태와 관계없이 지운다. 실험 외 데이터는 created_by와 ID 규칙으로 제외한다.
DELETE FROM order_schema.p_settlements s
USING order_schema.p_order_items i
WHERE s.order_item_id = i.id
  AND i.created_by = 'settlement-completion-perf'
  AND i.id::text LIKE 'f3000000-0000-4000-8000-%';

-- 정산 입력용 주문 10,000건. 같은 ID가 이미 있으면 그대로 둔다.
INSERT INTO order_schema.p_orders (
    id, order_no, user_id, order_type, order_status,
    total_product_amount, total_delivery_fee, total_payment_amount,
    recipient_name, recipient_phone, zip_code, address_base,
    paid_at, idempotency_key, created_by
)
SELECT ('f1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       'PERF-COMPLETION-' || n,
       'f9000000-0000-4000-8000-000000000001'::uuid,
       'NORMAL', 'PAID', 10000, 0, 10000,
       '테스트 수령인', '01000000000', '00000', '테스트 주소',
       CURRENT_TIMESTAMP - INTERVAL '2 days', 'settlement-completion-' || n,
       'settlement-completion-perf'
FROM generate_series(1, 10000) AS fixtures(n)
ON CONFLICT (id) DO NOTHING;

-- 주문 1건당 배송 그룹 1건. 같은 ID가 이미 있으면 그대로 둔다.
INSERT INTO order_schema.p_order_delivery_groups (
    id, order_id, seller_id, group_status, product_amount, delivery_fee, created_by
)
SELECT ('f2000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('f1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       'f9000000-0000-4000-8000-000000000002'::uuid,
       'DELIVERED', 10000, 0, 'settlement-completion-perf'
FROM generate_series(1, 10000) AS fixtures(n)
ON CONFLICT (id) DO NOTHING;

-- 재사용한 배송 그룹 중 예전 워밍업용 판매자로 남은 행을 측정 판매자로 맞춘다.
-- 아래 정산 INSERT가 배송 그룹의 판매자를 읽으므로 그보다 먼저 실행한다.
UPDATE order_schema.p_order_delivery_groups
SET seller_id = 'f9000000-0000-4000-8000-000000000002'::uuid
WHERE created_by = 'settlement-completion-perf'
  AND id::text LIKE 'f2000000-0000-4000-8000-%'
  AND seller_id <> 'f9000000-0000-4000-8000-000000000002'::uuid;

-- 주문 1건당 구매확정된 주문상품 1건. confirmed_at이 정산 가능 시각(eligible_at)이 된다. 같은 ID가 이미 있으면 그대로 둔다.
INSERT INTO order_schema.p_order_items (
    id, order_id, delivery_group_id, product_id, product_name,
    appearance_type, origin, harvest_date, sale_unit, unit_quantity,
    original_price, unit_price, quantity, item_status, confirmed_at, created_by
)
SELECT ('f3000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('f1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('f2000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('f8000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       '정산 완료 성능 측정 상품', 'NORMAL', '국내산', DATE '2026-09-01',
       'EA', 1.00, 10000, 10000, 1, 'CONFIRMED',
       CURRENT_TIMESTAMP - INTERVAL '1 minute', 'settlement-completion-perf'
FROM generate_series(1, 10000) AS fixtures(n)
ON CONFLICT (id) DO NOTHING;

-- 주문상품 1건당 완료 대기 정산 1건, 모두 10,000건을 실행할 때마다 새로 만든다.
INSERT INTO order_schema.p_settlements (
    id, order_item_id, seller_id, status, sales_amount, settlement_amount,
    eligible_at, version, created_at, created_by
)
SELECT ('f4000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       i.id, g.seller_id, 'PENDING', i.unit_price * i.quantity, i.unit_price * i.quantity,
       i.confirmed_at, 0, CURRENT_TIMESTAMP, 'settlement-completion-perf'
FROM generate_series(1, 10000) AS fixtures(n)
JOIN order_schema.p_order_items i
  ON i.id = ('f3000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
JOIN order_schema.p_order_delivery_groups g ON g.id = i.delivery_group_id;

COMMIT;

-- 결과 확인. 기대 값: experiment_ready = 10000, total_ready = 10000.
-- 스케줄러는 판매자 구분 없이 처리하므로 total_ready가 더 크면 다른 정산이 함께 처리된다. 이 경우 측정하지 않는다.
SELECT count(*) FILTER (WHERE created_by = 'settlement-completion-perf') AS experiment_ready,
       count(*) AS total_ready
FROM order_schema.p_settlements
WHERE status = 'PENDING' AND eligible_at <= now();

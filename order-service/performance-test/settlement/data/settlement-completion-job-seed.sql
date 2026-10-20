-- psql -X -v ON_ERROR_STOP=1 -v count=1000 -f settlement-completion-job-seed.sql
-- 전용 DB에서 완료 실험 정산만 초기화한다. 주문 픽스처와 기존 생성 검증 데이터는 보존한다.
BEGIN;
SELECT set_config('perf.measurement_count', :'count', true);
DO $$
BEGIN
    IF current_database() <> 'settlement_perf' THEN
        RAISE EXCEPTION '전용 settlement_perf DB에서만 실행할 수 있습니다.';
    END IF;
    IF current_setting('perf.measurement_count')::int NOT IN (10, 1000, 10000) THEN
        RAISE EXCEPTION '측정 건수는 10, 1000, 10000 중 하나여야 합니다.';
    END IF;
END;
$$;

DELETE FROM order_schema.p_settlements s
USING order_schema.p_order_items i
WHERE s.order_item_id = i.id
  AND i.created_by = 'settlement-completion-perf'
  AND i.id::text LIKE 'f3000000-0000-4000-8000-%';
-- 앞의 100건은 워밍업 전용이며 나머지를 측정에 사용한다.
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
FROM generate_series(1, :count + 100) AS fixtures(n)
ON CONFLICT (id) DO NOTHING;

INSERT INTO order_schema.p_order_delivery_groups (
    id, order_id, seller_id, group_status, product_amount, delivery_fee, created_by
)
SELECT ('f2000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('f1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       CASE WHEN n <= 100 THEN 'f9000000-0000-4000-8000-000000000003'::uuid
            ELSE 'f9000000-0000-4000-8000-000000000002'::uuid END,
       'DELIVERED', 10000, 0, 'settlement-completion-perf'
FROM generate_series(1, :count + 100) AS fixtures(n)
ON CONFLICT (id) DO NOTHING;

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
FROM generate_series(1, :count + 100) AS fixtures(n)
ON CONFLICT (id) DO NOTHING;
INSERT INTO order_schema.p_settlements (
    id, order_item_id, seller_id, status, sales_amount, settlement_amount,
    eligible_at, version, created_at, created_by
)
SELECT ('f4000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       i.id, g.seller_id, 'PENDING', i.unit_price * i.quantity, i.unit_price * i.quantity,
       i.confirmed_at, 0, CURRENT_TIMESTAMP, 'settlement-completion-perf'
FROM generate_series(1, :count + 100) AS fixtures(n)
JOIN order_schema.p_order_items i
  ON i.id = ('f3000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
JOIN order_schema.p_order_delivery_groups g ON g.id = i.delivery_group_id;
COMMIT;

-- 이전 주문 픽스처가 남아 있어도 이번 완료 작업에 사용할 정산만 집계한다.
WITH targets (purpose, seller_id, expected_count) AS (
    VALUES ('measurement', 'f9000000-0000-4000-8000-000000000002'::uuid, :count),
           ('warmup', 'f9000000-0000-4000-8000-000000000003'::uuid, 100)
)
SELECT t.purpose, t.expected_count,
       count(s.id) AS input_count,
       count(s.id) FILTER (
           WHERE s.status = 'PENDING' AND s.eligible_at <= CURRENT_TIMESTAMP
       ) AS ready_count
FROM targets t
LEFT JOIN order_schema.p_settlements s
  ON s.seller_id = t.seller_id
 AND s.created_by = 'settlement-completion-perf'
GROUP BY t.purpose, t.expected_count
ORDER BY t.purpose;

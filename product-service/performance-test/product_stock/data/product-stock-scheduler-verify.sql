-- Product Stock 만료 스케줄러 대량 처리 테스트 결과 확인
-- 스케줄러가 만료 예약 처리를 끝낸 뒤(reserved = 0) 실행한다.
--
--   docker exec -i postgres psql -U parut -d parut < performance-test\product_stock\data\product-stock-scheduler-verify.sql

-- 1. 처리 결과와 정합성 (분산 상품 200개, 초기 재고 100,000)
--    total - available     = RESERVED + EXPIRATION_FAILED 수량 합  → held_mismatch_rows 0
--    100,000 - total       = CONFIRMED 수량 합                     → confirmed_mismatch_rows 0
WITH stocks AS (
    SELECT id, total_quantity, available_quantity
    FROM product_schema.p_product_stocks
    WHERE id::text LIKE '77777777-7777-4777-8777-%'
),
reservation_sum AS (
    SELECT stock_id,
           COALESCE(SUM(quantity) FILTER (WHERE status IN ('RESERVED', 'EXPIRATION_FAILED')), 0) AS held_qty,
           COALESCE(SUM(quantity) FILTER (WHERE status = 'CONFIRMED'), 0)                        AS confirmed_qty
    FROM product_schema.p_product_stock_reservations
    WHERE stock_id IN (SELECT id FROM stocks)
    GROUP BY stock_id
)
SELECT COUNT(*) FILTER (WHERE (s.total_quantity - s.available_quantity) <> COALESCE(r.held_qty, 0)) AS held_mismatch_rows,
       COUNT(*) FILTER (WHERE (100000 - s.total_quantity) <> COALESCE(r.confirmed_qty, 0))         AS confirmed_mismatch_rows,
       (SELECT COUNT(*) FROM product_schema.p_product_stock_reservations
        WHERE stock_id IN (SELECT id FROM stocks) AND status = 'RESERVED')                         AS reserved,
       (SELECT COUNT(*) FROM product_schema.p_product_stock_reservations
        WHERE stock_id IN (SELECT id FROM stocks) AND status = 'EXPIRED')                          AS expired,
       (SELECT COUNT(*) FROM product_schema.p_product_stock_reservations
        WHERE stock_id IN (SELECT id FROM stocks) AND status = 'EXPIRATION_FAILED')                AS expiration_failed,
       (SELECT COUNT(*) FROM product_schema.p_product_stock_reservations
        WHERE stock_id IN (SELECT id FROM stocks) AND failure_count > 0)                           AS failure_count_over_0
FROM stocks s
LEFT JOIN reservation_sum r ON r.stock_id = s.id;

-- 2. 처리 시간과 만료 지연
--    총 처리 시간 = 첫 EXPIRED 처리 ~ 마지막 EXPIRED 처리 (updated_at)
--    만료 지연    = 처리 시각 - expires_at (스케줄러 주기 대기 + 처리 순서 대기)
SELECT COUNT(*)                                                               AS expired,
       MIN(updated_at)                                                        AS first_processed_at,
       MAX(updated_at)                                                        AS last_processed_at,
       ROUND(EXTRACT(EPOCH FROM MAX(updated_at) - MIN(updated_at))::numeric, 1) AS total_seconds,
       ROUND((EXTRACT(EPOCH FROM MAX(updated_at) - MIN(updated_at)) * 1000
              / NULLIF(COUNT(*) - 1, 0))::numeric, 2)                         AS ms_per_reservation,
       ROUND(EXTRACT(EPOCH FROM AVG(updated_at - expires_at))::numeric, 1)    AS avg_delay_seconds,
       ROUND(EXTRACT(EPOCH FROM MAX(updated_at - expires_at))::numeric, 1)    AS max_delay_seconds
FROM product_schema.p_product_stock_reservations
WHERE stock_id::text LIKE '77777777-7777-4777-8777-%'
  AND status = 'EXPIRED';

-- 3. 측정 조건 (이벤트 로그 양)
SELECT COUNT(*) AS event_logs_total
FROM product_schema.p_product_stock_event_logs;

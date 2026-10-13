-- Product Stock Load / Spike / Stress test 정합성 검증
-- 테스트 종료 후 product-service DB에서 실행한다.
--
-- 재고 상태 전이:
--   reserve : available -= q            (예약 RESERVED)
--   confirm : total     -= q            (예약 CONFIRMED)
--   restore / 만료 : available += q      (예약 CANCELLED / EXPIRED)
-- 따라서 재고 row마다 아래 두 식이 항상 성립해야 한다.
--   total - available            = RESERVED + EXPIRATION_FAILED 예약 수량 합
--   initial_total - total        = CONFIRMED 예약 수량 합
-- 결과의 mismatch 컬럼이 모두 0이면 정합성이 유지된 것이다.

WITH target_stocks AS (
    SELECT id, product_id, total_quantity, available_quantity,
           CASE WHEN id = '55555555-5555-4555-8555-555555555556' THEN 1000000 ELSE 100000 END AS initial_total
    FROM product_schema.p_product_stocks
    WHERE id::text LIKE '77777777-7777-4777-8777-%'
       OR id = '55555555-5555-4555-8555-555555555556'
),
reservation_sum AS (
    SELECT stock_id,
           COALESCE(SUM(quantity) FILTER (WHERE status IN ('RESERVED', 'EXPIRATION_FAILED')), 0) AS held_qty,
           COALESCE(SUM(quantity) FILTER (WHERE status = 'CONFIRMED'), 0)                        AS confirmed_qty,
           COUNT(*) FILTER (WHERE status = 'RESERVED')                                           AS reserved_cnt,
           COUNT(*) FILTER (WHERE status = 'CONFIRMED')                                          AS confirmed_cnt,
           COUNT(*) FILTER (WHERE status = 'CANCELLED')                                          AS cancelled_cnt,
           COUNT(*) FILTER (WHERE status = 'EXPIRED')                                            AS expired_cnt,
           COUNT(*) FILTER (WHERE status = 'EXPIRATION_FAILED')                                  AS expiration_failed_cnt
    FROM product_schema.p_product_stock_reservations
    WHERE stock_id IN (SELECT id FROM target_stocks)
    GROUP BY stock_id
),
per_stock AS (
    SELECT s.id,
           CASE WHEN s.id = '55555555-5555-4555-8555-555555555556' THEN 'HOT' ELSE 'DISTRIBUTED' END AS stock_group,
           (s.total_quantity - s.available_quantity) - COALESCE(r.held_qty, 0)   AS held_mismatch,
           (s.initial_total - s.total_quantity) - COALESCE(r.confirmed_qty, 0)   AS confirmed_mismatch,
           COALESCE(r.reserved_cnt, 0)          AS reserved_cnt,
           COALESCE(r.confirmed_cnt, 0)         AS confirmed_cnt,
           COALESCE(r.cancelled_cnt, 0)         AS cancelled_cnt,
           COALESCE(r.expired_cnt, 0)           AS expired_cnt,
           COALESCE(r.expiration_failed_cnt, 0) AS expiration_failed_cnt
    FROM target_stocks s
    LEFT JOIN reservation_sum r ON r.stock_id = s.id
)
SELECT stock_group,
       COUNT(*)                                    AS stock_rows,
       COUNT(*) FILTER (WHERE held_mismatch <> 0)  AS held_mismatch_rows,
       COUNT(*) FILTER (WHERE confirmed_mismatch <> 0) AS confirmed_mismatch_rows,
       SUM(reserved_cnt)          AS reserved,
       SUM(confirmed_cnt)         AS confirmed,
       SUM(cancelled_cnt)         AS cancelled,
       SUM(expired_cnt)           AS expired,
       SUM(expiration_failed_cnt) AS expiration_failed
FROM per_stock
GROUP BY stock_group
ORDER BY stock_group;

-- Product Stock 만료 스케줄러 간섭 테스트 결과 확인
-- JMeter Spike가 끝나고, seed로 넣은 만료 예약 처리가 끝난 뒤(seed_reserved = 0) 실행한다.
-- 실패한 예약은 다음 스케줄러 주기(1분)에 다시 시도하므로, seed_reserved가 0이 될 때까지 기다린다.
--
--   docker exec -i postgres psql -U parut -d parut < performance-test\product_stock\data\product-stock-scheduler-interference-verify.sql

-- 1. 정합성 (분산 상품 초기 100,000 / 핫 상품 초기 1,000,000)
--    JMeter가 만든 예약(RESERVED)과 seed 만료 예약을 모두 포함해 재고 row마다 아래 두 식이 성립해야 한다.
--    total - available       = RESERVED + EXPIRATION_FAILED 수량 합  → held_mismatch_rows 0
--    initial_total - total   = CONFIRMED 수량 합                     → confirmed_mismatch_rows 0
WITH target_stocks AS (
    SELECT id, total_quantity, available_quantity,
           CASE WHEN id = '55555555-5555-4555-8555-555555555556' THEN 1000000 ELSE 100000 END AS initial_total
    FROM product_schema.p_product_stocks
    WHERE id::text LIKE '77777777-7777-4777-8777-%'
       OR id = '55555555-5555-4555-8555-555555555556'
),
reservation_sum AS (
    SELECT stock_id,
           COALESCE(SUM(quantity) FILTER (WHERE status IN ('RESERVED', 'EXPIRATION_FAILED')), 0) AS held_qty,
           COALESCE(SUM(quantity) FILTER (WHERE status = 'CONFIRMED'), 0)                        AS confirmed_qty
    FROM product_schema.p_product_stock_reservations
    WHERE stock_id IN (SELECT id FROM target_stocks)
    GROUP BY stock_id
)
SELECT CASE WHEN s.id = '55555555-5555-4555-8555-555555555556' THEN 'HOT' ELSE 'DISTRIBUTED' END AS stock_group,
       COUNT(*)                                                                                  AS stock_rows,
       COUNT(*) FILTER (WHERE (s.total_quantity - s.available_quantity) <> COALESCE(r.held_qty, 0)) AS held_mismatch_rows,
       COUNT(*) FILTER (WHERE (s.initial_total - s.total_quantity) <> COALESCE(r.confirmed_qty, 0)) AS confirmed_mismatch_rows
FROM target_stocks s
LEFT JOIN reservation_sum r ON r.stock_id = s.id
GROUP BY 1
ORDER BY 1;

-- 2. seed로 넣은 만료 예약의 처리 결과
--    failure_count > 0      : 한 번 이상 실패했다가 다음 주기에 다시 시도한 예약 (낙관적 락 충돌 등)
--    EXPIRATION_FAILED      : 3번 실패해 격리된 예약 (재고가 복구되지 않음)
SELECT CASE WHEN stock_id = '55555555-5555-4555-8555-555555555556' THEN 'HOT' ELSE 'DISTRIBUTED' END AS stock_group,
       COUNT(*)                                                   AS seed_expired_target,
       COUNT(*) FILTER (WHERE status = 'RESERVED')                AS seed_reserved,
       COUNT(*) FILTER (WHERE status = 'EXPIRED')                 AS expired,
       COUNT(*) FILTER (WHERE status = 'EXPIRATION_FAILED')       AS expiration_failed,
       COUNT(*) FILTER (WHERE failure_count > 0)                  AS failure_count_over_0,
       COUNT(*) FILTER (WHERE failure_count = 1)                  AS failed_once,
       COUNT(*) FILTER (WHERE failure_count = 2)                  AS failed_twice,
       COUNT(*) FILTER (WHERE failure_count >= 3)                 AS failed_3_or_more
FROM product_schema.p_product_stock_reservations
WHERE created_by = 'performance-test'
  AND stock_id <> '88888888-8888-4888-8888-888888888888'
GROUP BY 1
ORDER BY 1;

-- 3. 처리 시각 (한국 시간)
--    처리 시작이 Spike 피크(JMeter 시작 후 3~4분) 안에 들어왔는지 확인한다.
SELECT to_char(MIN(expires_at) AT TIME ZONE 'Asia/Seoul', 'HH24:MI:SS')     AS expires_at_kst,
       to_char(MIN(updated_at) FILTER (WHERE status = 'EXPIRED') AT TIME ZONE 'Asia/Seoul', 'HH24:MI:SS') AS first_expired_kst,
       to_char(MAX(updated_at) FILTER (WHERE status = 'EXPIRED') AT TIME ZONE 'Asia/Seoul', 'HH24:MI:SS') AS last_expired_kst,
       ROUND(EXTRACT(EPOCH FROM MAX(updated_at) FILTER (WHERE status = 'EXPIRED')
                              - MIN(updated_at) FILTER (WHERE status = 'EXPIRED'))::numeric, 1)          AS total_seconds
FROM product_schema.p_product_stock_reservations
WHERE created_by = 'performance-test'
  AND stock_id <> '88888888-8888-4888-8888-888888888888';

-- 4. 분당 처리 건수 (재시도가 다음 주기로 넘어갔는지 확인)
SELECT to_char(date_trunc('minute', updated_at) AT TIME ZONE 'Asia/Seoul', 'HH24:MI') AS minute_kst,
       COUNT(*)                                                                      AS expired
FROM product_schema.p_product_stock_reservations
WHERE created_by = 'performance-test'
  AND stock_id <> '88888888-8888-4888-8888-888888888888'
  AND status = 'EXPIRED'
GROUP BY 1
ORDER BY 1;

-- 5. JMeter가 만든 예약 (참고: reserve 성공 건수와 일치해야 한다)
SELECT CASE WHEN stock_id = '55555555-5555-4555-8555-555555555556' THEN 'HOT' ELSE 'DISTRIBUTED' END AS stock_group,
       COUNT(*) AS jmeter_reserved
FROM product_schema.p_product_stock_reservations
WHERE created_by <> 'performance-test'
  AND (stock_id::text LIKE '77777777-7777-4777-8777-%' OR stock_id = '55555555-5555-4555-8555-555555555556')
GROUP BY 1
ORDER BY 1;

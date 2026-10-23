-- 만료 스케줄러가 예약 1건마다 실행하는 RESERVE 로그 조회의 실행 계획
-- (ProductStockEventLogRepository.findByReservationIdAndEventType)
-- seed 직후, 스케줄러가 처리하기 전에 실행한다. 인덱스 추가 전에는 Seq Scan, 추가 후에는 Index Scan이 나와야 한다.
--
--   docker exec -i postgres psql -U parut -d parut < performance-test\product_stock\data\product-stock-scheduler-explain.sql

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM product_schema.p_product_stock_event_logs
WHERE reservation_id = (
    SELECT id
    FROM product_schema.p_product_stock_reservations
    WHERE stock_id::text LIKE '77777777-7777-4777-8777-%'
    LIMIT 1
)
  AND event_type = 'RESERVE';

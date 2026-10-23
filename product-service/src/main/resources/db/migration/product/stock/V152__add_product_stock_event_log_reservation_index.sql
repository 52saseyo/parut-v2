CREATE INDEX idx_event_logs_reservation_type
    ON product_schema.p_product_stock_event_logs (reservation_id, event_type);

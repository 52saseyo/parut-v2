\set ON_ERROR_STOP on

WITH wal AS (
    SELECT wal_records,
           wal_fpi,
           wal_bytes,
           wal_buffers_full,
           wal_write,
           wal_sync,
           wal_write_time,
           wal_sync_time
    FROM pg_stat_wal
),
io AS (
    SELECT COALESCE(SUM(reads) FILTER (WHERE backend_type = 'client backend'), 0) AS client_reads,
           COALESCE(SUM(read_time) FILTER (WHERE backend_type = 'client backend'), 0) AS client_read_time_ms,
           COALESCE(SUM(writes) FILTER (WHERE backend_type = 'client backend'), 0) AS client_writes,
           COALESCE(SUM(write_time) FILTER (WHERE backend_type = 'client backend'), 0) AS client_write_time_ms,
           COALESCE(SUM(extends) FILTER (WHERE backend_type = 'client backend'), 0) AS client_extends,
           COALESCE(SUM(extend_time) FILTER (WHERE backend_type = 'client backend'), 0) AS client_extend_time_ms,
           COALESCE(SUM(fsyncs) FILTER (WHERE backend_type = 'client backend'), 0) AS client_fsyncs,
           COALESCE(SUM(fsync_time) FILTER (WHERE backend_type = 'client backend'), 0) AS client_fsync_time_ms,
           COALESCE(SUM(reads) FILTER (WHERE backend_type = 'autovacuum worker'), 0) AS autovacuum_reads,
           COALESCE(SUM(read_time) FILTER (WHERE backend_type = 'autovacuum worker'), 0) AS autovacuum_read_time_ms,
           COALESCE(SUM(writes) FILTER (WHERE backend_type = 'autovacuum worker'), 0) AS autovacuum_writes,
           COALESCE(SUM(write_time) FILTER (WHERE backend_type = 'autovacuum worker'), 0) AS autovacuum_write_time_ms
    FROM pg_stat_io
),
statements AS (
    SELECT COALESCE(SUM(calls), 0) AS insert_calls,
           COALESCE(SUM(rows), 0) AS insert_rows,
           COALESCE(SUM(total_exec_time), 0) AS insert_exec_time_ms,
           COALESCE(SUM(shared_blk_read_time), 0) AS insert_block_read_time_ms,
           COALESCE(SUM(shared_blk_write_time), 0) AS insert_block_write_time_ms,
           COALESCE(SUM(wal_records), 0) AS insert_wal_records,
           COALESCE(SUM(wal_fpi), 0) AS insert_wal_fpi,
           COALESCE(SUM(wal_bytes), 0) AS insert_wal_bytes
    FROM pg_stat_statements
    WHERE query ~* 'insert[[:space:]]+into.*p_notifications'
),
table_stats AS (
    SELECT COALESCE(n_live_tup, 0) AS live_tuples,
           COALESCE(n_dead_tup, 0) AS dead_tuples,
           COALESCE(autovacuum_count, 0) AS autovacuum_count
    FROM pg_stat_user_tables
    WHERE schemaname = 'notification_schema'
      AND relname = 'p_notifications'
),
relation_sizes AS (
    SELECT pg_relation_size('notification_schema.p_notifications'::regclass) AS table_size_bytes,
           pg_indexes_size('notification_schema.p_notifications'::regclass) AS index_size_bytes,
           pg_total_relation_size('notification_schema.p_notifications'::regclass) AS total_size_bytes
)
SELECT (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint AS captured_at_epoch_ms,
       wal.wal_records,
       wal.wal_fpi,
       wal.wal_bytes,
       wal.wal_buffers_full,
       wal.wal_write,
       wal.wal_sync,
       wal.wal_write_time AS wal_write_time_ms,
       wal.wal_sync_time AS wal_sync_time_ms,
       io.client_reads,
       io.client_read_time_ms,
       io.client_writes,
       io.client_write_time_ms,
       io.client_extends,
       io.client_extend_time_ms,
       io.client_fsyncs,
       io.client_fsync_time_ms,
       io.autovacuum_reads,
       io.autovacuum_read_time_ms,
       io.autovacuum_writes,
       io.autovacuum_write_time_ms,
       statements.insert_calls,
       statements.insert_rows,
       statements.insert_exec_time_ms,
       statements.insert_block_read_time_ms,
       statements.insert_block_write_time_ms,
       statements.insert_wal_records,
       statements.insert_wal_fpi,
       statements.insert_wal_bytes,
       checkpointer.num_timed AS checkpoint_timed,
       checkpointer.num_requested AS checkpoint_requested,
       checkpointer.buffers_written AS checkpoint_buffers_written,
       checkpointer.write_time AS checkpoint_write_time_ms,
       checkpointer.sync_time AS checkpoint_sync_time_ms,
       table_stats.live_tuples,
       table_stats.dead_tuples,
       table_stats.autovacuum_count,
       relation_sizes.table_size_bytes,
       relation_sizes.index_size_bytes,
       relation_sizes.total_size_bytes
FROM wal
CROSS JOIN io
CROSS JOIN statements
CROSS JOIN pg_stat_checkpointer AS checkpointer
CROSS JOIN table_stats
CROSS JOIN relation_sizes;

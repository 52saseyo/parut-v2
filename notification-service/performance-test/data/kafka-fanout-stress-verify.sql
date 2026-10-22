-- Verification for a single-event Kafka Fan-out stress run.
-- Required psql variables: event_id, time_deal_id, expected_count.

\set ON_ERROR_STOP on

select
  :'event_id'::uuid as event_id,
  :'time_deal_id'::uuid as time_deal_id,
  :'expected_count'::bigint as expected_notifications,
  count(*) as actual_notifications,
  count(*) - :'expected_count'::bigint as diff
from notification_schema.p_notifications
where event_id = :'event_id'::uuid;

select
  count(*) as duplicate_targets
from (
  select user_id
  from notification_schema.p_notifications
  where event_id = :'event_id'::uuid
  group by user_id
  having count(*) > 1
) duplicates;

with expected_targets as (
  select user_id
  from notification_schema.p_time_deal_notification_subscriptions
  where time_deal_id = :'time_deal_id'::uuid
    and deleted_at is null
),
actual_targets as (
  select user_id
  from notification_schema.p_notifications
  where event_id = :'event_id'::uuid
),
missing_targets as (
  select * from expected_targets
  except
  select * from actual_targets
),
unexpected_targets as (
  select * from actual_targets
  except
  select * from expected_targets
)
select 'missing_targets' as metric, count(*) as value from missing_targets
union all
select 'unexpected_targets', count(*) from unexpected_targets;

select
  event_id,
  count(*) as notification_count,
  min(created_at) as first_created_at,
  max(created_at) as last_created_at,
  round(extract(epoch from max(created_at) - min(created_at))::numeric, 3)
    as created_at_span_seconds
from notification_schema.p_notifications
where event_id = :'event_id'::uuid
group by event_id;

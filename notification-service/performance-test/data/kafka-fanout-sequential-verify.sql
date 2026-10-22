-- Sequential workload verification.

\set ON_ERROR_STOP on

with expected(event_no, event_id, time_deal_id, expected_count) as (
  values
    (1, '98100000-0000-4000-8000-000000000001'::uuid, '94100000-0000-4000-8000-000000000001'::uuid, 500),
    (2, '98100000-0000-4000-8000-000000000002'::uuid, '94100000-0000-4000-8000-000000000002'::uuid, 1500),
    (3, '98100000-0000-4000-8000-000000000003'::uuid, '94100000-0000-4000-8000-000000000003'::uuid, 10000),
    (4, '98100000-0000-4000-8000-000000000004'::uuid, '94100000-0000-4000-8000-000000000004'::uuid, 2000),
    (5, '98100000-0000-4000-8000-000000000005'::uuid, '94100000-0000-4000-8000-000000000005'::uuid, 4000)
),
actual as (
  select event_id, count(*) as actual_count
  from notification_schema.p_notifications
  where event_id in (select event_id from expected)
  group by event_id
)
select
  expected.event_no,
  expected.event_id,
  expected.time_deal_id,
  expected.expected_count,
  coalesce(actual.actual_count, 0) as actual_count,
  coalesce(actual.actual_count, 0) - expected.expected_count as diff
from expected
left join actual using (event_id)
order by expected.event_no;

with target_events as (
  select event_id
  from notification_schema.p_notifications
  where event_id between '98100000-0000-4000-8000-000000000001'
                     and '98100000-0000-4000-8000-000000000005'
)
select
  18000 as expected_notifications,
  count(*) as actual_notifications,
  count(*) - 18000 as diff
from target_events;

select
  count(*) as duplicate_targets
from (
  select event_id, user_id
  from notification_schema.p_notifications
  where event_id between '98100000-0000-4000-8000-000000000001'
                     and '98100000-0000-4000-8000-000000000005'
  group by event_id, user_id
  having count(*) > 1
) duplicates;

with expected(event_id, time_deal_id) as (
  values
    ('98100000-0000-4000-8000-000000000001'::uuid, '94100000-0000-4000-8000-000000000001'::uuid),
    ('98100000-0000-4000-8000-000000000002'::uuid, '94100000-0000-4000-8000-000000000002'::uuid),
    ('98100000-0000-4000-8000-000000000003'::uuid, '94100000-0000-4000-8000-000000000003'::uuid),
    ('98100000-0000-4000-8000-000000000004'::uuid, '94100000-0000-4000-8000-000000000004'::uuid),
    ('98100000-0000-4000-8000-000000000005'::uuid, '94100000-0000-4000-8000-000000000005'::uuid)
),
expected_targets as (
  select expected.event_id, subscriptions.user_id
  from expected
  join notification_schema.p_time_deal_notification_subscriptions subscriptions
    on subscriptions.time_deal_id = expected.time_deal_id
   and subscriptions.deleted_at is null
),
actual_targets as (
  select event_id, user_id
  from notification_schema.p_notifications
  where event_id in (select event_id from expected)
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
where event_id between '98100000-0000-4000-8000-000000000001'
                   and '98100000-0000-4000-8000-000000000005'
group by event_id
order by event_id;

\if :{?event_count}
\else
\set event_count 10
\endif

\if :{?subscriber_count}
\else
\set subscriber_count 10000
\endif

with expected as (
  select
    ('98000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as event_id,
    ('94000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as time_deal_id,
    :subscriber_count::int as expected_count,
    'Scenario Event ' || seq as test_case
  from generate_series(1, :event_count::int) as seq
),
actual as (
  select event_id, count(*) as actual_count
  from notification_schema.p_notifications
  where event_id in (select event_id from expected)
  group by event_id
)
select
  e.test_case,
  e.event_id,
  e.time_deal_id,
  e.expected_count,
  coalesce(a.actual_count, 0) as actual_count,
  coalesce(a.actual_count, 0) - e.expected_count as diff
from expected e
left join actual a on a.event_id = e.event_id
order by e.event_id;

with expected as (
  select
    ('98000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as event_id,
    :subscriber_count::int as expected_count
  from generate_series(1, :event_count::int) as seq
),
actual as (
  select count(*) as actual_count
  from notification_schema.p_notifications
  where event_id in (select event_id from expected)
)
select 'Total expected notifications' as metric, sum(expected_count)::bigint as value
from expected
union all
select 'Total actual notifications' as metric, actual_count as value
from actual;

with target_events as (
  select ('98000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as event_id
  from generate_series(1, :event_count::int) as seq
)
select
  count(*) as notification_count,
  min(created_at) as first_created_at,
  max(created_at) as last_created_at,
  round(extract(epoch from max(created_at) - min(created_at))::numeric, 3) as notification_created_at_span_seconds,
  round(
    count(*)::numeric
      / nullif(extract(epoch from max(created_at) - min(created_at))::numeric, 0),
    2
  ) as created_at_window_notification_rate
from notification_schema.p_notifications
where event_id in (select event_id from target_events);

with target_events as (
  select ('98000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as event_id
  from generate_series(1, :event_count::int) as seq
)
select event_id, user_id, count(*) as duplicate_count
from notification_schema.p_notifications
where event_id in (select event_id from target_events)
group by event_id, user_id
having count(*) > 1
order by duplicate_count desc, event_id, user_id;

with expected_targets as (
  select
    ('98000000-0000-4000-8000-' || lpad(event_no::text, 12, '0'))::uuid as event_id,
    ('b4000000-0000-4000-8000-' || lpad(((event_no - 1) * :subscriber_count::int + user_no)::text, 12, '0'))::uuid as user_id
  from generate_series(1, :event_count::int) as event_no
  cross join generate_series(1, :subscriber_count::int) as user_no
),
actual_targets as (
  select event_id, user_id
  from notification_schema.p_notifications
  where event_id between '98000000-0000-4000-8000-000000000001'
                     and ('98000000-0000-4000-8000-' || lpad(:event_count::text, 12, '0'))::uuid
),
missing_targets as (
  select event_id, user_id from expected_targets
  except
  select event_id, user_id from actual_targets
),
unexpected_targets as (
  select event_id, user_id from actual_targets
  except
  select event_id, user_id from expected_targets
)
select 'Missing expected notification targets' as metric, count(*) as value
from missing_targets
union all
select 'Unexpected notification targets' as metric, count(*) as value
from unexpected_targets;

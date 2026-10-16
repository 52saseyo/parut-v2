with expected as (
  select
    ('98000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as event_id,
    ('94000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as time_deal_id,
    10000 as expected_count,
    'Load Event ' || seq as test_case
  from generate_series(1, 100) as seq
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
  select ('98000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as event_id,
         10000 as expected_count
  from generate_series(1, 100) as seq
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

select
  count(*) as notification_count,
  min(created_at) as first_created_at,
  max(created_at) as last_created_at,
  round(extract(epoch from max(created_at) - min(created_at))::numeric, 3) as duration_seconds,
  round(
    count(*)::numeric / nullif(extract(epoch from max(created_at) - min(created_at))::numeric, 0),
    2
  ) as notification_tps
from notification_schema.p_notifications
where event_id between '98000000-0000-4000-8000-000000000001'
                and '98000000-0000-4000-8000-000000000100';

select event_id, user_id, count(*) as duplicate_count
from notification_schema.p_notifications
where event_id between '98000000-0000-4000-8000-000000000001'
                and '98000000-0000-4000-8000-000000000100'
group by event_id, user_id
having count(*) > 1
order by duplicate_count desc, event_id, user_id;

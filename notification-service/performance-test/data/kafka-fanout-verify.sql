with expected(event_id, time_deal_id, expected_count, test_case) as (
  values
    ('96000000-0000-4000-8000-000000001000'::uuid, '92000000-0000-4000-8000-000000001000'::uuid, 1000, 'Medium'),
    ('96000000-0000-4000-8000-000000010000'::uuid, '92000000-0000-4000-8000-000000010000'::uuid, 10000, 'Large')
  union all
  select
    ('97000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as event_id,
    ('93000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as time_deal_id,
    2000 as expected_count,
    'Multiple Event ' || seq as test_case
  from generate_series(1, 20) as seq
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
order by e.test_case;

with expected(event_id, expected_count) as (
  values
    ('96000000-0000-4000-8000-000000001000'::uuid, 1000),
    ('96000000-0000-4000-8000-000000010000'::uuid, 10000)
  union all
  select
    ('97000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid,
    2000
  from generate_series(1, 20) as seq
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

select event_id, user_id, count(*) as duplicate_count
from notification_schema.p_notifications
where event_id in (
  '96000000-0000-4000-8000-000000001000',
  '96000000-0000-4000-8000-000000010000'
)
or event_id between '97000000-0000-4000-8000-000000000001'
                and '97000000-0000-4000-8000-000000000020'
group by event_id, user_id
having count(*) > 1
order by duplicate_count desc, event_id, user_id;

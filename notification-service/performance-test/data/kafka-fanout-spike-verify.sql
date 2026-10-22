-- Spike workload verification: baseline 2K, mixed 20K burst, recovery 2K.

\set ON_ERROR_STOP on

create temporary table expected_spike_events (
  event_no integer primary key,
  phase text not null,
  event_id uuid not null,
  time_deal_id uuid not null,
  expected_count integer not null
);

insert into expected_spike_events values
  (1, 'baseline', '98200000-0000-4000-8000-000000000001', '94100000-0000-4000-8000-000000000004', 2000),
  (2, 'spike',    '98200000-0000-4000-8000-000000000002', '94100000-0000-4000-8000-000000000006', 1000),
  (3, 'spike',    '98200000-0000-4000-8000-000000000003', '94100000-0000-4000-8000-000000000004', 2000),
  (4, 'spike',    '98200000-0000-4000-8000-000000000004', '94100000-0000-4000-8000-000000000007', 3000),
  (5, 'spike',    '98200000-0000-4000-8000-000000000005', '94100000-0000-4000-8000-000000000005', 4000),
  (6, 'spike',    '98200000-0000-4000-8000-000000000006', '94100000-0000-4000-8000-000000000003', 10000),
  (7, 'recovery', '98200000-0000-4000-8000-000000000007', '94100000-0000-4000-8000-000000000004', 2000);

with actual as (
  select event_id, count(*) as actual_count
  from notification_schema.p_notifications
  where event_id in (select event_id from expected_spike_events)
  group by event_id
)
select
  expected.event_no,
  expected.phase,
  expected.event_id,
  expected.expected_count,
  coalesce(actual.actual_count, 0) as actual_count,
  coalesce(actual.actual_count, 0) - expected.expected_count as diff
from expected_spike_events expected
left join actual using (event_id)
order by expected.event_no;

select
  24000 as expected_notifications,
  count(*) as actual_notifications,
  count(*) - 24000 as diff
from notification_schema.p_notifications
where event_id in (select event_id from expected_spike_events);

select count(*) as duplicate_targets
from (
  select event_id, user_id
  from notification_schema.p_notifications
  where event_id in (select event_id from expected_spike_events)
  group by event_id, user_id
  having count(*) > 1
) duplicates;

with expected_targets as (
  select expected.event_id, subscriptions.user_id
  from expected_spike_events expected
  join notification_schema.p_time_deal_notification_subscriptions subscriptions
    on subscriptions.time_deal_id = expected.time_deal_id
   and subscriptions.deleted_at is null
),
actual_targets as (
  select event_id, user_id
  from notification_schema.p_notifications
  where event_id in (select event_id from expected_spike_events)
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
  expected.phase,
  notifications.event_id,
  count(*) as notification_count,
  min(notifications.created_at) as first_created_at,
  max(notifications.created_at) as last_created_at,
  round(extract(epoch from max(notifications.created_at) - min(notifications.created_at))::numeric, 3)
    as created_at_span_seconds
from notification_schema.p_notifications notifications
join expected_spike_events expected using (event_id)
group by expected.phase, notifications.event_id, expected.event_no
order by expected.event_no;

-- Kafka Fan-out Correctness Test seed
-- Expected notifications:
--   Medium: 1 event * 1,000 subscribers = 1,000
--   Large: 1 event * 10,000 subscribers = 10,000
--   Multiple Event: 20 events * 2,000 subscribers = 40,000
--   Total = 51,000

delete from notification_schema.p_notifications
where event_id in (
  '96000000-0000-4000-8000-000000001000',
  '96000000-0000-4000-8000-000000010000'
)
or event_id between '97000000-0000-4000-8000-000000000001'
                and '97000000-0000-4000-8000-000000000020';

delete from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id in (
  '92000000-0000-4000-8000-000000001000',
  '92000000-0000-4000-8000-000000010000'
)
or time_deal_id between '93000000-0000-4000-8000-000000000001'
                    and '93000000-0000-4000-8000-000000000020';

insert into notification_schema.p_time_deal_notification_subscriptions (
  id,
  user_id,
  time_deal_id,
  created_at,
  updated_at,
  deleted_at
)
select
  ('a1000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as id,
  ('b1000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as user_id,
  '92000000-0000-4000-8000-000000001000'::uuid as time_deal_id,
  now(),
  now(),
  null
from generate_series(1, 1000) as seq;

insert into notification_schema.p_time_deal_notification_subscriptions (
  id,
  user_id,
  time_deal_id,
  created_at,
  updated_at,
  deleted_at
)
select
  ('a2000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as id,
  ('b2000000-0000-4000-8000-' || lpad(seq::text, 12, '0'))::uuid as user_id,
  '92000000-0000-4000-8000-000000010000'::uuid as time_deal_id,
  now(),
  now(),
  null
from generate_series(1, 10000) as seq;

insert into notification_schema.p_time_deal_notification_subscriptions (
  id,
  user_id,
  time_deal_id,
  created_at,
  updated_at,
  deleted_at
)
select
  ('a3000000-0000-4000-8000-' || lpad(((deal_no - 1) * 2000 + user_no)::text, 12, '0'))::uuid as id,
  ('b3000000-0000-4000-8000-' || lpad(((deal_no - 1) * 2000 + user_no)::text, 12, '0'))::uuid as user_id,
  ('93000000-0000-4000-8000-' || lpad(deal_no::text, 12, '0'))::uuid as time_deal_id,
  now(),
  now(),
  null
from generate_series(1, 20) as deal_no
cross join generate_series(1, 2000) as user_no;

select
  case
    when time_deal_id = '92000000-0000-4000-8000-000000001000' then 'Medium'
    when time_deal_id = '92000000-0000-4000-8000-000000010000' then 'Large'
    when time_deal_id between '93000000-0000-4000-8000-000000000001'
                          and '93000000-0000-4000-8000-000000000020' then 'Multiple Event'
    else 'Other'
  end as test_case,
  count(*) as total_rows,
  count(*) filter (where deleted_at is null) as active_rows,
  count(distinct user_id) as distinct_users,
  count(distinct time_deal_id) as time_deal_count
from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id in (
  '92000000-0000-4000-8000-000000001000',
  '92000000-0000-4000-8000-000000010000'
)
or time_deal_id between '93000000-0000-4000-8000-000000000001'
                    and '93000000-0000-4000-8000-000000000020'
group by 1
order by 1;

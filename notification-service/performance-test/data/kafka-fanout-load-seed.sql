-- Kafka Fan-out Load Test seed
-- 100 events * 10,000 subscribers = 1,000,000 expected notifications.

delete from notification_schema.p_notifications
where event_id between '98000000-0000-4000-8000-000000000001'
                and '98000000-0000-4000-8000-000000000100';

delete from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id between '94000000-0000-4000-8000-000000000001'
                    and '94000000-0000-4000-8000-000000000100';

insert into notification_schema.p_time_deal_notification_subscriptions (
  id,
  user_id,
  time_deal_id,
  created_at,
  updated_at,
  deleted_at
)
select
  ('a4000000-0000-4000-8000-' || lpad(((deal_no - 1) * 10000 + user_no)::text, 12, '0'))::uuid as id,
  ('b4000000-0000-4000-8000-' || lpad(((deal_no - 1) * 10000 + user_no)::text, 12, '0'))::uuid as user_id,
  ('94000000-0000-4000-8000-' || lpad(deal_no::text, 12, '0'))::uuid as time_deal_id,
  now(),
  now(),
  null
from generate_series(1, 100) as deal_no
cross join generate_series(1, 10000) as user_no;

select
  count(*) as total_rows,
  count(*) filter (where deleted_at is null) as active_rows,
  count(distinct user_id) as distinct_users,
  count(distinct time_deal_id) as time_deal_count
from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id between '94000000-0000-4000-8000-000000000001'
                    and '94000000-0000-4000-8000-000000000100';

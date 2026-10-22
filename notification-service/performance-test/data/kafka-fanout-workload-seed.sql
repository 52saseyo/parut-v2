-- Shared Sequential/Spike workload seed.
-- 10,000 unique users subscribe to seven deals with overlapping memberships.
-- Sequential uses deals 1-5. Spike also uses 2,000-subscriber deal 4 for its
-- baseline/recovery events and deals 6-7 for 1,000/3,000-subscriber bursts.

\set ON_ERROR_STOP on

delete from notification_schema.p_notifications
where event_id between '98100000-0000-4000-8000-000000000001'
                   and '98100000-0000-4000-8000-000000000005';

delete from notification_schema.p_notifications
where event_id between '98200000-0000-4000-8000-000000000001'
                   and '98200000-0000-4000-8000-000000000007';

delete from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id between '94100000-0000-4000-8000-000000000001'
                      and '94100000-0000-4000-8000-000000000007';

with workload(time_deal_no, subscriber_count) as (
  values
    (1, 500),
    (2, 1500),
    (3, 10000),
    (4, 2000),
    (5, 4000),
    (6, 1000),
    (7, 3000)
)
insert into notification_schema.p_time_deal_notification_subscriptions (
  id,
  user_id,
  time_deal_id,
  created_at,
  updated_at,
  deleted_at
)
select
  ('a4100000-0000-4000-' || lpad(workload.time_deal_no::text, 4, '0') || '-' ||
    lpad(user_no::text, 12, '0'))::uuid,
  ('b4100000-0000-4000-8000-' || lpad(user_no::text, 12, '0'))::uuid,
  ('94100000-0000-4000-8000-' || lpad(workload.time_deal_no::text, 12, '0'))::uuid,
  now(),
  now(),
  null
from workload
cross join lateral generate_series(1, workload.subscriber_count) as user_no;

select
  count(*) as subscription_rows,
  count(*) filter (where deleted_at is null) as active_rows,
  count(distinct user_id) as unique_users,
  count(distinct time_deal_id) as time_deal_count
from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id between '94100000-0000-4000-8000-000000000001'
                      and '94100000-0000-4000-8000-000000000007';

select
  time_deal_id,
  count(*) as active_subscribers
from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id between '94100000-0000-4000-8000-000000000001'
                      and '94100000-0000-4000-8000-000000000007'
  and deleted_at is null
group by time_deal_id
order by time_deal_id;

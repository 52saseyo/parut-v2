-- Kafka Fan-out Load/Spike Test seed.
-- Shared by Load and Spike tests. Always pass the scenario explicitly:
-- Load: 60 events, Spike: 10 or 20 events, 10,000 subscribers per event.
-- Defaults remain the smallest Spike scenario for accidental-run safety.

\if :{?event_count}
\else
\set event_count 10
\endif

\if :{?subscriber_count}
\else
\set subscriber_count 10000
\endif

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
  ('a4000000-0000-4000-8000-' || lpad(((deal_no - 1) * :subscriber_count::int + user_no)::text, 12, '0'))::uuid as id,
  ('b4000000-0000-4000-8000-' || lpad(((deal_no - 1) * :subscriber_count::int + user_no)::text, 12, '0'))::uuid as user_id,
  ('94000000-0000-4000-8000-' || lpad(deal_no::text, 12, '0'))::uuid as time_deal_id,
  now(),
  now(),
  null
from generate_series(1, :event_count::int) as deal_no
cross join generate_series(1, :subscriber_count::int) as user_no;

select
  (:event_count::bigint * :subscriber_count::bigint) as expected_rows,
  count(*) as total_rows,
  count(*) - (:event_count::bigint * :subscriber_count::bigint) as row_diff,
  count(*) filter (where deleted_at is null) as active_rows,
  count(distinct user_id) as distinct_users,
  count(distinct time_deal_id) as time_deal_count
from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id between '94000000-0000-4000-8000-000000000001'
                    and ('94000000-0000-4000-8000-' || lpad(:event_count::text, 12, '0'))::uuid;

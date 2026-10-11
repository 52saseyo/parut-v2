-- Subscription concurrency test fixture.
-- This script resets the target user/time-deal pair so the JMeter test starts
-- from a clean state. Re-run it before each test execution.

delete from notification_schema.p_time_deal_notification_subscriptions
where user_id = '90000000-0000-4000-8000-000000000001'
  and time_deal_id = '91000000-0000-4000-8000-000000000001';

-- Expected before the test:
-- total_rows = 0, active_rows = 0
--
-- Expected after the test:
-- total_rows = 1, active_rows = 1
select
  count(*) as total_rows,
  count(*) filter (where deleted_at is null) as active_rows
from notification_schema.p_time_deal_notification_subscriptions
where user_id = '90000000-0000-4000-8000-000000000001'
  and time_deal_id = '91000000-0000-4000-8000-000000000001';

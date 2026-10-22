-- Parameterized seed for a single-event Kafka Fan-out stress run.
-- Required psql variables: event_id, time_deal_id, subscriber_count.

\set ON_ERROR_STOP on

select exists (
  select 1
  from notification_schema.p_notifications
  where event_id between '98300000-0000-4000-8000-000000000000'::uuid
                     and '98300000-0000-4000-8000-999999999999'::uuid
) as notification_cleanup_required
\gset

delete from notification_schema.p_notifications
where event_id between '98300000-0000-4000-8000-000000000000'::uuid
                   and '98300000-0000-4000-8000-999999999999'::uuid;

select exists (
  select 1
  from notification_schema.p_time_deal_notification_subscriptions
  where time_deal_id between '94300000-0000-4000-8000-000000000000'::uuid
                         and '94300000-0000-4000-8000-999999999999'::uuid
    and time_deal_id <> :'time_deal_id'::uuid
) as subscription_cleanup_required
\gset

delete from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id between '94300000-0000-4000-8000-000000000000'::uuid
                       and '94300000-0000-4000-8000-999999999999'::uuid
  and time_deal_id <> :'time_deal_id'::uuid;

insert into notification_schema.p_time_deal_notification_subscriptions as subscription (
  id,
  user_id,
  time_deal_id,
  created_at,
  updated_at,
  deleted_at
)
select
  md5('stress-subscription:' || :'time_deal_id' || ':' || user_no)::uuid,
  ('b4300000-0000-4000-8000-' || lpad(user_no::text, 12, '0'))::uuid,
  :'time_deal_id'::uuid,
  now(),
  now(),
  null
from generate_series(1, :'subscriber_count'::bigint) as user_no
on conflict (user_id, time_deal_id) do update
set deleted_at = null,
    updated_at = excluded.updated_at
where subscription.deleted_at is not null;

\if :notification_cleanup_required
vacuum (analyze) notification_schema.p_notifications;
\else
analyze notification_schema.p_notifications;
\endif

\if :subscription_cleanup_required
vacuum (analyze) notification_schema.p_time_deal_notification_subscriptions;
\else
analyze notification_schema.p_time_deal_notification_subscriptions;
\endif

select
  :'time_deal_id'::uuid as time_deal_id,
  :'subscriber_count'::bigint as expected_subscribers,
  count(*) filter (where deleted_at is null) as active_subscribers,
  count(*) filter (where deleted_at is not null) as deleted_subscribers
from notification_schema.p_time_deal_notification_subscriptions
where time_deal_id = :'time_deal_id'::uuid;

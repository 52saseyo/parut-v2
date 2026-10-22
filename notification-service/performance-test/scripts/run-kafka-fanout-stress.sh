#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./performance-test/scripts/run-kafka-fanout-stress.sh <subscriber-count> <run-number>

Example:
  ./performance-test/scripts/run-kafka-fanout-stress.sh 50000 1

Optional environment variables:
  DB_URL                PostgreSQL connection URL
  BOOTSTRAP_SERVERS     Kafka bootstrap servers for JMeter
  KAFKA_ADMIN_SERVER    Kafka bootstrap server inside the kafka container
  KAFKA_CONSUMER_GROUP  Consumer group to observe
  KAFKA_TOPIC           Kafka topic to publish
  KAFKA_CLIENT_JAR      kafka-clients JAR used by JMeter
  WAIT_TIMEOUT_SECONDS  Maximum processing wait, default 300
  RESULTS_DIR           Result directory, default ./test-results
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

subscriber_count="$1"
run_number="$2"

if [[ ! "${subscriber_count}" =~ ^[1-9][0-9]*$ ]] ||
   (( subscriber_count > 999999999 )); then
  echo "subscriber-count must be between 1 and 999999999" >&2
  exit 2
fi

if [[ ! "${run_number}" =~ ^[1-9][0-9]*$ ]] || (( run_number > 999 )); then
  echo "run-number must be between 1 and 999" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_dir="$(cd "${script_dir}/../.." && pwd)"
cd "${service_dir}"

scenario="stress-${subscriber_count}-run-${run_number}"
results_dir="${RESULTS_DIR:-${service_dir}/test-results}"
db_url="${DB_URL:-postgresql://parut:parut123@localhost:5433/parut}"
bootstrap_servers="${BOOTSTRAP_SERVERS:-localhost:9092}"
kafka_admin_server="${KAFKA_ADMIN_SERVER:-localhost:9092}"
consumer_group="${KAFKA_CONSUMER_GROUP:-notification-time-deal-opening-soon}"
kafka_topic="${KAFKA_TOPIC:-time-deal.opening-soon}"
wait_timeout_seconds="${WAIT_TIMEOUT_SECONDS:-300}"
kafka_client_jar="${KAFKA_CLIENT_JAR:-${HOME}/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar}"

if [[ ! "${wait_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "WAIT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

printf -v time_deal_suffix '%012d' "${subscriber_count}"
event_number=$((subscriber_count * 1000 + run_number))
printf -v event_suffix '%012d' "${event_number}"

time_deal_id="94300000-0000-4000-8000-${time_deal_suffix}"
event_id="98300000-0000-4000-8000-${event_suffix}"
time_deal_name="Stress Deal ${subscriber_count}"

seed_sql="performance-test/data/kafka-fanout-stress-seed.sql"
verify_sql="performance-test/data/kafka-fanout-stress-verify.sql"
jmeter_plan="performance-test/jmeter/kafka-fanout-stress-test.jmx"

jtl_file="${results_dir}/kafka-fanout-${scenario}.jtl"
jmeter_log="${results_dir}/kafka-fanout-${scenario}.log"
seed_result="${results_dir}/kafka-fanout-${scenario}-seed.txt"
verify_result="${results_dir}/kafka-fanout-${scenario}-verification.txt"
lag_result="${results_dir}/kafka-lag-${scenario}.csv"
stats_result="${results_dir}/container-stats-${scenario}.csv"
consumer_result="${results_dir}/kafka-consumer-${scenario}.txt"
publish_result="${results_dir}/kafka-publish-count-${scenario}.txt"
error_result="${results_dir}/errors-${scenario}.txt"
fanout_result="${results_dir}/fanout-measurements-${scenario}.csv"
fanout_summary="${results_dir}/fanout-throughput-${scenario}-summary.txt"

for command_name in psql jmeter docker awk; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "required command not found: ${command_name}" >&2
    exit 1
  fi
done

for input_file in "${seed_sql}" "${verify_sql}" "${jmeter_plan}" "${kafka_client_jar}"; do
  if [[ ! -f "${input_file}" ]]; then
    echo "required file not found: ${input_file}" >&2
    exit 1
  fi
done

mkdir -p "${results_dir}"

for output_file in \
  "${jtl_file}" \
  "${jmeter_log}" \
  "${seed_result}" \
  "${verify_result}" \
  "${lag_result}" \
  "${stats_result}" \
  "${consumer_result}" \
  "${publish_result}" \
  "${error_result}" \
  "${fanout_result}" \
  "${fanout_summary}"; do
  if [[ -e "${output_file}" ]]; then
    echo "result already exists: ${output_file}" >&2
    echo "use another run-number or move the existing result first" >&2
    exit 1
  fi
done

current_lag() {
  docker exec kafka \
    /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server "${kafka_admin_server}" \
    --describe \
    --group "${consumer_group}" 2>/dev/null |
    awk 'NR > 1 && $6 ~ /^[0-9]+$/ {sum += $6; found=1}
         END {if (found) print sum; else print "NA"}'
}

monitor_lag() {
  printf 'timestamp,lag\n'
  while true; do
    printf '%s,%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(current_lag)"
    sleep 1
  done
}

monitor_containers() {
  printf 'timestamp,container,cpu_percent,memory_usage,block_io\n'
  while true; do
    test_time="$(date '+%Y-%m-%d %H:%M:%S')"
    docker stats --no-stream \
      --format "${test_time},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.BlockIO}}" \
      postgres notification-service
    sleep 1
  done
}

lag_pid=''
stats_pid=''
monitor_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kafka-fanout-stress.XXXXXX")"
fanout_measurement_file="${monitor_temp_dir}/fanout-measurements.csv"

stop_monitors() {
  for monitor_pid in "${lag_pid}" "${stats_pid}"; do
    if [[ -n "${monitor_pid}" ]] && kill -0 "${monitor_pid}" 2>/dev/null; then
      kill "${monitor_pid}" 2>/dev/null || true
      wait "${monitor_pid}" 2>/dev/null || true
    fi
  done
  lag_pid=''
  stats_pid=''
}

cleanup() {
  stop_monitors
  rm -f "${fanout_measurement_file}"
  rmdir "${monitor_temp_dir}" 2>/dev/null || true
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

echo "[1/7] Seed ${subscriber_count} subscribers for ${scenario}"
set +e
psql "${db_url}" \
  -v event_id="${event_id}" \
  -v time_deal_id="${time_deal_id}" \
  -v subscriber_count="${subscriber_count}" \
  -f "${seed_sql}" | tee "${seed_result}"
seed_status=${PIPESTATUS[0]}
set -e

if (( seed_status != 0 )); then
  exit 1
fi

active_subscribers="$(
  psql "${db_url}" -Atq -c \
    "select count(*) from notification_schema.p_time_deal_notification_subscriptions where time_deal_id = '${time_deal_id}' and deleted_at is null;"
)"

if [[ "${active_subscribers}" != "${subscriber_count}" ]]; then
  echo "subscriber seed mismatch: expected=${subscriber_count}, actual=${active_subscribers}" >&2
  exit 1
fi

echo "[2/7] Record Consumer assignment and validate initial lag"
docker exec kafka \
  /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server "${kafka_admin_server}" \
  --describe \
  --group "${consumer_group}" |
  tee "${consumer_result}"

initial_lag="$(current_lag)"
if [[ "${initial_lag}" != '0' ]]; then
  echo "Kafka lag must be 0 before the test. Current lag: ${initial_lag}" >&2
  exit 1
fi

run_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "[3/7] Start Kafka lag and container monitoring"
monitor_lag >"${lag_result}" &
lag_pid=$!
monitor_containers >"${stats_result}" &
stats_pid=$!

echo "[4/7] Publish one ${subscriber_count}-subscriber Stress event"
set +e
jmeter -n -f \
  -Jsearch_paths="${kafka_client_jar}" \
  -t "${jmeter_plan}" \
  -JbootstrapServers="${bootstrap_servers}" \
  -Jtopic="${kafka_topic}" \
  -JeventId="${event_id}" \
  -JtimeDealId="${time_deal_id}" \
  -JtimeDealName="${time_deal_name}" \
  -JtimeDealStartAt='2099-01-01T00:00:00Z' \
  -l "${jtl_file}" \
  -j "${jmeter_log}"
jmeter_status=$?
set -e

sampler_name='Kafka opening-soon Stress 이벤트 발행'
if [[ -f "${jtl_file}" ]]; then
  awk -F',' -v sampler="${sampler_name}" \
    'NR > 1 && $3 == sampler {count[$4]++}
     END {for (code in count) print code, count[code]}' \
    "${jtl_file}" | tee "${publish_result}"
else
  : >"${publish_result}"
fi

echo "[5/7] Wait for ${subscriber_count} notifications and lag recovery"
deadline=$((SECONDS + wait_timeout_seconds))
stable_checks=0
wait_status=0

while (( SECONDS < deadline )); do
  actual_count="$(
    psql "${db_url}" -Atq -c \
      "select count(*) from notification_schema.p_notifications where event_id = '${event_id}';"
  )"
  observed_lag="$(current_lag)"

  if [[ "${actual_count}" == "${subscriber_count}" && "${observed_lag}" == '0' ]]; then
    stable_checks=$((stable_checks + 1))
    if (( stable_checks >= 2 )); then
      break
    fi
  elif [[ "${actual_count}" =~ ^[0-9]+$ ]] &&
       (( actual_count > subscriber_count )); then
    echo "notification count exceeded expected count: ${actual_count}" >&2
    break
  else
    stable_checks=0
  fi

  sleep 2
done

if (( stable_checks < 2 )); then
  echo "processing did not complete within ${wait_timeout_seconds}s after publishing" >&2
  wait_status=1
fi

stop_monitors

docker logs --since "${run_started_at}" notification-service 2>&1 |
  sed -n \
    's/.*FANOUT_MEASUREMENT eventId=\([^,]*\), consumerReceivedEpochMs=\([0-9][0-9]*\), transactionCompletedEpochMs=\([0-9][0-9]*\), durationMs=\([0-9][0-9]*\), result=\([^, ]*\).*/\1,\2,\3,\4,\5/p' \
    >"${fanout_measurement_file}"

actual_count="$(
  psql "${db_url}" -Atq -c \
    "select count(*) from notification_schema.p_notifications where event_id = '${event_id}';"
)"

measurement="$(
  awk -F',' -v id="${event_id}" \
    '$1 == id {latest=$0} $1 == id && $5 == "success" {success=$0}
     END {if (success != "") print success; else print latest}' \
    "${fanout_measurement_file}"
)"

received_epoch_ms=''
completed_epoch_ms=''
fanout_ms=''
fanout_status='missing'
notifications_per_second='NA'

if [[ -n "${measurement}" ]]; then
  IFS=',' read -r _ received_epoch_ms completed_epoch_ms fanout_ms fanout_status \
    <<<"${measurement}"
  notifications_per_second="$(
    awk -v count="${actual_count}" -v elapsed_ms="${fanout_ms}" \
      'BEGIN {if (elapsed_ms > 0) printf "%.3f", count / (elapsed_ms / 1000); else print "NA"}'
  )"
fi

{
  echo 'event_id,time_deal_id,expected_count,committed_count,consumer_received_epoch_ms,transaction_completed_epoch_ms,fanout_ms,result,notifications_per_second'
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${event_id}" \
    "${time_deal_id}" \
    "${subscriber_count}" \
    "${actual_count}" \
    "${received_epoch_ms}" \
    "${completed_epoch_ms}" \
    "${fanout_ms}" \
    "${fanout_status}" \
    "${notifications_per_second}"
} >"${fanout_result}"

max_lag="$(
  awk -F',' 'NR > 1 && $2 ~ /^[0-9]+$/ && $2 > max {max=$2}
    END {print max + 0}' "${lag_result}"
)"
final_lag="$(current_lag)"

{
  echo "scenario=${scenario}"
  echo "event_id=${event_id}"
  echo "time_deal_id=${time_deal_id}"
  echo "expected_notifications=${subscriber_count}"
  echo "committed_notifications=${actual_count}"
  echo "fanout_ms=${fanout_ms:-NA}"
  echo "notification_throughput=${notifications_per_second} notifications/s"
  echo "max_kafka_lag=${max_lag}"
  echo "final_kafka_lag=${final_lag}"
  echo "result=${fanout_status}"
} | tee "${fanout_summary}"

echo "[6/7] Collect errors and verify notification correctness"
{
  if [[ -f "${jtl_file}" ]]; then
    awk -F',' -v sampler="${sampler_name}" \
      'NR > 1 && $3 == sampler && $4 !~ /^2/ {print "jmeter," $0}' \
      "${jtl_file}"
  fi
  docker logs --since "${run_started_at}" notification-service 2>&1 |
    awk 'BEGIN {IGNORECASE=1} /ERROR|Exception|OutOfMemoryError|retries exhausted|rollback/'
} >"${error_result}" || true

set +e
psql "${db_url}" \
  -v event_id="${event_id}" \
  -v time_deal_id="${time_deal_id}" \
  -v expected_count="${subscriber_count}" \
  -f "${verify_sql}" | tee "${verify_result}"
verify_status=${PIPESTATUS[0]}
set -e

duplicate_count="$(
  psql "${db_url}" -Atq -c \
    "select count(*) from (select user_id from notification_schema.p_notifications where event_id = '${event_id}' group by user_id having count(*) > 1) duplicates;"
)"
missing_count="$(
  psql "${db_url}" -Atq -c \
    "select count(*) from (select user_id from notification_schema.p_time_deal_notification_subscriptions where time_deal_id = '${time_deal_id}' and deleted_at is null except select user_id from notification_schema.p_notifications where event_id = '${event_id}') missing;"
)"
unexpected_count="$(
  psql "${db_url}" -Atq -c \
    "select count(*) from (select user_id from notification_schema.p_notifications where event_id = '${event_id}' except select user_id from notification_schema.p_time_deal_notification_subscriptions where time_deal_id = '${time_deal_id}' and deleted_at is null) unexpected;"
)"
successful_publish_count="$(
  awk '$1 == "200" {count += $2} END {print count + 0}' "${publish_result}"
)"

correctness_status=0
if [[ "${actual_count}" != "${subscriber_count}" ||
      "${duplicate_count}" != '0' ||
      "${missing_count}" != '0' ||
      "${unexpected_count}" != '0' ||
      "${final_lag}" != '0' ||
      "${fanout_status}" != 'success' ||
      "${successful_publish_count}" != '1' ||
      -s "${error_result}" ]]; then
  correctness_status=1
fi

echo "[7/7] Complete"
echo "Scenario: ${scenario}"
echo "Event:    ${event_id}"
echo "Results:  ${results_dir}"
echo "Errors:   ${error_result}"
echo "Grafana:  capture Fan-out, DB Flush, JVM/GC and Hikari panels for this run"

if (( jmeter_status != 0 || wait_status != 0 || verify_status != 0 || correctness_status != 0 )); then
  exit 1
fi

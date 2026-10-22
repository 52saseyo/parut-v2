#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./performance-test/scripts/run-kafka-fanout-workload.sh <sequential|spike> <run-number>

Examples:
  ./performance-test/scripts/run-kafka-fanout-workload.sh sequential 1
  ./performance-test/scripts/run-kafka-fanout-workload.sh spike 1

Optional environment variables:
  DB_URL                PostgreSQL connection URL
  BOOTSTRAP_SERVERS     Kafka bootstrap servers for JMeter
  KAFKA_ADMIN_SERVER    Kafka bootstrap server inside the kafka container
  KAFKA_CONSUMER_GROUP  Consumer group to observe
  KAFKA_TOPIC           Kafka topic to publish
  KAFKA_CLIENT_JAR      kafka-clients JAR used by JMeter
  WAIT_TIMEOUT_SECONDS  Processing wait after JMeter finishes, default 180
  RECOVERY_OBSERVATION_SECONDS
                        Additional Spike observation after recovery, default 120
  RESULTS_DIR           Result directory, default ./test-results
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

test_type="$1"
run_number="$2"

if [[ "${test_type}" != 'sequential' && "${test_type}" != 'spike' ]]; then
  echo "test type must be sequential or spike" >&2
  exit 2
fi

if [[ ! "${run_number}" =~ ^[1-9][0-9]*$ ]]; then
  echo "run-number must be a positive integer" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_dir="$(cd "${script_dir}/../.." && pwd)"
cd "${service_dir}"

scenario="${test_type}-run-${run_number}"
results_dir="${RESULTS_DIR:-${service_dir}/test-results}"
db_url="${DB_URL:-postgresql://parut:parut123@localhost:5433/parut}"
bootstrap_servers="${BOOTSTRAP_SERVERS:-localhost:9092}"
kafka_admin_server="${KAFKA_ADMIN_SERVER:-localhost:9092}"
consumer_group="${KAFKA_CONSUMER_GROUP:-notification-time-deal-opening-soon}"
kafka_topic="${KAFKA_TOPIC:-time-deal.opening-soon}"
default_wait_timeout_seconds=180
if [[ "${test_type}" == 'spike' ]]; then
  default_wait_timeout_seconds=120
fi
wait_timeout_seconds="${WAIT_TIMEOUT_SECONDS:-${default_wait_timeout_seconds}}"
kafka_client_jar="${KAFKA_CLIENT_JAR:-${HOME}/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar}"

seed_sql="performance-test/data/kafka-fanout-workload-seed.sql"
verify_sql="performance-test/data/kafka-fanout-${test_type}-verify.sql"
jmeter_plan="performance-test/jmeter/kafka-fanout-${test_type}-test.jmx"
event_csv="performance-test/data/kafka-workload-${test_type}-events.csv"

expected_event_count=5
expected_notifications=18000
event_id_start='98100000-0000-4000-8000-000000000001'
event_id_end='98100000-0000-4000-8000-000000000005'
recovery_observation_seconds=0
if [[ "${test_type}" == 'spike' ]]; then
  expected_event_count=7
  expected_notifications=24000
  event_id_start='98200000-0000-4000-8000-000000000001'
  event_id_end='98200000-0000-4000-8000-000000000007'
  recovery_observation_seconds="${RECOVERY_OBSERVATION_SECONDS:-120}"
fi

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

for input_file in "${seed_sql}" "${verify_sql}" "${event_csv}" "${jmeter_plan}" "${kafka_client_jar}"; do
  if [[ ! -f "${input_file}" ]]; then
    echo "required file not found: ${input_file}" >&2
    exit 1
  fi
done

if [[ ! "${wait_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "WAIT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

if [[ ! "${recovery_observation_seconds}" =~ ^[0-9]+$ ]]; then
  echo "RECOVERY_OBSERVATION_SECONDS must be a non-negative integer" >&2
  exit 2
fi

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

event_metadata() {
  if [[ "${test_type}" == 'sequential' ]]; then
    awk -F',' 'NR > 1 {print $1 "," $6}' "${event_csv}"
  else
    awk -F',' 'NR > 1 {print $1 "," $7}' "${event_csv}"
  fi
}

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
monitor_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kafka-fanout.XXXXXX")"
event_metadata_file="${monitor_temp_dir}/events.csv"
event_count_file="${monitor_temp_dir}/event-counts.csv"
fanout_measurement_file="${monitor_temp_dir}/fanout-measurements.csv"
event_metadata >"${event_metadata_file}"

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
  rm -f \
    "${event_metadata_file}" \
    "${event_count_file}" \
    "${fanout_measurement_file}"
  rmdir "${monitor_temp_dir}" 2>/dev/null || true
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

echo "[1/7] Seed workload for ${scenario}"
psql "${db_url}" -f "${seed_sql}" | tee "${seed_result}"

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

echo "[4/7] Run ${test_type} JMeter plan"
set +e
jmeter -n -f \
  -Jsearch_paths="${kafka_client_jar}" \
  -t "${jmeter_plan}" \
  -JbootstrapServers="${bootstrap_servers}" \
  -Jtopic="${kafka_topic}" \
  -JeventCsv="${event_csv}" \
  -JeventCount="${expected_event_count}" \
  -Jthreads=1 \
  -JrampUp=1 \
  -l "${jtl_file}" \
  -j "${jmeter_log}"
jmeter_status=$?
set -e

sampler_name='Kafka opening-soon 이벤트 발행'
if [[ "${test_type}" == 'spike' ]]; then
  sampler_name='Kafka opening-soon Spike 이벤트 발행'
fi

if [[ -f "${jtl_file}" ]]; then
  awk -F',' -v sampler="${sampler_name}" \
    'NR > 1 && $3 == sampler {count[$4]++}
     END {for (code in count) print code, count[code]}' \
    "${jtl_file}" | tee "${publish_result}"

  sed -n 's/.*producerAckEpochMs=\([0-9][0-9]*\).*/\1/p' "${jtl_file}" |
    sort -n |
    awk 'NR == 1 {first = $1} {last = $1; count++}
         END {
           span_ms = count > 1 ? last - first : 0
           rate = span_ms > 0 ? count / (span_ms / 1000) : 0
           printf "producer_ack_count=%d\nproducer_ack_span_ms=%d\nkafka_event_rate=%.3f event/s\n", count, span_ms, rate
         }' | tee -a "${publish_result}"

  if [[ "${test_type}" == 'spike' ]]; then
    sed -n '/phase=spike/ s/.*producerAckEpochMs=\([0-9][0-9]*\).*/\1/p' "${jtl_file}" |
      sort -n |
      awk 'NR == 1 {first = $1} {last = $1; count++}
           END {
             span_ms = count > 1 ? last - first : 0
             printf "spike_producer_ack_count=%d\nspike_producer_ack_span_ms=%d\n", count, span_ms
           }' | tee -a "${publish_result}"
  fi
else
  : >"${publish_result}"
fi

echo "[5/7] Wait for ${expected_notifications} notifications and lag recovery"
deadline=$((SECONDS + wait_timeout_seconds))
stable_checks=0
wait_status=0

while (( SECONDS < deadline )); do
  actual_count="$(
    psql "${db_url}" -Atq -c \
      "select count(*) from notification_schema.p_notifications where event_id between '${event_id_start}' and '${event_id_end}';"
  )"
  observed_lag="$(current_lag)"

  if [[ "${actual_count}" == "${expected_notifications}" && "${observed_lag}" == '0' ]]; then
    stable_checks=$((stable_checks + 1))
    if (( stable_checks >= 2 )); then
      break
    fi
  else
    stable_checks=0
  fi

  sleep 2
done

if (( stable_checks < 2 )); then
  echo "processing did not complete within ${wait_timeout_seconds}s after publishing" >&2
  wait_status=1
fi

if (( wait_status == 0 && recovery_observation_seconds > 0 )); then
  echo "Observe recovered state for ${recovery_observation_seconds}s"
  sleep "${recovery_observation_seconds}"
fi

stop_monitors

docker logs --since "${run_started_at}" notification-service 2>&1 |
  sed -n \
    's/.*FANOUT_MEASUREMENT eventId=\([^,]*\), consumerReceivedEpochMs=\([0-9][0-9]*\), transactionCompletedEpochMs=\([0-9][0-9]*\), durationMs=\([0-9][0-9]*\), result=\([^, ]*\).*/\1,\2,\3,\4,\5/p' \
    >"${fanout_measurement_file}"

psql "${db_url}" -Atq -F',' -c \
  "select event_id, count(*) from notification_schema.p_notifications where event_id between '${event_id_start}' and '${event_id_end}' group by event_id;" \
  >"${event_count_file}"

printf 'event_id,expected_count,committed_count,consumer_received_epoch_ms,transaction_completed_epoch_ms,fanout_ms,result,notifications_per_second\n' \
  >"${fanout_result}"

while IFS=',' read -r event_id expected_count; do
  committed_count="$(
    awk -F',' -v id="${event_id}" '$1 == id {print $2; exit}' "${event_count_file}"
  )"
  committed_count="${committed_count:-0}"

  measurement="$(
    awk -F',' -v id="${event_id}" \
      '$1 == id {latest=$0} $1 == id && $5 == "success" {success=$0}
       END {if (success != "") print success; else print latest}' \
      "${fanout_measurement_file}"
  )"

  if [[ -z "${measurement}" ]]; then
    printf '%s,%s,%s,,,,missing,NA\n' \
      "${event_id}" "${expected_count}" "${committed_count}" >>"${fanout_result}"
    continue
  fi

  IFS=',' read -r _ received_epoch_ms completed_epoch_ms fanout_ms result \
    <<<"${measurement}"
  notifications_per_second="$(
    awk -v count="${committed_count}" -v elapsed_ms="${fanout_ms}" \
      'BEGIN {if (elapsed_ms > 0) printf "%.3f", count / (elapsed_ms / 1000); else print "NA"}'
  )"

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${event_id}" \
    "${expected_count}" \
    "${committed_count}" \
    "${received_epoch_ms}" \
    "${completed_epoch_ms}" \
    "${fanout_ms}" \
    "${result}" \
    "${notifications_per_second}" >>"${fanout_result}"
done <"${event_metadata_file}"

successful_transactions="$(
  awk -F',' 'NR > 1 && $7 == "success" {count++} END {print count + 0}' "${fanout_result}"
)"
failed_transactions="$(
  awk -F',' '$5 == "failure" {count++} END {print count + 0}' "${fanout_measurement_file}"
)"
committed_notifications="$(
  awk -F',' 'NR > 1 {sum += $3} END {print sum + 0}' "${fanout_result}"
)"
first_consumer_received_epoch_ms="$(
  awk -F',' 'NR > 1 && $7 == "success" && ($4 + 0) > 0 {
      if (first == "" || $4 < first) first=$4
    } END {print first}' "${fanout_result}"
)"
last_transaction_completed_epoch_ms="$(
  awk -F',' 'NR > 1 && $7 == "success" && ($5 + 0) > last {last=$5}
    END {if (last > 0) print last}' "${fanout_result}"
)"
fanout_average_ms="$(
  awk -F',' 'NR > 1 && $7 == "success" {sum += $6; count++}
    END {if (count > 0) printf "%.1f", sum / count; else print "NA"}' "${fanout_result}"
)"
fanout_max_ms="$(
  awk -F',' 'NR > 1 && $7 == "success" && ($6 + 0) > max {max=$6}
    END {if (max > 0) print max; else print "NA"}' "${fanout_result}"
)"

spike_first_consumer_received_epoch_ms=''
spike_last_transaction_completed_epoch_ms=''
spike_successful_transactions=0
spike_committed_notifications=0
baseline_fanout_ms='NA'
recovery_fanout_ms='NA'
if [[ "${test_type}" == 'spike' ]]; then
  spike_first_consumer_received_epoch_ms="$(
    awk -F',' 'NR > 1 && $1 ~ /^98200000-0000-4000-8000-00000000000[2-6]$/ &&
      $7 == "success" && ($4 + 0) > 0 {
        if (first == "" || $4 < first) first=$4
      } END {print first}' "${fanout_result}"
  )"
  spike_last_transaction_completed_epoch_ms="$(
    awk -F',' 'NR > 1 && $1 ~ /^98200000-0000-4000-8000-00000000000[2-6]$/ &&
      $7 == "success" && ($5 + 0) > last {last=$5}
      END {if (last > 0) print last}' "${fanout_result}"
  )"
  spike_successful_transactions="$(
    awk -F',' 'NR > 1 && $1 ~ /^98200000-0000-4000-8000-00000000000[2-6]$/ &&
      $7 == "success" {count++} END {print count + 0}' "${fanout_result}"
  )"
  spike_committed_notifications="$(
    awk -F',' 'NR > 1 && $1 ~ /^98200000-0000-4000-8000-00000000000[2-6]$/ {
      sum += $3
    } END {print sum + 0}' "${fanout_result}"
  )"
  baseline_fanout_ms="$(
    awk -F',' '$1 == "98200000-0000-4000-8000-000000000001" {print $6}' "${fanout_result}"
  )"
  recovery_fanout_ms="$(
    awk -F',' '$1 == "98200000-0000-4000-8000-000000000007" {print $6}' "${fanout_result}"
  )"
fi

fanout_window_ms='NA'
fanout_transaction_tps='NA'
notification_throughput='NA'
if [[ -n "${first_consumer_received_epoch_ms}" &&
      -n "${last_transaction_completed_epoch_ms}" ]]; then
  fanout_window_ms=$((
    last_transaction_completed_epoch_ms - first_consumer_received_epoch_ms
  ))
  fanout_transaction_tps="$(
    awk -v count="${successful_transactions}" -v elapsed_ms="${fanout_window_ms}" \
      'BEGIN {if (elapsed_ms > 0) printf "%.3f", count / (elapsed_ms / 1000); else print "NA"}'
  )"
  notification_throughput="$(
    awk -v count="${committed_notifications}" -v elapsed_ms="${fanout_window_ms}" \
      'BEGIN {if (elapsed_ms > 0) printf "%.3f", count / (elapsed_ms / 1000); else print "NA"}'
  )"
fi

spike_window_ms='NA'
spike_fanout_transaction_tps='NA'
spike_notification_throughput='NA'
if [[ "${test_type}" == 'spike' &&
      -n "${spike_first_consumer_received_epoch_ms}" &&
      -n "${spike_last_transaction_completed_epoch_ms}" ]]; then
  spike_window_ms=$((
    spike_last_transaction_completed_epoch_ms - spike_first_consumer_received_epoch_ms
  ))
  spike_fanout_transaction_tps="$(
    awk -v count="${spike_successful_transactions}" -v elapsed_ms="${spike_window_ms}" \
      'BEGIN {if (elapsed_ms > 0) printf "%.3f", count / (elapsed_ms / 1000); else print "NA"}'
  )"
  spike_notification_throughput="$(
    awk -v count="${spike_committed_notifications}" -v elapsed_ms="${spike_window_ms}" \
      'BEGIN {if (elapsed_ms > 0) printf "%.3f", count / (elapsed_ms / 1000); else print "NA"}'
  )"
fi

{
  echo "scenario=${scenario}"
  echo "successful_transactions=${successful_transactions}"
  echo "failed_transactions=${failed_transactions}"
  echo "committed_notifications=${committed_notifications}"
  echo "fanout_average_ms=${fanout_average_ms}"
  echo "fanout_max_ms=${fanout_max_ms}"

  if [[ "${fanout_window_ms}" != 'NA' ]]; then
    echo "first_consumer_received_epoch_ms=${first_consumer_received_epoch_ms}"
    echo "last_transaction_completed_epoch_ms=${last_transaction_completed_epoch_ms}"
    echo "fanout_window_ms=${fanout_window_ms}"
    echo "fanout_transaction_tps=${fanout_transaction_tps} transactions/s"
    echo "notification_throughput=${notification_throughput} notifications/s"
  else
    echo "fanout_window_ms=NA"
    echo "fanout_transaction_tps=NA"
    echo "notification_throughput=NA"
  fi

  if [[ "${test_type}" == 'spike' && "${spike_window_ms}" != 'NA' ]]; then
    echo "spike_successful_transactions=${spike_successful_transactions}"
    echo "spike_committed_notifications=${spike_committed_notifications}"
    echo "spike_window_ms=${spike_window_ms}"
    echo "spike_fanout_transaction_tps=${spike_fanout_transaction_tps} transactions/s"
    echo "spike_notification_throughput=${spike_notification_throughput} notifications/s"
    echo "baseline_fanout_ms=${baseline_fanout_ms}"
    echo "recovery_fanout_ms=${recovery_fanout_ms}"
  fi
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
psql "${db_url}" -f "${verify_sql}" | tee "${verify_result}"
verify_status=${PIPESTATUS[0]}
set -e

actual_count="$(
  psql "${db_url}" -Atq -c \
    "select count(*) from notification_schema.p_notifications where event_id between '${event_id_start}' and '${event_id_end}';"
)"
duplicate_count="$(
  psql "${db_url}" -Atq -c \
    "select count(*) from (select event_id, user_id from notification_schema.p_notifications where event_id between '${event_id_start}' and '${event_id_end}' group by event_id, user_id having count(*) > 1) duplicated;"
)"

correctness_status=0
if [[ "${actual_count}" != "${expected_notifications}" ||
      "${duplicate_count}" != '0' ||
      "${successful_transactions}" != "${expected_event_count}" ||
      "${failed_transactions}" != '0' ]]; then
  correctness_status=1
fi

producer_ack_count="$(awk -F= '$1 == "producer_ack_count" {print $2}' "${publish_result}")"
producer_ack_span_ms="$(awk -F= '$1 == "producer_ack_span_ms" {print $2}' "${publish_result}")"
if [[ "${producer_ack_count}" != "${expected_event_count}" ]]; then
  correctness_status=1
fi
if [[ "${test_type}" == 'spike' ]]; then
  spike_producer_ack_count="$(awk -F= '$1 == "spike_producer_ack_count" {print $2}' "${publish_result}")"
  spike_producer_ack_span_ms="$(awk -F= '$1 == "spike_producer_ack_span_ms" {print $2}' "${publish_result}")"
  if [[ "${spike_producer_ack_count}" != '5' ]] ||
     [[ ! "${spike_producer_ack_span_ms}" =~ ^[0-9]+$ ]] ||
     (( spike_producer_ack_span_ms > 1000 )); then
    correctness_status=1
  fi
  if [[ ! "${spike_window_ms}" =~ ^[0-9]+$ ]] ||
     (( spike_window_ms > 120000 )) ||
     [[ ! "${recovery_fanout_ms}" =~ ^[0-9]+$ ]] ||
     (( recovery_fanout_ms > 2000 )); then
    correctness_status=1
  fi
fi

event_mismatch_count="$(
  awk -F',' 'NR > 1 && $2 != $3 {count++} END {print count + 0}' "${fanout_result}"
)"

if [[ "${event_mismatch_count}" != '0' || -s "${error_result}" ]]; then
  correctness_status=1
fi

echo "[7/7] Complete"
echo "Scenario: ${scenario}"
echo "Results:  ${results_dir}"
echo "Errors:   ${error_result}"
echo "Grafana:  capture Fan-out, DB Flush, JVM/GC and Hikari panels for this run"

if (( jmeter_status != 0 || wait_status != 0 || verify_status != 0 || correctness_status != 0 )); then
  exit 1
fi

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
  COLLECT_JFR           Collect JVM Flight Recording, default false
  COLLECT_DB_DIAGNOSTICS
                        Collect DB snapshots and poll pg_stat_activity, default false
  COLLECT_HIBERNATE_STATISTICS
                        Collect Hibernate Session Metrics, default false
  COLLECT_KAFKA_LAG_DURING_RUN
                        Poll Kafka lag while Fan-out runs, default false
  KAFKA_LAG_POLL_INTERVAL_SECONDS
                        Kafka lag polling interval when enabled, default 10
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
collect_jfr="${COLLECT_JFR:-false}"
collect_db_diagnostics="${COLLECT_DB_DIAGNOSTICS:-false}"
collect_hibernate_statistics="${COLLECT_HIBERNATE_STATISTICS:-false}"
collect_kafka_lag_during_run="${COLLECT_KAFKA_LAG_DURING_RUN:-false}"
kafka_lag_poll_interval_seconds="${KAFKA_LAG_POLL_INTERVAL_SECONDS:-10}"
kafka_client_jar="${KAFKA_CLIENT_JAR:-${HOME}/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar}"

if [[ ! "${wait_timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "WAIT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

if [[ "${collect_jfr}" != 'true' && "${collect_jfr}" != 'false' ]]; then
  echo "COLLECT_JFR must be true or false" >&2
  exit 2
fi

if [[ "${collect_db_diagnostics}" != 'true' &&
      "${collect_db_diagnostics}" != 'false' ]]; then
  echo "COLLECT_DB_DIAGNOSTICS must be true or false" >&2
  exit 2
fi

if [[ "${collect_hibernate_statistics}" != 'true' &&
      "${collect_hibernate_statistics}" != 'false' ]]; then
  echo "COLLECT_HIBERNATE_STATISTICS must be true or false" >&2
  exit 2
fi

if [[ "${collect_kafka_lag_during_run}" != 'true' &&
      "${collect_kafka_lag_during_run}" != 'false' ]]; then
  echo "COLLECT_KAFKA_LAG_DURING_RUN must be true or false" >&2
  exit 2
fi

if [[ ! "${kafka_lag_poll_interval_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "KAFKA_LAG_POLL_INTERVAL_SECONDS must be a positive integer" >&2
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
diagnostics_sql="performance-test/sql/fanout-diagnostics.sql"
diagnostics_snapshot_sql="performance-test/sql/fanout-diagnostics-snapshot.sql"
jfr_script="performance-test/scripts/collect-fanout-jfr.sh"

jtl_file="${results_dir}/kafka-fanout-${scenario}.jtl"
jmeter_log="${results_dir}/kafka-fanout-${scenario}.log"
seed_result="${results_dir}/kafka-fanout-${scenario}-seed.txt"
verify_result="${results_dir}/kafka-fanout-${scenario}-verification.txt"
lag_result="${results_dir}/kafka-lag-${scenario}.csv"
stats_result="${results_dir}/container-stats-${scenario}.csv"
db_waits_result="${results_dir}/db-waits-${scenario}.csv"
consumer_result="${results_dir}/kafka-consumer-${scenario}.txt"
publish_result="${results_dir}/kafka-publish-count-${scenario}.txt"
error_result="${results_dir}/errors-${scenario}.txt"
fanout_result="${results_dir}/fanout-measurements-${scenario}.csv"
fanout_summary="${results_dir}/fanout-throughput-${scenario}-summary.txt"
phase_result="${results_dir}/fanout-phases-${scenario}.csv"
db_baseline_result="${results_dir}/db-diagnostics-baseline-${scenario}.txt"
db_result="${results_dir}/db-diagnostics-result-${scenario}.txt"
db_snapshot_before_result="${results_dir}/db-snapshot-before-${scenario}.csv"
db_snapshot_after_result="${results_dir}/db-snapshot-after-${scenario}.csv"
db_delta_result="${results_dir}/db-delta-${scenario}.txt"
container_summary_result="${results_dir}/container-summary-${scenario}.csv"
metadata_result="${results_dir}/metadata-${scenario}.txt"
jfr_result="${results_dir}/jfr-${scenario}.jfr"
hibernate_metrics_result="${results_dir}/hibernate-session-metrics-${scenario}.txt"

for command_name in psql jmeter docker awk; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "required command not found: ${command_name}" >&2
    exit 1
  fi
done

for input_file in \
  "${seed_sql}" \
  "${verify_sql}" \
  "${jmeter_plan}" \
  "${jfr_script}" \
  "${kafka_client_jar}"; do
  if [[ ! -f "${input_file}" ]]; then
    echo "required file not found: ${input_file}" >&2
    exit 1
  fi
done

if [[ "${collect_db_diagnostics}" == 'true' ]]; then
  for input_file in "${diagnostics_sql}" "${diagnostics_snapshot_sql}"; do
    if [[ ! -f "${input_file}" ]]; then
      echo "required file not found: ${input_file}" >&2
      exit 1
    fi
  done
fi

mkdir -p "${results_dir}"

for output_file in \
  "${jtl_file}" \
  "${jmeter_log}" \
  "${seed_result}" \
  "${verify_result}" \
  "${lag_result}" \
  "${stats_result}" \
  "${db_waits_result}" \
  "${consumer_result}" \
  "${publish_result}" \
  "${error_result}" \
  "${fanout_result}" \
  "${fanout_summary}" \
  "${phase_result}" \
  "${db_baseline_result}" \
  "${db_result}" \
  "${db_snapshot_before_result}" \
  "${db_snapshot_after_result}" \
  "${db_delta_result}" \
  "${container_summary_result}" \
  "${metadata_result}"; do
  if [[ -e "${output_file}" ]]; then
    echo "result already exists: ${output_file}" >&2
    echo "use another run-number or move the existing result first" >&2
    exit 1
  fi
done

if [[ "${collect_jfr}" == 'true' && -e "${jfr_result}" ]]; then
  echo "result already exists: ${jfr_result}" >&2
  echo "use another run-number or move the existing result first" >&2
  exit 1
fi

if [[ "${collect_hibernate_statistics}" == 'true' &&
      -e "${hibernate_metrics_result}" ]]; then
  echo "result already exists: ${hibernate_metrics_result}" >&2
  echo "use another run-number or move the existing result first" >&2
  exit 1
fi

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
  while true; do
    printf '%s,%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(current_lag)"
    sleep "${kafka_lag_poll_interval_seconds}"
  done
}

monitor_containers() {
  printf 'timestamp,container,cpu_percent,memory_usage,net_io,block_io,pids\n'
  while true; do
    test_time="$(date '+%Y-%m-%d %H:%M:%S')"
    docker stats --no-stream \
      --format "${test_time},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}" \
      postgres notification-service kafka prometheus
    sleep 1
  done
}

calculate_db_delta() {
  awk -F',' '
    NR == FNR {
      if (FNR == 1) {
        for (i = 1; i <= NF; i++) header[i] = $i
      } else {
        for (i = 1; i <= NF; i++) before[i] = $i
      }
      next
    }
    FNR == 1 { next }
    {
      for (i = 2; i <= NF; i++) {
        delta = ($i + 0) - (before[i] + 0)
        printf "%s_delta=%.3f\n", header[i], delta
      }
    }
  ' "${db_snapshot_before_result}" "${db_snapshot_after_result}" \
    >"${db_delta_result}"
}

summarize_containers() {
  awk -F',' '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function bytes(value, number) {
      value = trim(value)
      number = value + 0
      if (value ~ /KiB$/) return number * 1024
      if (value ~ /MiB$/) return number * 1024 * 1024
      if (value ~ /GiB$/) return number * 1024 * 1024 * 1024
      if (value ~ /kB$/) return number * 1000
      if (value ~ /MB$/) return number * 1000 * 1000
      if (value ~ /GB$/) return number * 1000 * 1000 * 1000
      return number
    }
    NR == 1 { next }
    {
      container = $2
      cpu = $3
      gsub(/%/, "", cpu)

      split($4, memory, "/")
      memory_bytes = bytes(memory[1])

      split($5, network, "/")
      network_receive_bytes = bytes(network[1])
      network_transmit_bytes = bytes(network[2])

      split($6, block, "/")
      block_read_bytes = bytes(block[1])
      block_write_bytes = bytes(block[2])

      cpu_sum[container] += cpu
      samples[container]++
      if (cpu > cpu_max[container]) cpu_max[container] = cpu
      if (memory_bytes > memory_max[container]) memory_max[container] = memory_bytes
      if ($7 + 0 > pids_max[container]) pids_max[container] = $7 + 0

      if (!(container in first_network_receive)) {
        first_network_receive[container] = network_receive_bytes
        first_network_transmit[container] = network_transmit_bytes
        first_block_read[container] = block_read_bytes
        first_block_write[container] = block_write_bytes
      }

      last_network_receive[container] = network_receive_bytes
      last_network_transmit[container] = network_transmit_bytes
      last_block_read[container] = block_read_bytes
      last_block_write[container] = block_write_bytes
    }
    END {
      print "container,samples,cpu_avg_percent,cpu_max_percent,memory_max_mib,network_receive_delta_bytes,network_transmit_delta_bytes,block_read_delta_bytes,block_write_delta_bytes,pids_max"
      for (container in samples) {
        printf "%s,%d,%.3f,%.3f,%.3f,%.0f,%.0f,%.0f,%.0f,%d\n",
          container,
          samples[container],
          cpu_sum[container] / samples[container],
          cpu_max[container],
          memory_max[container] / 1024 / 1024,
          last_network_receive[container] - first_network_receive[container],
          last_network_transmit[container] - first_network_transmit[container],
          last_block_read[container] - first_block_read[container],
          last_block_write[container] - first_block_write[container],
          pids_max[container]
      }
    }
  ' "${stats_result}" >"${container_summary_result}"
}

monitor_db_waits() {
  printf 'timestamp,pid,application_name,backend_type,state,xact_age_ms,wait_event_type,wait_event,query\n'
  while true; do
    psql "${db_url}" --csv -t -c "
      SELECT clock_timestamp(),
             pid,
             application_name,
             backend_type,
             state,
             COALESCE(
                 EXTRACT(EPOCH FROM (clock_timestamp() - xact_start)) * 1000,
                 0
             )::bigint,
             COALESCE(wait_event_type, '-'),
             COALESCE(wait_event, '-'),
             LEFT(REGEXP_REPLACE(query, E'[\\n\\r]+', ' ', 'g'), 300)
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND pid <> pg_backend_pid()
        AND state <> 'idle';
    "
    sleep 0.5
  done
}

lag_pid=''
stats_pid=''
db_waits_pid=''
jfr_active='false'
monitor_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kafka-fanout-stress.XXXXXX")"
fanout_measurement_file="${monitor_temp_dir}/fanout-measurements.csv"
flush_measurement_file="${monitor_temp_dir}/flush-measurements.csv"
commit_measurement_file="${monitor_temp_dir}/commit-measurements.csv"
run_log_file="${monitor_temp_dir}/notification-service.log"

stop_monitors() {
  for monitor_pid in "${lag_pid}" "${stats_pid}" "${db_waits_pid}"; do
    if [[ -n "${monitor_pid}" ]] && kill -0 "${monitor_pid}" 2>/dev/null; then
      kill "${monitor_pid}" 2>/dev/null || true
      wait "${monitor_pid}" 2>/dev/null || true
    fi
  done
  lag_pid=''
  stats_pid=''
  db_waits_pid=''
}

stop_jfr() {
  if [[ "${jfr_active}" == 'true' ]]; then
    jfr_active='false'
    "${jfr_script}" stop "${scenario}" "${jfr_result}"
  fi
}

cleanup() {
  stop_jfr || true
  stop_monitors
  rm -f \
    "${fanout_measurement_file}" \
    "${flush_measurement_file}" \
    "${commit_measurement_file}" \
    "${run_log_file}"
  rmdir "${monitor_temp_dir}" 2>/dev/null || true
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

shared_preload_libraries='not_collected'
track_io_timing='not_collected'
track_wal_io_timing='not_collected'

if [[ "${collect_db_diagnostics}" == 'true' ]]; then
  diagnostic_settings="$(
    psql "${db_url}" -Atq -F'|' -c \
      "select current_setting('shared_preload_libraries'), current_setting('track_io_timing'), current_setting('track_wal_io_timing');"
  )"
  IFS='|' read -r shared_preload_libraries track_io_timing track_wal_io_timing \
    <<<"${diagnostic_settings}"

  if [[ "${shared_preload_libraries}" != *pg_stat_statements* ||
        "${track_io_timing}" != 'on' ||
        "${track_wal_io_timing}" != 'on' ]]; then
    echo "PostgreSQL diagnostics are not enabled." >&2
    echo "Recreate PostgreSQL with the diagnostics Compose overlay." >&2
    exit 1
  fi
fi

kafka_healthcheck_command="$(
  docker inspect kafka --format '{{json .Config.Healthcheck.Test}}'
)"
case "${kafka_healthcheck_command}" in
  *kafka-broker-api-versions*) kafka_healthcheck_type='java-cli' ;;
  *'/dev/tcp/'*) kafka_healthcheck_type='tcp' ;;
  *) kafka_healthcheck_type='unknown' ;;
esac

hibernate_batch_size="$(
  docker inspect notification-service \
    --format '{{range .Config.Env}}{{println .}}{{end}}' |
    awk -F= '
      $1 == "SPRING_JPA_PROPERTIES_HIBERNATE_JDBC_BATCH_SIZE" {
        print $2
        exit
      }
    '
)"

if [[ -z "${hibernate_batch_size}" ]]; then
  hibernate_batch_size="$({
    awk '
      $1 == "jdbc:" {in_jdbc=1; next}
      in_jdbc && $1 == "batch_size:" {print $2; exit}
    ' src/main/resources/application.yml
  } || true)"
fi
hibernate_batch_size="${hibernate_batch_size:-unknown}"

hibernate_statistics_enabled="$(
  docker inspect notification-service \
    --format '{{range .Config.Env}}{{println .}}{{end}}' |
    awk -F= '
      $1 == "SPRING_JPA_PROPERTIES_HIBERNATE_GENERATE_STATISTICS" {
        print tolower($2)
        exit
      }
    '
)"
hibernate_statistics_enabled="${hibernate_statistics_enabled:-false}"

if [[ "${collect_hibernate_statistics}" == 'true' &&
      "${hibernate_statistics_enabled}" != 'true' ]]; then
  echo "Hibernate statistics are not enabled." >&2
  echo "Recreate notification-service with the diagnostics Compose overlay." >&2
  exit 1
fi

notification_limits="$(
  docker inspect notification-service \
    --format '{{.HostConfig.NanoCpus}}|{{.HostConfig.Memory}}'
)"
IFS='|' read -r notification_nano_cpus notification_memory_limit_bytes \
  <<<"${notification_limits}"

echo "[1/8] Seed ${subscriber_count} subscribers for ${scenario}"
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

echo "[2/8] Record Consumer assignment and validate initial lag"
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

{
  printf 'timestamp,lag\n'
  printf '%s,%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${initial_lag}"
} >"${lag_result}"

if [[ "${collect_db_diagnostics}" == 'true' ]]; then
  echo "[3/8] Capture PostgreSQL diagnostic baseline"
  psql "${db_url}" -v ON_ERROR_STOP=1 -c \
    'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
  psql "${db_url}" -v ON_ERROR_STOP=1 -f "${diagnostics_sql}" \
    >"${db_baseline_result}"
  psql "${db_url}" --csv -v ON_ERROR_STOP=1 \
    -f "${diagnostics_snapshot_sql}" >"${db_snapshot_before_result}"
else
  echo "[3/8] PostgreSQL diagnostic snapshots disabled"
fi

run_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

echo "[4/8] Start container and database monitoring"
if [[ "${collect_kafka_lag_during_run}" == 'true' ]]; then
  echo "Kafka lag polling enabled: every ${kafka_lag_poll_interval_seconds}s"
  monitor_lag >>"${lag_result}" &
  lag_pid=$!
else
  echo "Kafka lag polling disabled during Fan-out"
fi
monitor_containers >"${stats_result}" &
stats_pid=$!
if [[ "${collect_db_diagnostics}" == 'true' ]]; then
  monitor_db_waits >"${db_waits_result}" &
  db_waits_pid=$!
else
  echo "PostgreSQL wait polling disabled during Fan-out"
fi

if [[ "${collect_jfr}" == 'true' ]]; then
  "${jfr_script}" start "${scenario}"
  jfr_active='true'
fi

echo "[5/8] Publish one ${subscriber_count}-subscriber Stress event"
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

echo "[6/8] Wait for ${subscriber_count} notifications"
deadline=$((SECONDS + wait_timeout_seconds))
stable_checks=0
wait_status=0

while (( SECONDS < deadline )); do
  actual_count="$(
    psql "${db_url}" -Atq -c \
      "select count(*) from notification_schema.p_notifications where event_id = '${event_id}';"
  )"

  if [[ "${actual_count}" == "${subscriber_count}" ]]; then
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

stop_jfr
stop_monitors

# Keep Kafka CLI processes outside the measured CPU window.
sleep 2
final_lag='NA'
lag_recovery_deadline=$((SECONDS + wait_timeout_seconds))
while (( SECONDS < lag_recovery_deadline )); do
  final_lag="$(current_lag)"
  printf '%s,%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${final_lag}" \
    >>"${lag_result}"
  if [[ "${final_lag}" == '0' ]]; then
    break
  fi
  sleep 5
done

echo "[7/8] Capture measurements and verify notification correctness"
if [[ "${collect_db_diagnostics}" == 'true' ]]; then
  psql "${db_url}" -v ON_ERROR_STOP=1 -f "${diagnostics_sql}" \
    >"${db_result}"
  psql "${db_url}" --csv -v ON_ERROR_STOP=1 \
    -f "${diagnostics_snapshot_sql}" >"${db_snapshot_after_result}"
  calculate_db_delta
fi
summarize_containers

docker logs --since "${run_started_at}" notification-service \
  >"${run_log_file}" 2>&1

if [[ "${collect_hibernate_statistics}" == 'true' ]]; then
  awk -v expected_entities="${subscriber_count}" '
    /Logging session metrics:/ {
      capture = 1
      block = $0 ORS
      has_jdbc_batches = 0
      flushed_entities = 0
      next
    }
    capture {
      block = block $0 ORS
    }
    capture && /ns executing [1-9][0-9]* JDBC batches/ {
      has_jdbc_batches = 1
    }
    capture && /ns executing [0-9]+ flushes \(flushing a total of [0-9]+ entities/ {
      flush_line = $0
      sub(/^.*flushing a total of /, "", flush_line)
      sub(/ entities.*$/, "", flush_line)
      flushed_entities = flush_line + 0
    }
    capture && /partial-flushes \(flushing a total of [0-9]+ entities/ {
      if (has_jdbc_batches && flushed_entities >= expected_entities) {
        printf "%s", block
      }
      capture = 0
      block = ""
    }
  ' "${run_log_file}" >"${hibernate_metrics_result}"

  if [[ ! -s "${hibernate_metrics_result}" ]]; then
    echo "Hibernate Session Metrics for the ${subscriber_count}-subscriber batch were not found." >&2
    exit 1
  fi
fi

sed -n \
  's/.*FANOUT_MEASUREMENT eventId=\([^,]*\), consumerReceivedEpochMs=\([0-9][0-9]*\), transactionCompletedEpochMs=\([0-9][0-9]*\), durationMs=\([0-9][0-9]*\), result=\([^, ]*\).*/\1,\2,\3,\4,\5/p' \
  "${run_log_file}" >"${fanout_measurement_file}"

sed -n \
  's/.*FANOUT_FLUSH_MEASUREMENT eventId=\([^,]*\), durationMs=\([0-9][0-9]*\).*/\1,\2/p' \
  "${run_log_file}" >"${flush_measurement_file}"

sed -n \
  's/.*FANOUT_COMMIT_MEASUREMENT eventId=\([^,]*\), durationMs=\([0-9][0-9]*\), result=\([^, ]*\).*/\1,\2,\3/p' \
  "${run_log_file}" >"${commit_measurement_file}"

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

flush_measurement="$(
  awk -F',' -v id="${event_id}" '$1 == id {latest=$0} END {print latest}' \
    "${flush_measurement_file}"
)"

commit_measurement="$(
  awk -F',' -v id="${event_id}" \
    '$1 == id {latest=$0} $1 == id && $3 == "success" {success=$0}
     END {if (success != "") print success; else print latest}' \
    "${commit_measurement_file}"
)"

received_epoch_ms=''
completed_epoch_ms=''
fanout_ms=''
fanout_status='missing'
flush_ms=''
commit_ms=''
commit_status='missing'
notifications_per_second='NA'

if [[ -n "${measurement}" ]]; then
  IFS=',' read -r _ received_epoch_ms completed_epoch_ms fanout_ms fanout_status \
    <<<"${measurement}"
  notifications_per_second="$(
    awk -v count="${actual_count}" -v elapsed_ms="${fanout_ms}" \
      'BEGIN {if (elapsed_ms > 0) printf "%.3f", count / (elapsed_ms / 1000); else print "NA"}'
  )"
fi

if [[ -n "${flush_measurement}" ]]; then
  IFS=',' read -r _ flush_ms <<<"${flush_measurement}"
fi

if [[ -n "${commit_measurement}" ]]; then
  IFS=',' read -r _ commit_ms commit_status <<<"${commit_measurement}"
fi

{
  echo 'event_id,flush_ms,commit_ms,commit_result'
  printf '%s,%s,%s,%s\n' \
    "${event_id}" \
    "${flush_ms}" \
    "${commit_ms}" \
    "${commit_status}"
} >"${phase_result}"

{
  echo 'event_id,time_deal_id,expected_count,committed_count,consumer_received_epoch_ms,transaction_completed_epoch_ms,fanout_ms,flush_ms,commit_ms,result,notifications_per_second'
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${event_id}" \
    "${time_deal_id}" \
    "${subscriber_count}" \
    "${actual_count}" \
    "${received_epoch_ms}" \
    "${completed_epoch_ms}" \
    "${fanout_ms}" \
    "${flush_ms}" \
    "${commit_ms}" \
    "${fanout_status}" \
    "${notifications_per_second}"
} >"${fanout_result}"

max_observed_lag='not_collected'
if [[ "${collect_kafka_lag_during_run}" == 'true' ]]; then
  max_observed_lag="$(
    awk -F',' 'NR > 1 && $2 ~ /^[0-9]+$/ && $2 > max {max=$2}
      END {print max + 0}' "${lag_result}"
  )"
fi
run_completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

{
  echo "scenario=${scenario}"
  echo "event_id=${event_id}"
  echo "time_deal_id=${time_deal_id}"
  echo "subscriber_count=${subscriber_count}"
  echo "run_number=${run_number}"
  echo "started_at=${run_started_at}"
  echo "completed_at=${run_completed_at}"
  echo "kafka_healthcheck_type=${kafka_healthcheck_type}"
  echo "kafka_healthcheck_command=${kafka_healthcheck_command}"
  echo "hibernate_batch_size=${hibernate_batch_size}"
  echo "notification_nano_cpus=${notification_nano_cpus}"
  echo "notification_memory_limit_bytes=${notification_memory_limit_bytes}"
  echo "postgres_track_io_timing=${track_io_timing}"
  echo "postgres_track_wal_io_timing=${track_wal_io_timing}"
  echo "initial_kafka_lag=${initial_lag}"
  echo "final_kafka_lag=${final_lag}"
  echo "collect_kafka_lag_during_run=${collect_kafka_lag_during_run}"
  echo "kafka_lag_poll_interval_seconds=${kafka_lag_poll_interval_seconds}"
  echo "collect_db_diagnostics=${collect_db_diagnostics}"
  echo "collect_hibernate_statistics=${collect_hibernate_statistics}"
  echo "hibernate_statistics_enabled=${hibernate_statistics_enabled}"
  echo "collect_jfr=${collect_jfr}"
} >"${metadata_result}"

{
  echo "scenario=${scenario}"
  echo "event_id=${event_id}"
  echo "time_deal_id=${time_deal_id}"
  echo "expected_notifications=${subscriber_count}"
  echo "committed_notifications=${actual_count}"
  echo "fanout_ms=${fanout_ms:-NA}"
  echo "flush_ms=${flush_ms:-NA}"
  echo "commit_ms=${commit_ms:-NA}"
  echo "notification_throughput=${notifications_per_second} notifications/s"
  echo "max_observed_kafka_lag=${max_observed_lag}"
  echo "final_kafka_lag=${final_lag}"
  echo "result=${fanout_status}"
} | tee "${fanout_summary}"

echo "[8/8] Collect errors and verify notification correctness"
{
  if [[ -f "${jtl_file}" ]]; then
    awk -F',' -v sampler="${sampler_name}" \
      'NR > 1 && $3 == sampler && $4 !~ /^2/ {print "jmeter," $0}' \
      "${jtl_file}"
  fi
  awk 'BEGIN {IGNORECASE=1} /ERROR|Exception|OutOfMemoryError|retries exhausted|rollback/' \
    "${run_log_file}"
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
      -z "${flush_ms}" ||
      -z "${commit_ms}" ||
      "${commit_status}" != 'success' ||
      "${successful_publish_count}" != '1' ||
      -s "${error_result}" ]]; then
  correctness_status=1
fi

echo "Complete"
echo "Scenario: ${scenario}"
echo "Event:    ${event_id}"
echo "Results:  ${results_dir}"
echo "Errors:   ${error_result}"
echo "Grafana:  capture Fan-out, JPA Flush, Commit, JVM/GC and Hikari panels for this run"

if (( jmeter_status != 0 || wait_status != 0 || verify_status != 0 || correctness_status != 0 )); then
  exit 1
fi

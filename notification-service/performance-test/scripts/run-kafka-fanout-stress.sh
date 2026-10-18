#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./performance-test/scripts/run-kafka-fanout-stress.sh <subscriber-count> <run-number>

Example:
  ./performance-test/scripts/run-kafka-fanout-stress.sh 30000 1

Optional environment variables:
  DB_URL                PostgreSQL connection URL
  BOOTSTRAP_SERVERS     Kafka bootstrap servers for JMeter
  KAFKA_ADMIN_SERVER    Kafka bootstrap server inside the kafka container
  KAFKA_CONSUMER_GROUP  Consumer group to observe
  KAFKA_TOPIC           Kafka topic to publish
  KAFKA_CLIENT_JAR      kafka-clients JAR used by JMeter
  WAIT_TIMEOUT_SECONDS  Maximum processing wait time, default 600
  RESULTS_DIR           Result directory, default ./test-results
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

subscriber_count="$1"
run_number="$2"

if [[ ! "${subscriber_count}" =~ ^[1-9][0-9]*$ ]]; then
  echo "subscriber-count must be a positive integer" >&2
  exit 2
fi

if [[ ! "${run_number}" =~ ^[1-9][0-9]*$ ]]; then
  echo "run-number must be a positive integer" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_dir="$(cd "${script_dir}/../.." && pwd)"
cd "${service_dir}"

if (( subscriber_count % 1000 == 0 )); then
  subscriber_label="$((subscriber_count / 1000))k"
else
  subscriber_label="${subscriber_count}"
fi

scenario="stress-${subscriber_label}-run-${run_number}"
results_dir="${RESULTS_DIR:-${service_dir}/test-results}"
db_url="${DB_URL:-postgresql://parut:parut123@localhost:5433/parut}"
bootstrap_servers="${BOOTSTRAP_SERVERS:-localhost:9092}"
kafka_admin_server="${KAFKA_ADMIN_SERVER:-localhost:9092}"
consumer_group="${KAFKA_CONSUMER_GROUP:-notification-time-deal-opening-soon}"
kafka_topic="${KAFKA_TOPIC:-time-deal.opening-soon}"
wait_timeout_seconds="${WAIT_TIMEOUT_SECONDS:-600}"
kafka_client_jar="${KAFKA_CLIENT_JAR:-${HOME}/.gradle/caches/modules-2/files-2.1/org.apache.kafka/kafka-clients/4.2.1/6addc9b1f038d2dde0fc6b34464b1061ec5fb4c1/kafka-clients-4.2.1.jar}"

seed_sql="performance-test/data/kafka-fanout-load-seed.sql"
verify_sql="performance-test/data/kafka-fanout-scenario-verify.sql"
event_csv="performance-test/data/kafka-load-events.csv"
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
  "${error_result}"; do
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

trap stop_monitors EXIT
trap 'stop_monitors; exit 130' INT TERM

echo "[1/6] Seed ${subscriber_count} subscriptions for ${scenario}"
psql "${db_url}" \
  -v event_count=1 \
  -v subscriber_count="${subscriber_count}" \
  -f "${seed_sql}" |
  tee "${seed_result}"

echo "[2/6] Record Consumer assignment"
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

echo "[3/6] Start Kafka lag and container monitoring"
monitor_lag >"${lag_result}" &
lag_pid=$!
monitor_containers >"${stats_result}" &
stats_pid=$!

echo "[4/6] Publish one event with JMeter"
set +e
jmeter -n -f \
  -Jsearch_paths="${kafka_client_jar}" \
  -t "${jmeter_plan}" \
  -JbootstrapServers="${bootstrap_servers}" \
  -Jtopic="${kafka_topic}" \
  -JeventCsv="${event_csv}" \
  -JeventCount=1 \
  -JrampUp=1 \
  -l "${jtl_file}" \
  -j "${jmeter_log}"
jmeter_status=$?
set -e

if [[ -f "${jtl_file}" ]]; then
  awk -F',' 'NR > 1 && $3 == "Kafka opening-soon Stress 이벤트 발행" {
    count[$4]++
  } END {
    for (code in count) print code, count[code]
  }' "${jtl_file}" | tee "${publish_result}"

  awk -F',' 'NR > 1 && $3 == "Kafka opening-soon Stress 이벤트 발행" && $4 !~ /^2/ {
    print
  }' "${jtl_file}" | tee "${error_result}"
else
  : >"${publish_result}"
  echo "JMeter did not create ${jtl_file}" | tee "${error_result}" >&2
fi

echo "[5/6] Wait for ${subscriber_count} notifications and lag recovery"
deadline=$((SECONDS + wait_timeout_seconds))
stable_checks=0
wait_status=0

while (( SECONDS < deadline )); do
  actual_count="$(
    psql "${db_url}" -Atq -c \
      "select count(*) from notification_schema.p_notifications where event_id = '98000000-0000-4000-8000-000000000001';"
  )"
  observed_lag="$(current_lag)"

  if [[ "${actual_count}" == "${subscriber_count}" && "${observed_lag}" == '0' ]]; then
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
  echo "processing did not complete within ${wait_timeout_seconds}s" >&2
  wait_status=1
fi

stop_monitors

echo "[6/6] Verify notification correctness"
set +e
psql "${db_url}" \
  -v event_count=1 \
  -v subscriber_count="${subscriber_count}" \
  -f "${verify_sql}" |
  tee "${verify_result}"
verify_status=${PIPESTATUS[0]}
set -e

echo
echo "Scenario: ${scenario}"
echo "Results:  ${results_dir}"
echo "Grafana:  capture the Fan-out, DB Flush, JVM/GC and Hikari panels separately"

if (( jmeter_status != 0 || wait_status != 0 || verify_status != 0 )); then
  exit 1
fi

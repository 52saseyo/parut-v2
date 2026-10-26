# 정산 자동 완료 대시보드

화면: http://localhost:3000/d/settlement-completion

## 데이터 흐름과 화면 구성

대시보드 제목은 `Settlement Completion Performance Dashboard`이며 내부 표기는 한국어다. 측정 결과는 3열로 배치하고 DB 커넥션과 실행 상세를 아래에 둔다.

- 측정 결과: 처리 완료 건수, 전체 실행시간, 초당 정산 처리 건수(단위 `rows/s`). 기존 Counter/Timer에 PromQL을 적용한 결과이며 로그에서 값을 넣지 않는다.
- 자원 사용량: `CPU 사용률 (Process / System)` 패널은 `process_cpu_time_ns_total`의 증가율을 코어 수로 나눈 Process 값과 `system_cpu_usage`인 System 값을 표시한다. 개선 전후 비교는 Process 기준으로 한다.
- DB 커넥션: Active/Idle/Pending, 평균 커넥션 획득 시간, 커넥션 타임아웃(누적값).
- 실행 상세: 공용 Alloy/Loki에서 조회하는 별도 실행 상세. 실행 ID는 이 영역만 필터링한다. 상단 측정 결과에는 적용되지 않는다.

## 직접 확인하는 순서

1. 정상 실행만 포함하는 짧은 시간 구간을 선택한다. 작업 시작 전과 완료 후의 Prometheus 수집 표본이 모두 있어야 한다. 다른 실행/중단/재시작이 섞인 구간으로 성능 비교하지 않는다.
2. 각 누적 메트릭의 종료 시점 최신 표본에서 시작 시점 최신 표본을 뺀다. PromQL은 `metric - metric offset ${__range_s}s`를 사용하고 Grafana는 종료 시점의 instant query로 평가한다. 각 경계값은 해당 시각 이전의 최신 수집값이므로 실행 전후 표본이 확보됐는지 확인한다.
3. 처리 완료 건수는 완료 Counter 차이, 전체 실행시간은 Job Timer sum 차이 × 1,000(ms), 초당 정산 처리 건수는 완료 건수 차이 ÷ Timer sum 차이(초)다. 조회 기간 길이로 나누는 rate(counter)와 다르다.
4. 정상 실행, 무재시작/reset, 실행 전후 표본 확보는 테스트 조건으로 직접 확인한다. 패널 쿼리에서 Job count/프로세스 시작 시각/resets 검사를 반복하지 않는다. 현재 메트릭으로 실패 실행 유무를 자동 검출하지 못하므로 정상 실행만 분리한 구간에서 사용한다.
5. 같은 구간의 Hikari 그래프로 부하와 대기를 확인한다. 정확한 완료 건수는 DB 결과와 대조하고, 로그 상세는 보조 확인에 쓴다.

### 회차별 값 확인

상단 숫자 패널은 선택한 시간 범위의 증가량이므로 실행 한 번만 포함하도록 범위를 잡는다(예: 실행 시작 20초 전부터 종료 25초 후까지).
범위에 서버 재시작이 포함되면 누적값이 초기화되어 값이 틀어진다.
실행 상세는 실행 ID를 입력해 확인한다. 이 필터는 상단 숫자 패널에는 적용되지 않는다.
화면은 한국 시간이며 컨테이너 로그는 UTC다.

범례에는 Max와 Mean을 표시한다.
전체 실행시간 숫자 패널은 ms로 고정 표시한다.

## 집계 기준과 한계

완료 Counter는 청크 커밋 직후 증가하며 나중에 Job이 중단돼도 앞선 커밋 건수를 포함한다. 정상 Job Timer는 정상 종료 시에만 기록된다. 따라서 두 누적값이나 증가량을 조건 확인 없이 나누지 않는다. 상단 측정 결과는 정상 실행만 분리한 검증 구간에서 사용한다. 정상/중단을 섞는 운영 집계는 계측 범위를 맞추기 전 지원하지 않는다.

현재 실행 상세는 공용 수집 라벨 `platform="docker", service_name="parut-settlement-perf-order-perf-1"`로 로컬 perf 컨테이너를 조회한다. 쿼리는 공용 수집 라벨을 사용한다. 공용 로그 수집에는 기존 `docker-compose.infra.yml`의 Alloy를 사용한다.

```sh
docker compose --env-file /dev/null -p parut-v2 -f docker-compose.infra.yml up -d --no-deps --pull never alloy
```

Loki/Prometheus/Grafana와 perf 서버가 준비된 상태를 전제로 한다.

로그 보관 기간은 현재 7일이며 영구 실행 이력이 아니다. 없는 ID/기간 밖 결과는 기록 없음이며 0건/0ms가 아니다. 중단 로그에는 앞선 완료 건수는 있으나 전체 실행시간이 없어 중단 실행의 처리량을 계산하지 않는다. 실행 이력 표는 최대 1,000개 로그다. 실행 ID는 메트릭 태그나 Loki 인덱스 라벨에 추가하지 않고 조회할 때 추출한다.

HikariCP 풀 통계는 약 1초 갱신, Prometheus는 5초 수집이므로 짧은 실행의 순간 Active/Pending을 놓칠 수 있다. 연결 획득 평균은 rate(sum)/rate(count)이며 rate 조회 구간이 화면 시작 시각 이전까지 포함할 수 있다. 단일 실행 전용 평균으로 읽지 않는다. 정확한 실행별 대조는 보존된 전후 메트릭과 DB 표본을 사용한다. Counter 최초 생성 전 증가분은 rate/increase만으로 복원할 수 없고 재시작 시 누적값도 초기화된다.

정산 완료는 DB 상태 변경이며 실제 송금이 아니다. P95/P99, 운영 최대 처리량이나 장애 내구성의 검증 자료로 확대하지 않는다.

# 정산 완료 자동화 성능 검증

## 목적

정산 자동 완료 작업의 10,000건 처리 비용을 건별 커밋과 청크 커밋 방식으로 비교했다. 실제 송금과 정산 생성은 테스트 범위에 포함하지 않는다.

대기 상태(`PENDING`)이고 완료 가능 시각(`eligibleAt`)이 작업 기준 시각(`cutoff`) 이하인 ID를 조회한다. 100건씩 조건부 벌크 UPDATE하고 청크별로 커밋한다. DB 오류가 발생하면 실패 청크는 롤백하고 중단하며, 앞선 커밋은 유지한다. 스케줄러는 실행 시 `Instant.now()`를 cutoff로 고정하고 sellerId 없이 전체 판매자를 처리한다. 실패 원인을 제거하면 다음 정기 실행이 새 cutoff로 남은 대상을 처리한다. 같은 cutoff로 수동 재실행하는 진입점은 없다.

## 환경

- 전용 PostgreSQL `settlement_perf`, perf 주문 서버
- 실행 구성: `docker-compose.perf.yml`, 외부 네트워크 `parut-net`
- 진입점: `SettlementCompletionScheduler`의 정기 실행. 자동 완료 측정에는 JMeter를 사용하지 않는다.
- 기본 `application.yml`: 매일 03시 (`0 0 3 * * *`), `application-perf.yml`: 매분 (`0 * * * * *`), 시간대는 `Asia/Seoul`
- `settlement.completion.cron` 설정이 없으면 앱이 시작되지 않는다. 비활성화하려면 `"-"`로 설정한다.
- 청크 크기: 일반/perf 모두 100건 (`settlement.completion.chunk-size`)
- perf에서는 배송 자동완료(`delivery.completion.enabled=false`)와 자동 구매확정(`order.auto-confirmation.enabled=false`)을 끈다.
- 처리자는 주문 서비스의 공통 `app.system-account-id`를 사용한다. 일반 환경의 기본값은 임시 UUID이므로 운영 전 SYSTEM 계정 값으로 지정한다.

### 모니터링

공통 Prometheus에 `order-perf:8080/actuator/prometheus`가 수집 대상으로 등록되어 있다. 공통 모니터링과 전용 테스트 서버를 실행하면 기존 APM에서 지표를 확인할 수 있다.

- Prometheus: `up{job="order-perf"}`가 1이면 정상 수집이다. 0이면 서버/네트워크를, 결과가 없으면 활성 수집 설정을 확인한다.
- 기존 APM: application=`order`, instance=`order-perf:8080`, HikariPool-1 선택

기존 Prometheus가 설정 추가 전부터 실행 중이었다면 `docker restart prometheus`로 설정을 반영한다. 테스트 서버가 꺼져 있으면 대상은 DOWN으로 표시되지만, 공통 수집 실패/CPU 알림은 `-service`로 끝나는 job만 감시하므로 `order-perf`는 제외된다.

## 테스트 조건

| 항목 | 조건 |
| --- | --- |
| 목적 | 고정 작업량의 자동 완료 성능 측정 |
| 대상 | 10,000건, 5회 측정 후 중앙값 사용 |
| 실행 | 단일 작업자, 매분 스케줄러 실행 1회가 완료 작업 전체 실행 |
| 준비 | 서버 재시작 후 첫 실행은 워밍업으로 제외, 회차별 실험 데이터 초기화 |
| 비교 | Job 전체 시간, 내부 UPDATE/청크 트랜잭션 비용, 최종 DB 상태 |

10,000건은 비교용 작업량이며 운영 정상량이나 한계값은 아니다. 이번 측정은 같은 작업량의 처리 비용을 비교하며 최대 처리 용량을 주장하지 않는다. 용량이나 처리 기한 검증이 필요하면 작업량, 자원과 중단 기준을 별도로 정한다.

## 측정 결과

2026-10-27, perf 프로필의 매분 스케줄러로 10,000건을 처리했다. 서버 재시작 후 첫 실행은 제외하고, 이후 5회 측정의 중앙값을 사용했다.

| 지표 | 개선 전(건별 조건부 UPDATE, 건별 커밋) | 개선 후(100건 벌크 UPDATE, 청크 커밋) | 변화 |
| --- | ---: | ---: | --- |
| 실제 완료 건수 | 10,000건 | 10,000건 | Counter 증가량 = DB 완료 건수 |
| 전체 실행시간 | 1,953.9 ms | 284.0 ms | 85.5% 단축 |
| 초당 정산 처리 건수 | 5,118 rows/s | 35,213 rows/s | 6.9배 |
| CPU 사용 시간 | 840 ms | 410 ms | 약 51% 감소 |
| 커넥션 획득 | 10,001회 | 101회 | - |

| 회차 | 개선 전 실행시간(ms) | 개선 후 실행시간(ms) |
| --- | ---: | ---: |
| 첫 실행(제외) | 2,947.3 | 433.5 |
| 1회 | 2,097.9 | 466.6 |
| 2회 | 1,953.9 | 247.5 |
| 3회 | 1,880.8 | 239.6 |
| 4회 | 2,081.8 | 405.6 |
| 5회 | 1,788.4 | 284.0 |

로컬 단일 환경 결과이며 운영 처리량을 보장하지 않는다. 개선 후 회차 간 편차(239.6~466.6 ms)가 개선 전보다 크다.
CPU 사용 시간은 실행 직전과 직후 수집 시점 사이의 JVM 누적 CPU 시간 증가량이며 같은 구간의 다른 JVM 작업을 조금 포함한다.
DB 서버 CPU는 측정하지 않았다.

## 데이터 준비와 실행

`data/settlement-completion-job-seed.sql`은 `BEGIN`/`COMMIT`으로 묶인 순수 SQL이다. 실행마다 이전 실험 정산을 지우고 `PENDING` 10,000건을 만든다. 별도 워밍업 데이터는 없으며 기존 생성 검증 데이터와 입력 주문 픽스처는 보존한다.

1. `docker-compose.perf.yml` 구성으로 perf 서버를 빌드하고 기동한다.
2. 서버 재시작 후 첫 스케줄러 실행은 워밍업으로 보고 측정에서 제외한다.
3. `정산 자동완료 종료` 로그를 확인한 직후 시드를 실행한다. GUI SQL 콘솔에서 `localhost:55433`, `settlement_perf`에 접속하거나 시드 파일 상단 주석의 CLI 안내를 따른다. 작업 실행 중에는 적용하지 않는다.
4. 마지막 SELECT의 `experiment_ready`와 `total_ready`가 모두 10000인지 확인한다. 다르면 측정하지 않는다. 스케줄러가 전체 판매자를 처리하므로 실험 외 대상이 섞이지 않아야 한다.
5. 다음 정기 실행의 종료 로그와 Timer/Counter, DB 결과를 기록한다. DB 대조를 마친 뒤 3~5번을 반복해 총 5회 측정하고 중앙값을 사용한다.

회차별 결과는 `order-service/test-results/settlement-completion/remeasure-20261027/`에 보관한다(Git 제외). 개선 전 코드는 같은 폴더의 `before/source-snapshot/`에 보관한다.

### 확인 기준

- HTTP 응답 대신 `정산 자동완료 종료 result=CompletionRun[...]` 로그에서 `succeeded=10000`, `skipped=0`인지 확인한다. 중단 로그가 있으면 정상 측정값으로 사용하지 않는다.
- 로그의 `totalMs`와 Timer/Counter를 함께 확인한다. 조회 횟수 필드는 `selections`이며 마지막 빈 조회도 포함할 수 있다.
- DB에서 측정 sellerId와 `created_by='settlement-completion-perf'`로 한정하여 완료 건수, 금액, 버전, 처리자와 감사 필드를 대조한다. sellerId는 결과 대조용이며 스케줄러의 처리 범위를 제한하지 않는다.
- 새 시드를 넣지 않은 다음 정기 실행에서는 이미 완료한 정산이 다시 갱신되지 않아야 한다. 이 실행은 새 cutoff를 사용하며 같은 cutoff 재실행 검증과 구분한다.
- 반복 측정 전 DB 대조를 마친 뒤 다음 시드를 적용한다.

## 측정 지표

Micrometer Timer를 측정 대상별 이름으로 구분하고, 완료 정산 건수는 Counter로 기록한다. 실행 ID와 정산 ID는 로그에만 남기며 메트릭 태그로 사용하지 않는다.

| 종류 | 메트릭 이름 | 측정 범위 | 로그 필드 |
| --- | --- | --- | --- |
| Timer | `settlement.completion.job` | 정상 종료 Job 전체 시간 | `totalMs` |
| Timer | `settlement.completion.update` | 조건부 UPDATE 호출 시간 | `mutationMs`에 누적 |
| Timer | `settlement.completion.chunk` | Processor 프록시 호출부터 커밋 후 반환까지. 실패 청크도 기록 | `chunkTransactionMs`에 누적 |
| Counter | `settlement.completion.records.completed` | 청크 커밋 후 실제 갱신된 정산 건수만큼 증가 | `succeeded`와 같은 완료 건수 기준 |

`transactionBoundaryMs`는 청크 누적시간에서 UPDATE 누적시간을 뺀 값이며 순수 커밋 시간이 아니다. 전체 시간에 내부 구간이 포함되므로 서로 합산하지 않는다. Timer의 count는 시간 기록 횟수이며 완료 정산 건수가 아니다.

실행 결과는 종료 로그에서 확인한다. 대시보드 조회는 위 메트릭 이름을 사용한다. 화면과 PromQL 사용법은 [정산 완료 대시보드 안내](SETTLEMENT_DASHBOARD.md)를 따른다.

뒤 청크에서 오류가 나도 앞서 정상 커밋된 정산 건수는 Counter에 남는다. 0건 갱신/재실행은 Counter를 늘리지 않는다. 다만 DB 커밋과 메트릭 증가는 원자적이지 않고, 프로세스 종료/재시작이나 수집 전 종료에 따른 누락 가능성이 있어 DB 기록을 대신하지 않는다. 전체 Job Timer는 기존처럼 정상 종료 때만 기록한다.

## 정합성, 경합과 복구 검증

청크 실패 시 해당 청크는 롤백되고 앞선 커밋은 유지되며, 실패 원인 제거 후 남은 대상을 처리할 수 있음을 확인했다. 조건부 UPDATE로 중복 완료를 방지하고 수동/자동 경합에서도 중복 갱신되지 않음을 확인했다. 이전 perf API 진입점으로 검증, Job 처리 코드는 동일.

## 현재 처리 범위

- 벌크 UPDATE에서 상태/시간 조건, version 증가와 감사 필드를 명시한다.
- 0건 갱신은 제외로 집계하며 개별 제외 사유는 구분하지 않는다.
- cutoff는 완료 가능 시각의 기준이며 대상 목록을 고정하지 않는다. 실패 원인을 제거하면 다음 정기 실행이 새 cutoff로 남은 PENDING을 처리한다.
- 같은 cutoff의 수동 재실행 진입점, 대상 스냅샷, 영속 실행 이력과 체크포인트는 없다.
- AtomicBoolean은 같은 JVM의 중복 실행만 차단한다. 커밋 응답이 끊기면 DB 상태를 확인한다.

## 스케줄러 검증

스케줄러 검증(2026-10-27):

| 조건 | 결과 |
| --- | --- |
| 기본 프로필 | 정기 작업 3개 등록(정산 자동 완료, 배송 자동완료, 자동 구매확정) |
| `settlement.completion.cron` 미설정 | 기동 실패 |
| perf 프로필 | 정산 자동 완료만 매분 실행. 배송 자동완료와 자동 구매확정 실행 기록 없음 |

기본 프로필과 cron 미설정 조건은 임시 Spring 컨텍스트 테스트로 확인했으며 테스트 파일은 남기지 않았다. perf는 실행 로그와 `tasks_scheduled_execution_seconds_count` 메트릭으로 확인했다.

# CPU 주파수 스케일링 & 전력 관리

## 1. 개요

CPU 주파수 스케일링은 부하에 따라 CPU 동작 클럭을 동적으로 조절하는 기능이다. 전력 절약 목적으로 도입됐지만, 레이턴시 민감 서비스에서는 주파수 전환 지연이 tail latency를 크게 높일 수 있다. `performance` governor로 고정하면 최대 클럭을 유지해 일관된 응답 시간을 보장한다. 반대로 배치 처리나 비용 최적화 환경에서는 `schedutil`이나 `powersave`로 전력을 절약한다.

---

## 2. 설명

### 2.1 CPU Governor 종류

| Governor | 동작 방식 | 권장 환경 |
|----------|----------|----------|
| `performance` | 항상 최대 주파수 고정 | 레이턴시 민감 서비스, DB, 트레이딩 |
| `powersave` | 항상 최저 주파수 고정 | 유휴 서버, 비용 최적화 |
| `schedutil` | CFS 스케줄러 부하 기반 동적 조정 | 범용, 커널 5.x 기본값 |
| `ondemand` | CPU 사용률 기반 빠른 상승/느린 하강 | 레거시 환경, schedutil 이전 기본값 |
| `conservative` | ondemand보다 점진적 주파수 변화 | 전력 소비 최소화 |

### 2.2 현재 상태 확인

```bash
# 모든 CPU의 현재 governor 확인
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# cpupower로 상세 확인 (linux-tools 패키지 필요)
cpupower frequency-info

# 현재 주파수 실시간 확인
watch -n1 'cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq'

# 사용 가능한 governor 목록
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors

# 주파수 범위 확인
cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq
cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq

# turbostat으로 CPU 상태 종합 확인 (linux-tools 패키지)
turbostat --interval 1
```

### 2.3 Governor 변경

```bash
# 단일 CPU governor 변경
echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# 모든 CPU에 일괄 적용
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > $cpu   # 모든 CPU를 performance 모드로 전환
done

# cpupower 명령어로 전체 변경
cpupower frequency-set -g performance   # 모든 CPU를 performance governor로 설정

# 특정 주파수 고정
cpupower frequency-set -f 3600MHz   # 3.6GHz로 고정

# 주파수 범위 제한
cpupower frequency-set -d 2400MHz -u 3600MHz   # 2.4~3.6GHz 범위로 제한
```

**영구 적용 (systemd):**

```bash
# /etc/systemd/system/cpu-performance.service
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

# 서비스 활성화
systemctl enable --now cpu-performance.service
```

**영구 적용 (grub):**

```bash
# /etc/default/grub에 커널 파라미터 추가
GRUB_CMDLINE_LINUX_DEFAULT="... cpufreq.default_governor=performance"

# grub 재생성
grub2-mkconfig -o /boot/grub2/grub.cfg   # RHEL/CentOS
update-grub                               # Ubuntu/Debian
```

### 2.4 intel_pstate 드라이버

Intel CPU는 커널의 `intel_pstate` 드라이버가 P-state를 직접 제어한다.

```bash
# intel_pstate 상태 확인
cat /sys/devices/system/cpu/intel_pstate/status
# 출력: active / passive / off

# intel_pstate 모드
# active: 드라이버가 직접 P-state 제어 (기본)
# passive: 일반 cpufreq 스케일러 사용 가능

# Turbo Boost 상태 확인
cat /sys/devices/system/cpu/intel_pstate/no_turbo
# 0 = Turbo 활성화, 1 = Turbo 비활성화

# Turbo Boost 비활성화 (주파수 일관성 향상)
echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo

# 최대 주파수 비율 제한 (100 = 최대)
cat /sys/devices/system/cpu/intel_pstate/max_perf_pct
echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct
```

**Turbo Boost를 끄는 이유:**
- Turbo 클럭은 지속 불가능 (온도/전력 제한으로 자동 하강)
- 짧은 요청에서는 Turbo가 유리하지만, 부하가 높아지면 클럭이 낮아져 레이턴시 분산이 커짐
- p99 레이턴시를 최소화하려면 Turbo 끄고 안정적인 기본 클럭 유지가 나을 수 있음

### 2.5 C-state (CPU 유휴 상태)

C-state는 CPU가 유휴일 때 절전하는 깊이를 의미한다. 깊을수록 전력 절약이 크지만, 깨어나는 데 시간이 걸린다.

| C-state | 이름 | 레이턴시 | 전력 절약 |
|---------|------|---------|---------|
| C0 | 활성 | 0 | 없음 |
| C1 | Halt | ~1μs | 낮음 |
| C1E | Enhanced Halt | ~10μs | 낮음 |
| C3 | Sleep | ~50μs | 중간 |
| C6 | Deep Power Down | ~100μs | 높음 |
| C7/C8 | Enhanced Deep | ~200μs | 매우 높음 |

```bash
# 현재 지원되는 C-state 확인
cpupower idle-info

# C-state별 잔류 시간 통계
cpupower monitor -m Idle_Stats

# 최대 C-state 깊이 제한 (C1 이하로만 허용)
cpupower idle-set -D 1   # C1보다 깊은 C-state 비활성화

# 특정 C-state 비활성화 (C6 끄기)
cpupower idle-set -d 3   # 인덱스 3번 C-state 비활성화

# /sys 인터페이스로 직접 제어
echo 1 > /sys/devices/system/cpu/cpu0/cpuidle/state3/disable
```

**GRUB으로 C-state 제한 (영구):**

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="... intel_idle.max_cstate=1 processor.max_cstate=1"

# AMD CPU의 경우
GRUB_CMDLINE_LINUX_DEFAULT="... amd_idle.max_cstate=1"
```

### 2.6 레이턴시 최적화 종합 스크립트

```bash
#!/bin/bash
# latency-tuning.sh — 레이턴시 민감 서비스를 위한 CPU 최적화

# CPU governor를 performance로 설정
cpupower frequency-set -g performance

# Turbo Boost 비활성화 (Intel)
[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ] && \
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo

# C-state 깊이 제한 (C1 이하)
cpupower idle-set -D 1

# 주파수 스케일링을 최대로 고정
for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
    cat $cpu/cpuinfo_max_freq > $cpu/scaling_min_freq   # 최소 주파수를 최대로 설정
done

echo "CPU 레이턴시 최적화 완료"
cpupower frequency-info | grep "current CPU"
```

### 2.7 AWS EC2에서의 CPU 주파수 관리

```bash
# EC2 인스턴스의 현재 governor 확인
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Amazon Linux 2/2023: 기본값 확인
# c5, m5, r5 이상: 기본적으로 performance governor
# t3 (버스트형): schedutil 사용

# EC2에서 Turbo 상태 확인
cat /sys/devices/system/cpu/intel_pstate/no_turbo

# c5n, hpc6a 등 고성능 인스턴스: ENA enhanced networking과 함께
# performance governor 권장
```

**EC2 인스턴스 유형별 권장 설정:**

| 인스턴스 유형 | 권장 Governor | Turbo | C-state |
|-------------|-------------|-------|---------|
| c5, m5, r5 (일반 웹/앱) | schedutil | 활성화 | 기본 |
| c5n, hpc (고성능 컴퓨팅) | performance | 비활성화 | C1 제한 |
| db.r6g, db.m6g (RDS) | performance | 활성화 | 기본 |
| t3, t4g (버스트) | schedutil | 활성화 | 기본 |

### 2.8 성능 모니터링

```bash
# 주파수 이력 모니터링
turbostat --interval 1 --show PkgWatt,Avg_MHz,Busy%,Bzy_MHz

# CPU 주파수 분포 확인 (1초 간격 60회)
for i in $(seq 1 60); do
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq   # 현재 주파수 샘플링
    sleep 1
done | sort | uniq -c | sort -rn

# cpupower monitor로 P-state/C-state 종합
cpupower monitor -m Mperf,Idle_Stats

# perf stat으로 CPU 클럭 효율
perf stat -e cycles,instructions,cpu-clock -p <PID> sleep 10
```

### 2.9 전력 소비 vs 성능 트레이드오프

| 설정 | 전력 소비 | 응답 일관성 | 처리량 | 사용 케이스 |
|------|---------|-----------|--------|-----------|
| performance + no_turbo + C1 | 높음 | 매우 일관 | 중간 | 트레이딩, 실시간 |
| performance + turbo + C1 | 매우 높음 | 일관 | 높음 | DB, 고성능 컴퓨팅 |
| schedutil + turbo + 기본 C | 중간 | 보통 | 높음 | 범용 웹 서버 |
| powersave + 깊은 C | 낮음 | 불일관 | 낮음 | 유휴/배치 서버 |

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| 레이턴시 민감 서비스에 `ondemand`/`schedutil` 사용 | `cpupower frequency-set -g performance` + 서비스 시작 전 고정 |
| governor 변경 후 재부팅 시 초기화 | systemd 서비스나 GRUB 파라미터로 영구 적용 |
| Turbo Boost 켠 채로 일관된 레이턴시 기대 | 부하 높을 때 클럭 하강 → Turbo 끄고 기본 클럭 고정 |
| C-state 깊이 고려 없이 짧은 요청 처리 | `cpupower idle-set -D 1`로 C1 이하 제한 |
| `intel_pstate`와 일반 cpufreq 드라이버 혼동 | `cat /sys/devices/system/cpu/intel_pstate/status`로 드라이버 확인 |
| EC2 t3 인스턴스에서 performance governor 강제 | t3는 CPU 크레딧 기반 — performance governor는 크레딧 소진 가속 |
| turbostat 없이 주파수 추적 | `turbostat --interval 1`이 가장 정확한 클럭 측정 도구 |

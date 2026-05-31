## 1. 개요

리눅스 파일시스템 계층 구조(FHS, Filesystem Hierarchy Standard)는 디렉토리의 목적과 위치를 표준화한 규칙이다.
`/opt`에 넣어야 할지 `/usr/local`에 넣어야 할지 헷갈리는 경우가 많은데, 각 디렉토리의 설계 의도를 이해하면 배포 구조, 스크립트 경로, 트러블슈팅이 훨씬 명확해진다.

## 2. 전체 구조 한눈에 보기

```
/
├── bin/          → 기본 실행 파일 (ls, cp, bash 등)
├── sbin/         → 시스템 관리용 실행 파일 (root 전용: fdisk, iptables 등)
├── etc/          → 설정 파일 모음
├── var/          → 가변 데이터 (로그, 캐시, 스풀)
├── tmp/          → 임시 파일 (재부팅 시 삭제)
├── home/         → 일반 사용자 홈 디렉토리
├── root/         → root 계정 홈 디렉토리
├── opt/          → 서드파티 독립 패키지 설치 공간
├── srv/          → 서비스 데이터 (웹, FTP 등)
├── usr/          → 사용자 공유 읽기전용 데이터
│   ├── bin/      → 비필수 사용자 명령어 (python3, git 등)
│   ├── sbin/     → 비필수 시스템 명령어
│   ├── lib/      → 라이브러리
│   ├── local/    → 로컬에서 직접 컴파일/설치한 소프트웨어
│   │   ├── bin/  → 로컬 설치 실행 파일
│   │   ├── lib/  → 로컬 설치 라이브러리
│   │   └── etc/  → 로컬 설치 설정
│   └── share/    → 아키텍처 무관 공유 데이터 (man 페이지 등)
├── lib/          → 부팅에 필요한 공유 라이브러리
├── boot/         → 부트로더, 커널 이미지
├── dev/          → 장치 파일 (하드디스크, 터미널 등)
├── proc/         → 커널/프로세스 정보 가상 파일시스템
├── sys/          → 하드웨어/드라이버 정보 가상 파일시스템
├── run/          → 런타임 데이터 (PID 파일, 소켓 등, 재부팅 시 초기화)
└── mnt/          → 임시 마운트 지점
    └── media/    → USB, CD 등 이동식 미디어 자동 마운트
```

## 3. 핵심 디렉토리 상세 설명

### /etc - 시스템 설정의 중심

```
/etc/
├── passwd          → 사용자 계정 정보
├── shadow          → 비밀번호 해시 (root만 읽기)
├── group           → 그룹 정보
├── hosts           → 정적 호스트-IP 매핑
├── resolv.conf     → DNS 서버 설정
├── fstab           → 파일시스템 자동 마운트 설정
├── crontab         → 시스템 cron 작업
├── cron.d/         → 서비스별 cron 파일
├── systemd/
│   └── system/     → 커스텀 systemd 유닛 파일 위치
├── nginx/          → nginx 설정
├── ssh/
│   └── sshd_config → SSH 서버 설정
└── profile.d/      → 로그인 시 모든 사용자에 적용되는 환경변수 스크립트
```

> **원칙**: `/etc` 아래 파일은 설정만 담는다. 바이너리나 데이터는 두지 않는다.

### /opt - 서드파티 독립 패키지

패키지 관리자(`apt`, `yum`)를 통하지 않고 설치하는 **자체 완결형(self-contained)** 소프트웨어의 홈이다.
하나의 소프트웨어가 `/opt/<패키지명>/` 아래에 `bin/`, `lib/`, `conf/` 등을 모두 담는 구조.

```
/opt/
├── aws/                    → AWS CLI v2
│   └── bin/aws
├── google/
│   └── chrome/
├── datadog-agent/          → Datadog Agent
├── mycompany/
│   ├── backend-api/        → 회사 자체 서비스
│   │   ├── bin/
│   │   ├── conf/
│   │   └── logs/
│   └── scripts/            → 운영 자동화 스크립트
└── java/
    └── jdk-21/
```

**언제 `/opt`를 쓰나?**
- 패키지 매니저로 설치하지 않는 소프트웨어
- 특정 버전을 고정해서 사용해야 하는 런타임 (Java, Node.js 등)
- 회사 자체 개발 애플리케이션 배포 경로
- 여러 버전을 공존시켜야 하는 경우

```bash
# 실무 관례: 회사 앱 배포
/opt/mycompany/api/             → 앱 바이너리/소스
/opt/mycompany/api/conf/        → 앱 설정
/opt/mycompany/scripts/         → 운영 스크립트 (배포, 백업 등)
```

### /usr/local - 직접 컴파일/설치한 소프트웨어

OS 배포판이 관리하는 `/usr/bin`과 구분하여, **관리자가 직접 소스에서 빌드**하거나 패키지 매니저 외부에서 설치한 소프트웨어를 두는 공간.

```
/usr/local/
├── bin/        → 직접 설치한 실행 파일 (PATH에 포함됨)
├── sbin/       → 직접 설치한 시스템 관리 도구
├── lib/        → 직접 설치한 라이브러리
├── include/    → 직접 설치한 헤더 파일
├── share/      → 공유 데이터 (man 페이지 등)
└── etc/        → 로컬 설치 소프트웨어 설정
```

**`/usr/local/bin`에 두는 것들:**

```bash
# make install 로 소스 컴파일 후 자동으로 /usr/local/bin에 설치됨
./configure --prefix=/usr/local && make && sudo make install

# 커스텀 셸 스크립트를 시스템 전체에서 쓸 수 있게 배포
cp my-deploy-tool.sh /usr/local/bin/deploy
chmod 755 /usr/local/bin/deploy
# 이후 어디서든 `deploy` 명령어로 실행 가능 (PATH에 포함되어 있으므로)
```

**`/usr/local` vs `/opt` 언제 뭘 쓸까?**

| | `/usr/local/bin` | `/opt/<package>/` |
|---|---|---|
| 구조 | FHS 표준 구조로 분산 | 패키지 자체 디렉토리 내 독립 |
| 용도 | 단일 바이너리, 직접 컴파일 | 복잡한 패키지 (여러 파일 포함) |
| 예 | 커스텀 셸 스크립트, 빌드 도구 | Java, AWS CLI, 회사 앱 |

### /var - 변하는 데이터

```
/var/
├── log/            → 시스템/서비스 로그
│   ├── syslog      → Ubuntu 시스템 로그
│   ├── auth.log    → 인증 로그 (SSH 접속 기록)
│   ├── nginx/      → nginx 액세스/에러 로그
│   └── journal/    → systemd journal (영구 저장 시)
├── lib/            → 서비스 상태 데이터 (DB 데이터 파일 등)
│   ├── mysql/      → MySQL 데이터
│   └── postgresql/ → PostgreSQL 데이터
├── cache/          → 애플리케이션 캐시 (apt 패키지 캐시 등)
├── spool/          → 처리 대기 데이터 (메일 큐, 프린트 큐)
│   └── cron/       → 사용자 crontab 파일 실제 저장 위치
├── tmp/            → /tmp보다 오래 유지되는 임시 파일
└── run/ -> /run    → 런타임 PID 파일 (심볼릭 링크)
```

### /proc, /sys - 커널과 대화하는 창구

실제 파일이 아닌 **커널이 실시간으로 생성하는 가상 파일시스템**이다. 디스크 공간을 사용하지 않는다.

```bash
# 시스템 메모리 정보
cat /proc/meminfo

# CPU 정보 (코어 수, 모델명)
cat /proc/cpuinfo

# 특정 프로세스 정보 (PID로 접근)
cat /proc/1234/status       → 프로세스 상태
cat /proc/1234/cmdline      → 실행 명령어
ls -la /proc/1234/fd        → 열린 파일 디스크립터

# 커널 파라미터 실시간 조회/변경
cat /proc/sys/vm/swappiness
echo 10 > /proc/sys/vm/swappiness   # 즉시 적용 (재부팅 시 초기화)

# sysctl로 영구 적용 (/etc/sysctl.conf)
sysctl -w vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf
```

### /run - 런타임 상태 파일

부팅 후 생성되고 재부팅 시 초기화되는 런타임 데이터. PID 파일, 소켓 파일이 주로 위치한다.

```bash
# 실행 중인 서비스 PID 파일 위치 확인
cat /run/nginx.pid
cat /run/sshd.pid

# systemd 소켓 파일
ls /run/systemd/
```

## 4. 클라우드/DevOps 관례 정리

### AWS EC2에서 자주 쓰는 경로

```bash
# AWS CLI 설치 경로
/usr/local/bin/aws                  # pip install awscli
/usr/local/aws-cli/v2/current/bin/  # aws cli v2 공식 설치

# CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/   # 에이전트 바이너리
/etc/amazon/amazon-cloudwatch-agent/ # 설정 파일

# EC2 인스턴스 메타데이터
# (파일이 아닌 HTTP API: 169.254.169.254)
curl http://169.254.169.254/latest/meta-data/instance-id
```

### 앱 배포 경로 선택 기준

```bash
# 패키지 매니저로 설치한 공개 소프트웨어
/usr/bin/python3
/usr/bin/nginx

# 직접 빌드하거나 단순 바이너리 배포
/usr/local/bin/my-tool

# 자체 개발 서비스 (복잡한 디렉토리 구조)
/opt/mycompany/api/

# 서비스 설정
/etc/mycompany/api.conf

# 서비스 로그
/var/log/mycompany/api.log

# 서비스 데이터 (DB, 파일 저장소 등)
/var/lib/mycompany/
```

### 자주 헷갈리는 경로 비교

| 경로 | 목적 | 예 |
|---|---|---|
| `/bin` | OS 부팅에 필수인 기본 명령어 | `ls`, `cp`, `bash` |
| `/usr/bin` | 패키지 매니저로 설치한 일반 명령어 | `git`, `curl`, `python3` |
| `/usr/local/bin` | 직접 설치/빌드한 명령어 | 커스텀 스크립트, make install |
| `/opt/<pkg>/bin` | 특정 패키지의 독립 바이너리 | `/opt/aws/bin/aws` |
| `/sbin` | root 전용 시스템 관리 도구 | `fdisk`, `iptables`, `reboot` |
| `/usr/sbin` | 패키지 매니저 설치 시스템 도구 | `nginx`, `sshd` |

> **Tip**: `which` 또는 `type` 으로 명령어의 실제 위치 확인 가능
> ```bash
> which python3   # /usr/bin/python3
> which aws       # /usr/local/bin/aws
> type ll         # ll is aliased to 'ls -alF'
> ```

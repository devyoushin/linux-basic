## 1. 개요

`ip` 명령어는 `ifconfig`, `route`, `arp` 등 구식 net-tools를 대체하는 현대 리눅스 네트워크 관리 도구(`iproute2` 패키지)다.
네트워크 인터페이스 설정, 라우팅 테이블 조회/수정, ARP 캐시 관리를 하나의 명령어로 처리하며, 클라우드 환경(AWS ENI, K8s CNI)에서 네트워크 트러블슈팅 시 필수적으로 사용된다.

## 2. 설명

### 2.1 주요 서브커맨드 구조

| 서브커맨드 | 구식 대응 명령어 | 주요 역할 |
|---|---|---|
| `ip addr` | `ifconfig` | 인터페이스 IP 주소 조회/설정 |
| `ip link` | `ifconfig` | 인터페이스 상태(UP/DOWN), MAC 주소 |
| `ip route` | `route -n` | 라우팅 테이블 조회/수정 |
| `ip neigh` | `arp -n` | ARP 캐시(이웃 테이블) 조회 |
| `ip netns` | 없음 | 네트워크 네임스페이스 관리 |

### 2.2 자주 쓰는 실무 명령어

```bash
# 인터페이스 목록 및 IP 주소 확인 (가장 자주 사용)
ip addr show
ip a  # 축약형

# 특정 인터페이스만 확인
ip addr show eth0

# 라우팅 테이블 확인 (기본 게이트웨이 포함)
ip route show
ip r  # 축약형

# 특정 목적지로의 경로 확인
ip route get 8.8.8.8

# ARP 캐시 조회 (같은 네트워크 장비 MAC 주소 확인)
ip neigh show
```

### 2.3 일시적 설정 변경 (재부팅 시 초기화됨)

```bash
# IP 주소 추가/삭제
ip addr add 192.168.1.100/24 dev eth0
ip addr del 192.168.1.100/24 dev eth0

# 인터페이스 활성화/비활성화
ip link set eth0 up
ip link set eth0 down

# 기본 게이트웨이 추가/삭제
ip route add default via 192.168.1.1
ip route del default via 192.168.1.1

# 특정 대역 라우팅 추가
ip route add 10.0.0.0/8 via 192.168.1.254 dev eth0
```

> **주의**: `ip` 명령어로 설정한 내용은 재부팅 시 사라진다. 영구 적용은 `netplan`(Ubuntu 18.04+), `/etc/network/interfaces`(Debian), `nmcli`(RHEL/CentOS) 등 배포판별 도구를 사용해야 한다.

### 2.4 AWS 환경 트러블슈팅 실전 패턴

#### ENI(Elastic Network Interface) 추가 후 라우팅 문제

AWS EC2에 ENI를 두 개 이상 붙이면 비대칭 라우팅(asymmetric routing) 문제가 발생할 수 있다. 각 ENI가 자신의 게이트웨이로 응답해야 한다.

```bash
#!/bin/bash
# EC2 다중 ENI 환경에서 각 인터페이스별 라우팅 테이블 분리
# 예: eth0 = 주 네트워크(10.0.1.0/24), eth1 = 보조 네트워크(10.0.2.0/24)

# 1. 라우팅 테이블 ID 정의 (1~252 사이 임의 숫자)
echo "100 eth0rt" >> /etc/iproute2/rt_tables
echo "200 eth1rt" >> /etc/iproute2/rt_tables

# 2. 각 인터페이스 전용 라우팅 테이블 구성
ip route add 10.0.1.0/24 dev eth0 src 10.0.1.10 table eth0rt
ip route add default via 10.0.1.1 dev eth0 table eth0rt

ip route add 10.0.2.0/24 dev eth1 src 10.0.2.10 table eth1rt
ip route add default via 10.0.2.1 dev eth1 table eth1rt

# 3. 정책 라우팅: 출발지 IP에 따라 테이블 선택
ip rule add from 10.0.1.10 table eth0rt
ip rule add from 10.0.2.10 table eth1rt
```

#### Terraform user_data로 영구 적용 (Ubuntu/netplan)

```hcl
resource "aws_instance" "multi_eni_server" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.medium"

  user_data = <<-EOF
    #!/bin/bash
    # netplan 설정으로 다중 ENI 라우팅 영구 적용
    cat > /etc/netplan/99-multi-eni.yaml <<'NETPLAN'
    network:
      version: 2
      ethernets:
        eth0:
          dhcp4: true
          dhcp4-overrides:
            route-metric: 100
        eth1:
          dhcp4: true
          dhcp4-overrides:
            route-metric: 200
    NETPLAN
    netplan apply
  EOF
}
```

### 2.5 네트워크 네임스페이스 (K8s/Docker 트러블슈팅)

컨테이너나 Pod의 네트워크 스택은 네임스페이스로 격리되어 있다. 호스트에서 특정 컨테이너의 네트워크를 직접 검사할 때 사용한다.

```bash
# 현재 네트워크 네임스페이스 목록
ip netns list

# 특정 네임스페이스 안에서 명령 실행
ip netns exec <namespace-name> ip addr show
ip netns exec <namespace-name> ip route show

# Docker 컨테이너의 네임스페이스로 진입
CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' <container-id>)
nsenter -t $CONTAINER_PID -n ip addr show
```

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `ip` 명령 설정 후 재부팅 시 사라짐 | netplan/nmcli 등 영구 설정 도구 병행 사용 |
| AWS ENI 추가 후 응답 패킷이 잘못된 인터페이스로 나감 | 정책 라우팅(policy routing)으로 테이블 분리 |
| `ifconfig`로 설정 후 `ip`로 확인 시 불일치 | `ip` 명령어로 통일 (`ifconfig`는 deprecated) |

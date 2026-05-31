# IPVS (IP Virtual Server)

## 1. 개요

IPVS는 Linux 커널 내장 L4 로드 밸런서로, LVS(Linux Virtual Server) 프로젝트의 핵심 구성요소다.
iptables 기반 NAT보다 훨씬 낮은 오버헤드로 수만 개의 백엔드 서비스를 처리할 수 있으며,
Kubernetes kube-proxy의 IPVS 모드 백엔드로 널리 사용된다.
규모가 커질수록 iptables 대비 성능 차이가 두드러지기 때문에 대규모 클러스터 운영 시 필수 지식이다.

---

## 2. 설명

### 2.1 핵심 개념

#### IPVS vs iptables

| 항목 | iptables | IPVS |
|------|----------|------|
| 자료구조 | 선형 리스트 | 해시 테이블 |
| 규칙 1만 개 조회 | O(n) | O(1) |
| 연결 추적 | conntrack 의존 | 자체 세션 테이블 |
| 로드밸런싱 알고리즘 | 없음 (DNAT만) | rr, wrr, lc, wlc, sh, dh 등 10종 |
| 커널 위치 | Netfilter hooks | Netfilter hooks (입력 전용 최적화) |

#### 동작 모드

| 모드 | 설명 | 클라이언트 IP 보존 |
|------|------|------------------|
| NAT | Director가 목적지 IP 변환 (DNAT/SNAT) | 불가 (X-Forwarded-For 필요) |
| DR (Direct Routing) | MAC 주소만 변경, 응답은 Real Server → Client 직접 | 가능 |
| TUN (IP Tunneling) | IP-in-IP 캡슐화, 지리적 분산 가능 | 가능 |

> 실무에서 가장 많이 쓰는 모드는 **NAT**이며, Kubernetes kube-proxy도 NAT 모드를 사용한다.

#### 스케줄링 알고리즘

| 알고리즘 | 코드 | 특징 |
|----------|------|------|
| Round Robin | `rr` | 순서대로 분배, 기본값 |
| Weighted Round Robin | `wrr` | 가중치 비례 분배 |
| Least Connection | `lc` | 현재 연결 수가 가장 적은 서버 |
| Weighted Least Connection | `wlc` | 연결 수 + 가중치 복합 (권장) |
| Source Hashing | `sh` | 클라이언트 IP 기반 고정 (세션 유지) |
| Destination Hashing | `dh` | 목적지 IP 기반 고정 (캐시 서버) |

#### 구성 요소

```
Client
  │
  ▼
Virtual Service (VIP:PORT)   ← ipvsadm으로 관리
  │
  ├─ Real Server 1 (RIP:PORT, weight=10)
  ├─ Real Server 2 (RIP:PORT, weight=10)
  └─ Real Server 3 (RIP:PORT, weight=5)
```

- **VIP (Virtual IP)**: 클라이언트가 접속하는 가상 주소
- **Real Server (RS)**: 실제 요청을 처리하는 백엔드
- **Director**: IPVS가 동작하는 노드

---

### 2.2 실무 명령어

#### 커널 모듈 로드

```bash
# IPVS 관련 모듈 로드
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_lc
modprobe ip_vs_wlc
modprobe ip_vs_sh
modprobe nf_conntrack        # NAT 모드에 필요

# 로드된 모듈 확인
lsmod | grep ip_vs
```

```bash
# 부팅 시 자동 로드 설정 (RHEL/Rocky/Amazon Linux 2023)
cat > /etc/modules-load.d/ipvs.conf << 'EOF'
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_lc
ip_vs_wlc
ip_vs_sh
nf_conntrack
EOF
```

#### ipvsadm 설치

```bash
# RHEL/CentOS/Amazon Linux
dnf install -y ipvsadm

# Debian/Ubuntu
apt-get install -y ipvsadm
```

#### Virtual Service 관리

```bash
# TCP Virtual Service 추가 (VIP 192.168.1.100:80, 알고리즘 wlc)
ipvsadm -A -t <VIP>:80 -s wlc

# Real Server 추가 (NAT 모드, 가중치 10)
ipvsadm -a -t <VIP>:80 -r <RS1_IP>:80 -m -w 10
ipvsadm -a -t <VIP>:80 -r <RS2_IP>:80 -m -w 10

# Real Server 추가 (DR 모드, 가중치 5)
ipvsadm -a -t <VIP>:80 -r <RS3_IP>:80 -g -w 5

# 현재 설정 조회
ipvsadm -Ln

# 연결 통계 포함 조회
ipvsadm -Ln --stats

# 비율(rates) 기반 통계 조회
ipvsadm -Ln --rate
```

#### 출력 예시 해석

```bash
# ipvsadm -Ln 출력
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  192.168.1.100:80 wlc
  -> 10.0.0.1:80                  Masq    10     42         8
  -> 10.0.0.2:80                  Masq    10     38         5
  -> 10.0.0.3:80                  Route   5      20         2

# ActiveConn: 현재 활성 연결 수
# InActConn:  TIME_WAIT 등 비활성 연결 수 (FIN 이후)
```

#### 설정 저장 및 복원

```bash
# 현재 설정 저장
ipvsadm --save > /etc/sysconfig/ipvsadm

# 저장된 설정 복원
ipvsadm --restore < /etc/sysconfig/ipvsadm

# 모든 규칙 초기화
ipvsadm --clear
```

#### 세션 테이블 조회

```bash
# IPVS 연결 추적 테이블 확인 (procfs)
cat /proc/net/ip_vs_conn

# 연결 수 집계
wc -l /proc/net/ip_vs_conn
```

---

### 2.3 클라우드/DevOps 연계

#### Kubernetes kube-proxy IPVS 모드 전환

```bash
# 현재 kube-proxy 모드 확인
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode

# kube-proxy ConfigMap 수정
kubectl edit configmap kube-proxy -n kube-system
```

```yaml
# kube-proxy ConfigMap 핵심 설정
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"                  # iptables → ipvs 변경
ipvs:
  scheduler: "wlc"            # 스케줄링 알고리즘
  syncPeriod: "30s"           # 규칙 동기화 주기
  minSyncPeriod: "2s"         # 최소 동기화 간격
  strictARP: true             # DR 모드 사용 시 필요
```

```bash
# kube-proxy Pod 재시작 (변경 반영)
kubectl rollout restart daemonset kube-proxy -n kube-system

# 노드에서 IPVS 규칙 확인 (노드 SSH 후)
ipvsadm -Ln | head -30
```

#### kubeadm 신규 클러스터 설치 시 IPVS 모드 지정

```yaml
# kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
ipvs:
  scheduler: "wlc"
  strictARP: true
```

```bash
# 설정 파일로 클러스터 초기화
kubeadm init --config kubeadm-config.yaml
```

#### Keepalived + IPVS (HA 구성)

```bash
# keepalived 설치
dnf install -y keepalived ipvsadm
```

```ini
# /etc/keepalived/keepalived.conf (MASTER 노드)
vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 110                    # MASTER > BACKUP
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass <PASSWORD>        # 실제 패스워드로 교체
    }
    virtual_ipaddress {
        <VIP>/24                    # 가상 IP
    }
}

virtual_server <VIP> 80 {
    delay_loop 6
    lb_algo wlc                     # 스케줄링 알고리즘
    lb_kind NAT                     # 동작 모드
    protocol TCP

    real_server <RS1_IP> 80 {
        weight 10
        TCP_CHECK {
            connect_timeout 3
            connect_port 80
        }
    }
    real_server <RS2_IP> 80 {
        weight 10
        TCP_CHECK {
            connect_timeout 3
            connect_port 80
        }
    }
}
```

---

## 3. 자주 하는 실수

| 잘못된 방법 | 올바른 방법 | 이유 |
|------------|------------|------|
| NAT 모드에서 Real Server의 기본 게이트웨이를 일반 라우터로 설정 | Real Server의 default GW를 Director(IPVS 노드) IP로 설정 | NAT 모드에서 응답 패킷도 Director를 통해야 하므로 |
| `ipvsadm -A` 후 Real Server 없이 테스트 | Real Server 추가 후 `ipvsadm -Ln`으로 확인 | RS 없으면 모든 연결이 즉시 거절됨 |
| `--clear` 로 규칙 초기화 전 저장 생략 | `ipvsadm --save > /etc/sysconfig/ipvsadm` 후 초기화 | 복구 불가, K8s 환경에서 kube-proxy가 재생성하지만 순단 발생 |
| kube-proxy IPVS 모드 전환 전 커널 모듈 로드 생략 | `modprobe ip_vs_*` 선행 후 kube-proxy 재시작 | 모듈 없으면 kube-proxy가 iptables 모드로 fallback됨 |
| DR 모드에서 `strictARP: false` 유지 | `strictARP: true` 또는 `/proc/sys/net/ipv4/conf/all/arp_ignore=1` 설정 | VIP에 대한 ARP 응답을 Real Server가 가로채서 패킷 루프 발생 |
| Real Server 헬스체크 없이 운영 | keepalived TCP_CHECK 또는 외부 헬스체크 연동 | 장애 RS로 계속 트래픽이 전달되어 요청 실패 |

---

## 4. 트러블슈팅

#### 증상: ipvsadm 명령이 없거나 모듈 로드 실패

```bash
# 커널이 IPVS를 지원하는지 확인
grep -i ipvs /boot/config-$(uname -r)
# CONFIG_IP_VS=m 이면 모듈로 빌드됨

# 모듈 강제 로드 시도
modprobe ip_vs 2>&1

# dmesg로 로드 실패 원인 확인
dmesg | tail -20
```

#### 증상: kube-proxy가 IPVS 모드로 전환되지 않음

```bash
# kube-proxy 로그에서 fallback 메시지 확인
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep -i "fall\|ipvs\|iptables"

# 노드에서 직접 모듈 확인
lsmod | grep ip_vs

# 누락된 모듈 로드 후 kube-proxy 재시작
modprobe ip_vs ip_vs_rr ip_vs_wrr ip_vs_lc ip_vs_wlc ip_vs_sh nf_conntrack
kubectl rollout restart daemonset kube-proxy -n kube-system
```

#### 증상: IPVS 규칙은 있는데 연결이 안 됨 (NAT 모드)

```bash
# IP 포워딩 활성화 여부 확인
cat /proc/sys/net/ipv4/ip_forward
# 0이면 활성화 필요

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-ipvs.conf

# Real Server에서 기본 게이트웨이 확인
ip route show default
# → Director IP를 향해야 함
```

#### 증상: 특정 Real Server로만 트래픽이 몰림

```bash
# 현재 연결 분포 확인
ipvsadm -Ln

# InActConn이 비정상적으로 높으면 TIME_WAIT 문제
# → 짧은 연결이 많은 서비스의 경우 wlc보다 rr 또는 sh 고려

# 가중치 재조정
ipvsadm -e -t <VIP>:80 -r <RS_IP>:80 -m -w <NEW_WEIGHT>
```

#### 증상: DR 모드에서 패킷 루프 또는 응답 없음

```bash
# Real Server에서 ARP 설정 확인
sysctl net.ipv4.conf.all.arp_ignore
sysctl net.ipv4.conf.all.arp_announce

# Real Server lo 인터페이스에 VIP 설정 필요 (DR 모드)
ip addr add <VIP>/32 dev lo

# ARP 억제 설정 (Real Server에 적용)
sysctl -w net.ipv4.conf.all.arp_ignore=1
sysctl -w net.ipv4.conf.all.arp_announce=2
```

---

## 5. TIP

**연결 수 모니터링 원라이너**
```bash
# VIP별 활성 연결 수 실시간 확인
watch -n 1 'ipvsadm -Ln | grep -A5 "TCP\|UDP"'

# Real Server별 연결 수 합산
ipvsadm -Ln | awk '/->/{print $2, $5+$6}' | sort -k2 -rn
```

**IPVS 세션 만료 튜닝**
```bash
# TCP 세션 타임아웃 조회 (기본: established=900, fin=120, udp=300)
ipvsadm --list --timeout

# TCP 타임아웃 단축 (짧은 HTTP 요청 많을 때)
ipvsadm --set 120 30 300
# 순서: TCP established, TCP FIN, UDP
```

**K8s 환경에서 Service IP → 실제 백엔드 추적**
```bash
# Service ClusterIP로 IPVS 항목 찾기
ipvsadm -Ln | grep <CLUSTER_IP>

# Endpoint IP 목록과 대조
kubectl get endpoints <SERVICE_NAME> -n <NAMESPACE>
```

**IPVS 통계를 Prometheus로 수집**
`kube-proxy` IPVS 모드 사용 시 `/metrics` 엔드포인트에서 `kubeproxy_sync_proxy_rules_duration_seconds` 등 지표를 노출한다. 규칙 동기화 지연이 높다면 Service/Endpoint 수 증가 또는 노드 부하를 확인한다.

**iptables와 혼용 금지**
IPVS 모드와 iptables FORWARD 규칙이 충돌하면 예측 불가한 패킷 드롭이 발생한다. K8s 클러스터에서 IPVS 모드로 전환 후 기존 iptables 규칙을 반드시 정리한다.
```bash
# 기존 KUBE-* iptables 체인 확인 후 정리 (전환 후)
iptables -t nat -L | grep KUBE
iptables -t filter -L | grep KUBE
```

# Cilium & eBPF 네트워킹 — Kubernetes kube-proxy 완전 대체

## 1. 개요

Cilium은 eBPF 기반 Kubernetes 네트워킹 플러그인(CNI)이다. 기존 kube-proxy가 iptables 규칙으로 서비스를 구현하는 방식의 한계를 eBPF 맵으로 해결한다. 서비스 1000개 기준 iptables는 수만 개 규칙을 O(n) 순회하지만, Cilium은 BPF 해시맵을 O(1)으로 조회한다. Isovalent(Cilium 개발사)가 공개한 벤치마크에서 5000 서비스 기준 kube-proxy 대비 레이턴시 30%, CPU 사용률 40% 감소가 보고됐다.

---

## 2. 설명

### 2.1 iptables의 Kubernetes 한계

```
서비스 N개 → iptables 규칙 수: ~20N개

kube-proxy iptables 동작:
PREROUTING → KUBE-SERVICES → KUBE-SVC-XXXXX (서비스 체인)
             → KUBE-SEP-YYYYY (엔드포인트 1)  확률 1/N
             → KUBE-SEP-ZZZZZ (엔드포인트 2)  확률 1/(N-1)
             ...

문제점:
1. 규칙 추가/삭제 시 전체 테이블 flush & reload (O(n) 시간)
2. 패킷마다 규칙을 선형 탐색 (서비스 많을수록 레이턴시 증가)
3. conntrack 테이블: 모든 연결 상태 추적 → 대규모 클러스터에서 폭발
4. SNAT 적용 시 소스 IP 손실 → 로깅/보안 정책 어려움
```

```bash
# kube-proxy가 만든 iptables 규칙 수 확인
iptables-save | wc -l          # 전체 규칙 수 (서비스 많을수록 수만 개)
iptables -t nat -L | wc -l     # NAT 테이블 규칙 수

# conntrack 테이블 상태
conntrack -C                   # 현재 추적 중인 연결 수
sysctl net.netfilter.nf_conntrack_max   # 최대 허용 수
```

### 2.2 Cilium 아키텍처

```
┌─────────────────────────────────────────────────────┐
│                    Kubernetes API Server              │
└─────────────────────────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │ Cilium Agent │  (DaemonSet, 각 노드)
                    │             │
                    │ eBPF 컴파일  │
                    │ BPF 맵 관리  │
                    └──────┬──────┘
                           │ BPF 프로그램 로드
                    ┌──────▼──────────────────────┐
                    │         커널 eBPF             │
                    │                              │
                    │  tc BPF (ingress/egress)     │
                    │  XDP BPF (로드밸런서)         │
                    │  kprobe/tracepoint           │
                    │                              │
                    │  BPF 맵:                     │
                    │  - cilium_lb4_services        │  서비스 테이블
                    │  - cilium_lb4_backends        │  백엔드 테이블
                    │  - cilium_policy              │  정책 테이블
                    └──────────────────────────────┘
```

### 2.3 kube-proxy 없이 Cilium 설치

```bash
# 방법 1: kubeadm으로 신규 클러스터 구성 시 kube-proxy 스킵
kubeadm init \
    --pod-network-cidr=10.0.0.0/8 \
    --skip-phases=addon/kube-proxy   # kube-proxy 애드온 설치 건너뜀

# 방법 2: 기존 클러스터에서 kube-proxy 제거
kubectl -n kube-system delete ds kube-proxy   # kube-proxy DaemonSet 삭제
iptables-save | grep -v KUBE | iptables-restore   # kube-proxy 규칙 정리

# Cilium 설치 (Helm)
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \       # kube-proxy 완전 대체 모드
    --set k8sServiceHost=<API_SERVER_IP> \    # API 서버 주소
    --set k8sServicePort=6443 \
    --set bpf.masquerade=true \               # iptables MASQUERADE → eBPF
    --set ipam.mode=kubernetes \              # IPAM 모드
    --set tunnel=disabled \                   # 오버레이 없이 네이티브 라우팅
    --set autoDirectNodeRoutes=true           # 노드 간 직접 라우팅

# 설치 상태 확인
cilium status                                 # 전체 상태 요약
kubectl get pods -n kube-system | grep cilium # Cilium Pod 상태
```

### 2.4 eBPF 맵 vs iptables 성능 비교

```bash
# Cilium의 BPF 서비스 맵 확인
cilium service list                       # 서비스 목록 (BPF 맵에서 읽음)
cilium bpf lb list                        # 로드밸런서 BPF 엔트리

# iptables 규칙이 없는지 확인
iptables -t nat -L -n | grep KUBE         # 결과 없어야 정상

# BPF 맵 직접 조회
bpftool map list | grep cilium            # Cilium BPF 맵 목록
bpftool map dump name cilium_lb4_services # 서비스 맵 내용

# 연결 추적 없음 확인 (일부 구성)
conntrack -C                              # Cilium BPF CT 사용 시 감소 확인
cilium bpf ct list global | head -20      # Cilium 자체 BPF 연결 추적 테이블
```

**서비스 수에 따른 레이턴시 비교 (p99 기준):**

| 서비스 수 | kube-proxy (iptables) | Cilium (eBPF) |
|---------|---------------------|--------------|
| 100 | 0.1ms | 0.05ms |
| 1,000 | 0.5ms | 0.05ms |
| 5,000 | 2.5ms | 0.06ms |
| 10,000 | 5ms+ | 0.07ms |

### 2.5 Cilium Network Policy

```yaml
# Cilium NetworkPolicy — eBPF 레벨에서 L3/L4/L7 정책 적용
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: backend-policy
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: backend          # 이 레이블의 Pod에 적용
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend       # frontend Pod에서만 수신 허용
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:               # L7 HTTP 정책 (eBPF 파서)
        - method: "GET"
          path: "/api/.*"   # GET /api/* 만 허용
  - fromEndpoints:
    - matchLabels:
        app: monitoring
    toPorts:
    - ports:
      - port: "9090"        # Prometheus 메트릭 포트
        protocol: TCP
  egress:
  - toFQDNs:                # DNS 기반 이그레스 정책
    - matchName: "db.internal.example.com"
    toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
```

```bash
# Cilium 정책 상태 확인
cilium policy get                          # 적용된 정책 목록
cilium endpoint list                       # 엔드포인트 상태 (정책 적용 여부)
cilium endpoint get <endpoint-id>          # 특정 엔드포인트 상세

# 정책 위반 확인
cilium monitor --type drop                 # 드롭된 패킷 실시간 모니터링
```

### 2.6 Hubble: eBPF 기반 네트워크 관측

Hubble은 Cilium에 내장된 네트워크 관측 플랫폼으로, eBPF를 통해 **zero-overhead**로 모든 네트워크 플로우를 캡처한다.

```bash
# Hubble 활성화
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --reuse-values \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \    # 멀티노드 집계
    --set hubble.ui.enabled=true          # 웹 UI

# Hubble CLI 설치
cilium hubble enable --ui
export HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --fail --remote-name-all "https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-amd64.tar.gz"
tar xzvf hubble-linux-amd64.tar.gz
mv hubble /usr/local/bin/

# 플로우 관찰
hubble observe                             # 실시간 플로우 스트림
hubble observe --namespace production      # 특정 네임스페이스
hubble observe --pod backend-xxx-yyy       # 특정 Pod
hubble observe --verdict DROPPED           # 드롭된 패킷만
hubble observe --protocol http             # HTTP 트래픽만
hubble observe --to-port 80                # 포트 80 트래픽만

# HTTP L7 관측 (Cilium L7 파싱 활성화 필요)
hubble observe --http-method GET --http-path "/api/*"

# 플로우 통계
hubble observe --output json | jq '.flow.source.pod_name' | sort | uniq -c
```

```bash
# Hubble UI 포트 포워딩
kubectl port-forward -n kube-system svc/hubble-ui 12000:80 &
# 브라우저에서 http://localhost:12000 접속 — 서비스 맵 시각화
```

### 2.7 BandwidthManager: Pod 레벨 대역폭 제한

```bash
# BandwidthManager 활성화 (eBPF tc로 구현)
helm upgrade cilium cilium/cilium \
    --reuse-values \
    --set bandwidthManager.enabled=true

# Pod 대역폭 제한 (annotations)
apiVersion: v1
kind: Pod
metadata:
  name: bandwidth-limited-pod
  annotations:
    kubernetes.io/ingress-bandwidth: "10M"   # 수신 대역폭 제한
    kubernetes.io/egress-bandwidth: "10M"    # 송신 대역폭 제한
spec:
  containers:
  - name: app
    image: nginx
```

```bash
# BandwidthManager 상태 확인
cilium bpf bandwidth list                   # 대역폭 제한 BPF 맵
```

### 2.8 DSR (Direct Server Return)

DSR은 로드밸런서를 통해 들어온 요청에 대한 응답을 로드밸런서를 거치지 않고 클라이언트에 직접 보내는 방식이다. XDP로 구현해 성능을 극대화한다.

```bash
# DSR 활성화 (NodePort 트래픽)
helm upgrade cilium cilium/cilium \
    --reuse-values \
    --set loadBalancer.mode=dsr \          # DSR 모드 활성화
    --set loadBalancer.acceleration=native  # XDP Native 가속

# DSR 동작 확인
cilium status | grep DSR                    # DSR 상태
cilium bpf lb list | grep DSR              # DSR BPF 엔트리
```

### 2.9 Cilium Cluster Mesh

```bash
# Cluster Mesh: 멀티 클러스터 서비스 디스커버리
# 클러스터 1에서 설정
cilium clustermesh enable \
    --service-type LoadBalancer             # 또는 NodePort

# 클러스터 간 연결
cilium clustermesh connect \
    --destination-context cluster2          # kubectl 컨텍스트 이름

# 멀티 클러스터 서비스 (GlobalService)
apiVersion: v1
kind: Service
metadata:
  name: global-db
  annotations:
    service.cilium.io/global: "true"        # 전체 클러스터에서 접근 가능
    service.cilium.io/shared: "true"        # 다른 클러스터와 백엔드 공유
spec:
  selector:
    app: database
  ports:
  - port: 5432
```

### 2.10 설치 검증 및 연결성 테스트

```bash
# Cilium 연결성 테스트 (자동화된 종합 테스트)
cilium connectivity test                    # 전체 연결성 시나리오 실행
# 테스트 항목:
# - Pod to Pod (같은 노드)
# - Pod to Pod (다른 노드)
# - Pod to Service (ClusterIP)
# - Pod to Service (NodePort)
# - Pod to ExternalIP
# - Network Policy 적용 여부

# 개별 확인
cilium status --wait                        # 모든 컴포넌트 준비 대기
cilium connectivity test --test pod-to-pod  # 특정 테스트만 실행
```

### 2.11 트러블슈팅

```bash
# Cilium Agent 로그
kubectl logs -n kube-system -l k8s-app=cilium --tail=100
kubectl exec -n kube-system <cilium-pod> -- cilium status

# 엔드포인트 상태 확인
cilium endpoint list                        # 모든 엔드포인트
cilium endpoint get <endpoint-id>           # 특정 엔드포인트 상세 (정책, 레이블)

# 패킷 드롭 분석
cilium monitor --type drop                  # 실시간 드롭 이벤트
cilium monitor --type l7                    # L7 이벤트 (HTTP 등)
cilium monitor -v                           # 상세 패킷 정보

# BPF 맵 직접 조회
cilium bpf lb list                          # 로드밸런서 맵
cilium bpf ct list global                   # 연결 추적 테이블
cilium bpf endpoint list                    # 엔드포인트 맵
cilium bpf policy get <endpoint-id>         # 특정 엔드포인트 정책 BPF 맵

# 네트워크 정책 디버깅
cilium policy trace \
    --src-k8s-pod production/frontend-pod \
    --dst-k8s-pod production/backend-pod \
    --dport 8080 \
    --protocol tcp                           # 트래픽 허용/거부 시뮬레이션

# 노드 간 연결 문제
cilium-health status                         # 노드 간 헬스 상태
cilium-health ping <node-ip>                 # 특정 노드 헬스 확인

# XDP 가속 상태
cilium status | grep acceleration            # XDP/BPF 가속 활성화 여부
bpftool net show dev eth0                    # 인터페이스의 BPF 프로그램 확인
```

```bash
# 일반적인 문제 해결

# 문제: Pod 간 통신 불가
# 확인: 정책이 있는지 확인
cilium monitor --type drop 2>&1 | grep -E "src|dst|reason"

# 문제: DNS 해석 실패
kubectl exec -n kube-system <cilium-pod> -- cilium status | grep "DNS Proxy"
kubectl logs -n kube-system <cilium-pod> | grep dns

# 문제: NodePort 미동작
cilium service list | grep NodePort        # NodePort 서비스 BPF 등록 확인
cilium bpf lb list | grep <service-port>   # 해당 포트 BPF 엔트리 확인

# 문제: 업그레이드 후 이상 동작
cilium status                              # 전체 상태
kubectl rollout restart ds/cilium -n kube-system   # Cilium DaemonSet 재시작
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| kube-proxy 제거 없이 Cilium 설치 | `--set kubeProxyReplacement=strict`로 설치하고 kube-proxy DaemonSet 삭제 |
| Hubble 없이 네트워크 문제 디버깅 | Hubble 활성화 → `hubble observe --verdict DROPPED`로 즉시 원인 파악 |
| L7 정책 없이 HTTP 경로 제어 시도 | `CiliumNetworkPolicy`의 `rules.http` 섹션 사용 |
| Cilium 업그레이드 시 롤링 업데이트 미확인 | `cilium status --wait` 완료 후 다음 단계 진행 |
| 대규모 클러스터에서 BPF 맵 크기 기본값 사용 | `--set bpf.mapDynamicSizeRatio=0.0025`로 맵 크기 조정 |
| DSR 없이 고트래픽 NodePort 운영 | `--set loadBalancer.mode=dsr`로 응답 트래픽 로드밸런서 우회 |
| cilium connectivity test 미실행 | 설치/업그레이드 후 반드시 실행해 전체 시나리오 검증 |
| 기존 iptables 규칙 정리 안 함 | Cilium 설치 전 `iptables-flush` 또는 노드 재부팅으로 정리 |

## 1. 개요

`iptables`는 리눅스 커널의 넷필터(Netfilter) 프레임워크를 제어하여 패킷을 필터링하거나 NAT(Network Address Translation)를 수행하는 도구입니다. 본 문서에서는 `Table`과 `Chain`의 구조를 이해하고, 이를 코드화하여 관리하는 방법을 다룹니다.

## 2. 설명

### 2.1 iptables 구조: Table과 Chain

iptables는 3개의 계층 구조(Tables -> Chains -> Rules)를 가집니다.

- **Filter Table**: 가장 기본이 되는 테이블로, 패킷의 허용/차단(INPUT, FORWARD, OUTPUT)을 결정합니다.
- **NAT Table**: IP 주소 변환(PREROUTING, POSTROUTING)을 담당하며 주로 공유기나 게이트웨이 역할을 할 때 사용합니다.    
- **Mangle Table**: 패킷 헤더 수정(TOS, TTL 등)에 사용됩니다.
    

### 2.2 실무 적용: IaC를 통한 관리

#### 클라우드 초기화 시 iptables 기본 규칙 설정

Terraform의 `remote-exec`나 `cloud-init`을 사용하여 인스턴스 생성 시 SSH(22)와 HTTP(80)만 허용하는 화이트리스트 전략을 적용합니다.
```terraform
resource "aws_instance" "secure_node" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.small"

  user_data = <<-EOF
              #!/bin/bash
              # 1. 기존 규칙 초기화
              iptables -F
              # 2. 기본 정책 설정 (모두 차단)
              iptables -P INPUT DROP
              iptables -P FORWARD DROP
              iptables -P OUTPUT ACCEPT
              # 3. 루프백 및 기허용된 세션 허용
              iptables -A INPUT -i lo -j ACCEPT
              iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
              # 4. 특정 서비스 포트 오픈
              iptables -A INPUT -p tcp --dport 22 -j ACCEPT
              iptables -A INPUT -p tcp --dport 80 -j ACCEPT
              # 5. 설정 영구 저장 (Ubuntu 기준)
              apt-get update && apt-get install -y iptables-persistent
              EOF
}
```

#### Kubernetes 서비스 노출을 위한 iptables (Conceptual)

K8s는 `kube-proxy`를 통해 iptables 규칙을 자동으로 생성합니다. 서비스 타입이 `NodePort`일 때 내부적으로 생성되는 로직은 다음과 유사합니다.
```yaml
# 직접적인 iptables yaml은 없으나, Helm Chart의 post-install hook 등으로 스크립트 실행 가능
apiVersion: batch/v1
kind: Job
metadata:
  name: iptables-custom-rule
spec:
  template:
    spec:
      hostNetwork: true
      containers:
      - name: setup
        image: alpine
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c", "iptables -A INPUT -s 10.0.0.0/8 -j ACCEPT"]
      restartPolicy: Never
```

## 3. 트러블슈팅

### 3.1 규칙 순서(Order) 문제

- **증상**: 특정 IP를 차단(`DROP`)하는 규칙을 넣었으나 여전히 접속이 됨.
- **원인**: iptables는 상단에 위치한 규칙이 먼저 적용됩니다. 이미 상단에 `ACCEPT` 규칙이 있다면 하단의 `DROP`은 무시됩니다.
- **해결**: `iptables -I` (Insert) 명령어를 사용하여 최상단(1번)에 규칙을 삽입하세요.
    
    ```bash
    iptables -I INPUT 1 -s 1.2.3.4 -j DROP
    ```
    

### 3.2 DNS 질의 실패

- **증상**: `INPUT` 정책을 `DROP`으로 바꾼 후 `curl` 등이 동작하지 않음.
- **원인**: 나가는 패킷은 허용(`OUTPUT ACCEPT`)했으나, 돌아오는 응답 패킷이 차단됨.
- **해결**: 상태 추적(Stateful) 규칙을 추가해야 합니다.
    
    ```bash
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ```
    

## 4. 참고자료

- [Netfilter Project Official Documentation](https://netfilter.org/documentation/)
- [ArchWiki: iptables](https://wiki.archlinux.org/title/iptables)
- [Kubernetes: Debugging Service with iptables](https://www.google.com/search?q=https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/%23is-the-kube-proxy-working)
    

## TIP

- **보안(Security)**: 기본 정책(Default Policy)을 `DROP`으로 설정하는 **Default Deny** 전략을 사용하세요. 실수로 규칙이 삭제되어도 보안 사고를 방지할 수 있습니다.
- **비용(Cost)**: 대규모 트래픽 환경에서 수천 개의 iptables 규칙은 CPU 부하를 유발합니다. 규칙이 많아질 경우 선형 탐색이 아닌 Hash 기반의 `IPSet`을 병행 사용하면 성능을 비약적으로 높일 수 있습니다.
- **주의사항**: `iptables -F` 실행 전, 본인의 SSH 접속 IP가 허용되어 있는지 반드시 확인하세요. 그렇지 않으면 원격 서버에서 쫓겨날 수 있습니다(Self-Lockout).

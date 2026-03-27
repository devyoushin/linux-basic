## 1. 개요

Linux 시스템에서 호스트 이름을 IP 주소로 변환(Name Resolution)하는 과정에서 가장 핵심적인 두 파일인 `/etc/hosts`와 `/etc/resolv.conf`의 차이점을 분석합니다. 단순한 이론을 넘어, 현대적인 클라우드 환경(AWS, K8s)에서 이들을 어떻게 자동화하고 모니터링하는지 실무 가이드를 제공합니다.

## 2. 설명

### 2.1 주요 차이점 비교

|**항목**|**/etc/hosts**|**/etc/resolv.conf**|
|---|---|---|
|**역할**|로컬 정적 매핑 (Static Lookup)|외부 DNS 서버 설정 (Dynamic Lookup)|
|**우선순위**|일반적으로 1순위 (nsswitch.conf 설정에 따름)|2순위 (DNS 서버에 질의)|
|**관리 방식**|수동 관리 또는 IaC (Terraform/Ansible)|DHCP 또는 `resolvconf`, `systemd-resolved`가 관리|
|**주요 용도**|로컬 도메인 강제 지정, 테스트, DNS 장애 시 비상용|외부 인터넷 및 사내 서비스 도메인 질의|

### 2.2 실무 적용: IaC를 통한 관리

#### AWS EC2 초기화 시 hosts 파일 관리

EC2 인스턴스 생성 시 `user_data`를 통해 사내 공통 도메인을 강제로 주입하는 예시입니다.

```terraform
resource "aws_instance" "web_server" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.medium"

  user_data = <<-EOF
              #!/bin/bash
              echo "10.0.1.50 internal-db.local" >> /etc/hosts
              echo "10.0.1.60 api-gateway.local" >> /etc/hosts
              EOF
}
```

#### Kubernetes CoreDNS 설정 및 HostAliases

K8s Pod 단위에서 특정 도메인을 강제로 매핑할 때는 `hostAliases`를 사용합니다.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: internal-app
spec:
  hostAliases:
  - ip: "10.1.2.3"
    hostnames:
    - "legacy-service.corp.com"
  containers:
  - name: main
    image: nginx
    # resolv.conf 옵션 튜닝 (ndots 최적화)
    resources:
      limits:
        memory: "128Mi"
        cpu: "500m"
```

## 3. 트러블슈팅

### 3.1 `ndots` 문제로 인한 DNS 성능 저하

- **증상**: K8s 내부에서 외부 도메인 질의 시 응답 속도가 비정상적으로 느림.
- **원인**: `/etc/resolv.conf`의 `options ndots:5` 설정 때문. 점(.)이 5개 미만인 도메인은 내부 search 도메인을 먼저 모두 뒤진 후 외부로 나감.
- **해결**: 애플리케이션 호출 시 도메인 끝에 점을 붙이거나(`google.com.`), `ndots` 설정을 2로 낮춤.

### 3.2 `nsswitch.conf` 우선순위 무시

- **증상**: `/etc/hosts`에 등록했는데 적용이 안 됨.
- **체크**: `/etc/nsswitch.conf` 파일의 `hosts: files dns` 순서를 확인하십시오. `dns files`로 되어있으면 외부 DNS가 우선합니다.

### 3.3 모니터링 및 알람 전략 (Prometheus/Grafana)

DNS Resolution 실패는 서비스 장애로 직결됩니다.

- **Metric**: `coredns_dns_responses_total{rcode="SERVFAIL"}` 
- **Alert Rule (Prometheus)**:    

```yaml
groups:
- name: DNS_Alerts
  rules:
  - alert: HighDNSErrors
    expr: sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m])) > 10
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "DNS Resolution failures detected"
```

## 4. 참고자료

- [Linux Man Page: nsswitch.conf(5)](https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html)
- [Kubernetes Documentation: Pod DNS Config](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [AWS Knowledge Center: EC2 DNS Resolution](https://www.google.com/search?q=https://aws.amazon.com/premiumsupport/knowledge-center/ec2-linux-resolv-conf-nameserver/)

## TIP

- **보안(Security)**: `/etc/hosts`를 이용한 DNS Poisoning 공격을 방지하기 위해 파일 권한을 `644`로 유지하고, 변경 시 Auditing 도구(Auditd)로 감시하세요.
- **비용(Cost)**: 클라우드 환경(AWS Route53 등)에서 과도한 외부 DNS 쿼리는 비용을 발생시킵니다. 빈번히 호출되는 외부 API 주소는 `/etc/hosts`에 등록하거나, 로컬 DNS Caching(`systemd-resolved` 또는 `dnsmasq`)을 활성화하여 쿼리 수를 줄이세요.
- **최신 트렌드**: 최근 모던 배포판은 `systemd-resolved`가 `/etc/resolv.conf`를 심볼릭 링크로 관리하므로, 직접 수정하기보다는 `nmcli`나 `netplan`을 통해 수정하는 것이 정석입니다.

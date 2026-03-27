## 1. 개요

SSH(Secure Shell)는 원격 서버에 암호화된 채널로 접속하는 프로토콜이다.
`sshd_config`(서버 설정)와 `~/.ssh/config`(클라이언트 설정)를 이해하면 보안 강화와 접속 편의성을 동시에 높일 수 있다.
클라우드 환경에서는 키 기반 인증, 포트 변경, 점프 호스트(Bastion) 구성이 핵심 실무 항목이다.

## 2. 설명

### 2.1 SSH 키 생성 및 배포

```bash
# RSA 4096비트 키 생성 (범용)
ssh-keygen -t rsa -b 4096 -C "admin@company.com" -f ~/.ssh/id_rsa_prod

# Ed25519 키 생성 (더 짧고 보안성 높음, 최신 서버에서 권장)
ssh-keygen -t ed25519 -C "admin@company.com" -f ~/.ssh/id_ed25519_prod

# 공개키 서버에 배포
ssh-copy-id -i ~/.ssh/id_rsa_prod.pub ubuntu@192.168.1.100

# 수동 배포 (ssh-copy-id 없는 환경)
cat ~/.ssh/id_rsa_prod.pub | ssh ubuntu@192.168.1.100 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### 2.2 sshd_config - 서버 보안 강화

파일 경로: `/etc/ssh/sshd_config`

```ini
# 포트 변경 (기본 22는 스캔 공격 빈번)
Port 2222

# IPv4만 사용 (필요한 경우)
AddressFamily inet

# 루트 직접 로그인 비활성화 (필수)
PermitRootLogin no

# 비밀번호 인증 비활성화 (키 인증만 허용)
PasswordAuthentication no
ChallengeResponseAuthentication no

# 공개키 인증 활성화
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# 빈 비밀번호 허용 금지
PermitEmptyPasswords no

# 로그인 허용 사용자 화이트리스트
AllowUsers ubuntu deploy

# 로그인 실패 허용 횟수
MaxAuthTries 3

# 유휴 세션 자동 종료 (초 단위, 300초 = 5분)
ClientAliveInterval 300
ClientAliveCountMax 2

# X11 포워딩 비활성화 (서버 환경)
X11Forwarding no

# SSH 프로토콜 2만 허용 (1은 취약)
# Protocol 2  <- 현재 버전은 기본값이 2라 불필요, 명시 옵션 없음
```

```bash
# 설정 문법 검사 (sshd 재시작 전 필수)
sshd -t

# sshd 재시작 (접속 끊김 주의 - 기존 세션은 유지됨)
systemctl reload sshd   # reload: 기존 연결 유지하며 설정 반영
systemctl restart sshd  # restart: 기존 연결 강제 종료
```

> **주의**: sshd 설정 변경 후 바로 세션을 닫지 말고, **새 터미널에서 접속 테스트** 후 기존 세션을 닫는다. 설정 오류 시 서버 잠김(lock-out) 위험이 있다.

### 2.3 클라이언트 config - 접속 편의성

파일 경로: `~/.ssh/config`

```ini
# 공통 설정 (모든 호스트에 적용)
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    AddKeysToAgent yes

# 개발 서버
Host dev
    HostName 10.0.1.50
    User ubuntu
    Port 2222
    IdentityFile ~/.ssh/id_ed25519_dev

# 프로덕션 (Bastion 경유)
Host prod-app
    HostName 10.0.2.100
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519_prod
    ProxyJump bastion   # 아래 bastion 설정 경유

# Bastion 호스트
Host bastion
    HostName 52.78.xxx.xxx
    User ec2-user
    IdentityFile ~/.ssh/id_ed25519_bastion
    Port 22
```

```bash
# 설정 후 사용 (긴 명령어 대신 단축어로 접속)
ssh dev          # ssh -p 2222 ubuntu@10.0.1.50 -i ~/.ssh/id_ed25519_dev
ssh prod-app     # bastion 경유 자동 처리
```

### 2.4 Bastion(점프 호스트) 구성

외부 인터넷에서 private 서브넷 서버로 접근할 때 Bastion을 경유한다.

```bash
# 직접 ProxyJump 사용 (config 없이)
ssh -J ec2-user@bastion-ip ubuntu@private-server-ip

# 포트 포워딩으로 로컬에서 private DB 접근
# 로컬 13306 -> bastion 경유 -> DB 서버 3306
ssh -L 13306:db.internal:3306 bastion -N -f

# 접속 후 로컬에서 DB 클라이언트 연결
mysql -h 127.0.0.1 -P 13306 -u dbuser -p
```

#### Terraform으로 Bastion 구성

```hcl
# Bastion EC2 - public 서브넷에 위치
resource "aws_instance" "bastion" {
  ami                    = "ami-0c55b159cbfafe1f0"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  key_name               = aws_key_pair.bastion_key.key_name

  tags = { Name = "bastion" }
}

resource "aws_security_group" "bastion_sg" {
  name   = "bastion-sg"
  vpc_id = aws_vpc.main.id

  # 특정 IP만 SSH 허용 (회사 IP)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["203.0.113.0/32"]  # 회사 공인 IP
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### 2.5 SSH 키 권한 설정 (보안 필수)

```bash
# SSH 디렉토리 및 파일 권한 (틀리면 접속 거부됨)
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_rsa              # 개인키
chmod 644 ~/.ssh/id_rsa.pub          # 공개키
chmod 600 ~/.ssh/authorized_keys
chmod 600 ~/.ssh/config

# 권한 확인
ls -la ~/.ssh/
```

### 2.6 접속 디버깅

```bash
# 상세 디버그 로그 출력 (-v 1개~3개까지 레벨 증가)
ssh -v  ubuntu@server
ssh -vv ubuntu@server
ssh -vvv ubuntu@server

# sshd 로그 확인 (서버 측)
journalctl -u sshd -f
journalctl -u sshd --since "10 minutes ago"

# 접속 실패 IP 목록 (무차별 대입 공격 탐지)
grep "Failed password" /var/log/auth.log | awk '{print $11}' | sort | uniq -c | sort -rn | head -20
```

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| sshd 재시작 후 바로 세션 닫음 | 새 터미널에서 접속 확인 후 기존 세션 닫기 |
| 비밀번호 인증 끄기 전에 키 배포 안 함 | `PasswordAuthentication no` 전 키 배포 완료 확인 |
| `~/.ssh/authorized_keys` 권한 644로 설정 | 반드시 `chmod 600` (group/other 읽기 금지) |
| 개인키를 서버에 업로드 | 서버에는 공개키(`.pub`)만 배포, 개인키는 로컬 보관 |
| root 직접 로그인 허용 | `PermitRootLogin no` + sudo 사용 원칙 |

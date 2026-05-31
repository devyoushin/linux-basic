## 1. 개요

AWS CLI는 AWS 서비스를 터미널에서 직접 제어하는 공식 도구다.
단순 조회를 넘어 `--query`(JMESPath)와 `--output` 옵션을 활용하면 원하는 정보만 정확히 추출해 배포 자동화, 인스턴스 관리, S3 백업 등의 스크립트를 간결하게 만들 수 있다.

## 2. 설치 및 설정

### 2.1 설치

```bash
# AWS CLI v2 공식 설치 (Linux x86_64)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# 설치 확인
aws --version
# aws-cli/2.x.x Python/3.x.x Linux/...
```

### 2.2 인증 설정

```bash
# 로컬 개발 환경: IAM 사용자 키 설정
aws configure
# AWS Access Key ID: AKIA...
# AWS Secret Access Key: ...
# Default region name: ap-northeast-2
# Default output format: json

# 여러 프로파일 관리 (운영/개발 계정 분리)
aws configure --profile prod
aws configure --profile dev

# 프로파일 사용
aws s3 ls --profile prod
export AWS_PROFILE=prod   # 환경변수로 기본 프로파일 지정

# EC2 인스턴스에서는 IAM Role 사용 (키 불필요)
# 인스턴스에 적절한 IAM Role이 붙어있으면 자동 인증
aws s3 ls   # IAM Role 권한으로 자동 실행
```

### 2.3 출력 형식 제어

```bash
# --output: json(기본), table, text, yaml
aws ec2 describe-instances --output table
aws ec2 describe-instances --output text

# --query: JMESPath로 원하는 필드만 추출
# 기본 출력은 너무 많은 정보 → query로 필터링

# 전체 인스턴스 ID + 상태만 추출
aws ec2 describe-instances \
    --query 'Reservations[*].Instances[*].[InstanceId, State.Name]' \
    --output table
```

---

## 3. EC2

### 3.1 인스턴스 조회

```bash
# 전체 인스턴스 목록 (ID + 이름 + 상태 + IP)
aws ec2 describe-instances \
    --query 'Reservations[*].Instances[*].{
        ID:InstanceId,
        Name:Tags[?Key==`Name`]|[0].Value,
        State:State.Name,
        IP:PrivateIpAddress,
        Type:InstanceType
    }' \
    --output table

# 특정 태그로 필터링 (예: Environment=production)
aws ec2 describe-instances \
    --filters "Name=tag:Environment,Values=production" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].{ID:InstanceId,IP:PrivateIpAddress,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table

# 특정 인스턴스 상세 정보
aws ec2 describe-instances --instance-ids i-0123456789abcdef0
```

### 3.2 인스턴스 시작/중지

```bash
# 중지/시작
aws ec2 stop-instances --instance-ids i-0123456789abcdef0
aws ec2 start-instances --instance-ids i-0123456789abcdef0

# 완료까지 대기 (스크립트에서 활용)
aws ec2 wait instance-stopped --instance-ids i-0123456789abcdef0
echo "인스턴스 중지 완료"

aws ec2 wait instance-running --instance-ids i-0123456789abcdef0
echo "인스턴스 실행 완료"

# 여러 인스턴스 한 번에
aws ec2 stop-instances --instance-ids i-111 i-222 i-333
```

### 3.3 AMI 백업 자동화 스크립트

```bash
#!/bin/bash
# 태그 기반 인스턴스 자동 AMI 백업
set -euo pipefail

REGION="ap-northeast-2"
BACKUP_TAG_KEY="Backup"
BACKUP_TAG_VALUE="true"
RETENTION_DAYS=7

# Backup=true 태그가 달린 실행 중인 인스턴스 목록
INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:${BACKUP_TAG_KEY},Values=${BACKUP_TAG_VALUE}" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

for INSTANCE_ID in $INSTANCE_IDS; do
    NAME=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' \
        --output text)

    AMI_NAME="${NAME}-backup-$(date '+%Y%m%d')"
    echo "AMI 생성: ${AMI_NAME}"

    AMI_ID=$(aws ec2 create-image \
        --instance-id "$INSTANCE_ID" \
        --name "$AMI_NAME" \
        --no-reboot \
        --query 'ImageId' \
        --output text)

    # 태그 추가
    aws ec2 create-tags \
        --resources "$AMI_ID" \
        --tags "Key=Name,Value=${AMI_NAME}" \
               "Key=CreatedBy,Value=auto-backup" \
               "Key=SourceInstance,Value=${INSTANCE_ID}"

    echo "완료: ${AMI_ID}"
done

# 보존 기간 초과 AMI 삭제
OLD_AMIS=$(aws ec2 describe-images \
    --owners self \
    --filters "Name=tag:CreatedBy,Values=auto-backup" \
    --query "Images[?CreationDate<='$(date -d "${RETENTION_DAYS} days ago" '+%Y-%m-%d')'].ImageId" \
    --output text)

for AMI_ID in $OLD_AMIS; do
    echo "오래된 AMI 삭제: ${AMI_ID}"
    aws ec2 deregister-image --image-id "$AMI_ID"
done
```

### 3.4 인스턴스 메타데이터 서비스 (IMDS)

EC2 인스턴스 내부에서 자신의 정보를 가져올 때 사용한다. 키 없이 로컬 HTTP로 접근.

```bash
# IMDSv2 (권장 방식 - 토큰 기반)
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# 토큰 사용해서 메타데이터 조회
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id

# 자주 쓰는 메타데이터 항목
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/local-ipv4)
IAM_ROLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/)

echo "인스턴스: ${INSTANCE_ID}, 리전: ${REGION}, IP: ${PRIVATE_IP}"
```

---

## 4. S3

### 4.1 기본 조작

```bash
# 버킷/파일 목록
aws s3 ls
aws s3 ls s3://my-bucket/
aws s3 ls s3://my-bucket/logs/ --recursive --human-readable

# 파일 업로드/다운로드
aws s3 cp file.txt s3://my-bucket/uploads/file.txt
aws s3 cp s3://my-bucket/uploads/file.txt ./file.txt

# 디렉토리 동기화 (rsync와 유사)
aws s3 sync ./local-dir s3://my-bucket/backup/
aws s3 sync s3://my-bucket/backup/ ./local-dir

# 삭제
aws s3 rm s3://my-bucket/old-file.txt
aws s3 rm s3://my-bucket/old-dir/ --recursive
```

### 4.2 자주 쓰는 옵션

```bash
# 특정 파일 제외/포함
aws s3 sync . s3://my-bucket/ \
    --exclude "*.log" \
    --exclude ".git/*" \
    --include "important.log"

# 스토리지 클래스 지정 (비용 절감)
aws s3 cp backup.tar.gz s3://my-bucket/backups/ \
    --storage-class STANDARD_IA   # Infrequent Access

# 메타데이터/태그 추가
aws s3 cp file.txt s3://my-bucket/ \
    --metadata "env=prod,version=1.2.3"

# ACL 설정 (public 파일)
aws s3 cp index.html s3://my-static-site/ --acl public-read
```

### 4.3 S3 백업 스크립트

```bash
#!/bin/bash
# DB 덤프 후 S3 백업 + 보존 기간 관리
set -euo pipefail

DB_NAME="myapp_prod"
S3_BUCKET="my-company-backups"
S3_PREFIX="database"
RETENTION_DAYS=30
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="/tmp/${DB_NAME}_${TIMESTAMP}.sql.gz"

# DB 덤프
echo "DB 덤프 시작..."
mysqldump -u root "$DB_NAME" | gzip > "$BACKUP_FILE"

# S3 업로드
S3_KEY="${S3_PREFIX}/${DB_NAME}/${TIMESTAMP}.sql.gz"
echo "S3 업로드: s3://${S3_BUCKET}/${S3_KEY}"
aws s3 cp "$BACKUP_FILE" "s3://${S3_BUCKET}/${S3_KEY}" \
    --storage-class STANDARD_IA

# 로컬 임시 파일 삭제
rm -f "$BACKUP_FILE"

# 보존 기간 초과 파일 삭제
CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" '+%Y-%m-%d')
echo "보존 기간(${RETENTION_DAYS}일) 초과 파일 삭제 중..."
aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${DB_NAME}/" \
    | awk -v cutoff="$CUTOFF_DATE" '$1 < cutoff {print $4}' \
    | while read -r file; do
        echo "삭제: $file"
        aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${DB_NAME}/${file}"
    done

echo "백업 완료"
```

---

## 5. SSM Parameter Store - 시크릿 관리

환경변수나 설정 파일에 직접 비밀번호를 쓰지 않고 SSM에서 런타임에 가져온다.

```bash
# 파라미터 저장
aws ssm put-parameter \
    --name "/myapp/prod/DB_PASSWORD" \
    --value "super-secret-password" \
    --type SecureString \
    --overwrite

# 파라미터 조회 (--with-decryption: SecureString 복호화)
aws ssm get-parameter \
    --name "/myapp/prod/DB_PASSWORD" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text

# 경로 하위 파라미터 전체 조회
aws ssm get-parameters-by-path \
    --path "/myapp/prod/" \
    --with-decryption \
    --query 'Parameters[*].{Name:Name,Value:Value}' \
    --output table
```

#### 스크립트에서 SSM 파라미터 활용

```bash
#!/bin/bash
# 애플리케이션 시작 전 SSM에서 환경변수 로드

APP_ENV="prod"
SSM_PATH="/myapp/${APP_ENV}"

# SSM 파라미터를 환경변수로 export
while IFS=$'\t' read -r name value; do
    # /myapp/prod/DB_HOST → DB_HOST 형태로 키 추출
    key="${name##*/}"
    export "$key"="$value"
    echo "로드됨: ${key}"
done < <(aws ssm get-parameters-by-path \
    --path "$SSM_PATH" \
    --with-decryption \
    --query 'Parameters[*].[Name, Value]' \
    --output text)

# 이후 $DB_HOST, $DB_PASSWORD 등으로 사용 가능
exec /opt/myapp/bin/server
```

---

## 6. CloudWatch Logs

```bash
# 로그 그룹 목록
aws logs describe-log-groups \
    --query 'logGroups[*].logGroupName' \
    --output table

# 최근 로그 스트림 확인
aws logs describe-log-streams \
    --log-group-name "/ec2/my-app/journal" \
    --order-by LastEventTime \
    --descending \
    --max-items 5

# 로그 실시간 조회 (tail -f 유사)
aws logs tail "/ec2/my-app/journal" --follow

# 시간 범위 지정 조회
aws logs filter-log-events \
    --log-group-name "/ec2/my-app/journal" \
    --start-time $(date -d "1 hour ago" +%s000) \
    --filter-pattern "ERROR"

# 로그에서 특정 패턴 검색 + 결과를 awk로 가공
aws logs filter-log-events \
    --log-group-name "/ec2/my-app/journal" \
    --filter-pattern "DB_CONNECTION_FAILED" \
    --query 'events[*].message' \
    --output text \
    | awk '{print $1, $2}' \
    | sort | uniq -c | sort -rn
```

---

## 7. 유용한 패턴 모음

```bash
# 현재 계정 ID 확인 (스크립트에서 ARN 구성 시 활용)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)

# 인스턴스에 태그 일괄 추가
aws ec2 create-tags \
    --resources i-111 i-222 i-333 \
    --tags Key=Environment,Value=production Key=Team,Value=backend

# 보안 그룹 규칙 확인 (특정 포트)
aws ec2 describe-security-groups \
    --query 'SecurityGroups[*].{
        Name:GroupName,
        Inbound:IpPermissions[?FromPort==`22`]
    }' \
    --output json

# 만료 예정 SSL 인증서 목록 (ACM)
aws acm list-certificates \
    --query 'CertificateSummaryList[*].{Domain:DomainName,ARN:CertificateArn}' \
    --output table

# ECR 로그인 (Docker 이미지 push 전)
aws ecr get-login-password --region ap-northeast-2 \
    | docker login --username AWS --password-stdin \
      ${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com
```

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| IAM 키를 스크립트에 하드코딩 | EC2 IAM Role 사용, 로컬은 `aws configure` |
| `--query` 없이 전체 JSON 파싱 | `--query`로 필요한 필드만 추출 |
| IMDSv1 사용 (보안 취약) | IMDSv2 토큰 방식 사용 |
| S3 `sync` 후 삭제 파일 남음 | 완전 동기화 필요 시 `--delete` 옵션 추가 |
| 리전 미지정으로 다른 리전 조회 | `--region` 명시 또는 `AWS_DEFAULT_REGION` 환경변수 설정 |
| 민감 정보를 환경변수나 파일에 직접 저장 | SSM Parameter Store 또는 Secrets Manager 사용 |

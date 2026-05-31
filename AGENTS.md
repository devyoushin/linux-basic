# AGENTS.md — linux-basic Codex 작업 지침

이 저장소는 Linux 시스템, 네트워킹, 스토리지, 보안 운영 지식 베이스입니다. Codex 작업 시 `CLAUDE.md`와 `docs/rules/`의 규칙을 동일하게 따릅니다.

## 공통 원칙

- 설명 문서는 `docs/` 아래에 둡니다.
- 실행 가능한 스크립트나 실습 자산은 `ops/` 아래에 둡니다.
- Linux 명령 예시는 대상 배포판과 권한 요구사항을 명확히 표시합니다.
- 커널/sysctl/systemd 변경은 영향 범위와 rollback을 함께 설명합니다.

## Claude와의 싱크

- Claude 지침은 `CLAUDE.md`를 참고합니다.
- Codex도 공통 문서/운영 규칙은 `docs/rules/`를 따릅니다.
- 경로 구조 변경 시 README 계열 문서를 함께 확인합니다.

## 작업 체크리스트

- `git status --short` 확인
- shell script는 `bash -n` 검사
- 링크 검사와 `git diff --check` 수행

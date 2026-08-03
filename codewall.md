# Codewall — Instruções do Repositório

## Contexto

CI com análise SonarQube **informativa** (`continue-on-error` em PR + `qualitygate.wait=false`). Não bloqueia merge.

## Convenções aceitas (não flagar)

- Ferramentas de IA (Cursor, Claude Code) aprovadas pela Política de Uso Seguro de IA da Finaya.
- Secrets org-level no workflow Sonar (`GH_APP_ID`, `GH_APP_PRIVATE_KEY`, `SONAR_TOKEN`, `SONAR_HOST_URL`) — padrão intencional.
- Private key apenas no step Auth via `${{ secrets.* }}`; `SONAR_TOKEN` no step Sonar é requisito da action SonarSource.
- Actions pinadas por commit SHA (supply chain).
- Job ignorado em PRs de fork (secrets indisponíveis).

## Foco do review

Priorizar segurança e correção reais; sugestões sobre padrão Sonar informativo ou ferramenta de IA são baixa prioridade.

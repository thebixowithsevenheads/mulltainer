#!/usr/bin/env bash
# Runner de testes em bash puro. Uso: bash tests/run.sh [arquivo ...]
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RAIZ

OK=0
FALHA=0
declare -a FALHAS=()

_reportar() {
  local resultado="$1" desc="$2" detalhe="${3:-}"
  if [[ "$resultado" == "ok" ]]; then
    OK=$((OK + 1))
    printf '  \033[32m.\033[0m %s\n' "$desc"
  else
    FALHA=$((FALHA + 1))
    FALHAS+=("$desc")
    printf '  \033[31mX\033[0m %s\n' "$desc"
    [[ -n "$detalhe" ]] && printf '      %s\n' "$detalhe"
  fi
}

afirmar_igual() {
  if [[ "$1" == "$2" ]]; then _reportar ok "$3"
  else _reportar falha "$3" "esperado: [$1] / obtido: [$2]"; fi
}

afirmar_contem() {
  if [[ "$2" == *"$1"* ]]; then _reportar ok "$3"
  else _reportar falha "$3" "nao achei [$1] em: $2"; fi
}

afirmar_status() { afirmar_igual "$1" "$2" "$3"; }

declare -a arquivos=("$@")
if [[ ${#arquivos[@]} -eq 0 ]]; then
  while IFS= read -r linha; do arquivos+=("$linha"); done \
    < <(find "$RAIZ/tests" -name 'test_*.sh' | sort)
fi

# Descoberta vazia e' FALHA, nao sucesso. Antes disto, um find que nao achasse
# nada (diretorio errado, arquivos renomeados, checkout parcial) imprimia
# "0 passaram, 0 falharam" e saia 0 -- um verde que nao provava nada.
if [[ ${#arquivos[@]} -eq 0 ]]; then
  printf '\n\033[31mnenhum teste encontrado em %s/tests -- descoberta vazia conta como falha\033[0m\n' \
    "$RAIZ" >&2
  exit 1
fi

# --- o sumario e' impresso por um trap EXIT, nao no fim do corpo -------------
#
# Medido: o `set +e` no topo do laco roda ANTES do source. Um arquivo de teste
# que sourceia lib/common.sh (que faz `set -euo pipefail`) RELIGA o -e para o
# resto da propria execucao dele -- e o `set +e` de baixo, que desligaria de
# novo, so roda depois do source terminar. Entao um comando nao-zero
# desguardado dentro daquele arquivo aborta o PROCESSO durante o source, e o
# runner morria sem imprimir sumario nenhum.
#
# Esse e' o pior modo de falha possivel para um runner: uma suite que morre sem
# sumario PARECE uma suite que passou para quem bate o olho na saida. E e' a
# terceira vez que essa classe de vazamento de -e morde este projeto (ver o
# teste de regressao no fim do tests/test_common.sh e o helper
# _status_confirmar no mesmo arquivo).
#
# Com o trap: execucao normal imprime igual a antes; execucao abortada imprime
# as contagens que ja tinha, nomeia o arquivo que abortou, diz que a execucao
# esta INCOMPLETA, e sai 1.
#
# O trap e' instalado DEPOIS do check de descoberta vazia de proposito: aquele
# caminho tem mensagem propria e nao deve imprimir sumario de sucesso nenhum.
ARQUIVO_ATUAL=""
SUMARIO_IMPRESSO=0

_sumario() {
  local st=$?               # tem que ser a PRIMEIRA linha: e' o status do abort
  if (( SUMARIO_IMPRESSO )); then return 0; fi
  SUMARIO_IMPRESSO=1

  # A propria LINHA DE CONTAGEM tem que dizer que a execucao esta incompleta, no
  # mesmo fluxo (stdout) em que ela e' lida. Se o aviso fosse so no stderr, um
  # `bash tests/run.sh 2>/dev/null` ou um log que separa os fluxos mostraria
  # "1 passaram, 0 falharam" -- exatamente o verde enganoso que este trap
  # existe para eliminar.
  if [[ -n "$ARQUIVO_ATUAL" ]]; then
    printf '\n\033[31m%d passaram, %d falharam -- EXECUCAO INCOMPLETA, ABORTADA em %s (status %d)\033[0m\n' \
      "$OK" "$FALHA" "$(basename "$ARQUIVO_ATUAL")" "$st"
    printf '\033[31mos testes depois desse ponto NAO rodaram. Causa tipica: comando nao-zero\033[0m\n' >&2
    printf '\033[31mdesguardado depois de sourcear lib/common.sh, que religa o -e no processo.\033[0m\n' >&2
  else
    printf '\n%d passaram, %d falharam\n' "$OK" "$FALHA"
  fi

  if (( FALHA > 0 )); then
    printf '\nFalhas:\n'
    for f in "${FALHAS[@]}"; do printf '  - %s\n' "$f"; done
  fi

  if (( FALHA > 0 )) || [[ -n "$ARQUIVO_ATUAL" ]]; then exit 1; fi
  exit 0
}
trap _sumario EXIT

for arquivo in "${arquivos[@]}"; do
  set +e  # Desativa -e: libs sourced (lib/common.sh) definem set -euo pipefail e isso vazaria para ca
  printf '\n\033[1m%s\033[0m\n' "$(basename "$arquivo")"
  # ARQUIVO_ATUAL nao-vazio e' o marcador de "estou no meio de um source". Se o
  # trap disparar com ele setado, o processo morreu la dentro.
  ARQUIVO_ATUAL="$arquivo"
  # shellcheck disable=SC1090
  source "$arquivo"
  ARQUIVO_ATUAL=""
  set +e  # Desativa -e novamente para o runner continuar -e-livre e contar falhas ate o fim
done

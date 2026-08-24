#!/usr/bin/env bash
# demo/gravar-real.sh -- grava uma prova de conceito REAL, com asciinema.
#
# Diferente do demo/mockup.sh: aqui nada e encenado. E uma instalacao de
# verdade, numa conta Mullvad de verdade, e a prova e o IP de saida mudando
# entre dois relays diferentes.
#
# Por isso a gravacao NAO deve ser publicada crua. O fluxo completo e:
#
#   1. bash demo/gravar-real.sh          <- gera demo/build/real-bruto.cast
#   2. o proprio script redige e varre   <- gera demo/build/real.cast
#   3. voce confere o resultado          <- asciinema play demo/build/real.cast
#   4. so entao vira GIF
#
# O passo 2 sai com erro se sobrar qualquer padrao sensivel. Um arquivo que nao
# passa na varredura nao deve ser publicado.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${RAIZ}/lib/common.sh"

SAIDA_DIR="${RAIZ}/demo/build"
BRUTO="${SAIDA_DIR}/real-bruto.cast"
LIMPO="${SAIDA_DIR}/real.cast"
CONTAINER="${CONTAINER:-exegol-mullvad}"

# Ritmo. A gravacao e para ser LIDA, entao cada passo tem uma pausa e um titulo.
PAUSA="${PAUSA:-2.5}"

passo() {
  printf '\n%s%s %s %s\n\n' "$AZUL_FUNDO" "$AMARELO$NEGRITO" \
    "$(printf '%-74s' "$1")" "$RESET"
  sleep "$PAUSA"
}

# O que interessa do ipinfo: o IP e onde ele fica. O resto do JSON e ruido.
mostrar_ip() {
  local titulo="$1"
  printf '  %s%s%s\n' "$CINZA" "$titulo" "$RESET"
  docker exec "$CONTAINER" curl -s --max-time 20 https://ipinfo.io/json \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("    (sem resposta -- sem tunel, o kill switch bloqueia tudo)")
    raise SystemExit(0)
print("    IP ........ %s" % d.get("ip", "?"))
print("    Local ..... %s, %s" % (d.get("city", "?"), d.get("country", "?")))
print("    Rede ...... %s" % d.get("org", "?"))
' || printf '    (sem resposta)\n'
  sleep "$PAUSA"
}

# --- o roteiro gravado -------------------------------------------------------
roteiro() {
  clear 2>/dev/null || true
  banner
  printf '  %sProva de conceito: instalacao real, do zero.%s\n' "$NEGRITO" "$RESET"
  printf '  %sNenhum dado desta tela e encenado.%s\n' "$CINZA" "$RESET"
  sleep "$PAUSA"

  passo "1/4  Instalacao completa (opcao 1 do menu)"
  printf '  %sO numero da conta e lido sem eco e aparece mascarado.%s\n' "$CINZA" "$RESET"
  printf '  %sA chave privada nunca e impressa nem passa por argv.%s\n\n' "$CINZA" "$RESET"
  sleep "$PAUSA"
  sudo bash "${RAIZ}/install.sh"

  passo "2/4  IP de saida ANTES da troca"
  mostrar_ip "pelo relay escolhido na instalacao:"

  passo "3/4  Trocando de relay pelo mullvad-switch"
  printf '  %sEscolha um pais DIFERENTE do atual -- e o que prova a troca.%s\n\n' \
    "$CINZA" "$RESET"
  sleep "$PAUSA"
  docker exec -it "$CONTAINER" python3 /opt/my-resources/bin/mullvad-switch.py

  passo "4/4  IP de saida DEPOIS da troca"
  mostrar_ip "pelo relay novo:"

  printf '\n'
  ok "Se os dois IPs acima sao diferentes e ambos sao da Mullvad, esta provado."
  sleep 4
}

# --- orquestracao ------------------------------------------------------------
main() {
  tem_comando asciinema || morrer "asciinema nao encontrado"
  tem_comando docker    || morrer "docker nao encontrado"
  mkdir -p "$SAIDA_DIR"

  if [[ "${1:-}" == "--roteiro" ]]; then
    roteiro
    return 0
  fi

  aviso "Esta gravacao e REAL: conta Mullvad de verdade, instalacao de verdade."
  aviso "O arquivo bruto fica em ${BRUTO} e NAO deve ser publicado."
  aviso "A versao redigida e varrida fica em ${LIMPO}."
  printf '\n'
  confirmar "Gravar agora?" || { info "cancelado."; return 1; }

  asciinema rec --overwrite \
    -c "bash '${BASH_SOURCE[0]}' --roteiro" \
    "$BRUTO"

  printf '\n'
  info "Redigindo e varrendo..."
  # O usuario e o hostname vem da maquina, nao chumbados: e' o que faz este
  # script servir para quem nao e' o dono deste repositorio.
  #
  # `id -un`, nao REAL_USER: aquele so e' definido dentro de
  # descobrir_ambiente(), que exige root e mata o script fora dele. Este aqui
  # roda como usuario comum de proposito -- o sudo e so do install.sh.
  python3 "${RAIZ}/demo/redigir-cast.py" "$BRUTO" "$LIMPO" \
    --usuario "$(id -un)" --host "$(hostname)" \
    || { erro "A VARREDURA REPROVOU. Nao publique ${LIMPO}."; return 1; }

  printf '\n'
  ok "Gravacao redigida: ${LIMPO}"
  info "Confira com os proprios olhos antes de gerar o GIF:"
  printf '    asciinema play %s\n' "$LIMPO"
  info "Depois:"
  printf '    python3 demo/cast2gif.py %s demo/prova.gif --fps 4 --rows 40\n' "$LIMPO"
}

main "$@"

#!/usr/bin/env bash
# install.sh -- instalador plug and play: Exegol + Mullvad com kill switch em
# duas camadas. Menu interativo; cada estagio e idempotente e rodavel isolado.
#
# Uso: sudo bash install.sh [opcoes]
set -euo pipefail

RAIZ_INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${RAIZ_INSTALL}/lib/common.sh"
for _lib in 01-deps 02-mullvad 03-container 04-killswitch 05-verify 06-uninstall; do
  # shellcheck disable=SC1090
  source "${RAIZ_INSTALL}/lib/${_lib}.sh"
done

CONTAINER_NAME="${CONTAINER_NAME:-mullvad}"
IMAGE_TAG="${IMAGE_TAG:-free}"
NETWORK_NAME="${NETWORK_NAME:-exegol-vpn-net}"
SUBNET="${SUBNET:-172.30.30.0/24}"
GATEWAY="${GATEWAY:-172.30.30.1}"
STATIC_IP="${STATIC_IP:-172.30.30.10}"
ASSUME_SIM=0
CONF_INFORMADO=""
ESTAGIO_UNICO=""
DESINSTALAR=0

uso() {
  cat <<FIM
Uso: sudo bash install.sh [opcoes]

Sem opcao nenhuma, abre o menu interativo.

  --yes                assume os padroes e nao pergunta nada. Exige --conf.
  --conf PATH          usa este .conf da Mullvad (pula a escolha do estagio 2)
  --stage NOME         roda um estagio so: deps, mullvad, container,
                       killswitch, verify
  --uninstall          desinstala sem passar pelo menu
  --name NOME          nome do container, sem o prefixo exegol- (padrao: mullvad)
  --image TAG          tag da imagem Exegol (padrao: free)
  --network NOME       rede docker dedicada (padrao: exegol-vpn-net)
  --subnet CIDR        subnet da rede (padrao: 172.30.30.0/24)
  --ip IP              IP fixo do container (padrao: 172.30.30.10)
  -h, --help           mostra esta ajuda
FIM
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)       ASSUME_SIM=1; shift ;;
    --conf)      CONF_INFORMADO="${2:?--conf exige um caminho}"; shift 2 ;;
    --stage)     ESTAGIO_UNICO="${2:?--stage exige um nome}"; shift 2 ;;
    --uninstall) DESINSTALAR=1; shift ;;
    --name)      CONTAINER_NAME="${2:?}"; shift 2 ;;
    --image)     IMAGE_TAG="${2:?}"; shift 2 ;;
    --network)   NETWORK_NAME="${2:?}"; shift 2 ;;
    --subnet)    SUBNET="${2:?}"; shift 2 ;;
    --ip)        STATIC_IP="${2:?}"; shift 2 ;;
    -h|--help)   uso; exit 0 ;;
    *)           erro "argumento desconhecido: $1"; uso; exit 1 ;;
  esac
done

FULL_NAME="exegol-${CONTAINER_NAME}"
export ASSUME_SIM CONF_INFORMADO CONTAINER_NAME FULL_NAME IMAGE_TAG \
       NETWORK_NAME SUBNET GATEWAY STATIC_IP

descobrir_ambiente

# Se ja existe um .conf adotado, reaproveita sem perguntar de novo.
if [[ -z "$CONF_INFORMADO" ]]; then
  # O || true e obrigatorio: com pipefail, o find falhando (o diretorio ainda
  # nao existe numa instalacao limpa) mataria o script aqui, em silencio.
  _achado="$(find /etc/wireguard/mullvad -maxdepth 1 -name '*.conf' -type f 2>/dev/null \
    | sort | head -1 || true)"
  [[ -n "$_achado" ]] && MULLVAD_CONF="$_achado"
fi
export MULLVAD_CONF="${MULLVAD_CONF:-}"

# --- painel de estado ------------------------------------------------------

_linha() { printf '    %-18s %s\n' "$1" "$2"; }

_estado_imagem() {
  if docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" >/dev/null 2>&1; then
    docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" --format '{{.Size}}' \
      | awk -v t="$IMAGE_TAG" '{printf "%s (%.0f GB em disco)", t, $1/1000000000}' || true
  else
    printf '%s nao instalada' "$IMAGE_TAG"
  fi
}

_estado_container() {
  local estado
  estado="$(docker container inspect "$FULL_NAME" --format '{{.State.Status}}' 2>/dev/null)" \
    || { printf 'nao existe'; return; }
  printf '%s' "$estado"
}

mostrar_estado() {
  local chain unit
  chain="$(nome_chain "$CONTAINER_NAME")"
  unit="$(nome_unit "$CONTAINER_NAME")"

  banner

  _linha "Distro" "$(detectar_distro)"
  if systemctl is-active --quiet docker; then
    _linha "Docker" "ok, ativo"
  else
    _linha "Docker" "ausente ou parado"
  fi
  if [[ -x "$EXEGOL_BIN" ]]; then
    _linha "Exegol" "$(exegol_cmd version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1 || echo presente)"
  else
    _linha "Exegol" "nao instalado"
  fi
  _linha "Imagem" "$(_estado_imagem)"
  _linha "Config Mullvad" "${MULLVAD_CONF:-nenhuma encontrada}"
  _linha "Container" "$(_estado_container)"
  if iptables -L "$chain" -n >/dev/null 2>&1; then
    _linha "Kill switch" "ativo (chain ${chain})"
  else
    _linha "Kill switch" "inativo"
  fi
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    _linha "Watcher" "ativo"
  else
    _linha "Watcher" "inativo"
  fi
  printf '\n'
}

# --- orquestracao ----------------------------------------------------------

# Opcao do menu que retoma cada estagio, para a mensagem de erro dizer
# exatamente por onde continuar em vez de so anunciar a falha.
_opcao_do_estagio() {
  case "$1" in
    estagio_deps)       printf '2 (So dependencias)' ;;
    estagio_mullvad)    printf '3 (So config Mullvad)' ;;
    estagio_container)  printf '4 (So o container)' ;;
    estagio_killswitch) printf '5 (So o kill switch)' ;;
    estagio_verify)     printf '6 (Verificar)' ;;
    *)                  printf '1 (Instalacao completa)' ;;
  esac
}

# Roda um estagio e trata o status: 0 ok, 3 usuario cancelou, resto e erro.
#
# ATENCAO: o `"$fn" || st=$?` abaixo SUPRIME o errexit dentro do corpo do
# estagio -- e regra do bash para comandos em contexto de ||. Medido: uma funcao
# com um `false` no meio, chamada assim, segue executando e devolve 0. Por isso
# cada estagio guarda seus proprios comandos que mutam estado com
# `|| { erro "..."; return 1; }`; nao ha protecao implicita aqui.
#
# Medido tambem que a supressao atravessa chamadas aninhadas: se um estagio
# delega a uma funcao auxiliar que delega a outra, uma falha guardada com
# `return 1` no fundo da pilha e' descartada em silencio a menos que TODO nivel
# intermediario tambem verifique com `|| return $?` -- confirmado com
# `inner() { return 1; }; outer() { inner; echo "roda mesmo assim"; return 0; }`
# chamado como `outer || st=$?`: imprime a linha e devolve st=0. Por isso, dentro
# de cada estagio, toda chamada a uma funcao auxiliar que nao seja a ultima
# linha do corpo tambem leva `|| return $?`.
#
# Nao troque isto por subshell em background + wait para "recuperar" o errexit:
# testado, funciona para o errexit e QUEBRA o instalador, porque um subshell em
# background recebe EOF imediato no stdin e todo `confirmar` passa a falhar.
rodar() {
  local nome="$1" fn="$2" st=0
  printf '\n%s>>> %s%s\n' "$NEGRITO" "$nome" "$RESET"
  "$fn" || st=$?
  case "$st" in
    0) return 0 ;;
    3) aviso "estagio '${nome}' cancelado"; return 3 ;;
    *) erro "estagio '${nome}' falhou (status ${st})"
       erro "Para retomar daqui, escolha a opcao $(_opcao_do_estagio "$fn") no menu."
       return "$st" ;;
  esac
}

instalacao_completa() {
  rodar "Dependencias"  estagio_deps       || return $?
  rodar "Config Mullvad" estagio_mullvad   || return $?
  rodar "Container"     estagio_container  || return $?
  rodar "Kill switch"   estagio_killswitch || return $?
  info "Subindo o tunel pela primeira vez..."
  docker exec "$FULL_NAME" wg-quick down wg0 >/dev/null 2>&1 || true
  # return 1, nao morrer: chegar aqui ja significa deps, mullvad-conf, container
  # e kill switch todos mutados com sucesso -- morrer mataria o instalador sem o
  # rodar() reportar nada, deixando o usuario com tudo instalado, sem tunel de
  # pe, e sem instalador. instalacao_completa ja encadeia tudo com
  # `|| return $?`, entao isso propaga corretamente.
  docker exec "$FULL_NAME" wg-quick up wg0 \
    || { erro "wg-quick up falhou -- veja: docker exec ${FULL_NAME} wg-quick up wg0"; return 1; }
  sleep 2
  rodar "Verificacao"   estagio_verify     || return $?
  printf '\n'
  ok "Pronto. Use: exegol start ${CONTAINER_NAME}   e dentro dele: mullvad-switch"
}

menu() {
  while true; do
    mostrar_estado
    printf '    1) Instalacao completa   <- faz tudo, do zero\n'
    printf '    2) So dependencias\n'
    printf '    3) So config Mullvad\n'
    printf '    4) So o container\n'
    printf '    5) So o kill switch\n'
    printf '    6) Verificar / testar vazamento\n'
    printf '    7) Desinstalar\n'
    printf '    0) Sair\n\n'
    local escolha=""
    read -r -p "$(printf '%s[?]%s escolha> ' "$AMARELO" "$RESET")" escolha
    case "$escolha" in
      1) instalacao_completa || true ;;
      2) rodar "Dependencias"   estagio_deps        || true ;;
      3) rodar "Config Mullvad" estagio_mullvad     || true ;;
      4) rodar "Container"      estagio_container   || true ;;
      5) rodar "Kill switch"    estagio_killswitch  || true ;;
      6) rodar "Verificacao"    estagio_verify      || true ;;
      7) rodar "Desinstalacao"  estagio_desinstalar || true ;;
      0) exit 0 ;;
      *) erro "opcao invalida" ;;
    esac
  done
}

if (( DESINSTALAR )); then
  rodar "Desinstalacao" estagio_desinstalar
  exit $?
fi

if [[ -n "$ESTAGIO_UNICO" ]]; then
  case "$ESTAGIO_UNICO" in
    deps)       rodar "Dependencias"   estagio_deps ;;
    mullvad)    rodar "Config Mullvad" estagio_mullvad ;;
    container)  rodar "Container"      estagio_container ;;
    killswitch) rodar "Kill switch"    estagio_killswitch ;;
    verify)     rodar "Verificacao"    estagio_verify ;;
    *) erro "estagio desconhecido: ${ESTAGIO_UNICO}"; uso; exit 1 ;;
  esac
  exit $?
fi

if (( ASSUME_SIM )); then
  [[ -n "$CONF_INFORMADO" ]] || morrer \
    "--yes exige --conf PATH: a rota automatica precisa do numero da conta, que nao tem padrao"
  instalacao_completa
  exit $?
fi

menu

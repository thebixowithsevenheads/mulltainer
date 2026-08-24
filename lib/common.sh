#!/usr/bin/env bash
# lib/common.sh -- UI, log, deteccao de ambiente e derivacao de nomes.
# Sourceado pelo install.sh e por todos os estagios. Nao executa nada ao ser
# sourceado: define funcoes e variaveis, nada mais.
set -euo pipefail

AMARELO=$'\033[38;2;255;213;36m'
AZUL=$'\033[38;2;41;77;115m'
# O mesmo azul da marca como FUNDO. Como texto (AZUL, acima) ele quase nao
# contrasta com um terminal escuro, entao faixa de titulo usa o fundo.
AZUL_FUNDO=$'\033[48;2;41;77;115m'
BRANCO=$'\033[38;2;255;255;255m'
CINZA=$'\033[38;2;108;137;168m'
VERMELHO=$'\033[31m'
VERDE=$'\033[32m'
NEGRITO=$'\033[1m'
RESET=$'\033[0m'

info()   { printf '%s[*]%s %s\n' "$AZUL" "$RESET" "$*"; }
ok()     { printf '%s[+]%s %s\n' "$VERDE" "$RESET" "$*"; }
aviso()  { printf '%s[!]%s %s\n' "$AMARELO" "$RESET" "$*"; }
erro()   { printf '%s[-]%s %s\n' "$VERMELHO" "$RESET" "$*" >&2; }
morrer() { erro "$*"; exit 1; }

# Pergunta sim/nao. Padrao sim. Respeita ASSUME_SIM=1 (flag --yes).
confirmar() {
  local pergunta="$1" resposta=""
  if [[ "${ASSUME_SIM:-0}" == "1" ]]; then
    info "$pergunta -> sim (--yes)"
    return 0
  fi
  if ! read -r -p "$(printf '%s[?]%s %s [S/n] ' "$AMARELO" "$RESET" "$pergunta")" resposta; then
    erro "Terminal nao interativo e ASSUME_SIM nao definido. Use --yes ou redirecione stdin."
    return 1
  fi
  [[ -z "$resposta" || "$resposta" =~ ^[SsYy]$ ]]
}

# Familia da distro a partir de um os-release. Ecoa arch|debian|desconhecida.
detectar_distro() {
  local arquivo="${1:-/etc/os-release}"
  [[ -r "$arquivo" ]] || { printf 'desconhecida\n'; return 0; }
  local id id_like
  id="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print $2; exit}' "$arquivo")"
  id_like="$(awk -F= '/^ID_LIKE=/{gsub(/"/, "", $2); print $2; exit}' "$arquivo")"
  case " ${id} ${id_like} " in
    *" arch "*)                 printf 'arch\n' ;;
    *" debian "*|*" ubuntu "*)  printf 'debian\n' ;;
    *)                          printf 'desconhecida\n' ;;
  esac
}

# EXEGOL-MULLVAD-KS. iptables limita nomes de chain a 28 caracteres e
# "EXEGOL-" + "-KS" ja gastam 10, entao o nome do container e truncado em 18.
nome_chain() {
  local maiusc
  maiusc="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  printf 'EXEGOL-%.18s-KS\n' "$maiusc"
}

nome_unit()     { printf 'exegol-%s-killswitch-watcher.service\n' "$1"; }
dir_workspace() { printf '%s/.exegol/workspaces/%s\n' "$1" "$2"; }
caminho_state() { printf '%s/.exegol/workspaces/%s/.mullvad/state.json\n' "$1" "$2"; }

conta_valida() { [[ "${1:-}" =~ ^[0-9]{16}$ ]]; }

mascarar_conta() {
  local c="${1:-}"
  if (( ${#c} <= 4 )); then printf '%s\n' "$c"; return 0; fi
  printf '%s%s\n' "$(printf '%*s' $(( ${#c} - 4 )) '' | tr ' ' '*')" "${c: -4}"
}

# --- banner ---------------------------------------------------------------

# Arte de 80 colunas com gradiente do amarelo Mullvad (#FFD524) ao azul
# Mullvad (#294D73). Em terminal com menos de 82 colunas o bloco quebraria e
# ficaria pior que nao ter, entao cai numa versao compacta. Nunca imprime nada
# ao ser sourceado -- so quando chamada.
banner() {
  local cols
  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

  if (( cols < 82 )); then
    printf '\n  %sM U L L T A I N E R%s\n' "$AMARELO$NEGRITO" "$RESET"
    printf '  %scontainer Exegol que so sai pela Mullvad%s\n\n' "$CINZA" "$RESET"
    return 0
  fi

  # Uma cor por linha; os codigos vem do gradiente calculado uma vez, nao de
  # conta em tempo de execucao.
  local -a cor=(
    $'\033[38;2;255;213;36m'
    $'\033[38;2;212;186;52m'
    $'\033[38;2;169;159;68m'
    $'\033[38;2;127;131;83m'
    $'\033[38;2;84;104;99m'
    $'\033[38;2;41;77;115m'
  )
  # Só bloco cheio (U+2588) e espaço. A versão anterior era a ANSI Shadow do
  # figlet, que mistura █ com ═║╔╗╚╝: as bordas finas viram ruído em fonte
  # pequena e são o que mais varia de largura entre fontes monoespaçadas.
  local -a arte=(
'  ██    ██  ██  ██  ██     ██     ██████  ██████  ████  ██   ██  █████  █████ '
'  ████████  ██  ██  ██     ██       ██    ██  ██   ██   ███  ██  ██     ██  ██'
'  ██ ██ ██  ██  ██  ██     ██       ██    ██████   ██   ██ █ ██  ████   █████ '
'  ██ ██ ██  ██  ██  ██     ██       ██    ██  ██   ██   ██  ███  ██     ██ ██ '
'  ██    ██  ██  ██  ██     ██       ██    ██  ██   ██   ██   ██  ██     ██  ██'
'  ██    ██  ██████  █████  █████    ██    ██  ██  ████  ██   ██  █████  ██  ██'
  )

  printf '\n'
  local i
  for i in "${!arte[@]}"; do
    printf '%s%s%s\n' "${cor[$i]}" "${arte[$i]}" "$RESET"
  done
  printf '  %sExegol + Mullvad%s  %s·%s  %skill switch em duas camadas%s\n\n' \
    "$AMARELO" "$RESET" "$CINZA" "$RESET" "$CINZA" "$RESET"
}

# --- ambiente e privilegio -------------------------------------------------

# Exige root via sudo e descobre quem e o usuario real.
# Exporta REAL_USER, REAL_HOME, EXEGOL_BIN.
descobrir_ambiente() {
  [[ $EUID -eq 0 ]] || morrer "precisa de root: sudo bash install.sh"
  REAL_USER="${SUDO_USER:-}"
  [[ -n "$REAL_USER" ]] || morrer \
    "rode via sudo, nao como root direto -- preciso saber de quem e o ~/.exegol"
  REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"
  [[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || morrer "nao achei o home de $REAL_USER"
  EXEGOL_BIN="${EXEGOL_BIN:-$REAL_HOME/.local/bin/exegol}"
  export REAL_USER REAL_HOME EXEGOL_BIN
}

# Invoca o binario do Exegol como root, com HOME/SUDO_HOME do usuario real.
#
# O Exegol NAO se auto-escala -- nao existe chamada de sudo no codigo dele
# (verificado na v5.1.11). O prompt de senha que aparece na pratica vem de um
# alias de shell do usuario (ex.: alias exegol='sudo -E ~/.local/bin/exegol').
# Como o instalador ja roda como root, chamamos o binario direto. E por isso que
# o instalador NAO depende do usuario estar no grupo docker.
# SUDO_HOME e lido pelo Exegol para localizar o diretorio de config
# (ConstantConfig.py:25).
exegol_cmd() {
  HOME="$REAL_HOME" SUDO_HOME="$REAL_HOME" USER="$REAL_USER" LOGNAME="$REAL_USER" \
    "$EXEGOL_BIN" "$@"
}

tem_comando() { command -v "$1" >/dev/null 2>&1; }

# Raiz do repositorio, para achar payload/ independente do cwd de quem chamou.
# Definida a partir da localizacao deste arquivo, nao do diretorio corrente.
RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RAIZ_REPO

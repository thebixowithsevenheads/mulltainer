#!/usr/bin/env bash
# lib/01-deps.sh -- estagio 1: dependencias do host e imagem do Exegol.
# Sourceado pelo install.sh. Nao executa nada ao ser sourceado.
set -euo pipefail

# Tamanho conservador da imagem em disco, em GB. O `exegol info` reporta ~42 GB
# para a free; o `docker image inspect .Size` reporta ~67 GB para a mesma imagem
# (soma das camadas). Usamos o maior no check de espaco livre de proposito.
TAMANHO_IMAGEM_GB=67

# Nome do pacote de uma dependencia, por familia de distro.
# Status 1 se nao houver mapeamento.
pacote_para() {
  case "${1}:${2}" in
    arch:docker)     printf 'docker\n' ;;
    arch:pipx)       printf 'python-pipx\n' ;;
    arch:wg)         printf 'wireguard-tools\n' ;;
    arch:iptables)   printf 'iptables\n' ;;
    arch:curl)       printf 'curl\n' ;;
    arch:python3)    printf 'python\n' ;;
    debian:docker)   printf 'docker.io\n' ;;
    debian:pipx)     printf 'pipx\n' ;;
    debian:wg)       printf 'wireguard-tools\n' ;;
    debian:iptables) printf 'iptables\n' ;;
    debian:curl)     printf 'curl\n' ;;
    debian:python3)  printf 'python3\n' ;;
    *) return 1 ;;
  esac
}

comando_instalar() {
  local distro="$1"; shift
  case "$distro" in
    arch)   printf 'pacman -S --needed --noconfirm %s\n' "$*" ;;
    debian) printf 'apt-get install -y %s\n' "$*" ;;
    *) return 1 ;;
  esac
}

# Comando que testa a presenca de cada dependencia.
_presente() {
  case "$1" in
    docker)   tem_comando docker ;;
    pipx)     tem_comando pipx ;;
    wg)       tem_comando wg ;;
    iptables) tem_comando iptables ;;
    curl)     tem_comando curl ;;
    python3)  tem_comando python3 ;;
    *) return 1 ;;
  esac
}

estagio_deps() {
  local distro
  distro="$(detectar_distro)"
  info "Distro detectada: ${distro}"

  if [[ "$distro" == "desconhecida" ]]; then
    erro "Distro nao suportada. Suportadas: Arch (e derivadas) e Debian/Ubuntu."
    erro "Instale na mao e rode de novo: docker, pipx, wireguard-tools, iptables, curl, python3"
    return 3
  fi

  # --- systemd ---
  # ANTES de instalar qualquer coisa, nao depois: e' o que o README promete
  # ("verifica isso antes de instalar qualquer coisa") e e' o comportamento
  # certo -- nao ha por que baixar pacotes num host onde o resto do instalador
  # (unit do watcher, systemctl enable) nao tem como funcionar.
  tem_comando systemctl || morrer \
    "este instalador precisa de systemd (nao achei o systemctl). Suba o docker manualmente e rode de novo."

  # --- pacotes do sistema ---
  local faltando=() dep pacote
  for dep in docker pipx wg iptables curl python3; do
    if _presente "$dep"; then
      ok "${dep}: presente"
    else
      pacote="$(pacote_para "$distro" "$dep")" || morrer "sem mapeamento de pacote para ${dep}"
      aviso "${dep}: ausente -> pacote ${pacote}"
      faltando+=("$pacote")
    fi
  done

  if (( ${#faltando[@]} > 0 )); then
    local cmd
    cmd="$(comando_instalar "$distro" "${faltando[@]}")"
    info "Vou rodar: ${cmd}"
    confirmar "Instalar os pacotes que faltam?" || return 3
    [[ "$distro" == "debian" ]] && apt-get update -qq
    # shellcheck disable=SC2086
    eval $cmd || { erro "falha instalando pacotes com: ${cmd}"; return 1; }
  fi

  # --- docker ativo ---
  if ! systemctl is-active --quiet docker; then
    info "Habilitando e subindo o docker.service..."
    systemctl enable --now docker \
      || { erro "nao consegui habilitar o docker.service"; return 1; }
  fi
  ok "docker.service ativo"

  # O instalador fala com o docker como root, entao isso e conveniencia para o
  # uso posterior pelo proprio usuario -- a instalacao nao depende disso.
  getent group docker >/dev/null || aviso "grupo docker nao existe, pulando"
  if getent group docker >/dev/null && ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
    info "Adicionando ${REAL_USER} ao grupo docker (vale depois de relogar)..."
    usermod -aG docker "$REAL_USER"
    aviso "Para usar 'docker' sem sudo, relogue depois. A instalacao segue sem isso."
  fi

  # --- exegol ---
  if [[ -x "$EXEGOL_BIN" ]]; then
    ok "exegol: $(exegol_cmd version 2>/dev/null | head -1 || echo presente)"
  else
    info "Instalando o Exegol via pipx como ${REAL_USER}..."
    confirmar "Instalar o Exegol?" || return 3
    sudo -u "$REAL_USER" env HOME="$REAL_HOME" pipx install exegol
    [[ -x "$EXEGOL_BIN" ]] || morrer "pipx terminou mas nao achei o binario em ${EXEGOL_BIN}"
    ok "exegol instalado"
  fi

  _tela_imagem
}

# Tela de escolha da imagem. Mostra o `exegol info` cru de proposito: ele traz
# os tamanhos reais e o parse da tabela rica dele seria fragil e quebraria a
# cada release.
_tela_imagem() {
  if docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" >/dev/null 2>&1; then
    local tamanho
    tamanho="$(docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" \
      --format '{{.Size}}' | awk '{printf "%.0f GB", $1/1000000000}' || true)"
    ok "imagem ${IMAGE_TAG}: ja instalada (${tamanho})"
    return 0
  fi

  printf '\n%sImagens do Exegol%s\n\n' "$NEGRITO" "$RESET"
  printf '  %sfree%s   gratuita, sem assinatura -- e o padrao aqui\n' "$AMARELO" "$RESET"
  printf '  as demais aparecem marcadas "Pro / Enterprise only" na tabela abaixo\n\n'
  # A tabela do proprio exegol traz os tamanhos e ja marca quais exigem
  # assinatura. Mostramos ela crua: parsear essa tabela rica seria fragil e
  # quebraria a cada release.
  exegol_cmd info 2>/dev/null || aviso "nao consegui rodar 'exegol info'"

  local livre
  # || true: com pipefail, o df falhando (docker recem instalado, /var/lib/docker
  # ainda inexistente) mataria o estagio em silencio.
  livre="$(df --output=avail -BG /var/lib/docker 2>/dev/null \
    | tail -1 | tr -dc '0-9' || true)"
  if [[ -n "$livre" ]]; then
    printf '\n  Espaco livre em /var/lib/docker: %s GB\n' "$livre"
    # Os dois numeros divergem para a MESMA imagem e os dois sao reais:
    # `exegol info` reporta ~42 GB, e `docker image inspect .Size` reporta
    # ~67 GB (soma das camadas). O limite usa o numero conservador, porque
    # avisar de menos deixa o usuario sem disco no meio de um download de
    # dezenas de GB -- a falha tem que cair pro lado seguro.
    if (( livre < TAMANHO_IMAGEM_GB + 13 )); then
      aviso "A imagem ${IMAGE_TAG} ocupa ~42 GB pelo 'exegol info' e ~${TAMANHO_IMAGEM_GB} GB"
      aviso "pela soma de camadas do docker. Voce tem ${livre} GB livres."
      confirmar "Continuar mesmo assim?" || return 3
    fi
  fi

  info "Baixando a imagem ${IMAGE_TAG} (demora -- sao dezenas de GB)..."
  confirmar "Baixar agora?" || return 3
  exegol_cmd install "$IMAGE_TAG"
}

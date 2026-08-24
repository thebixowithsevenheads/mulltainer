#!/usr/bin/env bash
# lib/06-uninstall.sh -- remove tudo que o instalador colocou no host.
# Nao executa nada ao ser sourceado.
set -euo pipefail

estagio_desinstalar() {
  local unit chain falhas=0
  unit="$(nome_unit "$CONTAINER_NAME")"
  chain="$(nome_chain "$CONTAINER_NAME")"

  aviso "Isso vai remover o container ${FULL_NAME}, a rede ${NETWORK_NAME},"
  aviso "a chain ${chain} e a unit ${unit}."
  confirmar "Continuar com a desinstalacao?" || return 3

  if [[ -f "/etc/systemd/system/${unit}" ]]; then
    info "Removendo ${unit}..."
    systemctl disable --now "$unit" 2>/dev/null || true
    rm -f "/etc/systemd/system/${unit}"
    systemctl daemon-reload
  fi

  rm -f "/usr/local/sbin/exegol-${CONTAINER_NAME}-killswitch-watcher.sh"
  # O backstop e compartilhado entre containers: so remove se nao sobrou watcher.
  if ! ls /usr/local/sbin/exegol-*-killswitch-watcher.sh >/dev/null 2>&1; then
    rm -f /usr/local/sbin/exegol-killswitch-backstop.sh
  fi

  if iptables -L "$chain" -n >/dev/null 2>&1; then
    info "Removendo a chain ${chain}..."
    while iptables -C DOCKER-USER -j "$chain" 2>/dev/null; do
      iptables -D DOCKER-USER -j "$chain"
    done
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
  fi

  if docker container inspect "$FULL_NAME" >/dev/null 2>&1; then
    info "Removendo o container ${FULL_NAME}..."
    # docker rm -f, NAO `exegol remove` -- mesmas duas razoes do
    # lib/03-container.sh (o remove() apaga o volume de workspace e PERGUNTA por
    # isso; o rich.prompt.Confirm levanta EOFError em EOF, e o -F nao desvia
    # desse prompt). Aqui era pior que no estagio 3: a chain e a unit da camada 2
    # JA foram removidas acima, entao sem TTY a remocao falhava, o `|| true`
    # engolia, e o estagio imprimia "Desinstalado." com o container AINDA DE PE e
    # sem kill switch nenhum -- o pior meio-estado possivel para esta ferramenta.
    #
    # Parada graciosa de 2s antes do rm -f: e' o que o `exegol remove` fazia
    # (stop(timeout=2)) e um container de pentest pode ter trabalho em voo.
    docker stop -t 2 "$FULL_NAME" >/dev/null 2>&1 || true
    if docker rm -f "$FULL_NAME" >/dev/null 2>&1 \
        && ! docker container inspect "$FULL_NAME" >/dev/null 2>&1; then
      ok "container ${FULL_NAME} removido (o /workspace, bind mount no host, ficou intacto)"
    else
      # Reporta e SEGUE: abandonar aqui deixaria o usuario no meio de uma
      # desinstalacao, com menos removido e sem a pergunta dos segredos. Mas o
      # sucesso silencioso e' o que nao pode acontecer -- dai o contador.
      erro "nao consegui remover o container ${FULL_NAME} -- rode a mao: docker rm -f ${FULL_NAME}"
      erro "ATENCAO: a chain ${chain} e a unit ${unit} JA foram removidas acima."
      erro "Enquanto esse container existir, ele esta SEM a camada 2 do kill switch."
      falhas=$((falhas + 1))
    fi
  fi

  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    info "Removendo a rede ${NETWORK_NAME}..."
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || \
      aviso "nao consegui remover a rede (algum container ainda usa?)"
  fi

  if (( falhas )); then
    erro "Desinstalacao INCOMPLETA: ${falhas} item(ns) falharam -- veja as mensagens acima."
  else
    ok "Desinstalado."
  fi

  # Segredos ficam para o fim, com pergunta propria: apagar a chave localmente
  # NAO libera o slot de dispositivo na conta Mullvad.
  printf '\n'
  aviso "A chave registrada continua ocupando um dos 5 slots da sua conta Mullvad"
  aviso "mesmo depois de apagada aqui. Remova em mullvad.net -> Devices se quiser o slot de volta."
  if confirmar "Apagar tambem /etc/wireguard/mullvad/ e /etc/exegol-mullvad/key.json?"; then
    rm -rf /etc/wireguard/mullvad /etc/exegol-mullvad
    ok "segredos locais apagados"
  else
    info "segredos locais mantidos"
  fi

  # O status do estagio reflete a desinstalacao, nao a resposta da pergunta dos
  # segredos: o rodar() precisa saber que algo ficou para tras.
  (( falhas == 0 ))
}

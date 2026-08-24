#!/usr/bin/env bash
# lib/04-killswitch.sh -- estagio 4: camada 2 no host.
# Migra a instalacao antiga, instala os scripts e a unica unit systemd.
# Nao executa nada ao ser sourceado.
set -euo pipefail

BACKSTOP_INSTALADO="/usr/local/sbin/exegol-killswitch-backstop.sh"

estagio_killswitch() {
  # || return $? nas duas primeiras: sem isso, a supressao de errexit dentro de
  # um estagio (ver ATENCAO em install.sh:rodar()) deixaria uma falha de
  # _migrar_instalacao_antiga, por exemplo, ser ignorada e o estagio seguiria
  # para _instalar_scripts_host mesmo assim. _instalar_unit e' a ultima chamada
  # do corpo, entao seu proprio status ja e' o retorno da funcao.
  _migrar_instalacao_antiga || return $?
  _instalar_scripts_host    || return $?
  _instalar_unit
}

# A versao antiga tinha tres scripts, DUAS units (uma delas um oneshot que
# falhava no boot) e um diretorio de protocolo request/response que deixou de
# existir. Nada disso e compativel peca por peca, entao removemos antes.
_migrar_instalacao_antiga() {
  local unit_velha_oneshot="exegol-${CONTAINER_NAME}-killswitch.service"
  local unit_velha_watcher="exegol-${CONTAINER_NAME}-switch-watcher.service"
  local achou=0

  local u
  for u in "$unit_velha_oneshot" "$unit_velha_watcher"; do
    if [[ -f "/etc/systemd/system/${u}" ]]; then
      achou=1
      info "Removendo a unit antiga ${u}..."
      systemctl disable --now "$u" 2>/dev/null || true
      rm -f "/etc/systemd/system/${u}"
    fi
  done

  local s
  for s in "/usr/local/sbin/exegol-${CONTAINER_NAME}-killswitch.sh" \
           "/usr/local/sbin/exegol-${CONTAINER_NAME}-switch-apply.sh" \
           "/usr/local/sbin/exegol-${CONTAINER_NAME}-switch-watch.sh"; do
    if [[ -f "$s" ]]; then
      achou=1
      info "Removendo o script antigo $(basename "$s")..."
      rm -f "$s"
    fi
  done

  # Diretorio do protocolo request/response, que a arquitetura nova nao usa.
  local dir_velho="${REAL_HOME}/.exegol/workspaces/${CONTAINER_NAME}/.mullvad-switch"
  if [[ -d "$dir_velho" ]]; then
    achou=1
    info "Removendo ${dir_velho} (protocolo request/response aposentado)..."
    rm -rf "$dir_velho"
  fi
  rm -f "/run/exegol-${CONTAINER_NAME}-killswitch.last-endpoint"

  # A chain e o gancho no DOCKER-USER NAO sao tocados aqui, de proposito.
  #
  # A versao antiga e a nova usam o MESMO nome de chain (EXEGOL-<NOME>-KS), entao
  # apagar a antiga aqui e recria-la depois no _instalar_unit abriria uma janela
  # de alguns segundos em que o DOCKER-USER nao tem gancho para kill switch
  # nenhum -- e essa janela cai justamente num re-run com o container de pe e o
  # tunel aberto (a opcao "so o kill switch" do menu). Nesse intervalo a camada 2
  # simplesmente nao existe, e ela existe exatamente para ser o backstop de
  # quando a camada 1 for adulterada de dentro do container.
  #
  # Deixar como esta e' estritamente mais seguro: a chain continua aplicando o
  # ultimo estado que tinha ate o watcher novo assumir, e o host-backstop.sh e'
  # idempotente (cria se nao existe, sempre da -F antes de repovoar, e so insere
  # o gancho se ainda nao houver). Um gancho duplicado de execucoes antigas e
  # inofensivo: o trafego do container sempre bate num DROP antes do RETURN final
  # da chain, entao um segundo jump so reprocessaria trafego alheio.
  #
  # E o nome nao divergir nao e' sorte: o script legado montava
  # EXEGOL-<NOME-INTEIRO>-KS sem truncar, e o nome_chain novo trunca em 18. Eles
  # divergem so quando o nome passa de 18 caracteres -- ponto em que o nome
  # legado passa de 28 e o iptables recusa a criacao. Uma chain legada com nome
  # divergente nunca pode ter existido.

  if (( achou )); then
    systemctl daemon-reload \
      || { erro "systemctl daemon-reload falhou apos remover a instalacao antiga"; return 1; }
    ok "Instalacao antiga removida"
  fi
}

_instalar_scripts_host() {
  install -m 755 -o root -g root \
    "${RAIZ_REPO}/payload/host-backstop.sh" "$BACKSTOP_INSTALADO" \
    || { erro "nao consegui instalar host-backstop.sh em ${BACKSTOP_INSTALADO}"; return 1; }
  install -m 755 -o root -g root \
    "${RAIZ_REPO}/payload/host-watcher.sh" \
    "/usr/local/sbin/exegol-${CONTAINER_NAME}-killswitch-watcher.sh" \
    || { erro "nao consegui instalar host-watcher.sh"; return 1; }
  ok "scripts do host instalados em /usr/local/sbin"
}

# UMA unit so, e ela e um servico continuo -- nao um oneshot.
#
# O oneshot da versao antiga estava preso a After=docker.service e falhava no
# boot: o container e iniciado a mao, muito depois do docker subir, e o endpoint
# ainda nao existia naquele momento. O watcher resolve isso por construcao:
# aplica o estado fechado no boot e reage ao container quando ele aparecer.
_instalar_unit() {
  local unit chain arq_estado
  unit="$(nome_unit "$CONTAINER_NAME")"
  chain="$(nome_chain "$CONTAINER_NAME")"
  arq_estado="$(caminho_state "$REAL_HOME" "$CONTAINER_NAME")"

  if ! cat > "/etc/systemd/system/${unit}" <<FIM
[Unit]
Description=Kill switch (camada 2) do ${FULL_NAME}: mantem a chain ${chain} em DOCKER-USER
Wants=docker.service
After=docker.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/exegol-${CONTAINER_NAME}-killswitch-watcher.sh ${chain} ${STATIC_IP} ${FULL_NAME} ${arq_estado} ${BACKSTOP_INSTALADO}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
FIM
  then
    erro "nao consegui escrever /etc/systemd/system/${unit}"
    return 1
  fi

  # "enable --now" NAO reinicia uma unit que ja esta ativa: em uma unit ja
  # rodando, o "start" implicito e um no-op, e daemon-reload por si so nao
  # reinicia nada. Pior: depois do daemon-reload, "systemctl show -p ExecStart"
  # ja mostra a linha NOVA enquanto o processo em execucao ainda esta com a
  # linha velha -- ou seja, a checagem obvia mentiria que deu certo. Esse
  # caso importa de verdade aqui: este estagio e reexecutavel (menu opcao 5,
  # "so o kill switch"), e uma reexecucao apos mudar --ip ou --name reescreve
  # o arquivo da unit mas, sem "restart" explicito, deixaria o watcher rodando
  # com o IP ou nome antigo -- a chain protegeria um endereco que o container
  # nem tem mais. Por isso: enable (sem --now) e depois restart, sempre.
  systemctl daemon-reload || { erro "systemctl daemon-reload falhou"; return 1; }
  systemctl enable "$unit" || { erro "nao consegui habilitar ${unit}"; return 1; }
  systemctl restart "$unit" || { erro "nao consegui reiniciar ${unit}"; return 1; }
  sleep 1
  if systemctl is-active --quiet "$unit"; then
    ok "${unit}: ativo e habilitado no boot"
  else
    erro "A unit ${unit} nao subiu. Veja: journalctl -u ${unit} -n 30"
    return 1
  fi
  info "Estado atual da chain ${chain}:"
  iptables -L "$chain" -n -v 2>/dev/null || aviso "chain ainda nao criada"
}

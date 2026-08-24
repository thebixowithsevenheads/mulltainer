#!/usr/bin/env bash
# lib/05-verify.sh -- estagio 5: verificacao e teste de vazamento real.
#
# A verificacao da versao antiga so confirmava que a VPN estava de pe, o que nao
# testa kill switch nenhum. Aqui o tunel e derrubado de proposito para provar que
# nada sai sem ele.
set -euo pipefail

FALHAS_VERIFY=0
FALHAS_VAZAMENTO=0

_passa() { printf '  %s[PASSA]%s %s\n' "$VERDE" "$RESET" "$1"; }
_falha() { printf '  %s[FALHA]%s %s\n' "$VERMELHO" "$RESET" "$1"; FALHAS_VERIFY=$((FALHAS_VERIFY + 1)); }
# So para os itens de vazamento (IPv6, camada 1, camada 2 ausente/furada) --
# separado de _falha para que o alerta final ("o kill switch NAO esta
# protegendo") so dispare quando o problema for de vazamento de verdade, e
# nao, por exemplo, um DNS mal configurado.
_falha_vazamento() { _falha "$1"; FALHAS_VAZAMENTO=$((FALHAS_VAZAMENTO + 1)); }

_no_container() { docker exec "$FULL_NAME" "$@"; }

# Extrai o campo "ip" de um corpo am.i.mullvad.net/json. Vazio se o corpo nao
# for JSON valido -- inclusive o '{}' de fallback dos curls que falharam. O
# || true e o guard do achado de pipefail deste projeto: sem ele, um python3
# que estoura ao decodificar aborta o estagio inteiro em vez de so deixar o
# IP vazio, o que faz o item que depende disto reportar FALHA normalmente.
_mullvad_ip() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("ip", ""))
except Exception:
    print("")
' 2>/dev/null || true
}

# Handler do trap que cobre a janela deliberadamente aberta do item 7 (ver
# comentario ali). Chamado por INT, TERM ou EXIT enquanto o trap estiver
# armado -- um Ctrl-C, um terminal fechado ou um kill nessa janela nao pode
# deixar o container sem camada 1 por tempo indeterminado.
#
# Desarma o proprio trap como PRIMEIRA acao: e o que garante que ele nao
# dispare uma segunda vez, seja porque foi chamado por INT/TERM e o script
# segue rodando (o EXIT ainda estaria armado), seja por reentrancia se o
# proprio bash tentar disparar de novo. No caminho feliz (sem interrupcao),
# quem desarma e' o proprio estagio_verify(), logo depois do wg-quick up (ou
# da reaplicacao manual no ramo de falha) -- por isso este handler tambem
# precisa ser seguro de chamar quando a camada 1 ja esta bem: o
# killswitch-postup.sh e' idempotente (e' o mesmo script que o PostUp do
# wg-quick roda toda vez que o tunel sobe).
#
# So usa if/else (nunca um `||` cru): e' o que impede uma falha aqui de
# derrubar o proprio handler de trap, um contexto onde set -e se comporta de
# forma menos previsivel.
_restaurar_camada1_de_emergencia() {
  trap - INT TERM EXIT
  aviso "Interrompido com a camada 1 desligada de proposito (item 7) -- reaplicando agora..."
  if _no_container /opt/my-resources/bin/killswitch-postup.sh >/dev/null 2>&1; then
    ok "camada 1 reaplicada."
  else
    erro "nao consegui reaplicar a camada 1 automaticamente."
    erro "rode a mao: docker exec ${FULL_NAME} /opt/my-resources/bin/killswitch-postup.sh"
  fi
}

estagio_verify() {
  FALHAS_VERIFY=0
  FALHAS_VAZAMENTO=0
  local chain
  chain="$(nome_chain "$CONTAINER_NAME")"

  docker container inspect "$FULL_NAME" --format '{{.State.Running}}' 2>/dev/null \
    | grep -qx true || morrer "o container ${FULL_NAME} nao esta rodando"

  printf '\n%sVerificacao%s\n\n' "$NEGRITO" "$RESET"

  # Uma leitura so da saida do container e do host, usada pelos itens 1 e 2.
  # O curl AQUI e o que gera o trafego que o item 1 (handshake) precisa ver:
  # medido nesta maquina, o handshake do WireGuard fica em 0 na subida do
  # wg-quick e continua em 0 mesmo depois de 8s ocioso -- so muda depois de
  # trafego real. Por isso o curl vem antes da leitura do handshake, nunca
  # depois; a ordem de exibicao dos itens (1, depois 2) nao muda.
  local json host_json cont_ip host_ip
  json="$(_no_container curl -s --max-time 20 https://am.i.mullvad.net/json || echo '{}')"
  host_json="$(curl -s --max-time 20 https://am.i.mullvad.net/json || echo '{}')"
  cont_ip="$(_mullvad_ip "$json")"
  host_ip="$(_mullvad_ip "$host_json")"

  # 1) handshake
  if _no_container wg show wg0 latest-handshakes 2>/dev/null | awk '{exit !($2 > 0)}'; then
    _passa "handshake do wg0 estabelecido"
  else
    _falha "sem handshake no wg0"
  fi

  # 2) saindo pela Mullvad, com tunel proprio -- nao carona no do host
  #
  # "mullvad_exit_ip":true sozinho e falso positivo: medido nesta maquina, um
  # container com o wg0 fora e o iptables bem aberto ainda reporta true,
  # porque o trafego sai pelo host e o host mesmo esta na Mullvad. Por isso
  # comparamos o IP de saida do container com o do host: IPs iguais significa
  # que o container nao tem tunel proprio, so esta pegando carona no do host.
  if printf '%s' "$json" | grep -q '"mullvad_exit_ip":true' \
      && [[ -n "$cont_ip" ]] && [[ "$cont_ip" != "$host_ip" ]]; then
    _passa "saindo pela Mullvad: $(printf '%s' "$json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s (%s, %s)" % (d.get("ip"), d.get("city"), d.get("country")))' 2>/dev/null || true)"
  elif [[ -n "$cont_ip" && -n "$host_ip" && "$cont_ip" == "$host_ip" ]]; then
    _falha "IP de saida do container e IGUAL ao do host (${cont_ip}) -- sem tunel proprio, so carona no do host"
  else
    _falha "nao esta saindo pela Mullvad"
  fi

  # 3) DNS
  if _no_container grep -q '10.64.0.1' /etc/resolv.conf; then
    _passa "resolv.conf aponta para o DNS da Mullvad (10.64.0.1)"
  else
    _falha "resolv.conf nao aponta para 10.64.0.1"
  fi

  # 4) IPv6 bloqueado
  if _no_container curl -6 -s --max-time 5 https://ifconfig.co >/dev/null 2>&1; then
    _falha_vazamento "IPv6 saiu -- deveria estar bloqueado pelo ip6tables"
  else
    _passa "IPv6 bloqueado"
  fi

  # 5) o watcher da camada 2 esta VIVO.
  #
  # Os itens 7 e 8 provam que a chain descarta trafego -- e isso e' verdade com
  # ou sem processo de watcher no ar. Um watcher morto congela a chain no ultimo
  # estado que ela teve, e esse estado pode ser `aberto <endpoint velho>`: a
  # brecha UDP fica pendurada num IP que nada mais confirma. Sem este item, o
  # estagio imprimia "o kill switch esta protegendo nas duas camadas" com a
  # parte viva da camada 2 morta. E' item de VAZAMENTO, nao cosmetico.
  #
  # O install.sh:mostrar_estado ja fazia essa checagem no painel de estado; a
  # verificacao e' que nao fazia.
  local unit
  unit="$(nome_unit "$CONTAINER_NAME")"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    _passa "watcher da camada 2 ativo (${unit})"
  else
    _falha_vazamento "WATCHER MORTO: ${unit} nao esta ativo -- a chain congela no ultimo estado, que pode ser aberto para um endpoint que ja nao vale"
  fi

  printf '\n%sTeste de vazamento -- derrubando o tunel de proposito%s\n\n' \
    "$NEGRITO" "$RESET"

  local pacotes_antes pacotes_depois

  _no_container wg-quick down wg0 >/dev/null 2>&1 || true

  # 6) camada 1: nada sai de dentro do container
  if _no_container curl -s --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
    _falha_vazamento "CAMADA 1 FUROU: o container acessou a internet com o tunel fora"
  else
    _passa "camada 1: sem tunel, nada sai do container"
  fi

  # 7) camada 2: prova ativa, nao so presenca.
  #
  # A camada 1 (item 6) sozinha ja bloqueia o curl dentro do container -- nenhum
  # pacote chega a sair do container para o backstop do host descartar, e o
  # contador DROP nao teria motivo pra subir. As duas camadas nao podem ser
  # provadas pela mesma sonda: aqui simulamos exatamente o que a camada 2
  # existe para cobrir -- a camada 1 comprometida por um root DENTRO do
  # container -- e exigimos que o contador SUBA, nao so que a chain exista
  # (uma chain orfa, presente mas nao ancorada em DOCKER-USER, tambem daria
  # "0 -> 0" e pareceria sucesso sem descartar nada).
  #
  # O sleep 2 da tempo do watcher (tick de 1s) convergir para o estado fechado
  # depois que o PreDown do wg-quick down (item 6) removeu o state.json.
  sleep 2
  if ! iptables -C DOCKER-USER -j "$chain" 2>/dev/null; then
    _falha_vazamento "CAMADA 2 AUSENTE: a chain ${chain} nao esta ancorada no DOCKER-USER"
  else
    pacotes_antes="$(_contador_drop "$chain")"
    # A partir daqui a camada 1 esta desligada de proposito. Um Ctrl-C, um
    # terminal fechado ou um kill aqui deixaria o container sem ela por tempo
    # indeterminado -- a camada 2 cobre (o DROP dela bate no IP do container
    # nos dois estados), mas nao e' motivo para deixar assim.
    trap _restaurar_camada1_de_emergencia INT TERM EXIT
    _no_container iptables -P OUTPUT ACCEPT 2>/dev/null || true
    _no_container iptables -F OUTPUT 2>/dev/null || true
    _no_container curl -s --max-time 5 https://1.1.1.1 >/dev/null 2>&1 || true
    pacotes_depois="$(_contador_drop "$chain")"
    if [[ -n "$pacotes_antes" && -n "$pacotes_depois" ]] \
        && (( pacotes_depois > pacotes_antes )); then
      _passa "camada 2: descartou o trafego com a camada 1 desativada (${pacotes_antes} -> ${pacotes_depois})"
    else
      _falha_vazamento "CAMADA 2 FUROU: com a camada 1 desativada, o backstop do host nao descartou nada (${pacotes_antes:-?} -> ${pacotes_depois:-?})"
    fi
  fi

  info "Restaurando o tunel..."
  if _no_container wg-quick up wg0 >/dev/null 2>&1; then
    # Camada 1 reaplicada via PostUp do proprio wg-quick: a janela do item 7
    # fechou. Desarma o trap ANTES do sleep -- e' o que garante que ele nao
    # dispara de novo no caminho feliz quando o processo eventualmente sair
    # (o EXIT ficaria armado ate ali se nao desarmassemos aqui).
    trap - INT TERM EXIT
    sleep 3
    json="$(_no_container curl -s --max-time 20 https://am.i.mullvad.net/json || echo '{}')"
    cont_ip="$(_mullvad_ip "$json")"
    # 8) o mesmo criterio honesto do item 2: mullvad_exit_ip:true nao basta.
    if printf '%s' "$json" | grep -q '"mullvad_exit_ip":true' \
        && [[ -n "$cont_ip" ]] && [[ "$cont_ip" != "$host_ip" ]]; then
      _passa "tunel restaurado e saindo pela Mullvad"
    else
      _falha "o tunel voltou mas nao esta saindo pela Mullvad com IP proprio"
    fi
  else
    # O item 7 apagou de proposito as regras de camada 1 do container (para
    # provar a camada 2) e contava com este wg-quick up para reaplica-las via
    # PostUp. Se o tunel nao sobe, o container ficaria SEM camada 1 nenhuma
    # depois de uma "verificacao" -- por isso a reaplicacao manual aqui, na
    # mao, antes so registrar a falha de restauracao.
    aviso "Reaplicando a camada 1 na mao, ja que o tunel nao subiu..."
    _no_container /opt/my-resources/bin/killswitch-postup.sh >/dev/null 2>&1 \
      || _falha "nao consegui reaplicar a camada 1 -- o container esta protegido apenas pela camada 2"
    # Desarma aqui tambem: a reaplicacao manual acima (com sucesso ou nao) ja
    # e' a mesma acao que o trap faria, entao a janela do item 7 esta encerrada
    # de um jeito ou de outro. Seguro chamar mesmo se o trap nunca foi armado
    # (chain do item 7 ausente): `trap -` sem trap ativo e' um no-op.
    trap - INT TERM EXIT
    _falha "nao consegui restaurar o tunel -- rode: docker exec ${FULL_NAME} wg-quick up wg0"
  fi

  printf '\n'
  if (( FALHAS_VERIFY == 0 )); then
    ok "Tudo passou. O kill switch esta protegendo nas duas camadas."
    return 0
  fi
  erro "${FALHAS_VERIFY} verificacao(oes) falharam."
  if (( FALHAS_VAZAMENTO > 0 )); then
    erro "Falha nos itens de vazamento (camada 1 ou 2) significa que o kill switch NAO esta protegendo."
  fi
  return 1
}

# Soma os pacotes das regras DROP da chain. Vazio se a chain nao existe.
# O || true importa: com pipefail, iptables falhando numa chain inexistente
# mataria o estagio em vez de reportar FALHA no item da camada 2.
_contador_drop() {
  iptables -L "$1" -n -v -x 2>/dev/null \
    | awk '/DROP/ {soma += $1} END {if (NR > 0) print soma + 0}' || true
}

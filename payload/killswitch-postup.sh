#!/bin/bash
# Camada 1 do kill switch. Roda DENTRO do container, chamado pelo PostUp do
# wg-quick. Le o Endpoint do wg0.conf dinamicamente, entao serve pra qualquer
# relay sem precisar editar este arquivo quando o servidor trocar.
#
# As politicas DROP nao sao removidas quando o wg0 cai -- e isso que faz a queda
# do tunel ser fail-closed aqui dentro.
#
# KS_DRY_RUN=1 imprime o payload dos *-restore e os comandos de policy em vez de
# executar. E o que torna a camada 1 -- o arquivo mais critico do repo -- testavel
# sem root e sem container, do mesmo jeito que o host-backstop.sh: nao remova.
# Em dry-run o /etc/resolv.conf tambem nao e' tocado; o state.json continua sendo
# escrito, dentro de KS_DIR_ESTADO.
set -euo pipefail

DRY="${KS_DRY_RUN:-0}"
# Em dry-run, qual dos dois restores deve "falhar" (v4, v6 ou vazio). E o que
# exercita o fallback fechar_tudo, que de outro jeito nao teria cobertura
# nenhuma -- e ele e' exatamente o caminho em que um erro de sintaxe no payload
# deixaria a tabela INALTERADA, ou seja ACCEPT, na primeira subida.
DRY_FALHA="${KS_DRY_FALHA:-}"

# Sobrescreviveis so para teste; em producao ficam nos caminhos reais.
CONF="${KS_CONF:-/etc/wireguard/wg0.conf}"
DIR_ESTADO="${KS_DIR_ESTADO:-/workspace/.mullvad}"
ARQ_ESTADO="${DIR_ESTADO}/state.json"

# Uma policy (best-effort: o || true garante que a ausencia de ip6tables nao
# impeca o travamento do v4).
_policy() {
  local cmd="$1"; shift
  if [[ "$DRY" == "1" ]]; then
    printf '%s %s\n' "$cmd" "$*"
    return 0
  fi
  "$cmd" "$@" 2>/dev/null || true
}

# Um *-restore, com o payload no stdin. Devolve o status do comando real, ou o
# que o KS_DRY_FALHA pedir em dry-run.
_restore() {
  local cmd="$1" familia="$2"
  if [[ "$DRY" == "1" ]]; then
    printf -- '--- inicio %s\n' "$cmd"
    cat
    printf -- '--- fim %s\n' "$cmd"
    [[ "$DRY_FALHA" == "$familia" ]] && return 1
    return 0
  fi
  "$cmd"
}

# So a PRIMEIRA linha Endpoint conta -- um wg0.conf com mais de uma faria o
# host vir de uma linha e a porta de outra.
EP="$(awk -F'=' '/^Endpoint/{gsub(/ /, "", $2); print $2; exit}' "$CONF")"
if [[ -z "$EP" ]]; then
  echo "killswitch-postup: nao consegui ler o Endpoint de ${CONF}" >&2
  exit 1
fi
case "$EP" in
  \[*)
    echo "killswitch-postup: Endpoint IPv6 com colchetes nao suportado: ${EP}" >&2
    exit 1
    ;;
esac
EP_HOST="${EP%%:*}"
EP_PORT="${EP##*:}"
if [[ -z "$EP_HOST" || -z "$EP_PORT" ]] || ! [[ "$EP_PORT" =~ ^[0-9]+$ ]] \
    || (( 10#$EP_PORT < 1 || 10#$EP_PORT > 65535 )); then
  echo "killswitch-postup: Endpoint malformado (esperado host:porta): ${EP}" >&2
  exit 1
fi

# Fecha v4 E v6 e sai. Usado quando QUALQUER restore falha: travar so um dos
# protocolos deixa o outro aberto, e o Exegol forca IPv6 habilitado no container,
# entao um fallback so-v4 vazaria por v6. Best-effort em cada policy (|| true)
# para que a ausencia de ip6tables nao impeca o travamento do v4.
fechar_tudo() {
  echo "killswitch-postup: $1 -- fechando v4 e v6 na forca bruta" >&2
  local cmd politica
  for cmd in iptables ip6tables; do
    for politica in INPUT OUTPUT FORWARD; do
      _policy "$cmd" -P "$politica" DROP
    done
  done
  exit 1
}

# O DROP do 127.0.0.11 vem ANTES do ACCEPT do lo, e a ordem e' o ponto todo:
# em iptables a primeira regra que casa ganha, e o ACCEPT do lo cobriria o
# 127.0.0.11 se viesse primeiro.
#
# 127.0.0.11 e' o DNS embutido do docker numa rede definida pelo usuario -- e' o
# que o /etc/resolv.conf do container aponta antes deste script rodar. As
# consultas para ele NAO ficam no container: o dockerd as encaminha a partir do
# HOST, para os resolvers do host. E o DOCKER-USER (camada 2) so e' alcancado
# pelo FORWARD, entao ele estruturalmente nao ve pacote enderecado ao proprio
# host -- nenhuma das duas camadas veria essas consultas.
#
# O QUE ESTE DROP FECHA, exatamente: o caso com a camada 1 APLICADA. Nele todo
# o resto de OUTPUT ja esta fechado, mas o `-A OUTPUT -o lo -j ACCEPT` casava
# tambem o 127.0.0.11 -- entao qualquer coisa que consultasse esse endereco
# (a resolv.conf original do docker, uma ferramenta com resolver proprio,
# qualquer processo que releia o arquivo) escapava por ali, pelo link real do
# host, com o tunel de pe ou fora. Esse buraco agora esta fechado.
#
# O QUE ESTE DROP **NAO** FECHA: a janela em que a camada 1 esta AUSENTE. Nessa
# janela este DROP tambem esta ausente -- ele E' a camada 1. E a janela e' real
# no fluxo que o README documenta: `exegol start mullvad` e depois
# `mullvad-switch`, que resolve api.mullvad.net por 127.0.0.11 antes de existir
# tunel nenhum; o dockerd encaminha essa consulta a partir do host, invisivel
# para a camada 2. Fechar isso exige a camada 2 aplicar a camada 1 na transicao
# "container subiu" -- follow-up conhecido, deliberadamente fora do escopo aqui.
#
# --- IPv4: tabela inteira de uma vez via iptables-restore. Sem essa troca
# atomica existiria uma janela entre um "-F" e o "-P ... DROP" seguinte onde a
# policy ainda e a padrao do Docker (ACCEPT) e nenhuma regra esta no lugar --
# qualquer pacote emitido nessa janela sairia sem passar por regra nenhuma.
# iptables-restore sem --noflush troca a tabela inteira numa unica transacao:
# sem flush em separado, sem janela, um processo em vez de uma duzia.
if ! _restore iptables-restore v4 <<FIM
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -s 127.0.0.11 -j DROP
-A OUTPUT -d 127.0.0.11 -j DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -i wg0 -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -o wg0 -j ACCEPT
-A OUTPUT -p udp -d ${EP_HOST} --dport ${EP_PORT} -j ACCEPT
COMMIT
FIM
then
  # Se o restore falha (sintaxe ruim, endpoint ruim), a tabela fica INALTERADA
  # -- na primeira subida isso e ACCEPT. Por isso o fallback forca DROP direto
  # nas 3 policies antes de sair, em vez de confiar que o restore deixou algo
  # seguro.
  fechar_tudo "iptables-restore falhou"
fi

# --- IPv6 ---
# O Exegol forca net.ipv6.conf.all.disable_ipv6=0 (ContainerConfig.py:773),
# entao IPv6 fica HABILITADO no container. Bloquear v6 e responsabilidade daqui.
# Mesma logica atomica do IPv4: nada de wg0/udp aqui, v6 fica totalmente fechado.
if ! _restore ip6tables-restore v6 <<FIM
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
COMMIT
FIM
then
  fechar_tudo "ip6tables-restore falhou"
fi

if [[ "$DRY" == "1" ]]; then
  printf 'resolv.conf <- nameserver 10.64.0.1\n'
else
  echo "nameserver 10.64.0.1" > /etc/resolv.conf
fi

# --- state.json: o canal para o host ---
# Bind mount, lido como arquivo LOCAL pelo watcher -- e por isso que o host nao
# precisa de docker exec no loop. NAO contem chave nenhuma.
# Gerado com json.dump (python3) em vez de heredoc com interpolacao: um
# MULLVAD_ENTRADA/MULLVAD_SAIDA com aspas ou barra invertida quebraria o JSON
# se fosse so texto colado num heredoc. Escrito em tmp + mv para ser atomico:
# o watcher nunca le um arquivo parcial.
mkdir -p "$DIR_ESTADO"
EP_HOST="$EP_HOST" EP_PORT="$EP_PORT" \
MULLVAD_ENTRADA="${MULLVAD_ENTRADA:-}" MULLVAD_SAIDA="${MULLVAD_SAIDA:-}" \
MULLVAD_MODO="${MULLVAD_MODO:-desconhecido}" \
python3 - "${ARQ_ESTADO}.tmp" <<'PYEOF'
import json
import os
import sys
import time

destino = sys.argv[1]
estado = {
    "endpoint_ip": os.environ["EP_HOST"],
    "endpoint_port": int(os.environ["EP_PORT"]),
    "entry_hostname": os.environ.get("MULLVAD_ENTRADA", ""),
    "exit_hostname": os.environ.get("MULLVAD_SAIDA", ""),
    "mode": os.environ.get("MULLVAD_MODO", "desconhecido"),
    "ts": int(time.time()),
}
with open(destino, "w") as f:
    json.dump(estado, f, indent=2)
    f.write("\n")
PYEOF
mv "${ARQ_ESTADO}.tmp" "$ARQ_ESTADO"
chmod 644 "$ARQ_ESTADO"

#!/usr/bin/env bash
# Camada 2, parte viva: mantem o backstop sincronizado com o tunel do container.
#
# Le o state.json como ARQUIVO LOCAL (o /workspace do container e bind mount),
# e por isso NAO precisa de docker exec no loop -- diferente da versao antiga,
# que spawnava um processo dentro do container a cada segundo.
#
# O docker inspect e necessario por DOIS motivos:
#
#   1. Running: um container que morre sem rodar o PreDown deixa o state.json
#      para tras, e sem checar Running o watcher manteria a brecha UDP aberta
#      para um IP fixo que outro container poderia reusar sem tunel.
#
#   2. StartedAt: nada neste repo roda `wg-quick down` quando o container para,
#      entao o state.json sobrevive a um `exegol stop`, a um `docker kill`, a um
#      crash e a um reboot. Sem comparar o `ts` do state.json com o inicio ATUAL
#      do container, todo `exegol start` depois da primeira instalacao veria
#      "Running + endpoint" e iria direto para `aberto <ip velho> <porta velha>`
#      -- com a netns do container recem-criada e o iptables dela em ACCEPT,
#      porque a camada 1 so volta quando alguem roda wg-quick up. A janela que a
#      camada 2 existe para cobrir ficava, justamente ali, descoberta.
#
# Qualquer duvida ou falha -> fechado. Isso inclui nao conseguir provar que o
# state.json e' do boot ATUAL do container: numa reinicializacao o watcher nao
# "comeca fechado" e depois abre -- ele aplica direto o estado real de agora, e
# um state.json de um boot anterior nao conta como tunel de pe.
set -uo pipefail

CHAIN="${1:?falta a chain}"
IP_CONTAINER="${2:?falta o IP do container}"
CONTAINER="${3:?falta o nome do container}"
ARQ_ESTADO="${4:?falta o caminho do state.json}"
BACKSTOP="${5:-/usr/local/sbin/exegol-killswitch-backstop.sh}"
INTERVALO="${KS_INTERVALO:-1}"

aplicar() { "$BACKSTOP" "$CHAIN" "$IP_CONTAINER" "$@"; }

container_rodando() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]]
}

# Instante em que o container comecou a rodar, como o docker reporta: RFC3339
# com nanossegundos (ex.: 2026-08-23T21:40:00.123456789Z). Vazio se o inspect
# falhar -- e vazio faz o ler_endpoint FECHAR, nao abrir.
container_iniciado_em() {
  docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || true
}

# Ecoa "ip porta" se o state.json tem endpoint utilizavel E e' do boot atual do
# container; nada caso contrario. Nada -> o laco aplica "fechado".
#
# O `ts` do state.json e' epoch em segundos INTEIROS (int(time.time()) no
# killswitch-postup.sh) e o StartedAt tem nanossegundos, entao a comparacao usa
# o PISO do StartedAt: um PostUp que rodasse no mesmo segundo do start do
# container gravaria um ts truncado para baixo e seria descartado como velho
# por engano.
#
# Falha ao ler o ts, ao ler o StartedAt ou ao parsear qualquer um dos dois =>
# nao imprime nada => fechado. Fail closed, sempre.
ler_endpoint() {
  [[ -r "$ARQ_ESTADO" ]] || return 0
  ARQ="$ARQ_ESTADO" INICIADO="$(container_iniciado_em)" python3 <<'FIMPY' 2>/dev/null || true
import datetime, json, math, os, re


def instante(texto):
    """RFC3339 do docker -> epoch em segundos (float). Levanta ValueError."""
    m = re.match(
        r"^(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?\s*"
        r"(Z|z|[+-]\d{2}:?\d{2})?$",
        (texto or "").strip(),
    )
    if not m:
        raise ValueError("timestamp irreconhecivel: %r" % texto)
    data, hora, frac, off = m.groups()
    # fromisoformat aceita no maximo 6 digitos de fracao e, antes do 3.11, nao
    # aceita "Z" -- por isso a normalizacao aqui, em vez do texto cru.
    frac = (frac or "0")[:6].ljust(6, "0")
    if off in (None, "Z", "z"):
        off = "+00:00"
    elif len(off) == 5:
        off = off[:3] + ":" + off[3:]
    return datetime.datetime.fromisoformat(
        "%sT%s.%s%s" % (data, hora, frac, off)
    ).timestamp()


try:
    d = json.load(open(os.environ["ARQ"]))
except Exception:
    raise SystemExit(0)
ip, porta, ts = d.get("endpoint_ip"), d.get("endpoint_port"), d.get("ts")
if not (ip and porta):
    raise SystemExit(0)
try:
    ts = int(ts)
    inicio = math.floor(instante(os.environ.get("INICIADO", "")))
except Exception:
    # ts ausente/ilegivel, ou StartedAt ausente/ilegivel: nao da para provar
    # frescor, entao nao existe endpoint utilizavel. Fail closed.
    raise SystemExit(0)
if ts < inicio:
    # state.json de um boot anterior do container: a netns de agora e' nova e a
    # camada 1 ainda nao rodou nela.
    raise SystemExit(0)
print("%s %s" % (ip, porta))
FIMPY
}

# Reafirmar de tempo em tempo, nao so quando o estado desejado muda. Motivo: o
# docker reescreve o DOCKER-USER em eventos de rede (um `systemctl restart
# docker` o recria com so a regra default), e um `iptables -F DOCKER-USER` manual
# tem o mesmo efeito. Se isso acontecer enquanto o estado desejado NAO muda, o
# watcher nunca perceberia: `ultimo` continuaria afirmando que ha protecao
# enquanto o DOCKER-USER ja nao manda mais nada para a nossa chain.
REAFIRMAR_A_CADA="${KS_REAFIRMAR_A_CADA:-30}"

ultimo=""
ticks=0

while true; do
  desejado="fechado"
  if container_rodando; then
    ep="$(ler_endpoint)"
    [[ -n "$ep" ]] && desejado="aberto ${ep}"
  fi

  # Reaplica se o estado mudou OU se passou o intervalo de reafirmacao. O
  # ultimo="" inicial garante que a primeira volta sempre aplica -- e se essa
  # primeira aplicacao falhar (DOCKER-USER ainda nao pronto no boot), ultimo
  # continua vazio e a proxima volta tenta de novo, em vez de engolir o erro.
  if [[ "$desejado" != "$ultimo" ]] || (( ticks >= REAFIRMAR_A_CADA )); then
    ticks=0
    # shellcheck disable=SC2086
    if aplicar $desejado; then
      ultimo="$desejado"
    else
      # Falhou ao aplicar -> fecha. Nunca deixar a chain aberta por erro.
      aplicar fechado || true
      ultimo=""
    fi
  fi

  ticks=$((ticks + 1))
  sleep "$INTERVALO"
done

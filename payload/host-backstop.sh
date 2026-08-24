#!/usr/bin/env bash
# Camada 2 do kill switch: chain propria pendurada em DOCKER-USER, no host.
#
# Dois estados:
#   fechado  DROP de e para o IP do container. E o estado inicial e o de
#            qualquer falha -- nada sai sem tunel confirmado.
#   aberto   RETURN so pro UDP container->endpoint e pro retorno
#            ESTABLISHED,RELATED. DROP em todo o resto.
#
# Uso: host-backstop.sh <chain> <ip_container> fechado
#      host-backstop.sh <chain> <ip_container> aberto <endpoint_ip> <porta>
#
# KS_DRY_RUN=1 imprime os comandos em vez de executar. E o que torna esta logica
# testavel sem root -- nao remova.
set -euo pipefail

DRY="${KS_DRY_RUN:-0}"

ipt() {
  if [[ "$DRY" == "1" ]]; then
    printf 'iptables %s\n' "$*"
    # -C (checar se a regra existe) precisa "falhar" em dry-run tambem, ou o
    # teste nunca exercita o ramo "-I" -- e a logica de idempotencia (o que
    # evita pendurar a chain duas vezes) ficaria sem cobertura nenhuma.
    [[ "${1:-}" == "-C" ]] && return 1
    return 0
  fi
  iptables "$@"
}

CHAIN="${1:?falta o nome da chain}"
IP_CONTAINER="${2:?falta o IP do container}"
ESTADO="${3:?falta o estado: fechado|aberto}"

case "$ESTADO" in
  fechado) ;;
  aberto)
    EP_IP="${4:?estado aberto exige o IP do endpoint}"
    EP_PORTA="${5:?estado aberto exige a porta do endpoint}"
    ;;
  *) echo "estado invalido: ${ESTADO} (use fechado ou aberto)" >&2; exit 2 ;;
esac

# Cria se nao existe, e sempre limpa: a chain e reconstruida do zero a cada
# aplicacao, entao trocas de relay nao acumulam brechas antigas.
#
# JANELA DELIBERADA, NAO CORRIGIDA: entre este -F e o primeiro -A la embaixo,
# a chain fica momentaneamente vazia enquanto ja esta pendurada em
# DOCKER-USER (se esta e a segunda aplicacao em diante). Isso NAO e
# exploravel neste design especifico:
#   - A camada 1 (dentro do container) so deixa sair lo, wg0 e UDP pro
#     endpoint -- e dessas, so o UDP alcanca a bridge pra valer. O estado
#     aberto da camada 2 permite exatamente essa mesma tupla, entao o unico
#     trafego que o container CONSEGUE emitir durante a janela e trafego que
#     a camada 2 deixaria passar de qualquer forma.
#   - As transicoes so acontecem com a camada 1 em vigor: fechado->aberto
#     exige endpoint valido em state.json, que so existe depois do PostUp;
#     aberto->fechado acontece com o container parado (sem trafego nenhum)
#     ou com o state.json removido pelo PreDown, e as policies DROP da
#     camada 1 deliberadamente sobrevivem a interface (nao sao desfeitas).
# Um -F/-A atomico (iptables-restore --noflush, ou RETURN->ACCEPT com uma
# regra de piso permanente em DOCKER-USER) fecharia a janela, mas o primeiro
# depende de semantica que nao consigo verificar sem root, e o segundo e uma
# mudanca semantica com risco real de introduzir algo pior sem verificacao.
# Por isso, deixado como esta.
if [[ "$DRY" == "1" ]]; then
  ipt -N "$CHAIN"
else
  iptables -N "$CHAIN" 2>/dev/null || true
fi
ipt -F "$CHAIN"

# ORDEM IMPORTA: em iptables a primeira regra que casa ganha. Os RETURN da
# brecha precisam vir antes dos DROP, ou nada passa.
if [[ "$ESTADO" == "aberto" ]]; then
  ipt -A "$CHAIN" -s "$IP_CONTAINER" -d "$EP_IP" -p udp --dport "$EP_PORTA" -j RETURN
  ipt -A "$CHAIN" -d "$IP_CONTAINER" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
fi

ipt -A "$CHAIN" -s "$IP_CONTAINER" -j DROP
ipt -A "$CHAIN" -d "$IP_CONTAINER" -j DROP
ipt -A "$CHAIN" -j RETURN

# Pendura na posicao 1 do DOCKER-USER, antes de qualquer regra do docker.
# Mesmo caminho em dry-run e real: -C decide se o -I roda, em ambos os modos.
ipt -C DOCKER-USER -j "$CHAIN" 2>/dev/null || ipt -I DOCKER-USER 1 -j "$CHAIN"

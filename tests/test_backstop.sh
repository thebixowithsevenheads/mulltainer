# Arquivos de teste sao sourcados pelo runner; nao definem 'set' por si mesmo.
#
# Camada 2 do kill switch: host-backstop.sh (aplica um estado por chamada) e
# host-watcher.sh (mantem o estado sincronizado com o tunel). O ponto critico
# e a ORDEM das regras -- RETURN tem que vir antes de DROP -- e o watcher tem
# que voltar a fechar quando o state.json desaparece.

BACKSTOP="$RAIZ/payload/host-backstop.sh"

# --- estado fechado ---
saida_fechado="$(KS_DRY_RUN=1 bash "$BACKSTOP" TESTE-KS 172.30.30.10 fechado 2>&1)"

afirmar_contem "iptables -N TESTE-KS" "$saida_fechado" "fechado: cria a chain"
afirmar_contem "iptables -F TESTE-KS" "$saida_fechado" "fechado: limpa a chain"
afirmar_contem "iptables -A TESTE-KS -s 172.30.30.10 -j DROP" "$saida_fechado" \
  "fechado: DROP do container pra fora"
afirmar_contem "iptables -A TESTE-KS -d 172.30.30.10 -j DROP" "$saida_fechado" \
  "fechado: DROP de fora pro container"
afirmar_contem "iptables -I DOCKER-USER 1 -j TESTE-KS" "$saida_fechado" \
  "fechado: pendura na posicao 1 do DOCKER-USER"

# O dry-run tem que exercitar o MESMO caminho que o real: primeiro -C (checa
# se ja esta pendurado), so depois -I (pendura) se o -C nao achou. Sem isso
# em dry-run, a logica de idempotencia nunca e testada -- um -C invertido, ou
# que ignorasse a posicao, passaria batido.
linha_check="$(grep -n 'iptables -C DOCKER-USER -j TESTE-KS' <<< "$saida_fechado" | cut -d: -f1)"
linha_insert="$(grep -n 'iptables -I DOCKER-USER 1 -j TESTE-KS' <<< "$saida_fechado" | cut -d: -f1)"
if [[ -n "$linha_check" && -n "$linha_insert" && "$linha_check" -lt "$linha_insert" ]]; then
  afirmar_igual ok ok "fechado: -C DOCKER-USER vem antes do -I (dry-run exercita a idempotencia)"
else
  afirmar_igual "check(${linha_check}) < insert(${linha_insert})" "falso" \
    "fechado: -C DOCKER-USER vem antes do -I (dry-run exercita a idempotencia)"
fi

# O estado fechado NAO pode abrir brecha nenhuma.
afirmar_igual "0" "$(grep -c 'dport' <<< "$saida_fechado")" "fechado: nenhuma brecha UDP"
afirmar_igual "0" "$(grep -c 'ESTABLISHED' <<< "$saida_fechado")" "fechado: nenhum retorno liberado"

# --- estado aberto ---
saida_aberto="$(KS_DRY_RUN=1 bash "$BACKSTOP" TESTE-KS 172.30.30.10 aberto 1.2.3.4 3494 2>&1)"

afirmar_contem "-s 172.30.30.10 -d 1.2.3.4 -p udp --dport 3494 -j RETURN" "$saida_aberto" \
  "aberto: brecha UDP so pro endpoint atual"
afirmar_contem "-d 172.30.30.10 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" \
  "$saida_aberto" "aberto: retorno ESTABLISHED liberado"
afirmar_contem "iptables -A TESTE-KS -s 172.30.30.10 -j DROP" "$saida_aberto" \
  "aberto: DROP no resto continua"

# A ordem e o que faz o kill switch funcionar: RETURN antes de DROP.
linha_return="$(grep -n 'dport 3494' <<< "$saida_aberto" | cut -d: -f1)"
linha_drop="$(grep -n -- '-s 172.30.30.10 -j DROP' <<< "$saida_aberto" | cut -d: -f1)"
if [[ -n "$linha_return" && -n "$linha_drop" && "$linha_return" -lt "$linha_drop" ]]; then
  afirmar_igual ok ok "aberto: RETURN vem ANTES do DROP"
else
  afirmar_igual "return(${linha_return}) < drop(${linha_drop})" "falso" \
    "aberto: RETURN vem ANTES do DROP"
fi

# So um endpoint pode estar liberado por vez.
afirmar_igual "1" "$(grep -c 'dport' <<< "$saida_aberto")" "aberto: exatamente uma brecha"

# --- validacao de argumentos ---
KS_DRY_RUN=1 bash "$BACKSTOP" TESTE-KS 172.30.30.10 xpto >/dev/null 2>&1
afirmar_igual 2 "$?" "estado invalido sai com 2"

KS_DRY_RUN=1 bash "$BACKSTOP" TESTE-KS 172.30.30.10 aberto >/dev/null 2>&1
afirmar_igual 1 "$?" "aberto sem endpoint falha"

KS_DRY_RUN=1 bash "$BACKSTOP" >/dev/null 2>&1
afirmar_igual 1 "$?" "sem argumentos falha"

# --- watcher: maquina de estados completa, com backstop e docker de mentira ---
#
# Isso e o que discrimina um watcher que fecha de novo quando o tunel cai de
# um que fica aberto para sempre -- o bug que a camada 2 existe para evitar.
WATCHER="$RAIZ/payload/host-watcher.sh"

TMPW="$(mktemp -d)"
trap 'rm -rf "$TMPW"' RETURN
mkdir -p "$TMPW/.mullvad" "$TMPW/bin"

printf '#!/usr/bin/env bash\necho "$*" >> "%s/chamadas.log"\n' "$TMPW" > "$TMPW/backstop-falso.sh"

# docker de mentira que RESPONDE AO FORMATO PEDIDO. Precisa distinguir
# .State.Running de .State.StartedAt: um fake que devolvesse a mesma coisa para
# os dois tornaria o StartedAt sempre impossivel de parsear e, com o
# fail-closed, todos os casos de "abre" abaixo passariam por acidente.
cat > "$TMPW/bin/docker" <<FALSO
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *State.Running*)   cat "$TMPW/running";    exit 0 ;;
    *State.StartedAt*) cat "$TMPW/started_at"; exit 0 ;;
  esac
done
exit 1
FALSO
chmod +x "$TMPW/backstop-falso.sh" "$TMPW/bin/docker"

PATH_ANTES="$PATH"
export PATH="$TMPW/bin:$PATH"

# O `ts` do state.json e' epoch inteiro; o StartedAt do docker e' RFC3339 com
# nanossegundos. O watcher compara os dois, entao as fixtures tem que ser
# coerentes: container iniciado 60s atras, state.json escrito agora.
_iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123456789Z; }
AGORA="$(date +%s)"
_iso_utc $((AGORA - 60)) > "$TMPW/started_at"

_estado_fresco() {
  printf '{"endpoint_ip":"1.2.3.4","endpoint_port":3494,"mode":"multihop","ts":%s}' \
    "${1:-$AGORA}" > "$TMPW/.mullvad/state.json"
}

# Caso 1: container ausente do inicio ao fim -> fechado, e SEM repetir a cada
# tick (o watcher nao tem por que reaplicar "fechado" repetidamente quando o
# estado nao muda e o intervalo de reafirmacao ainda nao venceu).
echo false > "$TMPW/running"
rm -f "$TMPW/.mullvad/state.json"
: > "$TMPW/chamadas.log"
KS_INTERVALO=0.2 timeout 1 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
esperado_c1="TESTE-KS 172.30.30.10 fechado"
obtido_c1="$(cat "$TMPW/chamadas.log")"
afirmar_igual "$esperado_c1" "$obtido_c1" \
  "watcher: container ausente -> fechado, aplicado uma vez so"

# Caso 2: comeca fechado porque o tunel ainda nao subiu (nem container, nem
# state.json existem quando o watcher arranca -- o cenario real de boot), e
# so abre quando o endpoint aparece. A transicao e forcada em background
# DEPOIS que o watcher ja esta rodando, pra nao mascarar o estado inicial real.
echo false > "$TMPW/running"
rm -f "$TMPW/.mullvad/state.json"
: > "$TMPW/chamadas.log"
(
  sleep 0.4
  echo true > "$TMPW/running"
  _estado_fresco
) &
KS_INTERVALO=0.2 timeout 1.2 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
wait
esperado_c2="$(printf 'TESTE-KS 172.30.30.10 fechado\nTESTE-KS 172.30.30.10 aberto 1.2.3.4 3494')"
obtido_c2="$(cat "$TMPW/chamadas.log")"
afirmar_igual "$esperado_c2" "$obtido_c2" \
  "watcher: container rodando com state.json valido -> abre no endpoint certo"

# Caso 3: o tunel sobe e depois cai no meio (o PreDown apaga o state.json) ->
# volta a fechar. Esta e a transicao que mais importa: um watcher que abre e
# nunca fecha de volta e exatamente o bug que a camada 2 existe para impedir.
echo false > "$TMPW/running"
rm -f "$TMPW/.mullvad/state.json"
: > "$TMPW/chamadas.log"
(
  sleep 0.4
  echo true > "$TMPW/running"
  _estado_fresco
  sleep 0.6
  rm -f "$TMPW/.mullvad/state.json"
) &
KS_INTERVALO=0.2 timeout 1.8 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
wait
esperado_c3="$(printf 'TESTE-KS 172.30.30.10 fechado\nTESTE-KS 172.30.30.10 aberto 1.2.3.4 3494\nTESTE-KS 172.30.30.10 fechado')"
obtido_c3="$(cat "$TMPW/chamadas.log")"
afirmar_igual "$esperado_c3" "$obtido_c3" \
  "watcher: tunel cai (state.json some) -> volta a fechar"

# --- watcher: o guard container_rodando ISOLADO -------------------------------
#
# Os casos 1-3 movem "running" e state.json JUNTOS, entao nenhum deles
# discrimina o guard: trocar `if container_rodando` por `if true` passava nos
# tres. Aqui o state.json e' valido E fresco e so o Running e' false -- o unico
# jeito de aplicar "fechado" e' consultando o Running. E o comentario do proprio
# guard explica por que isso importa: com o container fora, manter a brecha UDP
# aberta para um IP fixo deixa outro container reusar esse IP sem tunel.
echo false > "$TMPW/running"
_estado_fresco
: > "$TMPW/chamadas.log"
KS_INTERVALO=0.2 timeout 1 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
afirmar_igual "TESTE-KS 172.30.30.10 fechado" "$(cat "$TMPW/chamadas.log")" \
  "watcher: container parado COM state.json valido e fresco -> fechado"

# --- watcher: frescor do state.json contra o inicio do container --------------
#
# Nada neste repo roda `wg-quick down` quando o container para, entao o
# state.json sobrevive a um exegol stop / docker kill / crash / reboot. Sem o
# check de frescor, todo `exegol start` seguinte via "Running + endpoint" e
# abria a brecha UDP para o endpoint velho -- com a netns nova do container em
# ACCEPT, porque a camada 1 so volta com um wg-quick up.
echo true > "$TMPW/running"
_estado_fresco $((AGORA - 3600))   # state.json de um boot anterior
: > "$TMPW/chamadas.log"
KS_INTERVALO=0.2 timeout 1 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
afirmar_igual "TESTE-KS 172.30.30.10 fechado" "$(cat "$TMPW/chamadas.log")" \
  "watcher: state.json mais velho que o start do container -> fechado"

# ts no mesmo segundo do start: o ts e' int(time.time()) e o StartedAt tem
# nanossegundos, entao o piso do StartedAt tem que ser usado -- senao um PostUp
# que rodasse no mesmo segundo do start seria descartado como velho por engano.
echo true > "$TMPW/running"
_estado_fresco $((AGORA - 60))
: > "$TMPW/chamadas.log"
KS_INTERVALO=0.2 timeout 1 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
afirmar_igual "TESTE-KS 172.30.30.10 aberto 1.2.3.4 3494" "$(cat "$TMPW/chamadas.log")" \
  "watcher: ts no mesmo segundo do start (fracao ignorada) -> abre"

# StartedAt ilegivel -> nao da para provar frescor -> FECHA (nunca abre).
echo true > "$TMPW/running"
_estado_fresco
printf 'lixo-que-nao-e-timestamp\n' > "$TMPW/started_at"
: > "$TMPW/chamadas.log"
KS_INTERVALO=0.2 timeout 1 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
afirmar_igual "TESTE-KS 172.30.30.10 fechado" "$(cat "$TMPW/chamadas.log")" \
  "watcher: StartedAt ilegivel -> fecha (fail closed), nao abre"

# StartedAt vazio (inspect falhou) -> mesma coisa.
: > "$TMPW/started_at"
: > "$TMPW/chamadas.log"
KS_INTERVALO=0.2 timeout 1 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
afirmar_igual "TESTE-KS 172.30.30.10 fechado" "$(cat "$TMPW/chamadas.log")" \
  "watcher: StartedAt vazio -> fecha (fail closed)"

_iso_utc $((AGORA - 60)) > "$TMPW/started_at"

# state.json sem o campo ts (versao antiga do killswitch-postup) -> FECHA.
echo true > "$TMPW/running"
printf '{"endpoint_ip":"1.2.3.4","endpoint_port":3494,"mode":"multihop"}' \
  > "$TMPW/.mullvad/state.json"
: > "$TMPW/chamadas.log"
KS_INTERVALO=0.2 timeout 1 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
afirmar_igual "TESTE-KS 172.30.30.10 fechado" "$(cat "$TMPW/chamadas.log")" \
  "watcher: state.json sem ts -> fecha (fail closed)"

# --- watcher: reafirma periodicamente mesmo sem troca de estado ---
#
# O docker pode recriar DOCKER-USER (systemctl restart docker, ou um
# iptables -F manual) sem que o estado DESEJADO mude. Sem reafirmacao
# periodica o watcher nunca percebe -- "ultimo" continua dizendo que ha
# protecao mesmo que o DOCKER-USER ja nao aponte mais pra nossa chain.
# KS_REAFIRMAR_A_CADA baixo (2 ticks) pra nao depender de um teste longo.
echo true > "$TMPW/running"
_estado_fresco
: > "$TMPW/chamadas.log"
KS_REAFIRMAR_A_CADA=2 KS_INTERVALO=0.2 timeout 1.6 bash "$WATCHER" \
  TESTE-KS 172.30.30.10 x "$TMPW/.mullvad/state.json" "$TMPW/backstop-falso.sh"
qtd_aberto="$(grep -c 'aberto 1.2.3.4 3494' "$TMPW/chamadas.log")"
if (( qtd_aberto > 1 )); then
  afirmar_igual ok ok \
    "watcher: reafirma periodicamente mesmo com estado desejado constante"
else
  afirmar_igual ">1 aplicacoes de aberto" "${qtd_aberto} aplicacoes" \
    "watcher: reafirma periodicamente mesmo com estado desejado constante"
fi

export PATH="$PATH_ANTES"

# --- contrato ExecStart <-> argv do watcher -----------------------------------
#
# A unit systemd (lib/04-killswitch.sh) e os parametros posicionais do
# host-watcher.sh sao um contrato entre dois arquivos que nada mais checa: uma
# troca de ordem de um lado so faria a camada 2 proteger o IP errado, ou
# procurar o state.json no lugar errado, sem erro nenhum de sintaxe.
args_unit="$(sed -n 's/.*killswitch-watcher\.sh \(.*\)$/\1/p' "$RAIZ/lib/04-killswitch.sh")"
afirmar_igual '${chain} ${STATIC_IP} ${FULL_NAME} ${arq_estado} ${BACKSTOP_INSTALADO}' \
  "$args_unit" "contrato: a ordem dos argumentos no ExecStart da unit"

args_watcher="$(sed -n 's/^\([A-Z_]*\)="\${\([0-9]\)[:?].*/\2 \1/p' "$RAIZ/payload/host-watcher.sh")"
afirmar_igual "$(printf '1 CHAIN\n2 IP_CONTAINER\n3 CONTAINER\n4 ARQ_ESTADO\n5 BACKSTOP')" \
  "$args_watcher" "contrato: a ordem dos posicionais que o watcher le"

# --- a verificacao tem que provar que o watcher esta VIVO ---------------------
#
# O estagio 5 provava que a chain descarta trafego, o que e' verdade com ou sem
# processo de watcher no ar -- e um watcher morto congela a chain no ultimo
# estado, inclusive `aberto <endpoint velho>`. E' item de vazamento, entao tem
# que usar _falha_vazamento (o que dispara o alerta final), nao _falha.
_bloco_watcher="$(awk '/# 5\) o watcher da camada 2/,/^  fi$/' "$RAIZ/lib/05-verify.sh")"
afirmar_contem 'systemctl is-active --quiet "$unit"' "$_bloco_watcher" \
  "verify: o item do watcher checa a unit com systemctl is-active"
afirmar_contem '_falha_vazamento "WATCHER MORTO' "$_bloco_watcher" \
  "verify: watcher morto conta como VAZAMENTO, nao como falha cosmetica"
afirmar_contem 'unit="$(nome_unit "$CONTAINER_NAME")"' "$_bloco_watcher" \
  "verify: o nome da unit vem do nome_unit, nao hardcoded"
unset _bloco_watcher

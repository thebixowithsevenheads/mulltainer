# Arquivos de teste sao sourcados pelo runner; nao definem 'set' por si mesmo.
#
# CAMADA 1 -- killswitch-postup.sh, o arquivo mais critico do repo. Ele roda
# dentro do container, chamado pelo PostUp do wg-quick, e e' o que impede o
# trafego de sair fora do tunel.
#
# Cobertura verificada por mutacao: antes destes testes, trocar
# ":OUTPUT DROP [0:0]" por ":OUTPUT ACCEPT [0:0]" -- isto e', APAGAR a camada 1
# -- deixava as duas suites 100% verdes.
#
# KS_DRY_RUN=1 imprime os payloads dos *-restore delimitados por
# "--- inicio <cmd>" / "--- fim <cmd>"; KS_DRY_FALHA=v4|v6 forca o restore
# daquela familia a falhar, exercitando o fallback fechar_tudo.

POSTUP="$RAIZ/payload/killswitch-postup.sh"

TMP1="$(mktemp -d)"
trap 'rm -rf "$TMP1"' RETURN
mkdir -p "$TMP1/estado"

# Escreve um wg0.conf de mentira e ecoa o caminho.
_conf_com() {
  local ep="$1" arq="$TMP1/wg0.conf"
  {
    printf '[Interface]\nPrivateKey = PRIVDEMENTIRA=\nAddress = 10.1.2.3/32\n'
    printf 'DNS = 10.64.0.1\n\n[Peer]\nPublicKey = PUBDEMENTIRA=\n'
    printf 'AllowedIPs = 0.0.0.0/0,::/0\n'
    [[ -n "$ep" ]] && printf 'Endpoint = %s\n' "$ep"
  } > "$arq"
  printf '%s\n' "$arq"
}

_rodar() {  # $1 = conf ; resto = env extra
  local conf="$1"; shift
  env KS_DRY_RUN=1 KS_CONF="$conf" KS_DIR_ESTADO="$TMP1/estado" "$@" \
    bash "$POSTUP" 2>&1
}

# Extrai um dos dois payloads (o miolo entre os delimitadores).
_secao() {
  awk -v ini="--- inicio $2" -v fim="--- fim $2" \
    '$0==ini {f=1; next} $0==fim {f=0} f' <<< "$1"
}

CONF_OK="$(_conf_com '1.2.3.4:3494')"
saida="$(_rodar "$CONF_OK")"
v4="$(_secao "$saida" iptables-restore)"
v6="$(_secao "$saida" ip6tables-restore)"

# --- as tres politicas sao DROP nas DUAS familias -----------------------------
# Isto e' a camada 1. Se qualquer uma virar ACCEPT, nao existe kill switch
# nenhum dentro do container.
for _p in INPUT OUTPUT FORWARD; do
  afirmar_contem ":${_p} DROP [0:0]" "$v4" "camada1 v4: policy ${_p} e' DROP"
  afirmar_contem ":${_p} DROP [0:0]" "$v6" "camada1 v6: policy ${_p} e' DROP"
done
afirmar_igual 0 "$(grep -c 'ACCEPT \[0:0\]' <<< "$v4" || true)" \
  "camada1 v4: nenhuma policy em ACCEPT"
afirmar_igual 0 "$(grep -c 'ACCEPT \[0:0\]' <<< "$v6" || true)" \
  "camada1 v6: nenhuma policy em ACCEPT"

# --- os ACCEPT do v4 sao EXATAMENTE lo, wg0 e a tupla UDP do endpoint ---------
afirmar_igual 6 "$(grep -c -- '-j ACCEPT' <<< "$v4" || true)" \
  "camada1 v4: exatamente 6 regras ACCEPT, nem uma a mais"
afirmar_contem '-A INPUT -i lo -j ACCEPT'   "$v4" "camada1 v4: ACCEPT de entrada no lo"
afirmar_contem '-A INPUT -i wg0 -j ACCEPT'  "$v4" "camada1 v4: ACCEPT de entrada no wg0"
afirmar_contem '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "$v4" \
  "camada1 v4: ACCEPT do retorno estabelecido"
afirmar_contem '-A OUTPUT -o lo -j ACCEPT'  "$v4" "camada1 v4: ACCEPT de saida no lo"
afirmar_contem '-A OUTPUT -o wg0 -j ACCEPT' "$v4" "camada1 v4: ACCEPT de saida no wg0"
afirmar_contem '-A OUTPUT -p udp -d 1.2.3.4 --dport 3494 -j ACCEPT' "$v4" \
  "camada1 v4: ACCEPT so da tupla UDP do endpoint atual"
# UMA brecha UDP so: um conf com dois Endpoint nao pode virar duas brechas.
afirmar_igual 1 "$(grep -c -- '--dport' <<< "$v4" || true)" \
  "camada1 v4: exatamente uma brecha UDP"
# Nenhum ACCEPT largo por interface fisica nem por endereco solto: tirando as
# seis linhas conhecidas, nao pode sobrar ACCEPT nenhum.
_v4_restante="$(grep -e ' lo ' -e ' wg0 ' -e 'conntrack' -e '\-\-dport' -v <<< "$v4" || true)"
afirmar_igual 0 "$(grep -c 'ACCEPT' <<< "$_v4_restante" || true)" \
  "camada1 v4: nenhum ACCEPT fora de lo/wg0/conntrack/UDP do endpoint"

# --- DNS embutido do docker (127.0.0.11) fechado ANTES do ACCEPT do lo --------
#
# O DOCKER-USER (camada 2) so e' alcancado pelo FORWARD, entao nao ve pacote
# enderecado ao proprio host; e o 127.0.0.11 e' resolvido pelo dockerd, que
# encaminha as consultas A PARTIR DO HOST. Numa janela sem camada 1, os nomes
# dos alvos sairiam pelo link real, invisiveis para as duas camadas.
afirmar_contem '-A OUTPUT -d 127.0.0.11 -j DROP' "$v4" \
  "camada1 v4: DROP das consultas ao DNS embutido do docker"
afirmar_contem '-A INPUT -s 127.0.0.11 -j DROP' "$v4" \
  "camada1 v4: DROP das respostas do DNS embutido do docker"

# A ORDEM e' o ponto todo: a primeira regra que casa ganha, e o ACCEPT do lo
# cobriria o 127.0.0.11 se viesse antes.
_l_drop_dns="$(grep -n -- '-A OUTPUT -d 127.0.0.11 -j DROP' <<< "$v4" | cut -d: -f1)"
_l_lo_out="$(grep -n -- '-A OUTPUT -o lo -j ACCEPT' <<< "$v4" | cut -d: -f1)"
if [[ -n "$_l_drop_dns" && -n "$_l_lo_out" && "$_l_drop_dns" -lt "$_l_lo_out" ]]; then
  afirmar_igual ok ok "camada1 v4: o DROP do 127.0.0.11 vem ANTES do ACCEPT do lo"
else
  afirmar_igual "dns(${_l_drop_dns}) < lo(${_l_lo_out})" "falso" \
    "camada1 v4: o DROP do 127.0.0.11 vem ANTES do ACCEPT do lo"
fi
_l_drop_in="$(grep -n -- '-A INPUT -s 127.0.0.11 -j DROP' <<< "$v4" | cut -d: -f1)"
_l_lo_in="$(grep -n -- '-A INPUT -i lo -j ACCEPT' <<< "$v4" | cut -d: -f1)"
if [[ -n "$_l_drop_in" && -n "$_l_lo_in" && "$_l_drop_in" -lt "$_l_lo_in" ]]; then
  afirmar_igual ok ok "camada1 v4: o DROP de entrada do 127.0.0.11 vem ANTES do ACCEPT do lo"
else
  afirmar_igual "dns(${_l_drop_in}) < lo(${_l_lo_in})" "falso" \
    "camada1 v4: o DROP de entrada do 127.0.0.11 vem ANTES do ACCEPT do lo"
fi

# --- o v6 admite SO loopback --------------------------------------------------
# O Exegol forca net.ipv6.conf.all.disable_ipv6=0 (ContainerConfig.py:773),
# entao o v6 fica HABILITADO e bloquea-lo e' responsabilidade daqui.
afirmar_igual 2 "$(grep -c -- '-j ACCEPT' <<< "$v6" || true)" \
  "camada1 v6: exatamente 2 regras ACCEPT"
afirmar_contem '-A INPUT -i lo -j ACCEPT'  "$v6" "camada1 v6: ACCEPT de entrada no lo"
afirmar_contem '-A OUTPUT -o lo -j ACCEPT' "$v6" "camada1 v6: ACCEPT de saida no lo"
afirmar_igual 0 "$(grep -c 'wg0' <<< "$v6" || true)" \
  "camada1 v6: nada de wg0 -- o tunel e' v4"
afirmar_igual 0 "$(grep -c -- '--dport' <<< "$v6" || true)" \
  "camada1 v6: nenhuma brecha UDP"
afirmar_igual 0 "$(grep -c 'conntrack' <<< "$v6" || true)" \
  "camada1 v6: nenhum retorno estabelecido liberado"

# --- state.json: o canal para a camada 2 --------------------------------------
_estado="$(cat "$TMP1/estado/state.json")"
afirmar_contem '"endpoint_ip": "1.2.3.4"' "$_estado" "camada1: state.json traz o IP do endpoint"
afirmar_contem '"endpoint_port": 3494'    "$_estado" "camada1: state.json traz a porta do endpoint"
# O ts e' o que o watcher usa para saber se o state.json e' do boot atual.
_ts="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ts"))' \
  "$TMP1/estado/state.json")"
if [[ "$_ts" =~ ^[0-9]{10,}$ ]]; then
  afirmar_igual ok ok "camada1: state.json traz ts em epoch (o watcher compara com o StartedAt)"
else
  afirmar_igual "epoch inteiro" "$_ts" \
    "camada1: state.json traz ts em epoch (o watcher compara com o StartedAt)"
fi
afirmar_igual 0 "$(grep -c 'PRIVDEMENTIRA' <<< "$_estado" || true)" \
  "camada1: state.json nao contem chave nenhuma"

# --- fallback fechar_tudo: fecha as DUAS familias -----------------------------
# Se o restore falha a tabela fica INALTERADA -- na primeira subida isso e'
# ACCEPT. Por isso o fallback tem que forcar DROP nas 3 policies das 2
# familias: travar so uma deixaria a outra escancarada, e o v6 esta habilitado.
for _fam in v4 v6; do
  saida_falha="$(_rodar "$CONF_OK" "KS_DRY_FALHA=$_fam")"
  st_falha=$?
  afirmar_igual 1 "$st_falha" "camada1 fallback (${_fam}): sai com status 1"
  afirmar_contem "fechando v4 e v6 na forca bruta" "$saida_falha" \
    "camada1 fallback (${_fam}): avisa no stderr"
  for _p in INPUT OUTPUT FORWARD; do
    afirmar_contem "iptables -P ${_p} DROP" "$saida_falha" \
      "camada1 fallback (${_fam}): iptables -P ${_p} DROP"
    afirmar_contem "ip6tables -P ${_p} DROP" "$saida_falha" \
      "camada1 fallback (${_fam}): ip6tables -P ${_p} DROP"
  done
done

# --- parse do Endpoint e validacao da porta -----------------------------------
# Ramos puros; a unica coisa que faltava era teste.
saida_sem_ep="$(_rodar "$(_conf_com '')")"; st=$?
afirmar_igual 1 "$st" "camada1: conf sem Endpoint sai com 1"
afirmar_contem "nao consegui ler o Endpoint" "$saida_sem_ep" \
  "camada1: conf sem Endpoint diz o que faltou"

saida_v6ep="$(_rodar "$(_conf_com '[2606:1234::1]:51820')")"; st=$?
afirmar_igual 1 "$st" "camada1: Endpoint IPv6 entre colchetes sai com 1"
afirmar_contem "IPv6 com colchetes nao suportado" "$saida_v6ep" \
  "camada1: Endpoint IPv6 entre colchetes e' recusado explicitamente"

# Exigir a MENSAGEM, nao so o status: sem a validacao explicita, uma porta nao
# numerica ainda faz o script sair 1 -- mas la embaixo, no int() do state.json,
# depois de o payload com "--dport abc" ja ter sido entregue ao iptables-restore.
# Um teste que olhasse so o status passaria com a validacao apagada.
for _ep in '1.2.3.4:0' '1.2.3.4:65536' '1.2.3.4:99999' '1.2.3.4:abc' '1.2.3.4:' \
           '1.2.3.4'; do
  saida_ruim="$(_rodar "$(_conf_com "$_ep")" 2>&1)"
  st=$?
  if (( st == 1 )) && grep -q 'Endpoint malformado' <<< "$saida_ruim"; then
    afirmar_igual ok ok "camada1: Endpoint malformado recusado na validacao (${_ep})"
  else
    afirmar_igual "status 1 + 'Endpoint malformado'" \
      "status ${st} / $(head -1 <<< "$saida_ruim")" \
      "camada1: Endpoint malformado recusado na validacao (${_ep})"
  fi
done

# Limites validos passam.
for _ep in '1.2.3.4:1' '1.2.3.4:65535' '1.2.3.4:51820'; do
  saida_ok="$(_rodar "$(_conf_com "$_ep")")"
  st=$?
  porta="${_ep##*:}"
  if (( st == 0 )) && grep -q -- "--dport ${porta} -j ACCEPT" <<< "$saida_ok"; then
    afirmar_igual ok ok "camada1: porta valida aceita (${_ep})"
  else
    afirmar_igual "status 0 e --dport ${porta}" "status ${st}" \
      "camada1: porta valida aceita (${_ep})"
  fi
done

# Somente a PRIMEIRA linha Endpoint conta: com duas, o host nao pode vir de uma
# e a porta de outra.
{
  printf '[Interface]\nPrivateKey = P=\nAddress = 10.1.2.3/32\n\n[Peer]\n'
  printf 'PublicKey = K=\nEndpoint = 1.2.3.4:3494\nEndpoint = 9.9.9.9:51820\n'
} > "$TMP1/dois.conf"
saida_dois="$(_rodar "$TMP1/dois.conf")"
afirmar_contem '-d 1.2.3.4 --dport 3494 -j ACCEPT' "$saida_dois" \
  "camada1: com dois Endpoint, vale o primeiro (host e porta do mesmo)"
afirmar_igual 0 "$(grep -c '9.9.9.9' <<< "$saida_dois" || true)" \
  "camada1: com dois Endpoint, o segundo e' ignorado"

unset _p _fam _ep _ts _estado _v4_restante _l_drop_dns _l_lo_out _l_drop_in _l_lo_in saida v4 v6 saida_falha st_falha st \
      saida_sem_ep saida_v6ep saida_ok saida_ruim saida_dois porta CONF_OK

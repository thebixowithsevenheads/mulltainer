#!/usr/bin/env bash
# lib/02-mullvad.sh -- estagio 2: obter e normalizar o .conf da Mullvad.
# Duas rotas: automatica (numero da conta) e manual (.conf que o usuario ja tem).
# Nao executa nada ao ser sourceado.
set -euo pipefail

# Sobrescreviveis por ambiente para que a normalizacao e a adocao de conf sejam
# testaveis sem root, apontando para um diretorio temporario. Em producao ficam
# nos caminhos padrao, root 600.
DIR_CONF="${DIR_CONF:-/etc/wireguard/mullvad}"
DIR_ESTADO="${DIR_ESTADO:-/etc/exegol-mullvad}"
ARQ_CHAVE="${ARQ_CHAVE:-${DIR_ESTADO}/key.json}"

estagio_mullvad() {
  if [[ $EUID -eq 0 ]]; then
    install -d -m 700 -o root -g root "$DIR_CONF" "$DIR_ESTADO" \
      || { erro "nao consegui criar ${DIR_CONF} ou ${DIR_ESTADO}"; return 1; }
  else
    install -d -m 700 "$DIR_CONF" "$DIR_ESTADO" \
      || { erro "nao consegui criar ${DIR_CONF} ou ${DIR_ESTADO}"; return 1; }
  fi

  # --conf explicito pula a escolha
  if [[ -n "${CONF_INFORMADO:-}" ]]; then
    [[ -f "$CONF_INFORMADO" ]] || morrer "arquivo nao encontrado: ${CONF_INFORMADO}"
    # || return $? obrigatorio: sem ele, uma falha do _adotar_conf seria
    # mascarada pelo "return 0" da linha seguinte (supressao de errexit, ver
    # ATENCAO em install.sh:rodar()).
    _adotar_conf "$CONF_INFORMADO" || return $?
    return 0
  fi

  if [[ "${ASSUME_SIM:-0}" == "1" ]]; then
    morrer "--yes exige --conf PATH: a rota automatica precisa do numero da conta, que nao tem padrao"
  fi

  printf '\n%sConfig da Mullvad%s\n\n' "$NEGRITO" "$RESET"
  printf '  1) Ja tenho um .conf\n'
  printf '  2) Gerar pelo numero da conta\n'
  printf '  0) Voltar\n\n'
  local escolha=""
  read -r -p "$(printf '%s[?]%s escolha> ' "$AMARELO" "$RESET")" escolha
  case "$escolha" in
    1) _rota_manual ;;
    2) _rota_automatica ;;
    0) return 3 ;;
    *) erro "opcao invalida"; return 3 ;;
  esac
}

# --- rota manual -----------------------------------------------------------

_rota_manual() {
  local candidatos=() arq
  while IFS= read -r arq; do candidatos+=("$arq"); done < <(
    find "$DIR_CONF" /etc/wireguard "${REAL_HOME}/Downloads" "$REAL_HOME" \
      -maxdepth 1 -name '*.conf' -type f 2>/dev/null | sort -u
  )

  if (( ${#candidatos[@]} == 0 )); then
    _instrucoes_download
    return 3
  fi

  printf '\n%s.conf encontrados%s\n\n' "$NEGRITO" "$RESET"
  local i=1 rotulo
  for arq in "${candidatos[@]}"; do
    rotulo="$(_identificar_conf "$arq")"
    printf '  %d) %s\n     %s%s%s\n' "$i" "$arq" "$CINZA" "$rotulo" "$RESET"
    i=$((i + 1))
  done
  printf '  %d) informar outro caminho\n' "$i"
  printf '  0) voltar\n\n'

  local escolha=""
  read -r -p "$(printf '%s[?]%s escolha> ' "$AMARELO" "$RESET")" escolha
  if [[ "$escolha" == "0" ]]; then return 3; fi
  if [[ "$escolha" == "$i" ]]; then
    read -r -p "caminho do .conf: " arq
    [[ -f "$arq" ]] || { erro "arquivo nao encontrado: ${arq}"; return 3; }
    # || return $?: mesmo motivo do estagio_mullvad -- sem isso o "return 0"
    # abaixo mascara uma falha do _adotar_conf.
    _adotar_conf "$arq" || return $?
    return 0
  fi
  if [[ "$escolha" =~ ^[0-9]+$ ]] && (( escolha >= 1 && escolha < i )); then
    _adotar_conf "${candidatos[$((escolha - 1))]}" || return $?
    return 0
  fi
  erro "opcao invalida"
  return 3
}

# Descreve um .conf batendo a chave publica do peer contra a lista de relays.
_identificar_conf() {
  local arq="$1"
  RAIZ="$RAIZ_REPO" python3 - "$arq" <<'PY' 2>/dev/null || printf 'nao consegui identificar o relay\n'
import os, re, sys
sys.path.insert(0, os.path.join(os.environ["RAIZ"], "payload"))
import mullvad_api as api
texto = open(sys.argv[1]).read()
m = re.search(r"(?m)^PublicKey\s*=\s*(\S+)", texto)
if not m:
    print("sem PublicKey -- nao parece um .conf de WireGuard")
    raise SystemExit(0)
relays = api.buscar_relays()
r = api.achar_por_pubkey(relays, m.group(1))
if r:
    print("%s -- %s, %s" % (r["hostname"], r["cidade"], r["pais"]))
else:
    print("relay nao esta na lista publica atual (pode ter sido descontinuado)")
PY
}

_instrucoes_download() {
  cat <<'FIM'

  Nao achei nenhum .conf. Para baixar um:

    1. Entre em https://mullvad.net/ com o numero da conta
    2. WireGuard configuration -> escolha um servidor -> plataforma Linux
    3. Baixe o .conf e salve em ~/Downloads/

  Depois rode este estagio de novo. Ou escolha a rota automatica, que gera o
  .conf sozinho a partir do numero da conta.

FIM
}

# --- rota automatica -------------------------------------------------------

_rota_automatica() {
  local conta=""
  read -r -s -p "$(printf '%s[?]%s numero da conta Mullvad (16 digitos): ' "$AMARELO" "$RESET")" conta
  printf '\n'
  conta_valida "$conta" || { erro "numero invalido: esperava 16 digitos"; return 3; }
  info "Conta $(mascarar_conta "$conta"): consultando..."

  # MULLVAD_CONTA no AMBIENTE, nunca em argv: /proc/<pid>/cmdline e'
  # -r--r--r-- (world-readable) e /proc/<pid>/environ e' -r-------- -- medido
  # neste host, sem hidepid. O numero da conta e' a unica credencial da conta
  # Mullvad; em argv ele fica visivel para qualquer usuario local e para
  # qualquer `ps` numa gravacao de tela. Mesmo motivo do _salvar_chave.
  local validade
  validade="$(MULLVAD_CONTA="$conta" python3 "${RAIZ_REPO}/payload/mullvad_api.py" conta-env \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expiry_iso","?"))')" \
    || { erro "a Mullvad nao reconheceu essa conta"; return 3; }
  ok "Conta valida. Expira em: ${validade}"

  local privkey pubkey endereco chave_utilizavel="" chave_desta_conta=0
  if [[ -f "$ARQ_CHAVE" ]] && _chave_e_desta_conta "$conta"; then
    chave_desta_conta=1
    chave_utilizavel="$(_ler_chave_salva)"
  fi

  if [[ -n "$chave_utilizavel" ]]; then
    info "Reaproveitando a chave ja registrada -- nao queima outro slot da conta."
    IFS=$'\t' read -r privkey endereco <<< "$chave_utilizavel"
  else
    if (( chave_desta_conta )); then
      aviso "Achei uma chave desta conta em ${ARQ_CHAVE}, mas ela esta incompleta ou ilegivel."
      aviso "Registrar uma nova vai consumir outro dos 5 slots da conta -- a antiga continua ocupando o dela."
      aviso "Ela so e liberada removendo o dispositivo em mullvad.net -> Devices; apagar o key.json local nao libera o slot."
    else
      aviso "Vou registrar uma chave nova. A Mullvad permite 5 por conta."
    fi
    confirmar "Continuar?" || return 3
    # Guardado: sem isso, um wg ausente/quebrado sai daqui com privkey ou
    # pubkey VAZIA e a falha aparece la embaixo como "a Mullvad recusou o
    # registro da chave" -- mandando o usuario investigar a conta em vez do
    # wireguard-tools.
    privkey="$(wg genkey)" \
      || { erro "wg genkey falhou -- o wireguard-tools esta instalado e funcional?"; return 3; }
    pubkey="$(printf '%s' "$privkey" | wg pubkey)" \
      || { erro "wg pubkey falhou -- nao consegui derivar a chave publica da privada"; return 3; }
    [[ -n "$privkey" && -n "$pubkey" ]] \
      || { erro "wg genkey/pubkey devolveram vazio -- nao vou registrar uma chave invalida"; return 3; }
    # Conta no ambiente; a pubkey pode ficar em argv (chave publica nao e' segredo).
    endereco="$(MULLVAD_CONTA="$conta" \
      python3 "${RAIZ_REPO}/payload/mullvad_api.py" registrar-env "$pubkey")" \
      || { erro "a Mullvad recusou o registro da chave"; return 3; }
    ok "Chave registrada. Endereco atribuido: ${endereco}"
    # || return $?: se o key.json nao gravar, o proximo re-run nao acha chave
    # utilizavel e registra outra -- queimando mais um dos 5 slots da conta a
    # toa. Preferimos parar aqui e deixar o usuario resolver o disco/permissao.
    _salvar_chave "$conta" "$privkey" "$pubkey" "$endereco" || return $?
  fi

  local relay_json
  relay_json="$(_escolher_relay)" || return 3
  local hostname ip porta pubkey_relay
  read -r hostname ip porta pubkey_relay <<< "$(printf '%s' "$relay_json" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["hostname"], r["ipv4_addr_in"], 51820, r["public_key"])')"

  local destino="${DIR_CONF}/${hostname}.conf"
  # WG_PRIVKEY/WG_ADDRESS no ambiente pelo mesmo motivo da conta: a chave
  # PRIVADA do WireGuard em argv apareceria em /proc/<pid>/cmdline, que e'
  # world-readable. pubkey do relay, IP e porta ficam em argv -- nao sao segredos.
  ( umask 077
    WG_PRIVKEY="$privkey" WG_ADDRESS="$endereco" \
      python3 "${RAIZ_REPO}/payload/wgconf.py" construir-env "$pubkey_relay" "$ip" "$porta" \
      > "$destino" ) \
    || { erro "nao consegui gerar o conf em ${destino}"; return 1; }
  # chown so faz sentido como root; sem isso a rota automatica nao roda em teste.
  [[ $EUID -eq 0 ]] && chown root:root "$destino"
  chmod 600 "$destino" \
    || { erro "nao consegui travar a permissao de ${destino}"; return 1; }
  ok "Conf gerado: ${destino}"
  MULLVAD_CONF="$destino"
  export MULLVAD_CONF
}

_chave_e_desta_conta() {
  local conta="$1" hash_atual hash_salvo
  hash_atual="$(printf '%s' "$conta" | sha256sum | cut -d' ' -f1)"
  hash_salvo="$(python3 -c \
    'import json,sys;print(json.load(open(sys.argv[1])).get("conta_sha256",""))' "$ARQ_CHAVE" 2>/dev/null)" || true
  [[ -n "$hash_salvo" && "$hash_atual" == "$hash_salvo" ]]
}

# Le privkey e address de uma vez. Qualquer campo faltando ou ilegivel conta
# como "sem chave utilizavel": cai no caminho de registro em vez de morrer.
# Um key.json truncado (disco cheio, processo morto no meio do _salvar_chave)
# passa no check de hash e chegaria aqui incompleto.
_ler_chave_salva() {
  python3 - "$ARQ_CHAVE" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
priv, addr = d.get("privkey"), d.get("address")
if priv and addr:
    print("%s\t%s" % (priv, addr))
PY
}

# Guarda a chave privada e um hash da conta -- nunca o numero da conta em claro.
_salvar_chave() {
  local conta="$1" privkey="$2" pubkey="$3" endereco="$4"
  ( umask 077
    CONTA="$conta" PRIV="$privkey" PUB="$pubkey" ADDR="$endereco" python3 - <<'PY' > "$ARQ_CHAVE"
import hashlib, json, os
conta = os.environ["CONTA"]
json.dump({
    "conta_sha256": hashlib.sha256(conta.encode()).hexdigest(),
    "conta_final": conta[-4:],
    "privkey": os.environ["PRIV"],
    "pubkey": os.environ["PUB"],
    "address": os.environ["ADDR"],
}, __import__("sys").stdout, indent=2)
PY
  ) || { erro "nao consegui gravar ${ARQ_CHAVE}"; return 1; }
  # chown so faz sentido como root; sem isso a rota automatica nao roda em teste.
  [[ $EUID -eq 0 ]] && chown root:root "$ARQ_CHAVE"
  chmod 600 "$ARQ_CHAVE" \
    || { erro "nao consegui travar a permissao de ${ARQ_CHAVE}"; return 1; }
}

# Menu de pais -> relay. Ecoa o JSON do relay escolhido no stdout.
# No host nao ha garantia de fzf, entao e menu numerado.
_escolher_relay() {
  local relays_json
  relays_json="$(python3 "${RAIZ_REPO}/payload/mullvad_api.py" relays)" \
    || { erro "nao consegui buscar a lista de relays"; return 3; }

  local paises=() pais
  while IFS= read -r pais; do paises+=("$pais"); done < <(printf '%s' "$relays_json" \
    | python3 -c 'import json,sys; [print(p) for p in sorted({r["pais"] for r in json.load(sys.stdin)})]')

  printf '\n%sPais de saida%s\n\n' "$NEGRITO" "$RESET" >&2
  local i=1
  for pais in "${paises[@]}"; do printf '  %3d) %s\n' "$i" "$pais" >&2; i=$((i + 1)); done
  local escolha=""
  read -r -p "$(printf '%s[?]%s pais> ' "$AMARELO" "$RESET")" escolha
  [[ "$escolha" =~ ^[0-9]+$ ]] && (( escolha >= 1 && escolha <= ${#paises[@]} )) \
    || { erro "opcao invalida"; return 3; }
  local pais_escolhido="${paises[$((escolha - 1))]}"

  local nodes=() linha
  while IFS= read -r linha; do nodes+=("$linha"); done < <(printf '%s' "$relays_json" \
    | PAIS="$pais_escolhido" python3 -c '
import json, os, sys
pais = os.environ["PAIS"]
for r in json.load(sys.stdin):
    if r["pais"] == pais:
        print("%s\t%s\t%s" % (r["hostname"], r["cidade"], json.dumps(r)))')

  printf '\n%sRelay em %s%s\n\n' "$NEGRITO" "$pais_escolhido" "$RESET" >&2
  i=1
  for linha in "${nodes[@]}"; do
    printf '  %3d) %s  (%s)\n' "$i" "$(cut -f1 <<< "$linha")" "$(cut -f2 <<< "$linha")" >&2
    i=$((i + 1))
  done
  read -r -p "$(printf '%s[?]%s relay> ' "$AMARELO" "$RESET")" escolha
  [[ "$escolha" =~ ^[0-9]+$ ]] && (( escolha >= 1 && escolha <= ${#nodes[@]} )) \
    || { erro "opcao invalida"; return 3; }
  cut -f3 <<< "${nodes[$((escolha - 1))]}"
}

# --- adocao e normalizacao -------------------------------------------------

# Copia o conf para o diretorio restrito, faz backup e normaliza.
_adotar_conf() {
  local origem="$1"
  local destino="${DIR_CONF}/$(basename "$origem")"
  if [[ "$origem" != "$destino" ]]; then
    if [[ $EUID -eq 0 ]]; then
      install -m 600 -o root -g root "$origem" "$destino" \
        || { erro "nao consegui copiar ${origem} para ${destino}"; return 1; }
    else
      install -m 600 "$origem" "$destino" \
        || { erro "nao consegui copiar ${origem} para ${destino}"; return 1; }
    fi
    info "Copiado para ${destino}"
  fi
  # Backup depois da copia, nao antes: protege contra a normalizacao que vem a
  # seguir, nao contra o adotar em si -- se o destino ja existia com outro
  # conteudo (mesmo basename adotado de novo), o backup guarda o que acabou
  # de ser copiado, nao a geracao anterior.
  cp -a "$destino" "${destino}.bak.$(date +%Y%m%d-%H%M%S)" \
    || { erro "nao consegui fazer o backup de ${destino}"; return 1; }
  # return 1, nao morrer: a copia e o backup ja aconteceram (mutacao feita),
  # entao morrer aqui mataria o instalador inteiro sem o rodar() chegar a
  # reportar o estagio nem a dica de retomada.
  python3 "${RAIZ_REPO}/payload/wgconf.py" normalizar "$destino" \
    || { erro "nao consegui normalizar ${destino}"; return 1; }
  chmod 600 "$destino" \
    || { erro "nao consegui travar a permissao de ${destino}"; return 1; }
  # chown so faz sentido como root; sem isso a funcao nao roda em teste.
  [[ $EUID -eq 0 ]] && chown root:root "$destino"
  ok "Conf pronto: ${destino}"
  MULLVAD_CONF="$destino"
  export MULLVAD_CONF
}

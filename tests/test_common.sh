# Arquivos de teste sao sourcados pelo runner; nao definem 'set' por si mesmo.
# shellcheck source=../lib/common.sh
source "$RAIZ/lib/common.sh"

# --- detectar_distro ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' RETURN

printf 'ID=arch\nNAME="Arch Linux"\n' > "$TMP/arch"
afirmar_igual "arch" "$(detectar_distro "$TMP/arch")" "detectar_distro: ID=arch"

printf 'ID=manjaro\nID_LIKE=arch\n' > "$TMP/manjaro"
afirmar_igual "arch" "$(detectar_distro "$TMP/manjaro")" "detectar_distro: ID_LIKE=arch"

printf 'ID=debian\n' > "$TMP/debian"
afirmar_igual "debian" "$(detectar_distro "$TMP/debian")" "detectar_distro: ID=debian"

printf 'ID=ubuntu\nID_LIKE=debian\n' > "$TMP/ubuntu"
afirmar_igual "debian" "$(detectar_distro "$TMP/ubuntu")" "detectar_distro: ubuntu"

printf 'ID=kali\nID_LIKE="debian"\n' > "$TMP/kali"
afirmar_igual "debian" "$(detectar_distro "$TMP/kali")" "detectar_distro: kali via ID_LIKE"

printf 'ID=fedora\nID_LIKE="rhel fedora"\n' > "$TMP/fedora"
afirmar_igual "desconhecida" "$(detectar_distro "$TMP/fedora")" "detectar_distro: fedora nao suportada"

afirmar_igual "desconhecida" "$(detectar_distro "$TMP/nao-existe")" "detectar_distro: arquivo ausente"

# --- nome_chain ---
afirmar_igual "EXEGOL-MULLVAD-KS" "$(nome_chain mullvad)" "nome_chain: caso padrao"
afirmar_igual "EXEGOL-MEU-VPN-KS" "$(nome_chain meu-vpn)" "nome_chain: hifen preservado"
# iptables limita chain a 28 caracteres; "EXEGOL-" + "-KS" ja gastam 10.
_longo="$(nome_chain aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
afirmar_igual 28 "${#_longo}" "nome_chain: truncado em 28"

# --- nome_unit ---
afirmar_igual "exegol-mullvad-killswitch-watcher.service" "$(nome_unit mullvad)" "nome_unit"

# --- caminhos ---
afirmar_igual "/home/joao/.exegol/workspaces/mullvad" \
  "$(dir_workspace /home/joao mullvad)" "dir_workspace"
afirmar_igual "/home/joao/.exegol/workspaces/mullvad/.mullvad/state.json" \
  "$(caminho_state /home/joao mullvad)" "caminho_state"

# --- conta_valida ---
conta_valida 1234567890123456 && afirmar_status 0 0 "conta_valida: 16 digitos" \
  || afirmar_status 0 1 "conta_valida: 16 digitos"
conta_valida 123 && afirmar_status 1 0 "conta_valida: curta rejeitada" \
  || afirmar_status 1 1 "conta_valida: curta rejeitada"
conta_valida 12345678901234ab && afirmar_status 1 0 "conta_valida: letras rejeitadas" \
  || afirmar_status 1 1 "conta_valida: letras rejeitadas"
conta_valida "" && afirmar_status 1 0 "conta_valida: vazia rejeitada" \
  || afirmar_status 1 1 "conta_valida: vazia rejeitada"

# --- mascarar_conta ---
afirmar_igual "************3456" "$(mascarar_conta 1234567890123456)" "mascarar_conta"

# --- confirmar ---
#
# confirmar() guarda TODOS os prompts destrutivos do instalador (recriar o
# container, apagar segredos na desinstalacao, instalar pacotes). Duas decisoes
# deliberadas de seguranca que nada pinava:
#
#   1. ASSUME_SIM=1 (--yes) responde sim SEM ler o stdin.
#   2. Terminal nao interativo SEM --yes FALHA ALTO em vez de assumir sim.
#      Assumir sim ali seria aprovar destruicao por default.
#
# O padrao com terminal (resposta vazia = sim) e' conveniencia; o que nao pode
# mudar em silencio sao os dois de cima.
#
# O helper existe porque o `source "$RAIZ/lib/common.sh"` la em cima ligou o
# `set -e` NESTE processo: um `confirmar` que devolve 1 como comando solto
# mataria o runner inteiro antes do sumario. O `|| st=$?` e' o que guarda.
_status_confirmar() {  # $1 = ASSUME_SIM, $2 = resposta no stdin
  local st=0
  ( ASSUME_SIM="$1" confirmar "prompt destrutivo?" >/dev/null 2>&1 <<< "$2" ) || st=$?
  printf '%s\n' "$st"
}

afirmar_igual 0 "$(_status_confirmar 1 n)" \
  "confirmar: ASSUME_SIM=1 devolve sim mesmo com 'n' no stdin"

_saida_yes=""
_saida_yes="$(ASSUME_SIM=1 confirmar "prompt destrutivo?" 2>&1 <<< "n")" || true
afirmar_contem "(--yes)" "$_saida_yes" "confirmar: ASSUME_SIM=1 diz que respondeu pelo --yes"

# ASSUME_SIM=1 nao pode CONSUMIR o stdin: se consumisse, o proximo read do
# instalador (um menu, um caminho de .conf) comeria a linha errada.
_resto=""
_resto="$(printf 'linha-do-proximo-read\n' \
  | { ASSUME_SIM=1 confirmar "x?" >/dev/null 2>&1; cat; })" || true
afirmar_igual "linha-do-proximo-read" "$_resto" \
  "confirmar: ASSUME_SIM=1 nao consome o stdin"

# Sem --yes e sem terminal: FALHA, e diz o que fazer. Esta e' a decisao de
# seguranca: assumir sim aqui aprovaria destruicao por default.
_st_eof=0
_saida_eof=""
_saida_eof="$(ASSUME_SIM=0 confirmar "prompt destrutivo?" 2>&1 </dev/null)" || _st_eof=$?
afirmar_igual 1 "$_st_eof" "confirmar: sem --yes e sem stdin, FALHA em vez de assumir sim"
afirmar_contem "--yes" "$_saida_eof" \
  "confirmar: a mensagem de terminal nao interativo aponta o --yes"

# Com stdin utilizavel: vazio e' sim; s/S/y/Y e' sim; o resto e' nao.
afirmar_igual 0 "$(_status_confirmar 0 '')" "confirmar: resposta vazia e' sim (padrao S)"
for _r in s S y Y; do
  afirmar_igual 0 "$(_status_confirmar 0 "$_r")" "confirmar: '${_r}' e' sim"
done
for _r in n N nao qualquer 0; do
  afirmar_igual 1 "$(_status_confirmar 0 "$_r")" "confirmar: '${_r}' e' nao"
done
unset _saida_yes _resto _saida_eof _st_eof _r
unset -f _status_confirmar

# --- pacote_para e comando_instalar ---
# shellcheck source=../lib/01-deps.sh
source "$RAIZ/lib/01-deps.sh"

afirmar_igual "docker"          "$(pacote_para arch docker)"    "pacote_para: arch/docker"
afirmar_igual "python-pipx"     "$(pacote_para arch pipx)"      "pacote_para: arch/pipx"
afirmar_igual "wireguard-tools" "$(pacote_para arch wg)"        "pacote_para: arch/wg"
afirmar_igual "docker.io"       "$(pacote_para debian docker)"  "pacote_para: debian/docker"
afirmar_igual "pipx"            "$(pacote_para debian pipx)"    "pacote_para: debian/pipx"
afirmar_igual "python3"         "$(pacote_para debian python3)" "pacote_para: debian/python3"

pacote_para fedora docker && afirmar_status 1 0 "pacote_para: distro nao mapeada falha" \
  || afirmar_status 1 1 "pacote_para: distro nao mapeada falha"
pacote_para arch inexistente && afirmar_status 1 0 "pacote_para: dep nao mapeada falha" \
  || afirmar_status 1 1 "pacote_para: dep nao mapeada falha"

afirmar_igual "pacman -S --needed --noconfirm docker curl" \
  "$(comando_instalar arch docker curl)" "comando_instalar: arch"
afirmar_igual "apt-get install -y docker.io curl" \
  "$(comando_instalar debian docker.io curl)" "comando_instalar: debian"
comando_instalar fedora foo && afirmar_status 1 0 "comando_instalar: distro nao suportada falha" \
  || afirmar_status 1 1 "comando_instalar: distro nao suportada falha"

# --- ordem no estagio de deps: systemd antes de instalar pacotes ---
#
# O README promete que o systemd e' verificado "antes de instalar qualquer
# coisa". Estava depois: o instalador baixava pacotes num host onde a unit do
# watcher nunca teria como subir.
_l_systemd="$(grep -n 'tem_comando systemctl || morrer' "$RAIZ/lib/01-deps.sh" | cut -d: -f1)"
_l_instala="$(grep -n 'eval \$cmd' "$RAIZ/lib/01-deps.sh" | cut -d: -f1)"
if [[ -n "$_l_systemd" && -n "$_l_instala" && "$_l_systemd" -lt "$_l_instala" ]]; then
  afirmar_igual ok ok "deps: o check de systemd vem ANTES da instalacao de pacotes"
else
  afirmar_igual "systemd(${_l_systemd}) < instala(${_l_instala})" "falso" \
    "deps: o check de systemd vem ANTES da instalacao de pacotes"
fi
unset _l_systemd _l_instala

# --- regressao: o runner sobrevive a comando falho quando -e esta ativo ---
# As fixtures sao geradas AQUI DENTRO, nao ficam em tests/: se ficassem, o find
# do runner real as descobriria e passaria a rodar fixture como se fosse teste.
TMP_RUNNER="$(mktemp -d)"
trap "rm -rf '$TMP_RUNNER'" RETURN
mkdir -p "$TMP_RUNNER/tests" "$TMP_RUNNER/lib"
cp "$RAIZ/tests/run.sh" "$TMP_RUNNER/tests/"
cp "$RAIZ/lib/common.sh" "$TMP_RUNNER/lib/"

# Liga o -e no processo do runner -- e esse vazamento que e o bug. Ordena primeiro.
printf 'source "$RAIZ/lib/common.sh"\n' > "$TMP_RUNNER/tests/test_a_liga_e.sh"
# Comando falho nao guardado, seguido de uma afirmacao que so roda se o runner sobreviveu.
printf 'false\nafirmar_igual ok ok "fixture: runner sobreviveu ao comando falho"\n' \
  > "$TMP_RUNNER/tests/test_z_falha.sh"

SAIDA_RUNNER="$(cd "$TMP_RUNNER" && bash tests/run.sh 2>&1 || true)"
afirmar_contem "passaram" "$SAIDA_RUNNER" \
  "regressao: runner chega ao sumario com -e ativo e comando falhando"

# --- regressao: descoberta vazia e' falha, nao "0 passaram" ------------------
#
# Um find que nao acha nada (diretorio errado, arquivos renomeados, checkout
# parcial) imprimia "0 passaram, 0 falharam" e saia 0 -- um verde que nao
# provava nada. CI nenhum pegaria isso.
# --- regressao: o runner SEMPRE imprime sumario, mesmo abortando ------------
#
# O buraco que o teste anterior nao cobre: ali o `false` esta num arquivo
# DIFERENTE do que sourceia o common.sh, e o `set +e` no topo do laco desliga o
# -e antes de sourcear o proximo. Aqui o comando nao-zero esta no MESMO arquivo,
# DEPOIS do source -- e nesse caso o `set +e` de baixo nunca roda, porque o
# processo morre durante o source.
#
# Sem o trap EXIT no runner, isso matava o processo sem imprimir sumario nenhum:
# so o cabecalho do arquivo, e nada mais. E uma suite que morre sem sumario
# PARECE uma suite que passou.
#
# As fixtures sao geradas AQUI DENTRO, nao ficam em tests/: se ficassem, o find
# do runner real as descobriria e o teste_b abortaria a suite de verdade -- erro
# que este projeto ja cometeu uma vez e teve que desfazer.
TMP_ABORTA="$(mktemp -d)"
mkdir -p "$TMP_ABORTA/tests" "$TMP_ABORTA/lib"
cp "$RAIZ/tests/run.sh" "$TMP_ABORTA/tests/"
cp "$RAIZ/lib/common.sh" "$TMP_ABORTA/lib/"

# a) passa, e prova que o sumario traz as contagens que o runner JA tinha.
printf 'source "$RAIZ/lib/common.sh"\nafirmar_igual ok ok "fixture: rodou antes do aborto"\n' \
  > "$TMP_ABORTA/tests/test_a_ok.sh"
# b) sourceia o common.sh (religa o -e) e chama nao-zero DESGUARDADO no mesmo arquivo.
printf 'source "$RAIZ/lib/common.sh"\nfalse\nafirmar_igual ok ok "fixture: NAO deveria alcancar"\n' \
  > "$TMP_ABORTA/tests/test_b_aborta.sh"
# c) depois do aborto: nao roda, e e' isso que a mensagem de INCOMPLETA anuncia.
printf 'source "$RAIZ/lib/common.sh"\nafirmar_igual ok ok "fixture: depois do aborto"\n' \
  > "$TMP_ABORTA/tests/test_c_depois.sh"

ST_ABORTA=0
SAIDA_ABORTA=""
# O `|| ST_ABORTA=$?` e' a mesma armadilha que este teste cobre: sem ele, o -e
# ligado neste processo mataria o runner DE FORA aqui mesmo.
SAIDA_ABORTA="$(cd "$TMP_ABORTA" && bash tests/run.sh 2>&1)" || ST_ABORTA=$?

afirmar_igual 1 "$ST_ABORTA" "regressao: arquivo que aborta faz o runner sair 1"
afirmar_contem "passaram" "$SAIDA_ABORTA" \
  "regressao: o sumario e' impresso mesmo quando um arquivo aborta"
afirmar_contem "1 passaram, 0 falharam" "$SAIDA_ABORTA" \
  "regressao: o sumario traz as contagens que o runner ja tinha"
afirmar_contem "EXECUCAO INCOMPLETA" "$SAIDA_ABORTA" \
  "regressao: a propria linha de contagem diz que a execucao esta incompleta"
# "ABORTADA em <arquivo>", nao so o nome do arquivo: o laco JA imprime o nome
# como cabecalho antes de sourcear, entao afirmar so o nome passaria mesmo sem
# o sumario nomear nada (verificado por mutacao).
afirmar_contem "ABORTADA em test_b_aborta.sh" "$SAIDA_ABORTA" \
  "regressao: o sumario nomeia o arquivo que abortou"
# O stdout SOZINHO nao pode parecer verde: um `2>/dev/null` ou um log que separa
# os fluxos mostraria so a linha de contagem.
SAIDA_ABORTA_STDOUT=""
SAIDA_ABORTA_STDOUT="$(cd "$TMP_ABORTA" && bash tests/run.sh 2>/dev/null)" || true
afirmar_contem "EXECUCAO INCOMPLETA" "$SAIDA_ABORTA_STDOUT" \
  "regressao: o aviso de incompleta esta no stdout, nao so no stderr"
# Esta ultima nao guarda defeito nenhum: ela DOCUMENTA a premissa que faz a
# palavra "INCOMPLETA" ser honesta em vez de decorativa -- o runner morre no
# arquivo que abortou e os seguintes nao rodam mesmo.
afirmar_igual 0 "$(grep -c 'fixture: depois do aborto' <<< "$SAIDA_ABORTA" || true)" \
  "regressao: o arquivo depois do aborto de fato nao roda (premissa do INCOMPLETA)"

TMP_VAZIO="$(mktemp -d)"
# Um `trap ... RETURN` substitui o anterior, entao este ultimo limpa todos.
trap "rm -rf '$TMP' '$TMP_RUNNER' '$TMP_ABORTA' '$TMP_VAZIO'" RETURN
mkdir -p "$TMP_VAZIO/tests" "$TMP_VAZIO/lib"
cp "$RAIZ/tests/run.sh" "$TMP_VAZIO/tests/"
cp "$RAIZ/lib/common.sh" "$TMP_VAZIO/lib/"

# O `|| ST_VAZIO=$?` e' obrigatorio: o `set -e` que o lib/common.sh ligou neste
# processo mataria o runner aqui, antes do sumario, ao ver a atribuicao falhar.
ST_VAZIO=0
SAIDA_VAZIO=""
SAIDA_VAZIO="$(cd "$TMP_VAZIO" && bash tests/run.sh 2>&1)" || ST_VAZIO=$?
afirmar_igual 1 "$ST_VAZIO" "regressao: descoberta vazia sai com status 1"
afirmar_contem "nenhum teste encontrado" "$SAIDA_VAZIO" \
  "regressao: descoberta vazia diz o que aconteceu"
afirmar_igual 0 "$(grep -c 'passaram' <<< "$SAIDA_VAZIO" || true)" \
  "regressao: descoberta vazia nao imprime sumario de sucesso"
unset TMP_ABORTA SAIDA_ABORTA SAIDA_ABORTA_STDOUT ST_ABORTA \
      TMP_VAZIO SAIDA_VAZIO ST_VAZIO

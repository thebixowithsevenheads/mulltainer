# Instalador plug and play Exegol + Mullvad — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Substituir o script monolitico de 700 linhas por um instalador interativo multi-estagio em que o container Exegol e autonomo: ele reescreve o proprio `wg0.conf`, reconecta, e o host apenas vigia e aplica o backstop de iptables.

**Architecture:** Um `install.sh` com menu interativo sourceia cinco estagios em `lib/`. O `wg0.conf` passa a viver dentro do container (gravavel), com semente no host. O `PostUp` do `wg-quick` aplica a camada 1 do kill switch dentro do container e escreve `state.json` num bind mount; um unico servico systemd no host le esse arquivo local e mantem a camada 2 (chain em `DOCKER-USER`) em estado aberto ou fechado. Isso elimina o protocolo request/response, o `switch-apply.sh`, a unit oneshot e o `docker exec` por segundo da versao atual.

**Tech Stack:** Bash 5 (`set -euo pipefail`), Python 3 stdlib (sem dependencias externas no host), iptables/ip6tables, systemd, Docker, Exegol v5.x, WireGuard (`wg`, `wg-quick`), API publica da Mullvad.

**Spec:** `docs/superpowers/specs/2026-08-23-exegol-mullvad-plug-and-play-design.md`

## Global Constraints

- **Idioma, seguindo a convencao do repo:** codigo, comentarios e mensagens de UI em `.sh`/`.py` em portugues **sem acentuacao** (o script atual e assim: "variaveis", "obrigatorio", "Nao consegui"). Arquivos `.md` em portugues **com** acentuacao.
- **`set -euo pipefail`** no topo de todo arquivo `.sh`.
- **Nenhuma dependencia Python externa no host.** Apenas stdlib. O host nao tem `pytest`, `bats` nem `shellcheck`; testes usam `unittest` da stdlib e um runner de asserts em bash puro.
- **`rich` e opcional**, nunca obrigatorio: todo import de `rich` fica em `try/except ImportError` com fallback ANSI.
- **Nenhum arquivo `lib/*.sh` executa nada ao ser sourceado.** Cada um define funcoes e nada mais. **Excecao inevitavel:** o proprio `set -euo pipefail` do topo e um comando executado, e ele LIGA `-e` no shell que sourceia. Verificado: sourcear `lib/common.sh` de um shell com `set -uo pipefail` deixa ele com `-e` ligado.
- **Arquivos `tests/test_*.sh` NAO levam linha `set`.** Eles sao sourceados pelo `tests/run.sh`, nao executados, e o runner precisa sobreviver a comandos que falham dentro deles para poder contar e reportar todas as falhas. Cada arquivo de teste comeca com um comentario dizendo isso.
- **`tests/run.sh` faz `set +e` no inicio de cada iteracao do loop de arquivos.** Sem isso, o primeiro arquivo de teste que sourceia um `lib/*.sh` liga `-e` no processo do runner, e o proximo comando que falha num arquivo posterior aborta o runner no meio -- pulando os arquivos restantes E a linha de sumario. Verificado empiricamente. Nao remova esse `set +e`.
- **Edicao de `.conf` sempre via Python**, nunca `sed -i`.
- Container padrao: nome `mullvad` (prefixo real `exegol-mullvad`), imagem `free`.
- Rede: `exegol-vpn-net`, subnet `172.30.30.0/24`, gateway `172.30.30.1`, IP fixo `172.30.30.10`, `--ipv6=false`, `com.docker.network.bridge.enable_ip_masquerade=true`.
- Criacao do container: `exegol start <name> <image> --vpn ""` — o valor **vazio** e obrigatorio; e ele que ativa `NET_ADMIN` + `/dev/net/tun` + `net.ipv4.conf.all.src_valid_mark=1` + `net.ipv6.conf.all.disable_ipv6=0` sem montar conf.
- Chain do backstop: `EXEGOL-<NOME EM MAIUSCULAS>-KS`, inserida em `DOCKER-USER` na **posicao 1**.
- Unit systemd, **uma so**: `exegol-<name>-killswitch-watcher.service`. Nao criar unit `oneshot` — foi a causa do bug de boot.
- DNS dentro do container: `10.64.0.1`.
- Segredos: `.conf` em `/etc/wireguard/mullvad/` e `/etc/exegol-mullvad/key.json`, ambos `root:root` modo `600`. `state.json` **nao contem chave nenhuma**.
- APIs da Mullvad (contratos verificados em 2026-08-23):
  - `GET https://api.mullvad.net/public/relays/wireguard/v1/` — 553 relays, expoe `multihop_port`.
  - `POST https://api.mullvad.net/wg/` com `account` e `pubkey` — devolve o endereco atribuido; `Account does not exist` / HTTP 400 se invalida.
  - `GET https://api.mullvad.net/www/accounts/<n>/` — dados da conta; `{"code":"ACCOUNT_NOT_FOUND"}` / HTTP 404.
- **Fail-closed sempre:** se o kill switch nao puder ser aplicado, o estado resultante e o fechado. Nunca deixar a chain aberta por falha.
- `KS_DRY_RUN=1` faz `host-backstop.sh` e `host-watcher.sh` imprimirem os comandos `iptables` em vez de executa-los. E o que torna a logica testavel sem root; nao remover.
- **A supressao do errexit propaga por chamadas ANINHADAS, entao guardas nas folhas nao bastam.** Medido: um estagio que chama `_rede` (que devolve 1 apos falhar) segue executando `_container` e devolve 0 -- o `rodar()` ve sucesso apesar da falha. Por isso **toda chamada de helper que nao seja a ultima da funcao leva `|| return $?`**. Achado pelo implementer da Task 13 durante a auditoria, alem da lista que eu havia passado; a minha lista estava incompleta.
- **O `errexit` NAO protege dentro dos estagios, e por isso todo comando que muta estado precisa de guarda explicita.** O `rodar()` do `install.sh` chama o estagio como `"$fn" || st=$?`, e a regra do bash e' que um comando em contexto de `||` roda com `errexit` suprimido -- a supressao vale para o CORPO INTEIRO da funcao chamada. Medido: uma funcao com `false` no meio, invocada assim, executa as linhas seguintes e devolve 0. Consequencia: um `docker network create` que falha nao aborta o estagio; ele imprime o `ok` seguinte e segue. Portanto **todo comando que cria, remove ou altera estado (docker, systemctl, install, exegol) leva `|| { erro "<mensagem acionavel>"; return 1; }`**. Use `return 1`, nao `morrer`: medido tambem, um `morrer` dentro de um estagio mata o instalador inteiro, entao o `rodar()` nunca chega a reportar qual estagio falhou nem a dica de retomada, e o menu morre. O `morrer` fica reservado a pre-condicao detectada ANTES de qualquer mutacao. Nao remova essas guardas confiando no `set -e` do topo do arquivo -- ele nao vale ali.
- **Cuidado com `pipefail` em captura de comando.** `set -o pipefail` esta ativo em todo arquivo, entao `x="$(cmd | filtro)"` **aborta o script em silencio** se `cmd` falhar -- mesmo com `2>/dev/null`. Verificado: `find` num diretorio inexistente, `df` num path inexistente e `iptables` numa chain inexistente todos matam o script. Como varios desses casos sao normais numa instalacao limpa, toda captura desse tipo termina em `|| true` (ou `|| morrer "msg"` quando a falha e fatal). Nao remova esses `|| true` achando que sao redundantes.
- Privilegio: `install.sh` roda via `sudo`, exige `SUDO_USER`, e invoca o **binario** do Exegol como root com `HOME` e `SUDO_HOME` apontados para o home do `REAL_USER`. Nao usar `sudo -u "$REAL_USER" exegol`.

---

## File Structure

**Criar:**

| Arquivo | Responsabilidade |
|---|---|
| `install.sh` | Entrypoint. Menu interativo, leitura de estado, parse de flags, orquestracao dos estagios. Nao contem logica de estagio. |
| `lib/common.sh` | UI (cores, cabecalho, prompts), log, deteccao de distro, derivacao de nomes/caminhos, checks de estado. Sourceado por todos. |
| `lib/01-deps.sh` | `estagio_deps()`: docker, pipx, exegol, wireguard-tools, iptables, curl, e a tela de escolha de imagem. |
| `lib/02-mullvad.sh` | `estagio_mullvad()`: rota automatica (n da conta) e manual, estado da chave, normalizacao do conf. |
| `lib/03-container.sh` | `estagio_container()`: rede dedicada, container com `--vpn ""`, IP fixo, instalacao do payload, conf para dentro, alias. |
| `lib/04-killswitch.sh` | `estagio_killswitch()`: migracao da instalacao antiga, instalacao dos scripts do host, unit systemd. |
| `lib/05-verify.sh` | `estagio_verify()`: verificacao e teste de vazamento real. |
| `lib/06-uninstall.sh` | `estagio_desinstalar()`: remove container, rede, chain, unit e (opcionalmente) os segredos. |
| `payload/wgconf.py` | Manipulacao pura do `.conf` (normalizar, construir, trocar peer, ler endpoint). Modulo + CLI. Roda no host e dentro do container. |
| `payload/mullvad_api.py` | API da Mullvad: relays, registro de chave, info de conta, montagem de endpoint single/multihop. Modulo + CLI. |
| `payload/killswitch-postup.sh` | Camada 1. Roda dentro do container via `PostUp`. |
| `payload/mullvad-switch.py` | Menu de troca de relay, dentro do container. Autonomo, com rollback. |
| `payload/host-backstop.sh` | Camada 2. Aplica a chain em `DOCKER-USER` nos estados aberto/fechado. |
| `payload/host-watcher.sh` | Loop de 1s: le `state.json` local e o estado do container, chama o backstop. |
| `tests/run.sh` | Runner de asserts em bash puro. Sem dependencia. |
| `tests/test_common.sh` | Testes das funcoes puras de `lib/common.sh`. |
| `tests/test_backstop.sh` | Testes da sequencia de regras do backstop, via `KS_DRY_RUN=1`. |
| `tests/test_wgconf.py` | `unittest` de `payload/wgconf.py`. |
| `tests/test_mullvad_api.py` | `unittest` de `payload/mullvad_api.py`. |

**Modificar:**

| Arquivo | Mudanca |
|---|---|
| `README.md` | Reescrito por completo (Task 14). |

**Remover:**

| Arquivo | Motivo |
|---|---|
| `exegol-mullvad-killswitch-setup.sh` | Substituido pelo `install.sh` + `lib/`. Removido na Task 13, nao antes — ele e a referencia viva durante a implementacao. |

**Por que `wgconf.py` e `mullvad_api.py` ficam em `payload/` e nao em `lib/`:** os dois sao usados pelos estagios no host **e** pelo `mullvad-switch.py` dentro do container. `payload/` e o que e copiado para `/opt/my-resources/bin/`, entao viver ali significa uma copia so, sem duplicacao. Os estagios os invocam do proprio repo.

---

### Task 1: Verificacoes de campo

Tres perguntas da spec nao podem ser respondidas sem root ou sem o container de pe. Elas gateiam Tasks 7, 8 e 11 — nao escreva o codigo que depende delas antes de responder.

**Files:**
- Create: `docs/superpowers/specs/2026-08-23-field-checks.md`

**Interfaces:**
- Consumes: nada.
- Produces: as tres respostas, consumidas por Task 7 (`--vpn ""` funciona), Task 11 (caminho do `fzf`, single-hop funciona).

- [ ] **Step 1: Container de teste com `--vpn ""`**

```bash
sudo -E /home/$USER/.local/bin/exegol start kstest free --vpn ""
docker inspect exegol-kstest \
  --format 'CapAdd={{.HostConfig.CapAdd}} Sysctls={{.HostConfig.Sysctls}} Devices={{.HostConfig.Devices}}'
```

Esperado: `CapAdd=[NET_ADMIN]`, `Sysctls` contendo `net.ipv4.conf.all.src_valid_mark:1` e `net.ipv6.conf.all.disable_ipv6:0`, e `/dev/net/tun` em Devices. Se `CapAdd` vier vazio, a abordagem inteira nao funciona e o plano precisa voltar pro brainstorming — pare e reporte.

- [ ] **Step 2: Confirmar que `/etc/wireguard` e gravavel e que o `wg-quick` sobe**

```bash
docker exec exegol-kstest sh -c 'touch /etc/wireguard/teste && echo GRAVAVEL && rm /etc/wireguard/teste'
docker exec exegol-kstest sh -c 'cat /proc/sys/net/ipv4/conf/all/src_valid_mark'
```

Esperado: `GRAVAVEL` e `1`. O `1` confirma que o `wg-quick` nao vai falhar tentando setar o sysctl.

- [ ] **Step 3: Caminho do fzf**

```bash
docker exec exegol-kstest sh -lc 'command -v fzf || ls -la /opt/tools/fzf/bin/fzf 2>&1'
```

Anote o caminho real. O codigo atual assume `/opt/tools/fzf/bin/fzf` fixo; Task 11 vai resolver por `command -v` com fallback, e precisa saber qual fallback.

- [ ] **Step 4: Single-hop com chave nova**

Gere uma chave descartavel, registre, monte um conf single-hop e teste:

```bash
PRIV=$(wg genkey); PUB=$(printf '%s' "$PRIV" | wg pubkey)
read -rsp 'Numero da conta Mullvad: ' CONTA; echo
ADDR=$(curl -s https://api.mullvad.net/wg/ -d account="$CONTA" --data-urlencode "pubkey=$PUB")
echo "endereco atribuido: $ADDR"
RELAY=$(curl -s https://api.mullvad.net/public/relays/wireguard/v1/ | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["countries"][0]["cities"][0]["relays"][0]; print(r["ipv4_addr_in"], r["public_key"])')
set -- $RELAY
printf '[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = 10.64.0.1\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0,::/0\nEndpoint = %s:51820\n' \
  "$PRIV" "$ADDR" "$2" "$1" | docker exec -i exegol-kstest tee /etc/wireguard/wg0.conf >/dev/null
docker exec exegol-kstest wg-quick up wg0
docker exec exegol-kstest curl -s --max-time 20 https://am.i.mullvad.net/json
```

Esperado, se single-hop funcionar: `"mullvad_exit_ip": true`. Se falhar, anote o erro exato — Task 11 entao oferece so multihop, e a spec e corrigida.

Essa chave descartavel ocupa um dos 5 slots da conta. Remova depois em mullvad.net → Devices, e anote no documento de achados que isso foi feito.

- [ ] **Step 5: Limpar o container de teste**

```bash
sudo -E /home/$USER/.local/bin/exegol stop kstest
sudo -E /home/$USER/.local/bin/exegol remove kstest -F
```

- [ ] **Step 6: Registrar os achados e commitar**

Escreva `docs/superpowers/specs/2026-08-23-field-checks.md` com as quatro respostas, cada uma com o **output literal** do comando, nao um resumo. Se algum achado contradisser a spec, corrija a spec no mesmo commit e diga o que mudou.

```bash
git add docs/superpowers/specs/
git commit -m "Verificacoes de campo: --vpn \"\", fzf, single-hop"
```

---

### Task 2: Harness de teste e lib/common.sh

**Files:**
- Create: `tests/run.sh`
- Create: `tests/test_common.sh`
- Create: `lib/common.sh`

**Interfaces:**
- Consumes: nada.
- Produces, usados por todas as tasks seguintes:
  - `info(msg)`, `ok(msg)`, `aviso(msg)`, `erro(msg)` (stderr), `morrer(msg)` (stderr + `exit 1`)
  - `detectar_distro([caminho_os_release]) -> "arch"|"debian"|"desconhecida"` no stdout
  - `nome_chain(nome_container) -> string` no stdout
  - `nome_unit(nome_container) -> string` no stdout
  - `dir_workspace(home, nome_container) -> string` no stdout
  - `caminho_state(home, nome_container) -> string` no stdout
  - `conta_valida(string) -> status 0|1`
  - `mascarar_conta(string) -> string` no stdout
  - `confirmar(pergunta) -> status 0|1`
  - Variaveis de cor: `AMARELO AZUL CINZA VERMELHO VERDE NEGRITO RESET`
- Produces, usados por `tests/test_*.sh`: `afirmar_igual(esperado, obtido, desc)`, `afirmar_contem(agulha, palheiro, desc)`, `afirmar_status(esperado, obtido, desc)`

- [ ] **Step 1: Escrever o runner de testes**

`tests/run.sh` — sem bats, sem dependencia. Sourceia cada `tests/test_*.sh`; os arquivos de teste chamam as afirmacoes direto no nivel de topo.

```bash
#!/usr/bin/env bash
# Runner de testes em bash puro. Uso: bash tests/run.sh [arquivo ...]
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RAIZ

OK=0
FALHA=0
declare -a FALHAS=()

_reportar() {
  local resultado="$1" desc="$2" detalhe="${3:-}"
  if [[ "$resultado" == "ok" ]]; then
    OK=$((OK + 1))
    printf '  \033[32m.\033[0m %s\n' "$desc"
  else
    FALHA=$((FALHA + 1))
    FALHAS+=("$desc")
    printf '  \033[31mX\033[0m %s\n' "$desc"
    [[ -n "$detalhe" ]] && printf '      %s\n' "$detalhe"
  fi
}

afirmar_igual() {
  if [[ "$1" == "$2" ]]; then _reportar ok "$3"
  else _reportar falha "$3" "esperado: [$1] / obtido: [$2]"; fi
}

afirmar_contem() {
  if [[ "$2" == *"$1"* ]]; then _reportar ok "$3"
  else _reportar falha "$3" "nao achei [$1] em: $2"; fi
}

afirmar_status() { afirmar_igual "$1" "$2" "$3"; }

declare -a arquivos=("$@")
if [[ ${#arquivos[@]} -eq 0 ]]; then
  while IFS= read -r linha; do arquivos+=("$linha"); done \
    < <(find "$RAIZ/tests" -name 'test_*.sh' | sort)
fi

for arquivo in "${arquivos[@]}"; do
  printf '\n\033[1m%s\033[0m\n' "$(basename "$arquivo")"
  # shellcheck disable=SC1090
  source "$arquivo"
done

printf '\n%d passaram, %d falharam\n' "$OK" "$FALHA"
if [[ $FALHA -gt 0 ]]; then
  printf '\nFalhas:\n'
  for f in "${FALHAS[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
```

- [ ] **Step 2: Escrever os testes que devem falhar**

`tests/test_common.sh`:

```bash
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
```

- [ ] **Step 3: Rodar e confirmar que falha**

Run: `bash tests/run.sh tests/test_common.sh`
Expected: FAIL — `lib/common.sh: No such file or directory`

- [ ] **Step 4: Escrever lib/common.sh**

```bash
#!/usr/bin/env bash
# lib/common.sh -- UI, log, deteccao de ambiente e derivacao de nomes.
# Sourceado pelo install.sh e por todos os estagios. Nao executa nada ao ser
# sourceado: define funcoes e variaveis, nada mais.
set -euo pipefail

AMARELO=$'\033[38;2;255;213;36m'
AZUL=$'\033[38;2;41;77;115m'
CINZA=$'\033[38;2;108;137;168m'
VERMELHO=$'\033[31m'
VERDE=$'\033[32m'
NEGRITO=$'\033[1m'
RESET=$'\033[0m'

info()   { printf '%s[*]%s %s\n' "$AZUL" "$RESET" "$*"; }
ok()     { printf '%s[+]%s %s\n' "$VERDE" "$RESET" "$*"; }
aviso()  { printf '%s[!]%s %s\n' "$AMARELO" "$RESET" "$*"; }
erro()   { printf '%s[-]%s %s\n' "$VERMELHO" "$RESET" "$*" >&2; }
morrer() { erro "$*"; exit 1; }

# Pergunta sim/nao. Padrao sim. Respeita ASSUME_SIM=1 (flag --yes).
confirmar() {
  local pergunta="$1" resposta=""
  if [[ "${ASSUME_SIM:-0}" == "1" ]]; then
    info "$pergunta -> sim (--yes)"
    return 0
  fi
  read -r -p "$(printf '%s[?]%s %s [S/n] ' "$AMARELO" "$RESET" "$pergunta")" resposta
  [[ -z "$resposta" || "$resposta" =~ ^[SsYy]$ ]]
}

# Familia da distro a partir de um os-release. Ecoa arch|debian|desconhecida.
detectar_distro() {
  local arquivo="${1:-/etc/os-release}"
  [[ -r "$arquivo" ]] || { printf 'desconhecida\n'; return 0; }
  local id id_like
  id="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print $2; exit}' "$arquivo")"
  id_like="$(awk -F= '/^ID_LIKE=/{gsub(/"/, "", $2); print $2; exit}' "$arquivo")"
  case " ${id} ${id_like} " in
    *" arch "*)                 printf 'arch\n' ;;
    *" debian "*|*" ubuntu "*)  printf 'debian\n' ;;
    *)                          printf 'desconhecida\n' ;;
  esac
}

# EXEGOL-MULLVAD-KS. iptables limita nomes de chain a 28 caracteres e
# "EXEGOL-" + "-KS" ja gastam 10, entao o nome do container e truncado em 18.
nome_chain() {
  local maiusc
  maiusc="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  printf 'EXEGOL-%.18s-KS\n' "$maiusc"
}

nome_unit()     { printf 'exegol-%s-killswitch-watcher.service\n' "$1"; }
dir_workspace() { printf '%s/.exegol/workspaces/%s\n' "$1" "$2"; }
caminho_state() { printf '%s/.exegol/workspaces/%s/.mullvad/state.json\n' "$1" "$2"; }

conta_valida() { [[ "${1:-}" =~ ^[0-9]{16}$ ]]; }

mascarar_conta() {
  local c="${1:-}"
  if (( ${#c} <= 4 )); then printf '%s\n' "$c"; return 0; fi
  printf '%s%s\n' "$(printf '%*s' $(( ${#c} - 4 )) '' | tr ' ' '*')" "${c: -4}"
}
```

- [ ] **Step 5: Rodar e confirmar que passa**

Run: `bash tests/run.sh tests/test_common.sh`
Expected: PASS — 18 passaram, 0 falharam

- [ ] **Step 6: Commit**

```bash
git add tests/run.sh tests/test_common.sh lib/common.sh
git commit -m "Harness de teste em bash puro e lib/common.sh"
```

---

### Task 3: payload/wgconf.py — manipulacao do .conf

**Files:**
- Create: `payload/wgconf.py`
- Create: `tests/test_wgconf.py`

**Interfaces:**
- Consumes: nada.
- Produces, usados por Task 6 (`lib/02-mullvad.sh`) e Task 11 (`mullvad-switch.py`):
  - `normalizar(texto: str) -> str`
  - `construir(privkey: str, address: str, peer_pubkey: str, endpoint_ip: str, porta: int) -> str`
  - `ler_endpoint(texto: str) -> tuple[str, int]` — levanta `ValueError` se ausente
  - `trocar_peer(texto: str, pubkey: str, endpoint_ip: str, porta: int) -> str` — levanta `ValueError` se ausente
  - Constantes `DNS_MULLVAD`, `POSTUP`, `PREDOWN`
  - CLI: `normalizar <arq>` (in-place), `endpoint <arq>` (ecoa `ip porta`), `peer <arq> <pubkey> <ip> <porta>` (in-place), `construir <privkey> <address> <pubkey> <ip> <porta>` (ecoa no stdout)

- [ ] **Step 1: Escrever os testes que devem falhar**

`tests/test_wgconf.py`:

```python
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "payload"))

import wgconf

CONF_MULLVAD = """[Interface]
PrivateKey = cHJpdmF0ZWtleWV4YW1wbGVwcml2YXRla2V5ZXhhbXA=
Address = 10.66.77.88/32,fc00:bbbb:bbbb:bb01::1:1/128
DNS = 10.64.0.1

[Peer]
PublicKey = cHVia2V5ZXhhbXBsZXB1YmtleWV4YW1wbGVwdWJrZXk=
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = 193.32.127.66:51820
"""


class TestNormalizar(unittest.TestCase):
    def test_injeta_postup_e_predown(self):
        r = wgconf.normalizar(CONF_MULLVAD)
        self.assertIn(f"PostUp = {wgconf.POSTUP}", r)
        self.assertIn(f"PreDown = {wgconf.PREDOWN}", r)

    def test_idempotente(self):
        uma = wgconf.normalizar(CONF_MULLVAD)
        duas = wgconf.normalizar(uma)
        self.assertEqual(uma, duas)
        self.assertEqual(uma.count("PostUp"), 1)

    def test_remove_postup_antigo(self):
        sujo = CONF_MULLVAD.replace(
            "DNS = 10.64.0.1", "DNS = 10.64.0.1\nPostUp = /caminho/velho.sh"
        )
        r = wgconf.normalizar(sujo)
        self.assertNotIn("velho.sh", r)
        self.assertEqual(r.count("PostUp"), 1)

    def test_remove_bloco_killswitch_inline(self):
        sujo = CONF_MULLVAD + (
            "# --- mullvad killswitch BEGIN ---\n"
            "PostUp = iptables -P OUTPUT DROP\n"
            "# --- mullvad killswitch END ---\n"
        )
        r = wgconf.normalizar(sujo)
        self.assertNotIn("killswitch BEGIN", r)
        self.assertNotIn("iptables -P OUTPUT DROP", r)

    def test_forca_dns_da_mullvad(self):
        r = wgconf.normalizar(CONF_MULLVAD.replace("DNS = 10.64.0.1", "DNS = 1.1.1.1"))
        self.assertIn("DNS = 10.64.0.1", r)
        self.assertNotIn("1.1.1.1", r)

    def test_insere_dns_quando_ausente(self):
        sem_dns = CONF_MULLVAD.replace("DNS = 10.64.0.1\n", "")
        r = wgconf.normalizar(sem_dns)
        self.assertIn("DNS = 10.64.0.1", r)
        self.assertIn(f"PostUp = {wgconf.POSTUP}", r)

    def test_garante_newline_final(self):
        self.assertTrue(wgconf.normalizar(CONF_MULLVAD.rstrip("\n")).endswith("\n"))


class TestLerEndpoint(unittest.TestCase):
    def test_le_ip_e_porta(self):
        self.assertEqual(wgconf.ler_endpoint(CONF_MULLVAD), ("193.32.127.66", 51820))

    def test_le_porta_multihop(self):
        c = CONF_MULLVAD.replace("51820", "3494")
        self.assertEqual(wgconf.ler_endpoint(c), ("193.32.127.66", 3494))

    def test_levanta_se_ausente(self):
        with self.assertRaises(ValueError):
            wgconf.ler_endpoint("[Interface]\n")


class TestTrocarPeer(unittest.TestCase):
    def test_troca_pubkey_e_endpoint(self):
        r = wgconf.trocar_peer(CONF_MULLVAD, "NOVACHAVE=", "1.2.3.4", 3494)
        self.assertIn("PublicKey = NOVACHAVE=", r)
        self.assertIn("Endpoint = 1.2.3.4:3494", r)
        self.assertNotIn("193.32.127.66", r)

    def test_preserva_a_chave_privada(self):
        r = wgconf.trocar_peer(CONF_MULLVAD, "NOVACHAVE=", "1.2.3.4", 3494)
        self.assertIn("PrivateKey = cHJpdmF0ZWtleWV4YW1wbGVwcml2YXRla2V5ZXhhbXA=", r)

    def test_nao_toca_a_chave_da_interface(self):
        # PrivateKey e PublicKey coexistem; a troca so pode mexer na do Peer.
        r = wgconf.trocar_peer(CONF_MULLVAD, "NOVACHAVE=", "1.2.3.4", 3494)
        self.assertEqual(r.count("NOVACHAVE="), 1)

    def test_levanta_se_falta_publickey(self):
        with self.assertRaises(ValueError):
            wgconf.trocar_peer("[Interface]\nEndpoint = 1.2.3.4:1\n", "K=", "5.6.7.8", 2)


class TestConstruir(unittest.TestCase):
    def test_conf_completo_e_reparseavel(self):
        c = wgconf.construir("PRIV=", "10.1.2.3/32", "PUB=", "9.8.7.6", 51820)
        self.assertEqual(wgconf.ler_endpoint(c), ("9.8.7.6", 51820))
        self.assertIn("AllowedIPs = 0.0.0.0/0,::/0", c)
        self.assertIn(f"DNS = {wgconf.DNS_MULLVAD}", c)

    def test_saida_ja_normalizada(self):
        c = wgconf.construir("PRIV=", "10.1.2.3/32", "PUB=", "9.8.7.6", 51820)
        self.assertEqual(c, wgconf.normalizar(c))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'wgconf'`

- [ ] **Step 3: Escrever payload/wgconf.py**

```python
#!/usr/bin/env python3
"""Manipulacao do .conf do WireGuard.

Usado no host pelos estagios do instalador e dentro do container pelo
mullvad-switch -- por isso vive em payload/, que e o que e copiado para
/opt/my-resources/bin/. As funcoes recebem e devolvem texto; quem toca disco e
o CLI no fim do arquivo.

Um .conf da Mullvad tem exatamente UM [Peer]. Multihop nao e dois peers: e esse
peer unico com o IP do relay de ENTRADA como Endpoint, a multihop_port do relay
de SAIDA como porta, e a chave publica da SAIDA como PublicKey.
"""
import re
import sys

DNS_MULLVAD = "10.64.0.1"
POSTUP = "/opt/my-resources/bin/killswitch-postup.sh"
PREDOWN = "rm -f /workspace/.mullvad/state.json"


def normalizar(texto):
    """Deixa o conf no formato que o kill switch espera. Idempotente.

    Remove blocos de killswitch inline de versoes antigas e PostUp/PreDown
    orfaos, forca o DNS da Mullvad e injeta os hooks.
    """
    # CRLF primeiro, antes de qualquer regex: as ancoras (?m)$ nao casam antes
    # de um \r, e sem isso um conf baixado no Windows sai daqui INTACTO -- sem
    # PostUp, ou seja, com a camada 1 do kill switch nunca aplicada.
    c = texto.replace("\r\n", "\n")
    c = c if c.endswith("\n") else c + "\n"
    # Os dois curingas da frente sao LAZY de proposito. Greedy + re.S casaria do
    # primeiro marcador BEGIN ate o ULTIMO marcador END, apagando tudo no meio --
    # inclusive a secao [Peer] inteira quando o conf tem dois blocos antigos.
    c = re.sub(
        r"(?m)^# --- .*?killswitch BEGIN ---.*?^# --- .*?killswitch END ---\n?",
        "", c, flags=re.S,
    )
    c = re.sub(r"(?m)^PostUp\s*=.*$\n?", "", c)
    c = re.sub(r"(?m)^PreDown\s*=.*$\n?", "", c)
    if re.search(r"(?m)^DNS\s*=", c):
        c = re.sub(r"(?m)^DNS\s*=.*$", "DNS = " + DNS_MULLVAD, c, count=1)
    else:
        c = re.sub(
            r"(?m)^\[Interface\]$", "[Interface]\nDNS = " + DNS_MULLVAD, c, count=1
        )
    c = re.sub(
        r"(?m)^(DNS\s*=.*)$",
        r"\1\nPostUp = " + POSTUP + "\nPreDown = " + PREDOWN,
        c, count=1,
    )
    return c


def ler_endpoint(texto):
    """Devolve (ip, porta) do Endpoint do peer. Levanta ValueError se ausente."""
    m = re.search(r"(?m)^Endpoint\s*=\s*([^\s:]+):(\d+)\s*$", texto)
    if not m:
        raise ValueError("nao achei uma linha Endpoint valida no conf")
    return m.group(1), int(m.group(2))


def trocar_peer(texto, pubkey, endpoint_ip, porta):
    """Troca PublicKey e Endpoint do peer, preservando o resto.

    O count=1 e defensivo contra um conf que carregue mais de um [Peer]. Nao e
    por causa do PrivateKey da [Interface]: ^PublicKey nao casa com uma linha
    PrivateKey, entao o primeiro match ja e o do peer.
    """
    if not re.search(r"(?m)^PublicKey\s*=", texto):
        raise ValueError("nao achei PublicKey no conf")
    if not re.search(r"(?m)^Endpoint\s*=", texto):
        raise ValueError("nao achei Endpoint no conf")
    c = re.sub(r"(?m)^PublicKey\s*=.*$", "PublicKey = " + pubkey, texto, count=1)
    c = re.sub(
        r"(?m)^Endpoint\s*=.*$", "Endpoint = %s:%d" % (endpoint_ip, int(porta)), c, count=1
    )
    return c


def construir(privkey, address, peer_pubkey, endpoint_ip, porta):
    """Monta um conf do zero, ja normalizado."""
    return (
        "[Interface]\n"
        "PrivateKey = %s\n"
        "Address = %s\n"
        "DNS = %s\n"
        "PostUp = %s\n"
        "PreDown = %s\n"
        "\n"
        "[Peer]\n"
        "PublicKey = %s\n"
        "AllowedIPs = 0.0.0.0/0,::/0\n"
        "Endpoint = %s:%d\n"
    ) % (
        privkey, address, DNS_MULLVAD, POSTUP, PREDOWN,
        peer_pubkey, endpoint_ip, int(porta),
    )


def _ler(caminho):
    with open(caminho) as f:
        return f.read()


def _escrever(caminho, texto):
    with open(caminho, "w") as f:
        f.write(texto)


def main(argv):
    if len(argv) < 2:
        print(
            "uso: wgconf.py normalizar <arq>\n"
            "     wgconf.py endpoint <arq>\n"
            "     wgconf.py peer <arq> <pubkey> <ip> <porta>\n"
            "     wgconf.py construir <privkey> <address> <pubkey> <ip> <porta>",
            file=sys.stderr,
        )
        return 2
    cmd = argv[1]
    try:
        if cmd == "normalizar":
            _escrever(argv[2], normalizar(_ler(argv[2])))
        elif cmd == "endpoint":
            ip, porta = ler_endpoint(_ler(argv[2]))
            print("%s %d" % (ip, porta))
        elif cmd == "peer":
            _escrever(argv[2], trocar_peer(_ler(argv[2]), argv[3], argv[4], int(argv[5])))
        elif cmd == "construir":
            sys.stdout.write(
                construir(argv[2], argv[3], argv[4], argv[5], int(argv[6]))
            )
        else:
            print("comando desconhecido: %s" % cmd, file=sys.stderr)
            return 2
    except (ValueError, IndexError, OSError) as e:
        print("erro: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS — 16 testes, OK

- [ ] **Step 5: Conferir o CLI na mao**

```bash
printf '[Interface]\nPrivateKey = X=\nAddress = 10.1.1.1/32\n\n[Peer]\nPublicKey = Y=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 5.5.5.5:51820\n' > /tmp/t.conf
python3 payload/wgconf.py normalizar /tmp/t.conf && cat /tmp/t.conf
python3 payload/wgconf.py endpoint /tmp/t.conf   # esperado: 5.5.5.5 51820
python3 payload/wgconf.py peer /tmp/t.conf NOVA= 6.6.6.6 3494
python3 payload/wgconf.py endpoint /tmp/t.conf   # esperado: 6.6.6.6 3494
rm /tmp/t.conf
```

- [ ] **Step 6: Commit**

```bash
git add payload/wgconf.py tests/test_wgconf.py
git commit -m "payload/wgconf.py: manipulacao do .conf com testes"
```

---

### Task 4: payload/mullvad_api.py — API da Mullvad

**Files:**
- Create: `payload/mullvad_api.py`
- Create: `tests/test_mullvad_api.py`

**Interfaces:**
- Consumes: nada.
- Produces, usados por Task 6 (`lib/02-mullvad.sh`) e Task 11 (`mullvad-switch.py`):
  - `parse_relays(dados: dict) -> list[dict]` — cada relay: `{hostname, public_key, ipv4_addr_in, multihop_port, pais, cidade}`
  - `endpoint_singlehop(relay: dict) -> tuple[str, int, str]` — `(ip, porta, pubkey)`
  - `endpoint_multihop(entrada: dict, saida: dict) -> tuple[str, int, str]`
  - `agrupar_por_pais(relays) -> dict[str, list[dict]]`
  - `achar_por_hostname(relays, hostname) -> dict | None`
  - `achar_por_ip(relays, ip) -> dict | None`
  - `achar_por_pubkey(relays, pubkey) -> dict | None`
  - `buscar_relays(url=URL_RELAYS) -> list[dict]` (rede)
  - `info_conta(conta: str) -> dict` (rede)
  - `registrar_chave(conta: str, pubkey: str) -> str` (rede, devolve o endereco)
  - `ErroMullvad(Exception)`, `PORTA_SINGLEHOP = 51820`
  - CLI: `relays` (JSON no stdout), `conta <n>`, `registrar <n> <pubkey>`

- [ ] **Step 1: Escrever os testes que devem falhar**

`tests/test_mullvad_api.py`. Os testes de rede nao existem de proposito: fixture deterministica so para as funcoes puras.

```python
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "payload"))

import mullvad_api as api

FIXTURE = {
    "countries": [
        {
            "name": "Sweden",
            "cities": [
                {
                    "name": "Gothenburg",
                    "relays": [
                        {
                            "hostname": "se-got-wg-007",
                            "public_key": "SEGOT007=",
                            "ipv4_addr_in": "45.83.220.7",
                            "multihop_port": 3007,
                        }
                    ],
                }
            ],
        },
        {
            "name": "Brazil",
            "cities": [
                {
                    "name": "Sao Paulo",
                    "relays": [
                        {
                            "hostname": "br-sao-wg-101",
                            "public_key": "BRSAO101=",
                            "ipv4_addr_in": "191.96.30.101",
                            "multihop_port": 3101,
                        },
                        {
                            "hostname": "br-sao-wg-102",
                            "public_key": "BRSAO102=",
                            "ipv4_addr_in": "191.96.30.102",
                            "multihop_port": 3102,
                        },
                    ],
                }
            ],
        },
    ]
}


class TestParseRelays(unittest.TestCase):
    def test_achata_a_arvore(self):
        r = api.parse_relays(FIXTURE)
        self.assertEqual(len(r), 3)
        self.assertEqual(
            sorted(r[0].keys()),
            ["cidade", "hostname", "ipv4_addr_in", "multihop_port", "pais", "public_key"],
        )

    def test_ordena_por_pais_cidade_hostname(self):
        r = api.parse_relays(FIXTURE)
        self.assertEqual(
            [x["hostname"] for x in r],
            ["br-sao-wg-101", "br-sao-wg-102", "se-got-wg-007"],
        )

    def test_propaga_pais_e_cidade(self):
        r = api.parse_relays(FIXTURE)
        se = api.achar_por_hostname(r, "se-got-wg-007")
        self.assertEqual(se["pais"], "Sweden")
        self.assertEqual(se["cidade"], "Gothenburg")

    def test_arvore_vazia(self):
        self.assertEqual(api.parse_relays({}), [])
        self.assertEqual(api.parse_relays({"countries": []}), [])


class TestEndpoints(unittest.TestCase):
    def setUp(self):
        self.relays = api.parse_relays(FIXTURE)
        self.se = api.achar_por_hostname(self.relays, "se-got-wg-007")
        self.br = api.achar_por_hostname(self.relays, "br-sao-wg-101")

    def test_singlehop_usa_51820_e_a_chave_do_proprio_relay(self):
        self.assertEqual(
            api.endpoint_singlehop(self.br), ("191.96.30.101", 51820, "BRSAO101=")
        )

    def test_multihop_ip_da_entrada_porta_e_chave_da_saida(self):
        # Mecanica validada: IP da entrada, multihop_port da saida, chave da saida.
        self.assertEqual(
            api.endpoint_multihop(self.se, self.br), ("45.83.220.7", 3101, "BRSAO101=")
        )

    def test_multihop_recusa_entrada_igual_a_saida(self):
        with self.assertRaises(api.ErroMullvad):
            api.endpoint_multihop(self.se, self.se)


class TestBusca(unittest.TestCase):
    def setUp(self):
        self.relays = api.parse_relays(FIXTURE)

    def test_agrupar_por_pais(self):
        g = api.agrupar_por_pais(self.relays)
        self.assertEqual(sorted(g.keys()), ["Brazil", "Sweden"])
        self.assertEqual(len(g["Brazil"]), 2)

    def test_achar_por_ip(self):
        self.assertEqual(
            api.achar_por_ip(self.relays, "45.83.220.7")["hostname"], "se-got-wg-007"
        )

    def test_achar_por_pubkey(self):
        self.assertEqual(
            api.achar_por_pubkey(self.relays, "BRSAO102=")["hostname"], "br-sao-wg-102"
        )

    def test_achar_devolve_none_quando_nao_existe(self):
        self.assertIsNone(api.achar_por_hostname(self.relays, "xx-nada-wg-999"))
        self.assertIsNone(api.achar_por_ip(self.relays, "9.9.9.9"))
        self.assertIsNone(api.achar_por_pubkey(self.relays, "NADA="))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mullvad_api'`

- [ ] **Step 3: Escrever payload/mullvad_api.py**

```python
#!/usr/bin/env python3
"""API publica da Mullvad.

Contratos verificados em 2026-08-23:
  GET  /public/relays/wireguard/v1/   -> lista de relays, expoe multihop_port
  POST /wg/  (account, pubkey)        -> endereco atribuido; HTTP 400 se conta invalida
  GET  /www/accounts/<n>/             -> dados da conta; HTTP 404 se nao existe

A API nova (app/v1/relays) NAO expoe multihop_port, por isso usamos a legada.
Apenas stdlib -- roda no host e dentro do container sem instalar nada.
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

URL_RELAYS = "https://api.mullvad.net/public/relays/wireguard/v1/"
URL_WG = "https://api.mullvad.net/wg/"
URL_CONTA = "https://api.mullvad.net/www/accounts/%s/"
PORTA_SINGLEHOP = 51820
TIMEOUT = 15


class ErroMullvad(Exception):
    """Falha ao falar com a Mullvad ou dado invalido vindo dela."""


def parse_relays(dados):
    """Achata a arvore paises->cidades->relays numa lista ordenada."""
    relays = []
    for pais in dados.get("countries", []):
        for cidade in pais.get("cities", []):
            for r in cidade.get("relays", []):
                relays.append({
                    "hostname": r["hostname"],
                    "public_key": r["public_key"],
                    "ipv4_addr_in": r["ipv4_addr_in"],
                    "multihop_port": r["multihop_port"],
                    "pais": pais["name"],
                    "cidade": cidade["name"],
                })
    relays.sort(key=lambda r: (r["pais"], r["cidade"], r["hostname"]))
    return relays


def endpoint_singlehop(relay):
    """(ip, porta, pubkey) para conexao direta a um relay."""
    return relay["ipv4_addr_in"], PORTA_SINGLEHOP, relay["public_key"]


def endpoint_multihop(entrada, saida):
    """(ip, porta, pubkey) para multihop.

    Conecta no IP da ENTRADA, na porta multihop_port PROPRIA da SAIDA,
    autenticando com a chave publica da SAIDA.
    """
    if entrada["hostname"] == saida["hostname"]:
        raise ErroMullvad("entrada e saida nao podem ser o mesmo relay")
    return entrada["ipv4_addr_in"], saida["multihop_port"], saida["public_key"]


def agrupar_por_pais(relays):
    grupos = {}
    for r in relays:
        grupos.setdefault(r["pais"], []).append(r)
    return grupos


def _achar(relays, campo, valor):
    for r in relays:
        if r[campo] == valor:
            return r
    return None


def achar_por_hostname(relays, hostname):
    return _achar(relays, "hostname", hostname)


def achar_por_ip(relays, ip):
    return _achar(relays, "ipv4_addr_in", ip)


def achar_por_pubkey(relays, pubkey):
    return _achar(relays, "public_key", pubkey)


def buscar_relays(url=URL_RELAYS):
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            return parse_relays(json.load(r))
    except (urllib.error.URLError, ValueError, KeyError) as e:
        raise ErroMullvad("nao consegui buscar a lista de relays: %s" % e)


def info_conta(conta):
    """Dados da conta. Levanta ErroMullvad se nao existe."""
    try:
        with urllib.request.urlopen(URL_CONTA % conta, timeout=TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise ErroMullvad("conta nao encontrada")
        raise ErroMullvad("erro HTTP %d ao consultar a conta" % e.code)
    except (urllib.error.URLError, ValueError) as e:
        raise ErroMullvad("nao consegui consultar a conta: %s" % e)


def registrar_chave(conta, pubkey):
    """Registra a chave publica na conta e devolve o endereco atribuido.

    Cada chave registrada ocupa um dos 5 slots de dispositivo da conta -- quem
    chama e responsavel por reaproveitar chave existente em vez de gerar nova.
    """
    dados = urllib.parse.urlencode({"account": conta, "pubkey": pubkey}).encode()
    try:
        with urllib.request.urlopen(URL_WG, data=dados, timeout=TIMEOUT) as r:
            endereco = r.read().decode().strip()
    except urllib.error.HTTPError as e:
        corpo = e.read().decode(errors="replace").strip()
        raise ErroMullvad(
            "a Mullvad recusou o registro da chave: %s" % (corpo or ("HTTP %d" % e.code))
        )
    except urllib.error.URLError as e:
        raise ErroMullvad("nao consegui falar com a API da Mullvad: %s" % e)
    if not endereco:
        raise ErroMullvad("a Mullvad aceitou o registro mas nao devolveu endereco")
    return endereco


def main(argv):
    if len(argv) < 2:
        print(
            "uso: mullvad_api.py relays\n"
            "     mullvad_api.py conta <numero>\n"
            "     mullvad_api.py registrar <numero> <pubkey>",
            file=sys.stderr,
        )
        return 2
    cmd = argv[1]
    try:
        if cmd == "relays":
            json.dump(buscar_relays(), sys.stdout)
        elif cmd == "conta":
            json.dump(info_conta(argv[2]), sys.stdout)
        elif cmd == "registrar":
            print(registrar_chave(argv[2], argv[3]))
        else:
            print("comando desconhecido: %s" % cmd, file=sys.stderr)
            return 2
    except (ErroMullvad, IndexError) as e:
        print("erro: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS — 27 testes no total (16 de wgconf + 11 aqui), OK

- [ ] **Step 5: Conferir contra a API real**

A fixture e sintetica; este passo confirma que o parse aguenta o payload de verdade.

```bash
python3 payload/mullvad_api.py relays | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("relays:", len(r))
print("paises:", len({x["pais"] for x in r}))
faltando = [x for x in r if not x.get("multihop_port")]
print("sem multihop_port:", len(faltando))
print("exemplo:", r[0])
'
python3 payload/mullvad_api.py conta 0000000000000000; echo "status esperado 1: $?"
```

Esperado: ~550 relays, dezenas de paises, `sem multihop_port: 0`, e a conta invalida saindo com status 1 e a mensagem `erro: conta nao encontrada`.

- [ ] **Step 6: Commit**

```bash
git add payload/mullvad_api.py tests/test_mullvad_api.py
git commit -m "payload/mullvad_api.py: API da Mullvad com testes"
```

---

### Task 5: lib/01-deps.sh e os helpers de privilegio

**Files:**
- Modify: `lib/common.sh` (adiciona os helpers de ambiente no fim do arquivo)
- Create: `lib/01-deps.sh`
- Modify: `tests/test_common.sh` (adiciona os testes de `pacote_para` e `comando_instalar`)

**Interfaces:**
- Consumes de Task 2: `info ok aviso erro morrer confirmar detectar_distro`
- Produces:
  - Em `lib/common.sh`: `descobrir_ambiente()` — exporta `REAL_USER`, `REAL_HOME`, `EXEGOL_BIN`; `exegol_cmd(args...)` — invoca o Exegol como root com `HOME`/`SUDO_HOME` do usuario real
  - Em `lib/01-deps.sh`: `pacote_para(distro, dep) -> string` (status 1 se nao mapeado), `comando_instalar(distro, pacotes...) -> string`, `estagio_deps()`
- Requer Task 1 concluida (o achado do `--vpn ""` nao afeta este estagio, mas a ordem do plano e sequencial).

- [ ] **Step 1: Escrever os testes que devem falhar**

Anexe em `tests/test_common.sh`:

```bash
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `bash tests/run.sh tests/test_common.sh`
Expected: FAIL — `lib/01-deps.sh: No such file or directory`

- [ ] **Step 3: Adicionar os helpers de ambiente em lib/common.sh**

Anexe no fim de `lib/common.sh`:

```bash
# --- ambiente e privilegio -------------------------------------------------

# Exige root via sudo e descobre quem e o usuario real.
# Exporta REAL_USER, REAL_HOME, EXEGOL_BIN.
descobrir_ambiente() {
  [[ $EUID -eq 0 ]] || morrer "precisa de root: sudo bash install.sh"
  REAL_USER="${SUDO_USER:-}"
  [[ -n "$REAL_USER" ]] || morrer \
    "rode via sudo, nao como root direto -- preciso saber de quem e o ~/.exegol"
  # || true obrigatorio: getent passwd de usuario inexistente sai com 2, o
  # pipefail propaga, e o set -e mataria o script AQUI -- antes da checagem
  # amigavel da linha seguinte, que existe justamente pra esse caso.
  REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"
  [[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || morrer "nao achei o home de $REAL_USER"
  EXEGOL_BIN="${EXEGOL_BIN:-$REAL_HOME/.local/bin/exegol}"
  export REAL_USER REAL_HOME EXEGOL_BIN
}

# Invoca o binario do Exegol como root, com HOME/SUDO_HOME do usuario real.
#
# O Exegol NAO se auto-escala -- nao existe chamada de sudo no codigo dele
# (verificado na v5.1.11). O prompt de senha que aparece na pratica vem de um
# alias de shell do usuario (ex.: alias exegol='sudo -E ~/.local/bin/exegol').
# Como o instalador ja roda como root, chamamos o binario direto. E por isso que
# o instalador NAO depende do usuario estar no grupo docker.
# SUDO_HOME e lido pelo Exegol para localizar o diretorio de config
# (ConstantConfig.py:25).
exegol_cmd() {
  HOME="$REAL_HOME" SUDO_HOME="$REAL_HOME" USER="$REAL_USER" LOGNAME="$REAL_USER" \
    "$EXEGOL_BIN" "$@"
}

tem_comando() { command -v "$1" >/dev/null 2>&1; }

# Raiz do repositorio, para achar payload/ independente do cwd de quem chamou.
# Definida a partir da localizacao deste arquivo, nao do diretorio corrente.
RAIZ_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RAIZ_REPO
```

- [ ] **Step 4: Escrever lib/01-deps.sh**

```bash
#!/usr/bin/env bash
# lib/01-deps.sh -- estagio 1: dependencias do host e imagem do Exegol.
# Sourceado pelo install.sh. Nao executa nada ao ser sourceado.
set -euo pipefail

# Tamanho conservador da imagem em disco, em GB. O `exegol info` reporta ~42 GB
# para a free; o `docker image inspect .Size` reporta ~67 GB para a mesma imagem
# (soma das camadas). Usamos o maior no check de espaco livre de proposito.
TAMANHO_IMAGEM_GB=67

# Nome do pacote de uma dependencia, por familia de distro.
# Status 1 se nao houver mapeamento.
pacote_para() {
  case "${1}:${2}" in
    arch:docker)     printf 'docker\n' ;;
    arch:pipx)       printf 'python-pipx\n' ;;
    arch:wg)         printf 'wireguard-tools\n' ;;
    arch:iptables)   printf 'iptables\n' ;;
    arch:curl)       printf 'curl\n' ;;
    arch:python3)    printf 'python\n' ;;
    debian:docker)   printf 'docker.io\n' ;;
    debian:pipx)     printf 'pipx\n' ;;
    debian:wg)       printf 'wireguard-tools\n' ;;
    debian:iptables) printf 'iptables\n' ;;
    debian:curl)     printf 'curl\n' ;;
    debian:python3)  printf 'python3\n' ;;
    *) return 1 ;;
  esac
}

comando_instalar() {
  local distro="$1"; shift
  case "$distro" in
    arch)   printf 'pacman -S --needed --noconfirm %s\n' "$*" ;;
    debian) printf 'apt-get install -y %s\n' "$*" ;;
    *) return 1 ;;
  esac
}

# Comando que testa a presenca de cada dependencia.
_presente() {
  case "$1" in
    docker)   tem_comando docker ;;
    pipx)     tem_comando pipx ;;
    wg)       tem_comando wg ;;
    iptables) tem_comando iptables ;;
    curl)     tem_comando curl ;;
    python3)  tem_comando python3 ;;
    *) return 1 ;;
  esac
}

estagio_deps() {
  local distro
  distro="$(detectar_distro)"
  info "Distro detectada: ${distro}"

  if [[ "$distro" == "desconhecida" ]]; then
    erro "Distro nao suportada. Suportadas: Arch (e derivadas) e Debian/Ubuntu."
    erro "Instale na mao e rode de novo: docker, pipx, wireguard-tools, iptables, curl, python3"
    return 3
  fi

  # --- pacotes do sistema ---
  local faltando=() dep pacote
  for dep in docker pipx wg iptables curl python3; do
    if _presente "$dep"; then
      ok "${dep}: presente"
    else
      pacote="$(pacote_para "$distro" "$dep")" || morrer "sem mapeamento de pacote para ${dep}"
      aviso "${dep}: ausente -> pacote ${pacote}"
      faltando+=("$pacote")
    fi
  done

  if (( ${#faltando[@]} > 0 )); then
    local cmd
    cmd="$(comando_instalar "$distro" "${faltando[@]}")"
    info "Vou rodar: ${cmd}"
    confirmar "Instalar os pacotes que faltam?" || return 3
    [[ "$distro" == "debian" ]] && apt-get update -qq
    # shellcheck disable=SC2086
    eval $cmd
  fi

  # --- docker ativo ---
  # Devuan reporta ID_LIKE=debian e usa sysvinit, entao um host suportado pode
  # nao ter systemctl. Sem esta checagem o estagio morre com "command not found".
  tem_comando systemctl || morrer \
    "este instalador precisa de systemd (nao achei o systemctl). Suba o docker na mao e rode de novo."
  if ! systemctl is-active --quiet docker; then
    info "Habilitando e subindo o docker.service..."
    systemctl enable --now docker \
      || { erro "nao consegui habilitar o docker.service"; return 1; }
  fi
  ok "docker.service ativo"

  # O instalador fala com o docker como root, entao isso e conveniencia para o
  # uso posterior pelo proprio usuario -- a instalacao nao depende disso.
  # O grupo pode nao existir; e conveniencia, entao nunca pode ser fatal.
  if ! getent group docker >/dev/null 2>&1; then
    aviso "grupo docker nao existe, pulando o usermod"
  elif ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
    info "Adicionando ${REAL_USER} ao grupo docker (vale depois de relogar)..."
    usermod -aG docker "$REAL_USER"
    aviso "Para usar 'docker' sem sudo, relogue depois. A instalacao segue sem isso."
  fi

  # --- exegol ---
  if [[ -x "$EXEGOL_BIN" ]]; then
    ok "exegol: $(exegol_cmd version 2>/dev/null | head -1 || echo presente)"
  else
    info "Instalando o Exegol via pipx como ${REAL_USER}..."
    confirmar "Instalar o Exegol?" || return 3
    sudo -u "$REAL_USER" env HOME="$REAL_HOME" pipx install exegol
    [[ -x "$EXEGOL_BIN" ]] || morrer "pipx terminou mas nao achei o binario em ${EXEGOL_BIN}"
    ok "exegol instalado"
  fi

  _tela_imagem
}

# Tela de escolha da imagem. Mostra o `exegol info` cru de proposito: ele traz
# os tamanhos reais e o parse da tabela rica dele seria fragil e quebraria a
# cada release.
_tela_imagem() {
  if docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" >/dev/null 2>&1; then
    local tamanho
    tamanho="$(docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" \
      --format '{{.Size}}' | awk '{printf "%.0f GB", $1/1000000000}' || true)"
    ok "imagem ${IMAGE_TAG}: ja instalada (${tamanho})"
    return 0
  fi

  printf '\n%sImagens do Exegol%s\n\n' "$NEGRITO" "$RESET"
  printf '  %sfree%s   gratuita, sem assinatura -- e o padrao aqui\n' "$AMARELO" "$RESET"
  printf '  as demais aparecem marcadas "Pro / Enterprise only" na tabela abaixo\n\n'
  # A tabela do proprio exegol traz os tamanhos e ja marca quais exigem
  # assinatura. Mostramos ela crua: parsear essa tabela rica seria fragil e
  # quebraria a cada release.
  exegol_cmd info 2>/dev/null || aviso "nao consegui rodar 'exegol info'"

  local livre
  # || true: com pipefail, o df falhando (docker recem instalado, /var/lib/docker
  # ainda inexistente) mataria o estagio em silencio.
  livre="$(df --output=avail -BG /var/lib/docker 2>/dev/null \
    | tail -1 | tr -dc '0-9' || true)"
  if [[ -n "$livre" ]]; then
    printf '\n  Espaco livre em /var/lib/docker: %s GB\n' "$livre"
    # Os dois numeros divergem para a MESMA imagem e os dois sao reais:
    # `exegol info` reporta ~42 GB, e `docker image inspect .Size` reporta
    # ~67 GB (soma das camadas). O limite usa o numero conservador, porque
    # avisar de menos deixa o usuario sem disco no meio de um download de
    # dezenas de GB -- a falha tem que cair pro lado seguro.
    if (( livre < TAMANHO_IMAGEM_GB + 13 )); then
      aviso "A imagem ${IMAGE_TAG} ocupa ~42 GB pelo 'exegol info' e ~${TAMANHO_IMAGEM_GB} GB"
      aviso "pela soma de camadas do docker. Voce tem ${livre} GB livres."
      confirmar "Continuar mesmo assim?" || return 3
    fi
  fi

  info "Baixando a imagem ${IMAGE_TAG} (demora -- sao dezenas de GB)..."
  confirmar "Baixar agora?" || return 3
  exegol_cmd install "$IMAGE_TAG"
}
```

- [ ] **Step 5: Rodar os testes e confirmar que passam**

Run: `bash tests/run.sh tests/test_common.sh`
Expected: PASS — 29 passaram, 0 falharam

- [ ] **Step 6: Conferir a sintaxe dos dois arquivos**

Run: `bash -n lib/common.sh && bash -n lib/01-deps.sh && echo SINTAXE_OK`
Expected: `SINTAXE_OK`

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh lib/01-deps.sh tests/test_common.sh
git commit -m "Estagio 1: dependencias do host, imagem, e helpers de privilegio"
```

---

### Task 6: lib/02-mullvad.sh — config da Mullvad

**Files:**
- Create: `lib/02-mullvad.sh`

**Interfaces:**
- Consumes: `info ok aviso erro morrer confirmar` (Task 2), `payload/wgconf.py` (Task 3), `payload/mullvad_api.py` (Task 4), `REAL_HOME` (Task 5)
- Produces: `estagio_mullvad()` — no sucesso, deixa `MULLVAD_CONF` apontando para um `.conf` normalizado em `/etc/wireguard/mullvad/`, modo 600 root, e exporta a variavel.

- [ ] **Step 1: Escrever lib/02-mullvad.sh**

Sem teste unitario: cada funcao aqui e I/O de disco privilegiado ou rede. A logica pura que daria pra testar ja esta em `wgconf.py` e `mullvad_api.py`, testadas nas Tasks 3 e 4.

```bash
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
    install -d -m 700 -o root -g root "$DIR_CONF" "$DIR_ESTADO"
  else
    install -d -m 700 "$DIR_CONF" "$DIR_ESTADO"
  fi

  # --conf explicito pula a escolha
  if [[ -n "${CONF_INFORMADO:-}" ]]; then
    [[ -f "$CONF_INFORMADO" ]] || morrer "arquivo nao encontrado: ${CONF_INFORMADO}"
    _adotar_conf "$CONF_INFORMADO"
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
    _adotar_conf "$arq"
    return 0
  fi
  if [[ "$escolha" =~ ^[0-9]+$ ]] && (( escolha >= 1 && escolha < i )); then
    _adotar_conf "${candidatos[$((escolha - 1))]}"
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

  local validade
  validade="$(python3 "${RAIZ_REPO}/payload/mullvad_api.py" conta "$conta" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expiry_iso","?"))')" \
    || { erro "a Mullvad nao reconheceu essa conta"; return 3; }
  ok "Conta valida. Expira em: ${validade}"

  local privkey pubkey endereco salva=""
  if [[ -f "$ARQ_CHAVE" ]] && _chave_e_desta_conta "$conta"; then
    salva="$(_ler_chave_salva)"
  fi
  if [[ -n "$salva" ]]; then
    info "Reaproveitando a chave ja registrada -- nao queima outro slot da conta."
    IFS=$'\t' read -r privkey endereco <<< "$salva"
  else
    if [[ -f "$ARQ_CHAVE" ]]; then
      # key.json existe mas nao rende chave utilizavel (truncado, campo faltando).
      # O usuario precisa saber que a chave antiga fica ORFA ocupando um slot.
      aviso "Achei um ${ARQ_CHAVE} mas nao consegui ler uma chave utilizavel dele."
      aviso "Registrar uma nova consome outro dos 5 slots, e a anterior continua"
      aviso "ocupando o dela ate voce remover em mullvad.net -> Devices."
      aviso "Apagar o key.json aqui NAO libera o slot."
    fi
    aviso "Vou registrar uma chave nova. A Mullvad permite 5 por conta."
    confirmar "Continuar?" || return 3
    privkey="$(wg genkey)"
    pubkey="$(printf '%s' "$privkey" | wg pubkey)"
    endereco="$(python3 "${RAIZ_REPO}/payload/mullvad_api.py" registrar "$conta" "$pubkey")" \
      || { erro "a Mullvad recusou o registro da chave"; return 3; }
    ok "Chave registrada. Endereco atribuido: ${endereco}"
    _salvar_chave "$conta" "$privkey" "$pubkey" "$endereco"
  fi

  local relay_json
  relay_json="$(_escolher_relay)" || return 3
  local hostname ip porta pubkey_relay
  read -r hostname ip porta pubkey_relay <<< "$(printf '%s' "$relay_json" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["hostname"], r["ipv4_addr_in"], 51820, r["public_key"])')"

  local destino="${DIR_CONF}/${hostname}.conf"
  ( umask 077
    python3 "${RAIZ_REPO}/payload/wgconf.py" construir "$privkey" "$endereco" "$pubkey_relay" "$ip" "$porta" \
      > "$destino" )
  [[ $EUID -eq 0 ]] && chown root:root "$destino"
  chmod 600 "$destino"
  ok "Conf gerado: ${destino}"
  MULLVAD_CONF="$destino"
  export MULLVAD_CONF
}

# Le privkey e address de uma vez, tolerando arquivo ausente, ilegivel ou com
# campo faltando -- qualquer um desses conta como "sem chave utilizavel". Um
# key.json truncado (disco cheio, processo morto no meio do _salvar_chave) passa
# no check de hash e chegaria incompleto no caminho de reuso.
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

_chave_e_desta_conta() {
  local conta="$1" hash_atual hash_salvo
  hash_atual="$(printf '%s' "$conta" | sha256sum | cut -d' ' -f1)"
  # || true: com pipefail um key.json corrompido mataria o estagio aqui.
  hash_salvo="$(python3 -c \
    'import json;print(json.load(open("'"$ARQ_CHAVE"'")).get("conta_sha256",""))' 2>/dev/null || true)"
  [[ -n "$hash_salvo" && "$hash_atual" == "$hash_salvo" ]]
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
  )
  # O umask 077 do subshell ja deixou o arquivo em 600; o chown so faz sentido
  # como root. Sem a guarda, um run nao-root aborta aqui por EPERM logo DEPOIS
  # de a chave ja ter sido registrada na Mullvad -- lugar pessimo para morrer.
  [[ $EUID -eq 0 ]] && chown root:root "$ARQ_CHAVE"
  chmod 600 "$ARQ_CHAVE"
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
      install -m 600 -o root -g root "$origem" "$destino"
    else
      install -m 600 "$origem" "$destino"
    fi
    info "Copiado para ${destino}"
  fi
  cp -a "$destino" "${destino}.bak.$(date +%Y%m%d-%H%M%S)"
  python3 "${RAIZ_REPO}/payload/wgconf.py" normalizar "$destino" \
    || morrer "nao consegui normalizar ${destino}"
  chmod 600 "$destino"
  # chown so faz sentido como root; sem isso a funcao nao roda em teste.
  [[ $EUID -eq 0 ]] && chown root:root "$destino"
  ok "Conf pronto: ${destino}"
  MULLVAD_CONF="$destino"
  export MULLVAD_CONF
}
```

- [ ] **Step 2: Conferir a sintaxe**

Run: `bash -n lib/02-mullvad.sh && echo SINTAXE_OK`
Expected: `SINTAXE_OK`

- [ ] **Step 3: Exercitar a normalizacao com um conf de mentira**

```bash
sudo install -d -m 700 /etc/wireguard/mullvad
printf '[Interface]\nPrivateKey = FAKE=\nAddress = 10.1.1.1/32\nDNS = 1.1.1.1\nPostUp = /velho.sh\n\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:51820\n' > /tmp/fake.conf
sudo bash -c 'cd "$PWD"; source lib/common.sh; source lib/02-mullvad.sh; REAL_HOME='"$HOME"'; _adotar_conf /tmp/fake.conf'
sudo cat /etc/wireguard/mullvad/fake.conf
```

Esperado: `DNS = 10.64.0.1`, um unico `PostUp` apontando para `/opt/my-resources/bin/killswitch-postup.sh`, um `PreDown`, e o `/velho.sh` sumido. Limpe depois: `sudo rm /etc/wireguard/mullvad/fake.conf*`

- [ ] **Step 4: Commit**

```bash
git add lib/02-mullvad.sh
git commit -m "Estagio 2: config da Mullvad por rota automatica ou manual"
```

---

### Task 7: lib/03-container.sh — rede, container, payload

Requer o achado de Task 1 Step 1 (o `--vpn ""` entrega `NET_ADMIN` + `src_valid_mark`). Se aquele passo falhou, pare aqui.

**Files:**
- Create: `lib/03-container.sh`

**Interfaces:**
- Consumes: `info ok aviso morrer confirmar exegol_cmd RAIZ_REPO REAL_HOME` (Tasks 2 e 5), `MULLVAD_CONF` (Task 6), e as variaveis globais `CONTAINER_NAME FULL_NAME IMAGE_TAG NETWORK_NAME SUBNET GATEWAY STATIC_IP` (definidas pelo `install.sh` na Task 13)
- Produces: `estagio_container()`

- [ ] **Step 1: Escrever lib/03-container.sh**

```bash
#!/usr/bin/env bash
# lib/03-container.sh -- estagio 3: rede dedicada, container, payload, conf.
# Nao executa nada ao ser sourceado.
set -euo pipefail

estagio_container() {
  [[ -n "${MULLVAD_CONF:-}" ]] || morrer "sem .conf -- rode o estagio 2 primeiro"
  [[ -f "$MULLVAD_CONF" ]] || morrer "conf nao encontrado: ${MULLVAD_CONF}"
  _rede_dedicada
  _recriar_container
  _fixar_ip
  _instalar_payload
  _conf_para_dentro
  _alias_no_zshrc
}

_rede_dedicada() {
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    ok "rede ${NETWORK_NAME}: ja existe"
    return 0
  fi
  info "Criando a rede ${NETWORK_NAME} (${SUBNET})..."
  docker network create --driver bridge \
    --subnet "$SUBNET" --gateway "$GATEWAY" \
    --opt com.docker.network.bridge.enable_ip_masquerade=true \
    --ipv6=false "$NETWORK_NAME" \
    || { erro "nao consegui criar a rede ${NETWORK_NAME} -- a subnet ${SUBNET} colide com outra rede docker?"; return 1; }
  ok "rede criada"
}

_recriar_container() {
  if docker container inspect "$FULL_NAME" >/dev/null 2>&1; then
    aviso "${FULL_NAME} ja existe e vai ser RECRIADO."
    aviso "O /workspace e bind mount e sobrevive. O resto do filesystem dele, nao."
    confirmar "Recriar ${FULL_NAME}?" || return 3
    exegol_cmd stop "$CONTAINER_NAME" 2>/dev/null || true
    exegol_cmd remove "$CONTAINER_NAME" -F 2>/dev/null || true
  fi

  # O --vpn com valor VAZIO e o ponto central desta arquitetura: ele ativa
  # NET_ADMIN, /dev/net/tun, net.ipv4.conf.all.src_valid_mark=1 e
  # net.ipv6.conf.all.disable_ipv6=0 SEM montar conf nenhum, deixando
  # /etc/wireguard gravavel dentro do container. Ver ContainerConfig.py:347
  # (if ParametersManager().vpn is not None) e :756-804 (enableVPN) do Exegol.
  info "Criando ${FULL_NAME} com capabilities de VPN..."
  exegol_cmd start "$CONTAINER_NAME" "$IMAGE_TAG" --vpn "" \
    || { erro "o exegol start falhou -- veja a saida acima"; return 1; }
  _conferir_capabilities
}

_conferir_capabilities() {
  local caps sysctls
  # Sem o || morrer, o set -e derrubaria o estagio com o erro cru do docker em
  # vez da mensagem que diz o que fazer.
  caps="$(docker inspect "$FULL_NAME" --format '{{.HostConfig.CapAdd}}' 2>/dev/null)" \
    || morrer "nao consegui inspecionar ${FULL_NAME} -- ele subiu?"
  sysctls="$(docker inspect "$FULL_NAME" --format '{{.HostConfig.Sysctls}}' 2>/dev/null)" \
    || morrer "nao consegui inspecionar ${FULL_NAME} -- ele subiu?"
  [[ "$caps" == *NET_ADMIN* ]] || morrer \
    "container sem NET_ADMIN -- o 'exegol start --vpn \"\"' nao fez o esperado"
  [[ "$sysctls" == *src_valid_mark* ]] || morrer \
    "container sem net.ipv4.conf.all.src_valid_mark -- o wg-quick vai falhar"
  ok "capabilities conferidas: NET_ADMIN + src_valid_mark"
}

_fixar_ip() {
  info "Fixando ${STATIC_IP} em ${NETWORK_NAME}..."
  exegol_cmd stop "$CONTAINER_NAME"
  local rede
  for rede in $(docker inspect "$FULL_NAME" \
      --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'); do
    docker network disconnect "$rede" "$FULL_NAME" 2>/dev/null || true
  done
  docker network connect --ip "$STATIC_IP" "$NETWORK_NAME" "$FULL_NAME" \
    || { erro "nao consegui fixar ${STATIC_IP} -- o endereco ja esta em uso nessa rede?"; return 1; }
  exegol_cmd start "$CONTAINER_NAME"
  ok "IP fixo: ${STATIC_IP}"
}

# /opt/my-resources dentro do container e bind mount de ~/.exegol/my-resources,
# entao o payload e instalado escrevendo no host. E o que elimina a pilha de
# 'docker exec ... tee' com heredoc aninhado da versao antiga.
_instalar_payload() {
  local dir_bin="${REAL_HOME}/.exegol/my-resources/bin"
  install -d -m 755 "$dir_bin"
  local arq
  for arq in killswitch-postup.sh mullvad-switch.py wgconf.py mullvad_api.py; do
    install -m 755 "${RAIZ_REPO}/payload/${arq}" "${dir_bin}/${arq}"
  done
  ok "payload instalado em ${dir_bin}"
}

# A copia VIVA do conf e a de dentro do container. A do host e semente e backup.
_conf_para_dentro() {
  docker exec "$FULL_NAME" install -d -m 700 /etc/wireguard
  docker exec -i "$FULL_NAME" sh -c 'umask 077; cat > /etc/wireguard/wg0.conf' \
    < "$MULLVAD_CONF"
  docker exec "$FULL_NAME" chmod 600 /etc/wireguard/wg0.conf
  docker exec "$FULL_NAME" install -d -m 755 /workspace/.mullvad
  ok "conf instalado em /etc/wireguard/wg0.conf dentro do container"
}

# Sem env vars: o mullvad-switch le tudo do state.json. Idempotente.
_alias_no_zshrc() {
  docker exec "$FULL_NAME" sh -c \
    'grep -v "^alias mullvad-switch=" /root/.zshrc > /root/.zshrc.novo \
      && mv /root/.zshrc.novo /root/.zshrc'
  docker exec "$FULL_NAME" sh -c \
    "printf \"alias mullvad-switch='python3 /opt/my-resources/bin/mullvad-switch.py'\n\" >> /root/.zshrc"
  ok "alias mullvad-switch instalado"
}
```

- [ ] **Step 2: Conferir a sintaxe**

Run: `bash -n lib/03-container.sh && echo SINTAXE_OK`
Expected: `SINTAXE_OK`

- [ ] **Step 3: Commit**

```bash
git add lib/03-container.sh
git commit -m "Estagio 3: rede dedicada, container com --vpn vazio, payload"
```

---

### Task 8: payload/killswitch-postup.sh — camada 1

**Files:**
- Create: `payload/killswitch-postup.sh`

**Interfaces:**
- Consumes: nada (roda dentro do container, chamado pelo `PostUp` que `wgconf.normalizar` injeta)
- Produces: escreve `/workspace/.mullvad/state.json` com `{endpoint_ip, endpoint_port, entry_hostname, exit_hostname, mode, ts}` — o contrato que `host-watcher.sh` (Task 9) le. Le opcionalmente as env vars `MULLVAD_MODO`, `MULLVAD_ENTRADA`, `MULLVAD_SAIDA`, exportadas pelo `mullvad-switch.py` (Task 11).

- [ ] **Step 1: Escrever payload/killswitch-postup.sh**

```bash
#!/bin/bash
# Camada 1 do kill switch. Roda DENTRO do container, chamado pelo PostUp do
# wg-quick. Le o Endpoint do wg0.conf dinamicamente, entao serve pra qualquer
# relay sem precisar editar este arquivo quando o servidor trocar.
#
# As politicas DROP nao sao removidas quando o wg0 cai -- e isso que faz a queda
# do tunel ser fail-closed aqui dentro.
set -euo pipefail

CONF=/etc/wireguard/wg0.conf
DIR_ESTADO=/workspace/.mullvad
ARQ_ESTADO="${DIR_ESTADO}/state.json"

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
  iptables  -P INPUT   DROP 2>/dev/null || true
  iptables  -P OUTPUT  DROP 2>/dev/null || true
  iptables  -P FORWARD DROP 2>/dev/null || true
  ip6tables -P INPUT   DROP 2>/dev/null || true
  ip6tables -P OUTPUT  DROP 2>/dev/null || true
  ip6tables -P FORWARD DROP 2>/dev/null || true
  exit 1
}

# --- IPv4: tabela inteira de uma vez via iptables-restore. Sem essa troca
# atomica existiria uma janela entre um "-F" e o "-P ... DROP" seguinte onde a
# policy ainda e a padrao do Docker (ACCEPT) e nenhuma regra esta no lugar --
# qualquer pacote emitido nessa janela sairia sem passar por regra nenhuma.
# iptables-restore sem --noflush troca a tabela inteira numa unica transacao:
# sem flush em separado, sem janela, um processo em vez de uma duzia.
if ! iptables-restore <<FIM
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
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
if ! ip6tables-restore <<FIM
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

echo "nameserver 10.64.0.1" > /etc/resolv.conf

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
```

- [ ] **Step 2: Conferir a sintaxe e o JSON gerado**

O script exige root e iptables, entao teste so a geracao do state.json isolando esse trecho:

```bash
bash -n payload/killswitch-postup.sh && echo SINTAXE_OK
mkdir -p /tmp/ks/.mullvad
MULLVAD_ENTRADA=se-got-wg-007 MULLVAD_SAIDA=br-sao-wg-101 MULLVAD_MODO=multihop \
EP_HOST=1.2.3.4 EP_PORT=3101 ARQ_ESTADO=/tmp/ks/.mullvad/state.json bash -c '
cat > "${ARQ_ESTADO}.tmp" <<FIM
{
  "endpoint_ip": "${EP_HOST}",
  "endpoint_port": ${EP_PORT},
  "entry_hostname": "${MULLVAD_ENTRADA:-}",
  "exit_hostname": "${MULLVAD_SAIDA:-}",
  "mode": "${MULLVAD_MODO:-desconhecido}",
  "ts": $(date +%s)
}
FIM
mv "${ARQ_ESTADO}.tmp" "$ARQ_ESTADO"'
python3 -c 'import json; d=json.load(open("/tmp/ks/.mullvad/state.json")); print(d); assert d["endpoint_port"]==3101 and d["mode"]=="multihop"; print("JSON_OK")'
rm -rf /tmp/ks
```

Expected: `SINTAXE_OK`, o dict impresso, e `JSON_OK`.

- [ ] **Step 3: Commit**

```bash
git add payload/killswitch-postup.sh
git commit -m "Camada 1 do kill switch: iptables no container e state.json atomico"
```

---

### Task 9: payload/host-backstop.sh e host-watcher.sh — camada 2

**Files:**
- Create: `payload/host-backstop.sh`
- Create: `payload/host-watcher.sh`
- Create: `tests/test_backstop.sh`

**Interfaces:**
- Consumes: o contrato do `state.json` de Task 8
- Produces:
  - `host-backstop.sh <chain> <ip_container> fechado`
  - `host-backstop.sh <chain> <ip_container> aberto <endpoint_ip> <porta>`
  - `host-watcher.sh <chain> <ip_container> <container> <arq_state> [caminho_backstop]`
  - Ambos respeitam `KS_DRY_RUN=1`; o watcher respeita `KS_INTERVALO` (padrao 1)

- [ ] **Step 1: Escrever os testes que devem falhar**

`tests/test_backstop.sh`. O ponto critico e a **ordem** das regras: em iptables a primeira que casa ganha, entao um `RETURN` depois do `DROP` seria um kill switch que nao protege nada.

```bash
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `bash tests/run.sh tests/test_backstop.sh`
Expected: FAIL — todas as afirmacoes falham, `host-backstop.sh: No such file or directory`

- [ ] **Step 3: Escrever payload/host-backstop.sh**

```bash
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

# No dry-run, imprime o comando. Um "-C" em dry-run devolve 1 de proposito, para
# que o caminho `ipt -C ... || ipt -I ...` percorra os DOIS ramos e o teste
# exercite a MESMA estrutura que roda de verdade. Sem isso o dry-run divergiria
# do caminho real e os testes verificariam uma ficcao -- a logica de
# idempotencia do gancho no DOCKER-USER nunca seria testada.
ipt() {
  if [[ "$DRY" == "1" ]]; then
    printf 'iptables %s\n' "$*"
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
# Mesma estrutura em dry-run e em execucao real (ver o comentario do ipt()):
# o -C decide, e so insere se ainda nao estiver la.
ipt -C DOCKER-USER -j "$CHAIN" 2>/dev/null || ipt -I DOCKER-USER 1 -j "$CHAIN"
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `bash tests/run.sh tests/test_backstop.sh`
Expected: PASS — 15 passaram, 0 falharam

- [ ] **Step 5: Escrever payload/host-watcher.sh**

```bash
#!/usr/bin/env bash
# Camada 2, parte viva: mantem o backstop sincronizado com o tunel do container.
#
# Le o state.json como ARQUIVO LOCAL (o /workspace do container e bind mount),
# e por isso NAO precisa de docker exec no loop -- diferente da versao antiga,
# que spawnava um processo dentro do container a cada segundo.
#
# O docker inspect e necessario: um container que morre sem rodar o PreDown
# deixa o state.json para tras, e sem checar Running o watcher manteria a brecha
# UDP aberta para um IP fixo que outro container poderia reusar sem tunel.
#
# Comeca fechado. Qualquer duvida ou falha -> fechado.
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

# Ecoa "ip porta" se o state.json tem endpoint utilizavel; nada caso contrario.
ler_endpoint() {
  [[ -r "$ARQ_ESTADO" ]] || return 0
  ARQ="$ARQ_ESTADO" python3 <<'PY' 2>/dev/null || true
import json, os
try:
    d = json.load(open(os.environ["ARQ"]))
except Exception:
    raise SystemExit(0)
ip, porta = d.get("endpoint_ip"), d.get("endpoint_port")
if ip and porta:
    print("%s %s" % (ip, porta))
PY
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
```

- [ ] **Step 6: Exercitar o watcher com um backstop de mentira**

Isso testa a maquina de estados completa sem root e sem docker de verdade: um
`backstop` falso que so registra as chamadas, e um `docker` falso no PATH cuja
resposta a gente controla.

```bash
mkdir -p /tmp/wt/.mullvad /tmp/wt/bin
printf '#!/usr/bin/env bash\necho "$*" >> /tmp/wt/chamadas.log\n' > /tmp/wt/backstop-falso.sh
printf '#!/usr/bin/env bash\ncat /tmp/wt/running\n' > /tmp/wt/bin/docker
chmod +x /tmp/wt/backstop-falso.sh /tmp/wt/bin/docker

# Caso 1: container ausente -> fechado, e SEM repetir a cada tick.
echo false > /tmp/wt/running
: > /tmp/wt/chamadas.log
KS_INTERVALO=0.2 timeout 1 bash payload/host-watcher.sh \
  TESTE-KS 172.30.30.10 x /tmp/wt/.mullvad/state.json /tmp/wt/backstop-falso.sh
echo "--- caso 1 ---"; cat /tmp/wt/chamadas.log

# Caso 2: container de pe com state.json valido -> abre.
echo true > /tmp/wt/running
printf '{"endpoint_ip":"1.2.3.4","endpoint_port":3494,"mode":"multihop","ts":1}' \
  > /tmp/wt/.mullvad/state.json
: > /tmp/wt/chamadas.log
KS_INTERVALO=0.2 timeout 1 bash payload/host-watcher.sh \
  TESTE-KS 172.30.30.10 x /tmp/wt/.mullvad/state.json /tmp/wt/backstop-falso.sh
echo "--- caso 2 ---"; cat /tmp/wt/chamadas.log

# Caso 3: o tunel cai no meio (o PreDown apaga o state.json) -> volta a fechar.
: > /tmp/wt/chamadas.log
( sleep 0.5; rm -f /tmp/wt/.mullvad/state.json ) &
KS_INTERVALO=0.2 timeout 1.5 bash payload/host-watcher.sh \
  TESTE-KS 172.30.30.10 x /tmp/wt/.mullvad/state.json /tmp/wt/backstop-falso.sh
echo "--- caso 3 ---"; cat /tmp/wt/chamadas.log
rm -rf /tmp/wt
```

Expected, exatamente:

```
--- caso 1 ---
TESTE-KS 172.30.30.10 fechado
--- caso 2 ---
TESTE-KS 172.30.30.10 fechado
TESTE-KS 172.30.30.10 aberto 1.2.3.4 3494
--- caso 3 ---
TESTE-KS 172.30.30.10 fechado
TESTE-KS 172.30.30.10 aberto 1.2.3.4 3494
TESTE-KS 172.30.30.10 fechado
```

Uma linha por tick em qualquer caso significaria que o watcher esta reaplicando
a chain sem necessidade. E a ausencia do `fechado` final no caso 3 significaria
que a queda do tunel deixou a brecha UDP aberta -- o bug que a camada 2 existe
para nao ter.

- [ ] **Step 7: Commit**

```bash
git add payload/host-backstop.sh payload/host-watcher.sh tests/test_backstop.sh
git commit -m "Camada 2 do kill switch: backstop com estados aberto/fechado e watcher"
```

---

### Task 10: lib/04-killswitch.sh — migracao, instalacao e systemd

**Files:**
- Create: `lib/04-killswitch.sh`

**Interfaces:**
- Consumes: `info ok aviso morrer confirmar nome_chain nome_unit caminho_state RAIZ_REPO REAL_HOME` (Tasks 2 e 5), os scripts de Task 9
- Produces: `estagio_killswitch()`; instala `/usr/local/sbin/exegol-killswitch-backstop.sh` e `/usr/local/sbin/exegol-<name>-killswitch-watcher.sh`; cria e habilita `exegol-<name>-killswitch-watcher.service`

- [ ] **Step 1: Escrever lib/04-killswitch.sh**

```bash
#!/usr/bin/env bash
# lib/04-killswitch.sh -- estagio 4: camada 2 no host.
# Migra a instalacao antiga, instala os scripts e a unica unit systemd.
# Nao executa nada ao ser sourceado.
set -euo pipefail

BACKSTOP_INSTALADO="/usr/local/sbin/exegol-killswitch-backstop.sh"

estagio_killswitch() {
  _migrar_instalacao_antiga
  _instalar_scripts_host
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
    systemctl daemon-reload
    ok "Instalacao antiga removida"
  fi
}

_instalar_scripts_host() {
  install -m 755 -o root -g root \
    "${RAIZ_REPO}/payload/host-backstop.sh" "$BACKSTOP_INSTALADO"
  install -m 755 -o root -g root \
    "${RAIZ_REPO}/payload/host-watcher.sh" \
    "/usr/local/sbin/exegol-${CONTAINER_NAME}-killswitch-watcher.sh"
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

  cat > "/etc/systemd/system/${unit}" <<FIM
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

  # daemon-reload + enable NAO reinicia uma unit que ja esta ativa: verificado
  # empiricamente, o PID nao muda depois de reescrever o arquivo da unit. Pior,
  # `systemctl show -p ExecStart` passa a reportar o valor NOVO enquanto o
  # processo rodando ainda usa o antigo -- ele mente sobre o que esta em
  # execucao. Sem o restart, rerodar este estagio depois de mudar --ip ou --name
  # deixaria o watcher protegendo o IP antigo, em silencio.
  systemctl daemon-reload
  systemctl enable "$unit"
  systemctl restart "$unit"
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
```

- [ ] **Step 2: Conferir a sintaxe**

Run: `bash -n lib/04-killswitch.sh && echo SINTAXE_OK`
Expected: `SINTAXE_OK`

- [ ] **Step 3: Commit**

```bash
git add lib/04-killswitch.sh
git commit -m "Estagio 4: migracao da instalacao antiga e unica unit systemd"
```

---

### Task 11: payload/mullvad-switch.py — troca de relay

Requer os achados de Task 1 Steps 3 e 4 (caminho do `fzf`, se single-hop funciona). Se single-hop falhou, remova o modo `singlehop` do menu e registre o motivo no docstring.

**Files:**
- Create: `payload/mullvad-switch.py`

**Interfaces:**
- Consumes: `wgconf` (Task 3) e `mullvad_api` (Task 4), ambos em `/opt/my-resources/bin/`; o `state.json` de Task 8
- Produces: o executavel que o alias `mullvad-switch` chama dentro do container

- [ ] **Step 1: Escrever payload/mullvad-switch.py**

```python
#!/usr/bin/env python3
"""Troca o relay Mullvad ativo, de dentro do container.

Autonomo: reescreve /etc/wireguard/wg0.conf e reconecta sem envolver o host. O
PostUp reaplica a camada 1 do kill switch e reescreve o state.json; o watcher do
host reage em ate 1 segundo. Nao existe mais protocolo request/response.

Rollback: guarda o conf anterior e, se nao houver handshake dentro de
ESPERA_HANDSHAKE segundos, volta pra ele e reconecta. Uma troca que falha nao
deixa o container sem internet.

O modo rapido NAO tem relay chumbado: reusa a entrada que estiver no state.json.
"""
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mullvad_api as api
import wgconf

CONF = "/etc/wireguard/wg0.conf"
CONF_BACKUP = "/etc/wireguard/wg0.conf.rollback"
ARQ_ESTADO = "/workspace/.mullvad/state.json"
ESPERA_HANDSHAKE = 10

AMARELO = "\033[38;2;255;213;36m"
CINZA = "\033[38;2;108;137;168m"
VERMELHO = "\033[31m"
VERDE = "\033[32m"
NEGRITO = "\033[1m"
RESET = "\033[0m"


def diga(msg):
    print(msg)


def erro(msg):
    print("%s[-]%s %s" % (VERMELHO, RESET, msg), file=sys.stderr)


def ok(msg):
    print("%s[+]%s %s" % (VERDE, RESET, msg))


def banner():
    print("\n%s%s  M U L L V A D   S W I T C H  %s\n" % (NEGRITO, AMARELO, RESET))


def ler_estado():
    try:
        with open(ARQ_ESTADO) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def achar_fzf():
    """Resolve o fzf sem chumbar caminho. None -> cai pro menu numerado."""
    achado = shutil.which("fzf")
    if achado:
        return achado
    conhecido = "/opt/tools/fzf/bin/fzf"
    return conhecido if os.access(conhecido, os.X_OK) else None


FZF = achar_fzf()


def escolher(opcoes, titulo):
    """Escolhe um item. opcoes: lista de (rotulo, valor). None se cancelou."""
    if not opcoes:
        return None
    if FZF:
        entrada = "\n".join(
            "%d\t%s" % (i, rotulo) for i, (rotulo, _) in enumerate(opcoes)
        )
        proc = subprocess.run(
            [FZF, "--layout=reverse", "--height=90%", "--border=rounded",
             "--delimiter=\t", "--with-nth=2", "--header=ESC cancela | " + titulo,
             "--prompt=%s> " % titulo],
            input=entrada, capture_output=True, text=True,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        return opcoes[int(proc.stdout.split("\t", 1)[0])][1]

    print("\n%s%s%s\n" % (NEGRITO, titulo, RESET))
    for i, (rotulo, _) in enumerate(opcoes, 1):
        print("  %3d) %s" % (i, rotulo))
    try:
        bruto = input("\n%s> " % titulo).strip()
    except (EOFError, KeyboardInterrupt):
        return None
    if not bruto.isdigit() or not (1 <= int(bruto) <= len(opcoes)):
        return None
    return opcoes[int(bruto) - 1][1]


def escolher_relay(relays, titulo, excluir=None):
    grupos = api.agrupar_por_pais(relays)
    while True:
        pais = escolher(
            [("%s  (%d relays)" % (p, len(grupos[p])), p) for p in sorted(grupos)],
            titulo + " / pais",
        )
        if pais is None:
            return None
        candidatos = [r for r in grupos[pais] if not excluir or r["hostname"] != excluir]
        escolhido = escolher(
            [("%s  %s" % (r["hostname"], r["cidade"]), r) for r in candidatos],
            titulo + " / " + pais,
        )
        if escolhido is not None:
            return escolhido
        # ESC no relay volta pro pais, em vez de cancelar tudo.


def wg(*args):
    return subprocess.run(["wg-quick", *args], capture_output=True, text=True)


def tem_handshake():
    """So para exibicao no status. NAO use isto para validar uma troca.

    O WireGuard e preguicoso: nao faz handshake ate haver dado para enviar.
    Verificado em campo -- um tunel funcional recem-subido fica com
    latest-handshakes em 0 indefinidamente enquanto ocioso, e so handshakeia
    quando o primeiro pacote sai. Validar uma troca por handshake faria
    rollback de TODA troca bem-sucedida.
    """
    p = subprocess.run(["wg", "show", "wg0", "latest-handshakes"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return False
    for linha in p.stdout.strip().splitlines():
        partes = linha.split()
        if len(partes) == 2 and partes[1].isdigit() and int(partes[1]) > 0:
            return True
    return False


def sondar_saida(saida_esperada=None):
    """Sonda a conectividade pelo tunel. Devolve (ok, hostname_de_saida).

    E esta funcao que valida uma troca, nao o handshake: o curl GERA o trafego
    que dispara o handshake, e de quebra confirma ponta a ponta que a saida e a
    esperada. Conferir o hostname importa porque, se o proprio host estiver
    numa VPN Mullvad, um container sem tunel algum ainda responde
    mullvad_exit_ip: true -- verificado em campo. O hostname distingue.
    """
    p = subprocess.run(
        ["curl", "-s", "--max-time", "8", "https://am.i.mullvad.net/json"],
        capture_output=True, text=True,
    )
    try:
        d = json.loads(p.stdout)
    except ValueError:
        return False, None
    host = d.get("mullvad_exit_ip_hostname")
    if not d.get("mullvad_exit_ip"):
        return False, host
    if saida_esperada and host != saida_esperada:
        return False, host
    return True, host


def aplicar(pubkey, ip, porta, modo, entrada_hostname, saida_hostname, estado_anterior):
    """Reescreve o conf, reconecta e confirma handshake. Rollback se falhar.

    estado_anterior e o state.json lido antes da troca. Ele existe porque o
    rollback precisa RESTAURAR as env vars MULLVAD_* junto com o conf: o PostUp
    le essas vars para escrever entry/exit/mode no state.json, e sem restaurar
    elas um rollback deixa o state.json descrevendo o relay que falhou. O
    endpoint em si vem do conf e fica correto, entao o backstop do host nao e
    afetado -- mas o "Ver status" mente e, pior, o modo rapido reusa a entrada
    que acabou de falhar, acumulando o erro.
    """
    with open(CONF) as f:
        antes = f.read()
    shutil.copyfile(CONF, CONF_BACKUP)
    os.chmod(CONF_BACKUP, 0o600)

    with open(CONF, "w") as f:
        f.write(wgconf.trocar_peer(antes, pubkey, ip, porta))

    # O PostUp le estas env vars para gravar entrada/saida/modo no state.json.
    os.environ["MULLVAD_MODO"] = modo
    os.environ["MULLVAD_ENTRADA"] = entrada_hostname
    os.environ["MULLVAD_SAIDA"] = saida_hostname

    wg("down", "wg0")
    subida = wg("up", "wg0")
    if subida.returncode != 0:
        erro("wg-quick up falhou:\n" + subida.stderr.strip())
        return rollback(estado_anterior)

    # O Ctrl-C aqui precisa ser tratado: a espera dura ate 10s, tempo de sobra
    # para alguem desistir -- e nesse ponto o conf novo ja esta aplicado e o wg0
    # de pe sem passar trafego. Sem esta guarda o script morre deixando o
    # container fail-closed sem internet e sem rollback.
    # Sondar conectividade, nao handshake: o curl gera o trafego que faz o
    # WireGuard handshakear. Esperar por handshake sozinho faria rollback de
    # toda troca que deu certo (verificado em campo).
    try:
        diga("%sconfirmando a conexao (ate %ds)...%s" % (CINZA, ESPERA_HANDSHAKE, RESET))
        ultimo_host = None
        for _ in range(ESPERA_HANDSHAKE):
            ok_saida, ultimo_host = sondar_saida(saida_hostname)
            if ok_saida:
                return True
            time.sleep(1)
    except KeyboardInterrupt:
        erro("interrompido durante a confirmacao -- voltando pro relay anterior")
        return rollback(estado_anterior)

    if ultimo_host:
        erro("saindo por %s em vez de %s -- o tunel nao subiu como esperado"
             % (ultimo_host, saida_hostname))
    else:
        erro("sem conectividade em %ds -- o relay nao respondeu" % ESPERA_HANDSHAKE)
    return rollback(estado_anterior)


def rollback(estado_anterior=None):
    # Restaura as env vars antes do wg up, senao o PostUp grava no state.json o
    # relay que falhou em vez do que voltou a rodar.
    anterior = estado_anterior or {}
    os.environ["MULLVAD_MODO"] = anterior.get("mode") or "desconhecido"
    os.environ["MULLVAD_ENTRADA"] = anterior.get("entry_hostname") or ""
    os.environ["MULLVAD_SAIDA"] = anterior.get("exit_hostname") or ""
    if not os.path.exists(CONF_BACKUP):
        erro("nao ha backup pra voltar. O tunel esta fora.")
        return False
    diga("%svoltando pro relay anterior...%s" % (AMARELO, RESET))
    shutil.copyfile(CONF_BACKUP, CONF)
    wg("down", "wg0")
    if wg("up", "wg0").returncode == 0:
        ok("rollback feito: o relay anterior esta de volta")
    else:
        erro("o rollback tambem falhou. O tunel esta fora -- rode 'wg-quick up wg0'")
    return False


def mostrar_saida():
    p = subprocess.run(
        ["curl", "-s", "--max-time", "10", "https://am.i.mullvad.net/json"],
        capture_output=True, text=True,
    )
    try:
        d = json.loads(p.stdout)
    except ValueError:
        erro("nao consegui confirmar a saida em am.i.mullvad.net")
        return
    pela_mullvad = d.get("mullvad_exit_ip")
    print("\n  IP de saida ......... %s" % d.get("ip", "?"))
    print("  Localizacao ......... %s, %s" % (d.get("city", "?"), d.get("country", "?")))
    print("  Saindo pela Mullvad . %s\n" % (
        "%ssim%s" % (VERDE, RESET) if pela_mullvad else "%sNAO%s" % (VERMELHO, RESET)
    ))


def status(estado, relays):
    entrada = estado.get("entry_hostname") or "?"
    saida = estado.get("exit_hostname") or "?"
    print("\n  Modo ....... %s" % (estado.get("mode") or "?"))
    print("  Entrada .... %s" % entrada)
    print("  Saida ...... %s" % saida)
    print("  Endpoint ... %s:%s" % (
        estado.get("endpoint_ip", "?"), estado.get("endpoint_port", "?")
    ))
    print("  Handshake .. %s" % ("sim" if tem_handshake() else "NAO"))
    mostrar_saida()


def main():
    if os.geteuid() != 0:
        erro("roda como root dentro do container")
        return 1

    banner()
    estado = ler_estado()
    try:
        relays = api.buscar_relays()
    except api.ErroMullvad as e:
        erro(str(e))
        return 1
    diga("%s%d relays disponiveis.%s" % (CINZA, len(relays), RESET))

    entrada_atual = api.achar_por_hostname(relays, estado.get("entry_hostname") or "")

    opcoes = []
    if entrada_atual:
        opcoes.append(
            ("Trocar so a saida  (mantem a entrada %s)" % entrada_atual["hostname"],
             "rapido")
        )
    opcoes.append(("Multihop completo  (escolher entrada e saida)", "multihop"))
    opcoes.append(("Single-hop  (um relay so)", "singlehop"))
    opcoes.append(("Ver status", "status"))

    modo = escolher(opcoes, "modo")
    if modo is None:
        diga("cancelado.")
        return 1

    if modo == "status":
        status(estado, relays)
        return 0

    if modo == "singlehop":
        relay = escolher_relay(relays, "SAIDA")
        if relay is None:
            diga("cancelado.")
            return 1
        ip, porta, pubkey = api.endpoint_singlehop(relay)
        alvo = (pubkey, ip, porta, "singlehop", relay["hostname"], relay["hostname"])
        diga("\nSingle-hop -> %s (%s, %s)" % (
            relay["hostname"], relay["cidade"], relay["pais"]))
    else:
        if modo == "rapido":
            entrada = entrada_atual
        else:
            entrada = escolher_relay(relays, "ENTRADA")
            if entrada is None:
                diga("cancelado.")
                return 1
        saida = escolher_relay(relays, "SAIDA", excluir=entrada["hostname"])
        if saida is None:
            diga("cancelado.")
            return 1
        try:
            ip, porta, pubkey = api.endpoint_multihop(entrada, saida)
        except api.ErroMullvad as e:
            erro(str(e))
            return 1
        alvo = (pubkey, ip, porta, "multihop", entrada["hostname"], saida["hostname"])
        diga("\nMultihop: %s -> %s (%s, %s)" % (
            entrada["hostname"], saida["hostname"], saida["cidade"], saida["pais"]))

    if not aplicar(*alvo):
        return 1
    ok("conectado")
    mostrar_saida()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Conferir sintaxe e imports**

```bash
python3 -m py_compile payload/mullvad-switch.py && echo COMPILA_OK
cd payload && python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('ms', 'mullvad-switch.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print('achar_fzf ->', m.achar_fzf())
print('escolher([], t) ->', m.escolher([], 'x'))
print('ler_estado (sem arquivo) ->', m.ler_estado())
"; cd ..
```

Expected: `COMPILA_OK`, e as tres chamadas retornando sem estourar (`achar_fzf` provavelmente `None` no host, `escolher([])` -> `None`, `ler_estado()` -> `{}`).

- [ ] **Step 3: Commit**

```bash
git add payload/mullvad-switch.py
git commit -m "mullvad-switch autonomo: rollback, modo rapido sem relay chumbado"
```

---

### Task 12: lib/05-verify.sh — teste de vazamento

**Files:**
- Create: `lib/05-verify.sh`

**Interfaces:**
- Consumes: `info ok erro aviso nome_chain` (Tasks 2 e 5), o container e a chain de pe
- Produces: `estagio_verify()` — status 0 se tudo passou, 1 se algum item falhou

- [ ] **Step 1: Escrever lib/05-verify.sh**

```bash
#!/usr/bin/env bash
# lib/05-verify.sh -- estagio 5: verificacao e teste de vazamento real.
#
# A verificacao da versao antiga so confirmava que a VPN estava de pe, o que nao
# testa kill switch nenhum. Aqui o tunel e derrubado de proposito para provar que
# nada sai sem ele.
set -euo pipefail

FALHAS_VERIFY=0
# Contador separado: so os itens de vazamento (camadas 1 e 2, IPv6) justificam a
# mensagem de "o kill switch nao esta protegendo".
FALHAS_VAZAMENTO=0

_passa() { printf '  %s[PASSA]%s %s\n' "$VERDE" "$RESET" "$1"; }
_falha() { printf '  %s[FALHA]%s %s\n' "$VERMELHO" "$RESET" "$1"; FALHAS_VERIFY=$((FALHAS_VERIFY + 1)); }
# Para os itens de vazamento: conta nos dois lugares.
_falha_vazamento() { _falha "$1"; FALHAS_VAZAMENTO=$((FALHAS_VAZAMENTO + 1)); }

_no_container() { docker exec "$FULL_NAME" "$@"; }

estagio_verify() {
  FALHAS_VERIFY=0
  local chain
  chain="$(nome_chain "$CONTAINER_NAME")"

  docker container inspect "$FULL_NAME" --format '{{.State.Running}}' 2>/dev/null \
    | grep -qx true || morrer "o container ${FULL_NAME} nao esta rodando"

  printf '\n%sVerificacao%s\n\n' "$NEGRITO" "$RESET"

  # 1) handshake -- DEPOIS de gerar trafego, nunca antes.
  # O WireGuard e preguicoso: um tunel funcional ocioso fica com
  # latest-handshakes em 0 indefinidamente (verificado em campo). Checar antes
  # de qualquer trafego reprovaria um tunel perfeitamente bom.
  _no_container curl -s --max-time 8 -o /dev/null https://am.i.mullvad.net/json 2>/dev/null || true
  if _no_container wg show wg0 latest-handshakes 2>/dev/null | awk '{exit !($2 > 0)}'; then
    _passa "handshake do wg0 estabelecido (apos gerar trafego)"
  else
    _falha "sem handshake no wg0 mesmo apos gerar trafego"
  fi

  # 2) saindo pela Mullvad -- E por um tunel PROPRIO, nao pelo do host
  #
  # ATENCAO: "mullvad_exit_ip: true" sozinho e um FALSO POSITIVO se o host
  # tambem estiver na Mullvad. Verificado neste host: um container com wg0
  # inexistente e iptables em ACCEPT reportou true, porque o trafego dele saiu
  # pelo host, que estava na Mullvad. O comparativo com a saida do HOST e o que
  # torna este item honesto: se os dois IPs sao iguais, o container NAO esta
  # usando tunel proprio -- esta pegando carona.
  local json json_host ip_container ip_host
  json="$(_no_container curl -s --max-time 20 https://am.i.mullvad.net/json || echo '{}')"
  json_host="$(curl -s --max-time 20 https://am.i.mullvad.net/json || echo '{}')"
  ip_container="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ip",""))' 2>/dev/null || true)"
  ip_host="$(printf '%s' "$json_host" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ip",""))' 2>/dev/null || true)"
  if [[ -n "$ip_container" && "$ip_container" == "$ip_host" ]]; then
    # Nao afirmar "saindo pela Mullvad" aqui: este ramo tambem alcanca o caso em
    # que o host nao esta em VPN alguma e os dois compartilham o IP publico cru.
    _falha "o container sai pelo MESMO IP do host (${ip_host}) -- nao ha tunel proprio"
  elif printf '%s' "$json" | grep -q '"mullvad_exit_ip":true'; then
    _passa "saindo pela Mullvad: $(printf '%s' "$json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s (%s, %s)" % (d.get("ip"), d.get("city"), d.get("country")))')"
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

  printf '\n%sTeste de vazamento -- derrubando o tunel de proposito%s\n\n' \
    "$NEGRITO" "$RESET"

  local pacotes_antes pacotes_depois
  pacotes_antes="$(_contador_drop "$chain")"

  _no_container wg-quick down wg0 >/dev/null 2>&1 || true

  # 5) camada 1: nada sai de dentro do container
  if _no_container curl -s --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
    _falha_vazamento "CAMADA 1 FUROU: o container acessou a internet com o tunel fora"
  else
    _passa "camada 1: sem tunel, nada sai do container"
  fi

  # 6) camada 2: prova ATIVA, nao estrutural.
  #
  # Ler o contador duas vezes e conferir que as leituras nao vieram vazias NAO
  # prova nada: uma chain que existe mas esta orfa (sem gancho no DOCKER-USER)
  # devolve "0" nas duas e passaria. Pior ainda, a camada 1 acabou de ser
  # provada no item 5 -- e e' exatamente por funcionar que ela impede qualquer
  # pacote de chegar a camada 2. Com a camada 1 de pe, o contador do backstop
  # NUNCA sobe. As duas camadas nao podem ser demonstradas pela mesma sonda.
  #
  # Entao provamos a camada 2 simulando o que ela existe para cobrir: a camada 1
  # comprometida de dentro do container (um root ali pode zerar as regras). O
  # wg-quick up do item 7 reaplica a camada 1 pelo PostUp; e se ele falhar, o
  # postup e chamado direto no caminho de erro, para nao deixar o container sem
  # camada 1 nenhuma.
  #
  # O sleep da tempo ao watcher (tick de 1s) de convergir para o estado fechado
  # depois de o PreDown ter apagado o state.json.
  sleep 2
  if ! iptables -C DOCKER-USER -j "$chain" 2>/dev/null; then
    _falha_vazamento "CAMADA 2 AUSENTE: a chain ${chain} nao esta ancorada no DOCKER-USER"
  else
    pacotes_antes="$(_contador_drop "$chain")"
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
    sleep 3
    json="$(_no_container curl -s --max-time 20 https://am.i.mullvad.net/json || echo '{}')"
    if printf '%s' "$json" | grep -q '"mullvad_exit_ip":true'; then
      _passa "tunel restaurado e saindo pela Mullvad"
    else
      _falha "o tunel voltou mas nao esta saindo pela Mullvad"
    fi
  else
    _falha "nao consegui restaurar o tunel -- rode: docker exec ${FULL_NAME} wg-quick up wg0"
    # O item 6 zerou as regras do container de proposito e contava com o PostUp
    # do wg-quick up para reaplica-las. Como o up falhou, reaplica direto: sem
    # isso o container ficaria sem camada 1 nenhuma depois de uma "verificacao".
    aviso "Reaplicando a camada 1 na mao, ja que o tunel nao subiu..."
    _no_container /opt/my-resources/bin/killswitch-postup.sh >/dev/null 2>&1 \
      || _falha "nao consegui reaplicar a camada 1 -- o container esta protegido apenas pela camada 2"
  fi

  printf '\n'
  if (( FALHAS_VERIFY == 0 )); then
    ok "Tudo passou. O kill switch esta protegendo nas duas camadas."
    return 0
  fi
  erro "${FALHAS_VERIFY} verificacao(oes) falharam."
  # A frase alarmante so aparece quando um item de VAZAMENTO falhou. Imprimi-la
  # em qualquer falha (um DNS mal configurado, por exemplo) gastaria o sinal.
  if (( FALHAS_VAZAMENTO > 0 )); then
    erro "FALHA EM ITEM DE VAZAMENTO: o kill switch NAO esta protegendo."
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
```

- [ ] **Step 2: Conferir a sintaxe**

Run: `bash -n lib/05-verify.sh && echo SINTAXE_OK`
Expected: `SINTAXE_OK`

- [ ] **Step 3: Commit**

```bash
git add lib/05-verify.sh
git commit -m "Estagio 5: verificacao com teste de vazamento nas duas camadas"
```

---

### Task 13: install.sh, desinstalacao, e remocao do script antigo

**Files:**
- Create: `install.sh`
- Create: `lib/06-uninstall.sh`
- Delete: `exegol-mullvad-killswitch-setup.sh`

**Interfaces:**
- Consumes: todos os `estagio_*()` das Tasks 5, 6, 7, 10, 12
- Produces: as variaveis globais que os estagios consomem (`CONTAINER_NAME FULL_NAME IMAGE_TAG NETWORK_NAME SUBNET GATEWAY STATIC_IP MULLVAD_CONF ASSUME_SIM CONF_INFORMADO`) e `estagio_desinstalar()`

- [ ] **Step 1: Escrever lib/06-uninstall.sh**

```bash
#!/usr/bin/env bash
# lib/06-uninstall.sh -- remove tudo que o instalador colocou no host.
# Nao executa nada ao ser sourceado.
set -euo pipefail

estagio_desinstalar() {
  local unit chain
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
    exegol_cmd stop "$CONTAINER_NAME" 2>/dev/null || true
    exegol_cmd remove "$CONTAINER_NAME" -F 2>/dev/null || true
  fi

  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    info "Removendo a rede ${NETWORK_NAME}..."
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || \
      aviso "nao consegui remover a rede (algum container ainda usa?)"
  fi

  ok "Desinstalado."

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
}
```

- [ ] **Step 2: Escrever install.sh**

```bash
#!/usr/bin/env bash
# install.sh -- instalador plug and play: Exegol + Mullvad com kill switch em
# duas camadas. Menu interativo; cada estagio e idempotente e rodavel isolado.
#
# Uso: sudo bash install.sh [opcoes]
set -euo pipefail

RAIZ_INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${RAIZ_INSTALL}/lib/common.sh"
for _lib in 01-deps 02-mullvad 03-container 04-killswitch 05-verify 06-uninstall; do
  # shellcheck disable=SC1090
  source "${RAIZ_INSTALL}/lib/${_lib}.sh"
done

CONTAINER_NAME="${CONTAINER_NAME:-mullvad}"
IMAGE_TAG="${IMAGE_TAG:-free}"
NETWORK_NAME="${NETWORK_NAME:-exegol-vpn-net}"
SUBNET="${SUBNET:-172.30.30.0/24}"
GATEWAY="${GATEWAY:-172.30.30.1}"
STATIC_IP="${STATIC_IP:-172.30.30.10}"
ASSUME_SIM=0
CONF_INFORMADO=""
ESTAGIO_UNICO=""
DESINSTALAR=0

uso() {
  cat <<FIM
Uso: sudo bash install.sh [opcoes]

Sem opcao nenhuma, abre o menu interativo.

  --yes                assume os padroes e nao pergunta nada. Exige --conf.
  --conf PATH          usa este .conf da Mullvad (pula a escolha do estagio 2)
  --stage NOME         roda um estagio so: deps, mullvad, container,
                       killswitch, verify
  --uninstall          desinstala sem passar pelo menu
  --name NOME          nome do container, sem o prefixo exegol- (padrao: mullvad)
  --image TAG          tag da imagem Exegol (padrao: free)
  --network NOME       rede docker dedicada (padrao: exegol-vpn-net)
  --subnet CIDR        subnet da rede (padrao: 172.30.30.0/24)
  --ip IP              IP fixo do container (padrao: 172.30.30.10)
  -h, --help           mostra esta ajuda
FIM
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)       ASSUME_SIM=1; shift ;;
    --conf)      CONF_INFORMADO="${2:?--conf exige um caminho}"; shift 2 ;;
    --stage)     ESTAGIO_UNICO="${2:?--stage exige um nome}"; shift 2 ;;
    --uninstall) DESINSTALAR=1; shift ;;
    --name)      CONTAINER_NAME="${2:?}"; shift 2 ;;
    --image)     IMAGE_TAG="${2:?}"; shift 2 ;;
    --network)   NETWORK_NAME="${2:?}"; shift 2 ;;
    --subnet)    SUBNET="${2:?}"; shift 2 ;;
    --ip)        STATIC_IP="${2:?}"; shift 2 ;;
    -h|--help)   uso; exit 0 ;;
    *)           erro "argumento desconhecido: $1"; uso; exit 1 ;;
  esac
done

FULL_NAME="exegol-${CONTAINER_NAME}"
export ASSUME_SIM CONF_INFORMADO CONTAINER_NAME FULL_NAME IMAGE_TAG \
       NETWORK_NAME SUBNET GATEWAY STATIC_IP

descobrir_ambiente

# Se ja existe um .conf adotado, reaproveita sem perguntar de novo.
if [[ -z "$CONF_INFORMADO" ]]; then
  # O || true e obrigatorio: com pipefail, o find falhando (o diretorio ainda
  # nao existe numa instalacao limpa) mataria o script aqui, em silencio.
  _achado="$(find /etc/wireguard/mullvad -maxdepth 1 -name '*.conf' -type f 2>/dev/null \
    | sort | head -1 || true)"
  [[ -n "$_achado" ]] && MULLVAD_CONF="$_achado"
fi
export MULLVAD_CONF="${MULLVAD_CONF:-}"

# --- painel de estado ------------------------------------------------------

_linha() { printf '    %-18s %s\n' "$1" "$2"; }

_estado_imagem() {
  if docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" >/dev/null 2>&1; then
    docker image inspect "nwodtuhs/exegol:${IMAGE_TAG}" --format '{{.Size}}' \
      | awk -v t="$IMAGE_TAG" '{printf "%s (%.0f GB em disco)", t, $1/1000000000}' || true
  else
    printf '%s nao instalada' "$IMAGE_TAG"
  fi
}

_estado_container() {
  local estado
  estado="$(docker container inspect "$FULL_NAME" --format '{{.State.Status}}' 2>/dev/null)" \
    || { printf 'nao existe'; return; }
  printf '%s' "$estado"
}

mostrar_estado() {
  local chain unit
  chain="$(nome_chain "$CONTAINER_NAME")"
  unit="$(nome_unit "$CONTAINER_NAME")"

  printf '\n  %s+--------------------------------------------+%s\n' "$AZUL" "$RESET"
  printf '  %s|%s   %sEXEGOL x MULLVAD%s  --  kill switch       %s|%s\n' \
    "$AZUL" "$RESET" "$AMARELO" "$RESET" "$AZUL" "$RESET"
  printf '  %s+--------------------------------------------+%s\n\n' "$AZUL" "$RESET"

  _linha "Distro" "$(detectar_distro)"
  if systemctl is-active --quiet docker; then
    _linha "Docker" "ok, ativo"
  else
    _linha "Docker" "ausente ou parado"
  fi
  if [[ -x "$EXEGOL_BIN" ]]; then
    _linha "Exegol" "$(exegol_cmd version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1 || echo presente)"
  else
    _linha "Exegol" "nao instalado"
  fi
  _linha "Imagem" "$(_estado_imagem)"
  _linha "Config Mullvad" "${MULLVAD_CONF:-nenhuma encontrada}"
  _linha "Container" "$(_estado_container)"
  if iptables -L "$chain" -n >/dev/null 2>&1; then
    _linha "Kill switch" "ativo (chain ${chain})"
  else
    _linha "Kill switch" "inativo"
  fi
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    _linha "Watcher" "ativo"
  else
    _linha "Watcher" "inativo"
  fi
  printf '\n'
}

# --- orquestracao ----------------------------------------------------------

# Opcao do menu que retoma cada estagio, para a mensagem de erro dizer
# exatamente por onde continuar em vez de so anunciar a falha.
_opcao_do_estagio() {
  case "$1" in
    estagio_deps)       printf '2 (So dependencias)' ;;
    estagio_mullvad)    printf '3 (So config Mullvad)' ;;
    estagio_container)  printf '4 (So o container)' ;;
    estagio_killswitch) printf '5 (So o kill switch)' ;;
    estagio_verify)     printf '6 (Verificar)' ;;
    *)                  printf '1 (Instalacao completa)' ;;
  esac
}

# Roda um estagio e trata o status: 0 ok, 3 usuario cancelou, resto e erro.
#
# ATENCAO: o `"$fn" || st=$?` abaixo SUPRIME o errexit dentro do corpo do
# estagio -- e regra do bash para comandos em contexto de ||. Medido: uma funcao
# com um `false` no meio, chamada assim, segue executando e devolve 0. Por isso
# cada estagio guarda seus proprios comandos que mutam estado com
# `|| { erro "..."; return 1; }`; nao ha protecao implicita aqui.
#
# Nao troque isto por subshell em background + wait para "recuperar" o errexit:
# testado, funciona para o errexit e QUEBRA o instalador, porque um subshell em
# background recebe EOF imediato no stdin e todo `confirmar` passa a falhar.
rodar() {
  local nome="$1" fn="$2" st=0
  printf '\n%s>>> %s%s\n' "$NEGRITO" "$nome" "$RESET"
  "$fn" || st=$?
  case "$st" in
    0) return 0 ;;
    3) aviso "estagio '${nome}' cancelado"; return 3 ;;
    *) erro "estagio '${nome}' falhou (status ${st})"
       erro "Para retomar daqui, escolha a opcao $(_opcao_do_estagio "$fn") no menu."
       return "$st" ;;
  esac
}

instalacao_completa() {
  rodar "Dependencias"  estagio_deps       || return $?
  rodar "Config Mullvad" estagio_mullvad   || return $?
  rodar "Container"     estagio_container  || return $?
  rodar "Kill switch"   estagio_killswitch || return $?
  info "Subindo o tunel pela primeira vez..."
  docker exec "$FULL_NAME" wg-quick down wg0 >/dev/null 2>&1 || true
  docker exec "$FULL_NAME" wg-quick up wg0 \
    || morrer "wg-quick up falhou -- veja: docker exec ${FULL_NAME} wg-quick up wg0"
  sleep 2
  rodar "Verificacao"   estagio_verify     || return $?
  printf '\n'
  ok "Pronto. Use: exegol start ${CONTAINER_NAME}   e dentro dele: mullvad-switch"
}

menu() {
  while true; do
    mostrar_estado
    printf '    1) Instalacao completa   <- faz tudo, do zero\n'
    printf '    2) So dependencias\n'
    printf '    3) So config Mullvad\n'
    printf '    4) So o container\n'
    printf '    5) So o kill switch\n'
    printf '    6) Verificar / testar vazamento\n'
    printf '    7) Desinstalar\n'
    printf '    0) Sair\n\n'
    local escolha=""
    read -r -p "$(printf '%s[?]%s escolha> ' "$AMARELO" "$RESET")" escolha
    case "$escolha" in
      1) instalacao_completa || true ;;
      2) rodar "Dependencias"   estagio_deps        || true ;;
      3) rodar "Config Mullvad" estagio_mullvad     || true ;;
      4) rodar "Container"      estagio_container   || true ;;
      5) rodar "Kill switch"    estagio_killswitch  || true ;;
      6) rodar "Verificacao"    estagio_verify      || true ;;
      7) rodar "Desinstalacao"  estagio_desinstalar || true ;;
      0) exit 0 ;;
      *) erro "opcao invalida" ;;
    esac
  done
}

if (( DESINSTALAR )); then
  rodar "Desinstalacao" estagio_desinstalar
  exit $?
fi

if [[ -n "$ESTAGIO_UNICO" ]]; then
  case "$ESTAGIO_UNICO" in
    deps)       rodar "Dependencias"   estagio_deps ;;
    mullvad)    rodar "Config Mullvad" estagio_mullvad ;;
    container)  rodar "Container"      estagio_container ;;
    killswitch) rodar "Kill switch"    estagio_killswitch ;;
    verify)     rodar "Verificacao"    estagio_verify ;;
    *) erro "estagio desconhecido: ${ESTAGIO_UNICO}"; uso; exit 1 ;;
  esac
  exit $?
fi

if (( ASSUME_SIM )); then
  [[ -n "$CONF_INFORMADO" ]] || morrer \
    "--yes exige --conf PATH: a rota automatica precisa do numero da conta, que nao tem padrao"
  instalacao_completa
  exit $?
fi

menu
```

- [ ] **Step 3: Conferir sintaxe e o carregamento dos estagios**

```bash
bash -n install.sh && echo SINTAXE_OK
chmod +x install.sh
bash install.sh --help
# Deve recusar sem root:
bash install.sh --stage deps; echo "status esperado 1: $?"
# Deve recusar --yes sem --conf:
sudo bash install.sh --yes; echo "status esperado 1: $?"
# Deve recusar estagio inexistente:
sudo bash install.sh --stage xpto; echo "status esperado 1: $?"
```

Expected: `SINTAXE_OK`, a ajuda impressa, e as tres recusas com status 1 e mensagem clara — a primeira dizendo `precisa de root`, a segunda dizendo que `--yes exige --conf`, a terceira dizendo `estagio desconhecido: xpto`.

- [ ] **Step 4: Rodar a suite inteira**

```bash
bash tests/run.sh
python3 -m unittest discover -s tests
for f in install.sh lib/*.sh payload/*.sh; do bash -n "$f" || echo "SINTAXE RUIM: $f"; done
python3 -m py_compile payload/*.py && echo PY_OK
```

Expected: **50** asserts em bash passando, **66** testes Python OK com saida limpa (zero linhas extras), nenhuma linha `SINTAXE RUIM`, `PY_OK`. Estes numeros cresceram durante a implementacao conforme os reviews exigiram testes novos; confirme o que os comandos realmente imprimem em vez de assumir.

- [ ] **Step 5: Remover o script antigo**

O `install.sh` mais os estagios substituem ele por completo. Ele foi mantido ate aqui de proposito, como referencia viva durante a implementacao.

```bash
git rm exegol-mullvad-killswitch-setup.sh
```

- [ ] **Step 6: Commit**

```bash
git add install.sh lib/06-uninstall.sh
git commit -m "install.sh: menu interativo, flags, desinstalacao; remove o script monolitico"
```

---

### Task 14: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: o comportamento real construido nas Tasks 5-13
- Produces: nada de codigo.

- [ ] **Step 1: Reescrever o README.md**

Estrutura obrigatoria, em portugues **com** acentuacao:

1. **Titulo e tres linhas** dizendo o que e: container Exegol dedicado que so sai pela Mullvad, kill switch em duas camadas, troca de relay por menu.
2. **Instalacao** — um bloco, um comando:
   ```bash
   git clone https://github.com/tsoi32/docker-over-mullvad.git
   cd docker-over-mullvad
   sudo bash install.sh
   ```
   Diga que o menu detecta o que falta e instala, incluindo Docker e Exegol, e que **nao e preciso relogar nem entrar no grupo docker** — o instalador fala com o Docker como root.
3. **O que o menu oferece** — a lista das 8 opcoes, com uma linha cada.
4. **Config da Mullvad** — as duas rotas. Na automatica, avise explicitamente que a Mullvad permite **5 chaves por conta** e que o instalador reaproveita a chave ja registrada para nao queimar slots.
5. **Como funciona** — reproduza o diagrama de fluxo da secao "Estagio 04" da spec, e explique as duas camadas em um paragrafo cada. Diga que a camada 2 comeca **fechada**, e que e isso que cobre a janela entre o container subir e o `wg-quick` rodar.
6. **Verificacao** — mostre que a opcao 6 do menu derruba o tunel de proposito e prova que nada sai, e o que cada item PASSA/FALHA significa. Deixe claro que FALHA nos itens de vazamento quer dizer que o kill switch nao esta protegendo.
7. **Trocar de relay** — `exegol start mullvad`, depois `mullvad-switch` dentro do container. Os quatro modos (trocar so a saida, multihop completo, single-hop, status) e o rollback automatico.
8. **Tabela de flags** — copie a tabela da secao "Menu do install.sh" da spec, incluindo que `--yes` exige `--conf`.
9. **Troubleshooting** — no minimo estes casos, com o comando de diagnostico de cada um:
   - watcher nao subiu: `journalctl -u exegol-mullvad-killswitch-watcher.service -n 30`
   - container sem NET_ADMIN: o `exegol start --vpn ""` nao rodou; refaca o estagio 4 do container
   - sem handshake depois de trocar de relay: o rollback deve ter voltado sozinho; confira com `mullvad-switch` -> Ver status
   - `docker exec ... wg show` vazio: o tunel esta fora, a camada 1 esta bloqueando por design
10. **Desinstalacao** — opcao 7 do menu ou `sudo bash install.sh --uninstall`, e o aviso de que apagar a chave localmente **nao** libera o slot na conta Mullvad.

Marque os pontos de insercao dos GIFs como comentarios HTML, sem referenciar os arquivos atuais:

```markdown
<!-- GIF: instalação (regravar — os GIFs antigos mostram a UI do script monolítico) -->
<!-- GIF: verificação / teste de vazamento -->
<!-- GIF: troca de relay -->
```

Os tres GIFs existentes (`demo-install.gif`, `demo-container.gif`, `demo-switch.gif`) mostram a ferramenta antiga, inclusive o menu com a entrada `se-got-wg-007` chumbada. **Nao os referencie** como se refletissem o comportamento novo. Deixe os arquivos no repo (o usuario decide se regrava ou apaga).

- [ ] **Step 2: Conferir os comandos do README**

Todo bloco `bash` do README precisa ser um comando que existe de fato. Confira um por um:

```bash
grep -oE '(sudo )?bash install\.sh[^`]*' README.md | sort -u
```

Cada linha listada tem que casar com uma flag documentada no `uso()` do `install.sh`. Qualquer flag no README que nao exista no `uso()` e um bug de documentacao.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "README: reescrito para o instalador com menu interativo"
```

---

## Ordem de execucao e dependencias

```
Task 1  (verificacoes de campo)  -- gateia 7, 11
Task 2  (harness + common.sh)    -- gateia todas
Task 3  (wgconf.py)              -- gateia 6, 11
Task 4  (mullvad_api.py)         -- gateia 6, 11
Task 5  (01-deps + privilegio)   -- gateia 7, 13
Task 6  (02-mullvad)             -- gateia 7
Task 7  (03-container)           -- gateia 10, 12
Task 8  (killswitch-postup)      -- gateia 9 (contrato do state.json)
Task 9  (backstop + watcher)     -- gateia 10
Task 10 (04-killswitch)          -- gateia 12
Task 11 (mullvad-switch)         -- independente depois de 3, 4
Task 12 (05-verify)              -- gateia 13
Task 13 (install.sh)             -- gateia 14
Task 14 (README)
```

Tasks 3 e 4 nao dependem uma da outra e podem ir em paralelo. Tasks 8 e 9 tambem, desde que o contrato do `state.json` da Task 8 seja respeitado.

**Correcao de ordem (ruling do preflight):** a **Task 11 roda ANTES da Task 7**. O
`_instalar_payload` da Task 7 instala `mullvad-switch.py`, que so existe depois da Task 11,
e a Task 11 nao depende da 7 -- so das Tasks 3 e 4. Ordem efetiva:

```
2, 3, 4, 5, 6, 11, 1, 7, 8, 9, 10, 12, 13, 14
```

A Task 1 fica imediatamente antes da 7, que e a primeira que depende dos achados dela.

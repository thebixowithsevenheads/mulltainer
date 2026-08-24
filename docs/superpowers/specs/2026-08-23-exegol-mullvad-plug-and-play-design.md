# Exegol + Mullvad — instalador plug and play com kill switch

Data: 2026-08-23
Status: aprovado, pronto pro plano de implementação

## Objetivo

Substituir o script monolítico atual (`exegol-mullvad-killswitch-setup.sh`, 700
linhas, uma execução tudo-ou-nada) por um instalador interativo que qualquer
pessoa roda sem configurar nada na mão: detecta o que falta, instala, obtém a
config da Mullvad, cria o container isolado e prova que o kill switch funciona.

Escopo fechado: host Linux (Arch e Debian/Ubuntu), Exegol v5, Mullvad via
WireGuard. Fora de escopo: Fedora, outros provedores de VPN, WSL/macOS.

## Ponto de partida — o que existe hoje

Infraestrutura viva medida em 2026-08-23:

- Host Arch, Exegol v5.1.11, imagem `nwodtuhs/exegol:free` v3.1.14 (67,3 GB em disco).
- Container `exegol-mullvad` na rede `exegol-vpn-net` (172.30.30.0/24), IP fixo
  172.30.30.10, `CapAdd=NET_ADMIN`, `net.ipv4.conf.all.src_valid_mark=1`.
  `net.ipv6.conf.all.disable_ipv6=0` — IPv6 fica habilitado no sysctl e é
  bloqueado apenas por `ip6tables -P DROP` dentro do container.
- `.conf` da Mullvad montado **read-only** em `/etc/wireguard/wg0.conf` pelo
  `--vpn` nativo do Exegol.
- Host: chain `EXEGOL-MULLVAD-KS` pendurada em `DOCKER-USER`;
  `exegol-mullvad-switch-watcher.service` enabled+active;
  `exegol-mullvad-killswitch.service` disabled (mudança não commitada).
- Três scripts no host: `killswitch.sh`, `switch-apply.sh`, `switch-watch.sh`.

### Divergências encontradas entre o repo e a infra viva

1. **Não commitado no repo:** o watcher passou a ser o backstop contínuo
   (compara `/tmp/mullvad-endpoint.txt` a cada 1s via `docker exec` e reaplica o
   kill switch) e o `killswitch.service` foi tirado do boot. Motivo: o container
   sobe manualmente muito depois do `docker.service`, então um oneshot com
   `After=docker.service` só falhava — o endpoint ainda não existia.
2. **A infra viva está atrasada em relação ao repo:** o `mullvad-switch.py` em
   `~/.exegol/my-resources/bin/` ainda é a versão com `se-got-wg-007` e
   Suécia/Suíça hardcoded, e o alias no `.zshrc` do container não passa as env
   vars. A versão generalizada do repo nunca foi aplicada no container.
3. Drift de mensagem no `switch-apply.sh` instalado: diz que o log fica "no
   container" quando fica no host (`/var/log/exegol-mullvad-switch-wgup.log`).

### Problemas estruturais que motivam a reescrita

- **Tudo-ou-nada.** Não há como só reinstalar o kill switch: qualquer execução
  recria o container do zero e perde o que estava dentro dele.
- **Um `docker exec` por segundo, para sempre.** O watcher spawna um processo
  dentro do container a cada segundo só pra ler um arquivo.
- **Janela sem proteção.** Entre o container subir e o `wg-quick up` rodar, não
  existe regra nenhuma dentro do container. O oneshot desabilitado não cobre isso.
- **Round-trip host↔container pra trocar de relay**, com timeout de 25s e um
  modo de falha ("timeout esperando o host") que o usuário não sabe diagnosticar.
- **Troca de relay sem rollback:** se o relay novo não fecha handshake, o usuário
  fica sem internet e sem pista do motivo.
- **A verificação não testa kill switch.** Só confirma que a VPN está de pé.
- **`.conf` obtido 100% na mão**, com passos de site na documentação.
- **Heredocs aninhados** (`docker exec ... tee <<'EOF'` dentro de `cat > x <<EOF`)
  são a parte mais frágil e ilegível do script atual.

## Decisão de arquitetura: container autônomo

Investigação da API pública da Mullvad (verificada ao vivo em 2026-08-23):

| Endpoint | Contrato confirmado |
|---|---|
| `POST api.mullvad.net/wg/` (`account`, `pubkey`) | registra a chave e devolve o endereço atribuído; `Account does not exist` / HTTP 400 se a conta é inválida |
| `GET api.mullvad.net/www/accounts/<n>/` | dados da conta incluindo validade; `{"code":"ACCOUNT_NOT_FOUND"}` / HTTP 404 |
| `GET api.mullvad.net/public/relays/wireguard/v1/` | HTTP 200, 553 relays, expõe `multihop_port` (a API nova `app/v1/relays` **não** expõe) |

Consequência: se nós geramos a chave, o `.conf` deixa de ser um artefato
read-only vindo de fora. Isso remove a razão de existir do protocolo
host↔container.

**A arquitetura nova:** o `wg0.conf` vive **dentro** do container (gravável),
com cópia-semente no host em `/etc/wireguard/mullvad/`. O `mullvad-switch`
reescreve o conf e reconecta sozinho. O host não manda mais no túnel — só vigia.

Isso elimina: `switch-apply.sh`, o protocolo `request.json`/`response.json`, o
timeout de 25s, o modo de falha "timeout esperando o host", a unit oneshot, e
todo `docker exec` do loop do watcher. De três scripts no host sobra um.

**O container continua sendo criado com `--vpn`, mas com valor vazio.**
`ContainerConfig.py:347` faz `if ParametersManager().vpn is not None: enableVPN()`,
e `enableVPN()` com `config_path=None` e `--vpn ""` cai no ramo "Enabling VPN
capabilities without managing a VPN connection" (linha 799): adiciona
`/dev/net/tun`, a capability `NET_ADMIN`, `net.ipv6.conf.all.disable_ipv6=0` e
`net.ipv4.conf.all.src_valid_mark=1` — **sem montar conf nenhum**. É um caminho
de primeira classe do Exegol, não contorno: entrega exatamente as capabilities e
os sysctls que o `wg-quick` exige, sem o mount read-only que impedia o container
de reescrever o próprio conf.

Consequência a registrar: o Exegol força `disable_ipv6=0`, ou seja, IPv6 fica
habilitado no container. O bloqueio de IPv6 continua sendo responsabilidade do
nosso `ip6tables`, e o estágio 05 testa isso explicitamente.

Único custo aceito: a chave privada passa a existir no filesystem do container —
que já rodava como root e já montava o conf, então a exposição é equivalente.

Abordagens descartadas: manter o protocolo atual (menor risco, mas carrega todos
os problemas estruturais acima); e a variante event-driven com `inotifywait` +
`docker events`, que adiciona dependência pra substituir um `stat` local por
segundo — YAGNI.

## Layout do repositório

```
exegol-mullvad-killswitch/
├── install.sh                    # entrypoint: menu interativo
├── lib/
│   ├── common.sh                 # ui, log, detecção de distro, checks de estado
│   ├── 01-deps.sh                # docker, pipx, exegol, wireguard-tools, imagem
│   ├── 02-mullvad.sh             # .conf: auto (nº da conta) ou manual
│   ├── 03-container.sh           # rede, container, IP fixo, payload, conf pra dentro
│   ├── 04-killswitch.sh          # camada 1 + camada 2 + watcher
│   └── 05-verify.sh              # verificação e teste de vazamento real
├── payload/
│   ├── killswitch-postup.sh      # roda dentro do container, via PostUp
│   ├── mullvad-switch.py         # menu de troca de relay, dentro do container
│   ├── host-backstop.sh          # aplica a chain em DOCKER-USER
│   └── host-watcher.sh           # loop: endpoint mudou → reaplica backstop
├── tests/
│   ├── test_common.sh            # funções puras de lib/common.sh
│   └── test_mullvad_switch.py    # montagem de conf, parse da API
├── docs/superpowers/specs/       # este documento
└── README.md
```

`payload/` contém arquivos reais, não heredocs. `/opt/my-resources` é bind mount
de `~/.exegol/my-resources`, então o payload do container é instalado por cópia
no host — sem `docker exec ... tee`.

Cada `lib/NN-*.sh` expõe uma função `estagio_<nome>()` e é sourceado pelo
`install.sh`. Nenhum deles roda nada ao ser sourceado.

## Modelo de privilégio

`install.sh` roda via `sudo`. Deriva `REAL_USER` de `SUDO_USER` e recusa execução
como root direto (sem `SUDO_USER` não há como saber de quem é o `~/.exegol`).

**O Exegol não se auto-escala** — não há chamada de `sudo` no código dele
(verificado na v5.1.11). O prompt de senha que aparece na prática vem de um alias
de shell do usuário: `alias exegol='sudo -E /home/USUARIO/.local/bin/exegol'`
(`.zshrc:152` neste host). O Exegol suporta `SUDO_HOME` para localizar o diretório
de config (`ConstantConfig.py:25`).

Portanto, como o instalador já roda como root, ele invoca o **binário** do Exegol
diretamente com `HOME` e `SUDO_HOME` apontados para o home do `REAL_USER` —
equivalente ao `sudo -E` do alias. Não usa `sudo -u "$REAL_USER"`.

Ganho direto de plug and play: **isso elimina a dependência de o usuário estar no
grupo `docker`**, e com ela o passo "relogar depois disso" que a documentação
atual exige no meio da instalação. O `usermod -aG docker` continua sendo feito,
mas como conveniência para o uso posterior do `docker` pelo próprio usuário, não
como requisito do instalador.

O `pipx install exegol` roda como `REAL_USER` (via `sudo -u`), porque instalar
pipx-como-root colocaria o binário em `/root/.local/bin`.

Efeito colateral conhecido e aceito: o Exegol rodando como root cria arquivos em
`~REAL_USER/.exegol` com dono root (é o que já acontece hoje — `my-resources/bin`
está `drwxrws--- root USUARIO`). O próprio Exegol tem tratamento de `chmod g+rws`
para isso (`FsUtils.py:92`).

## Menu do install.sh

Abre exibindo o estado real antes de qualquer pergunta:

```
  ┌────────────────────────────────────────────┐
  │   EXEGOL × MULLVAD  —  kill switch         │
  └────────────────────────────────────────────┘

    Docker ............ ok, ativo
    Exegol ............ v5.1.11
    Imagem ............ free (67 GB em disco)
    Config Mullvad .... nenhuma encontrada
    Container ......... não existe
    Kill switch ....... inativo
    Watcher ........... inativo

    1) Instalação completa   ← faz tudo, do zero
    2) Só dependências
    3) Só config Mullvad
    4) Só o container
    5) Só o kill switch
    6) Verificar / testar vazamento
    7) Desinstalar
    0) Sair
```

Opção 1 roda 01→05 em sequência e só pergunta o que não consegue descobrir.
Opções 2–5 permitem consertar uma peça sem recriar o container. Toda opção é
idempotente: rodar de novo não quebra nada.

Flags para uso não interativo (CI, reinstalação scriptada):

| Flag | Efeito |
|---|---|
| `--yes` | assume os padrões, não pergunta nada |
| `--stage deps\|mullvad\|container\|killswitch\|verify` | roda um estágio só (nome, não número, pra não confundir com a numeração do menu) |
| `--uninstall` | desinstala sem passar pelo menu |
| `--conf PATH` | usa este `.conf`, pula a escolha do estágio 02 |
| `--name`, `--image`, `--network`, `--subnet`, `--ip` | sobrescrevem os padrões |

`--yes` **exige** `--conf PATH`: a rota automática precisa do número da conta, que
não tem padrão possível. Sem `--conf`, `--yes` falha na hora com essa mensagem, em
vez de travar esperando input. Sem flag nenhuma, o modo é interativo.

## Estágio 01 — dependências

Detecta a distro por `ID` e `ID_LIKE` do `/etc/os-release`; suporta `arch` e
`debian`. Em distro não suportada, imprime a lista do que instalar e sai com
código distinto de erro genérico.

Verifica e instala o que falta: `docker` (+ habilita `docker.service`), `pipx`,
`exegol` (via `pipx install exegol` como `REAL_USER`), `wireguard-tools` (o
`wg genkey` é necessário na rota automática), `iptables`, `python3`, `curl`.

Adiciona `REAL_USER` ao grupo `docker` como conveniência para o uso posterior,
avisando que só vale depois de relogar — mas **a instalação não depende disso**,
porque o instalador fala com o Docker como root (ver "Modelo de privilégio").

Tela da imagem Exegol: lista as imagens disponíveis lendo `exegol info` (tamanhos
reais, não números chumbados no código), explica que `free` é a gratuita e que as
demais exigem assinatura, mostra o espaço livre em disco e alerta se for
insuficiente. Padrão `free`. Se a imagem já está instalada, só confirma.

## Estágio 02 — config da Mullvad

Menu com duas rotas.

**Rota automática (nº da conta):**

1. Lê o número da conta com `read -rs` (sem eco no terminal).
2. `GET /www/accounts/<n>/` — valida e exibe a validade. HTTP 404 → mensagem
   clara e volta ao menu.
3. Consulta `/etc/exegol-mullvad/key.json` (root, 600). **Se já existe chave
   registrada para essa conta, reaproveita.** Isso é o que evita queimar os 5
   slots de dispositivo da conta a cada execução. O arquivo guarda a chave
   privada, a pública, o endereço atribuído, um hash da conta e os 4 últimos
   dígitos — nunca o número da conta em claro.
4. Se não existe: `wg genkey` → `wg pubkey` → `POST /wg/` com `account` e
   `pubkey` → resposta é o endereço (`10.x.y.z/32,fc00:.../128`).
5. Escolha do relay inicial: menu por país e cidade, alimentado pela API legada.
   No host não há garantia de `fzf`, então é menu numerado próprio.
6. Monta o `.conf`.

**Rota manual:** varre `/etc/wireguard/mullvad/`, `/etc/wireguard/`,
`~REAL_USER/Downloads` e `~REAL_USER`; identifica cada `.conf` contra a API
(exibe `br-sao-wg-101 — São Paulo, Brasil`) e lista pra escolher; ou aceita um
caminho digitado. Copia para `/etc/wireguard/mullvad/` com 600 root.

**Normalização (ambas as rotas):** backup datado antes de qualquer edição;
remove `PostUp`/`PreDown` órfãos e blocos de kill switch inline de versões
antigas; força `DNS = 10.64.0.1`; injeta
`PostUp = /opt/my-resources/bin/killswitch-postup.sh` e
`PreDown = rm -f /workspace/.mullvad/state.json`. Edição sempre via Python,
nunca `sed -i`.

## Estágio 03 — container

1. Rede docker dedicada, idempotente: `exegol-vpn-net`, subnet 172.30.30.0/24,
   gateway .1, `--ipv6=false`, `enable_ip_masquerade=true`.
2. `exegol start <name> <image> --vpn ""` — o valor vazio ativa o modo "VPN
   capabilities" do Exegol (`NET_ADMIN`, `/dev/net/tun`, `src_valid_mark=1`,
   `disable_ipv6=0`) **sem montar conf nenhum**, deixando `/etc/wireguard/`
   gravável dentro do container.
3. `exegol stop`, desconecta de todas as redes, `docker network connect --ip`
   na rede dedicada, `exegol start`.
4. Instala `payload/killswitch-postup.sh` e `payload/mullvad-switch.py` em
   `~REAL_USER/.exegol/my-resources/bin/` (bind mount → aparece em
   `/opt/my-resources/bin/` dentro do container), com 755.
5. Copia o `.conf` normalizado para `/etc/wireguard/wg0.conf` dentro do
   container, 600. **Esta é a cópia viva**; a do host é semente e backup.
6. Instala o alias no `/root/.zshrc` do container, idempotente (remove a linha
   antiga antes de adicionar). Sem env vars — o `mullvad-switch` lê o estado do
   `state.json`, então não há mais nada de configuração no alias.
7. Garante `python3-rich`. A imagem free já traz `rich` (verificado); o
   `mullvad-switch.py` importa dentro de `try/except` e cai para saída ANSI
   simples se faltar, em vez de exigir `apt-get` (que só funcionaria depois do
   túnel estar de pé — ordem invertida no script atual).

## Estágio 04 — kill switch em duas camadas

### Fluxo de dados

```
  CONTAINER                                    HOST
  ─────────                                    ────
  mullvad-switch  ──reescreve──> wg0.conf
                                    │
                              wg-quick up
                                    │
                                 PostUp
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
              iptables DROP                 /workspace/.mullvad/
              (camada 1)                        state.json
                                            (bind mount, sem segredo)
                                                    │
                                                    ▼
                                            host-watcher (1s)
                                                    │
                                            host-backstop
                                            chain em DOCKER-USER
                                                  (camada 2)
```

### Camada 1 — dentro do container

`killswitch-postup.sh`, chamado pelo `PostUp` do `wg-quick`. Lê o `Endpoint` do
`/etc/wireguard/wg0.conf` dinamicamente (funciona pra qualquer relay sem editar
o script). Aplica: política `DROP` em INPUT/OUTPUT/FORWARD, v4 e v6; `ACCEPT`
em `lo` e `wg0`; `ACCEPT` do UDP para o endpoint; `ACCEPT` de
`ESTABLISHED,RELATED` no INPUT. Escreve `nameserver 10.64.0.1` no
`/etc/resolv.conf`.

Escreve `/workspace/.mullvad/state.json` com `endpoint_ip`, `endpoint_port`,
`entry_hostname`, `exit_hostname`, `mode`, `ts`. **Nenhuma chave** — é por isso
que o watcher pode ler um arquivo local do host em vez de fazer `docker exec`.

O caminho no host é `~REAL_USER/.exegol/workspaces/<name>/.mullvad/state.json`
(`/workspace` é bind mount de `~REAL_USER/.exegol/workspaces/<name>`). O diretório
novo é `.mullvad`; o `.mullvad-switch` da versão antiga é removido na migração.

As políticas `DROP` não são removidas quando o `wg0` cai, então a queda do túnel
já é fail-closed dentro do container.

### Camada 2 — backstop no host

`host-backstop.sh` mantém a chain pendurada em `DOCKER-USER` (inserida na posição
1, idempotente), com dois estados. O nome da chain é derivado do nome do
container: `EXEGOL-<NAME em maiúsculas>-KS` (com `--name mullvad`, fica
`EXEGOL-MULLVAD-KS`, a mesma de hoje).

- **Fechado** — nenhum endpoint válido conhecido, ou container parado: `DROP` de
  e para o IP do container.
- **Aberto** — `RETURN` para o UDP `container → endpoint:porta`, `RETURN` para
  `ESTABLISHED,RELATED` de volta, `DROP` em todo o resto de e para o IP.

`host-watcher.sh` roda em loop de 1s: lê `state.json` como arquivo local e
`docker inspect -f '{{.State.Running}}'` pra saber se o container está de pé.
Container parado ou sem endpoint válido → aplica o estado fechado. Endpoint novo
→ aplica o estado aberto. Começa fechado.

O `docker inspect` por segundo é uma chamada de API, não um processo dentro do
container como o `docker exec` de hoje. Necessário porque um container que morre
sem rodar o `PreDown` deixa o `state.json` para trás; sem checar `Running`, o
watcher manteria a brecha UDP aberta para um IP fixo que pode ser reusado por um
container sem túnel.

Isso fecha a janela da camada 1: entre o container subir e o `wg-quick up` rodar,
a camada 2 já está no estado fechado.

### systemd

**Uma única unit**, `exegol-<name>-killswitch-watcher.service`, `enabled`,
`Wants`/`After=docker.service`, `Restart=always`, `RestartSec=2`. Não existe mais
unit oneshot — é o que elimina de vez o bug do kill switch no boot: o watcher
aplica o estado fechado no boot e reage ao container quando ele aparecer.

## Estágio 05 — verificação e teste de vazamento

A verificação atual só confirma que a VPN está de pé, o que não testa kill
switch nenhum. A nova derruba o túnel de propósito:

1. `wg show` — handshake recente.
2. `curl am.i.mullvad.net/json` — `mullvad_exit_ip: true`, país, cidade, IP.
3. `resolv.conf` aponta 10.64.0.1.
4. `curl -6` falha (IPv6 bloqueado).
5. `wg-quick down wg0` → `curl -m5 https://1.1.1.1` **tem que falhar** (camada 1).
6. Com o túnel down, do host: os contadores de `iptables -L EXEGOL-*-KS -v`
   mostram os pacotes do IP do container morrendo na chain (camada 2).
7. Restaura o túnel e reconfirma o item 2.

Cada item imprime PASSA/FALHA. Qualquer FALHA nos itens 5 e 6 é tratada como
erro grave e sinalizada como tal — significa que o kill switch não está
protegendo.

## mullvad-switch — troca de relay

Roda dentro do container, como root, sem envolver o host. Lê a entrada e a saída
atuais do `state.json`. Menu: trocar só a saída (mantém a entrada), multihop
completo (entrada + saída), single-hop, ou ver status.

Escreve o novo `/etc/wireguard/wg0.conf` e faz `wg-quick down`/`up`. O `PostUp`
reaplica a camada 1 e reescreve o `state.json`; o host reage em até 1s.

**Rollback:** guarda o conf anterior e, se não houver handshake em ~10s, volta
para ele e reconecta. Hoje uma troca que falha deixa o usuário sem internet e
sem diagnóstico.

Duas mudanças de comportamento em relação ao que está rodando:

- **O modo rápido deixa de ser hardcoded.** A versão viva no container tem
  `se-got-wg-007` e Suécia/Suíça escritos no código. O novo reusa a entrada do
  `state.json` — "rápido" passa a significar "mantém a entrada, troca a saída".
- **Single-hop passa a ser oferecido.** Mecânica: `Endpoint = relay.ipv4:51820`,
  `PublicKey = relay.public_key`. Multihop preserva exatamente a mecânica já
  validada: `Endpoint = entrada.ipv4:saida.multihop_port`,
  `PublicKey = saida.public_key`.

Seleção de relay usa `fzf` se disponível, resolvido por `command -v fzf` com
fallback para o caminho conhecido da imagem e, por último, menu numerado — em vez
do caminho fixo `/opt/tools/fzf/bin/fzf` que o código atual assume.

## Desinstalação

Para e remove o container, remove a rede dedicada, remove a chain do
`DOCKER-USER` e a chain em si, para e remove a unit systemd e os scripts do
host. Pergunta separadamente antes de apagar `/etc/wireguard/mullvad/` e
`/etc/exegol-mullvad/key.json`, porque a chave registrada na conta Mullvad
continua ocupando um slot mesmo depois de apagada localmente — o texto avisa
isso.

## Migração da instalação atual

Este host já tem a versão antiga rodando, e a nova estrutura não é compatível
peça por peça. O estágio 04 detecta e remove a instalação antiga antes de
instalar a nova, de forma idempotente:

- para e desabilita as units `exegol-<name>-killswitch.service` (o oneshot que
  causava o bug de boot) e `exegol-<name>-switch-watcher.service`, e apaga os
  arquivos de unit;
- apaga os três scripts antigos de `/usr/local/sbin/`: `*-killswitch.sh`,
  `*-switch-apply.sh`, `*-switch-watch.sh`;
- remove o `.mullvad-switch/` do workspace (o diretório do protocolo
  request/response, que deixa de existir) e o
  `/run/exegol-<name>-killswitch.last-endpoint`;
- remove a chain antiga do `DOCKER-USER` antes de recriar, para não acumular
  regras duplicadas de execuções anteriores;
- avisa que o container atual foi criado com `--vpn <arquivo>` (mount read-only) e
  que precisa ser recriado com `--vpn ""` para a nova arquitetura funcionar,
  pedindo confirmação, porque recriar o container **apaga o que está dentro dele**
  (`/workspace` é bind mount e sobrevive; o resto do filesystem não).

O `.conf` existente em `/etc/wireguard/mullvad/` é reaproveitado como semente —
a migração não exige gerar chave nova nem queimar um slot da conta.

## Tratamento de erros

Todo estágio é idempotente e pode ser rerodado. `set -euo pipefail` em todos os
arquivos. Falha em um estágio para a instalação completa com uma mensagem que diz
qual estágio falhou e qual opção do menu retomar.

Operações destrutivas (recriar container, remover rede, desinstalar) confirmam
antes. `.conf` sempre tem backup datado antes de edição.

Se o kill switch não puder ser aplicado, o estado seguro é o fechado — nunca
deixar a chain aberta por falha.

## Testes

Não há suíte automatizada hoje e o alvo (iptables, systemd, docker, rede real)
não é unit-testável de forma honesta. A estratégia é:

- **Estágio 05 é o teste de integração**, e ele testa o que importa: que o
  tráfego morre quando o túnel cai. Roda no fim da instalação completa e é
  chamável isolado pelo menu.
- **Verificação manual em host limpo** para os estágios 01 e 02 (as duas
  distros, as duas rotas de config).
- Funções puras que dão pra testar sem privilégio (parse do `.conf`, montagem do
  conf, normalização, parse da resposta da API) ficam em `lib/common.sh` e no
  `mullvad-switch.py` separadas do efeito colateral, com testes rodáveis por
  `bash tests/run.sh` e `python3 -m unittest discover -s tests`.

  O host não tem `pytest`, `bats` nem `shellcheck` instalados, e o instalador não
  vai passar a exigir dependência de teste para rodar. Então: `unittest` da
  stdlib para o Python, e um runner de asserts em bash puro para o shell.

  Para tornar testável o que normalmente só roda como root, `host-backstop.sh` e
  `host-watcher.sh` respeitam `KS_DRY_RUN=1`: imprimem os comandos `iptables` que
  executariam, em vez de executá-los. Os testes afirmam a sequência exata de
  regras — é o que permite testar a lógica do kill switch sem privilégio.

## Verificações já resolvidas na fase de design

- **Capabilities sem mount read-only.** `exegol start ... --vpn ""` entrega
  `NET_ADMIN` + `src_valid_mark` + `/dev/net/tun` sem montar conf nenhum. Lido em
  `ContainerConfig.py:347` e `:756-804`. Era o risco que poderia inviabilizar a
  abordagem A inteira.
- **Modelo de privilégio.** O Exegol não se auto-escala; o prompt de sudo vinha de
  um alias de shell do usuário. Resolve o modelo descrito acima e remove a
  dependência do grupo `docker`.
- **Contratos da API da Mullvad.** Os três endpoints testados ao vivo (tabela na
  seção de decisão de arquitetura).

## Verificações pendentes — fazer antes de escrever o código que depende delas

Estas exigem privilégio de root no host ou o container de pé, então entram como
primeira tarefa do plano, antes do código que depende delas:

1. **Caminho do `fzf`** na imagem `free`. Resolver por `command -v` com fallback,
   mas confirmar o que a imagem realmente traz — o código atual assume
   `/opt/tools/fzf/bin/fzf` fixo.
2. **Se single-hop funciona** com chave gerada por nós. O comentário no código
   atual afirma que não funciona "pra essa conta/chave", mas isso era com a chave
   antiga; a suspeita é que fosse artefato daquela config. Testar no install e usar
   o resultado, não a suposição.
3. **Se o `wg-quick` sobe sem atrito** no container criado com `--vpn ""`. O
   sysctl `src_valid_mark` vem setado na criação, mas o `wg-quick` também tenta
   escrevê-lo; confirmar que ele não falha nesse ponto.

## Documentação

`README.md` reescrito: o que é em três linhas, um comando pra instalar,
diagrama das duas camadas, tabela de flags, verificação, troubleshooting dos
modos de falha conhecidos, desinstalação.

Os três GIFs atuais (`demo-install`, `demo-container`, `demo-switch`) mostram a
UI antiga, inclusive o menu com a entrada hardcoded. O README novo marca os
pontos de inserção mas não reaproveita os GIFs como se refletissem a ferramenta
nova — eles precisam ser regravados.

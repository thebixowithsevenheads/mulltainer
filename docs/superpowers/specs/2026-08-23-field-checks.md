# Verificações de campo — steps 1, 2 e 3

Data: 2026-08-23
Host: Arch Linux, Exegol v5.1.11, imagem `nwodtuhs/exegol:free` v3.1.14 (já
instalada, ~42 GB).

Container de teste: `exegol-kstest`, criado com
`/home/USUARIO/.local/bin/exegol start kstest free --vpn ""` (binário chamado
direto, sem sudo e sem o alias `sudo -E` do `.zshrc` — o binário funciona sem
privilégio elevado neste host).

**Escopo deste documento:** apenas os steps 1-3 do brief da Task 1 (Container
de teste com `--vpn ""`; `/etc/wireguard` gravável + `src_valid_mark`; caminho
do `fzf`). Steps 4 (single-hop com chave nova) e 5 (limpeza) estão **fora de
escopo desta execução** — ver seção final.

## Step 1 — Container de teste com `--vpn ""`

Comando executado:

```
/home/USUARIO/.local/bin/exegol start kstest free --vpn ""
```

Saída literal (trecho relevante — omiti apenas o banner de versão e o aviso de
self-update do exegol, que não afetam o resultado):

```
[*] Skipping interactive mode (arguments supplied)
[*] Creating new container kstest
[-] The repository resources has been cloned as root.
[-] The current user does not have the necessary rights to perform the
self-update operations.
[-] Please reinstall exegol (with git clone) without sudo.
[*] Defaulting to Docker to protect host from VPN. Use --network host if you
need to access VPN from your host.
[+] Enabling VPN capabilities without managing a VPN connection

⭐ Container summary
┌──────────────────┬───────────────────────────────────────┐
│             Name │ kstest                                │
│            Image │ free - v.3.1.14 (Up to date)          │
├──────────────────┼───────────────────────────────────────┤
│      Credentials │ root : FH3SE7etVxLa79aRWBpmDfKnoSsW5O │
│   Remote Desktop │ Off 🪓                                │
│      Console GUI │ On ✔ (X11 + Wayland)                  │
│          Network │ Docker                                │
│         Timezone │ On ✔                                  │
│ Exegol resources │ On ✔ (/opt/resources)                 │
│     My resources │ On ✔ (/opt/my-resources)              │
│    Shell logging │ Off 🪓                                │
│       Privileged │ Off ✔                                 │
│     Capabilities │ NET_ADMIN                             │
│        Workspace │ Dedicated (/workspace)                │
│          Devices │ /dev/net/tun                          │
│         Systctls │ net.ipv6.conf.all.disable_ipv6 = 0    │
│                  │ net.ipv4.conf.all.src_valid_mark = 1  │
└──────────────────┴───────────────────────────────────────┘

[*] Creating new exegol container
[+] Exegol container successfully created!
[+] Successfully deployed my-resources!
[*] Location of the exegol workspace on the host :
/home/USUARIO/.exegol/workspaces/kstest
[*] Shared host device: /dev/net/tun
[+] Opening zsh shell in Exegol kstest
cannot attach stdin to a TTY-enabled container because stdin is not a terminal
```

A última linha (`cannot attach stdin...`) é apenas a falha de anexar um shell
interativo (não havia TTY na sessão que rodou o comando) — não afeta a criação
do container, confirmada pela linha `[+] Exegol container successfully
created!` acima dela.

Verificação com `docker inspect`:

```
$ docker ps -a --filter name=exegol-kstest --format '{{.Names}}\t{{.Status}}'
exegol-kstest	Up 7 seconds

$ docker inspect exegol-kstest \
  --format 'CapAdd={{.HostConfig.CapAdd}} Sysctls={{.HostConfig.Sysctls}} Devices={{.HostConfig.Devices}}'
CapAdd=[NET_ADMIN] Sysctls=map[net.ipv4.conf.all.src_valid_mark:1 net.ipv6.conf.all.disable_ipv6:0] Devices=[{/dev/net/tun /dev/net/tun rwm}]
```

**Resultado: confirma exatamente o esperado pelo brief e pela spec.**
`CapAdd=[NET_ADMIN]`, `Sysctls` contém `net.ipv4.conf.all.src_valid_mark:1` e
`net.ipv6.conf.all.disable_ipv6:0`, e `/dev/net/tun` está em `Devices`. Nenhum
`.conf` foi montado (nenhum `Mounts`/bind relacionado a wireguard aparece no
summary do exegol — só `Network: Docker`, sem entrada de VPN).

Isso confirma ao vivo a leitura de `ContainerConfig.py:347` e `:756-804`
citada na spec de design: `--vpn ""` cai no ramo "Enabling VPN capabilities
without managing a VPN connection" e entrega exatamente as capabilities e
sysctls esperados, sem mount de conf.

## Step 2 — `/etc/wireguard` gravável e `src_valid_mark`

Comandos executados:

```
$ docker exec exegol-kstest sh -c 'touch /etc/wireguard/teste && echo GRAVAVEL && rm /etc/wireguard/teste'
GRAVAVEL

$ docker exec exegol-kstest sh -c 'cat /proc/sys/net/ipv4/conf/all/src_valid_mark'
1
```

**Resultado: confirma exatamente o esperado.** `/etc/wireguard` é gravável
dentro do container (sem mount read-only), e `src_valid_mark` já vem setado a
`1` na criação do container — o `wg-quick` não precisa (e não vai falhar
tentando) setar esse sysctl.

Nota de escopo: este step confirma apenas os dois fatos pedidos pelo título do
step (gravável + sysctl). Não testei efetivamente `wg-quick up` aqui — isso
é parte do step 4 (single-hop), que está fora de escopo desta execução.

## Step 3 — Caminho do `fzf`

Comando pedido pelo brief:

```
$ docker exec exegol-kstest sh -lc 'command -v fzf || ls -la /opt/tools/fzf/bin/fzf 2>&1'
-rwxr-xr-x 1 root root 4448408 Feb 19  2026 /opt/tools/fzf/bin/fzf
```

O `command -v fzf` não imprimiu nada (falhou, cai no `||`), então o que se vê
é a saída do fallback `ls -la`. Para não deixar ambíguo se `fzf` está ou não
no `PATH`, testei os dois lados separadamente:

```
$ docker exec exegol-kstest sh -lc 'command -v fzf; echo "exit=$?"'
exit=127

$ docker exec exegol-kstest sh -lc 'echo $PATH'
/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin

$ docker exec exegol-kstest zsh -lc 'command -v fzf; echo "exit=$?"'
exit=1

$ docker exec exegol-kstest sh -lc 'ls -la /opt/tools/fzf/bin/'
total 4368
drwxr-xr-x  2 root root    4096 Mar  1 10:21 .
drwxr-xr-x 11 root root    4096 Mar  1 10:21 ..
-rwxr-xr-x  1 root root 4448408 Feb 19  2026 fzf
-rwxr-xr-x  1 root root    2868 Mar  1 10:21 fzf-preview.sh
-rwxr-xr-x  1 root root    7316 Mar  1 10:21 fzf-tmux
```

**Resultado / achado:** o binário `fzf` existe e é executável em
`/opt/tools/fzf/bin/fzf` (confirma o caminho fixo que o código atual assume),
mas **não está no `PATH`** de nenhum shell testado (`sh` login nem `zsh`
login, que é o shell padrão do container Exegol). Ou seja, na prática
`command -v fzf` **sempre** vai falhar nesta imagem, e o código vai cair
sempre no fallback do caminho fixo — o fallback é o caminho quente, não uma
exceção rara.

Isso não contradiz a estratégia da spec ("resolver por `command -v` com
fallback para o caminho conhecido da imagem e, por último, menu numerado") —
essa estratégia já previa exatamente este caso. Mas é uma correção de
expectativa importante para a Task 11: **não assumir** que `command -v fzf`
vai resolver na maioria das instalações "free"; o fallback fixo
`/opt/tools/fzf/bin/fzf` é o caminho real usado. Recomenda-se manter esse
fallback com o mesmo valor que o código atual já usa (confirmado, não
mudou), e não remover essa constante mesmo generalizando para `command -v`.

## Step 4 — Single-hop com chave nova (PENDENTE — fora de escopo desta execução)

**Não executado nesta sessão.** Este step exige o número da conta Mullvad do
usuário e faz uma chamada real a `https://api.mullvad.net/wg/` que registra
uma chave nova, consumindo um dos 5 slots de dispositivo da conta. Nem o
agente nem a sessão que o disparou têm o número da conta, e não é apropriado
gerar esse efeito colateral sem o usuário presente para depois removê-lo em
mullvad.net → Devices.

**O usuário deve rodar o step 4 manualmente**, usando o `exegol-kstest`
container que foi deixado de pé para esse fim (ver seção seguinte), seguindo
o roteiro do brief (`.superpowers/sdd/2026-08-23-plug-and-play-installer/task-1-brief.md`,
step 4).

## Step 5 — Limpeza do container (PENDENTE — fora de escopo desta execução)

**Não executado.** O container `exegol-kstest` foi deixado **criado e em
execução** intencionalmente, para que o usuário possa usá-lo no step 4 sem
precisar recriar o ambiente. A remoção (`exegol stop kstest` +
`exegol remove kstest -F`) é responsabilidade de quem rodar o step 4 depois,
ou de quem cuidar da limpeza subsequente.

## Conclusão para as Tasks 7 e 11

- **Task 7** (`exegol start ... --vpn ""`): confirmado ao vivo, sem
  ressalvas. Capabilities, sysctls e devices batem exatamente com o que a
  spec de design descreve. `/etc/wireguard` é gravável e `src_valid_mark` já
  vem setado — nenhum atrito esperado do `wg-quick` nesse ponto.
- **Task 11** (caminho do `fzf` / single-hop): o caminho de fallback fixo é
  `/opt/tools/fzf/bin/fzf`, e ele será usado na prática (não é um caso raro —
  `fzf` não está no `PATH` por padrão nesta imagem). O resultado do single-hop
  (step 4) continua pendente do usuário; a Task 11 não pode assumir nenhum dos
  dois resultados até isso ser respondido.

Nenhum achado dos steps 1-3 contradiz
`docs/superpowers/specs/2026-08-23-exegol-mullvad-plug-and-play-design.md`;
os três pontos batem com o que a spec já registrava como "verificações já
resolvidas" e "verificações pendentes" (itens 1 e 3 da lista de pendências).
Nenhuma edição foi feita na spec de design.

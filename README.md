```
  ██    ██  ██  ██  ██     ██     ██████  ██████  ████  ██   ██  █████  █████ 
  ████████  ██  ██  ██     ██       ██    ██  ██   ██   ███  ██  ██     ██  ██
  ██ ██ ██  ██  ██  ██     ██       ██    ██████   ██   ██ █ ██  ████   █████ 
  ██ ██ ██  ██  ██  ██     ██       ██    ██  ██   ██   ██  ███  ██     ██ ██ 
  ██    ██  ██  ██  ██     ██       ██    ██  ██   ██   ██   ██  ██     ██  ██
  ██    ██  ██████  █████  █████    ██    ██  ██  ████  ██   ██  █████  ██  ██
```

# Mulltainer

Container Exegol que só sai à internet pela Mullvad, nunca pelo seu IP real.
Se o túnel cair, o tráfego para — não vaza. A troca de relay (país, servidor,
single-hop ou multihop) é feita por um menu de dentro do container.

**Requer** Arch ou Debian/Ubuntu (ou derivadas), com `systemd`.

## Instalação

```bash
git clone git@tsoi:thebixowithsevenheads/mulltainer.git
cd mulltainer
sudo bash install.sh
```

Um comando. O menu detecta o que falta — Docker, Exegol, imagem, config da
Mullvad, container, kill switch — e instala só o que estiver faltando. A
opção **1** faz tudo do zero.

![Mulltainer do zero até o multihop](demo/mulltainer.gif)

A imagem `free` do Exegol ocupa cerca de 40 GB, então a primeira instalação
demora. As outras imagens do Exegol são pagas.

## Uso

Depois de instalado:

```bash
exegol start mullvad          # entra no container
mullvad-switch                # dentro dele: troca de relay
```

O `mullvad-switch` lista os relays da Mullvad e oferece quatro modos: trocar
só a saída, multihop completo, single-hop, ou ver o status atual. Se a troca
não conectar, ele volta sozinho para o relay anterior.

Para conferir que está tudo de pé — inclusive derrubando o túnel de propósito
para provar que nada escapa:

```bash
sudo bash install.sh --stage verify
```

## O menu

```
  1) Instalacao completa   <- faz tudo, do zero
  2) So dependencias
  3) So config Mullvad
  4) So o container
  5) So o kill switch
  6) Verificar / testar vazamento
  7) Desinstalar
  0) Sair
```

Rodar qualquer opção de novo chega no mesmo estado — **exceto a 4**, que
recria o container do zero. Ela avisa e pede confirmação antes. O
`/workspace` sobrevive, por ser bind mount; o resto do filesystem do
container, não.

## Config da Mullvad

Duas rotas, no submenu da opção 3:

- **Pelo número da conta.** Você digita (sem eco no terminal); o instalador
  valida, registra uma chave WireGuard e monta o `.conf`, com um menu de país
  e relay.
- **Por um `.conf` que você já tem.** Ele procura em `/etc/wireguard/`,
  `~/Downloads` e no seu home, identifica cada arquivo contra a lista de
  relays e deixa escolher.

> **A Mullvad permite 5 dispositivos por conta.** O instalador reaproveita a
> chave já registrada em vez de queimar outro slot. E apagar essa chave do
> disco **não libera o slot** — para isso, remova o dispositivo em
> mullvad.net → Devices.

## Como funciona

Duas camadas independentes, para que um vazamento não dependa de uma só regra
sobreviver:

- **No container:** quando o túnel sobe, o `PostUp` do `wg-quick` aplica
  `iptables` com política `DROP`, liberando apenas o loopback, a `wg0` e o UDP
  do relay atual. As regras **não caem junto com o túnel** — por isso a queda
  já é fail-closed.
- **No host:** uma chain em `DOCKER-USER` espelha a mesma regra por fora e
  **começa fechada**, cobrindo a janela entre o container subir e o túnel
  ficar pronto. Um serviço `systemd` a mantém em dia.

## Flags

Para uso não interativo. Sem nenhuma, abre o menu.

| Flag | Efeito |
|---|---|
| `--yes` | não pergunta nada. **Exige `--conf`** |
| `--conf PATH` | usa este `.conf` |
| `--stage deps\|mullvad\|container\|killswitch\|verify` | roda um estágio só |
| `--uninstall` | desinstala |
| `--name NOME` | nome do container (padrão: `mullvad`) |
| `--image TAG` | imagem Exegol (padrão: `free`) |
| `--network NOME` | rede docker (padrão: `exegol-vpn-net`) |
| `--subnet CIDR` | subnet (padrão: `172.30.30.0/24`) |
| `--ip IP` | IP fixo do container (padrão: `172.30.30.10`) |
| `-h`, `--help` | ajuda |

## Problemas comuns

**Nada sai do container.** Provavelmente o túnel está fora, e é o
comportamento correto — a camada 1 bloqueia por design. Suba de novo:

```bash
docker exec exegol-mullvad wg-quick up wg0
```

**Container sem `NET_ADMIN`.** Recrie pela opção **4** (atenção: recria o
container do zero).

```bash
docker inspect exegol-mullvad --format '{{.HostConfig.CapAdd}}'
```

**O kill switch do host não subiu.**

```bash
journalctl -u exegol-mullvad-killswitch-watcher.service -n 30
```

## Desinstalação

```bash
sudo bash install.sh --uninstall
```

Ou pela opção **7**. Remove o container, a rede, a chain do host e o serviço.
Depois pergunta, separadamente, se quer apagar também a config da Mullvad e a
chave em `/etc/exegol-mullvad/`.

> Apagar a chave **não libera o slot de dispositivo** na sua conta Mullvad —
> remova em mullvad.net → Devices.

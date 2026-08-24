#!/usr/bin/env python3
"""Manipulacao do .conf do WireGuard.

Usado no host pelos estagios do instalador e dentro do container pelo
mullvad-switch -- por isso vive em payload/, que e o que e copiado para
/opt/my-resources/bin/. As funcoes recebem e devolvem texto; quem toca disco e
o CLI no fim do arquivo.

Nota: um .conf de Mullvad tem exatamente um [Peer]. Multihop nao e dois peers
-- e esse peer unico com o IP do relay ENTRY como Endpoint, a porta
multihop_port do relay EXIT, e a chave publica do EXIT. Portanto trocar_peer
sempre altera apenas o primeiro [Peer], o unico que existe.
"""
import os
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
    c = texto.replace("\r\n", "\n")
    c = c if c.endswith("\n") else c + "\n"
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

    O count=1 e defensivo contra confs com mais de um [Peer], embora um
    .conf de Mullvad valido tenha sempre um [Peer] unico.
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


def do_ambiente(nome):
    """Le um segredo do ambiente. Levanta ValueError se ausente ou vazio.

    /proc/<pid>/cmdline e' -r--r--r-- (world-readable) enquanto
    /proc/<pid>/environ e' -r-------- (so do dono) -- medido neste host, sem
    hidepid. A chave privada do WireGuard, portanto, nunca entra por argv.
    """
    valor = os.environ.get(nome, "")
    if not valor:
        raise ValueError("variavel de ambiente %s ausente ou vazia" % nome)
    return valor


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
            "     wgconf.py construir <privkey> <address> <pubkey> <ip> <porta>\n"
            "         (privkey em argv -- NAO usar com chave real)\n"
            "     wgconf.py construir-env <pubkey> <ip> <porta>\n"
            "         (privkey em WG_PRIVKEY, address em WG_ADDRESS)",
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
        elif cmd == "construir-env":
            # pubkey do relay, IP e porta continuam em argv: nao sao segredos.
            sys.stdout.write(
                construir(
                    do_ambiente("WG_PRIVKEY"), do_ambiente("WG_ADDRESS"),
                    argv[2], argv[3], int(argv[4]),
                )
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

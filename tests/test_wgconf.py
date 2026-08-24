import contextlib
import io
import os
import sys
import unittest
from unittest import mock

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

    def test_remove_dois_blocos_killswitch(self):
        # Regression: greedy regex destruia [Peer] com dois blocos
        dois_blocos = """[Interface]
PrivateKey = X=
Address = 10.1.1.1/32
# --- mullvad killswitch BEGIN ---
PostUp = /old/path.sh
# --- mullvad killswitch END ---
DNS = 10.64.0.1

[Peer]
PublicKey = Y=
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = 5.5.5.5:51820
# --- mullvad killswitch BEGIN ---
PostUp = iptables -P OUTPUT DROP
# --- mullvad killswitch END ---
"""
        r = wgconf.normalizar(dois_blocos)
        # Verifica que [Peer] nao foi destruida
        self.assertIn("PublicKey = Y=", r)
        self.assertIn("AllowedIPs = 0.0.0.0/0,::/0", r)
        self.assertIn("Endpoint = 5.5.5.5:51820", r)

    def test_normaliza_crlf_sem_dns(self):
        # Regression: CRLF sem DNS linha nao injetava hooks
        crlf_sem_dns = (
            "[Interface]\r\nPrivateKey = X=\r\nAddress = 10.1.1.1/32\r\n"
            "\r\n[Peer]\r\nPublicKey = Y=\r\nAllowedIPs = 0.0.0.0/0,::/0\r\n"
            "Endpoint = 5.5.5.5:51820\r\n"
        )
        r = wgconf.normalizar(crlf_sem_dns)
        # Deve injetar DNS e hooks
        self.assertIn("DNS = 10.64.0.1", r)
        self.assertIn(f"PostUp = {wgconf.POSTUP}", r)
        # Saida nao deve ter \r
        self.assertNotIn("\r", r)

    def test_normaliza_crlf_com_dns(self):
        # Regression: CRLF com DNS sabia com line endings mistos
        crlf_com_dns = (
            "[Interface]\r\nPrivateKey = X=\r\nAddress = 10.1.1.1/32\r\n"
            "DNS = 10.64.0.1\r\n\r\n[Peer]\r\nPublicKey = Y=\r\n"
            "AllowedIPs = 0.0.0.0/0,::/0\r\nEndpoint = 5.5.5.5:51820\r\n"
        )
        r = wgconf.normalizar(crlf_com_dns)
        # Saida nao deve ter \r
        self.assertNotIn("\r", r)
        self.assertIn(f"PostUp = {wgconf.POSTUP}", r)


class TestLerEndpoint(unittest.TestCase):
    def test_le_ip_e_porta(self):
        self.assertEqual(wgconf.ler_endpoint(CONF_MULLVAD), ("193.32.127.66", 51820))

    def test_le_porta_alternativa(self):
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

    def test_levanta_se_falta_endpoint(self):
        # Regression: so testava missing PublicKey
        with self.assertRaises(ValueError):
            wgconf.trocar_peer(
                "[Interface]\nPrivateKey = X=\n\n[Peer]\nPublicKey = Y=\n",
                "K=", "5.6.7.8", 2
            )

    def test_count_um_com_dois_peers(self):
        # Regression: count=1 nao podia falhar pois fixture tinha um peer
        # Testa que so o primeiro peer e trocado
        dois_peers = """[Interface]
PrivateKey = X=
Address = 10.1.1.1/32
DNS = 10.64.0.1

[Peer]
PublicKey = PRIMEIRO=
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = 1.1.1.1:51820

[Peer]
PublicKey = SEGUNDO=
AllowedIPs = 192.168.1.0/24
Endpoint = 2.2.2.2:51820
"""
        r = wgconf.trocar_peer(dois_peers, "NOVO=", "3.3.3.3", 3494)
        # Apenas o primeiro peer deve ser trocado
        self.assertIn("PublicKey = NOVO=", r)
        self.assertEqual(r.count("PublicKey = NOVO="), 1)
        # O segundo peer nao deve mudar
        self.assertIn("PublicKey = SEGUNDO=", r)
        self.assertIn("Endpoint = 2.2.2.2:51820", r)


class TestConstruir(unittest.TestCase):
    def test_conf_completo_e_reparseavel(self):
        c = wgconf.construir("PRIV=", "10.1.2.3/32", "PUB=", "9.8.7.6", 51820)
        self.assertEqual(wgconf.ler_endpoint(c), ("9.8.7.6", 51820))
        self.assertIn("AllowedIPs = 0.0.0.0/0,::/0", c)
        self.assertIn(f"DNS = {wgconf.DNS_MULLVAD}", c)

    def test_saida_ja_normalizada(self):
        c = wgconf.construir("PRIV=", "10.1.2.3/32", "PUB=", "9.8.7.6", 51820)
        self.assertEqual(c, wgconf.normalizar(c))


class TestCLIChavePrivadaForaDeArgv(unittest.TestCase):
    """A chave privada entra por ambiente, nunca por argv.

    /proc/<pid>/cmdline e' world-readable; /proc/<pid>/environ nao e'.
    """

    def _rodar(self, argv, ambiente):
        saida = io.StringIO()
        with mock.patch.dict(os.environ, ambiente, clear=False), \
                contextlib.redirect_stdout(saida), \
                contextlib.redirect_stderr(io.StringIO()):
            st = wgconf.main(argv)
        return st, saida.getvalue()

    def test_construir_env_le_privkey_e_address_do_ambiente(self):
        st, saida = self._rodar(
            ["wgconf.py", "construir-env", "PUBDORELAY=", "9.8.7.6", "3494"],
            {"WG_PRIVKEY": "PRIVSECRETA=", "WG_ADDRESS": "10.1.2.3/32"},
        )
        self.assertEqual(st, 0)
        self.assertIn("PrivateKey = PRIVSECRETA=", saida)
        self.assertIn("Address = 10.1.2.3/32", saida)
        self.assertIn("PublicKey = PUBDORELAY=", saida)
        self.assertEqual(wgconf.ler_endpoint(saida), ("9.8.7.6", 3494))

    def test_construir_env_produz_o_mesmo_conf_que_a_forma_posicional(self):
        st_env, via_env = self._rodar(
            ["wgconf.py", "construir-env", "PUB=", "9.8.7.6", "51820"],
            {"WG_PRIVKEY": "PRIV=", "WG_ADDRESS": "10.1.2.3/32"},
        )
        st_argv, via_argv = self._rodar(
            ["wgconf.py", "construir", "PRIV=", "10.1.2.3/32", "PUB=", "9.8.7.6", "51820"], {}
        )
        self.assertEqual((st_env, st_argv), (0, 0))
        self.assertEqual(via_env, via_argv)

    def test_construir_env_sem_privkey_falha_em_vez_de_gerar_conf_quebrado(self):
        st, saida = self._rodar(
            ["wgconf.py", "construir-env", "PUB=", "9.8.7.6", "51820"],
            {"WG_PRIVKEY": "", "WG_ADDRESS": "10.1.2.3/32"},
        )
        self.assertEqual(st, 1)
        self.assertEqual(saida, "")

    def test_construir_env_sem_address_falha(self):
        st, saida = self._rodar(
            ["wgconf.py", "construir-env", "PUB=", "9.8.7.6", "51820"],
            {"WG_PRIVKEY": "PRIV=", "WG_ADDRESS": ""},
        )
        self.assertEqual(st, 1)
        self.assertEqual(saida, "")

    def test_do_ambiente_rejeita_ausente_e_vazio(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError):
                wgconf.do_ambiente("NAO_EXISTE_NO_AMBIENTE")


if __name__ == "__main__":
    unittest.main()

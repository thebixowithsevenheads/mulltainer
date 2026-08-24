import contextlib
import io
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "payload"))

import mullvad_api as api

FIXTURE = {
    "countries": [
        {
            "name": "Albania",
            "cities": [
                {
                    "name": "Tirana",
                    "relays": [
                        {
                            "hostname": "zz-alb-wg-001",
                            "public_key": "ZZALB001=",
                            "ipv4_addr_in": "103.124.165.1",
                            "multihop_port": 3001,
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
    ]
}


class TestParseRelays(unittest.TestCase):
    def test_achata_a_arvore(self):
        r = api.parse_relays(FIXTURE)
        self.assertEqual(len(r), 4)
        self.assertEqual(
            sorted(r[0].keys()),
            ["cidade", "hostname", "ipv4_addr_in", "multihop_port", "pais", "public_key"],
        )

    def test_ordena_por_pais_cidade_hostname(self):
        r = api.parse_relays(FIXTURE)
        self.assertEqual(
            [x["hostname"] for x in r],
            ["zz-alb-wg-001", "br-sao-wg-101", "br-sao-wg-102", "se-got-wg-007"],
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
        self.assertEqual(sorted(g.keys()), ["Albania", "Brazil", "Sweden"])
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


class TestCLISegredosForaDeArgv(unittest.TestCase):
    """As credenciais entram por ambiente, nunca por argv.

    /proc/<pid>/cmdline e' -r--r--r-- (world-readable) e /proc/<pid>/environ e'
    -r-------- (so do dono) -- medido no host de desenvolvimento, sem hidepid.
    O numero da conta e' a UNICA credencial da conta Mullvad.
    """

    def _rodar(self, argv, ambiente):
        saida = io.StringIO()
        with mock.patch.dict(os.environ, ambiente, clear=False), \
                contextlib.redirect_stdout(saida), \
                contextlib.redirect_stderr(io.StringIO()):
            st = api.main(argv)
        return st, saida.getvalue()

    def test_conta_env_le_o_numero_do_ambiente_e_nao_de_argv(self):
        with mock.patch.object(api, "info_conta", return_value={"expiry_iso": "2027-01-01"}) as m:
            st, saida = self._rodar(
                ["mullvad_api.py", "conta-env"], {"MULLVAD_CONTA": "1234567890123456"}
            )
        self.assertEqual(st, 0)
        self.assertEqual(m.call_args[0][0], "1234567890123456")
        self.assertIn("2027-01-01", saida)

    def test_conta_env_sem_a_variavel_falha_em_vez_de_consultar(self):
        with mock.patch.object(api, "info_conta") as m:
            st, _ = self._rodar(["mullvad_api.py", "conta-env"], {"MULLVAD_CONTA": ""})
        self.assertEqual(st, 1)
        m.assert_not_called()

    def test_registrar_env_le_a_conta_do_ambiente_e_a_pubkey_de_argv(self):
        with mock.patch.object(api, "registrar_chave", return_value="10.66.1.2/32") as m:
            st, saida = self._rodar(
                ["mullvad_api.py", "registrar-env", "PUBKEYDORELAY="],
                {"MULLVAD_CONTA": "1234567890123456"},
            )
        self.assertEqual(st, 0)
        self.assertEqual(m.call_args[0], ("1234567890123456", "PUBKEYDORELAY="))
        self.assertIn("10.66.1.2/32", saida)

    def test_registrar_env_sem_a_variavel_falha_em_vez_de_registrar(self):
        # Importa mais que o resto: um registro com conta vazia queimaria um
        # slot -- ou daria um erro cuja causa o usuario nao consegue adivinhar.
        with mock.patch.object(api, "registrar_chave") as m:
            st, _ = self._rodar(
                ["mullvad_api.py", "registrar-env", "PUB="], {"MULLVAD_CONTA": ""}
            )
        self.assertEqual(st, 1)
        m.assert_not_called()

    def test_do_ambiente_rejeita_ausente_e_vazio(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(api.ErroMullvad):
                api.do_ambiente("NAO_EXISTE_NO_AMBIENTE")
        with mock.patch.dict(os.environ, {"VAZIA": ""}, clear=False):
            with self.assertRaises(api.ErroMullvad):
                api.do_ambiente("VAZIA")

    def test_subcomando_argv_continua_existindo_para_os_casos_sem_segredo(self):
        with mock.patch.object(api, "info_conta", return_value={"expiry_iso": "x"}) as m:
            st, _ = self._rodar(["mullvad_api.py", "conta", "1111222233334444"], {})
        self.assertEqual(st, 0)
        self.assertEqual(m.call_args[0][0], "1111222233334444")


if __name__ == "__main__":
    unittest.main()

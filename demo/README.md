# demo

Material do GIF do README. Nada aqui é executado pelo instalador.

- `mockup.sh` — encena uma sessão completa do Mulltainer. Não toca em
  container, rede, iptables nem systemd: são `printf` e `sleep`. Sourceia o
  `lib/common.sh` de verdade, então banner, cores e o formato de
  `info`/`ok`/`aviso` vêm das funções reais. As mensagens foram copiadas dos
  estágios; `tests/test_demo.sh` falha se um estágio mudar o texto e o mockup
  não acompanhar.
- `mulltainer.cast` — a gravação (asciinema v3, 80x24).
- `mulltainer.gif` — o GIF publicado no README.
- `cast2gif.py` — converte `.cast` em GIF. Existe porque este host tem
  `asciinema` e `ffmpeg` mas não tem `agg`.
- `build/` — saída intermediária, git-ignored.

## Regravar

```bash
asciinema rec --overwrite -c 'bash demo/mockup.sh' demo/mulltainer.cast
python3 demo/cast2gif.py demo/mulltainer.cast demo/mulltainer.gif --fps 4 --rows 34
```

Dois padrões que não são cosméticos:

`--rows 34` — o cast guarda as 24 linhas do terminal que gravou, e o painel
inicial passa disso. Como o scroll é decisão de quem renderiza, 34 linhas
mantêm o banner inteiro no quadro em vez de deixá-lo rolar para fora.

`--antialias nao` (padrão) e sem `--escala` — parecem detalhe de acabamento e
não são. A suavização dos glifos cria centenas de tons intermediários que
lotam a paleta do GIF e **expulsam as cores raras**: o vermelho do `demon7` no
prompt ocupa ~0,02% dos pixels e saía trocado por oliva mesmo com uma paleta
de 192 cores. Sem antialias e sem redimensionar, cada pixel fica sendo
exatamente uma cor da UI, e o resultado é melhor nos três eixos ao mesmo
tempo: cor exata, quadro maior (744×670 contra 632×569) e arquivo bem menor
(0,8 MB contra 2,4 MB).

Existe `--paleta por-quadro` para o caso de uma gravação com muitas cores,
mas ele multiplica o tamanho por ~10 e não é necessário aqui.

## Gravação real (prova de conceito)

`mockup.sh` encena; `gravar-real.sh` grava uma instalação de verdade, com conta
Mullvad de verdade, e prova a troca pelo IP de saída mudando entre dois relays.

```bash
bash demo/gravar-real.sh
```

Ele grava, redige e varre em sequência. O bruto fica em
`demo/build/real-bruto.cast` — dentro do diretório git-ignored, de propósito:
**o bruto nunca deve ser publicado nem versionado.**

### O que sai e o que fica

A política do `redigir-cast.py` é: o que **prova** a ferramenta fica, o que
**identifica a máquina** sai.

| Sai | Fica |
|---|---|
| número da conta, inclusive os 4 dígitos que o instalador mostra mascarados | hostnames de relay (a lista da Mullvad é pública) |
| chaves WireGuard | IP de saída e cidade/país (são os IPs *compartilhados* dos relays, não o seu — e são a prova) |
| endereço atribuído no túnel (`10.6x`/`fc00:`), que identifica o slot de device | `10.64.0.1`, o DNS da Mullvad, igual para todo assinante |
| validade da conta | |
| usuário, home e hostname da máquina; MACs — entram no lugar como `demon7@sect`, a mesma identidade do prompt do container | |
| senha de root do container, que o Exegol imprime no resumo de criação | |

O instalador já ajuda: o número da conta é lido com `read -s` (sem eco) e só
aparece mascarado, e a chave privada nunca é impressa nem passa por `argv`.

### A varredura

Depois de redigir, o script **varre o resultado** procurando os mesmos padrões
e sai com erro se sobrar qualquer um. A varredura é separada das regras de
propósito: se uma regra falhar em casar, é ela que avisa, em vez do silêncio.

Isso não é hipotético. A primeira gravação real **passou limpa** na varredura e
continha um segredo: a senha de root do container, que o Exegol imprime no
resumo de criação. São 30 chars sem `=`, não casavam com o padrão de chave
WireGuard, e nenhuma regra as pegava — foi achada lendo a gravação linha por
linha. Por isso a varredura ganhou uma regra que **não olha formato conhecido,
olha cara de aleatório**: 20+ chars misturando maiúscula, minúscula e dígito, o
que texto humano e caminho de arquivo praticamente nunca fazem. É ela que vai
pegar o próximo segredo que ninguém previu.

A lição vale para quem for gravar: **a varredura verde não substitui ler o
arquivo.**

Um arquivo que não passa na varredura não deve ser publicado. E mesmo que
passe, assista antes de gerar o GIF:

```bash
asciinema play demo/build/real.cast
python3 demo/cast2gif.py demo/build/real.cast demo/prova.gif --fps 4 --rows 40
```

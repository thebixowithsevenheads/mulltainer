#!/usr/bin/env python3
"""Converte um .cast do asciinema em GIF, sem depender do agg.

Existe porque este host tem asciinema e ffmpeg mas nao tem agg nem
asciicast2gif. Nao pretende ser um emulador de terminal completo: cobre
exatamente o que o demo/mockup.sh emite -- SGR (reset, negrito, cores basicas
e truecolor), limpar tela, home, CR e LF. Se o mockup passar a usar
movimentacao de cursor, isto precisa crescer.

Formato: asciinema v3 grava os eventos com intervalo RELATIVO ao evento
anterior, nao com timestamp absoluto. Descobri isso na pratica (a soma dos
intervalos dava a duracao, o maximo nao). O v2 usa absoluto; ambos sao aceitos
via --tempo.

Uso:
  python3 demo/cast2gif.py entrada.cast saida.gif [--fps 10] [--escala 1.0]
                           [--tempo relativo|absoluto] [--corte-final 1.5]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

FONTE_REGULAR = "/usr/share/fonts/TTF/DejaVuSansMono.ttf"
FONTE_NEGRITO = "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf"

FUNDO = (16, 20, 28)          # quase preto, levemente azulado
FRENTE = (208, 216, 226)      # cinza claro padrao
CORES_BASICAS = {
    30: (16, 20, 28), 31: (232, 88, 88), 32: (126, 202, 122), 33: (255, 213, 36),
    34: (41, 77, 115), 35: (186, 128, 200), 36: (108, 180, 190), 37: (208, 216, 226),
}

# 40-47 sao as mesmas cores dos 30-37, aplicadas ao fundo.
CORES_BASICAS_FUNDO = {k + 10: v for k, v in CORES_BASICAS.items()}

# Lista de um elemento pra desenhar() poder ler sem virar parametro em todas as
# chamadas. Definido no main a partir do argumento.
ANTIALIAS = [True]

CSI = re.compile(r"\x1b\[([0-9;]*)([A-Za-z])")


VAZIA = (" ", FRENTE, FUNDO, False)


class Tela:
    """Grade de celulas (char, cor, fundo, negrito) com cursor e scroll.

    A cor de FUNDO por celula existe porque a UI usa faixas de titulo -- texto
    amarelo sobre o azul da marca. Sem isso o GIF mostrava as faixas como texto
    amarelo solto num fundo preto, que nao e' o que o terminal desenha.
    """

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.cor = FRENTE
        self.fundo = FUNDO
        self.negrito = False
        self._limpar()

    def _limpar(self):
        self.grade = [[VAZIA] * self.cols for _ in range(self.rows)]
        self.lin = self.col = 0

    def _rolar(self):
        self.grade.pop(0)
        self.grade.append([VAZIA] * self.cols)
        self.lin = self.rows - 1

    def _nova_linha(self):
        self.lin += 1
        if self.lin >= self.rows:
            self._rolar()

    def escrever(self, texto):
        i = 0
        while i < len(texto):
            ch = texto[i]
            if ch == "\x1b":
                m = CSI.match(texto, i)
                if m:
                    self._csi(m.group(1), m.group(2))
                    i = m.end()
                    continue
                # Escape que nao entendemos: pula o ESC e segue. Melhor perder um
                # atributo do que despejar lixo no frame.
                i += 1
                continue
            if ch == "\n":
                self._nova_linha()
            elif ch == "\r":
                self.col = 0
            elif ch == "\t":
                self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)
            elif ch == "\b":
                self.col = max(0, self.col - 1)
            elif ord(ch) >= 32:
                if self.col >= self.cols:
                    self.col = 0
                    self._nova_linha()
                self.grade[self.lin][self.col] = (ch, self.cor, self.fundo, self.negrito)
                self.col += 1
            i += 1

    def _csi(self, params, final):
        if final == "m":
            self._sgr(params)
        elif final == "H":
            p = [int(x) for x in params.split(";") if x] or [1, 1]
            self.lin = max(0, min(self.rows - 1, (p[0] if p else 1) - 1))
            self.col = max(0, min(self.cols - 1, (p[1] if len(p) > 1 else 1) - 1))
        elif final == "J":
            # O `clear` deste host emite ESC[H ESC[J ESC[3J -- o J sem parametro
            # e modo 0 (do cursor ao fim da tela), nao 2. Tratar so o 2 fazia o
            # segundo clear do mockup nao limpar nada, e o quadro saia com o
            # texto antigo por baixo do novo.
            modo = params or "0"
            if modo == "0":
                self._apagar(self.lin, self.col, self.rows - 1, self.cols - 1)
            elif modo == "1":
                self._apagar(0, 0, self.lin, self.col)
            elif modo == "2":
                self._apagar(0, 0, self.rows - 1, self.cols - 1)
            # 3J limpa o scrollback, que aqui nao existe.
        elif final == "K":
            modo = params or "0"
            ini = self.col if modo == "0" else 0
            fim = self.col if modo == "1" else self.cols - 1
            self._apagar(self.lin, ini, self.lin, fim)
        # Qualquer outro final e ignorado de proposito.

    def _apagar(self, l0, c0, l1, c1):
        """Apaga de (l0,c0) a (l1,c1) inclusive, em ordem de varredura."""
        for l in range(max(0, l0), min(self.rows, l1 + 1)):
            ini = c0 if l == l0 else 0
            fim = c1 if l == l1 else self.cols - 1
            for c in range(max(0, ini), min(self.cols, fim + 1)):
                self.grade[l][c] = VAZIA

    def _sgr(self, params):
        codigos = [int(x) for x in params.split(";") if x] or [0]
        i = 0
        while i < len(codigos):
            c = codigos[i]
            if c == 0:
                self.cor, self.fundo, self.negrito = FRENTE, FUNDO, False
            elif c == 1:
                self.negrito = True
            elif c == 22:
                self.negrito = False
            elif c in CORES_BASICAS:
                self.cor = CORES_BASICAS[c]
            elif c in (90, 91, 92, 93, 94, 95, 96, 97):
                self.cor = CORES_BASICAS.get(c - 60, FRENTE)
            elif c == 38 and i + 4 < len(codigos) and codigos[i + 1] == 2:
                self.cor = (codigos[i + 2], codigos[i + 3], codigos[i + 4])
                i += 4
            elif c == 39:
                self.cor = FRENTE
            elif c in CORES_BASICAS_FUNDO:
                self.fundo = CORES_BASICAS_FUNDO[c]
            elif c in (100, 101, 102, 103, 104, 105, 106, 107):
                self.fundo = CORES_BASICAS_FUNDO.get(c - 60, FUNDO)
            elif c == 48 and i + 4 < len(codigos) and codigos[i + 1] == 2:
                self.fundo = (codigos[i + 2], codigos[i + 3], codigos[i + 4])
                i += 4
            elif c == 49:
                self.fundo = FUNDO
            i += 1


def ler_cast(caminho, tempo):
    linhas = [l for l in open(caminho, encoding="utf-8").read().splitlines() if l.strip()]
    cab = json.loads(linhas[0])
    term = cab.get("term") or {}
    cols = term.get("cols") or cab.get("width") or 80
    rows = term.get("rows") or cab.get("height") or 24

    brutos = []
    for l in linhas[1:]:
        try:
            ev = json.loads(l)
        except json.JSONDecodeError:
            continue
        if len(ev) >= 3 and ev[1] == "o":
            brutos.append((float(ev[0]), ev[2]))

    if tempo == "auto":
        soma = sum(t for t, _ in brutos)
        maximo = max((t for t, _ in brutos), default=0)
        # Em absoluto, o ultimo evento ~= duracao total, logo maximo ~= soma dos
        # deltas. Em relativo, a soma e muito maior que o maximo.
        tempo = "relativo" if soma > maximo * 1.5 else "absoluto"
        print(f"  tempo detectado: {tempo}")

    eventos, acc = [], 0.0
    for t, d in brutos:
        if tempo == "relativo":
            acc += t
            eventos.append((acc, d))
        else:
            eventos.append((t, d))
    return cols, rows, eventos


def desenhar(tela, fonte_r, fonte_n, lc, ac, margem):
    img = Image.new("RGB", (tela.cols * lc + margem * 2, tela.rows * ac + margem * 2), FUNDO)
    d = ImageDraw.Draw(img)
    if not ANTIALIAS[0]:
        # fontmode "1" = glifo em 1 bit, sem suavizacao. Cada pixel fica sendo
        # exatamente a cor do texto ou a do fundo, em vez de centenas de tons
        # intermediarios. Isso importa muito mais do que parece: sao os tons de
        # antialiasing que lotam a paleta do GIF e expulsam as cores raras --
        # com eles, o vermelho do prompt (0,02%% dos pixels) sumia mesmo com
        # 192 cores.
        d.fontmode = "1"

    # Passo 1: os fundos. Antes do texto, senao o retangulo de uma celula
    # apagaria o glifo da anterior -- os blocos do banner sao mais largos que a
    # celula e invadem a vizinha de proposito.
    for r, linha in enumerate(tela.grade):
        c = 0
        while c < tela.cols:
            fundo = linha[c][2]
            fim = c
            while fim < tela.cols and linha[fim][2] == fundo:
                fim += 1
            if fundo != FUNDO:
                d.rectangle([margem + c * lc, margem + r * ac,
                             margem + fim * lc - 1, margem + (r + 1) * ac - 1],
                            fill=fundo)
            c = fim

    # Passo 2: o texto. Agrupa celulas consecutivas de mesma cor/peso: menos
    # chamadas de desenho e texto mais bem espacado que caractere por caractere.
    for r, linha in enumerate(tela.grade):
        c = 0
        while c < tela.cols:
            ch, cor, _, neg = linha[c]
            if ch == " ":
                c += 1
                continue
            fim = c
            buf = []
            while fim < tela.cols:
                ch2, cor2, _, neg2 = linha[fim]
                if ch2 == " " or cor2 != cor or neg2 != neg:
                    break
                buf.append(ch2)
                fim += 1
            d.text((margem + c * lc, margem + r * ac), "".join(buf),
                   font=(fonte_n if neg else fonte_r), fill=cor)
            c = fim if fim > c else c + 1
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cast")
    ap.add_argument("gif")
    ap.add_argument("--fps", type=float, default=10)
    ap.add_argument("--escala", type=float, default=1.0)
    ap.add_argument("--tamanho-fonte", type=int, default=15)
    ap.add_argument("--tempo", choices=["auto", "relativo", "absoluto"], default="auto")
    ap.add_argument("--cols", type=int, default=0, help="sobrescreve as colunas do cast")
    ap.add_argument("--rows", type=int, default=0,
                    help="sobrescreve as linhas do cast. O cast guarda o tamanho do "
                         "terminal que gravou, mas o scroll e decisao de quem renderiza: "
                         "com mais linhas o conteudo nao rola e o banner nao e cortado.")
    ap.add_argument("--antialias", default="nao", choices=["sim", "nao"],
                    help="suavizacao dos glifos. 'nao' mantem as cores exatas e "
                         "e' o que permite uma paleta pequena preservar cor rara.")
    ap.add_argument("--paleta", default="global", choices=["por-quadro", "global"],
                    help="Uma paleta GLOBAL para o video inteiro descarta cor rara: "
                         "o vermelho do prompt ocupa ~0,02%% dos pixels e sumia "
                         "mesmo com 192 cores, saindo como oliva. Com paleta POR "
                         "QUADRO cada quadro escolhe as suas, e a cor rara "
                         "sobrevive nos quadros onde ela aparece.")
    ap.add_argument("--cores", type=int, default=64,
                    help="tamanho da paleta. O conteudo e texto sobre fundo plano: "
                         "64 cores bastam e o GIF fica bem menor que com 256.")
    ap.add_argument("--dither", default="none",
                    help="dither do paletteuse. 'none' e o certo aqui -- nao ha "
                         "gradiente dentro de uma linha, so cores planas, e o "
                         "dither so adiciona ruido que nao comprime.")
    ap.add_argument("--corte-final", type=float, default=1.5,
                    help="segundos de cauda a manter depois do ultimo evento")
    args = ap.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg nao encontrado")
    for f in (FONTE_REGULAR, FONTE_NEGRITO):
        if not os.path.exists(f):
            sys.exit(f"fonte ausente: {f}")

    cols, rows, eventos = ler_cast(args.cast, args.tempo)
    cols = args.cols or cols
    rows = args.rows or rows
    if not eventos:
        sys.exit("cast sem eventos de saida")
    dur = eventos[-1][0] + args.corte_final
    print(f"  {cols}x{rows}, {len(eventos)} eventos, {dur:.1f}s")

    ANTIALIAS[0] = args.antialias == "sim"
    fonte_r = ImageFont.truetype(FONTE_REGULAR, args.tamanho_fonte)
    fonte_n = ImageFont.truetype(FONTE_NEGRITO, args.tamanho_fonte)
    lc = round(fonte_r.getlength("M"))
    ac = args.tamanho_fonte + 4
    margem = 12
    print(f"  celula {lc}x{ac}px -> quadro {cols*lc+margem*2}x{rows*ac+margem*2}px")

    tela = Tela(cols, rows)
    tmp = tempfile.mkdtemp(prefix="cast2gif-")
    n_frames = int(dur * args.fps)
    prox = 0
    try:
        for i in range(n_frames):
            t = i / args.fps
            while prox < len(eventos) and eventos[prox][0] <= t:
                tela.escrever(eventos[prox][1])
                prox += 1
            img = desenhar(tela, fonte_r, fonte_n, lc, ac, margem)
            if args.escala != 1.0:
                img = img.resize((int(img.width * args.escala), int(img.height * args.escala)),
                                 Image.LANCZOS)
            img.save(os.path.join(tmp, f"f{i:05d}.png"))
            if i % 50 == 0:
                print(f"    frame {i}/{n_frames}", flush=True)

        # palettegen/paletteuse da GIF muito melhor que a conversao direta.
        entrada = os.path.join(tmp, "f%05d.png")
        if args.paleta == "por-quadro":
            # stats_mode=single + paletteuse=new=1: uma paleta por quadro.
            filtro = (f"split[a][b];[a]palettegen=max_colors={args.cores}"
                      f":stats_mode=single[p];[b][p]paletteuse=new=1"
                      f":dither={args.dither}")
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-framerate", str(args.fps),
                            "-i", entrada, "-lavfi", filtro,
                            "-loop", "0", args.gif], check=True)
        else:
            pal = os.path.join(tmp, "pal.png")
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-framerate", str(args.fps),
                            "-i", entrada,
                            "-vf", f"palettegen=max_colors={args.cores}:stats_mode=full",
                            pal], check=True)
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-framerate", str(args.fps),
                            "-i", entrada, "-i", pal,
                            "-lavfi", f"paletteuse=dither={args.dither}",
                            "-loop", "0", args.gif], check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    mb = os.path.getsize(args.gif) / 1024 / 1024
    print(f"  {args.gif}: {mb:.1f} MB, {n_frames} frames @ {args.fps}fps")


if __name__ == "__main__":
    main()

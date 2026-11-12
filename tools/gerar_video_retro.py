#!/usr/bin/env python3
"""
Gera uma animacao em estilo videogame antigo (visao da cabine, pseudo-3D)
para servir de fundo ao HUD do ProjetoAelSistemas.

Saidas:
  video.raw     -> quadros 320x240 em RGB332 (1 byte/pixel, R nos bits altos),
                   sem cabecalho, prontos para gravar nos setores do cartao SD.
                   Cada quadro = 76800 bytes = exatamente 150 setores de 512 bytes.
  preview.mp4   -> o mesmo video ampliado 2x, para ver no PC.
  quadro_exemplo.png -> um quadro solto (ampliado 2x).

O loop e perfeito: o ultimo quadro emenda no primeiro.

Uso:  python3 gerar_video_retro.py [--fps 15] [--segundos 30] [--seed 7]
"""
import argparse
import math
import random
import subprocess
import shutil

import numpy as np
from PIL import Image

W, H = 320, 240
HORIZON = H // 2          # linha do horizonte = centro (CY do HUD em 640x480 / 2)

# ---------------------------------------------------------------------------
# Cores (todas ja exatamente representaveis em RGB332, entao nao ha surpresa)
# R e G: 3 bits -> 0,36,73,109,146,182,219,255   B: 2 bits -> 0,85,170,255
# HUD e verde puro (0,F,0): nada de verde claro no cenario.
# ---------------------------------------------------------------------------
R3 = [0, 36, 73, 109, 146, 182, 219, 255]
B2 = [0, 85, 170, 255]


def c(r, g, b):
    """Cor pelos niveis RGB332 (r:0-7, g:0-7, b:0-3)."""
    return (R3[r], R3[g], B2[b])


SKY_BANDS = [c(0, 1, 2), c(0, 2, 2), c(1, 3, 3), c(2, 4, 3), c(3, 5, 3)]  # topo -> horizonte
CLOUD = c(7, 7, 3)
CLOUD_SHADE = c(5, 6, 3)
MOUNTAIN_FAR = c(2, 2, 2)
MOUNTAIN_NEAR = c(1, 1, 1)
GROUND_A = c(5, 3, 0)     # terra clara
GROUND_B = c(4, 2, 0)     # terra escura
ROAD = c(3, 3, 1)
ROAD_LINE = c(7, 7, 2)

# ---------------------------------------------------------------------------
# Sprites em pixel art (desenho proprio). '.' = transparente.
# ---------------------------------------------------------------------------
PAL = {
    'D': c(0, 2, 0),   # verde-escuro (copa)
    'd': c(0, 1, 0),   # verde mais escuro (sombra)
    'T': c(3, 1, 0),   # tronco
    'K': c(1, 1, 1),   # cinza escuro (jato)
    'G': c(3, 3, 2),   # cinza (jato)
    'L': c(5, 5, 2),   # cinza claro (jato)
    'R': c(7, 1, 0),   # vermelho (marca do inimigo / chama)
    'Y': c(7, 6, 0),   # amarelo (chama)
}

TREE = """
.......D.......
......DDd......
.....DDDdd.....
....DDDDDdd....
......DDd......
.....DDDdd.....
....DDDDDdd....
...DDDDDDDdd...
.....DDDDd.....
....DDDDDdd....
...DDDDDDDdd...
..DDDDDDDDDdd..
.DDDDDDDDDDDdd.
DDDDDDDDDDDDDdd
......TTT......
......TTT......
......TTT......
"""

# jato inimigo visto por tras (asas em delta, duas derivas, chama do motor)
JET = """
.........K.K.........
.........G.G.........
........KGLGK........
........GLLLG........
..K....GLLRLLG....K..
..GG..GLLLLLLLG..GG..
..GLGGLLLLLLLLLGGLG..
KGGLLLLLLLLLLLLLLLGGK
..KKKGGGGRRRGGGGKKK..
........KYRYK........
.........YRY.........
"""


def parse_sprite(txt):
    rows = [r for r in txt.strip('\n').split('\n')]
    h, w = len(rows), max(len(r) for r in rows)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch in PAL:
                rgba[y, x, :3] = PAL[ch]
                rgba[y, x, 3] = 255
    return Image.fromarray(rgba, 'RGBA')


TREE_IMG = parse_sprite(TREE)
JET_IMG = parse_sprite(JET)


def paste_scaled(frame, sprite, cx, bottom, scale):
    """Cola o sprite escalado (vizinho mais proximo), centrado em cx, apoiado em 'bottom'."""
    w = max(1, int(round(sprite.width * scale)))
    h = max(1, int(round(sprite.height * scale)))
    if w > 3 * W or h > 3 * H:
        return
    spr = sprite.resize((w, h), Image.NEAREST)
    frame.paste(spr, (int(round(cx - w / 2)), int(round(bottom - h))), spr)


# ---------------------------------------------------------------------------
# Camadas fixas: ceu, montanhas
# ---------------------------------------------------------------------------
def build_sky():
    sky = np.zeros((HORIZON, W, 3), dtype=np.uint8)
    n = len(SKY_BANDS)
    # faixas de alturas crescentes perto do horizonte (visual de jogo antigo)
    edges = [0, 30, 60, 85, 105, HORIZON]
    for i in range(n):
        sky[edges[i]:edges[i + 1]] = SKY_BANDS[i]
    return sky


def build_mountains(rng):
    layer = np.zeros((HORIZON, W, 4), dtype=np.uint8)

    def ridge(base, amp, color, seed_off):
        # soma de senos com periodo exato W -> emenda dos lados
        phases = [rng.uniform(0, 2 * math.pi) for _ in range(3)]
        for x in range(W):
            t = 2 * math.pi * x / W
            h = base + amp * (0.6 * math.sin(2 * t + phases[0]) +
                              0.3 * math.sin(5 * t + phases[1]) +
                              0.15 * math.sin(11 * t + phases[2]))
            top = int(HORIZON - max(2, h))
            layer[top:HORIZON, x, :3] = color
            layer[top:HORIZON, x, 3] = 255

    ridge(14, 8, MOUNTAIN_FAR, 0)
    ridge(7, 5, MOUNTAIN_NEAR, 1)
    return Image.fromarray(layer, 'RGBA')


def build_clouds(rng):
    """Faixa de nuvens com largura W (desliza e da a volta sem emenda)."""
    layer = Image.new('RGBA', (W, HORIZON), (0, 0, 0, 0))
    arr = np.array(layer)
    for _ in range(7):
        cx = rng.uniform(0, W)
        cy = rng.uniform(15, HORIZON - 35)
        for _ in range(rng.randint(3, 5)):          # cada nuvem = varias elipses
            ex = cx + rng.uniform(-18, 18)
            ey = cy + rng.uniform(-3, 3)
            rx, ry = rng.uniform(8, 16), rng.uniform(3, 6)
            for x in range(int(ex - rx), int(ex + rx) + 1):
                for y in range(int(ey - ry), int(ey + ry) + 1):
                    if 0 <= y < HORIZON and ((x - ex) / rx) ** 2 + ((y - ey) / ry) ** 2 <= 1:
                        col = CLOUD_SHADE if y > ey + ry * 0.4 else CLOUD
                        arr[y, x % W, :3] = col
                        arr[y, x % W, 3] = 255
    return Image.fromarray(arr, 'RGBA')


# ---------------------------------------------------------------------------
# Chao pseudo-3D
# ---------------------------------------------------------------------------
CAM_H = 30.0       # altura da camera
FOCAL = 160.0      # distancia focal em pixels
STRIPE = 40.0      # comprimento de cada faixa do chao (unidades do mundo)
ROAD_HALF = 25.0   # meia-largura da pista
DASH = 20.0        # comprimento da faixa central da pista


def ground_rows():
    """Distancia z de cada linha abaixo do horizonte."""
    ys = np.arange(HORIZON + 1, H)
    z = CAM_H * FOCAL / (ys - HORIZON)
    return ys, z


def draw_ground(img, cam_z, cam_x):
    ys, z = ground_rows()
    xs = np.arange(W) - W / 2
    world_z = z[:, None] + cam_z
    world_x = xs[None, :] * z[:, None] / FOCAL + cam_x
    stripe = (np.floor(world_z / STRIPE).astype(int) % 2) == 0
    stripe = np.broadcast_to(stripe, world_x.shape)
    g = np.where(stripe[..., None], np.array(GROUND_A), np.array(GROUND_B)).astype(np.uint8)
    road = np.abs(world_x) < ROAD_HALF
    g[road] = ROAD
    line = (np.abs(world_x) < 1.5) & ((np.floor(world_z / DASH).astype(int) % 2) == 0)
    g[line] = ROAD_LINE
    img[HORIZON + 1:H] = g
    img[HORIZON] = MOUNTAIN_NEAR  # linha fina no horizonte


# ---------------------------------------------------------------------------
# Cabecalho (modo arquivo FAT32)
#
# Setor de 512 bytes que vem antes do primeiro quadro. A FPGA le o cartao a
# partir do setor 0 procurando este setor; os quadros comecam no setor seguinte.
#   bytes  0-15 : "AEL_HUD_VIDEO_V1" (ASCII)
#   bytes 16-31 : os mesmos 16 bytes invertidos (NOT bit a bit) -> evita achar
#                 a assinatura por acaso
#   bytes 32-33 : largura   (little-endian)       = 320
#   bytes 34-35 : altura    (little-endian)       = 240
#   bytes 36-39 : numero de quadros (little-endian)
#   bytes 40-41 : setores por quadro (little-endian) = 150
#   byte  42    : fps
#   byte  43    : formato (1 = RGB332, RRRGGGBB)
#   resto       : zeros
# ---------------------------------------------------------------------------
MAGIC = b'AEL_HUD_VIDEO_V1'


def make_header(n_frames, fps):
    h = bytearray(512)
    h[0:16] = MAGIC
    h[16:32] = bytes((~b) & 0xFF for b in MAGIC)
    h[32:34] = W.to_bytes(2, 'little')
    h[34:36] = H.to_bytes(2, 'little')
    h[36:40] = n_frames.to_bytes(4, 'little')
    h[40:42] = (W * H // 512).to_bytes(2, 'little')
    h[42] = fps
    h[43] = 1
    return bytes(h)


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--fps', type=int, default=15)
    ap.add_argument('--segundos', type=int, default=30)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--saida', default='video.raw')
    ap.add_argument('--cabecalho', action='store_true',
                    help='poe 1 setor de cabecalho com assinatura antes dos quadros '
                         '(para copiar como arquivo comum num cartao FAT32)')
    args = ap.parse_args()

    rng = random.Random(args.seed)
    N = args.fps * args.segundos

    sky = build_sky()
    mountains = build_mountains(rng)
    clouds = build_clouds(rng)

    # O mundo se repete a cada WORLD_LEN unidades; a camera anda exatamente
    # WORLD_LEN por loop -> o ultimo quadro emenda no primeiro.
    WORLD_LEN = 2400.0                       # multiplo de STRIPE e DASH
    speed = WORLD_LEN / N

    # arvores dos dois lados da pista, em posicoes fixas no mundo
    trees = []
    z = 0.0
    while z < WORLD_LEN:
        side = rng.choice([-1, 1])
        x = side * rng.uniform(ROAD_HALF + 15, 260)
        trees.append((x, z))
        z += rng.uniform(25, 60)

    # jatos inimigos: trajetorias periodicas (periodo = divisor de N)
    jets = []
    for k in range(4):
        jets.append(dict(
            ax=rng.uniform(40, 110), ay=rng.uniform(10, 40),
            fx=rng.choice([1, 2, 3]), fy=rng.choice([1, 2, 3, 4]),
            px=rng.uniform(0, 2 * math.pi), py=rng.uniform(0, 2 * math.pi),
            cy=rng.uniform(45, 95),
            sc=rng.uniform(0.9, 1.6), fz=rng.choice([1, 2]), pz=rng.uniform(0, 2 * math.pi),
        ))

    raw = open(args.saida, 'wb')
    if args.cabecalho:
        raw.write(make_header(N, args.fps))
    ff = None
    if shutil.which('ffmpeg'):
        ff = subprocess.Popen(
            ['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
             '-s', f'{W}x{H}', '-r', str(args.fps), '-i', '-',
             '-vf', 'scale=640:480:flags=neighbor', '-pix_fmt', 'yuv420p',
             '-c:v', 'libx264', '-crf', '18', 'preview.mp4'],
            stdin=subprocess.PIPE)

    for f in range(N):
        t = f / N                                    # 0..1 ao longo do loop
        cam_z = f * speed
        cam_x = 35 * math.sin(2 * math.pi * t * 2)   # leve zigue-zague sobre a pista

        base = np.zeros((H, W, 3), dtype=np.uint8)
        base[:HORIZON] = sky
        draw_ground(base, cam_z, cam_x)
        frame = Image.fromarray(base).convert('RGBA')

        # nuvens deslizam exatamente W pixels por loop
        shift = int(round(t * W)) % W
        cl = Image.fromarray(np.roll(np.array(clouds), -shift, axis=1), 'RGBA')
        frame.alpha_composite(cl, (0, 0))
        # montanhas andam um pouco com o zigue-zague
        mshift = int(round(-cam_x * 0.3)) % W
        frame.alpha_composite(Image.fromarray(np.roll(np.array(mountains), mshift, axis=1), 'RGBA'), (0, 0))

        # arvores: de longe para perto
        visible = []
        for (x, z0) in trees:
            dz = (z0 - cam_z) % WORLD_LEN
            if 8 < dz < 900:
                visible.append((dz, x))
        for dz, x in sorted(visible, reverse=True):
            s = FOCAL / dz
            sx = W / 2 + (x - cam_x) * s
            sy = HORIZON + CAM_H * s
            paste_scaled(frame, TREE_IMG, sx, sy, s * 2.2)

        # jatos inimigos (desenhados por cima de tudo, estao no ar)
        for j in jets:
            a = 2 * math.pi * t
            jx = W / 2 + j['ax'] * math.sin(j['fx'] * a + j['px'])
            jy = j['cy'] + j['ay'] * math.sin(j['fy'] * a + j['py'])
            sc = j['sc'] * (1 + 0.35 * math.sin(j['fz'] * a + j['pz']))  # aproxima/afasta
            paste_scaled(frame, JET_IMG, jx, jy, sc)

        rgb = np.array(frame.convert('RGB'))
        # empacota em RGB332: RRRGGGBB
        r = rgb[..., 0] >> 5
        g = rgb[..., 1] >> 5
        b = rgb[..., 2] >> 6
        raw.write(((r << 5) | (g << 2) | b).astype(np.uint8).tobytes())

        if ff:
            ff.stdin.write(rgb.tobytes())
        if f == N // 3:
            Image.fromarray(rgb).resize((W * 2, H * 2), Image.NEAREST).save('quadro_exemplo.png')

    raw.close()
    if ff:
        ff.stdin.close()
        ff.wait()
    print(f'{N} quadros, {N * W * H} bytes ({N * 150} setores de 512 B)')


if __name__ == '__main__':
    main()

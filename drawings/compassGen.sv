module compassGen #(
    parameter int CX = 320,
    parameter int HALF_W = 100, // meia largura da fita (px)
    parameter int TAPE_Y = 120, // y da linha
    parameter int THICKNESS = 2,
    parameter int PPD = 2, // pixels por grau
    parameter int BAR_DEG = 10, // uma barra a cada 10 graus (precisa dividir 360)
    parameter int BAR_W = 2, // largura da barra (px)
    parameter int BAR_H = 10, // altura da barra (px)
    parameter int N_BAR_H = 18, // altura da barra do NORTE (px): bem maior que as barras normais
    parameter int N_GAP = 3, // espaço entre o topo da barra do norte e a letra N (px)
    parameter bit SIGNED_HEADING  = 1'b0   // 0: heading 0..359 / 1: -180..179
)(
    input  logic clk,
    input  logic rstN,
    input  logic [9:0] x,
    input  logic [9:0] y,
    input  logic validPixel,
    input  logic signed [8:0] compassHeading,
    input  logic [3:0] compassFrac, // 1/16 de grau
    output logic drawCompass
);

localparam int SPACING = PPD * BAR_DEG; // pixels entre barras
localparam int WRAP = 360 * PPD; // múltiplo de SPACING: só mantém a soma positiva

// heading em pixels (com a fração)
logic signed [15:0] hdgS;
logic [15:0] headPx;

assign hdgS   = SIGNED_HEADING ? 16'($signed(compassHeading)) : 16'({1'b0, compassHeading});
assign headPx = hdgS * PPD + ((compassFrac * PPD) >> 4);

// posição do pixel dentro do padrão de barras
logic signed [11:0] distX;
logic signed [15:0] sum;
logic [15:0] phase;

assign distX = $signed({2'b00, x}) - 12'(CX);
assign sum   = $signed(headPx) + 16'(distX) + 16'(WRAP);
assign phase = sum % SPACING;

// formas
logic inTape, drawLine, drawBars;

assign inTape   = (distX >= -HALF_W) && (distX <= HALF_W);
assign drawLine = inTape && (y >= TAPE_Y) && (y < TAPE_Y + THICKNESS);
assign drawBars = inTape && (phase < BAR_W) && (y >= TAPE_Y - BAR_H) && (y < TAPE_Y);

// ---------- Marca do NORTE ----------
// O norte é o ângulo 0. Ele aparece na fita como uma barra grossa e bem mais alta que as outras, com uma letra N em cima.
// Ela desliza junto com a fita: com o ângulo em 0 fica no centro da tela, e conforme você gira ela anda para o lado.
// (O compass é uma simulação, então "norte" aqui é o ângulo em que o compass estava quando foi ligado, não o norte de verdade.)
//
// pos = posição do pixel na escala de graus, em pixels. pos = 0 é o ângulo 0 (norte); pos = 360*PPD é o ângulo 360, que é o mesmo norte.
// dN  = distância do pixel até o norte mais próximo (negativo = à esquerda do norte). Sem divisão nem resto: só uma subtração.
localparam int N_GLYPH_W = 12; // largura da letra N (px)
localparam int N_GLYPH_H = 14; // altura da letra N (px)
localparam int N_GLYPH_TOP = TAPE_Y - N_BAR_H - N_GAP - N_GLYPH_H; // y da primeira linha da letra

logic signed [16:0] pos;
logic signed [16:0] dN;

assign pos = $signed({1'b0, headPx}) + 17'(distX);
assign dN  = (pos > $signed(17'(WRAP / 2))) ? (pos - 17'(WRAP)) : pos;

// Barra do norte: 4 pixels de largura, centrada no norte (as barras normais têm BAR_W = 2).
logic drawNorthBar;
assign drawNorthBar = inTape && (dN >= -1) && (dN <= 2) && (y >= TAPE_Y - N_BAR_H) && (y < TAPE_Y);

// Letra N, desenhada pixel a pixel numa caixa de 12 x 14 centrada no norte:
//   gc = coluna dentro da caixa (0 a 11), gr = linha dentro da caixa (0 a 13).
//   Traço da esquerda: colunas 0 e 1. Traço da direita: colunas 10 e 11. Diagonal: desce da coluna 2 (no topo) até a 9 (embaixo), com 2 pixels de grossura.
logic signed [11:0] gc;
logic signed [11:0] gr;
logic signed [11:0] gDiag;
logic inGlyphBox;
logic drawNorthLetter;

assign gc    = 12'(dN) + 12'sd5;
assign gr    = $signed({2'b00, y}) - 12'(N_GLYPH_TOP);
assign gDiag = 12'sd2 + ((gr * 12'sd9) >>> 4);

assign inGlyphBox = inTape && (gc >= 0) && (gc < N_GLYPH_W) && (gr >= 0) && (gr < N_GLYPH_H);
assign drawNorthLetter = inGlyphBox && ((gc <= 1) || (gc >= 10) || ((gc >= gDiag) && (gc <= gDiag + 1)));

assign drawCompass = validPixel & (drawLine | drawBars | drawNorthBar | drawNorthLetter);

endmodule

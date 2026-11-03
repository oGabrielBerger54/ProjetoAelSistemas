// O QUE ESTE MÓDULO FAZ
//  Desenha a escala vertical de altitude (a "fita") na esquerda da tela:
//   - duas linhas verticais finas (a fita),
//   - risquinhos grandes (a cada 32 linhas da tela) e pequenos (a cada 16),
//   - um ponteiro em forma de triângulo, parado no meio da altura da tela, apontando para a fita,
//   - a MARCA DO ZERO: um risco grosso e comprido, com um "0" (caixa) ao lado. Ela desliza junto com a fita e mostra onde está a altura de referência.
//     Com altOffset = 0 a marca fica exatamente no ponteiro. Se você subir, ela desce (e vice-versa).
//  O desenho é o mesmo da versão antiga. O que mudou é COMO ele é calculado: agora é SEQUENCIAL, igual ao horizonGen.

// O QUE MUDOU (versão antiga -> esta)
//  Antes: em CADA pixel, somava y + altOffset e testava se o resultado dava um risquinho.
//  Agora: tapeLevel (um registrador) guarda o valor de y + altOffset da linha atual.
//   - Quando termina uma linha da tela, tapeLevel soma 1 (a próxima linha tem y + 1).
//   - Quando termina o quadro, tapeLevel recomeça em altOffset (a primeira linha tem y = 0).
//   - altOffset só é lido UMA vez por quadro. Assim, se ele mudar no meio do desenho, a escala não "rasga" ao meio.

// COMO O RISQUINHO É ESCOLHIDO
//  Se tapeLevel for múltiplo de 32 -> risquinho grande. Se for múltiplo de 16 -> risquinho pequeno.
//  Múltiplo de 32 = os 5 bits de baixo são 0.  Múltiplo de 16 = os 4 bits de baixo são 0. (Sem divisão, só olhar os bits.)
//  Subir o altOffset de 1 faz cada risquinho aparecer 1 linha MAIS ACIMA, ou seja, a escala sobe na tela.
//  Valores negativos funcionam sozinhos: tapeLevel tem 12 bits e 4096 é múltiplo de 32, então a conta "dá a volta" sem erro.

// DE ONDE VÊM OS DADOS
//  altOffset <- barToAlt.altOffset. É o quanto a escala desliza, em pixels, com sinal.
//  x, y, validPixel <- coordGen (mesmos sinais que o horizonGen usa).

module altGen #(
    parameter int CY = 240, // altura do meio da tela (onde fica o ponteiro)
    parameter int TAPE_X = 120, // posição horizontal da fita na tela
    parameter int TAPE_HALF_HEIGHT = 160, // a fita ocupa de CY-160 até CY+160
    parameter int POINTER_START = 4, // o ponteiro começa 4 pixels à direita da fita
    parameter int POINTER_LENGTH = 12, // comprimento do ponteiro (e metade da altura da base dele)
    parameter int ZERO_TICK_LEN = 44, // a marca do zero é um risco grosso de 44 pixels para a esquerda da fita (os risquinhos grandes têm só 16)
    parameter int ZERO_BOX_LEFT = 62, // a "caixa do zero" (um 0 desenhado como retângulo) começa 62 pixels à esquerda da fita...
    parameter int ZERO_BOX_RIGHT = 50, // ...e termina 50 pixels à esquerda da fita (13 pixels de largura)
    parameter int ZERO_BOX_HALF = 7, // metade da altura da caixa do zero
    parameter int H_LAST = 639, // último x visível
    parameter int V_LAST = 479 // último y visível
)(
    input logic clk,
    input logic rstN,
    input logic unsigned [9:0] x,
    input logic unsigned [9:0] y,
    input logic signed [11:0] altOffset, // pixels que a escala desliza (vem do barToAlt)
    input logic validPixel,
    output logic drawAlt
);

// ---------- Marcadores de fim de linha e fim de quadro (igual ao horizonGen) ----------
logic lineEnd;
logic frameEnd;
assign lineEnd = validPixel && (x == H_LAST);
assign frameEnd = lineEnd && (y == V_LAST);

// ---------- Parte sequencial: tapeLevel = y + altOffset da linha atual ----------
logic [11:0] tapeLevel;

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        tapeLevel <= '0; // no reset, y = 0 e altOffset = 0
    end else if(frameEnd) begin
        tapeLevel <= 12'(altOffset); // próxima linha é y = 0: tapeLevel = 0 + altOffset
    end else if(lineEnd) begin
        tapeLevel <= tapeLevel + 1'b1; // próxima linha: y aumenta 1
    end
end

// ---------- Risquinhos ----------
logic isMajorTick;
logic isMinorTick;
assign isMajorTick = (tapeLevel[4:0] == 5'd0); // múltiplo de 32
assign isMinorTick = (tapeLevel[3:0] == 4'd0); // múltiplo de 16

// ---------- Marca do zero ----------
// O "zero" da altura é o nível tapeLevel == CY: com altOffset = 0 ele cai exatamente na linha do ponteiro.
// zeroDist = quantas linhas a linha atual está do zero (0 = é a linha do zero; negativo = acima; positivo = abaixo).
// A conta "dá a volta" em 12 bits, então vale também para tapeLevel negativo.
logic signed [11:0] zeroDist;
assign zeroDist = $signed(tapeLevel - 12'(CY));

// ---------- Posição vertical: a fita só existe perto do meio da tela ----------
logic inInterval;
assign inInterval = (y >= CY - TAPE_HALF_HEIGHT) && (y <= CY + TAPE_HALF_HEIGHT);

// ---------- Ponteiro (triângulo) ----------
// pointerDist = quantos pixels o x atual está depois do começo do ponteiro (0 na ponta). A altura do triângulo cresce junto com ele.
logic signed [11:0] signedY;
logic signed [11:0] pointerDist;
assign signedY = $signed({2'b00, y});
assign pointerDist = $signed({2'b00, x}) - 12'(TAPE_X + POINTER_START);

// ---------- Sinais de desenho ----------
logic drawTapeLine;
logic drawTapeTicks;
logic drawTapePointer;
logic drawZeroTick;
logic drawZeroBox;

always_comb begin
    // Duas linhas de grossura
    drawTapeLine = (x == TAPE_X) || (x == TAPE_X + 1);

    // Risquinho grande: 16 pixels para a esquerda da fita. Pequeno: 8 pixels.
    drawTapeTicks = (x <= TAPE_X) && ((isMajorTick && (x >= TAPE_X - 16)) || (isMinorTick && (x >= TAPE_X - 8)));

    // Triângulo: em cada coluna, desenha de CY - pointerDist até CY + pointerDist
    drawTapePointer = (pointerDist >= 0) && (pointerDist <= POINTER_LENGTH)
                   && (signedY >= CY - pointerDist) && (signedY <= CY + pointerDist);

    // Marca do zero, parte 1: risco grosso (3 linhas) e bem mais comprido que os outros, na linha do zero
    drawZeroTick = (zeroDist >= -1) && (zeroDist <= 1) && (x >= TAPE_X - ZERO_TICK_LEN) && (x <= TAPE_X);

    // Marca do zero, parte 2: um retângulo vazio (parece um "0") ao lado do risco, centrado na linha do zero
    drawZeroBox = (zeroDist >= -ZERO_BOX_HALF) && (zeroDist <= ZERO_BOX_HALF)
               && (x >= TAPE_X - ZERO_BOX_LEFT) && (x <= TAPE_X - ZERO_BOX_RIGHT)
               && ((x == TAPE_X - ZERO_BOX_LEFT) || (x == TAPE_X - ZERO_BOX_RIGHT)
                   || (zeroDist == -ZERO_BOX_HALF) || (zeroDist == ZERO_BOX_HALF));

    if(validPixel && ((inInterval && (drawTapeLine || drawTapeTicks || drawZeroTick || drawZeroBox)) || drawTapePointer)) begin
        drawAlt = 1'b1;
    end else begin
        drawAlt = 1'b0;
    end
end

endmodule

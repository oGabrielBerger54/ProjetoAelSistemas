// O QUE ESTE MÓDULO FAZ
//  Desenha a escala vertical de altitude (a "fita") na esquerda da tela:
//   - duas linhas verticais finas (a fita),
//   - risquinhos grandes (a cada 32 linhas da tela) e pequenos (a cada 16),
//   - um ponteiro em forma de triângulo, parado no meio da altura da tela, apontando para a fita.

// COMO O RISQUINHO É ESCOLHIDO
//  Se tapeLevel for múltiplo de 32 -> risquinho grande. Se for múltiplo de 16 -> risquinho pequeno.
//  Múltiplo de 32 = os 5 bits de baixo são 0.  Múltiplo de 16 = os 4 bits de baixo são 0.
//  Subir o altOffset em 1 faz cada risquinho aparecer 1 linha MAIS ACIMA, ou seja, a escala sobe na tela.\

module altGen #(
    parameter int CY = 240, // altura do meio da tela (onde fica o ponteiro)
    parameter int TAPE_X = 120, // posição horizontal da fita na tela
    parameter int TAPE_HALF_HEIGHT = 160, // a fita ocupa de CY-160 até CY+160
    parameter int POINTER_START = 4, // o ponteiro começa 4 pixels à direita da fita
    parameter int POINTER_LENGTH = 12, // comprimento do ponteiro (e metade da altura da base dele)
    parameter int H_LAST = 639, // último x visível
    parameter int V_LAST = 479 // último y visível
)(
    input logic clk,
    input logic rstN,
    input logic unsigned [9:0] x,
    input logic unsigned [9:0] y,
    input logic signed [11:0] altOffset, // quantos pixels a escala de altitude deve deslizar na tela(vem do barToAlt)
    input logic validPixel,
    output logic drawAlt
);

logic lineEnd;
logic frameEnd;
assign lineEnd = validPixel && (x == H_LAST);
assign frameEnd = lineEnd && (y == V_LAST);

logic [11:0] tapeLevel; // em que posição da fita está a linha da tela que estou desenhando agora

// o deslizar da tela
always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        tapeLevel <= '0; // no reset, y = 0 e altOffset = 0
    end else if(frameEnd) begin
        tapeLevel <= 12'(altOffset); // próxima linha é y = 0: tapeLevel = 0 + altOffset
    end else if(lineEnd) begin
        tapeLevel <= tapeLevel + 1'b1; // próxima linha: y aumenta 1
    end
end

logic isMajorTick;
logic isMinorTick;
assign isMajorTick = (tapeLevel[4:0] == 5'd0); // múltiplo de 32
assign isMinorTick = (tapeLevel[3:0] == 4'd0); // múltiplo de 16

logic inInterval;
assign inInterval = (y >= CY - TAPE_HALF_HEIGHT) && (y <= CY + TAPE_HALF_HEIGHT);

// pointerDist = quantos pixels o x atual está depois do começo do ponteiro (0 na ponta). A altura do triângulo cresce junto com ele.
logic signed [11:0] signedY;
logic signed [11:0] pointerDist;
assign signedY = $signed({2'b00, y});
assign pointerDist = $signed({2'b00, x}) - 12'(TAPE_X + POINTER_START);

logic drawTapeLine;
logic drawTapeTicks;
logic drawTapePointer;

always_comb begin
    // Duas linhas de grossura
    drawTapeLine = (x == TAPE_X) || (x == TAPE_X + 1);

    // Risquinho grande: 16 pixels para a esquerda da fita. Pequeno: 8 pixels.
    drawTapeTicks = (x <= TAPE_X) && ((isMajorTick && (x >= TAPE_X - 16)) || (isMinorTick && (x >= TAPE_X - 8)));

    // Triângulo: em cada coluna, desenha de CY - pointerDist até CY + pointerDist
    drawTapePointer = (pointerDist >= 0) && (pointerDist <= POINTER_LENGTH)
                   && (signedY >= CY - pointerDist) && (signedY <= CY + pointerDist);

    if(validPixel && ((inInterval && (drawTapeLine || drawTapeTicks)) || drawTapePointer)) begin
        drawAlt = 1'b1;
    end else begin
        drawAlt = 1'b0;
    end
end
endmodule

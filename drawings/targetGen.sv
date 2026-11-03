// O QUE ESTE MÓDULO FAZ
//  Desenha a MIRA (marcador de alvo) na posição que o joystick escolheu:
//   - 4 cantos em forma de "L" (um quadrado aberto) em volta da posição,
//   - um pontinho no centro,
//   - se estiver TRAVADA: o quadrado fecha (as 4 bordas inteiras). Dá para ver na tela que travou.
//  Não confundir com o retículo central (reticleGen): o retículo fica sempre no meio. Esta mira é a que anda.

// COMO FUNCIONA (igual ao horizonGen)
//  targetX, targetY e targetLocked só são copiados para dentro daqui no FIM de cada quadro (frameEnd).
//  Assim, se o joystick mexer no meio do desenho, a mira não se "parte em duas" (uma metade no lugar velho e outra no novo).
//  Depois, o desenho é só comparar o pixel atual (x, y) com a posição guardada (tx, ty).

// DE ONDE VÊM OS DADOS
//  targetX, targetY, targetLocked <- joyToTarget.
//  x, y, validPixel <- coordGen (mesmos sinais que o horizonGen usa).

module targetGen #(
    parameter int HALF = 14, // metade do lado do quadrado (o quadrado todo tem 2 x 14 + 1 = 29 pixels)
    parameter int ARM = 6, // comprimento de cada "perna" do L, em pixels
    parameter int H_LAST = 639, // último x visível
    parameter int V_LAST = 479 // último y visível
)(
    input logic clk,
    input logic rstN,
    input logic unsigned [9:0] x,
    input logic unsigned [9:0] y,
    input logic [9:0] targetX, // posição da mira (coluna), vem do joyToTarget
    input logic [9:0] targetY, // posição da mira (linha), vem do joyToTarget
    input logic targetLocked, // 1 = mira travada
    input logic validPixel,
    output logic drawTarget
);

logic frameEnd;
assign frameEnd = validPixel && (x == H_LAST) && (y == V_LAST);

// Posição e trava, copiadas no fim de cada quadro (ficam fixas durante o desenho do quadro).
logic signed [11:0] tx, ty;
logic locked;

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        tx <= 12'((H_LAST + 1) / 2);
        ty <= 12'((V_LAST + 1) / 2);
        locked <= 1'b0;
    end else if(frameEnd) begin
        tx <= $signed({2'b00, targetX});
        ty <= $signed({2'b00, targetY});
        locked <= targetLocked;
    end
end

// Distância do pixel atual até o centro da mira, sem sinal (só o tamanho da distância).
logic signed [11:0] distX, distY;
logic [11:0] absDistX, absDistY;

assign distX = $signed({2'b00, x}) - tx;
assign distY = $signed({2'b00, y}) - ty;
assign absDistX = distX[11] ? (~distX + 1'b1) : distX;
assign absDistY = distY[11] ? (~distY + 1'b1) : distY;

logic drawCorners;
logic drawBox;
logic drawDot;

always_comb begin
    // Cantos: nas 4 pontas do quadrado, uma perna de ARM pixels para cada lado.
    drawCorners = ((absDistX == HALF) && (absDistY <= HALF) && (absDistY >= HALF - ARM))
               || ((absDistY == HALF) && (absDistX <= HALF) && (absDistX >= HALF - ARM));

    // Quadrado fechado: as 4 bordas inteiras. Só aparece quando está travada.
    drawBox = ((absDistX == HALF) && (absDistY <= HALF))
           || ((absDistY == HALF) && (absDistX <= HALF));

    // Pontinho no centro: 3 x 3 pixels
    drawDot = (absDistX <= 1) && (absDistY <= 1);

    if(validPixel) begin
        drawTarget = drawCorners || drawDot || (locked && drawBox);
    end else begin
        drawTarget = 1'b0;
    end
end

endmodule

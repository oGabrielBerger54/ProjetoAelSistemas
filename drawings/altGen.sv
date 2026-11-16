module altGen #(
    parameter int CY = 240, // altura do meio da tela (onde fica o ponteiro)
    parameter int TAPE_X = 60, // posição horizontal da fita na tela
    parameter int TAPE_HALF_HEIGHT = 200, // a fita ocupa de CY-160 até CY+160
    parameter int POINTER_START = 4, // o ponteiro começa 4 pixels à direita da fita
    parameter int POINTER_LENGTH = 12, // comprimento do ponteiro (e metade da altura da base dele)
    parameter int H_LAST = 639, // último x visível
    parameter int V_LAST = 479, // último y visível
    parameter bit MIRROR = 1'b0, // 1 = espelhado: risquinhos para a direita e ponteiro para a esquerda
    parameter int LABEL_DIGITS = 4, // dígitos do número nas marcas grandes
    parameter int LABEL_SCALE  = 1, // tamanho da fonte (cada pixel da fonte vira LABEL_SCALE x LABEL_SCALE)
    parameter int LABEL_GAP    = 3, // espaço entre a marca grande e o número
    parameter int FT_PER_TICK  = 100 // pés por marca grande (valor fictício)
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

logic signed [13:0] aLevel; // altitude (em pixels da fita) da linha da tela que estou desenhando agora: sobe para cima da tela

// o deslizar da tela: quando altOffset aumenta, a escala desce
always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        aLevel <= 14'(CY); // no reset, altOffset = 0 e a linha y = 0 está CY pixels acima do ponteiro
    end else if(frameEnd) begin
        aLevel <= 14'(altOffset) + 14'(CY); // próxima linha é y = 0
    end else if(lineEnd) begin
        aLevel <= aLevel - 1'b1; // próxima linha: y aumenta 1, a altitude cai 1
    end
end

// ---------- Risquinhos ----------
logic isMajorTick;
logic isMinorTick;
assign isMajorTick = (aLevel[4:0] == 5'd0); // múltiplo de 32
assign isMinorTick = (aLevel[3:0] == 4'd0); // múltiplo de 16

// ---------- Posição vertical: a fita só existe perto do meio da tela ----------
logic inInterval;
assign inInterval = (y >= CY - TAPE_HALF_HEIGHT) && (y <= CY + TAPE_HALF_HEIGHT);

logic signed [11:0] signedY;
logic signed [11:0] pointerDist;
assign signedY = $signed({2'b00, y});
assign pointerDist = MIRROR ? 12'(TAPE_X + 1 - POINTER_START) - $signed({2'b00, x})
                            : $signed({2'b00, x}) - 12'(TAPE_X + POINTER_START);

// ---- números nas marcas grandes ----
localparam int LABEL_CELL = 6 * LABEL_SCALE;
localparam int LABEL_W    = LABEL_DIGITS * LABEL_CELL - LABEL_SCALE;   // largura visível com todos os dígitos
localparam int LABEL_H    = 7 * LABEL_SCALE;
localparam int LABEL_OFFS = LABEL_H / 2;
// esquerda: o número termina LABEL_GAP antes da marca; espelhado: começa LABEL_GAP depois dela
localparam int LABEL_X0   = MIRROR ? (TAPE_X + 18 + LABEL_GAP) : (TAPE_X - 16 - LABEL_GAP - LABEL_W);

logic [4:0]  lvlRow;       // linha do número (0 = topo): aLevel diminui 1 por linha, então LABEL_OFFS - aLevel
logic signed [13:0] tickN; // índice da marca grande a que esta linha pertence (altitude da marca = tickN * 32 px)
logic signed [11:0] tickY; // y da marca grande a que esta linha pertence
logic inLabelRow;
logic [9:0] labelX, labelY;
logic [15:0] labelVal;
logic drawLabel;

assign lvlRow = 5'(LABEL_OFFS) - aLevel[4:0];
assign tickN  = (aLevel + $signed({9'b0, lvlRow}) - 14'(LABEL_OFFS)) >>> 5;
assign tickY  = signedY + 12'(LABEL_OFFS) - $signed({7'b0, lvlRow});
// altitude negativa não tem número (só a marca)
assign inLabelRow = (lvlRow < LABEL_H) && !tickN[13] &&
                    (tickY >= CY - TAPE_HALF_HEIGHT) && (tickY <= CY + TAPE_HALF_HEIGHT);
assign labelVal = 16'(tickN[10:0]) * FT_PER_TICK;   // marca n vale n * FT_PER_TICK

// no lado espelhado o número fica colado na marca (alinhado à esquerda)
assign labelX = x;
assign labelY = inLabelRow ? 10'(lvlRow) : 10'h3FF;

numberGen #(.X0(LABEL_X0), .Y0(0), .NDIGITS(LABEL_DIGITS), .SCALE(LABEL_SCALE)) u_label (
    .x(labelX), .y(labelY), .validPixel(validPixel),
    .value(labelVal), .drawNumber(drawLabel)
);

logic drawTapeLine;
logic drawTapeTicks;
logic drawTapePointer;
logic drawLimiter;

always_comb begin
    // Duas linhas de grossura
    drawTapeLine = (x == TAPE_X) || (x == TAPE_X + 1);

    // Risquinho grande: 16 pixels para fora da fita. Pequeno: 8 pixels.
    if(MIRROR) begin
        drawTapeTicks = (x >= TAPE_X + 1) && ((isMajorTick && (x <= TAPE_X + 17)) || (isMinorTick && (x <= TAPE_X + 9)));
        drawLimiter = ((x >= TAPE_X - 18) && (x <= TAPE_X + 18)) && 
                       ((y == CY+TAPE_HALF_HEIGHT || (y == CY+TAPE_HALF_HEIGHT+1))||(y == CY-TAPE_HALF_HEIGHT)||(y == CY-TAPE_HALF_HEIGHT-1)) ;
    
    end else begin
        drawTapeTicks = (x <= TAPE_X) && ((isMajorTick && (x >= TAPE_X - 16)) || (isMinorTick && (x >= TAPE_X - 8)));
        drawLimiter = ((x >= TAPE_X - 18) && (x <= TAPE_X + 18)) && 
                       ((y == CY+TAPE_HALF_HEIGHT || (y == CY+TAPE_HALF_HEIGHT+1))||(y == CY-TAPE_HALF_HEIGHT)||(y == CY-TAPE_HALF_HEIGHT-1)) ;
    end

    // Triângulo: em cada coluna, desenha de CY - pointerDist até CY + pointerDist
    drawTapePointer = (pointerDist >= 0) && (pointerDist <= POINTER_LENGTH)
                   && (signedY >= CY - pointerDist) && (signedY <= CY + pointerDist);

    if(validPixel && ((inInterval && (drawTapeLine || drawTapeTicks)) || drawTapePointer || drawLabel || drawLimiter)) begin
        drawAlt = 1'b1;
    end else begin
        drawAlt = 1'b0;
    end
end

endmodule
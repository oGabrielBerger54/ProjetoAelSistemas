module altGen #(
    parameter int CY = 240, // altura do meio da tela (onde fica o ponteiro)
    parameter int TAPE_X = 50, // posição horizontal da fita na tela
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

logic [11:0] lvl;
logic [4:0]  lvlRow;       // linha dentro do bloco de 32 (0 = LABEL_OFFS linhas antes da marca)
logic signed [11:0] tickY; // y da marca grande a que esta linha pertence
logic inLabelRow;
logic [9:0] labelX, labelY;
logic [15:0] labelVal;
logic [3:0] nLead;         // dígitos escondidos à esquerda
logic drawLabel;

assign lvl    = tapeLevel + 12'(LABEL_OFFS);
assign lvlRow = lvl[4:0];
assign tickY  = signedY + 12'(LABEL_OFFS) - $signed({7'b0, lvlRow});
assign inLabelRow = (lvlRow < LABEL_H) &&
                    (tickY >= CY - TAPE_HALF_HEIGHT) && (tickY <= CY + TAPE_HALF_HEIGHT);
assign labelVal = 16'(lvl[11:5]) * FT_PER_TICK;   // marca n vale n * FT_PER_TICK

always_comb begin
    int d, p;
    d = 1; p = 10;
    for (int i = 1; i < LABEL_DIGITS; i++) begin
        if (int'(labelVal) >= p) d = i + 1;
        p = p * 10;
    end
    nLead = 4'(LABEL_DIGITS - d);
end

// no lado espelhado o número fica colado na marca (alinhado à esquerda)
assign labelX = MIRROR ? 10'(x + nLead * LABEL_CELL) : x;
assign labelY = inLabelRow ? 10'(lvlRow) : 10'h3FF;

numberGen #(.X0(LABEL_X0), .Y0(0), .NDIGITS(LABEL_DIGITS), .SCALE(LABEL_SCALE), .HIDE_ZEROS(1'b1)) u_label (
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
module horizonGen #(
    parameter int CX = 320,
    parameter int CY = 240,
    parameter int RADIUS = 60,
    parameter int GAP = RADIUS + 10,
    parameter int INNER_LINE_LENGTH = 40,
    parameter int STEP_WIDTH = 20,
    parameter int STEP_HEIGHT = 10,
    parameter int H_LAST = 639, // último x visível
    parameter int V_LAST = 479  // último y visível
)(
    input logic clk,
    input logic rstN,
    input logic unsigned [9:0] x,
    input logic unsigned [9:0] y,
    input logic signed [8:0] horizonVerticalDelta, // deslocamento vertical (pixels)
    input logic signed  [9:0] horizonHorizontalDelta, // inclinação (fator / 256)
    input logic validPixel,
    output logic drawHorizon
);

logic frameEnd;
assign frameEnd = validPixel && (x == H_LAST) && (y == V_LAST);

logic signed [11:0] baseY; // CY + horizonVerticalDelta (fixo durante o quadro)
logic signed [23:0] slope; // horizonHorizontalDelta (fixo durante o quadro)

logic signed [23:0] lineStartAcc; // Ponto de partida do acumulador

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        baseY <= 12'(CY);
        slope <= '0;
        lineStartAcc <= '0;
    end else if(frameEnd) begin
        baseY <= 12'(CY) + horizonVerticalDelta;
        slope <= horizonHorizontalDelta; // extensão de sinal
        lineStartAcc <= 24'(horizonHorizontalDelta * (-CX)); // 1 multiplicação por quadro
    end
end

logic signed [23:0] acc; // acumulador de distX × slope

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        acc <= '0;
    end else if(validPixel) begin
        acc <= acc + slope; // próximo pixel: distX aumenta 1
    end else begin
        acc <= lineStartAcc; // fora da área visível: prepara x = 0
    end
end

logic signed [11:0] distX;
logic [11:0] absDistX;
logic signed [11:0] signedY;
logic signed [11:0] verticalDelta;
logic signed [11:0] horizonY; // altura da linha do horizonte na coluna x atual

assign signedY = $signed({2'b00, y});
assign distX = $signed({2'b00, x}) - 12'(CX);
assign absDistX = distX[11] ? (~distX + 1'b1) : distX; 
assign verticalDelta = acc[19:8]; // == (tirar copias do sinal) (distX * slope) (>>> 8 joga fora os 8 bits de baixo)
assign horizonY = baseY + verticalDelta;

// Correspondência vertical com a linha do horizonte e a linha do degrau
logic matchBaseY;
logic matchStepTopY;

assign matchBaseY    = (signedY >= horizonY) && (signedY <= horizonY + 1);
// "-" porque o degrau fica acima da linha (o eixo Y cresce para baixo)
assign matchStepTopY = (signedY >= horizonY - STEP_HEIGHT) && (signedY <= horizonY - STEP_HEIGHT + 1);

logic drawInnerLine;
logic drawStepInnerVert;
logic drawStepTop;
logic drawStepOuterVert;
logic drawOuterLine;

always_comb begin
    drawInnerLine     = (absDistX >= GAP) && (absDistX < GAP + INNER_LINE_LENGTH) && matchBaseY;
    drawStepInnerVert = (absDistX == GAP + INNER_LINE_LENGTH) && (signedY <= horizonY) && (signedY >= horizonY - STEP_HEIGHT);
    drawStepTop       = (absDistX >= GAP + INNER_LINE_LENGTH) && (absDistX < GAP + INNER_LINE_LENGTH + STEP_WIDTH) && matchStepTopY;
    drawStepOuterVert = (absDistX == GAP + INNER_LINE_LENGTH + STEP_WIDTH) && (signedY <= horizonY) && (signedY >= horizonY - STEP_HEIGHT);
    drawOuterLine     = (absDistX >= GAP + INNER_LINE_LENGTH + STEP_WIDTH) && matchBaseY;

    if(validPixel) begin
        drawHorizon = drawOuterLine || drawInnerLine || drawStepTop || drawStepOuterVert || drawStepInnerVert;
    end else begin
        drawHorizon = 1'b0;
    end
end

endmodule

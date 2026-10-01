module horizonGen (
    input logic unsigned [9:0] x,
    input logic unsigned [9:0] y,
    input logic signed [8:0] horizonVerticalDelta,
    input logic signed [9:0] horizonHorizontalDelta,
    input logic validPixel,
    output logic drawHorizon
);

parameter CX = 320; 
parameter CY = 240; 
parameter RADIUS = 60;
parameter GAP = RADIUS + 10; 

parameter INNER_LINE_LENGTH = 40; 
parameter STEP_WIDTH = 20; 
parameter STEP_HEIGHT = 10; 

// Coordenadas e distâncias
logic [11:0] absDistX; 
logic signed [11:0] distX; 

logic signed [11:0] signedY;
assign signedY = $signed({1'b0, y});

logic signed [11:0] horizonY; // Altura exata que deve ser ocupada pela linha do horizonte em cada coluna X (eixo Y) da tela


assign distX = $signed({1'b0, x}) - $signed(CX);
assign absDistX = (distX[11] == 1) ? (~distX + 1) : distX;

// Cálculo da inclinação lateral
logic signed [11:0] verticalDelta;

logic signed [23:0] distXExpanded; 
logic signed [23:0] horizonHorizontalDeltaExpanded; 
logic signed [23:0] verticalDeltaExpanded; 

assign distXExpanded = distX;
assign horizonHorizontalDeltaExpanded = horizonHorizontalDelta;

// Multiplica a distância horizontal pelo fator do giroscópio para inclinar a linha proporcionalmente ao afastamento do centro.
assign verticalDeltaExpanded = (distXExpanded * horizonHorizontalDeltaExpanded) >>> 8;
assign verticalDelta = verticalDeltaExpanded[11:0];

assign horizonY = $signed(CY) + horizonVerticalDelta + verticalDelta; 

// Correspondência vertical com a linha do horizonte e linhan do degrau
logic matchBaseY; 
logic matchStepTopY; 

assign matchBaseY = (signedY >= horizonY) && (signedY <= horizonY + 1); // Linha do horizonte é de 1 pixel de altura
// Sinal de "-" por que a linha do degrau esta mais acima, por que o eixo Y cresce para baixo, então o topo do degrau é menor que a linha do horizonte
assign matchStepTopY = (signedY >= horizonY - STEP_HEIGHT) && (signedY <= horizonY - STEP_HEIGHT + 1);

// Sinais de desenho
logic drawInnerLine; 
logic drawStepInnerVert; 
logic drawStepTop; 
logic drawStepOuterVert; 
logic drawOuterLine; 

always_comb begin
    drawInnerLine = (absDistX >= GAP) && (absDistX < GAP + INNER_LINE_LENGTH) && matchBaseY;
    drawStepInnerVert = (absDistX == GAP + INNER_LINE_LENGTH) && (signedY <= horizonY) && (signedY >= horizonY - STEP_HEIGHT);
    drawStepTop = (absDistX >= GAP + INNER_LINE_LENGTH) && (absDistX < GAP + INNER_LINE_LENGTH + STEP_WIDTH) && matchStepTopY;
    drawStepOuterVert = (absDistX == GAP + INNER_LINE_LENGTH + STEP_WIDTH) && (signedY <= horizonY) && (signedY >= horizonY - STEP_HEIGHT);
    drawOuterLine = (absDistX >= GAP + INNER_LINE_LENGTH + STEP_WIDTH) && matchBaseY;

    if (validPixel == 1) begin
        drawHorizon = (drawOuterLine || drawInnerLine || drawStepTop || drawStepOuterVert || drawStepInnerVert);
    end else begin
        drawHorizon = 0;
    end
end
endmodule

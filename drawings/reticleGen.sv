
module reticleGen #(
    parameter CX = 320,
    parameter CY = 240,
    parameter RADIUS = 60,
    parameter CIRCLE_WIDTH = 1,
    parameter CROSS_WIDTH = 1,
    parameter HALF_CROSS_HEIGHT = 5
)(
    input  logic unsigned [9:0] x,
    input  logic unsigned [9:0] y,
    input  logic validPixel,
    output logic drawReticle
);

logic drawCross;
logic drawCircle;
logic drawCardinals;

logic signed [11:0] posX, posY;
logic        [11:0] absX, absY;
logic [23:0] distSquared;
logic [11:0] major;

assign posX = $signed({1'b0, x}) - $signed(CX); // Negativo se x é menor que CX
assign posY = $signed({1'b0, y}) - $signed(CY); // Negativo se y é menor que CY
assign absX = (posX < 0) ? -posX : posX;
assign absY = (posY < 0) ? -posY : posY;
assign major = (absX >= absY) ? absX : absY;   // maior entre |dx| e |dy|

assign distSquared = (posX)*(posX) + (posY)*(posY);

always_comb begin
    // Medida de - ou | para "+" é de 15 pixels, tanto para vertical quanto para horizontal
    drawCross = ((y == CY) && 
                (x >= CX - HALF_CROSS_HEIGHT) && (x <= CX + HALF_CROSS_HEIGHT)) ||
                ((x == CX) && (y >= CY - HALF_CROSS_HEIGHT) && (y <= CY + HALF_CROSS_HEIGHT));

    // Assumindo um raio de 60 pixels, engrossando um pouco
    drawCircle = (distSquared + major >= RADIUS*RADIUS) && (distSquared < RADIUS*RADIUS + major);
    // Desenhando os pontos cardeais, assumindo uma distância de 85 a 100 pixels do centro
    drawCardinals = (
        ((posX == 0) && (((posY >= -RADIUS) && (posY <= -(RADIUS-HALF_CROSS_HEIGHT))) || ((posY >= RADIUS-HALF_CROSS_HEIGHT) && (posY <= RADIUS)))) ||
        ((posY == 0) && (((posX >= -RADIUS) && (posX <= -(RADIUS-HALF_CROSS_HEIGHT))) || ((posX >= RADIUS-HALF_CROSS_HEIGHT) && (posX <= RADIUS))))
    );

    if(validPixel == 1) begin
        drawReticle = (drawCross || drawCircle || drawCardinals);
    end else begin
        drawReticle = 0;
    end
end
endmodule


module reticleGen (
    input  logic unsigned [9:0] x,
    input  logic unsigned [9:0] y,
    input  logic validPixel,
    output logic drawReticle
);

parameter CX = 320;
parameter CY = 240;

logic drawCross;
logic drawCircle;
logic drawCardinals;

logic signed [11:0] distX, distY;
logic [23:0] distSquared;

assign distX = $signed({1'b0, x}) - $signed(CX); // Negativo se x é menor que CX
assign distY = $signed({1'b0, y}) - $signed(CY); // Negativo se y é menor que CY
assign distSquared = (distX * distX) + (distY * distY);

always_comb begin
    // Medida de - ou | para "+" é de 15 pixels, tanto para vertical quanto para horizontal
    drawCross = ((y == CY) && (x >= CX - 15) && (x <= CX + 15)) || ((x == CX) && (y >= CY - 15) && (y <= CY + 15));

    // Assumindo um raio de 60 pixels, engrossando um pouco
    drawCircle = (distSquared >= 3300) && (distSquared <= 3900);

    // Desenhando os pontos cardeais, assumindo uma distância de 85 a 100 pixels do centro
    drawCardinals = (
        ((distX == 0) && (((distY >= -60) && (distY <= -45)) || ((distY >= 45) && (distY <= 60)))) ||
        ((distY == 0) && (((distX >= -60) && (distX <= -45)) || ((distX >= 45) && (distX <= 60))))
    );

    if(validPixel == 1) begin
        drawReticle = (drawCross || drawCircle || drawCardinals);
    end else begin
        drawReticle = 0;
    end
end
endmodule


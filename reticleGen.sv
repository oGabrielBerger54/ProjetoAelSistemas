module reticleGen (
    input  logic unsigned [9:0] x,
    input  logic unsigned [9:0] y,
    input  logic validPixel,
    output logic drawReticle
);

localparam CX = 320;
localparam CY = 240;

logic drawCross;
logic drawCircle;
logic drawCardinals;

logic signed [11:0] distX, distY;
logic [23:0] distSquared;

assign distX = $signed({1'b0, x}) - $signed(CX);
assign distY = $signed({1'b0, y}) - $signed(CY);
assign distSquared = (distX * distX) + (distY * distY);

always_comb begin

    // medida de - ou | para "+" é de 15 pixels, tanto para vertical quanto para horizontal
    drawCross = ((y == CY) && (x >= CX - 15) && (x <= CX + 15)) || ((x == CX) && (y >= CY - 15) && (y <= CY + 15));

    // assumindo um raio de 100 pixels, a equação do círculo é (x - cx)^2 + (y - cy)^2 = r^2
    drawCircle = (distSquared >= 9500) && (distSquared <= 10500);

    // desenhando os pontos cardeais, assumindo uma distância de 85 a 100 pixels do centro
    drawCardinals = (
        ((distX == 0) && (((distY >= -100) && (distY <= -85)) || ((distY >= 85) && (distY <= 100)))) || 
        ((distY == 0) && (((distX >= -100) && (distX <= -85)) || ((distX >= 85) && (distX <= 100))))
    );

    if(validPixel == 1) begin
        drawReticle = (drawCross || drawCircle || drawCardinals);
    end else begin
        drawReticle = 0;
    end
end
endmodule


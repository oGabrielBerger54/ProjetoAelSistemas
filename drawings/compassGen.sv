module compassGen #(
    parameter int CX              = 320,
    parameter int RADIUS          = 180,   // raio do arco (px)
    parameter int ARC_TOP_Y       = 436,   // y do topo do arco (o centro do círculo fica RADIUS abaixo)
    parameter int THICKNESS       = 2,
    parameter int BAR_DEG         = 10,    // uma barra a cada 10 graus (precisa dividir 360)
    parameter int BAR_W           = 2,     // largura da barra (px)
    parameter int BAR_H           = 10,    // comprimento da barra, para fora do arco (px)
    parameter bit SIGNED_HEADING  = 1'b0,  // 0: heading 0..359 / 1: -180..179
    parameter int H_LAST          = 639,
    parameter int V_LAST          = 479
)(
    input  logic clk,
    input  logic rstN,
    input  logic [9:0] x,
    input  logic [9:0] y,
    input  logic validPixel,
    input  logic signed [8:0] compassHeading,
    input  logic [3:0] compassFrac,         // 1/16 de grau
    output logic drawCompass
);

localparam int CYC = ARC_TOP_Y + RADIUS;   // y do centro do círculo (fora da tela, embaixo)

// ---------- seno/cosseno constantes (Q8) das barras, só em tempo de compilação ----------
// Aproximação de Bhaskara: erro < 0,2 %
function automatic int sinQ8(input int deg);
    int d, num, den;
    d   = (deg < 0) ? -deg : deg;
    num = 4 * d * (180 - d) * 256;
    den = 40500 - d * (180 - d);
    sinQ8 = (deg < 0) ? -(num / den) : (num / den);
endfunction

function automatic int cosQ8(input int deg);
    cosQ8 = sinQ8(90 - ((deg < 0) ? -deg : deg));
endfunction

// ---------- heading -> giro alpha = heading mod BAR_DEG, seno e cosseno em Q16 ----------
// Pipeline sempre rodando (o heading muda devagar); o resultado é capturado no fim de cada quadro.
logic frameEnd;
assign frameEnd = validPixel && (x == H_LAST) && (y == V_LAST);

logic signed [15:0] hdgS;
logic signed [15:0] sumQ;                      // heading em 1/16 de grau, sempre positivo
assign hdgS = SIGNED_HEADING ? 16'($signed(compassHeading)) : 16'({1'b0, compassHeading});
assign sumQ = hdgS * 16 + 16'(compassFrac) + 16'(360 * 16);

localparam logic signed [47:0] ONE = 48'sd1048576;   // 1,0 em Q20

logic        [15:0] alphaR;                    // alpha em 1/16 de grau
logic signed [47:0] a1, a1d, a1dd, a1ddd;      // alpha em radianos, Q20
logic signed [47:0] a2, a2d;                   // alpha^2
logic signed [47:0] p1, q1, p2, q2;
logic signed [47:0] sinR, cosR;

always_ff @(posedge clk) begin
    alphaR <= 16'(sumQ % (BAR_DEG * 16));
    a1     <= 48'(alphaR) * 1144;              // pi/2880 em Q20
    a2     <= (a1 * a1) >>> 20;
    a1d    <= a1;
    p1     <= ONE - (a2 / 20);
    q1     <= ONE - (a2 / 12);
    a2d    <= a2;
    a1dd   <= a1d;
    p2     <= ONE - (((a2d / 6) * p1) >>> 20);
    q2     <= ONE - (((a2d / 2) * q1) >>> 20);
    a1ddd  <= a1dd;
    sinR   <= (a1ddd * p2) >>> 24;             // Q16
    cosR   <= q2 >>> 4;                        // Q16
end

logic signed [17:0] sinA, cosA;

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        sinA <= '0;
        cosA <= 18'sd65536;
    end else if(frameEnd) begin
        sinA <= 18'(sinR);
        cosA <= 18'(cosR);
    end
end

// ---------- geometria do pixel em relação ao centro do círculo ----------
logic signed [11:0] dx, h;                     // h = altura do pixel acima do centro
logic signed [31:0] d2;

assign dx = $signed({2'b00, x}) - 12'(CX);
assign h  = 12'(CYC) - $signed({2'b00, y});
assign d2 = 32'(dx) * 32'(dx) + 32'(h) * 32'(h);

// pixel girado de alpha: neste referencial as barras ficam paradas em k*BAR_DEG
logic signed [31:0] dxr, hr;                   // Q4 (1/16 px)
assign dxr = (32'(dx) * 32'(cosA) + 32'(h) * 32'(sinA)) >>> 12;
assign hr  = (32'(h)  * 32'(cosA) - 32'(dx) * 32'(sinA)) >>> 12;

// ---------- arco ----------
logic drawArc;
assign drawArc = (h > 0) && (d2 >= RADIUS * RADIUS) && (d2 < (RADIUS + THICKNESS) * (RADIUS + THICKNESS));

// ---------- barras radiais ----------
localparam int NH = (60 + BAR_DEG - 1) / BAR_DEG;   // barras de -NH*BAR_DEG a +NH*BAR_DEG

logic [2*NH:0] onLine;

genvar k;
generate
    for (k = -NH; k <= NH; k++) begin : g_tick
        localparam int PHI = k * BAR_DEG;
        localparam int SK  = sinQ8(PHI);
        localparam int CK  = cosQ8(PHI);
        logic signed [31:0] lineDist;                  // distância à reta, Q12
        assign lineDist = dxr * CK - hr * SK;
        assign onLine[k + NH] = (lineDist > -(BAR_W * 2048)) && (lineDist < (BAR_W * 2048));
    end
endgenerate

logic drawTicks;
assign drawTicks = (h > 0) && (d2 >= RADIUS * RADIUS) &&
                   (d2 < (RADIUS + BAR_H) * (RADIUS + BAR_H)) && (|onLine);

assign drawCompass = validPixel & (drawArc | drawTicks);

endmodule
module compassGen #(
    parameter int CX              = 320,
    parameter int RADIUS          = 220,   // raio do arco (px)
    parameter int ARC_TOP_Y       = 436,   // y do topo do arco (o centro do círculo fica RADIUS abaixo)
    parameter int THICKNESS       = 2,
    parameter int BAR_DEG         = 10,    // uma barra a cada 10 graus
    parameter int MAJOR_DEG       = 30,    // barra principal (com número) a cada 30 graus: múltiplo de BAR_DEG e divisor de 360
    parameter int BAR_W           = 2,     // largura da barra (px)
    parameter int BAR_H           = 10,    // comprimento das barras menores, para fora do arco (px)
    parameter int BAR_H_MAJOR     = 16,    // comprimento das barras principais (px)
    parameter int LABEL_DIGITS    = 3,     // dígitos do número das barras principais
    parameter int LABEL_SCALE     = 1,     // tamanho da fonte
    parameter int LABEL_GAP       = 4,     // espaço entre a ponta da barra principal e o número (px)
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

// ---------- heading -> ângulo de giro alpha = heading mod MAJOR_DEG, seno e cosseno em Q16 ----------
// Pipeline sempre rodando (o heading muda devagar); o resultado é capturado no fim de cada quadro.
logic frameEnd;
assign frameEnd = validPixel && (x == H_LAST) && (y == V_LAST);

logic signed [15:0] hdgS;
logic signed [15:0] sumQ;                      // heading em 1/16 de grau, sempre positivo
assign hdgS = SIGNED_HEADING ? 16'($signed(compassHeading)) : 16'({1'b0, compassHeading});
assign sumQ = hdgS * 16 + 16'(compassFrac) + 16'(360 * 16);

localparam logic signed [47:0] ONE = 48'sd1048576;   // 1,0 em Q20

logic        [15:0] alphaR;                    // alpha em 1/16 de grau
logic        [3:0]  m1, m2, m3, m4, m5, m6;    // heading / MAJOR_DEG, atrasado junto com o pipeline
logic signed [47:0] a1, a1d, a1dd, a1ddd;      // alpha em radianos, Q20
logic signed [47:0] a2, a2d;                   // alpha^2
logic signed [47:0] p1, q1, p2, q2;
logic signed [47:0] sinR, cosR;

always_ff @(posedge clk) begin
    alphaR <= 16'(sumQ % (MAJOR_DEG * 16));
    m1     <= 4'((sumQ / (MAJOR_DEG * 16)) % (360 / MAJOR_DEG));
    m2 <= m1; m3 <= m2; m4 <= m3; m5 <= m4; m6 <= m5;
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

logic signed [17:0] sinA, cosA;   // seno e cosseno de alpha (alpha = heading mod MAJOR_DEG)
logic        [3:0]  mA;

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        sinA <= '0;
        cosA <= 18'sd65536;
        mA   <= '0;
    end else if(frameEnd) begin
        sinA <= 18'(sinR);
        cosA <= 18'(cosR);
        mA   <= m6;
    end
end

// ---------- geometria do pixel em relação ao centro do círculo ----------
logic signed [11:0] dx, h;                     // h = altura do pixel acima do centro
logic signed [31:0] d2;

assign dx = $signed({2'b00, x}) - 12'(CX);
assign h  = 12'(CYC) - $signed({2'b00, y});
assign d2 = 32'(dx) * 32'(dx) + 32'(h) * 32'(h);

// pixel girado de alpha: as barras ficam paradas a k*BAR_DEG neste referencial
logic signed [31:0] dxr, hr;                   // Q4 (1/16 px)
assign dxr = (32'(dx) * 32'(cosA) + 32'(h) * 32'(sinA)) >>> 12;
assign hr  = (32'(h)  * 32'(cosA) - 32'(dx) * 32'(sinA)) >>> 12;

// ---------- arco ----------
logic drawArc;
assign drawArc = (h > 0) && (d2 >= RADIUS * RADIUS) && (d2 < (RADIUS + THICKNESS) * (RADIUS + THICKNESS));

// ---------- barras radiais ----------
localparam int NH = (60 + BAR_DEG - 1) / BAR_DEG;   // barras de -NH*BAR_DEG a +NH*BAR_DEG

logic [2*NH:0] onLine, onMajor;

genvar k;
generate
    for (k = -NH; k <= NH; k++) begin : g_tick
        localparam int PHI = k * BAR_DEG;
        localparam int SK  = sinQ8(PHI);
        localparam int CK  = cosQ8(PHI);
        logic signed [31:0] lineDist;                      // distância à reta, Q12
        assign lineDist = dxr * CK - hr * SK;
        localparam bit IS_MAJOR = (k % (MAJOR_DEG / BAR_DEG)) == 0;
        assign onLine[k + NH]  = (lineDist > -(BAR_W * 2048)) && (lineDist < (BAR_W * 2048));
        assign onMajor[k + NH] = IS_MAJOR && (lineDist > -(BAR_W * 2048)) && (lineDist < (BAR_W * 2048));
    end
endgenerate

logic drawTicks;
assign drawTicks = (h > 0) && (d2 >= RADIUS * RADIUS) &&
                   (((d2 < (RADIUS + BAR_H) * (RADIUS + BAR_H)) && (|onLine)) ||
                    ((d2 < (RADIUS + BAR_H_MAJOR) * (RADIUS + BAR_H_MAJOR)) && (|onMajor)));

// ---------- números das barras principais ----------
// Cada número fica na direção da sua barra, logo depois da ponta. A barra principal s está em
// theta = s*MAJOR_DEG - alpha (graus, positivo = direita). Valem s = -1..2 (cobre -60..+60 graus).
localparam int NS      = 4;
localparam int NMAJ    = 360 / MAJOR_DEG;
localparam int LABEL_W = LABEL_DIGITS * 6 * LABEL_SCALE - LABEL_SCALE;   // largura com todos os dígitos
localparam int LABEL_H = 7 * LABEL_SCALE;
localparam int BASE_R  = RADIUS + BAR_H_MAJOR + LABEL_GAP;

function automatic int nDig(input int v);        // quantos dígitos tem v (1..LABEL_DIGITS)
    int d, p;
    d = 1; p = 10;
    for (int i = 1; i < LABEL_DIGITS; i++) begin
        if (v >= p) d = i + 1;
        p = p * 10;
    end
    nDig = d;
endfunction

logic [NS-1:0] drawLab;

genvar i;
generate
    for (i = 0; i < NS; i++) begin : g_lab
        localparam int S   = i - 1;
        localparam int PHI = S * MAJOR_DEG;
        localparam int S8  = sinQ8(PHI);
        localparam int C8  = cosQ8(PHI);

        // valor da barra: bearing = (m + S) * MAJOR_DEG, de 0 a 360 - MAJOR_DEG
        logic [15:0] val;
        assign val = 16'(((int'(mA) + S + NMAJ) % NMAJ) * MAJOR_DEG);

        // posição do número (calculada uma vez por quadro; o pipeline assenta bem antes do quadro seguinte)
        logic signed [17:0] sTh, cTh;        // seno e cosseno de theta (Q16)
        logic signed [24:0] radQ;            // distância ao centro do número (Q16)
        logic signed [42:0] px, py;
        logic signed [11:0] bx, by;          // canto do retângulo do número (com os dígitos escondidos)

        always_ff @(posedge clk) begin
            sTh  <= 18'((S8 * 32'(cosA) - C8 * 32'(sinA)) >>> 8);
            cTh  <= 18'((C8 * 32'(cosA) + S8 * 32'(sinA)) >>> 8);
            radQ <= 25'(BASE_R * 65536 + (LABEL_W / 2) * (sTh[17] ? -sTh : sTh) + (LABEL_H / 2) * cTh);
            px   <= radQ * sTh;
            py   <= radQ * cTh;
            // centraliza só os dígitos que aparecem: os escondidos ficam à esquerda
            bx   <= 12'(CX + int'((px + 43'sd2147483648) >>> 32)
                        - (nDig(int'(val)) * 6 * LABEL_SCALE - LABEL_SCALE) / 2
                        - (LABEL_DIGITS - nDig(int'(val))) * 6 * LABEL_SCALE);
            by   <= 12'(CYC - int'((py + 43'sd2147483648) >>> 32) - LABEL_H / 2);
        end

        logic signed [11:0] dxs, dys;
        logic labelOk;                       // só mostra o número se ele couber inteiro na tela
        assign dxs = $signed({2'b00, x}) - bx;
        assign dys = $signed({2'b00, y}) - by;
        assign labelOk = (by >= 0) && (by + LABEL_H <= V_LAST + 1) &&
                         (bx + (LABEL_DIGITS - nDig(int'(val))) * 6 * LABEL_SCALE >= 0) &&
                         (bx + LABEL_DIGITS * 6 * LABEL_SCALE - LABEL_SCALE <= H_LAST + 1);

        numberGen #(.X0(0), .Y0(0), .NDIGITS(LABEL_DIGITS), .SCALE(LABEL_SCALE), .HIDE_ZEROS(1'b1)) u_num (
            .x(10'(dxs)), .y(10'(dys)), .validPixel(validPixel & labelOk),
            .value(val), .drawNumber(drawLab[i])
        );
    end
endgenerate

assign drawCompass = validPixel & (drawArc | drawTicks | (|drawLab));

endmodule
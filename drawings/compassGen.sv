module compassGen #(
    parameter int CX              = 320,
    parameter int HALF_W          = 100,   // meia largura da fita (px)
    parameter int TAPE_Y          = 120,   // y da linha
    parameter int THICKNESS       = 2,
    parameter int PPD             = 2,     // pixels por grau
    parameter int BAR_DEG         = 10,    // uma barra a cada 10 graus (precisa dividir 360)
    parameter int BAR_W           = 2,     // largura da barra (px)
    parameter int BAR_H           = 10,    // altura da barra (px)
    parameter bit SIGNED_HEADING  = 1'b0   // 0: heading 0..359 / 1: -180..179
)(
    input  logic clk,                       // não usados, mantidos para não mexer no hudTop
    input  logic rstN,
    input  logic [9:0] x,
    input  logic [9:0] y,
    input  logic validPixel,
    input  logic signed [8:0] compassHeading,
    input  logic [3:0] compassFrac,         // 1/16 de grau
    output logic drawCompass
);

localparam int SPACING = PPD * BAR_DEG;    // pixels entre barras
localparam int WRAP    = 360 * PPD;        // múltiplo de SPACING: só mantém a soma positiva

// heading em pixels (com a fração)
logic signed [15:0] hdgS;
logic        [15:0] headPx;

assign hdgS   = SIGNED_HEADING ? 16'($signed(compassHeading)) : 16'({1'b0, compassHeading});
assign headPx = hdgS * PPD + ((compassFrac * PPD) >> 4);

// posição do pixel dentro do padrão de barras
logic signed [11:0] distX;
logic signed [15:0] sum;
logic        [15:0] phase;

assign distX = $signed({2'b00, x}) - 12'(CX);
assign sum   = $signed(headPx) + 16'(distX) + 16'(WRAP);
assign phase = sum % SPACING;

// formas
logic inTape, drawLine, drawBars;

assign inTape   = (distX >= -HALF_W) && (distX <= HALF_W);
assign drawLine = inTape && (y >= TAPE_Y) && (y < TAPE_Y + THICKNESS);
assign drawBars = inTape && (phase < BAR_W) && (y >= TAPE_Y - BAR_H) && (y < TAPE_Y);

assign drawCompass = validPixel & (drawLine | drawBars);

endmodule
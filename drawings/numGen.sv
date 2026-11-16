module numberGen #(
    parameter int X0      = 20,   // canto superior esquerdo do número
    parameter int Y0      = 20,
    parameter int NDIGITS = 4,    // quantidade de dígitos (zeros à esquerda aparecem)
    parameter int SCALE   = 2     // cada pixel da fonte vira SCALE x SCALE
)(
    input  logic [9:0]  x,
    input  logic [9:0]  y,
    input  logic        validPixel,
    input  logic [15:0] value,    // 0 .. 10**NDIGITS - 1
    output logic        drawNumber
);

localparam int CELL_W  = 6 * SCALE;        // 5 colunas + 1 de espaço
localparam int TOTAL_W = NDIGITS * CELL_W;
localparam int TOTAL_H = 7 * SCALE;

// Fonte 5x7: 7 linhas de 5 bits, a linha de cima fica nos bits mais altos
function automatic logic [34:0] glyph(input logic [3:0] d);
    case (d)
        4'd0: glyph = {5'b01110, 5'b10001, 5'b10011, 5'b10101, 5'b11001, 5'b10001, 5'b01110};
        4'd1: glyph = {5'b00100, 5'b01100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};
        4'd2: glyph = {5'b01110, 5'b10001, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b11111};
        4'd3: glyph = {5'b01110, 5'b10001, 5'b00001, 5'b00110, 5'b00001, 5'b10001, 5'b01110};
        4'd4: glyph = {5'b00010, 5'b00110, 5'b01010, 5'b10010, 5'b11111, 5'b00010, 5'b00010};
        4'd5: glyph = {5'b11111, 5'b10000, 5'b11110, 5'b00001, 5'b00001, 5'b10001, 5'b01110};
        4'd6: glyph = {5'b00110, 5'b01000, 5'b10000, 5'b11110, 5'b10001, 5'b10001, 5'b01110};
        4'd7: glyph = {5'b11111, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b01000, 5'b01000};
        4'd8: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b01110, 5'b10001, 5'b10001, 5'b01110};
        4'd9: glyph = {5'b01110, 5'b10001, 5'b10001, 5'b01111, 5'b00001, 5'b00010, 5'b01100};
        default: glyph = '0;
    endcase
endfunction

// 1) Separa o valor em dígitos (digits[0] = mais significativo)
logic [3:0] digits [NDIGITS];

always_comb begin
    int v;
    v = int'(value);
    for (int i = NDIGITS - 1; i >= 0; i--) begin
        digits[i] = 4'(v % 10);
        v = v / 10;
    end
end

// 2) Posição do pixel dentro do número
//    A subtração sem sinal "dá a volta" quando x < X0 e vira um valor enorme,
//    então um único teste "< TOTAL_W" já cobre o limite esquerdo e o direito.
logic [9:0] ux, uy;
logic       inBox;

assign ux    = x - 10'(X0);
assign uy    = y - 10'(Y0);
assign inBox = (ux < TOTAL_W) && (uy < TOTAL_H);

logic [9:0]  digitIdx;
logic [2:0]  col;
logic [2:0]  row;
logic [34:0] g;
logic [4:0]  rowBits;
logic        pixelOn;

always_comb begin
    digitIdx = ux / CELL_W;
    col      = 3'((ux % CELL_W) / SCALE);   // 0..5 (5 é o espaço entre dígitos)
    row      = 3'(uy / SCALE);              // 0..6

    g        = '0;
    rowBits  = '0;
    pixelOn  = 1'b0;

    if (inBox && col < 5) begin
        g       = glyph(digits[digitIdx]);
        rowBits = g[5*(6 - int'(row)) +: 5];
        pixelOn = rowBits[4 - col];
    end
end

// 3) Saída
assign drawNumber = validPixel & pixelOn;

endmodule
// Display de 7 segmentos da Nexys A7: 8 digitos em hexadecimal.
// value[3:0] = digito mais a direita (AN0); value[31:28] = mais a esquerda (AN7).
// Segmentos e anodos sao ativos em nivel baixo.
module seg7_hex8 (
  input  logic        clk, rst,
  input  logic [31:0] value,
  output logic [6:0]  seg,   // {CG,CF,CE,CD,CC,CB,CA}
  output logic        dp,
  output logic [7:0]  an
);
  logic [18:0] cnt;
  logic [2:0]  sel;
  logic [3:0]  nib;

  always_ff @(posedge clk) begin
    if (rst) cnt <= '0;
    else     cnt <= cnt + 1'b1;
  end

  assign sel = cnt[18:16];              // troca de digito a ~1,5 kHz (varredura completa ~190 Hz)
  assign nib = value[4*sel +: 4];
  assign an  = ~(8'b1 << sel);          // acende apenas o digito selecionado
  assign dp  = (sel != 3'd3);           // ponto entre temp e press (apos o 4o digito)

  always_comb begin
    case (nib)
      4'h0: seg = 7'b1000000;
      4'h1: seg = 7'b1111001;
      4'h2: seg = 7'b0100100;
      4'h3: seg = 7'b0110000;
      4'h4: seg = 7'b0011001;
      4'h5: seg = 7'b0010010;
      4'h6: seg = 7'b0000010;
      4'h7: seg = 7'b1111000;
      4'h8: seg = 7'b0000000;
      4'h9: seg = 7'b0010000;
      4'hA: seg = 7'b0001000;
      4'hB: seg = 7'b0000011;
      4'hC: seg = 7'b1000110;
      4'hD: seg = 7'b0100001;
      4'hE: seg = 7'b0000110;
      4'hF: seg = 7'b0001110;
    endcase
  end
endmodule
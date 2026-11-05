// xadcReader : le os dois eixos do joystick pelo XADC (canais VAUX3 = X e VAUX10 = Y).
// Usa o IP "xadc_wiz_0" gerado pelo XADC Wizard.
// Saida: xVal e yVal, 12 bits (0..4095 = 0..1 V no pino do XADC), ja suavizados.
module xadcReader (
    input  logic clk100, // 100 MHz (mesmo clock do DCLK do Wizard)
    input  logic vauxp3,  vauxn3, // JXADC pino 1 (P) e 7 (N)  -> eixo X
    input  logic vauxp10, vauxn10, // JXADC pino 2 (P) e 8 (N)  -> eixo Y
    output logic [11:0] xVal,
    output logic [11:0] yVal
);

logic [15:0] doOut;
logic drdy, eoc;
logic [4:0]  chan; // canal que acabou de ser convertido
logic [4:0]  chanQ; // canal guardado para quando o dado chegar

xadc_wiz_0 u_xadc (
    .daddr_in({2'b00, chan}), // o endereco do resultado de VAUXn eh 0x10 + n
    .dclk_in(clk100),
    .den_in(eoc), // fim da conversao -> pede leitura do resultado
    .di_in(16'h0000),
    .dwe_in(1'b0),
    .vauxp3(vauxp3),
    .vauxn3(vauxn3),
    .vauxp10(vauxp10),
    .vauxn10(vauxn10),
    .vp_in(1'b0),
    .vn_in(1'b0),
    .do_out(doOut),
    .drdy_out(drdy),
    .channel_out(chan),
    .eoc_out(eoc),
    .eos_out(),
    .busy_out(),
    .alarm_out()
);

// guarda qual canal foi convertido (o dado chega alguns ciclos depois)
always_ff @(posedge clk100)
    if(eoc) chanQ <= chan;

// filtro simples: anda 1/4 do caminho em direcao a cada leitura nova (tira o tremido)
logic signed [13:0] dx, dy;
always_comb begin
    dx = $signed({2'b00, doOut[15:4]}) - $signed({2'b00, xVal});
    dy = $signed({2'b00, doOut[15:4]}) - $signed({2'b00, yVal});
end

always_ff @(posedge clk100) begin
    if(drdy) begin
        case (chanQ)
            5'h13:   xVal <= xVal + 12'(dx >>> 2); // VAUX3 = eixo X
            5'h1A:   yVal <= yVal + 12'(dy >>> 2); // VAUX10 = eixo Y
            default: ;
        endcase
    end
end
endmodule

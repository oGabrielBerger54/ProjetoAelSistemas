`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  É a ponte entre o xadcReader e o joyToTarget.
//  O xadcReader entrega números de 0 a 4095 (o centro do joystick cai perto de 1690).
//  O joyToTarget espera números de 0 a 1023 com o centro em 512.
//  Este módulo faz essa conversão e também gera o pulso "chegou leitura nova" (100 vezes por segundo).

// COMO FUNCIONA (4 passos)
//  1) SINCRONIZAR: o xadcReader roda no clock de 100 MHz e este módulo no de 25 MHz. O valor passa por 2 registradores e só é aceito se
//     duas leituras seguidas forem iguais (evita pegar um número "pela metade" no instante em que ele muda).
//  2) CALIBRAR O CENTRO: logo depois de ligar (ou do reset), espera ~0,5 s e depois tira a média de 64 leituras (~0,64 s).
//     Essa média é o "centro" do seu joystick. POR ISSO: NÃO MEXA NO JOYSTICK ao ligar a placa ou apertar o reset.
//  3) CONVERTER: diferença = leitura - centro. Multiplica por GAIN_NUM/16 e soma 512. Limita entre 0 e 1023.
//  4) AVISAR: a cada 10 ms (depois de calibrado) dá um pulso de 1 ciclo em joyValid.

module xadcToJoy #(
    // Ganho = GAIN_NUM / 16. Com 5, o ganho é 0,3125: o joystick todo para um lado (~1690 de diferença) vira ~528, e o limite corta em 511.
    parameter int GAIN_NUM = 5,

    parameter int SETTLE_READS = 50, // leituras ignoradas antes de calibrar (50 x 10 ms = 0,5 s)
    parameter int CAL_LOG2 = 6, // a média do centro usa 2^6 = 64 leituras

    parameter int CLK_HZ = 25_000_000, // clock deste módulo
    parameter int READ_HZ = 100 // leituras por segundo enviadas ao joyToTarget
)(
    input logic clk, // clock de 25 MHz
    input logic rst_n, // reset, ativo em 0
    input logic [11:0] xRaw, // eixo X vindo do xadcReader (0 a 4095)
    input logic [11:0] yRaw, // eixo Y vindo do xadcReader (0 a 4095)

    output logic [9:0] joyX, // 0 a 1023, centro em 512
    output logic [9:0] joyY, // 0 a 1023, centro em 512
    output logic joyValid, // pulso de 1 ciclo: "chegou leitura nova"
    output logic calibrated // 1 = centro já calibrado
);

// PASSO 1 - SINCRONIZAR (clock de 100 MHz -> 25 MHz)
logic [11:0] xS1, xS2, yS1, yS2;
logic [11:0] xStable, yStable;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        xS1 <= '0; xS2 <= '0; yS1 <= '0; yS2 <= '0;
        xStable <= '0; yStable <= '0;
    end else begin
        xS1 <= xRaw; xS2 <= xS1;
        yS1 <= yRaw; yS2 <= yS1;
        if(xS1 == xS2) xStable <= xS2;
        if(yS1 == yS2) yStable <= yS2;
    end
end

// Pulso a cada 10 ms
localparam int TICK_MAX = CLK_HZ / READ_HZ - 1;
logic [$clog2(TICK_MAX + 1) - 1:0] tickCnt;
logic tick;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        tickCnt <= '0;
        tick <= 1'b0;
    end else if(tickCnt == TICK_MAX) begin
        tickCnt <= '0;
        tick <= 1'b1;
    end else begin
        tickCnt <= tickCnt + 1'b1;
        tick <= 1'b0;
    end
end

// PASSO 2 - CALIBRAR O CENTRO
typedef enum logic [1:0] {SETTLE, CAL, RUN} state_t;
state_t state;

logic [8:0] cnt;
logic [CAL_LOG2 + 11:0] sumX, sumY;
logic [CAL_LOG2 + 11:0] nextSumX, nextSumY;
logic [11:0] centerX, centerY;

assign nextSumX = sumX + {{CAL_LOG2{1'b0}}, xStable};
assign nextSumY = sumY + {{CAL_LOG2{1'b0}}, yStable};

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state <= SETTLE;
        cnt <= '0;
        sumX <= '0;
        sumY <= '0;
        centerX <= 12'd1690;
        centerY <= 12'd1690;
    end else if(tick) begin
        case(state)
            SETTLE: begin
                if(cnt == SETTLE_READS - 1) begin
                    cnt <= '0;
                    sumX <= '0;
                    sumY <= '0;
                    state <= CAL;
                end else cnt <= cnt + 1'b1;
            end
            CAL: begin
                sumX <= nextSumX;
                sumY <= nextSumY;
                if(cnt == (1 << CAL_LOG2) - 1) begin
                    centerX <= nextSumX[CAL_LOG2 + 11:CAL_LOG2];
                    centerY <= nextSumY[CAL_LOG2 + 11:CAL_LOG2];
                    state <= RUN;
                end else cnt <= cnt + 1'b1;
            end
            default: ;
        endcase
    end
end

assign calibrated = (state == RUN);

// PASSO 3 - CONVERTER
logic signed [13:0] diffX, diffY; // distancias do  centro
logic signed [31:0] valX, valY;

always_comb begin
    diffX = $signed({2'b00, xStable}) - $signed({2'b00, centerX});
    diffY = $signed({2'b00, yStable}) - $signed({2'b00, centerY});
    valX = 32'sd512 + ((32'(diffX) * GAIN_NUM) >>> 4);
    valY = 32'sd512 + ((32'(diffY) * GAIN_NUM) >>> 4);
end

function automatic logic [9:0] clamp10(input logic signed [31:0] v);
    if(v < 0) return 10'd0;
    else if(v > 1023) return 10'd1023;
    else return v[9:0];
endfunction

// PASSO 4 - AVISAR
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        joyX <= 10'd512;
        joyY <= 10'd512;
        joyValid <= 1'b0;
    end else begin
        joyValid <= tick && (state == RUN);
        if(state == RUN) begin
            joyX <= clamp10(valX);
            joyY <= clamp10(valY);
        end else begin
            joyX <= 10'd512;
            joyY <= 10'd512;
        end
    end
end

endmodule

`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  Transforma os dois números CRUS do barômetro BMP085 (UT = temperatura crua e UP = pressão crua) na PRESSÃO VERDADEIRA, em Pascal.
//  É a conta que o datasheet do BMP085 manda fazer (seção 3.5, modo OSS = 0). Ela NÃO desenha nada: só entrega um número de pressão
//  que não depende mais da temperatura do sensor.
//
// POR QUE ISSO É NECESSÁRIO
//  O número UP cru muda MUITO com a temperatura do próprio sensor, mesmo com a pressão do ar parada:
//  pelas contas do datasheet, cerca de 76 unidades de UP por grau Celsius, o que equivale a uns 19 metros por grau!
//  Meio grau de aquecimento (chip da FPGA por perto, a mão, o próprio sensor esquentando) já joga o altímetro para fora da tela.
//  Usando UT para compensar, o resultado em Pascal só muda quando o ar muda de verdade.
//
// DE ONDE VÊM OS DADOS
//  bmp085_reader entrega: temp_raw (UT), press_raw (UP), calib (22 bytes de calibração do sensor) e o pulso data_valid.
//  Os 22 bytes são 11 números de 16 bits, na ordem do datasheet (primeiro o byte de cima):
//    calib[0..1]=AC1  [2..3]=AC2  [4..5]=AC3  [6..7]=AC4  [8..9]=AC5  [10..11]=AC6
//    [12..13]=B1  [14..15]=B2  [16..17]=MB (não usado)  [18..19]=MC  [20..21]=MD
//
// COMO FUNCIONA
//  A conta do datasheet tem várias multiplicações e 2 divisões. Para caber no clock, ela é feita em PASSOS: a cada ciclo, uma operação
//  simples, guardando o resultado num registrador. Todos os passos juntos levam uns 100 ciclos (4 microssegundos), enquanto a leitura nova
//  só chega a cada ~100 ms. As divisões usam o seqDiv (1 bit por ciclo).
//  Os nomes (x1, x2, b3, b4, b5, b6, b7...) são os mesmos do datasheet, para dar para conferir linha a linha.
//
//   Temperatura:   x1 = ((UT - AC6) * AC5) / 2^15
//                  x2 = (MC * 2^11) / (x1 + MD)
//                  b5 = x1 + x2                       (b5 é o "número da temperatura")
//   Pressão:       b6 = b5 - 4000
//                  x3 = (B2 * (b6*b6 / 2^12)) / 2^11  +  (AC2 * b6) / 2^11
//                  b3 = ((AC1*4 + x3) + 2) / 4
//                  x3 = ((AC3*b6) / 2^13  +  (B1 * (b6*b6 / 2^12)) / 2^16  + 2) / 4
//                  b4 = AC4 * (x3 + 32768) / 2^15
//                  b7 = (UP - b3) * 50000
//                  p  = (b7 * 2) / b4
//                  p  = p + ( ((p/2^8)^2 * 3038 / 2^16)  +  (-7357 * p / 2^16)  +  3791 ) / 16
//  O resultado "p" é a pressão em Pascal (ao nível do mar, uns 101325).
//  Exemplo do próprio datasheet (testado no modelo): UT = 27898 e UP = 23843 com os coeficientes de exemplo dão p = 69964 Pa.
//
// COMO USAR
//  Dê um pulso de 1 ciclo em "start" quando chegar uma leitura nova (use o data_valid do bmp085_reader). Uns 100 ciclos depois sai
//  um pulso de 1 ciclo em "valid", com a pressão nova em "pressPa". Se chegar outro "start" no meio da conta, ele é ignorado.

module baroCompensate (
    input logic clk,
    input logic rst_n, // reset, ativo em 0
    input logic [15:0] ut, // temperatura crua (temp_raw do bmp085_reader)
    input logic [15:0] up, // pressão crua (press_raw do bmp085_reader)
    input logic [7:0] calib [0:21], // calibração (calib do bmp085_reader)
    input logic start, // pulso de 1 ciclo: "chegou leitura nova"

    output logic [19:0] pressPa, // pressão compensada, em Pascal
    output logic valid // pulso de 1 ciclo: "pressPa novo"
);

// ---------- Os 10 números de calibração que a conta usa ----------
logic signed [15:0] ac1, ac2, ac3, b1, b2, mc, md;
logic [15:0] ac4, ac5, ac6; // estes três são SEM sinal no datasheet
assign ac1 = {calib[0], calib[1]};
assign ac2 = {calib[2], calib[3]};
assign ac3 = {calib[4], calib[5]};
assign ac4 = {calib[6], calib[7]};
assign ac5 = {calib[8], calib[9]};
assign ac6 = {calib[10], calib[11]};
assign b1 = {calib[12], calib[13]};
assign b2 = {calib[14], calib[15]};
assign mc = {calib[18], calib[19]};
assign md = {calib[20], calib[21]};

// ---------- Divisor sequencial ----------
logic divStart;
logic divBusy;
logic divDone;
logic [33:0] divNum;
logic [33:0] divDen;
logic [33:0] divQuo;

seqDiv #(.N(34)) div (
    .clk(clk),
    .rst_n(rst_n),
    .start(divStart),
    .num(divNum),
    .den(divDen),
    .quo(divQuo),
    .busy(divBusy),
    .done(divDone)
);

// ---------- Registradores da conta (cada um com o tamanho que o resultado precisa) ----------
logic [15:0] utL; // UT guardado no começo da conta
logic [15:0] upL; // UP guardado no começo da conta
logic signed [33:0] prodX1;
logic signed [19:0] x1;
logic signed [27:0] x2;
logic signed [27:0] b5;
logic signed [15:0] b6;
logic signed [31:0] sq; // b6 * b6
logic signed [15:0] t1; // b6*b6 / 2^12
logic signed [31:0] m1, m2, m3, m4;
logic signed [19:0] x3a, xb, xc, x3b;
logic signed [19:0] b3;
logic signed [17:0] x3p;
logic signed [34:0] prodB4;
logic signed [19:0] b4;
logic signed [19:0] diff; // UP - b3
logic signed [35:0] b7;
logic signed [23:0] pp; // pressão ainda sem o ajuste final
logic signed [15:0] p8; // pp / 2^8
logic signed [37:0] m5;
logic signed [31:0] sq2; // p8 * p8
logic signed [47:0] m6;
logic signed [19:0] x1p, x2p;
logic signed [31:0] pf; // pressão final
logic neg1; // o resultado da divisão 1 é negativo?

// ---------- Preparação da divisão 1: x2 = (MC * 2^11) / (x1 + MD). O divisor só trabalha com números SEM sinal, então usamos o valor absoluto e voltamos o sinal depois.
logic signed [27:0] num1;
logic signed [20:0] den1;
logic [27:0] num1Abs;
logic [20:0] den1Abs;
assign num1 = 28'(mc) <<< 11;
assign den1 = 21'(x1) + 21'(md);
assign num1Abs = num1[27] ? (~num1 + 28'd1) : num1;
assign den1Abs = den1[20] ? (~den1 + 21'd1) : den1;

// ---------- Máquina de passos ----------
typedef enum logic [4:0] {
    S_IDLE,
    S_X1A, S_X1B,
    S_DIV1, S_DIV1W,
    S_B5, S_B6, S_SQ, S_T1,
    S_MUL,
    S_B3A, S_B3B,
    S_B4A, S_B4B, S_B4C,
    S_B7A, S_B7B,
    S_DIV2, S_DIV2W,
    S_P1, S_P2, S_P3, S_P4, S_P5,
    S_OUT
} state_e;

state_e st;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        st <= S_IDLE;
        valid <= 1'b0;
        divStart <= 1'b0;
        pressPa <= '0;
    end else begin
        valid <= 1'b0;
        divStart <= 1'b0;

        case(st)
            S_IDLE: begin
                if(start) begin
                    utL <= ut;
                    upL <= up;
                    st <= S_X1A;
                end
            end

            // x1 = ((UT - AC6) * AC5) >> 15
            S_X1A: begin
                prodX1 <= ($signed({1'b0, utL}) - $signed({1'b0, ac6})) * $signed({1'b0, ac5});
                st <= S_X1B;
            end
            S_X1B: begin
                x1 <= prodX1 >>> 15;
                st <= S_DIV1;
            end

            // x2 = (MC << 11) / (x1 + MD)
            S_DIV1: begin
                divNum <= {6'b0, num1Abs};
                divDen <= {13'b0, den1Abs};
                neg1 <= num1[27] ^ den1[20];
                divStart <= 1'b1;
                st <= S_DIV1W;
            end
            S_DIV1W: begin
                if(divDone) begin
                    x2 <= neg1 ? -$signed(divQuo[27:0]) : $signed(divQuo[27:0]);
                    st <= S_B5;
                end
            end

            // b5 = x1 + x2 ; b6 = b5 - 4000 ; t1 = (b6*b6) >> 12
            S_B5: begin
                b5 <= 28'(x1) + x2;
                st <= S_B6;
            end
            S_B6: begin
                b6 <= 16'(b5) - 16'sd4000;
                st <= S_SQ;
            end
            S_SQ: begin
                sq <= b6 * b6;
                st <= S_T1;
            end
            S_T1: begin
                t1 <= sq >>> 12;
                st <= S_MUL;
            end

            // As 4 multiplicações da parte da pressão (independentes, feitas juntas)
            S_MUL: begin
                m1 <= b2 * t1;
                m2 <= ac2 * b6;
                m3 <= ac3 * b6;
                m4 <= b1 * t1;
                st <= S_B3A;
            end

            // x3a = (B2*t1 >> 11) + (AC2*b6 >> 11) ; xb = AC3*b6 >> 13 ; xc = B1*t1 >> 16
            S_B3A: begin
                x3a <= (m1 >>> 11) + (m2 >>> 11);
                xb <= m3 >>> 13;
                xc <= m4 >>> 16;
                st <= S_B3B;
            end
            // b3 = ((AC1*4 + x3a) + 2) >> 2 ; x3b = ((xb + xc) + 2) >> 2
            S_B3B: begin
                b3 <= ((20'(ac1) <<< 2) + x3a + 20'sd2) >>> 2;
                x3b <= (xb + xc + 20'sd2) >>> 2;
                st <= S_B4A;
            end

            // b4 = (AC4 * (x3b + 32768)) >> 15
            S_B4A: begin
                x3p <= 18'(x3b) + 18'sd32768;
                st <= S_B4B;
            end
            S_B4B: begin
                prodB4 <= $signed({1'b0, ac4}) * x3p;
                st <= S_B4C;
            end
            S_B4C: begin
                b4 <= prodB4 >>> 15;
                st <= S_B7A;
            end

            // b7 = (UP - b3) * 50000
            S_B7A: begin
                diff <= $signed({4'b0, upL}) - b3;
                st <= S_B7B;
            end
            S_B7B: begin
                b7 <= diff * 36'sd50000;
                st <= S_DIV2;
            end

            // p = (b7 * 2) / b4   (se algo der errado e b7 ou b4 vierem sem sentido, usa 0 e 1 para não travar)
            S_DIV2: begin
                divNum <= b7[35] ? 34'd0 : {b7[32:0], 1'b0};
                divDen <= (b4 > 20'sd0) ? {14'b0, b4} : 34'd1;
                divStart <= 1'b1;
                st <= S_DIV2W;
            end
            S_DIV2W: begin
                if(divDone) begin
                    pp <= {1'b0, divQuo[22:0]};
                    st <= S_P1;
                end
            end

            // Ajuste final: p = p + ( ((p>>8)^2 * 3038 >> 16) + (-7357*p >> 16) + 3791 ) >> 4
            S_P1: begin
                p8 <= pp >>> 8;
                m5 <= pp * (-38'sd7357);
                st <= S_P2;
            end
            S_P2: begin
                sq2 <= p8 * p8;
                st <= S_P3;
            end
            S_P3: begin
                m6 <= sq2 * 48'sd3038;
                st <= S_P4;
            end
            S_P4: begin
                x1p <= m6 >>> 16;
                x2p <= m5 >>> 16;
                st <= S_P5;
            end
            S_P5: begin
                pf <= pp + ((x1p + x2p + 20'sd3791) >>> 4);
                st <= S_OUT;
            end

            // Entrega (cortando em 0 .. 1048575 para caber nos 20 bits)
            S_OUT: begin
                if(pf < 0) pressPa <= 20'd0;
                else if(pf > 32'sd1048575) pressPa <= 20'hFFFFF;
                else pressPa <= pf[19:0];
                valid <= 1'b1;
                st <= S_IDLE;
            end

            default: st <= S_IDLE;
        endcase
    end
end

endmodule

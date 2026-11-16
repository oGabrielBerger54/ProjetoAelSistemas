`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  Recebe a pressão CRUA do barômetro BMP085 (o número UP) e entrega o "altOffset": quantos PIXELS a escala de altitude (altGen) deve deslizar.
//    Placa SOBE -> pressão do ar CAI -> UP diminui -> a escala desce na tela (altOffset negativo)
//    Placa DESCE -> pressão do ar SOBE -> UP aumenta -> a escala sobe na tela  (altOffset positivo)
//    Mesma altura de quando ligou -> altOffset = 0
//  (A escala desce quando você sobe porque o ponteiro fica parado no meio e os números novos vêm de cima, como num avião de verdade.
//   No caso de ficar ao contrário, ponha INVERT em 1'b1.)

// DE ONDE VÊM OS DADOS (o caminho todo)
//  sensor BMP085 --(fios SDA e SCL, protocolo I2C)--> i2c_master --> bmp085_reader --> barToAlt (este arquivo) --> altGen --> tela
//    i2c_master = o "spiMaster" do I2C: sabe mandar/ler 1 byte nos fios.
//    bmp085_reader = o "adxl362Ctrl" do I2C: sabe a ordem de conversa com o sensor (pedir medida, esperar, ler os bytes).
//    pressRaw <- bmp085_reader.press_raw   (número UP, 16 bits, sem sinal)
//    pressValid <- bmp085_reader.data_valid  (pulso de 1 ciclo: "chegou UP novo")
//  O bmp085_reader entrega cerca de 9 leituras por segundo. Cada vez que chega uma, ele dá UM pulso de 1 ciclo em data_valid.
//  Daqui para baixo, "1 leitura" = 1 pulso de pressValid.

// O QUE O DATASHEET DO BMP085 DIZ
//  - Com OSS = 0, cada unidade de UP vale ~3 Pa de pressão.
//  - Fórmula do datasheet:  altura = 44330 x (1 - (p / p0) ^ (1 / 5,255))   [altura em metros, p e p0 em Pa]
//    Ela serve para a altura ABSOLUTA, mas precisa de "elevar a 1/5,255", e isso é pesado de fazer na FPGA.
//    Não precisamos dela: o HUD só mostra a MUDANÇA de altura. Para mudanças pequenas a curva é praticamente uma reta.
//    A inclinação da reta perto do nível do mar é 44330 / 5,255 / 101325 = 0,0833 metro por Pa.
//  - Então: 1 unidade de UP = 3 Pa x 0,0833 m/Pa = ~0,25 metro.
//  - ATENÇÃO 1: o BMP085 é sensível ao calor. Esquentar o sensor (com a mão, por exemplo) muda o UP mesmo sem a placa se mexer.
//  - ATENÇÃO 2: a conta usa o valor do datasheet (~3 Pa por UP). Cada sensor é um pouco diferente. Se a escala andar mais ou menos
//    do que deveria quando você levanta a placa 1 metro, ajuste PX_PER_METER.

// COMO FUNCIONA (4 passos)
//  1) FILTRAR: o UP treme um pouco. A cada leitura nova, o valor filtrado anda só uma parte do caminho até ela.
//  2) REFERÊNCIA: depois do reset (e de algumas leituras para o filtro firmar), guarda o UP daquele momento. Essa é a altura "zero".
//  3) DIFERENÇA e ESCALA: UP de referência - UP filtrado = quanto a pressão caiu. Isso vira pixels (PX_PER_METER pixels por metro).
//  4) LIMITE: corta em +/-ALT_LIMIT para o número nunca passar do que cabe em 12 bits (altOffset vai de -2048 a 2047).

module barToAlt #(
    parameter bit INVERT = 1'b0, // 1 = troca o sentido (a escala sobe quando você sobe, vice-versa)

    parameter int PX_PER_METER = 50, // quantos pixels a escala anda por metro. Treme demais? Diminua. Quase não mexe? Aumente.

    parameter int FILT_SHIFT = 4, // quão devagar o filtro acompanha: anda 1/4 do caminho a cada leitura. Maior = mais suave e mais lento. (São só ~9 leituras por segundo, então 3 já fica bem lento.)

    parameter int ALT_LIMIT = 1000, // deslocamento máximo da escala, em pixels, para cima ou para baixo (máximo 2047)
    parameter int SETTLE_READS = 16 // quantas leituras esperar antes de pegar a referência (máximo 255). 16 leituras = ~2 s
)(
    input logic clk, // clock
    input logic rst_n, // reset
    input logic [15:0] pressRaw, // UP: pressão crua, 16 bits, sem sinal
    input logic pressValid, // pulso de 1 ciclo: "chegou UP novo"
    input logic zeroRef, // 1 = refaz a referência (a escala volta para 0 quando soltar)

    output logic signed [11:0] altOffset // pixels que a escala desliza. Mesmo tipo da entrada altOffset do altGen
);

// O valor filtrado guarda x16 (4 bits depois da vírgula) para não perder diferenças pequenas.
localparam int FRAC = 4;

// Pixels por unidade de UP, multiplicado por 256 (para ter casas depois da vírgula):
//  0,2498 m por unidade de UP (3 Pa x 0,08325 m/Pa) x 256 = 63,93  ->  6393 / 100 x PX_PER_METER
localparam int GAIN_X256 = (6393 * PX_PER_METER) / 100;

// PASSO 1 - FILTRO
// 22 bits com sinal: 16 do dado + 4 do x16 + folga para o sinal.
logic signed [21:0] pressX16; // leitura nova, já x16
logic signed [21:0] filtP; // valor filtrado (x16)
logic init; // 0 até chegar a primeira leitura

assign pressX16 = $signed({2'b00, pressRaw, {FRAC{1'b0}}});

function automatic logic signed [21:0] iirStep(
    input logic signed [21:0] currentFilteredVal, // valor atual do filtro (x16)
    input logic signed [21:0] newValueX16 // leitura nova (x16)
);
    logic signed [21:0] errorDelta;
    errorDelta = newValueX16 - currentFilteredVal; // distância até a leitura
    return currentFilteredVal + (errorDelta >>> FILT_SHIFT); // anda uma parte dessa distância
endfunction

// PASSO 2 - REFERÊNCIA
logic [7:0] settle; // quantas leituras já esperou (contador de leituras, antes de pegar a referencia)
logic haveRef; // 1 = a referência já foi pega (0, caso contrario)
logic signed [21:0] refP; // UP de referência (x16). A leitura do meu "chão". A altura zero, que é a pressão que esta guardada aqui.

// PASSO 3 e 4 - DIFERENÇA, ESCALA e LIMITE
logic signed [21:0] dP; // quanto a pressão caiu desde a referência. Positivo = subiu
logic signed [47:0] heightPx; // altura em pixels. Positivo = subiu
logic signed [47:0] shiftPx; // quanto a escala desliza. Positivo = escala sobe na tela
logic signed [11:0] altClamp;

always_comb begin
    dP = refP - filtP; // positivo = a pressão caiu => subiu
    heightPx = (48'(dP) * GAIN_X256) >>> (FRAC + 8); // tira o x16 e o x256 e vira pixels

    // Subiu -> a escala desce na tela (altOffset negativo). INVERT troca isso.
    shiftPx = INVERT ? heightPx : -heightPx;

    if(shiftPx > ALT_LIMIT) altClamp = 12'(ALT_LIMIT);
    else if(shiftPx < -ALT_LIMIT) altClamp = 12'(-ALT_LIMIT);
    else altClamp = shiftPx[11:0];
end

// Tudo roda 1 ciclo DEPOIS do pressValid (validD): no ciclo do pressValid o filtro ainda está sendo atualizado.
logic validD;

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        init <= 1'b0;
        filtP <= '0;
        settle <= '0;
        haveRef <= 1'b0;
        refP <= '0;
        validD <= 1'b0;
        altOffset <= '0;
    end else begin
            validD <= pressValid;

            // Filtro: na primeira leitura já começa nela (senão levaria muito tempo subindo desde 0).
            if(pressValid) begin
                if(!init) begin
                    filtP <= pressX16;
                    init <= 1'b1;
                end else begin
                    filtP <= iirStep(filtP, pressX16);
                end
            end

        // Referência: zeroRef = 1 reinicia a espera. Depois de SETTLE_READS leituras, guarda o UP daquele momento.
        if(zeroRef) begin
            settle <= '0;
            haveRef <= 1'b0;
        end else if(validD && !haveRef) begin
            if(settle == 8'(SETTLE_READS - 1)) begin
                refP <= filtP;
                haveRef <= 1'b1;
            end else begin
                settle <= settle + 1'b1;
            end
        end
        // Saída: só muda quando chega leitura nova. Sem referência ainda, fica em 0 (escala parada).
        if(validD) altOffset <= haveRef ? altClamp : 12'sd0;
    end
end
endmodule

`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  Recebe a PRESSÃO do ar, em Pascal (já compensada pela temperatura, vinda do baroCompensate), e entrega o "altOffset":
//  quantos PIXELS a escala de altitude (altGen) deve deslizar.
//  Ele NÃO desenha nada. É o equivalente do accelToHorizon / accelToCompass, só que para o barômetro.
//    Placa SOBE   -> pressão do ar CAI    -> a escala desce na tela (altOffset negativo)
//    Placa DESCE  -> pressão do ar SOBE   -> a escala sobe na tela  (altOffset positivo)
//    Mesma altura de quando pegou a referência -> altOffset = 0
//  (A escala desce quando você sobe porque o ponteiro fica parado no meio e os números novos vêm de cima, como num avião de verdade.
//   Se na sua tela ficar ao contrário, ponha INVERT em 1'b1.)

// DE ONDE VÊM OS DADOS (o caminho todo)
//  sensor BMP085 --(fios SDA e SCL, protocolo I2C)--> i2c_master --> bmp085_reader --> baroCompensate --> barToAlt (este arquivo) --> altGen --> tela
//    i2c_master      = o "spiMaster" do I2C: sabe mandar/ler 1 byte nos fios.
//    bmp085_reader   = o "adxl362Ctrl" do I2C: sabe a ordem de conversa com o sensor (pedir medida, esperar, ler os bytes).
//    baroCompensate  = faz a conta do datasheet: pega a temperatura crua e a pressão crua e entrega a pressão VERDADEIRA em Pascal.
//                      Sem isso, o número cru muda ~19 metros por grau de temperatura do sensor, e o altímetro foge sozinho.
//    pressPa    <- baroCompensate.pressPa  (pressão em Pascal, 20 bits, sem sinal)
//    pressValid <- baroCompensate.valid    (pulso de 1 ciclo: "chegou pressão nova")
//  Chega cerca de 9 a 10 leituras por segundo. Daqui para baixo, "1 leitura" = 1 pulso de pressValid.

// A CONTA DE PRESSÃO PARA ALTURA
//  Fórmula do datasheet (seção 3.6):  altura = 44330 x (1 - (p / p0) ^ (1 / 5,255))   [altura em metros, p e p0 em Pa]
//  Ela precisa de "elevar a 1/5,255", que é pesado para a FPGA. Como o HUD só mostra a MUDANÇA de altura, e para mudanças pequenas a curva
//  é praticamente uma reta, usamos a inclinação da reta perto do nível do mar: 44330 / 5,255 / 101325 = 0,0833 metro por Pascal.
//  (Conferido com a fórmula completa: a reta erra só ~1% até 100 m de diferença.)
//  Então: 1 Pa = ~0,0833 m, ou 12 Pa = ~1 metro.
//  ATENÇÃO: o sensor tem um ruído de uns 6 Pa (~0,5 m) em cada leitura. O filtro abaixo existe para esconder isso.
//  Pressão do ambiente (ar-condicionado, porta, vento) também move a leitura de verdade.

// COMO FUNCIONA (4 passos)
//  1) FILTRAR: a pressão treme um pouco. A cada leitura nova, o valor filtrado anda só uma parte do caminho até ela.
//  2) REFERÊNCIA: depois do reset (e de algumas leituras para o filtro firmar), guarda a pressão daquele momento. Essa é a altura "zero".
//  3) DIFERENÇA e ESCALA: pressão de referência - pressão filtrada = quanto a pressão caiu. Isso vira pixels (PX_PER_METER pixels por metro).
//  4) LIMITE: corta em +/-ALT_LIMIT para o número nunca passar do que cabe em 12 bits (altOffset vai de -2048 a 2047).

module barToAlt #(
    // São os "botões de ajuste". Dá para mudar na instância dentro do hudTop, sem mexer neste arquivo.
    parameter bit INVERT = 1'b0, // 1 = troca o sentido (a escala sobe quando você sobe)

    parameter int PX_PER_METER = 150, // quantos pixels a escala anda por metro. Treme demais? Diminua. Quase não mexe? Aumente.

    parameter int FILT_SHIFT = 3, // quão devagar o filtro acompanha: anda 1/8 do caminho a cada leitura. Maior = mais suave e mais lento. (São só ~9 leituras por segundo, então 4 já fica bem lento.)

    parameter int FAST_ERR_PA = 14, // filtro adaptivo: se a leitura nova estiver a mais de FAST_ERR_PA Pascal do valor filtrado (12 Pa = ~1 m), é movimento de verdade, não ruído, e o filtro fica rápido. Muito alto = nunca fica rápido (mais lento). Muito baixo = o ruído dispara o modo rápido (treme).
    parameter int FILT_SHIFT_FAST = 2, // quão rápido o filtro anda nesse modo: 2 = 1/4 do caminho a cada leitura. Menor = mais rápido.

    parameter int HYST_PX = 10, // zona morta: a escala só se mexe se o valor novo for mais que HYST_PX pixels diferente do atual. Tira o tremor pequeno. 0 = desligado. Muito grande = a escala anda aos pulos.

    parameter int ALT_LIMIT = 1000, // deslocamento máximo da escala, em pixels, para cima ou para baixo (máximo 2047)
    parameter int SETTLE_READS = 16 // quantas leituras esperar antes de pegar a referência (máximo 255). 16 leituras = ~2 s
)(
    input logic clk, // clock
    input logic rst_n, // reset, ativo em 0
    input logic [19:0] pressPa, // pressão do ar em Pascal (compensada), 20 bits, sem sinal
    input logic pressValid, // pulso de 1 ciclo: "chegou pressão nova"
    input logic zeroRef, // 1 = refaz a referência (a escala volta para 0 quando soltar)

    output logic signed [11:0] altOffset // pixels que a escala desliza. Mesmo tipo da entrada altOffset do altGen
);

// O valor filtrado guarda x16 (4 bits depois da vírgula) para não perder diferenças pequenas, igual ao accelToHorizon.
localparam int FRAC = 4;

// Pixels por Pascal, multiplicado por 256 (para ter casas depois da vírgula):
//   0,08325 metro por Pa x 256 = 21,31  ->  2131 / 100 x PX_PER_METER
localparam int GAIN_X256 = (2131 * PX_PER_METER) / 100;

// PASSO 1 - FILTRO
// 26 bits com sinal: 20 do dado + 4 do x16 + folga para o sinal.
logic signed [25:0] pressX16; // leitura nova, já x16
logic signed [25:0] filtP; // valor filtrado (x16)
logic init; // 0 até chegar a primeira leitura

assign pressX16 = $signed({2'b00, pressPa, {FRAC{1'b0}}});

// Filtro ADAPTIVO: o passo depende de quão longe a leitura nova está do valor filtrado.
//   Perto (só ruído, até FAST_ERR_PA Pascal): anda devagar, 1/2^FILT_SHIFT do caminho. A escala fica parada.
//   Longe (movimento de verdade): anda rápido, 1/2^FILT_SHIFT_FAST do caminho. A escala acompanha logo.
localparam int FAST_ERR_X16 = FAST_ERR_PA << FRAC; // o mesmo limite, já na escala x16

function automatic logic signed [25:0] iirStep(
    input logic signed [25:0] currentFilteredVal, // valor atual do filtro (x16)
    input logic signed [25:0] newValueX16 // leitura nova (x16)
);
    logic signed [25:0] errorDelta;
    errorDelta = newValueX16 - currentFilteredVal; // distância até a leitura
    if((errorDelta > FAST_ERR_X16) || (errorDelta < -FAST_ERR_X16))
        return currentFilteredVal + (errorDelta >>> FILT_SHIFT_FAST); // longe: anda rápido
    else
        return currentFilteredVal + (errorDelta >>> FILT_SHIFT); // perto: anda devagar
endfunction

// PASSO 2 - REFERÊNCIA
logic [7:0] settle; // quantas leituras já esperou
logic haveRef; // 1 = a referência já foi pega
logic signed [25:0] refP; // pressão de referência (x16)

// PASSO 3 e 4 - DIFERENÇA, ESCALA e LIMITE
logic signed [25:0] dP; // quanto a pressão caiu desde a referência (x16). Positivo = subiu
logic signed [47:0] heightPx; // altura em pixels. Positivo = subiu
logic signed [47:0] shiftPx; // quanto a escala desliza. Positivo = escala sobe na tela
logic signed [11:0] altClamp;

always_comb begin
    dP = refP - filtP; // positivo = a pressão caiu = subiu
    heightPx = (48'(dP) * GAIN_X256) >>> (FRAC + 8); // tira o x16 e o x256 e vira pixels

    // Subiu -> a escala desce na tela (altOffset negativo). INVERT troca isso.
    shiftPx = INVERT ? heightPx : -heightPx;

    if(shiftPx > ALT_LIMIT) altClamp = 12'(ALT_LIMIT);
    else if(shiftPx < -ALT_LIMIT) altClamp = 12'(-ALT_LIMIT);
    else altClamp = shiftPx[11:0];
end

// Tudo roda 1 ciclo DEPOIS do pressValid (validD): no ciclo do pressValid o filtro ainda está sendo atualizado (mesmo motivo do accelToHorizon).
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

        // Referência: zeroRef = 1 reinicia a espera. Depois de SETTLE_READS leituras, guarda a pressão daquele momento.
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
        // Zona morta (HYST_PX): com referência, a saída só acompanha o valor novo se ele estiver a mais de HYST_PX pixels do valor atual.
        // Assim o tremor pequeno some, e um movimento de verdade (que passa de HYST_PX) continua sendo seguido.
        if(validD) begin
            if(!haveRef) altOffset <= 12'sd0;
            else if((altClamp - altOffset > HYST_PX) || (altOffset - altClamp > HYST_PX)) altOffset <= altClamp;
        end
    end
end

endmodule

`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  Empurrou a placa para a DIREITA  -> o ângulo da bússola AUMENTA (0, 15, 30 ... 359, volta para 0)
//  Empurrou a placa para a ESQUERDA -> o ângulo DIMINUI (0, 345, 330 ...)
//  Funciona com a placa plana ou inclinada. Não é o norte de verdade, é só uma simulação.
//  Ele NÃO desenha nada: só entrega o ângulo (compassHeading) para quem for desenhar a bússola.

//  1) Separar a leitura em duas partes: a parte PARADA e a parte do EMPURRÃO.
//  2) Só contar o empurrão se ele for forte o bastante (FLICK_MG). Cada empurrão contado soma STEP_DEG graus.
//  3) Depois de contar um empurrão, IGNORAR as leituras por um tempinho (LOCKOUT_READS).
//  Assim, O ângulo não pula de uma vez. Ele anda aos poucos para a bússola deslizar suave na tela.

// DE ONDE VÊM OS DADOS
//  adxl362Ctrl.accelX -> accelX
//  adxl362Ctrl.accelY -> accelY
//  adxl362Ctrl.dataValid -> accelValid
//  O adxl362Ctrl lê o sensor 100 vezes por segundo. Cada vez que chega uma leitura nova, ele dá UM pulso de 1 ciclo em dataValid.
//  Daqui para baixo, "1 leitura" = 10 ms. As leituras são em mg (milésimos de g), com sinal (podem ser negativas).

// DEPOIS DO RESET
//   O ângulo começa em 0. Nos primeiros ~1,2 s empurrões são ignorados, para a média lenta ter tempo de descobrir a gravidade.

module accelToCompass #(
    // São os "botões de ajuste". Dá para mudar na instância dentro do hudTop, sem mexer neste arquivo.
    parameter bit SWAP_XY = 1'b1, // eixo que sente ESQUERDA/DIREITA: 0 = usa X, 1 = usa Y
    parameter bit INVERT  = 1'b0, // 1 = troca os lados 

    parameter int HP_SHIFT = 5, // quão devagar a média lenta acompanha a leitura. Maior = mais lenta.

    parameter int FLICK_MG = 200, // O que é um empurrão? --> força mínima do empurrão, em mg. Empurrou e nada aconteceu? Diminua. Conta empurrão sozinho? Aumente.
    parameter int LOCKOUT_READS = 40, // quantas leituras ignorar depois de um empurrão. Precisa cobrir o tempo de parar a placa. Se o ângulo "volta sozinho" depois do empurrão, aumente.

    parameter int STEP_DEG = 15, // quantos graus cada empurrão soma
    parameter int SLEW = 128 // quanto o ângulo anda por leitura até chegar no destino, em 1/256 de grau. 128 = meio grau por leitura = 50 graus por segundo
)(
    input logic clk, // clock
    input logic rst_n, // reset, ativo em 0
    input logic signed [11:0] accelX, // leitura do eixo X, em mg
    input logic signed [11:0] accelY, // leitura do eixo Y, em mg
    input logic accelValid, // pulso de 1 ciclo: "chegou leitura nova"

    output logic [8:0] compassHeading, // ângulo da bússola, em graus inteiros: 0 a 359
    output logic [3:0] compassFrac // pedaço do grau, para a escala deslizar sem pulos de 1 grau
);

// 1 grau = 256 unidades. Volta inteira = 360 x 256 = 92160 unidades (cabe em 17 bits).
localparam int FULL_TURN = 360 * 256;
localparam int STEP_UNITS = STEP_DEG * 256; // o passo de cada empurrão, nessa unidade
localparam int FRAC = 4; // a média lenta guarda a leitura x16
localparam int SETTLE_READS = 120; // ~1,2s ignorando empurrões depois do reset

logic signed [11:0] rawSide;
always_comb begin
    rawSide = SWAP_XY ? accelY : accelX;
    if(INVERT) rawSide = -rawSide;
end

// Placa parada e inclinada para o lado, por exemplo, lê 300 mg o tempo todo. Isso NÃO é empurrão, é só a gravidade.
// A média lenta vai se aproximando da leitura aos poucos, até chegar nesses 300 mg.
// Um empurrão é rápido demais: a média quase não se mexe durante ele. Por isso a diferença "leitura - média" mostra só o empurrão.
logic signed [17:0] slowAvg; // média lenta, guardada x16

function automatic logic signed [17:0] iirStep(
    input logic signed [17:0] currentFilteredVal, // valor atual da média (x16)
    input logic signed [11:0] newSensorValue, // leitura nova, em mg
    input int shift // quanto maior, mais devagar anda
);
    logic signed [17:0] expandedSensorVal, errorDelta;

    expandedSensorVal = {{2{newSensorValue[11]}}, newSensorValue, {FRAC{1'b0}}}; // leitura x16, para ficar na mesma escala da média

    errorDelta = expandedSensorVal - currentFilteredVal; // distância até a leitura

    return currentFilteredVal + (errorDelta >>> shift); // anda uma fração dessa distância
endfunction

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) slowAvg <= '0;
    else if(accelValid) slowAvg <= iirStep(slowAvg, rawSide, HP_SHIFT); // só atualiza quando chega leitura nova
end

// Placa parada (plana ou inclinada): leitura e média são iguais, então a força é ~0.
// Exemplo: placa parada em 300 mg, empurrou e a leitura foi para 700 mg. A média ainda está em ~300. Força = 700 - 300 = 400 mg.
// Positiva = empurrou para um lado. Negativa = empurrou para o outro.
// (>>> FRAC tira o "x16" da média para ficar em mg igual à leitura.)
logic signed [17:0] pushMg;
always_comb begin
    pushMg = $signed({{6{rawSide[11]}}, rawSide}) - (slowAvg >>> FRAC);
end

// No ciclo do accelValid a média lenta ainda está sendo atualizada, e só no ciclo seguinte ela já tem o valor novo.

logic validD; // accelValid atrasado em 1 ciclo
logic [7:0] lockout; // quantas leituras ainda faltam ignorar (0 = pode contar empurrão)
logic signed [17:0] pending; // quanto ainda falta o ângulo andar (em 1/256 de grau)
logic [16:0] angleAcc; // ângulo atual (em 1/256 de grau, de 0 a 92159)

logic pushed; // 1 = acabou de ser contado um empurrão
logic signed [17:0] stepAdd; // passo novo deste empurrão (+ ou -). Vale 0 se não houve empurrão
logic signed [17:0] pendEff; // quanto falta andar, já contando o passo novo
logic signed [17:0] move; // quanto o ângulo anda NESTA leitura (no máximo SLEW)
logic signed [17:0] pendingNext; // quanto ainda vai faltar depois de andar
logic signed [18:0] sum; // ângulo + move, com sinal, para dar para perceber que passou de 359 ou ficou abaixo de 0

always_comb begin
    // a) Contar: a força passou de FLICK_MG (para qualquer lado) E a pausa já acabou (lockout = 0).
    //    A pausa é o que impede de contar a parada da placa como um empurrão ao contrário.
    pushed = validD && (lockout == 0) && ((pushMg > 18'(FLICK_MG)) || (pushMg < -18'(FLICK_MG)));

    // b) O passo tem o sinal da força: positiva soma STEP_DEG graus, negativa subtrai.
    stepAdd = '0;
    if(pushed) stepAdd = (pushMg > 0) ? 18'(STEP_UNITS) : -18'(STEP_UNITS);
    pendEff = pending + stepAdd;

    // c) Andar: nesta leitura o ângulo anda no máximo SLEW em direção ao destino.
    //    Exemplo: um empurrão = 15 graus = 3840 unidades. Andando 128 por leitura, leva 30 leituras (0,3 s) para chegar.
    if(pendEff > 18'(SLEW)) move = 18'(SLEW);
    else if(pendEff < -18'(SLEW)) move = -18'(SLEW);
    else move = pendEff;

    pendingNext = pendEff - move;

    // d) Novo ângulo = ângulo + o que andou.
    sum = $signed({2'b00, angleAcc}) + $signed({move[17], move});
end

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        validD <= 1'b0;
        lockout <= 8'(SETTLE_READS); // começa em pausa, para a média lenta descobrir a gravidade antes
        pending <= '0;
        angleAcc <= '0; // começa no 0
    end else begin
        validD <= accelValid;
        if(validD) begin
            pending <= pendingNext;

            // Contou empurrão: começa a pausa. Senão, a pausa vai diminuindo 1 por leitura até chegar a 0.
            if(pushed) lockout <= 8'(LOCKOUT_READS);
            else if(lockout != 0) lockout <= lockout - 1'b1;

            // Dar a volta: passou de 359,99 volta para o começo; ficou abaixo de 0 volta para o fim (~359).
            if(sum < 0) angleAcc <= 17'(sum + FULL_TURN);
            else if(sum >= FULL_TURN) angleAcc <= 17'(sum - FULL_TURN);
            else angleAcc <= 17'(sum);
        end
    end
end
// angleAcc / 256 = graus inteiros. Dividir por 256 é só pegar os bits de cima [16:8]. O máximo é 92159/256 = 359, cabe em 9 bits.
// Os 4 bits seguintes ([7:4]) são o pedaço do grau, de 1/16 em 1/16.
assign compassHeading = angleAcc[16:8];
assign compassFrac = angleAcc[7:4];
endmodule

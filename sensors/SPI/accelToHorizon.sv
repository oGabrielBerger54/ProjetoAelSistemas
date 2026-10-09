`timescale 1ns / 1ps

// OBJETIVO
//   O adxl362Ctrl entrega a aceleração medida pelo sensor em "mg" (milésimos de g). Mas o horizonGen (que desenha a linha do horizonte no VGA) não entende "mg". 

//   Ele precisa saber duas coisas:
//       - quantos PIXELS subir/descer o horizonte -> horizonVerticalDelta
//       - quão INCLINADA fica a linha -> horizonHorizontalDelta

//   Este módulo faz essa tradução em 4 passos:
//       1) ESCOLHE qual eixo vira o quê (e se inverte o sinal)
//       2) SUAVIZA (filtro) para a linha não ficar tremendo
//       3) ESCALA (mg -> pixels) e LIMITA, para o desenho não sair da tela
//       4) GUARDA o resultado nas saídas, só quando há leitura nova

//   O adxl362Ctrl lê o sensor ~100 vezes por segundo. A cada leitura nova ele atualiza accelX/accelY/accelZ e dá UM pulso de 1 ciclo em dataValid.
//   No hudTop a ligação é:
//       adxl362Ctrl.accelX     ->  accelToHorizon.accelX
//       adxl362Ctrl.accelY     ->  accelToHorizon.accelY
//       adxl362Ctrl.dataValid  ->  accelToHorizon.accelValid

//   Os valores são números COM SINAL de 12 bits, em mg. Com a placa parada e plana, o eixo Z "vê" ~1000 mg (a gravidade) e X e Y ficam perto de 0. 
//   Inclinando a placa, X e Y passam a "ver" uma parte da gravidade. Entre dois pulsos de accelValid, os números ficam parados.

// PARA ONDE VÃO OS DADOS
//   horizonVerticalDelta e horizonHorizontalDelta -> (hudTop) -> horizonGen.
//   O horizonGen só copia esses valores no FIM de cada quadro de vídeo, então eles podem mudar a qualquer momento sem "rasgar" a imagem.

// DEPOIS DO RESET
//   As saídas começam em 0 (horizonte reto, no meio). O 1º dado do sensor só chega ~50 ms depois (o adxl362Ctrl espera o sensor ligar e medir). 
//   Como o filtro parte de 0, o horizonte "desliza" até a posição certa em ~0,2 s.

module accelToHorizon #(
    // São os "botões de ajuste". Dá para mudá-los na instância dentro do hudTop, sem mexer neste arquivo. Exemplo: accelToHorizon #(.INVERT_V(1'b1))
    parameter bit SWAP_XY = 1'b1,   // 1 = troca os eixos (X vira vertical, Y vira inclinação)
    parameter bit INVERT_V = 1'b0,  // 1 = inverte o sentido do deslocamento vertical
    parameter bit INVERT_H = 1'b0,  // 1 = inverte o sentido da inclinação

    parameter int FILT_SHIFT = 3,   // força do filtro: a cada leitura nova, o aumento do valor filtrado, nesse caso, eh divido por 8 para ficar suave o movimento
                                    //   0 = sem filtro.

    parameter int V_SHIFT = 2,      // Divide por 4 o valor do sensor vertical (para caber na tela)
    parameter int H_SHIFT = 2,      // Divide por 4 o valor do sensor horizontal (para caber na tela)

    parameter int V_LIMIT = 200,    // deslocamento vertical máximo, em pixels (para cima ou para baixo)
    parameter int H_LIMIT = 511     // inclinação máxima (para um lado ou para o outro)
)(
    input logic clk, // clock do projeto
    input logic rst_n, // reset, ativo em 0
    input logic signed [11:0] accelX, // aceleração X em mg, vem do adxl362Ctrl. "signed" = pode ser negativa (complemento de 2).
    input logic signed [11:0] accelY, // aceleração Y em mg, vem do adxl362Ctrl
    input logic accelValid, // pulso de 1 ciclo: "X e Y acabaram de ser atualizados"

    // Os dois números abaixo vão para o horizonGen (via hudTop).
    // Lembre: o Y da tela CRESCE PARA BAIXO, então valor positivo = desce.
    output logic signed [8:0] horizonVerticalDelta,   // pixels que o horizonte sobe/desce (-256 a 255)
    output logic signed [9:0] horizonHorizontalDelta  // inclinação da linha, em 1/256 de pixel por coluna (-512 a 511). Ex.: 128 = 0,5 px por coluna
);

// Quantos bits "depois da vírgula" o filtro guarda. Pois o filtro pode acabar zerando valores.
localparam int FRAC = 4;

// PASSO 1 - ESCOLHER O EIXO (e inverter o sinal, se pedido)
// Por padrão:  Y -> deslocamento VERTICAL do horizonte (como "inclinar o nariz") X -> INCLINAÇÃO da linha (como "rolar as asas")
// Obs: Não se sabe de antemão como o chip está orientado na placa: teste inclinando a placa e, se o horizonte mexer errado, mude SWAP_XY / INVERT_V / INVERT_H. (***)

logic signed [11:0] rawV, rawH;
always_comb begin
    rawV = SWAP_XY ? accelX : accelY;
    rawH = SWAP_XY ? accelY : accelX;
    if(INVERT_V) rawV = -rawV;
    if(INVERT_H) rawH = -rawH;
end

// PASSO 2 - FILTRO (suavizar o "tremido")
// O sensor treme um pouco (ruído) e qualquer vibração. Sem filtro, a linha do horizonte ficaria tremendo na tela.

// Solução: a cada leitura nova, o valor filtrado NÃO pula para a leitura; ele anda só uma fração do caminho até ela:
//        novo_filtrado = filtrado + (leitura - filtrado) / 2^FILT_SHIFT

// Com FILT_SHIFT = 3, anda 1/8 do caminho. Exemplo (placa passa de 0 a 1000 mg):
//        1ª leitura -> 125 mg, 2ª -> 234 mg, 3ª -> 330 mg ... (chega perto de 1000 em ~22 leituras, cerca de 0,2 s). Ruídos pequenos quase somem.

// POR QUE FRAC = 4 BITS "DEPOIS DA VÍRGULA"?
//   Dividir por 8 em números inteiros joga fora o resto: 
//   Uma diferença pequena (menos de 8) viraria 0. Então o valor filtrado é guardado multiplicado por 16 (4 bits extras, como casas decimais em binário). 
//   Assim as divisões não perdem precisão. filtV/filtH valem, portanto, "mg x 16".
//   São 18 bits: 12 do dado + 4 extras + 2 de folga para a conta da diferença não estourar.

logic signed [17:0] filtV, filtH; // valores filtrados (mg x 16): registradores, guardam entre ciclos

// Entra o valor filtrado atual (y) e a leitura nova (x), sai o novo valor filtrado.
function automatic logic signed [17:0] iirStep(
    input logic signed [17:0] currentFilteredVal, // O valor acumulado no filtro (mg x 16)
    input logic signed [11:0] newSensorValue // O dado bruto de 12 bits do acelerômetro
);
    logic signed [17:0] expandedSensorVal, errorDelta;

    // 1. Ajusta o formato da nova leitura: 2 bits de sinal no topo + 4 bits fracionários na base (x16)
    expandedSensorVal = {{2{newSensorValue[11]}}, newSensorValue, {FRAC{1'b0}}};

    // 2. Calcula o erro/distância entre o valor atual do filtro e a nova leitura
    errorDelta = expandedSensorVal - currentFilteredVal;

    // 3. Avança uma fração desse caminho (errorDelta / 2^FILT_SHIFT) e atualiza o filtro
    return currentFilteredVal + (errorDelta >>> FILT_SHIFT);
endfunction

// Só atualiza o filtro quando chega leitura NOVA (accelValid = 1, ~a cada 10 ms).
// Nos outros ciclos, filtV e filtH ficam como estão.
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        filtV <= '0;
        filtH <= '0;
    end else if(accelValid) begin
        filtV <= iirStep(filtV, rawV);
        filtH <= iirStep(filtH, rawH);
    end
end

// PASSO 3 - ESCALA (mg -> pixels) e LIMITE

// ESCALA: ">>> (FRAC + V_SHIFT)" faz duas coisas de uma vez: tira os 4 bits extras do filtro (volta para mg) e divide por 2^V_SHIFT.
//     vertical:  mg / 4  ->  1000 mg = 250 pixels
//     inclinação: mg / 4 ->  1000 mg = 250, que o horizonGen lê como  250/256 = ~1 pixel por coluna (~45 graus)

// LIMITE: se o resultado passar do máximo, trava no máximo (e no mínimo).
//   - vertical: +/-200 pixels. Em torno do centro da tela (y = 240), o horizonte fica entre y = 40 e y = 440, sempre dentro dos 480 pixels.

// O limite é atingido com ~800 mg (placa inclinada uns 53 graus).
//   - inclinação: +/-511. O sensor entrega no máximo ~2047 mg, e 2047/4 = 511.
//     Acima de ~2 pixels por coluna, a linha (que tem 2 pixels de espessura) teria buracos.

logic signed [17:0] scaledV, scaledH; // valores já em "pixels" (ainda sem limite)
logic signed [8:0]  clampV; // vertical depois do limite (cabe em 9 bits com sinal)
logic signed [9:0]  clampH; // inclinação depois do limite (cabe em 10 bits com sinal)

always_comb begin
    scaledV = filtV >>> (FRAC + V_SHIFT);
    scaledH = filtH >>> (FRAC + H_SHIFT);

    if(scaledV >  V_LIMIT) clampV = 9'(V_LIMIT); // passou do máximo: trava no máximo
    else if(scaledV < -V_LIMIT) clampV = 9'(-V_LIMIT); // passou do mínimo: trava no mínimo
    else clampV = scaledV[8:0]; // está dentro: pega só os 9 bits de baixo (cabe, porque já está entre -200 e 200)

    if(scaledH >  H_LIMIT) clampH = 10'(H_LIMIT);
    else if(scaledH < -H_LIMIT) clampH = 10'(-H_LIMIT);
    else clampH = scaledH[9:0];
end


// PASSO 4 - REGISTRO DE SAÍDA (guardar o resultado)

// As saídas só mudam quando há leitura nova, e ficam estáveis entre elas.
// POR QUE O 'validD' (accelValid atrasado 1 ciclo)?
//   Linha do tempo:
//     - na borda do clock em que accelValid = 1, o filtro atualiza filtV/filtH. O clampV/clampH só refletem o valor NOVO depois dessa borda.
//     - se copiássemos a saída nessa mesma borda, pegaríamos o resultado ANTIGO. Então esperamos 1 ciclo: validD vale 1 no ciclo seguinte, quando clampV/clampH já estão corretos, e aí copiamos.

logic validD; // registrador: accelValid atrasado em 1 ciclo
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        validD <= 1'b0;
        horizonVerticalDelta <= '0;
        horizonHorizontalDelta <= '0;
    end else begin
        validD <= accelValid;
        if(validD) begin
            horizonVerticalDelta   <= clampV;
            horizonHorizontalDelta <= clampH;
        end
    end
end
endmodule

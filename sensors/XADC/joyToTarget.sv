`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  Pega a posição do joystick (joyX, joyY: números de 0 a 1023) e transforma na posição da MIRA na tela (targetX, targetY: pixels).
//  Também trava a mira: apertou o gatilho, a mira para onde está. Apertou de novo, destrava. (***)
//    Joystick no centro        -> mira no meio da tela
//    Joystick todo à direita   -> mira perto da borda direita
//    Joystick todo para cima   -> mira perto da borda de cima
//  A mira SEGUE a posição do joystick. Soltou o joystick (volta ao centro) = a mira volta ao meio, A NÃO SER que esteja travada.

// COMO FUNCIONA (4 passos)
//  1) ESCOLHER o eixo: qual eixo do joystick vira esquerda/direita e qual vira cima/baixo (e se inverte). Depende de como o JSTK2 está encaixado.
//  2) ZONA MORTA: o joystick solto não lê exatamente 512, fica tremendo um pouquinho. Perto do centro, a leitura vira 512 certinho, para a mira não tremer.
//  3) ESCALA e LIMITE: 0 a 1023 vira 0 a 639 (largura da tela) e 0 a 479 (altura da tela). A mira nunca chega a menos de MARGIN pixels da borda.
//  4) TRAVA: o gatilho liga/desliga a trava. Travada, a mira não anda.

module joyToTarget #(
    // São os "botões de ajuste". Dá para mudar na instância dentro do hudTop, sem mexer neste arquivo.
    parameter bit SWAP_XY = 1'b0, // 1 = troca os eixos (X vira vertical, Y vira horizontal)
    parameter bit INVERT_H = 1'b0, // 1 = troca esquerda e direita
    parameter bit INVERT_V = 1'b0, // 1 = troca cima e baixo

    parameter int DEADZONE = 12, // zona morta: até 12 de distância do centro (512), a leitura vale 512.

    parameter int MARGIN = 20, // distância mínima da mira até a borda da tela, em pixels (o desenho da mira precisa de espaço)

    parameter bit LOCK_TOGGLE = 1'b1, // 1 = cada aperto do gatilho liga/desliga a trava. 0 = trava SÓ enquanto o gatilho estiver apertado.
    parameter int BTN_LOCKOUT_READS = 20, // depois de um aperto, ignora o gatilho por 20 leituras (0,2 s). Evita que o "tremido" do botão conte 2 vezes.

    parameter int H_LAST = 639, // último x visível
    parameter int V_LAST = 479 // último y visível
)(
    input logic clk, // clock
    input logic rst_n, // reset, ativo em 0
    input logic [9:0] joyX, // posição X do joystick, 0 a 1023
    input logic [9:0] joyY, // posição Y do joystick, 0 a 1023
    input logic btnTrigger, // gatilho: 1 = apertado
    input logic joyValid, // pulso de 1 ciclo: "chegou leitura nova"

    output logic [9:0] targetX, // posição da mira na tela (coluna), 0 a 639
    output logic [9:0] targetY, // posição da mira na tela (linha), 0 a 479. Lembre: o Y da tela CRESCE PARA BAIXO.
    output logic targetLocked // 1 = mira travada
);

// PASSO 1 - ESCOLHER O EIXO
// axisH: 0 = esquerda, 1023 = direita.   axisV: 0 = baixo, 1023 = cima.
// Se a mira andar do lado errado, mude SWAP_XY / INVERT_H / INVERT_V no hudTop e teste de novo.
logic [9:0] axisH, axisV;
always_comb begin
    axisH = SWAP_XY ? joyY : joyX;
    axisV = SWAP_XY ? joyX : joyY;
    if(INVERT_H) axisH = 10'd1023 - axisH;
    if(INVERT_V) axisV = 10'd1023 - axisV;
end

// PASSO 2 - ZONA MORTA
// deltaH / deltaV = distância até o centro (512). Negativo = esquerda/baixo, positivo = direita/cima.
// Se a distância for menor que DEADZONE, a leitura vira 512 certinho.
logic signed [11:0] deltaH, deltaV;
logic [9:0] centerH, centerV;
always_comb begin
    deltaH = $signed({2'b00, axisH}) - 12'sd512;
    deltaV = $signed({2'b00, axisV}) - 12'sd512;

    centerH = axisH;
    centerV = axisV;
    if((deltaH < DEADZONE) && (deltaH > -DEADZONE)) centerH = 10'd512;
    if((deltaV < DEADZONE) && (deltaV > -DEADZONE)) centerV = 10'd512;
end

// PASSO 3 - ESCALA e LIMITE
// pixels = leitura x (tamanho da tela) / 1024. O "/ 1024" é só pegar os bits de cima ([19:10]).
//   Horizontal: 512 x 640 / 1024 = 320 (meio da tela).   1023 x 640 / 1024 = 639 (última coluna).
//   Vertical: o Y da tela cresce para BAIXO e o joystick cresce para CIMA, então fazemos "480 - resultado".
//             512 x 480 / 1024 = 240 -> 480 - 240 = 240 (meio da tela).
logic [19:0] mulH, mulV;
logic [9:0] posH, posV;
logic [9:0] wantX, wantY;
always_comb begin
    mulH = 20'(centerH) * 20'(H_LAST + 1);
    mulV = 20'(centerV) * 20'(V_LAST + 1);
    posH = mulH[19:10];
    posV = 10'(V_LAST + 1) - mulV[19:10]; // como aumenta pra baixo, precisa da altura pra subtrair

    // LIMITE: a mira fica entre MARGIN e (último pixel - MARGIN)
    if(posH < 10'(MARGIN)) wantX = 10'(MARGIN);
    else if(posH > 10'(H_LAST - MARGIN)) wantX = 10'(H_LAST - MARGIN);
    else wantX = posH;

    if(posV < 10'(MARGIN)) wantY = 10'(MARGIN);
    else if(posV > 10'(V_LAST - MARGIN)) wantY = 10'(V_LAST - MARGIN);
    else wantY = posV;
end

// PASSO 4 - TRAVA
// Só vale um APERTO NOVO: o gatilho está em 1 agora e estava em 0 na leitura anterior (trigPrev). Segurar o gatilho não conta de novo.
// Depois de contar um aperto, lockoutCnt ignora o gatilho por BTN_LOCKOUT_READS leituras (o botão "treme" ao apertar).
logic trigPrev; // gatilho na leitura anterior
logic [7:0] lockoutCnt; // quantas leituras ainda faltam ignorar o gatilho (0 = pode contar)
logic pressed; // 1 = aconteceu um aperto novo agora
logic lockNext; // como a trava vai ficar depois desta leitura

always_comb begin
    pressed = btnTrigger && !trigPrev && (lockoutCnt == 0);

    lockNext = targetLocked;
    if(LOCK_TOGGLE) begin
        if(pressed) lockNext = !targetLocked; // aperto novo: troca (travada <-> solta)
    end else begin
        lockNext = btnTrigger; // sem toggle: travada enquanto o gatilho estiver apertado
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        targetX <= 10'((H_LAST + 1) / 2); // começa no meio da tela
        targetY <= 10'((V_LAST + 1) / 2);
        targetLocked <= 1'b0;
        trigPrev <= 1'b0;
        lockoutCnt <= '0;
    end else if(joyValid) begin // só atualiza quando chega leitura nova
        trigPrev <= btnTrigger;
        targetLocked <= lockNext;

        if(pressed) lockoutCnt <= 8'(BTN_LOCKOUT_READS);
        else if(lockoutCnt != 0) lockoutCnt <= lockoutCnt - 1'b1;

        // Se a mira vai ficar travada (inclusive nesta leitura), NÃO anda. Assim, apertar o gatilho não empurra a mira junto.
        if(!lockNext) begin
            targetX <= wantX;
            targetY <= wantY;
        end
    end
end

endmodule

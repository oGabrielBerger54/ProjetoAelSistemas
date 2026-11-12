// tbVideo: testa o vídeo do cartão SD de ponta a ponta, SÓ PARA SIMULAÇÃO.
//
// vgaTiming + videoBackground (com sdVideoReader) + cartão simulado (sdCardModel).
// O testbench confere, pixel a pixel, se a cor que sai para o VGA é a do quadro que deveria estar
// na tela, e se o vídeo volta para o 1º quadro depois do último (loop com CMD12).
//
// Como rodar: vivado -mode batch -source sim/sim.tcl   (na pasta ProjetoAelSistemas)
`timescale 1ns/1ps
module tbVideo;

localparam int NF   = 3;   // quadros no "cartão"
localparam int HDR  = 40;  // setor do cabeçalho
localparam int SWAPS_TO_CHECK = 5; // 5 trocas > 3 quadros: passa pelo loop

logic clk = 0;
always #20 clk = ~clk; // 25 MHz

logic rstN = 0;
initial begin
    #200 rstN = 1;
end

logic hs, vs, activeVideo;
logic [9:0] pxJ, pxI;

vgaTiming vgaTiming (
    .clk(clk), .rstN(rstN),
    .hsync(hs), .vsync(vs), .activeVideo(activeVideo),
    .pxJ(pxJ), .pxI(pxI)
);

logic sdReset, sdSclk, sdMosi, sdMiso, sdCsN;
logic [3:0] bgR, bgG, bgB;
logic videoOn, statusLed;

// CLK_HZ pequeno: as esperas de liga/desliga ficam 100x mais curtas na simulação
videoBackground #(.CLK_HZ(250_000)) dut (
    .clk(clk), .rstN(rstN),
    .pxJ(pxJ), .pxI(pxI),
    .sdReset(sdReset), .sdSclk(sdSclk), .sdMosi(sdMosi), .sdMiso(sdMiso), .sdCsN(sdCsN),
    .bgR(bgR), .bgG(bgG), .bgB(bgB),
    .videoOn(videoOn), .statusLed(statusLed)
);

sdCardModel #(.HDR(HDR), .NF(NF), .FPS(15)) card (
    .powerOff(sdReset), .sclk(sdSclk), .mosi(sdMosi), .csN(sdCsN), .miso(sdMiso)
);

function automatic logic [7:0] pat(input int f, input int off);
    return 8'((f * 37 + off + (off >> 8)) & 8'hFF);
endfunction

// conta as trocas: a k-ésima troca põe na tela o quadro (k-1) mod NF
int swaps = 0;
int onScreen = -1;
always @(posedge clk) if(dut.swapAck) begin
    swaps++;
    onScreen = (swaps - 1) % NF;
    $display("[%0t] troca %0d: quadro %0d na tela", $time, swaps, onScreen);
end

// confere cada pixel visível
int errors = 0, checked = 0;
always @(negedge clk) begin
    if(rstN && videoOn && pxJ < 640 && pxI < 480 && onScreen >= 0) begin
        logic [7:0] b;
        logic [3:0] eR, eG, eB;
        b  = pat(onScreen, (pxI / 2) * 320 + (pxJ / 2));
        eR = {b[7:5], b[7]};
        eG = {b[4:2], b[4]};
        eB = {b[1:0], b[1:0]};
        checked++;
        if({bgR, bgG, bgB} !== {eR, eG, eB}) begin
            errors++;
            if(errors <= 10)
                $display("ERRO pixel (%0d,%0d) quadro %0d: veio %h%h%h, esperado %h%h%h",
                         pxJ, pxI, onScreen, bgR, bgG, bgB, eR, eG, eB);
        end
    end
end

// acompanha o status
logic [1:0] lastStatus = 2'bxx;
always @(posedge clk) if(dut.status !== lastStatus) begin
    lastStatus = dut.status;
    case(dut.status)
        2'd0: $display("[%0t] status: ligando o cartao", $time);
        2'd1: $display("[%0t] status: procurando o cabecalho", $time);
        2'd2: $display("[%0t] status: tocando (1o quadro no setor %0d)", $time, dut.sdVideoReader.firstFrame);
        2'd3: $display("[%0t] status: ERRO", $time);
    endcase
end

initial begin
    wait(swaps == SWAPS_TO_CHECK + 1);
    if(dut.sdVideoReader.firstFrame != HDR + 1) begin
        $display("ERRO: primeiro quadro no setor %0d, esperado %0d", dut.sdVideoReader.firstFrame, HDR + 1);
        errors++;
    end
    $display("--------------------------------------------");
    $display("Pixels conferidos: %0d   erros: %0d", checked, errors);
    if(errors == 0 && checked > 0) $display("PASSOU");
    else                           $display("FALHOU");
    $display("--------------------------------------------");
    $finish;
end

// trava de segurança
initial begin
    #2s;
    $display("FALHOU: tempo esgotado (trocas = %0d, status = %0d)", swaps, dut.status);
    $finish;
end

endmodule

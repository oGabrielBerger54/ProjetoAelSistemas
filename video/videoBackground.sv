// videoBackground: vídeo do cartão SD como fundo do HUD.
//
// - O sdVideoReader escreve cada quadro (320x240, RGB332) no buffer de trás.
// - Este módulo mostra o buffer da frente ampliado 2x (640x480) e troca os dois buffers
//   no começo do apagamento vertical (linha 480). Assim a imagem nunca aparece "rasgada".
// - Ritmo: cada quadro do vídeo fica na tela por 60/fps quadros VGA (15 fps -> 4).
//   Se o cartão não der conta, o vídeo só fica mais lento, sem falhas na imagem.
//
// A cor sai registrada e alinhada com o pixel atual (pxJ, pxI): o endereço é calculado
// para o próximo pixel, porque a BRAM entrega o dado 1 ciclo depois.
module videoBackground #(
    parameter int CLK_HZ = 25_000_000 // só muda na simulação, para os tempos de espera ficarem curtos
) (
    input  logic       clk,      // clk25
    input  logic       rstN,
    input  logic [9:0] pxJ,      // contadores do vgaTiming (0..799, 0..524)
    input  logic [9:0] pxI,

    // slot microSD
    output logic       sdReset,
    output logic       sdSclk,
    output logic       sdMosi,
    input  logic       sdMiso,
    output logic       sdCsN,

    output logic [3:0] bgR,
    output logic [3:0] bgG,
    output logic [3:0] bgB,
    output logic       videoOn,  // 1 = já tem quadro de vídeo na tela
    output logic       statusLed // apagado = ligando, piscando devagar = procurando o vídeo,
                                 // aceso = tocando, piscando rápido = erro (tenta de novo sozinho)
);

localparam int FRAME_BYTES = 320 * 240; // 76800

// ---------- Leitor do cartão ----------
logic        wrEn;
logic [16:0] wrAddr;
logic [7:0]  wrData;
logic        frameReady, swapAck;
logic [7:0]  fps;
logic [1:0]  status;

sdVideoReader #(.CLK_HZ(CLK_HZ)) sdVideoReader (
    .clk(clk),
    .rstN(rstN),
    .sdReset(sdReset),
    .sdSclk(sdSclk),
    .sdMosi(sdMosi),
    .sdMiso(sdMiso),
    .sdCsN(sdCsN),
    .wrEn(wrEn),
    .wrAddr(wrAddr),
    .wrData(wrData),
    .frameReady(frameReady),
    .swapAck(swapAck),
    .fps(fps),
    .status(status)
);

// ---------- Troca de buffers ----------
logic       front;      // buffer que está na tela (0 ou 1); o leitor escreve no outro
logic       shown;      // já trocou pelo menos uma vez
logic [3:0] vgaCnt;     // quadros VGA desde a última troca
logic [3:0] hold;       // quantos quadros VGA cada quadro do vídeo fica na tela
logic [5:0] blink;

always_comb begin
    if     (fps >= 8'd30) hold = 4'd2;
    else if(fps >= 8'd20) hold = 4'd3;
    else if(fps >= 8'd15) hold = 4'd4;
    else if(fps >= 8'd12) hold = 4'd5;
    else if(fps >= 8'd10) hold = 4'd6;
    else                  hold = 4'd10;
end

logic vblankStart;
assign vblankStart = (pxI == 10'd480) && (pxJ == 10'd0);

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        front   <= 1'b0;
        shown   <= 1'b0;
        vgaCnt  <= '0;
        swapAck <= 1'b0;
        blink   <= '0;
    end else begin
        swapAck <= 1'b0;
        if(vblankStart) begin
            blink <= blink + 1'b1;
            if(frameReady && vgaCnt >= hold - 1'b1) begin
                front   <= ~front;
                shown   <= 1'b1;
                swapAck <= 1'b1;
                vgaCnt  <= '0;
            end else if(vgaCnt != 4'hF) begin
                vgaCnt <= vgaCnt + 1'b1;
            end
        end
        if(status == 2'd3) shown <= 1'b0; // erro: volta para o fundo fixo até o vídeo voltar
    end
end

assign videoOn = shown && (status == 2'd2);

always_comb begin
    case(status)
        2'd0:    statusLed = 1'b0;
        2'd1:    statusLed = blink[5];   // ~1 Hz
        2'd2:    statusLed = 1'b1;
        default: statusLed = blink[3];   // ~4 Hz
    endcase
end

// ---------- Framebuffer: 2 quadros de 76800 bytes (38 BRAMs) ----------
(* ram_style = "block" *) logic [7:0] fb [0:2*FRAME_BYTES-1];

logic [17:0] wrFull;
assign wrFull = front ? 18'(wrAddr) : 18'(wrAddr) + 18'(FRAME_BYTES); // escreve no buffer de trás

always_ff @(posedge clk) begin
    if(wrEn) fb[wrFull] <= wrData;
end

// próximo pixel
logic [9:0] nx, ny;
always_comb begin
    if(pxJ == 10'd799) begin
        nx = 10'd0;
        ny = (pxI == 10'd524) ? 10'd0 : pxI + 1'b1;
    end else begin
        nx = pxJ + 1'b1;
        ny = pxI;
    end
end

logic [8:0]  vx;
logic [7:0]  vy;
logic [16:0] rdOff;
logic [17:0] rdFull;
assign vx     = nx[9:1];                                    // 0..319 (quando nx < 640)
assign vy     = ny[8:1];                                    // 0..239 (quando ny < 480)
assign rdOff  = 17'(vx) + 17'({vy, 8'b0}) + 17'({vy, 6'b0}); // vy*320 + vx (fora da tela o valor não importa)
assign rdFull = front ? 18'(rdOff) + 18'(FRAME_BYTES) : 18'(rdOff);

logic [7:0] pix;
always_ff @(posedge clk) begin
    pix <= fb[rdFull];
end

// RGB332 -> 4 bits por cor (repete os bits de cima para ir de 0 a 15)
assign bgR = {pix[7:5], pix[7]};
assign bgG = {pix[4:2], pix[4]};
assign bgB = {pix[1:0], pix[1:0]};

endmodule

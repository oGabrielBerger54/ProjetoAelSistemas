// sdVideoReader: lê o vídeo do cartão microSD (modo SPI) e escreve os quadros no framebuffer.
//
// O vídeo é o arquivo VIDEO.BIN copiado num cartão FAT32 recém-formatado. Não lemos o FAT:
// procuramos o setor de cabeçalho pela assinatura, e os quadros vêm logo depois, em setores seguidos.
//   Cabeçalho (1 setor de 512 bytes):
//     bytes  0-15 : "AEL_HUD_VIDEO_V1"
//     bytes 16-31 : os mesmos 16 bytes invertidos (NOT bit a bit)
//     bytes 36-39 : número de quadros (little-endian)
//     byte  42    : fps
//   Quadros: 320x240, 1 byte por pixel (RGB332 = RRRGGGBB), 150 setores cada.
//
// Passos: liga o cartão -> inicializa (CMD0, CMD8, ACMD41, CMD58) -> CMD18 (leitura contínua) a partir do
// setor 0 procurando o cabeçalho -> lê os quadros -> no último, CMD12 e volta para o primeiro (loop).
// Se algo der errado, desliga o cartão, espera ~1 s e tenta de novo (dá para colocar o cartão depois).
//
// Troca de quadro (double buffer): quando um quadro inteiro foi escrito, frameReady sobe e a leitura PARA
// (no SPI o cartão espera o tempo que for sem clock). O videoBackground mostra o quadro e dá um pulso em
// swapAck; aí frameReady desce e a leitura do próximo quadro começa.
module sdVideoReader #(
    parameter int CLK_HZ       = 25_000_000,
    parameter int SEARCH_LIMIT = 262_144 // procura o cabeçalho nos primeiros 128 MB do cartão
) (
    input  logic        clk,
    input  logic        rstN,

    // pinos do slot microSD (modo SPI)
    output logic        sdReset,  // 1 = cartão desligado (na Nexys A7 o slot só tem energia com 0)
    output logic        sdSclk,
    output logic        sdMosi,   // SD_CMD
    input  logic        sdMiso,   // SD_DAT[0]
    output logic        sdCsN,    // SD_DAT[3]

    // escrita no framebuffer (endereço 0..76799 dentro do quadro)
    output logic        wrEn,
    output logic [16:0] wrAddr,
    output logic [7:0]  wrData,

    // troca de quadro
    output logic        frameReady,
    input  logic        swapAck,

    output logic [7:0]  fps,      // do cabeçalho
    output logic [1:0]  status    // 0 = ligando/inicializando, 1 = procurando o vídeo, 2 = tocando, 3 = erro
);

localparam int BLOCKS_PER_FRAME = 150; // 320*240 / 512
localparam logic [127:0] MAGIC = "AEL_HUD_VIDEO_V1"; // byte 0 = 'A' fica nos bits 127:120

localparam int T_POWER_OFF = CLK_HZ / 50;     // 20 ms com o cartão desligado
localparam int T_POWER_ON  = CLK_HZ / 25;     // 40 ms para a alimentação firmar
localparam int T_RETRY     = CLK_HZ;          // 1 s em erro antes de tentar de novo
localparam int ACMD41_TRIES = 4000;           // ~1,5 s em 390 kHz
localparam int TOKEN_TRIES  = 1_000_000;      // ~0,7 s em 12,5 MHz esperando o dado

// ---------- Byte SPI ----------
logic       spiSlow, spiStart, spiBusy, spiDone;
logic [7:0] spiTx, spiRx;

logic spiSclk, spiMosi, csN;

sdSpiByte #(.SLOW_HALF(32)) sdSpiByte (
    .clk(clk), .rstN(rstN),
    .slow(spiSlow), .start(spiStart), .txByte(spiTx),
    .rxByte(spiRx), .busy(spiBusy), .done(spiDone),
    .sclk(spiSclk), .mosi(spiMosi), .miso(sdMiso)
);

// Com o cartão desligado, todas as linhas ficam em 0 (senão os pinos em 1 alimentam o cartão "por trás"
// e ele não reseta direito).
assign sdSclk = sdReset ? 1'b0 : spiSclk;
assign sdMosi = sdReset ? 1'b0 : spiMosi;
assign sdCsN  = sdReset ? 1'b0 : csN;

// ---------- Máquina de estados ----------
typedef enum logic [5:0] {
    S_POWER_OFF, S_POWER_ON, S_DUMMY,
    S_CMD0, S_CMD0_R,
    S_CMD8, S_CMD8_R, S_CMD8_CHK,
    S_CMD55, S_CMD55_R, S_ACMD41, S_ACMD41_R,
    S_CMD58, S_CMD58_R, S_CMD58_CHK,
    S_CMD16, S_CMD16_R,
    S_READ_START, S_READ_R,
    S_GATE, S_TOKEN, S_TOKEN_CHK, S_DATA, S_DATA_GOT, S_CRC, S_BLOCK_END,
    S_STOP, S_STOP_R, S_STOP_BUSY, S_STOP_BUSY_CHK,
    // sub-rotinas
    S_XFER_WAIT,
    S_CMD_SEND, S_CMD_NEXT, S_CMD_R1, S_CMD_R1_CHK,
    S_RESP4, S_RESP4_GOT,
    S_GAP, S_GAP_DONE,
    S_ERROR
} state_t;

state_t state, xferRet, cmdRet, respRet, gapRet;

logic [47:0] cmdBuf;
logic [2:0]  cmdCnt;
logic [3:0]  pollCnt;
logic        skipFirst;     // CMD12: o primeiro byte depois do comando é lixo
logic [7:0]  r1;
logic [31:0] resp;
logic [2:0]  respCnt;

logic [24:0] timer;
logic [19:0] tries;
logic [3:0]  dummyCnt;

logic        v2Card;        // respondeu ao CMD8
logic        ccs;           // 1 = SDHC/SDXC (endereço em setores), 0 = SDSC (endereço em bytes)

logic        searching;
logic [31:0] sector;        // setor do próximo bloco que vai chegar
logic [31:0] firstFrame;    // setor do 1º quadro (cabeçalho + 1)
logic [31:0] nFrames, frameIdx;
logic [7:0]  blkInFrame;
logic [9:0]  byteCnt;
logic        crcCnt;
logic        matchOk;

logic [31:0] readArg;
assign readArg = ccs ? sector : {sector[22:0], 9'b0};

// byte esperado do cabeçalho na posição byteCnt (0..31)
logic [7:0] magicByte;
always_comb begin
    if(byteCnt < 10'd16) magicByte = MAGIC[127 - 8*byteCnt[3:0] -: 8];
    else                 magicByte = ~MAGIC[127 - 8*byteCnt[3:0] -: 8];
end

// Carrega um comando de 6 bytes: 01xxxxxx | argumento (32 bits) | CRC + bit de fim
`define SD_CMD(idx, arg, crc, ret) begin \
    cmdBuf <= {2'b01, 6'(idx), 32'(arg), 8'(crc)}; \
    cmdCnt <= '0; cmdRet <= ret; skipFirst <= 1'b0; \
    csN <= 1'b0; state <= S_CMD_SEND; end

`define XFER(b, ret) begin spiTx <= 8'(b); spiStart <= 1'b1; xferRet <= ret; state <= S_XFER_WAIT; end

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        state      <= S_POWER_OFF;
        xferRet    <= S_POWER_OFF;
        cmdRet     <= S_POWER_OFF;
        respRet    <= S_POWER_OFF;
        gapRet     <= S_POWER_OFF;
        sdReset    <= 1'b1;
        csN      <= 1'b1;
        spiSlow    <= 1'b1;
        spiStart   <= 1'b0;
        spiTx      <= 8'hFF;
        cmdBuf     <= '0;
        cmdCnt     <= '0;
        pollCnt    <= '0;
        skipFirst  <= 1'b0;
        r1         <= 8'hFF;
        resp       <= '0;
        respCnt    <= '0;
        timer      <= '0;
        tries      <= '0;
        dummyCnt   <= '0;
        v2Card     <= 1'b0;
        ccs        <= 1'b0;
        searching  <= 1'b1;
        sector     <= '0;
        firstFrame <= '0;
        nFrames    <= '0;
        frameIdx   <= '0;
        blkInFrame <= '0;
        byteCnt    <= '0;
        crcCnt     <= 1'b0;
        matchOk    <= 1'b1;
        fps        <= 8'd15;
        wrEn       <= 1'b0;
        wrAddr     <= '0;
        wrData     <= '0;
        frameReady <= 1'b0;
        status     <= 2'd0;
    end else begin
        spiStart <= 1'b0;
        wrEn     <= 1'b0;
        if(swapAck) frameReady <= 1'b0;

        case(state)
        // ---------------- Liga o cartão ----------------
        S_POWER_OFF: begin
            sdReset <= 1'b1; csN <= 1'b1; spiSlow <= 1'b1;
            if(timer == 25'(T_POWER_OFF)) begin timer <= '0; state <= S_POWER_ON; end
            else timer <= timer + 1'b1;
        end
        S_POWER_ON: begin
            sdReset <= 1'b0;
            if(timer == 25'(T_POWER_ON)) begin timer <= '0; dummyCnt <= '0; state <= S_DUMMY; end
            else timer <= timer + 1'b1;
        end
        // 80 clocks com CS em 1: o cartão acorda
        S_DUMMY: begin
            if(dummyCnt == 4'd10) begin tries <= '0; state <= S_CMD0; end
            else begin dummyCnt <= dummyCnt + 1'b1; `XFER(8'hFF, S_DUMMY) end
        end

        // ---------------- Inicialização ----------------
        S_CMD0: `SD_CMD(0, 32'h0, 8'h95, S_CMD0_R)
        S_CMD0_R: begin
            if(r1 == 8'h01) begin gapRet <= S_CMD8; state <= S_GAP; end
            else if(tries == 20'd20) state <= S_ERROR;
            else begin tries <= tries + 1'b1; gapRet <= S_CMD0; state <= S_GAP; end
        end

        S_CMD8: `SD_CMD(8, 32'h0000_01AA, 8'h87, S_CMD8_R)
        S_CMD8_R: begin
            if(r1 == 8'h01) begin respRet <= S_CMD8_CHK; respCnt <= '0; state <= S_RESP4; end
            else if(r1[2]) begin v2Card <= 1'b0; tries <= '0; gapRet <= S_CMD55; state <= S_GAP; end // cartão antigo (v1)
            else state <= S_ERROR;
        end
        S_CMD8_CHK: begin
            if(resp[11:0] == 12'h1AA) begin v2Card <= 1'b1; tries <= '0; gapRet <= S_CMD55; state <= S_GAP; end
            else state <= S_ERROR;
        end

        // ACMD41 = CMD55 + CMD41, repetido até o cartão dizer que terminou de inicializar (R1 = 0)
        S_CMD55: `SD_CMD(55, 32'h0, 8'h65, S_CMD55_R)
        S_CMD55_R: begin
            if(r1[7:1] == 7'd0) begin gapRet <= S_ACMD41; state <= S_GAP; end
            else state <= S_ERROR;
        end
        S_ACMD41: `SD_CMD(41, (v2Card ? 32'h4000_0000 : 32'h0), 8'h77, S_ACMD41_R)
        S_ACMD41_R: begin
            if(r1 == 8'h00) begin
                gapRet <= v2Card ? S_CMD58 : S_CMD16;
                ccs    <= 1'b0;
                state  <= S_GAP;
            end else if(r1 == 8'h01 && tries != 20'(ACMD41_TRIES)) begin
                tries <= tries + 1'b1; gapRet <= S_CMD55; state <= S_GAP;
            end else state <= S_ERROR;
        end

        // CMD58: lê o OCR para saber se é SDHC (bit 30 = CCS)
        S_CMD58: `SD_CMD(58, 32'h0, 8'hFD, S_CMD58_R)
        S_CMD58_R: begin
            if(r1 == 8'h00) begin respRet <= S_CMD58_CHK; respCnt <= '0; state <= S_RESP4; end
            else state <= S_ERROR;
        end
        S_CMD58_CHK: begin
            ccs    <= resp[30];
            gapRet <= resp[30] ? S_READ_START : S_CMD16;
            state  <= S_GAP;
        end

        // Cartão SDSC: garante bloco de 512 bytes
        S_CMD16: `SD_CMD(16, 32'd512, 8'h15, S_CMD16_R)
        S_CMD16_R: begin
            if(r1 == 8'h00) begin gapRet <= S_READ_START; state <= S_GAP; end
            else state <= S_ERROR;
        end

        // ---------------- Leitura contínua (CMD18) ----------------
        S_READ_START: begin
            spiSlow <= 1'b0; // daqui para frente: 12,5 MHz
            if(searching) status <= 2'd1;
            `SD_CMD(18, readArg, 8'hFF, S_READ_R)
        end
        S_READ_R: begin
            if(r1 == 8'h00) state <= S_GATE; // CS continua em 0 enquanto os blocos chegam
            else state <= S_ERROR;
        end

        // Antes de começar um quadro novo, espera o quadro anterior ir para a tela
        S_GATE: begin
            if(!searching && blkInFrame == 8'd0 && frameReady) state <= S_GATE;
            else begin tries <= '0; state <= S_TOKEN; end
        end
        S_TOKEN: `XFER(8'hFF, S_TOKEN_CHK)
        S_TOKEN_CHK: begin
            if(spiRx == 8'hFE) begin byteCnt <= '0; matchOk <= 1'b1; state <= S_DATA; end
            else if(spiRx == 8'hFF && tries != 20'(TOKEN_TRIES)) begin tries <= tries + 1'b1; state <= S_TOKEN; end
            else state <= S_ERROR; // token de erro (ex.: passou do fim do cartão) ou demorou demais
        end
        S_DATA: `XFER(8'hFF, S_DATA_GOT)
        S_DATA_GOT: begin
            if(searching) begin
                if(byteCnt < 10'd32 && spiRx != magicByte) matchOk <= 1'b0;
                case(byteCnt)
                    10'd36: nFrames[7:0]   <= spiRx;
                    10'd37: nFrames[15:8]  <= spiRx;
                    10'd38: nFrames[23:16] <= spiRx;
                    10'd39: nFrames[31:24] <= spiRx;
                    default: ;
                endcase
            end else begin
                wrEn   <= 1'b1;
                wrData <= spiRx;
                wrAddr <= 17'(blkInFrame) * 17'd512 + 17'(byteCnt);
            end
            if(searching && byteCnt == 10'd42) fps <= (spiRx == 8'd0) ? 8'd15 : spiRx;
            if(byteCnt == 10'd511) begin crcCnt <= 1'b0; state <= S_CRC; end
            else begin byteCnt <= byteCnt + 1'b1; `XFER(8'hFF, S_DATA_GOT) end // já pede o próximo byte
        end
        S_CRC: begin // 2 bytes de CRC, ignorados
            if(crcCnt) `XFER(8'hFF, S_BLOCK_END)
            else begin crcCnt <= 1'b1; `XFER(8'hFF, S_CRC) end
        end
        S_BLOCK_END: begin
            sector <= sector + 1'b1;
            if(searching) begin
                if(matchOk && nFrames != 32'd0) begin
                    // achou o cabeçalho: os quadros começam no próximo setor, que já está vindo
                    searching  <= 1'b0;
                    status     <= 2'd2;
                    firstFrame <= sector + 1'b1;
                    frameIdx   <= '0;
                    blkInFrame <= '0;
                    state      <= S_GATE;
                end else if(sector == 32'(SEARCH_LIMIT - 1)) state <= S_ERROR;
                else state <= S_GATE;
            end else if(blkInFrame == 8'(BLOCKS_PER_FRAME - 1)) begin
                // quadro completo
                blkInFrame <= '0;
                frameReady <= 1'b1;
                if(frameIdx == nFrames - 1'b1) begin
                    frameIdx <= '0;
                    state    <= S_STOP; // fim do vídeo: volta para o primeiro quadro
                end else begin
                    frameIdx <= frameIdx + 1'b1;
                    state    <= S_GATE;
                end
            end else begin
                blkInFrame <= blkInFrame + 1'b1;
                state      <= S_GATE;
            end
        end

        // CMD12 para a leitura contínua; depois recomeça no primeiro quadro
        S_STOP: begin
            `SD_CMD(12, 32'h0, 8'h61, S_STOP_R)
            skipFirst <= 1'b1;
        end
        S_STOP_R: begin
            if(r1[7]) state <= S_ERROR;
            else begin tries <= '0; state <= S_STOP_BUSY; end
        end
        S_STOP_BUSY: `XFER(8'hFF, S_STOP_BUSY_CHK)
        S_STOP_BUSY_CHK: begin // depois do CMD12 o cartão segura MISO em 0 enquanto está ocupado
            if(spiRx != 8'h00) begin sector <= firstFrame; gapRet <= S_READ_START; state <= S_GAP; end
            else if(tries == 20'(TOKEN_TRIES)) state <= S_ERROR;
            else begin tries <= tries + 1'b1; state <= S_STOP_BUSY; end
        end

        // ---------------- Sub-rotinas ----------------
        S_XFER_WAIT: if(spiDone) state <= xferRet;

        S_CMD_SEND: `XFER(cmdBuf[47:40], S_CMD_NEXT)
        S_CMD_NEXT: begin
            cmdBuf <= {cmdBuf[39:0], 8'hFF};
            if(cmdCnt == 3'd5) begin pollCnt <= '0; state <= S_CMD_R1; end
            else begin cmdCnt <= cmdCnt + 1'b1; state <= S_CMD_SEND; end
        end
        S_CMD_R1: `XFER(8'hFF, S_CMD_R1_CHK)
        S_CMD_R1_CHK: begin
            if(skipFirst) begin skipFirst <= 1'b0; state <= S_CMD_R1; end
            else if(!spiRx[7]) begin r1 <= spiRx; state <= cmdRet; end
            else if(pollCnt == 4'd15) begin r1 <= 8'hFF; state <= cmdRet; end // sem resposta
            else begin pollCnt <= pollCnt + 1'b1; state <= S_CMD_R1; end
        end

        // lê 4 bytes depois do R1 (R7 do CMD8, OCR do CMD58)
        S_RESP4: `XFER(8'hFF, S_RESP4_GOT)
        S_RESP4_GOT: begin
            resp <= {resp[23:0], spiRx};
            if(respCnt == 3'd3) state <= respRet;
            else begin respCnt <= respCnt + 1'b1; state <= S_RESP4; end
        end

        // fim de comando: CS em 1 e mais 8 clocks
        S_GAP: begin
            csN <= 1'b1;
            `XFER(8'hFF, S_GAP_DONE)
        end
        S_GAP_DONE: state <= gapRet;

        // ---------------- Erro: desliga, espera e tenta de novo ----------------
        S_ERROR: begin
            status     <= 2'd3;
            csN      <= 1'b1;
            sdReset    <= 1'b1;
            spiSlow    <= 1'b1;
            searching  <= 1'b1;
            sector     <= '0;
            nFrames    <= '0;
            blkInFrame <= '0;
            if(timer == 25'(T_RETRY)) begin timer <= '0; state <= S_POWER_OFF; end
            else timer <= timer + 1'b1;
        end

        default: state <= S_ERROR;
        endcase
    end
end

`undef SD_CMD
`undef XFER

endmodule

// sdCardModel: cartão SDHC simulado (modo SPI), SÓ PARA SIMULAÇÃO.
//
// Responde CMD0, CMD8, CMD55/ACMD41 (fica "ocupado" nas 3 primeiras vezes), CMD58 (SDHC),
// CMD18 (leitura contínua) e CMD12 (para a leitura, com byte de lixo, R1 e "busy").
//
// Conteúdo do "cartão":
//   setores 0 .. HDR-1 : lixo (como o FAT e as pastas do Android)
//   setor HDR          : cabeçalho AEL_HUD_VIDEO_V1 com NF quadros
//   setores seguintes  : NF quadros de 150 setores; pixel = pat(quadro, posição)
module sdCardModel #(
    parameter int HDR = 40,
    parameter int NF  = 3,
    parameter int FPS = 15
) (
    input  logic powerOff, // SD_RESET
    input  logic sclk,
    input  logic mosi,
    input  logic csN,
    output logic miso
);

function automatic logic [7:0] pat(input int f, input int off);
    return 8'((f * 37 + off + (off >> 8)) & 8'hFF);
endfunction

function automatic logic [7:0] sectorByte(input int s, input int i);
    logic [127:0] magic;
    int k, f, off;
    magic = "AEL_HUD_VIDEO_V1";
    if(s < HDR) return 8'((s * 13 + i * 7 + 5) & 8'hFF);
    if(s == HDR) begin
        if(i < 16)  return magic[127 - 8*i -: 8];
        if(i < 32)  return ~magic[127 - 8*(i-16) -: 8];
        if(i == 32) return 8'(320 & 8'hFF);
        if(i == 33) return 8'(320 >> 8);
        if(i == 34) return 8'd240;
        if(i == 36) return 8'(NF);
        if(i == 40) return 8'd150;
        if(i == 42) return 8'(FPS);
        if(i == 43) return 8'd1;
        return 8'h00;
    end
    k   = s - HDR - 1;
    f   = k / 150;
    off = (k % 150) * 512 + i;
    if(f < NF) return pat(f, off);
    return 8'h00;
endfunction

// ---------- fila de resposta ----------
logic [7:0] q [$];
int   bitCnt;
logic [7:0] inSh, outSh;
logic [7:0] cmd [0:5];
int   cmdIdx;
int   acmdTries;
bit   appCmd;

// leitura contínua
bit   streaming;
int   stSector, stPos; // stPos: 0..2 = espera (FF), 3 = token, 4..515 = dados, 516..517 = CRC

function automatic logic [7:0] streamByte();
    logic [7:0] b;
    if(stPos < 3)         b = 8'hFF;
    else if(stPos == 3)   b = 8'hFE;
    else if(stPos < 516)  b = sectorByte(stSector, stPos - 4);
    else                  b = 8'hA5; // CRC (ignorado)
    stPos++;
    if(stPos == 518) begin stPos = 0; stSector++; end
    return b;
endfunction

function automatic logic [7:0] nextOut();
    if(q.size() > 0) return q.pop_front();
    if(streaming)    return streamByte();
    return 8'hFF;
endfunction

task automatic execCmd();
    int idx;
    logic [31:0] arg;
    idx = cmd[0][5:0];
    arg = {cmd[1], cmd[2], cmd[3], cmd[4]};
    if(appCmd && idx == 41) begin
        appCmd = 0;
        q.push_back(8'hFF);
        if(acmdTries < 3) begin acmdTries++; q.push_back(8'h01); end
        else q.push_back(8'h00);
        return;
    end
    appCmd = 0;
    case(idx)
        0:  begin q.push_back(8'hFF); q.push_back(8'h01); end
        8:  begin
                if(cmd[5] != 8'h87) $error("CMD8 com CRC errado");
                q.push_back(8'hFF); q.push_back(8'h01);
                q.push_back(8'h00); q.push_back(8'h00); q.push_back(8'h01); q.push_back(8'hAA);
            end
        55: begin appCmd = 1; q.push_back(8'hFF); q.push_back(8'h01); end
        58: begin
                q.push_back(8'hFF); q.push_back(8'h00);
                q.push_back(8'hC0); q.push_back(8'hFF); q.push_back(8'h80); q.push_back(8'h00);
            end
        18: begin
                q.push_back(8'hFF); q.push_back(8'h00);
                streaming = 1; stSector = arg; stPos = 0;
                $display("[%0t] cartao: CMD18 a partir do setor %0d", $time, arg);
            end
        12: begin
                streaming = 0;
                q.delete();
                q.push_back(8'h5A); // byte de lixo (bit 7 = 0 de propósito: o leitor tem que pular)
                q.push_back(8'h00); // R1
                q.push_back(8'h00); q.push_back(8'h00); q.push_back(8'h00); // ocupado
                $display("[%0t] cartao: CMD12", $time);
            end
        default: begin q.push_back(8'hFF); q.push_back(8'h04); end // comando ilegal
    endcase
endtask

// recebe na subida
always @(posedge sclk or posedge csN or posedge powerOff) begin
    if(powerOff) begin
        q.delete(); bitCnt = 0; cmdIdx = -1; streaming = 0; acmdTries = 0; appCmd = 0;
    end else if(csN) begin
        bitCnt = 0;
    end else begin
        inSh = {inSh[6:0], mosi};
        bitCnt++;
        if(bitCnt == 8) begin
            bitCnt = 0;
            if(cmdIdx < 0 && inSh[7:6] == 2'b01) cmdIdx = 0;
            if(cmdIdx >= 0) begin
                cmd[cmdIdx] = inSh;
                cmdIdx++;
                if(cmdIdx == 6) begin cmdIdx = -1; execCmd(); end
            end
        end
    end
end

// envia na descida (o 1º bit de cada byte sai na descida que fecha o byte anterior)
always @(negedge sclk or posedge csN or posedge powerOff) begin
    if(powerOff || csN) begin
        miso  <= 1'b1;
        outSh <= 8'hFF;
    end else if(bitCnt == 0) begin
        logic [7:0] b;
        b = nextOut();
        miso  <= b[7];
        outSh <= {b[6:0], 1'b1};
    end else begin
        miso  <= outSh[7];
        outSh <= {outSh[6:0], 1'b1};
    end
end

initial begin
    cmdIdx = -1; bitCnt = 0; streaming = 0; acmdTries = 0; appCmd = 0; miso = 1'b1;
end

endmodule

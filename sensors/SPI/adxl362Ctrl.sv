`timescale 1ns / 1ps 
module adxl362Ctrl #(
    parameter int CLK_HZ = 25_000_000,       // frequência do 'clk' que entra (Hz)
    parameter int SCLK_HZ = 1_000_000,       // velocidade desejada do SPI (Hz)
    parameter int MS_TICKS = CLK_HZ / 1000   // ciclos de clk em 1 ms (25 MHz -> 25000)
)(
    input logic clk, // clock do projeto
    input logic rst_n, // reset; o "_n" quer dizer: ATIVO EM 0
    input logic acl_miso, // bits que o chip envia para a FPGA (pino E15)

    output logic acl_sclk, // clock do SPI (gerado pelo spiMaster)
    output logic acl_mosi, // bits que a FPGA envia ao chip (gerado pelo spiMaster)
    output logic acl_csn, 
    // Chip Select NEGADO (n = ativo em 0), gerado aqui:
    //   0 = "chip, estou falando com você"
    //   1 = "chip, pode ignorar os fios" (repouso)
    output logic signed [11:0] accelX,  // aceleração em X, Y, Z; 12 bits COM sinal (complemento de 2).
    output logic signed [11:0] accelY,
    output logic signed [11:0] accelZ,  
    output logic dataValid, // pulso de 1 ciclo: "X, Y e Z acabaram de atualizar"
    output logic idOk // 1 = o chip respondeu 0xAD (está lá e o SPI funciona)
);

localparam logic [7:0] CMD_WRITE = 8'h0A; // comando: ESCREVER registrador
localparam logic [7:0] CMD_READ = 8'h0B; // comando: LER registrador

localparam logic [7:0] REG_DEVID_AD = 8'h00; // endereço da página do "crachá" (ID)
localparam logic [7:0] DEVID_VALUE = 8'hAD; // valor do crachá (ID da Analog Devices)

localparam logic [7:0] REG_POWER_CTL = 8'h2D; // endereço da página que liga a medição
localparam logic [7:0] POWER_CTL_MEASURE = 8'h02;  // valor que coloca o chip em modo de medição

localparam logic [7:0] REG_XDATA_L = 8'h0E;  // endereço do 1º byte de dados (X, parte baixa)

localparam int T_POWERUP = 6 * MS_TICKS;  // após o reset: o chip leva ~5 ms para ficar pronto
localparam int T_GAP = 1 * MS_TICKS;  // pausa curta entre ler o ID e ligar a medição
localparam int T_MEASURE = 40 * MS_TICKS;  // após ligar a medição: 1º dado válido só depois 40 ms
localparam int T_PERIOD  = 10 * MS_TICKS;  // entre leituras: o chip gera 1 dado novo a cada 10 ms

// Tempo entre o CS mudar e o SCLK mexer (o chip exige um tempo mínimo, de ordem de 100 ns). Usamos meio período do SCLK, mas nunca menos que 4 ciclos.
localparam int HALF_SCLK = CLK_HZ / (2 * SCLK_HZ);   // meio período do SCLK, em ciclos de clk
localparam int CS_GUARD = (HALF_SCLK < 4) ? 4 : HALF_SCLK;   // 12 ciclos = 480 ns a 25 MHz / 1 MHz

//   São DOIS níveis, como uma receita:
//   trans_t = Qual conversa estamos fazendo (ler ID, ligar medição, ler dados)
//   state_t = Em qual estagio da conversa estamos (esperando, mandando byte, esperando byte, etc)

typedef enum logic [2:0] {
    S_DELAY, // 1) espera um tempo, com o CS em 1 (chip desligado)
    S_CS_SETUP, // 2) baixa o CS e espera uma folga antes do 1º byte
    S_BYTE_START, // 3) manda o spiMaster começar 1 byte
    S_BYTE_WAIT, // 4) espera o spiMaster terminar esse byte
    S_CS_HOLD, // 5) espera uma folga depois do último byte e sobe o CS
    S_FINISH // 6) olha o que chegou e decide a próxima conversa
} state_t;

typedef enum logic [1:0] {TR_DEVID, TR_POWER, TR_READ} trans_t;   // 3 conversas -> 2 bits
// TR_DEVID = ler o ID, TR_POWER = ligar a medição, TR_READ = ler X, Y e Z

state_t state; // registrador: passo atual
trans_t trans; // registrador: conversa atual
logic [31:0] timer; // registrador: contador de ciclos, reaproveitado por 3 estados de espera (S_DELAY, S_CS_SETUP, S_CS_HOLD)
logic [31:0] delayTarget; // registrador: quantos ciclos o S_DELAY deve esperar
logic [2:0] byteIdx; // registrador: número do byte em andamento (0 a 7)
logic [2:0] lastIdx; // fio: número do ÚLTIMO byte desta conversa (2 ou 7)
logic [7:0] rxBuf [0:7]; // registradores: 8 "caixinhas" de 1 byte para guardar o que o chip devolveu. rxBuf[i] = resposta recebida durante o byte i

// spiStart: registrador (pulso "comece").
// spiBusy: fio vindo do spiMaster, MAS NINGUÉM USA (pode ignorar).
// spiDone: fio vindo do spiMaster ("terminei o byte").
logic spiStart, spiBusy, spiDone;   
                                    
// spiTx: fio, o byte a enviar agora.  
// spiRx: fio, o byte que acabou de chegar do chip.
logic [7:0] spiTx, spiRx;          
                                    
// spiMaster cuida de CADA BIT (gera o SCLK, desloca bits no MOSI, lê o MISO)
// adxl362Ctrl cuida da CONVERSA (que bytes, em que ordem, quando esperar)
// Os fios sclk, mosi e miso passam direto pelo spiMaster. O CS NÃO passa por ele: é controlado aqui, porque precisa ficar em 0 durante TODOS os bytes da conversa.
spiMaster #(.CLK_HZ (CLK_HZ), .SCLK_HZ(SCLK_HZ)) u_spi (
    .clk(clk),
    .rst_n(rst_n),
    .start(spiStart), // entrada: pulso de 1 ciclo "troque 1 byte agora"
    .txByte(spiTx), // entrada: o byte a enviar
    .rxByte(spiRx), // saída: o byte recebido (vale quando done = 1)
    .busy(spiBusy), // saída: "ocupado" (não usada aqui)
    .done(spiDone), // saída: pulso de 1 ciclo "terminei o byte"
    .sclk(acl_sclk), // fio para o chip
    .mosi(acl_mosi), // fio para o chip
    .miso(acl_miso) // fio vindo do chip
);

// Os bytes de uma conversa são numerados a partir de 0:
// DEVID e POWER têm 3 bytes -> números 0, 1, 2 -> o último é o 2
// READ tem 8 bytes -> números 0 a 7   -> o último é o 7
// lastIdx serve para saber quando acabaram os bytes da conversa.
assign lastIdx = (trans == TR_READ) ? 3'd7 : 3'd2;

// Aqui ela funciona como uma TABELA que escolhe QUAL BYTE ENVIAR, conforme a conversa (trans) e o número do byte (byteIdx):
//   byteIdx |  TR_DEVID |  TR_POWER |  TR_READ
//      0    |   0B      |   0A      |   0B <- COMANDO
//      1    |   00      |   2D      |   0E <- ENDEREÇO
//      2    |   00      |   02      |   00 <- DADO (02 na escrita; dummy na leitura)
//    3 a 7  |    -      |    -      |   00 <- dummy (só existe na leitura)

always_comb begin
    case(byteIdx)
        3'd0: spiTx = (trans == TR_POWER) ? CMD_WRITE : CMD_READ;
        3'd1: spiTx = (trans == TR_POWER) ? REG_POWER_CTL : (trans == TR_DEVID) ? REG_DEVID_AD  : REG_XDATA_L;
        3'd2: spiTx = (trans == TR_POWER) ? POWER_CTL_MEASURE : 8'h00;
        default: spiTx = 8'h00; // bytes "dummy": o valor não importa; servem para gerar clock
    endcase
end

// always_ff = lógica COM memória, como um CADERNO: só escreve na borda do clock e lembra o que escreveu. 
// É o "cérebro": muda de passo, conta tempo guarda bytes e sobe/desce o CS.
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state <= S_DELAY; // começa esperando
        trans <= TR_DEVID; // 1ª conversa: ler o ID
        timer <= '0;
        delayTarget <= 32'(T_POWERUP); // espera 6 ms antes de falar com o chip
        byteIdx <= '0;
        acl_csn <= 1'b1; // CS em 1 = chip desligado
        spiStart <= 1'b0;
        dataValid <= 1'b0;
        idOk <= 1'b0;
        accelX <= '0;
        accelY <= '0;
        accelZ <= '0;
        for(int i = 0; i < 8; i++) rxBuf[i] <= '0; // limpa as 8 caixinhas
    end else begin
        // "Zeros padrão": por padrão estes dois sinais voltam a 0 a cada ciclo. Só ficam em 1 se algum estado abaixo os puser em 1 -> viram PULSOS de exatamente 1 ciclo.
        spiStart <= 1'b0;
        dataValid <= 1'b0;

        case(state)
            // Espera 'delayTarget' ciclos com o chip desligado (CS = 1).
            // Contar de 0 até delayTarget-1 dá exatamente delayTarget ciclos.
            S_DELAY: begin
                if(timer >= delayTarget - 1) begin
                    timer <= '0;
                    byteIdx <= '0; // a conversa começa no byte 0
                    acl_csn <= 1'b0; // CS desce: COMEÇA a conversa
                    state <= S_CS_SETUP;
                end else begin
                    timer <= timer + 1;
                end
            end

            // CS já está em 0. Espera um tempo antes de mexer no SCLK.
            S_CS_SETUP: begin
                if(timer >= 32'(CS_GUARD - 1)) begin
                    timer <= '0;
                    state <= S_BYTE_START;
                end else begin
                    timer <= timer + 1;
                end
            end

            // Dura 1 ciclo. spiStart sobe e, no ciclo seguinte, o "zero padrão" o derruba: é o pulso que o spiMaster precisa. Neste momento
            S_BYTE_START: begin
                spiStart <= 1'b1;
                state <= S_BYTE_WAIT;
            end

            // Não faz nada até o spiMaster avisar (spiDone = 1) que terminou o byte (~190 ciclos a 1 MHz). Quando avisa:
            //   - guarda o byte recebido na caixinha rxBuf[byteIdx]
            //   - se era o último byte da conversa -> vai para S_CS_HOLD
            //   - se não -> passa ao próximo byte (volta para S_BYTE_START)
            S_BYTE_WAIT: begin
                if(spiDone) begin
                    rxBuf[byteIdx] <= spiRx;
                    if(byteIdx == lastIdx) begin
                        timer <= '0;
                        state <= S_CS_HOLD;
                    end else begin
                        byteIdx <= byteIdx + 1'b1;
                        state <= S_BYTE_START;
                    end
                end
            end

            // Último byte já foi. Espera o tempo final e SÓ ENTÃO sobe o CS, encerrando a conversa.
            S_CS_HOLD: begin
                if(timer >= 32'(CS_GUARD - 1)) begin
                    timer <= '0;
                    acl_csn <= 1'b1;// CS sobe: FIM da conversa
                    state <= S_FINISH;
                end else begin
                    timer <= timer + 1;
                end
            end

            // Dura 1 ciclo. ATENÇÃO: aqui 'trans' ainda vale a conversa que ACABOU de terminar. 
            // O valor novo que gravamos em 'trans' vale para a PRÓXIMA conversa. Também escolhemos quanto esperar antes dela (delayTarget).
            S_FINISH: begin
                state <= S_DELAY;
                timer <= '0;
                case(trans)
                    // Terminou a leitura do ID: o 3º byte recebido (rxBuf[2]) deve ser 0xAD.
                    TR_DEVID: begin
                        idOk <= (rxBuf[2] == DEVID_VALUE);
                        if(rxBuf[2] == DEVID_VALUE) begin
                            trans <= TR_POWER; // chip está lá: ligar a medição
                            delayTarget <= 32'(T_GAP); // espera 1 ms
                        end else begin
                            trans <= TR_DEVID; // não respondeu 0xAD: tenta de novo
                            delayTarget <= 32'(T_PERIOD); // espera 10 ms
                        end
                    end

                    // Terminou de ligar a medição. O chip passa a medir sozinho.
                    TR_POWER: begin
                        trans <= TR_READ;
                        delayTarget <= 32'(T_MEASURE); // espera 40 ms até o 1º dado válido
                    end

                    // Terminou uma leitura de dados. Os 8 bytes recebidos são:
                    //   rxBuf[0], rxBuf[1] = lixo (chegaram durante comando e endereço)
                    //   rxBuf[2]=XL  rxBuf[3]=XH  rxBuf[4]=YL  rxBuf[5]=YH  rxBuf[6]=ZL  rxBuf[7]=ZH
                    // Cada eixo tem 12 bits: byte baixo (8 bits) + os 4 bits
                    // de baixo do byte alto. Os 4 bits de cima do byte alto
                    // são só cópia do sinal e são descartados.
                    default: begin
                        accelX <= {rxBuf[3][3:0], rxBuf[2]};
                        accelY <= {rxBuf[5][3:0], rxBuf[4]};
                        accelZ <= {rxBuf[7][3:0], rxBuf[6]};
                        dataValid <= 1'b1; // avisa: dados novos!
                        trans <= TR_READ; // continua lendo para sempre
                        delayTarget <= 32'(T_PERIOD); // espera 10 ms entre leituras
                    end
                endcase
            end
            // Segurança: se 'state' ficar com um valor inválido, volta ao início.
            default: state <= S_DELAY;
        endcase
    end
end
endmodule

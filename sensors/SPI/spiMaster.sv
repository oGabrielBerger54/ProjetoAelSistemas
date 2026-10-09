module spiMaster #(
    parameter int CLK_HZ = 25_000_000, // frequência do clk de entrada
    parameter int SCLK_HZ = 1_000_000 // frequência do SCLK
)(
    input logic clk,
    input logic rst_n,
    input logic start, 
    input logic [7:0] txByte,
    output logic [7:0] rxByte,
    output logic busy,
    output logic done,
    output logic sclk,
    output logic mosi,
    input logic miso
);

// Quantos ciclos de clk cabem em meio período de SCLK
localparam int HALF_RAW = CLK_HZ / (2 * SCLK_HZ);
// Quantos ciclos dura o meio periodo? Neste caso, 12!
localparam int HALF = (HALF_RAW < 4) ? 4 : HALF_RAW;
// numero de bits do contador divCnt
localparam int DIV_W = $clog2(HALF);


// Estados do SPI: Parado, SCLK baixo & SLCK alto
typedef enum logic [1:0] {IDLE, PHASE_LOW, PHASE_HIGH} state_t;
state_t state;

// Contador de ciclos dentro do meio período do clk, comecando em Zero.
logic [DIV_W-1:0] divCnt;

// Qual dos oito bits do byte está sendo transmitido/recebido
logic [2:0] bitCnt;

// Copia do byte ao enviar, vai sendo deslocado a esquerda a cada bit transmitido. O bit mais significativo é enviado primeiro.
logic [7:0] txShift;

// Byte sendo montado, bits novos entram pela direita. O bit mais significativo é recebido primeiro.
logic [7:0] rxShift;

// Nivel logico alto quando o meio periodo acabou
logic halfDone;

// Sinais de fora da FPGA, que 
logic misoMeta, misoSync;
always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        misoMeta <= 1'b0;
        misoSync <= 1'b0;
    end else begin
        misoMeta <= miso;
        misoSync <= misoMeta;
    end
end

assign halfDone = (divCnt == DIV_W'(HALF - 1));

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state   <= IDLE;
        divCnt  <= '0;
        bitCnt  <= '0;
        txShift <= '0;
        rxShift <= '0;
        rxByte  <= '0;
        sclk    <= 1'b0;
        mosi    <= 1'b0;
        busy    <= 1'b0;
        done    <= 1'b0;
    end else begin
        done <= 1'b0;
        case(state)
            IDLE: begin
                sclk <= 1'b0;
                if(start) begin
                    txShift <= txByte;
                    mosi <= txByte[7];
                    bitCnt <= '0;
                    divCnt <= '0;
                    busy <= 1'b1;
                    state <= PHASE_LOW;
                end
            end
            PHASE_LOW: begin // Le o o bit do MISO na borda de subida do SCLK
                if(halfDone) begin
                    divCnt  <= '0;
                    sclk    <= 1'b1; // borda de subida na troca para o proximo estado
                    rxShift <= {rxShift[6:0], misoSync};
                    state   <= PHASE_HIGH;
                end else begin
                    divCnt <= divCnt + 1'b1; // ganha tempo pro misoSync estabilizar
                end
            end
            PHASE_HIGH: begin
                if(halfDone) begin
                    divCnt <= '0;
                    sclk   <= 1'b0; // borda de descida na troca para o proximo estado
                    if(bitCnt == 3'd7) begin // ultimo bit recebido
                        rxByte <= rxShift; // 8 bits completos
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= IDLE;
                    end else begin // troca de MOSI e incremento do contador de bits
                        bitCnt <= bitCnt + 1'b1;
                        txShift <= {txShift[6:0], 1'b0}; // desloca o byte a esquerda (na proxima borda)
                        mosi <= txShift[6];
                        state <= PHASE_LOW;
                    end
                end else begin
                    divCnt <= divCnt + 1'b1; // ganha tempo pro misoSync estabilizar
                end
            end
            default: state <= IDLE;
        endcase
    end
end
endmodule

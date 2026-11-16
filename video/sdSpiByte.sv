// sdSpiByte: troca 1 byte com o cartão SD no modo SPI (modo 0: SCLK parado em 0,
// o cartão lê MOSI na subida e o FPGA lê MISO na subida; MOSI muda na descida).
//
// Uso: põe o byte em txByte e dá um pulso em start (só quando busy = 0).
// Quando terminar, done fica em 1 por 1 ciclo e rxByte tem o byte que chegou do cartão.
//
// slow = 1 -> SCLK = clk / (2 * SLOW_HALF)  (na inicialização o cartão exige <= 400 kHz)
// slow = 0 -> SCLK = clk / 2                 (com clk25: 12,5 MHz)
module sdSpiByte #(
    parameter int SLOW_HALF = 32 // 25 MHz / 64 = ~390 kHz
) (
    input  logic       clk,
    input  logic       rstN,
    input  logic       slow,
    input  logic       start,
    input  logic [7:0] txByte,
    output logic [7:0] rxByte,
    output logic       busy,
    output logic       done,

    output logic       sclk,
    output logic       mosi,
    input  logic       miso
);

logic [7:0] txSh, rxSh;
logic [2:0] bitCnt;
logic [5:0] divCnt;
logic [5:0] halfMax;

assign halfMax = slow ? 6'(SLOW_HALF - 1) : 6'd0;

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        busy   <= 1'b0;
        done   <= 1'b0;
        sclk   <= 1'b0;
        mosi   <= 1'b1;
        txSh   <= 8'hFF;
        rxSh   <= 8'h00;
        rxByte <= 8'h00;
        bitCnt <= '0;
        divCnt <= '0;
    end else begin
        done <= 1'b0;
        if(!busy) begin
            if(start) begin
                busy   <= 1'b1;
                txSh   <= txByte;
                mosi   <= txByte[7]; // primeiro bit já fica pronto antes da 1ª subida
                bitCnt <= '0;
                divCnt <= '0;
                sclk   <= 1'b0;
            end
        end else if(divCnt != halfMax) begin
            divCnt <= divCnt + 1'b1;
        end else begin
            divCnt <= '0;
            if(!sclk) begin
                // subida: o cartão lê MOSI, nós lemos MISO
                sclk <= 1'b1;
                rxSh <= {rxSh[6:0], miso};
            end else begin
                // descida: próximo bit, ou fim do byte
                sclk <= 1'b0;
                if(bitCnt == 3'd7) begin
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    rxByte <= rxSh;
                    mosi   <= 1'b1; // linha em 1 quando parada
                end else begin
                    bitCnt <= bitCnt + 1'b1;
                    txSh   <= {txSh[6:0], 1'b1};
                    mosi   <= txSh[6];
                end
            end
        end
    end
end

endmodule

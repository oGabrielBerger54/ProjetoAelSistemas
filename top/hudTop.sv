module hudTop (
    input  logic clock,
    input  logic reset,

    // Switch de modo: SW[0] = 1 -> horizonte segue o acelerômetro / SW[0] = 0 -> horizonte fixo (neutro)
    input logic SW0,
    // Switch da bússola: SW[1] = 1 -> o ângulo da bússola segue os empurrões na placa / SW[1] = 0 -> bússola desligada (ângulo parado em 0)
    input logic SW1,

    // Acelerômetro ADXL362 (SPI)
    input logic ACL_MISO,
    output logic ACL_MOSI,
    output logic ACL_SCLK,
    output logic ACL_CSN,
    
    // LED[0] aceso = acelerômetro respondeu
    output logic LED0,

    output logic VGAHS,
    output logic VGAVS,
    output logic [3:0] VGAR,
    output logic [3:0] VGAG,
    output logic [3:0] VGAB
);

logic [1:0] clkDiv = 2'b00;
logic clk25;

always_ff @(posedge clock) begin
    clkDiv <= clkDiv + 1'b1;
end

assign clk25 = clkDiv[1];

// Reset: o botão é assíncrono; entra assíncrono e sai sincronizado com clk25
logic [1:0] rstSync;
logic rstN;

always_ff @(posedge clk25 or posedge reset) begin
    if(reset) rstSync <= 2'b00;
    else rstSync <= {rstSync[0], 1'b1};
end

assign rstN = rstSync[1];

logic activeVideo;
logic unsigned [9:0] pxJ, pxI;

vgaTiming vgaTiming (
    .clk(clk25),
    .rstN(rstN),
    .hsync(VGAHS),
    .vsync(VGAVS),
    .activeVideo(activeVideo),
    .pxJ(pxJ),
    .pxI(pxI)
);

logic unsigned [9:0] x, y;
logic validPixel;

coordGen coordGen (
    .activeVideo(activeVideo),
    .pxJ(pxJ),
    .pxI(pxI),
    .x(x),
    .y(y),
    .validPixel(validPixel)
);

logic signed [11:0] accelX, accelY;
logic aclValid, aclIdOk;

adxl362Ctrl #(
    .CLK_HZ (25_000_000),
    .SCLK_HZ(1_000_000)
) adxl362Ctrl (
    .clk (clk25),
    .rst_n (rstN),
    .acl_sclk (ACL_SCLK),
    .acl_mosi (ACL_MOSI),
    .acl_csn (ACL_CSN),
    .acl_miso (ACL_MISO),
    .accelX (accelX),
    .accelY (accelY),
    .accelZ(),
    .dataValid(aclValid),
    .idOk (aclIdOk)
);

assign LED0 = aclIdOk;

logic signed [8:0] accelVerticalDelta;
logic signed [9:0] accelHorizontalDelta;

// Ajuste SWAP_XY / INVERT_V / INVERT_H depois de testar inclinando a placa
accelToHorizon #(
    .SWAP_XY (1'b1),
    .INVERT_V(1'b0),
    .INVERT_H(1'b0)
) accelToHorizon (
    .clk(clk25),
    .rst_n(rstN),
    .accelX(accelX),
    .accelY(accelY),
    .accelValid(aclValid),
    .horizonVerticalDelta(accelVerticalDelta),
    .horizonHorizontalDelta(accelHorizontalDelta)
);

// Sinais de controle de voo independentes
logic signed [8:0] horizonVerticalDelta;
logic signed [9:0] horizonHorizontalDelta;

// SW0 vem de um switch (assíncrono), mas o horizonGen só usa o valor no fim do quadro, uma eventual metaestabilidade afeta no máximo 1 quadro.
assign horizonVerticalDelta = SW0 ? accelVerticalDelta : 9'sd0;
assign horizonHorizontalDelta = SW0 ? accelHorizontalDelta : 10'sd0;

// SW1 vem de um switch (assíncrono): passa por 2 flip-flops antes de ser usado.
// Quando SW1 = 0, o accelToCompass fica em reset: ângulo em 0. Quando SW1 sobe, ele ignora empurrões por ~1,2 s e depois começa a contar.
logic [1:0] sw1Sync;
logic compassRstN;

always_ff @(posedge clk25 or negedge rstN) begin
    if(!rstN) begin
        sw1Sync <= 2'b00;
        compassRstN <= 1'b0;
    end else begin
        sw1Sync <= {sw1Sync[0], SW1};
        compassRstN <= sw1Sync[1];
    end
end

logic [8:0] compassHeading;
logic [3:0] compassFrac;

// SWAP_XY igual ao do accelToHorizon. Se empurrar para a direita DIMINUIR o ângulo, ponha INVERT em 1'b1.
accelToCompass #(
    .SWAP_XY(1'b1),
    .INVERT (1'b0)
) accelToCompass (
    .clk(clk25),
    .rst_n(compassRstN),
    .accelX(accelX),
    .accelY(accelY),
    .accelValid(aclValid),
    .compassHeading(compassHeading),
    .compassFrac(compassFrac)
);

logic drawReticle;
logic drawHorizon;

reticleGen reticleGen (
    .x(x),
    .y(y),
    .validPixel(validPixel),
    .drawReticle(drawReticle)
);

horizonGen horizonGen (
    .clk(clk25),
    .rstN(rstN),
    .x(x),
    .y(y),
    .horizonVerticalDelta(horizonVerticalDelta),
    .horizonHorizontalDelta(horizonHorizontalDelta),
    .validPixel(validPixel),
    .drawHorizon(drawHorizon)
);

parameter [3:0] BGR = 4'h4;
parameter [3:0] BGG = 4'h6;
parameter [3:0] BGB = 4'h9;

always_comb begin
    if(validPixel) begin
        if(drawReticle || drawHorizon) begin
            VGAR = 4'h0;
            VGAG = 4'hF;
            VGAB = 4'h0;
        end else begin
            VGAR = BGR;
            VGAG = BGG;
            VGAB = BGB;
        end
    end else begin
        VGAR = 4'h0;
        VGAG = 4'h0;
        VGAB = 4'h0;
    end
end
endmodule

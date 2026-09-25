module hudTop (
    input  logic clock,
    input  logic reset,

    output logic VGAHS,
    output logic VGAVS,
    output logic [3:0] VGAR,
    output logic [3:0] VGAG,
    output logic [3:0] VGAB
);

logic [1:0] clkDiv;
logic clk25;
logic rstN;

assign rstN = ~reset;

always_ff @(posedge clock) begin
    clkDiv <= clkDiv + 1'b1;
end

assign clk25 = clkDiv[1];

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

logic drawReticle;

reticleGen reticleGen (
    .x(x),
    .y(y),
    .validPixel(validPixel),
    .drawReticle(drawReticle)
);

parameter [3:0] BGR = 4'h4;
parameter [3:0] BGG = 4'h6;
parameter [3:0] BGB = 4'h9;

always_comb begin
    if(validPixel) begin
        if(drawReticle) begin
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

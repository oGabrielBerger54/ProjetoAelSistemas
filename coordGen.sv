module coordGen (
    input logic activeVideo,
    input logic unsigned [9:0] pxJ,
    input logic unsigned [9:0] pxI,
    
    output logic unsigned [9:0] x,
    output logic unsigned [9:0] y,
    output logic validPixel
);

always_comb begin
    validPixel = activeVideo;
    if(activeVideo == 1) begin
        x = pxJ;
        y = pxI;
    end 
    else begin
        x = '0;
        y = '0;
    end
end
endmodule

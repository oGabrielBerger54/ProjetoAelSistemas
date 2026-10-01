module altGen (
    input  logic unsigned [9:0] x,
    input  logic unsigned [9:0] y,
    input  logic signed [11:0] altOffset,
    input  logic validPixel,
    output logic drawAlt
);

parameter CX = 320;
parameter CY = 240;

parameter TAPE_X = 120; // Posição horizontal da fita de altitude na tela

// Intervalo de exibição vertical da fita de altitude
logic inInterval;
assign inInterval = (y >= CY - 160) && (y <= CY + 160);

// Posição Y que sofre deslocamento horizontal pela altitude
logic [11:0] altOffsetLevel;
assign altOffsetLevel = y + altOffset;

// Identificação das marcações da fita
logic isMajorTick;
logic isMinorTick;
assign isMajorTick = (altOffsetLevel % 32 == 0); // a cada 32 bits, há uma marcação maior
assign isMinorTick = (altOffsetLevel % 16 == 0); // a cada 16 bits, há uma marcação menor

// Sinais de controle de desenho padronizados
logic drawTapeLine;
logic drawTapeTicks;
logic drawTapePointer;

always_comb begin 
    drawTapeLine = (x == TAPE_X) || (x == TAPE_X + 1); // Duas linhas de grossura
    
    drawTapeTicks = (x <= TAPE_X) && ((isMajorTick && (x >= TAPE_X - 16)) || (isMinorTick && (x >= TAPE_X - 8)));
    
    drawTapePointer = (x >= TAPE_X + 4) && (x <= TAPE_X + 16) && (y >= CY - (x - (TAPE_X + 4))) && (y <= CY + (x - (TAPE_X + 4)));

    if (validPixel && ((inInterval && (drawTapeLine || drawTapeTicks)) || drawTapePointer)) begin
        drawAlt = 1;
    end else begin
        drawAlt = 0;
    end
end

endmodule


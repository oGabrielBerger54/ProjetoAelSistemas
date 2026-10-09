module vgaTiming (
    input  logic clk,
    input  logic rstN,
    output logic hsync,
    output logic vsync,
    output logic activeVideo,
    output logic unsigned [9:0] pxJ,
    output logic unsigned [9:0] pxI
);

// PADRÃO VGA: 640x480 a 60Hz (clock de 25MHz)
// http://microvga.com/vga-timing/640x480@60Hz

// Pixels visíveis na horizontal
parameter H_DISPLAY = 640;

// Tempo de espera (tela preta) antes de puxar o feixe (VESA DMT)
parameter H_FRONT = 16;

// Tempo que o feixe leva sendo puxado para a esquerda (VESA DMT)
parameter H_SYNC = 96;  

// Total de ciclos gastos em uma linha inteira (640+16+96+48)
parameter H_TOTAL = 800; 

// Linhas visíveis na vertical 
parameter V_DISPLAY = 480;

// Linhas de espera (tela preta) antes de subir o feixe (VESA DMT)
parameter V_FRONT = 10;

// Tempo que o feixe leva sendo puxado para o topo (VESA DMT)
parameter V_SYNC = 2;

// Total de linhas percorridas para desenhar uma tela (480+10+2+33)
parameter V_TOTAL = 525;

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        // caso o reset seja desativado, reinicia os contadores de pixel
        pxJ <= '0;
        pxI <= '0;
    end 
    else begin
        // No caso de estarmos no último pixel da linha, reinicia o contador horizontal
        if(pxJ == H_TOTAL - 1) begin
            pxJ <= '0;
            // No caso de estarmos no último pixel da tela, reinicia o contador vertical
            if(pxI == V_TOTAL - 1) begin
                pxI <= '0;
            end else begin
                // Caso contrário, incrementa o contador vertical
                pxI <= pxI + 1;
            end
        end 
        else begin
            // Caso contrário, incrementa o contador horizontal
            pxJ <= pxJ + 1;
        end
    end
end

always_comb begin
    // Caso o contador horizontal esteja entre o final da tela visível e o final do tempo de sincronização, o sinal de sincronização horizontal é ativado
    hsync = ~((pxJ >= H_DISPLAY + H_FRONT) && (pxJ < H_DISPLAY + H_FRONT + H_SYNC));
    
    // Caso o contador vertical esteja entre o final da tela visível e o final do tempo de sincronização, o sinal de sincronização vertical é ativado
    vsync = ~((pxI >= V_DISPLAY + V_FRONT) && (pxI < V_DISPLAY + V_FRONT + V_SYNC));

    // Caso o contador horizontal e vertical estejam dentro da tela visível, o sinal de vídeo ativo é ativado
    activeVideo = (pxJ < H_DISPLAY) && (pxI < V_DISPLAY);
end

endmodule

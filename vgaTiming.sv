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
parameter HDISPLAY = 640;

// Tempo de espera (tela preta) antes de puxar o feixe (VESA DMT)
parameter HFRONT = 16;

// Tempo que o feixe leva sendo puxado para a esquerda (VESA DMT)
parameter HSYNC = 96;  

// Tempo de estabilização antes de começar a próxima linha (VESA DMT)
parameter HBACK = 48;

// Total de ciclos gastos em uma linha inteira (640+16+96+48)
parameter HTOTAL = 800; 

// Linhas visíveis na vertical 
parameter VDISPLAY = 480;

// Linhas de espera (tela preta) antes de subir o feixe (VESA DMT)
parameter VFRONT = 10;

// Tempo que o feixe leva sendo puxado para o topo (VESA DMT)
parameter VSYNC = 2;

// Tempo de estabilização no topo (VESA DMT)
parameter VBACK = 33; 

// Total de linhas percorridas para desenhar uma tela (480+10+2+33)
parameter VTOTAL = 525;

always_ff @(posedge clk or negedge rstN) begin
    if(!rstN) begin
        // caso o reset seja desativado, reinicia os contadores de pixel
        pxJ <= '0;
        pxI <= '0;
    end 
    else begin
        // no caso de estarmos no último pixel da linha, reinicia o contador horizontal
        if(pxJ == HTOTAL - 1) begin
            pxJ <= '0;
            // no caso de estarmos no último pixel da tela, reinicia o contador vertical
            if(pxI == VTOTAL - 1) begin
                pxI <= '0;
            end else begin
                // caso contrário, incrementa o contador vertical
                pxI <= pxI + 1;
            end
        end 
        else begin
            // caso contrário, incrementa o contador horizontal
            pxJ <= pxJ + 1;
        end
    end
end

always_comb begin
    // caso o contador horizontal esteja entre o final da tela visível e o final do tempo de sincronização, o sinal de sincronização horizontal é ativado
    hsync = ~((pxJ >= HDISPLAY + HFRONT) && (pxJ < HDISPLAY + HFRONT + HSYNC));
    
    // caso o contador vertical esteja entre o final da tela visível e o final do tempo de sincronização, o sinal de sincronização vertical é ativado
    vsync = ~((pxI >= VDISPLAY + VFRONT) && (pxI < VDISPLAY + VFRONT + VSYNC));

    // caso o contador horizontal e vertical estejam dentro da tela visível, o sinal de vídeo ativo é ativado
    activeVideo = (pxJ < HDISPLAY) && (pxI < VDISPLAY);
end

endmodule


`timescale 1ns / 1ps

// O QUE ESTE MÓDULO FAZ
//  Divisão de números inteiros SEM SINAL, feita aos pouquinhos: 1 bit do resultado por ciclo de clock.
//  Com N = 34 bits ela leva 34 ciclos (a 25 MHz, uns 1,4 microssegundos). Para o altímetro isso é de sobra,
//  porque chega uma leitura nova só a cada ~100 ms.
//  Por que não usar o "/" direto? Porque um "/" de 34 bits feito num ciclo só é lento demais para o clock e daria erro de timing.
//
// COMO USAR
//  1) Ponha o dividendo em "num" e o divisor em "den".
//  2) Dê um pulso de 1 ciclo em "start" (com "busy" em 0).
//  3) Espere o pulso de 1 ciclo em "done". Nesse ciclo "quo" tem o resultado (quociente, arredondado para baixo).
//  Se "den" for 0 o resultado é lixo (tudo 1), mas o módulo termina do mesmo jeito e não trava.
//
// COMO FUNCIONA (divisão "de papel", em binário)
//  Vai puxando os bits do dividendo, da esquerda para a direita, para dentro do "resto".
//  Se o resto já é maior ou igual ao divisor, subtrai o divisor e o bit do quociente é 1. Senão, o bit é 0.

module seqDiv #(
    parameter int N = 34 // largura do dividendo, do divisor e do quociente, em bits
)(
    input logic clk,
    input logic rst_n, // ativo em 0
    input logic start, // pulso de 1 ciclo: começa uma divisão
    input logic [N-1:0] num, // dividendo
    input logic [N-1:0] den, // divisor
    output logic [N-1:0] quo, // quociente (vale quando "done" = 1)
    output logic busy, // 1 enquanto está dividindo
    output logic done // pulso de 1 ciclo: terminou
);

logic [N:0] rem; // resto parcial
logic [N-1:0] q; // começa com o dividendo e vai sendo trocado, bit a bit, pelo quociente
logic [N-1:0] d; // divisor guardado
logic [7:0] cnt; // quantos bits faltam

logic [N:0] remShift; // resto já com o próximo bit do dividendo puxado para dentro
assign remShift = {rem[N-1:0], q[N-1]};

always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rem <= '0;
        q <= '0;
        d <= '0;
        cnt <= '0;
        busy <= 1'b0;
        done <= 1'b0;
    end else begin
        done <= 1'b0;

        if(start && !busy) begin
            rem <= '0;
            q <= num;
            d <= den;
            cnt <= 8'(N);
            busy <= 1'b1;
        end else if(busy) begin
            if(remShift >= {1'b0, d}) begin
                rem <= remShift - {1'b0, d};
                q <= {q[N-2:0], 1'b1};
            end else begin
                rem <= remShift;
                q <= {q[N-2:0], 1'b0};
            end

            cnt <= cnt - 1'b1;
            if(cnt == 8'd1) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
end

assign quo = q;

endmodule

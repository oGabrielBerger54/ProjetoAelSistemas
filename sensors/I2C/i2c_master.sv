// Mestre I2C
// f_SCL = f_clk / (4*CLK_DIV)

module i2c_master import i2c_pkg::*; #(
  parameter int CLK_DIV = 63 // >= 2
)(
  input  logic       clk, rst,
  input  logic       cmd_valid,
  output logic       cmd_ready,
  input  cmd_e       cmd_type,
  input  logic [7:0] cmd_data, // WRITE: byte a enviar
  input  logic       cmd_last, // READ: 1 = envia NACK (ultimo byte)
  output logic       done, // pulso ao terminar o comando
  output logic [7:0] rdata, // READ: byte lido
  output logic       nack, // WRITE: 1 = escravo NAO deu ACK
  inout  wire        scl, sda
);
  typedef enum logic [1:0] {S_IDLE, S_START, S_STOP, S_BYTE} state_e;
  state_e st;

  logic [1:0] ph; // fase (1/4 de periodo de SCL)
  logic [3:0] bitn; // 0..7 dados, 8 = ACK
  logic [7:0] sh;
  logic       rd, nack_in;
  logic       scl_low, sda_low; // 1 = puxa a linha para 0
  logic [$clog2(CLK_DIV)-1:0] cnt;
  logic [1:0] scl_s, sda_s; // sincronizadores

  assign scl = scl_low ? 1'b0 : 1'bz;
  assign sda = sda_low ? 1'b0 : 1'bz;

  wire scl_i   = scl_s[1];
  wire sda_i   = sda_s[1];
  wire tick    = (cnt == CLK_DIV-1);
  wire stretch = (ph == 2'd2) && !scl_i; // escravo segurando SCL

  assign cmd_ready = (st == S_IDLE);
  assign rdata     = sh;

  always_ff @(posedge clk) begin
    scl_s <= {scl_s[0], scl};
    sda_s <= {sda_s[0], sda};
    done  <= 1'b0;
    cnt   <= tick ? '0 : cnt + 1'b1;

    if (rst) begin
      st       <= S_IDLE;
      scl_low  <= 1'b0;
      sda_low  <= 1'b0;
      ph       <= '0;
      bitn     <= '0;
      cnt      <= '0;
      nack     <= 1'b0;
      rd       <= 1'b0;
      nack_in  <= 1'b0;
      sh       <= 8'h00;
      scl_s    <= 2'b11;
      sda_s    <= 2'b11;
    end else case (st)

      S_IDLE: if (cmd_valid) begin
        ph <= '0; bitn <= '0;
        sh <= cmd_data; rd <= (cmd_type == CMD_READ); nack_in <= cmd_last;
        case (cmd_type)
          CMD_START: st <= S_START;
          CMD_STOP:  st <= S_STOP;
          default:   st <= S_BYTE;
        endcase
      end

      // START
      S_START: if (tick && !stretch) begin
        ph <= ph + 1'b1;
        case (ph)
          2'd0: sda_low <= 1'b0; // solta SDA
          2'd1: scl_low <= 1'b0; // solta SCL
          2'd2: sda_low <= 1'b1; // SDA cai com SCL alto = START
          2'd3: begin scl_low <= 1'b1; st <= S_IDLE; done <= 1'b1; end
        endcase
      end

      // STOP
      S_STOP: if (tick && !stretch) begin
        ph <= ph + 1'b1;
        case (ph)
          2'd0: sda_low <= 1'b1;
          2'd1: scl_low <= 1'b0;
          2'd3: begin sda_low <= 1'b0; st <= S_IDLE; done <= 1'b1; end  // SDA sobe com SCL alto
          default: ;
        endcase
      end

      // 8 bits de dados + 1 bit de ACK
      S_BYTE: if (tick && !stretch) begin
        ph <= ph + 1'b1;
        case (ph)
          2'd0: begin
            scl_low <= 1'b1;
            if (bitn < 8) sda_low <= rd ? 1'b0 : ~sh[7];
            else sda_low <= rd ? ~nack_in : 1'b0; // READ: ACK = puxa p/ 0
          end
          2'd1: scl_low <= 1'b0;
          2'd2: if (bitn < 8) sh   <= {sh[6:0], sda_i}; // amostra no meio do SCL alto
                else          nack <= sda_i;
          2'd3: begin
            scl_low <= 1'b1;
            bitn <= bitn + 1'b1;
            if (bitn == 8) begin st <= S_IDLE; done <= 1'b1; end
          end
        endcase
      end
    endcase
  end
endmodule

// BMP085
module bmp085_reader import i2c_pkg::*; #(
  parameter logic [6:0] ADDR = 7'h77,
  parameter int CLK_HZ = 100_000_000,
  parameter int I2C_HZ = 100_000
)(
  input  logic clk, rst,
  inout  wire scl, sda,
  output logic [15:0] temp_raw,
  output logic [15:0] press_raw,
  output logic data_valid,
  output logic error,
  output logic [7:0] calib [0:21],
  output logic [3:0] debug
);
  localparam int CLK_DIV = CLK_HZ / (4 * I2C_HZ);
  localparam int STARTUP_TICKS = CLK_HZ / 100; // 10 ms
  localparam int CONV_TICKS = CLK_HZ / 200;    // 5 ms
  localparam int PERIOD_TICKS = CLK_HZ / 10;   // 100 ms

  logic cmd_valid, cmd_ready, cmd_last, done, nack;
  cmd_e cmd_type;
  logic [7:0] cmd_data, rdata;

  i2c_master #(.CLK_DIV(CLK_DIV)) u_i2c (
    .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .cmd_type(cmd_type), .cmd_data(cmd_data), .cmd_last(cmd_last),
    .done(done), .rdata(rdata), .nack(nack), .scl(scl), .sda(sda)
  );

  typedef enum logic [1:0] {ST_DELAY, ST_LOAD, ST_ISSUE, ST_WAIT} fsm_e;
  typedef enum logic [2:0] {S_START, S_ADDRW, S_REG, S_VAL,
                            S_RSTART, S_ADDRR, S_READ, S_STOP} step_e;
  typedef enum logic [2:0] {JOB_ID, JOB_CALIB, JOB_TEMP_CMD,
                            JOB_TEMP_READ, JOB_PRESS_CMD, JOB_PRESS_READ} job_e;
  fsm_e fsm;
  step_e step;
  job_e job;

  logic req_wr;
  logic [7:0] req_reg, req_val;
  logic [4:0] req_n, idx;
  logic [7:0] rxbuf [0:21];
  logic [31:0] delay_count;
  logic err;

  assign error = err;
  assign debug = {nack, step};

  always_ff @(posedge clk) begin
    data_valid <= 1'b0;
    // retira valid logo que o mestre aceita o comando (evita duplicacao).
    if (cmd_valid && cmd_ready) cmd_valid <= 1'b0;

    if (rst) begin
      fsm <= ST_DELAY;
      step <= S_START;
      job <= JOB_ID;
      delay_count <= STARTUP_TICKS;
      err <= 1'b0;
      cmd_valid <= 1'b0;
      cmd_last <= 1'b0;
      cmd_type <= CMD_START;
      cmd_data <= 8'h00;
      req_wr <= 1'b0;
      req_reg <= 8'h00;
      req_val <= 8'h00;
      req_n <= 5'd0;
      idx <= 5'd0;
      temp_raw <= 16'd0;
      press_raw <= 16'd0;
    end else case (fsm)
      ST_DELAY: begin
        if (delay_count == 0) fsm <= ST_LOAD;
        else delay_count <= delay_count - 1'b1;
      end

      ST_LOAD: begin
        idx <= 5'd0;
        step <= S_START;
        fsm <= ST_ISSUE;
        if (job == JOB_ID) err <= 1'b0;
        case (job)
          JOB_ID:         begin req_wr <= 1'b0; req_reg <= 8'hD0; req_n <= 5'd1;  end
          JOB_CALIB:      begin req_wr <= 1'b0; req_reg <= 8'hAA; req_n <= 5'd22; end
          JOB_TEMP_CMD:   begin req_wr <= 1'b1; req_reg <= 8'hF4; req_val <= 8'h2E; end
          JOB_TEMP_READ:  begin req_wr <= 1'b0; req_reg <= 8'hF6; req_n <= 5'd2;  end
          JOB_PRESS_CMD:  begin req_wr <= 1'b1; req_reg <= 8'hF4; req_val <= 8'h34; end
          JOB_PRESS_READ: begin req_wr <= 1'b0; req_reg <= 8'hF6; req_n <= 5'd3;  end
          default:        begin req_wr <= 1'b0; req_reg <= 8'hD0; req_n <= 5'd1;  end
        endcase
      end

      ST_ISSUE: begin
        // Enviar comando apenas quando o mestre estiver livre.
        if (cmd_ready && !cmd_valid) begin
          cmd_valid <= 1'b1;
          cmd_last <= 1'b0;
          case (step)
            S_START, S_RSTART: cmd_type <= CMD_START;
            S_ADDRW: begin cmd_type <= CMD_WRITE; cmd_data <= {ADDR, 1'b0}; end
            S_REG:   begin cmd_type <= CMD_WRITE; cmd_data <= req_reg;      end
            S_VAL:   begin cmd_type <= CMD_WRITE; cmd_data <= req_val;      end
            S_ADDRR: begin cmd_type <= CMD_WRITE; cmd_data <= {ADDR, 1'b1}; end
            S_READ:  begin cmd_type <= CMD_READ; cmd_last <= (idx == req_n - 1'b1); end
            S_STOP:  cmd_type <= CMD_STOP;
            default: cmd_type <= CMD_STOP;
          endcase
          fsm <= ST_WAIT;
        end
      end

            ST_WAIT: if (done) begin
        if (nack && (step == S_ADDRW || step == S_REG ||
                     step == S_VAL || step == S_ADDRR)) begin
          $display("I2C NACK: job=%0d step=%0d", job, step);
          err <= 1'b1;
          step <= S_STOP;
          fsm <= ST_ISSUE;
        end else begin
          fsm <= ST_ISSUE;
          case (step)
            S_START:  step <= S_ADDRW;
            S_ADDRW:  step <= S_REG;
            S_REG:    step <= req_wr ? S_VAL : S_RSTART;
            S_VAL:    step <= S_STOP;
            S_RSTART: step <= S_ADDRR;
            S_ADDRR: step <= S_READ;
            S_READ: begin
              rxbuf[idx] <= rdata;
              if (idx == req_n - 1'b1) step <= S_STOP;
              else idx <= idx + 1'b1;
            end
            S_STOP: begin
              if (err) begin
                job <= JOB_ID;
                delay_count <= PERIOD_TICKS;
                fsm <= ST_DELAY;
              end else case (job)
                JOB_ID: begin
                  if (rxbuf[0] == 8'h55) begin
                    job <= JOB_CALIB;
                    fsm <= ST_LOAD;
                  end else begin
                    err <= 1'b1;
                    job <= JOB_ID;
                    delay_count <= PERIOD_TICKS;
                    fsm <= ST_DELAY;
                  end
                end
                JOB_CALIB: begin
                  for (int i = 0; i < 22; i++) calib[i] <= rxbuf[i];
                  job <= JOB_TEMP_CMD;
                  fsm <= ST_LOAD;
                end
                JOB_TEMP_CMD: begin
                  job <= JOB_TEMP_READ;
                  delay_count <= CONV_TICKS;
                  fsm <= ST_DELAY;
                end
                JOB_TEMP_READ: begin
                  temp_raw <= {rxbuf[0], rxbuf[1]};
                  job <= JOB_PRESS_CMD;
                  fsm <= ST_LOAD;
                end
                JOB_PRESS_CMD: begin
                  job <= JOB_PRESS_READ;
                  delay_count <= CONV_TICKS;
                  fsm <= ST_DELAY;
                end
                JOB_PRESS_READ: begin
                  // OSS=0: UP = (MSB:LSB:XLSB) >> 8.
                  press_raw <= {rxbuf[0], rxbuf[1]};
                  data_valid <= 1'b1;
                  job <= JOB_TEMP_CMD;
                  delay_count <= PERIOD_TICKS;
                  fsm <= ST_DELAY;
                end
                default: begin
                  job <= JOB_ID;
                  fsm <= ST_LOAD;
                end
              endcase
            end
            default: step <= S_STOP;
          endcase
        end
      end
      default: fsm <= ST_DELAY;
    endcase
  end
endmodule

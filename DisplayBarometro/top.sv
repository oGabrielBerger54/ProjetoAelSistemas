// Nexys A7 + BMP085
// LED0: 1 = primeira amostra completa recebida e sem erros
// LED1..LED15: sempre apagados.
module top (
  input  logic        CLK100MHZ,
  input  logic        CPU_RESETN,
  input  logic [1:0]  SW,   // SW[0]: temp/press | SW[1]: 1 = status
  //input  logic [0:0]  SW,  // Mantido para compatibilidade com o XDC; nao utilizado.
  output logic [15:0] LED,
  inout  wire         JA1,   // SDA
  inout  wire         JA2,   // SCL
  output logic        JA3,    // XCLRE
  output logic [6:0]  SEG,
  output logic        DP,
  output logic [7:0]  AN
);
  logic rst, data_valid, error, sensor_ok;
  logic [15:0] press_raw, temp_raw;
  logic [7:0] calib [0:21];
  logic [3:0] debug;

  assign rst = ~CPU_RESETN;

  bmp085_reader #(
    .ADDR(7'h77), .CLK_HZ(100_000_000), .I2C_HZ(100_000)
  ) u_baro (
    .clk(CLK100MHZ), .rst(rst), .scl(JA2), .sda(JA1),
    .press_raw(press_raw), .temp_raw(temp_raw),
    .data_valid(data_valid), .error(error), .calib(calib),
    .debug(debug)
  );

  always_ff @(posedge CLK100MHZ) begin
    if (rst || error) sensor_ok <= 1'b0;
    else if (data_valid) sensor_ok <= 1'b1;
  end

  //assign LED = {15'b0, (sensor_ok && !error && !rst)};
  // SW[1]=1: status; SW[1]=0: SW[0]=0 mostra press_raw, SW[0]=1 mostra temp_raw
  assign LED = {10'b0, debug, error, sensor_ok};

  seg7_hex8 u_seg (
    .clk(CLK100MHZ), .rst(rst),
    .value({temp_raw, press_raw}),
    .seg(SEG), .dp(DP), .an(AN)
  );
endmodule

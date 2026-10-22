//==============================================================================
// Orgnization   : Shanghai Fudan Microelectronics Co., Ltd. Confidential
// File Name     : ai7030_edif_top.v
// Author        : 
// Project       : 
// Create Date   : 
// Description   :
//------------------------------------------------------------------------------
// Modification History :
// Rev     Date         Who          Description
//==============================================================================

module ai7030_edif_top (
  // PS
  inout     [53 : 0]     FIXED_IO_0_mio            ,
  inout     [14 : 0]     DDR_0_addr                , 
  inout     [2  : 0]     DDR_0_ba                  , 
  inout                  DDR_0_cas_n               , 
  inout                  DDR_0_ck_n                , 
  inout                  DDR_0_ck_p                , 
  inout                  DDR_0_cke                 , 
  inout                  DDR_0_cs_n                , 
  inout     [3  : 0]     DDR_0_dm                  , 
  inout     [31 : 0]     DDR_0_dq                  , 
  inout     [3  : 0]     DDR_0_dqs_n               , 
  inout     [3  : 0]     DDR_0_dqs_p               , 
  inout                  DDR_0_odt                 , 
  inout                  DDR_0_ras_n               , 
  inout                  DDR_0_reset_n             , 
  inout                  DDR_0_we_n                , 
  inout                  FIXED_IO_0_ddr_vrn        , 
  inout                  FIXED_IO_0_ddr_vrp        , 
  inout                  FIXED_IO_0_ps_clk         ,
  inout                  FIXED_IO_0_ps_porb        ,
  inout                  FIXED_IO_0_ps_srstb       ,
         
  // PL DDR       
  inout     [ 63 : 0]    ddr3_dq                   ,
  inout     [  7 : 0]    ddr3_dqs_n                ,
  inout     [  7 : 0]    ddr3_dqs_p                ,
  output    [  7 : 0]    ddr3_dm                   ,
  output    [ 14 : 0]    ddr3_addr                 ,
  output    [  2 : 0]    ddr3_ba                   ,
  output                 ddr3_ras_n                ,
  output                 ddr3_cas_n                ,
  output                 ddr3_we_n                 ,
  output                 ddr3_reset_n              ,
  output    [  0 : 0]    ddr3_ck_p                 ,
  output    [  0 : 0]    ddr3_ck_n                 ,
  output    [  0 : 0]    ddr3_cke                  ,
  output    [  0 : 0]    ddr3_cs_n                 ,
  output    [  0 : 0]    ddr3_odt                  ,
       
  input                  sys_rst                   ,
  input                  sys_clk_p                 ,
  input                  sys_clk_n                 ,

  // SDI BUS
  // MGT REFCLKs

 
  output    [  1 : 0]    led                       ,

  input                  PJTAG_TCK                 ,
  input                  PJTAG_TMS                 ,
  input                  PJTAG_TDI                 ,
  output                 PJTAG_TDO                 
);

  // User CustomOp REG BUS
  wire   [ 31 : 0]  User_Reg_awwaddr        ;
  wire   [ 31 : 0]  User_Reg_awwdata        ;
  wire              User_Reg_awwvalid       ;
  wire              User_Reg_awwready       ;
  wire   [ 31 : 0]  User_Reg_araddr         ;
  wire              User_Reg_arvalid        ;
  wire              User_Reg_arready        ;
  wire   [ 31 : 0]  User_Reg_rdata          ;
  wire              User_Reg_rvalid         ;
  wire              User_Reg_rready         ;

  //User CustomOp DATA BUS
  wire   [ 31 : 0]  User_Ddr_awwaddr  ;
  wire   [511 : 0]  User_Ddr_awwdata  ;
  wire   [ 71 : 0]  User_Ddr_awwinfo  ; //{1'b0,pl_awen[63:0],pl_awinfo[5:0],pl_awlast[0]}
  wire              User_Ddr_awwvalid ;
  wire              User_Ddr_awwready ;
  wire   [ 31 : 0]  User_Ddr_araddr   ;
  wire              User_Ddr_arvalid  ;
  wire   [ 31 : 0]  User_Ddr_arinfo   ;  //{25'h0,pl_arinfo,pl_arlast}
  wire              User_Ddr_arready  ;
  wire   [511 : 0]  User_Ddr_rdata    ;
  wire              User_Ddr_rvalid   ;
  wire   [ 31 : 0]  User_Ddr_rinfo    ;  //{25'h0,pl_rinfo,pl_rlast}
  wire              User_Ddr_rready   ;
  wire              gp_clk            ;
  wire              hp_clk            ;
  wire              gp_clk_rst        ;
  wire              hp_clk_rst        ;
  // CAM


ps_ai_peripheral U0_ps_ai_peripheral(
  .FIXED_IO_0_mio         ( FIXED_IO_0_mio      ),
  .DDR_0_addr             ( DDR_0_addr          ), 
  .DDR_0_ba               ( DDR_0_ba            ), 
  .DDR_0_cas_n            ( DDR_0_cas_n         ), 
  .DDR_0_ck_n             ( DDR_0_ck_n          ), 
  .DDR_0_ck_p             ( DDR_0_ck_p          ), 
  .DDR_0_cke              ( DDR_0_cke           ), 
  .DDR_0_cs_n             ( DDR_0_cs_n          ), 
  .DDR_0_dm               ( DDR_0_dm            ), 
  .DDR_0_dq               ( DDR_0_dq            ), 
  .DDR_0_dqs_n            ( DDR_0_dqs_n         ), 
  .DDR_0_dqs_p            ( DDR_0_dqs_p         ), 
  .DDR_0_odt              ( DDR_0_odt           ), 
  .DDR_0_ras_n            ( DDR_0_ras_n         ), 
  .DDR_0_reset_n          ( DDR_0_reset_n       ), 
  .DDR_0_we_n             ( DDR_0_we_n          ), 
  .FIXED_IO_0_ddr_vrn     ( FIXED_IO_0_ddr_vrn  ), 
  .FIXED_IO_0_ddr_vrp     ( FIXED_IO_0_ddr_vrp  ), 
  .FIXED_IO_0_ps_clk      ( FIXED_IO_0_ps_clk   ),
  .FIXED_IO_0_ps_porb     ( FIXED_IO_0_ps_porb  ),
  .FIXED_IO_0_ps_srstb    ( FIXED_IO_0_ps_srstb ),

  .ddr3_dq                ( ddr3_dq            ),
  .ddr3_dqs_n             ( ddr3_dqs_n         ),
  .ddr3_dqs_p             ( ddr3_dqs_p         ),
  .ddr3_dm                ( ddr3_dm            ),
  .ddr3_addr              ( ddr3_addr          ),
  .ddr3_ba                ( ddr3_ba            ),
  .ddr3_ras_n             ( ddr3_ras_n         ),
  .ddr3_cas_n             ( ddr3_cas_n         ),
  .ddr3_we_n              ( ddr3_we_n          ),
  .ddr3_reset_n           ( ddr3_reset_n       ),
  .ddr3_ck_p              ( ddr3_ck_p          ),
  .ddr3_ck_n              ( ddr3_ck_n          ),
  .ddr3_cke               ( ddr3_cke           ),
  .ddr3_cs_n              ( ddr3_cs_n          ),
  .ddr3_odt               ( ddr3_odt           ),
       
  .sys_rst                ( sys_rst            ),
  .sys_clk_p              ( sys_clk_p          ),
  .sys_clk_n              ( sys_clk_n          ),


 
  .led                    ( led                ),  // ouput
  .PJTAG_TCK              ( PJTAG_TCK          ),
  .PJTAG_TMS              ( PJTAG_TMS          ),
  .PJTAG_TDI              ( PJTAG_TDI          ),
  .PJTAG_TDO              ( PJTAG_TDO          ),

  .gp_clk                 ( gp_clk             ),
  .hp_clk                 ( hp_clk             ),
  .gp_clk_rst             ( gp_clk_rst         ),
  .hp_clk_rst             ( hp_clk_rst         ),

  .User_Reg_awwaddr       ( User_Reg_awwaddr   ),
  .User_Reg_awwdata       ( User_Reg_awwdata   ),
  .User_Reg_awwvalid      ( User_Reg_awwvalid  ),
  .User_Reg_awwready      ( User_Reg_awwready  ),
  .User_Reg_araddr        ( User_Reg_araddr    ),
  .User_Reg_arvalid       ( User_Reg_arvalid   ),
  .User_Reg_arready       ( User_Reg_arready   ),
  .User_Reg_rdata         ( User_Reg_rdata     ),
  .User_Reg_rvalid        ( User_Reg_rvalid    ),
  .User_Reg_rready        ( User_Reg_rready    ),

  .User_Ddr_awwaddr       ( User_Ddr_awwaddr   ),
  .User_Ddr_awwdata       ( User_Ddr_awwdata   ),
  .User_Ddr_awwinfo       ( User_Ddr_awwinfo   ),  //{1'b0,pl_awen[63:0],pl_awinfo[5:0],pl_awlast[0]}
  .User_Ddr_awwvalid      ( User_Ddr_awwvalid  ),
  .User_Ddr_awwready      ( User_Ddr_awwready  ),
  .User_Ddr_araddr        ( User_Ddr_araddr    ),
  .User_Ddr_arvalid       ( User_Ddr_arvalid   ),
  .User_Ddr_arinfo        ( User_Ddr_arinfo    ),  //{25'h0,pl_arinfo,pl_arlast}
  .User_Ddr_arready       ( User_Ddr_arready   ),
  .User_Ddr_rdata         ( User_Ddr_rdata     ),
  .User_Ddr_rvalid        ( User_Ddr_rvalid    ),
  .User_Ddr_rinfo         ( User_Ddr_rinfo     ),  //{25'h0,pl_rinfo,pl_rlast}
  .User_Ddr_rready        ( User_Ddr_rready    ) 
);





assign User_Ddr_awwinfo = {1'b0, {64{1'b1}}, 6'b0, 1'b1};
assign User_Ddr_arinfo  = {25'h0, 6'b0, 1'b1};


// Ground-station registers; retired example window terminates locally.
wire [31:0] legacy_wr_addr,legacy_wr_data,legacy_rd_addr,legacy_rsp_data;
wire legacy_wr_valid,legacy_wr_ready,legacy_rd_valid,legacy_rd_ready,legacy_rsp_valid,legacy_rsp_ready;
wire [31:0] station_wr_addr,station_wr_data,station_rd_addr,station_rsp_data;
wire station_wr_valid,station_wr_ready,station_rd_valid,station_rd_ready,station_rsp_valid,station_rsp_ready;
(* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] gs_gp_release;
always @(posedge gp_clk or posedge gp_clk_rst) begin
  if(gp_clk_rst) gs_gp_release <= 2'b00;
  else gs_gp_release <= {gs_gp_release[0],1'b1};
end
gs_register_router U_gs_router(
  .clk(gp_clk),
  .rst_n(gs_gp_release[1]),
  .up_wr_addr(User_Reg_awwaddr),
  .up_wr_data(User_Reg_awwdata),
  .up_wr_valid(User_Reg_awwvalid),
  .up_wr_ready(User_Reg_awwready),
  .up_rd_addr(User_Reg_araddr),
  .up_rd_valid(User_Reg_arvalid),
  .up_rd_ready(User_Reg_arready),
  .up_rsp_data(User_Reg_rdata),
  .up_rsp_valid(User_Reg_rvalid),
  .up_rsp_ready(User_Reg_rready),
  .legacy_wr_addr(legacy_wr_addr),
  .legacy_wr_data(legacy_wr_data),
  .legacy_wr_valid(legacy_wr_valid),
  .legacy_wr_ready(legacy_wr_ready),
  .legacy_rd_addr(legacy_rd_addr),
  .legacy_rd_valid(legacy_rd_valid),
  .legacy_rd_ready(legacy_rd_ready),
  .legacy_rsp_data(legacy_rsp_data),
  .legacy_rsp_valid(legacy_rsp_valid),
  .legacy_rsp_ready(legacy_rsp_ready),
  .station_wr_addr(station_wr_addr),
  .station_wr_data(station_wr_data),
  .station_wr_valid(station_wr_valid),
  .station_wr_ready(station_wr_ready),
  .station_rd_addr(station_rd_addr),
  .station_rd_valid(station_rd_valid),
  .station_rd_ready(station_rd_ready),
  .station_rsp_data(station_rsp_data),
  .station_rsp_valid(station_rsp_valid),
  .station_rsp_ready(station_rsp_ready)
);
gs_multinode_physical #(.C_CLOCKS_PER_MS(200000),.C_WINDOW(64),.C_TIMEOUT(1000000)) U_gs_station(
 .i_ps_clk(gp_clk),.i_ps_rstn(~gp_clk_rst),.i_pl_clk(hp_clk),.i_pl_rstn(~hp_clk_rst),
 .i_wr_addr(station_wr_addr),.i_wr_data(station_wr_data),.i_wr_valid(station_wr_valid),.o_wr_ready(station_wr_ready),
 .i_rd_addr(station_rd_addr),.i_rd_valid(station_rd_valid),.o_rd_ready(station_rd_ready),
 .o_rd_data(station_rsp_data),.o_rd_valid(station_rsp_valid),.i_rd_ready(station_rsp_ready),.o_alarm_state()
);
// Retired adder window: deterministic response prevents a hanging bus read.
gs_unused_register_port U_unused_register_port(
 .clk(gp_clk),.rst_n(gs_gp_release[1]),
 .rd_valid(legacy_rd_valid),.rd_ready(legacy_rd_ready),
 .rd_data(legacy_rsp_data),.rd_data_valid(legacy_rsp_valid),
 .rd_data_ready(legacy_rsp_ready),.wr_ready(legacy_wr_ready)
);
// No custom DMA master remains. Keep the shared platform port idle.
assign User_Ddr_awwaddr = 32'd0;
assign User_Ddr_awwdata = 512'd0;
assign User_Ddr_awwvalid = 1'b0;
assign User_Ddr_araddr = 32'd0;
assign User_Ddr_arvalid = 1'b0;
assign User_Ddr_rready = 1'b1;



endmodule

`timescale 1ns/1ps
// Capture external reset, then cancel the entire backend from the PS clock domain.
module gs_backend_reset_bridge (
    input wire ps_clk, ps_rst_n, pl_rst_n,
    output wire backend_rst_n, backend_up
);
    // Async assertion stretches even a pulse received while the PS clock is stopped.
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] notice_release;
    always @(posedge ps_clk or negedge pl_rst_n) begin
        if(!pl_rst_n) notice_release<=2'b00;
        else notice_release<={notice_release[0],1'b1};
    end
    // Only this first D pin receives the asynchronously changing captured level.
    (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] notice_sync;
    always @(posedge ps_clk or negedge ps_rst_n) begin
        if(!ps_rst_n) notice_sync<=2'b00;
        else notice_sync<={notice_sync[0],notice_release[1]};
    end
    // Pair PS banks need two release edges; wait three before admitting guard traffic.
    reg [2:0] warmup;
    always @(posedge ps_clk) begin
        if(!notice_sync[1]) warmup<=3'b000;
        else warmup<={warmup[1:0],1'b1};
    end
    assign backend_rst_n=notice_sync[1];
    assign backend_up=notice_sync[1] && warmup[2];
endmodule

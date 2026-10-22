`timescale 1ns/1ps
// One outstanding bundled-data transaction. Either reset aborts entire channel.
module gs_cdc_mailbox #(parameter integer WIDTH=128, parameter integer RESET_PRE_SYNCED=0)(
 input wire src_clk,src_rst_n,
 input wire src_submit,input wire [WIDTH-1:0] src_data,
 output wire src_ready,output reg src_done,
 input wire dst_clk,dst_rst_n,
 output reg dst_valid,output reg [WIDTH-1:0] dst_data,input wire dst_ready
);
 wire src_run,dst_run;
 generate if (RESET_PRE_SYNCED == 0) begin : local_reset_release
 // Synchronize each reset source separately: no combined asynchronous sources
 // before a release synchronizer. Either source still aborts both domains.
 (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] src_release,dst_release;
 (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] src_peer_release,dst_peer_release;
 always @(posedge src_clk or negedge src_rst_n)
   if(!src_rst_n) src_release<=0; else src_release<={src_release[0],1'b1};
 always @(posedge src_clk or negedge dst_rst_n)
   if(!dst_rst_n) src_peer_release<=0; else src_peer_release<={src_peer_release[0],1'b1};
 always @(posedge dst_clk or negedge dst_rst_n)
   if(!dst_rst_n) dst_release<=0; else dst_release<={dst_release[0],1'b1};
 always @(posedge dst_clk or negedge src_rst_n)
   if(!src_rst_n) dst_peer_release<=0; else dst_peer_release<={dst_peer_release[0],1'b1};
 assign src_run=src_release[1] && src_peer_release[1];
 assign dst_run=dst_release[1] && dst_peer_release[1];
 end else begin : shared_reset_release
 // Caller guarantees each reset is locally synchronous on deassertion,
 // and either system reset asynchronously aborts both local domains.
 assign src_run=src_rst_n;
 assign dst_run=dst_rst_n;
 end endgenerate
 reg req_toggle,ack_toggle,pending;
 reg [WIDTH-1:0] payload;
 (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO" *) reg [1:0] req_sync,ack_sync;
 always @(posedge dst_clk or negedge dst_run)
   if(!dst_run) req_sync<=0;
   else req_sync<={req_sync[0],req_toggle};
 always @(posedge src_clk or negedge src_run)
   if(!src_run) ack_sync<=0;
   else ack_sync<={ack_sync[0],ack_toggle};
 // Local release falls asynchronously on either reset, and rises only on src_clk.
 // Keep the raw remote reset out of the payload acceptance enable.
 assign src_ready=src_run && !pending;
 always @(posedge src_clk or negedge src_run) begin
   if(!src_run) begin req_toggle<=0;pending<=0;payload<=0;src_done<=0; end
   else begin
     src_done<=0;
     if(src_submit && src_ready) begin
       payload<=src_data;req_toggle<=~req_toggle;pending<=1;
     end else if(pending && ack_sync[1]==req_toggle) begin
       pending<=0;src_done<=1;
     end
   end
 end
 always @(posedge dst_clk or negedge dst_run) begin
   if(!dst_run) begin ack_toggle<=0;dst_valid<=0;dst_data<=0;end
   else begin
     if(!dst_valid && req_sync[1]!=ack_toggle) begin
       // payload has been held since req launch through its two-stage synchronizer.
       dst_data<=payload;dst_valid<=1;
     end else if(dst_valid && dst_ready) begin
       dst_valid<=0;ack_toggle<=req_sync[1];
     end
   end
 end
endmodule




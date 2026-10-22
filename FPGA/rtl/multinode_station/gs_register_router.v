`timescale 1ns/1ps
// Register window router / ?????????????????????
module gs_register_router (
    input wire clk, rst_n,
    input wire [31:0] up_wr_addr, up_wr_data,
    input wire up_wr_valid,
    output wire up_wr_ready,
    input wire [31:0] up_rd_addr,
    input wire up_rd_valid,
    output wire up_rd_ready,
    output wire [31:0] up_rsp_data,
    output wire up_rsp_valid,
    input wire up_rsp_ready,
    output wire [31:0] legacy_wr_addr, legacy_wr_data,
    output wire legacy_wr_valid,
    input wire legacy_wr_ready,
    output wire [31:0] legacy_rd_addr,
    output wire legacy_rd_valid,
    input wire legacy_rd_ready,
    input wire [31:0] legacy_rsp_data,
    input wire legacy_rsp_valid,
    output wire legacy_rsp_ready,
    output wire [31:0] station_wr_addr, station_wr_data,
    output wire station_wr_valid,
    input wire station_wr_ready,
    output wire [31:0] station_rd_addr,
    output wire station_rd_valid,
    input wire station_rd_ready,
    input wire [31:0] station_rsp_data,
    input wire station_rsp_valid,
    output wire station_rsp_ready
);
    wire write_station = up_wr_addr[31:12] == 20'h400c1;
    wire read_station = up_rd_addr[31:12] == 20'h400c1;
    reg read_busy, response_station;
    assign legacy_wr_addr = up_wr_addr;
    assign legacy_wr_data = up_wr_data;
    assign station_wr_addr = {20'd0,up_wr_addr[11:0]};
    assign station_wr_data = up_wr_data;
    assign legacy_wr_valid = rst_n && up_wr_valid && !write_station;
    assign station_wr_valid = rst_n && up_wr_valid && write_station;
    assign up_wr_ready = rst_n && (write_station ? station_wr_ready : legacy_wr_ready);
    assign legacy_rd_addr = up_rd_addr;
    assign station_rd_addr = {20'd0,up_rd_addr[11:0]};
    assign legacy_rd_valid = rst_n && !read_busy && up_rd_valid && !read_station;
    assign station_rd_valid = rst_n && !read_busy && up_rd_valid && read_station;
    assign up_rd_ready = rst_n && !read_busy && (read_station ? station_rd_ready : legacy_rd_ready);
    assign up_rsp_valid = rst_n && read_busy && (response_station ? station_rsp_valid : legacy_rsp_valid);
    assign up_rsp_data = response_station ? station_rsp_data : legacy_rsp_data;
    assign legacy_rsp_ready = rst_n && read_busy && !response_station && up_rsp_ready;
    assign station_rsp_ready = rst_n && read_busy && response_station && up_rsp_ready;
    // One accepted address owns the response until its data transfer completes.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_busy <= 1'b0;
            response_station <= 1'b0;
        end else begin
            if (up_rd_valid && up_rd_ready) begin
                read_busy <= 1'b1;
                response_station <= read_station;
            end else if (up_rsp_valid && up_rsp_ready) begin
                read_busy <= 1'b0;
            end
        end
    end
endmodule

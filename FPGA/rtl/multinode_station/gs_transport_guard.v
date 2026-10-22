`timescale 1ns/1ps
// PS-domain transaction retention / PS域读事务保留，后台复位不能取消上游响应。
module gs_transport_guard (
    input wire clk,
    input wire rst,
    input wire backend_up,
    input wire [31:0] rd_addr,
    input wire rd_valid,
    output wire rd_ready,
    output wire [31:0] rd_data,
    output wire rd_data_valid,
    input wire rd_data_ready,
    input wire [31:0] wr_addr,
    input wire [31:0] wr_data,
    input wire wr_valid,
    output wire wr_ready,
    output wire [31:0] backend_rd_addr,
    output wire backend_rd_valid,
    input wire backend_rd_ready,
    input wire [31:0] backend_rd_data,
    input wire backend_rd_data_valid,
    output wire backend_rd_data_ready,
    output wire [31:0] backend_wr_addr,
    output wire [31:0] backend_wr_data,
    output wire backend_wr_valid,
    input wire backend_wr_ready
);
    localparam [1:0] IDLE=2'd0, ISSUE=2'd1, WAIT_DATA=2'd2, HOLD=2'd3;
    localparam [31:0] FAULT_DATA=32'h47534621;
    reg [1:0] state;
    reg [31:0] address_reg, response_reg, epoch_reg;
    reg previous_up, ever_up, reset_seen, overflow;
    reg read_aborted, write_dropped, bad_diag;
    wire reset_event = previous_up && !backend_up;
    wire epoch_full = epoch_reg == 32'hffffffff;
    wire next_overflow = overflow || (reset_event && epoch_full);
    wire [31:0] next_epoch = (reset_event && !epoch_full) ? epoch_reg + 32'd1 : epoch_reg;
    wire available = backend_up && !next_overflow;
    wire diag_read = rd_addr[31:6] == 26'h8;
    wire diag_write = wr_valid && (wr_addr[31:6] == 26'h8);
    wire write_fire = wr_valid && wr_ready;
    wire next_write_dropped = write_dropped || (write_fire && !diag_write && !available);
    wire next_bad_diag = bad_diag || (write_fire && diag_write);
    wire [31:0] status_value = {25'd0, next_bad_diag, next_write_dropped,
        read_aborted, next_overflow, (reset_seen || reset_event),
        (ever_up || backend_up), backend_up};

    assign rd_ready = !rst && state == IDLE;
    assign rd_data_valid = !rst && state == HOLD;
    assign rd_data = rst ? 32'd0 : response_reg;
    assign backend_rd_addr = address_reg;
    assign backend_rd_valid = !rst && state == ISSUE && available;
    assign backend_rd_data_ready = !rst && state == WAIT_DATA && available;
    assign backend_wr_addr = wr_addr;
    assign backend_wr_data = wr_data;
    assign backend_wr_valid = !rst && wr_valid && !diag_write && available;
    assign wr_ready = !rst && (diag_write || !available || backend_wr_ready);

    // Only PS reset clears this slot. backend_up is an event, not a reset pin.
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            address_reg <= 32'd0;
            response_reg <= 32'd0;
            epoch_reg <= 32'd0;
            previous_up <= 1'b0;
            ever_up <= 1'b0;
            reset_seen <= 1'b0;
            overflow <= 1'b0;
            read_aborted <= 1'b0;
            write_dropped <= 1'b0;
            bad_diag <= 1'b0;
        end else begin
            epoch_reg <= next_epoch;
            previous_up <= backend_up;
            ever_up <= ever_up || backend_up;
            reset_seen <= reset_seen || reset_event;
            overflow <= next_overflow;
            write_dropped <= next_write_dropped;
            bad_diag <= next_bad_diag;
            case (state)
                IDLE: if (rd_valid && rd_ready) begin
                    address_reg <= rd_addr;
                    if (diag_read) begin
                        state <= HOLD;
                        case (rd_addr)
                            32'h200: response_reg <= 32'h47535431;
                            32'h204: response_reg <= status_value;
                            32'h208: response_reg <= next_epoch;
                            32'h20c: response_reg <= 32'h00010001;
                            default: begin
                                response_reg <= FAULT_DATA;
                                bad_diag <= 1'b1;
                            end
                        endcase
                    end else if (!available) begin
                        state <= HOLD;
                        response_reg <= FAULT_DATA;
                        read_aborted <= 1'b1;
                    end else state <= ISSUE;
                end
                ISSUE, WAIT_DATA: begin
                    if (!available) begin
                        state <= HOLD;
                        response_reg <= FAULT_DATA;
                        read_aborted <= 1'b1;
                    end else if (state == ISSUE && backend_rd_ready) state <= WAIT_DATA;
                    else if (state == WAIT_DATA && backend_rd_data_valid) begin
                        response_reg <= backend_rd_data;
                        state <= HOLD;
                    end
                end
                HOLD: if (rd_data_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule

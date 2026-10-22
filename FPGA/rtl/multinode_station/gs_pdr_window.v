`timescale 1ns/1ps
// Count finalized packet outcomes in transmit order.
// 输入已在本时钟域完成结算；不解析网络包，不推断丢包。
module gs_pdr_window #(
    parameter integer WINDOW = 64
)(
    input wire clk,
    input wire rst,
    input wire in_valid,
    input wire received,
    output wire [8:0] count,
    output wire [8:0] delivered,
    output wire [8:0] lost,
    output wire result_valid,
    output wire window_full
);
    localparam [8:0] LAST_FILL = WINDOW - 1;
    generate
        if (WINDOW < 1 || WINDOW > 256) begin : invalid_window
            ERROR_WINDOW_MUST_BE_IN_RANGE_ONE_TO_256 invalid_configuration();
        end
    endgenerate

    // 最老结果固定在最高位，避免动态读地址的宽多路选择器。
    reg [WINDOW-1:0] history;
    reg [8:0] count_o;
    reg [8:0] delivered_o;
    reg full_o;
    reg valid_o;
    wire departing;
    assign departing = full_o & history[WINDOW-1];
    assign count = count_o;
    assign delivered = delivered_o;
    assign lost = count_o - delivered_o;
    assign result_valid = valid_o;
    assign window_full = full_o;

    // 同步复位优先，空拍保持；移位写法也覆盖WINDOW=1。
    always @(posedge clk) begin
        if (rst) begin
            history <= {WINDOW{1'b0}};
            count_o <= 9'd0;
            delivered_o <= 9'd0;
            full_o <= 1'b0;
            valid_o <= 1'b0;
        end else if (in_valid) begin
            history <= (history << 1);
            history[0] <= received;
            valid_o <= 1'b1;
            if (!full_o) begin
                count_o <= count_o + 9'd1;
                full_o <= (count_o == LAST_FILL);
            end
            // 同时移出/移入相同结果时计数不变，避免串联加减器。
            case ({received, departing})
                2'b10: delivered_o <= delivered_o + 9'd1;
                2'b01: delivered_o <= delivered_o - 9'd1;
                default: delivered_o <= delivered_o;
            endcase
        end
    end
endmodule

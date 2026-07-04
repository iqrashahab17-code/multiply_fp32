`timescale 1ns / 1ps

module fmultiplier(
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,      // 1-cycle start pulse
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] z,
    output reg         out_valid   // 1-cycle pulse when z is updated
);

    // FSM control
    reg [2:0] counter;
    reg       busy;

    reg [31:0] a_r, b_r;

    // internal regs
    reg [23:0] a_m, b_m, z_m;
    reg  [9:0] a_e, b_e, z_e;
    reg        a_s, b_s, z_s;

    reg [49:0] product;

    reg guard_bit, round_bit, sticky;

    reg        special_case;
    reg [31:0] special_z;

    wire [7:0]   expA = a_r[30:23];
    wire [7:0]   expB = b_r[30:23];
    wire [22:0]  manA = a_r[22:0];
    wire [22:0]  manB = b_r[22:0];

    wire a_is_nan  = (expA == 8'hFF) && (manA != 0);
    wire b_is_nan  = (expB == 8'hFF) && (manB != 0);
    wire a_is_inf  = (expA == 8'hFF) && (manA == 0);
    wire b_is_inf  = (expB == 8'hFF) && (manB == 0);
    wire a_is_zero = (expA == 8'h00) && (manA == 0);
    wire b_is_zero = (expB == 8'h00) && (manB == 0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            counter      <= 3'd0;
            busy         <= 1'b0;
            out_valid    <= 1'b0;

            a_r          <= 32'd0;
            b_r          <= 32'd0;

            a_m          <= 24'd0;
            b_m          <= 24'd0;
            z_m          <= 24'd0;

            a_e          <= 10'd0;
            b_e          <= 10'd0;
            z_e          <= 10'd0;

            a_s          <= 1'b0;
            b_s          <= 1'b0;
            z_s          <= 1'b0;

            product      <= 50'd0;

            guard_bit    <= 1'b0;
            round_bit    <= 1'b0;
            sticky       <= 1'b0;

            special_case <= 1'b0;
            special_z    <= 32'd0;

            z            <= 32'd0;
        end else begin
            out_valid <= 1'b0; // default

            // Start logic
            if (!busy) begin
                counter <= 3'd0;
                if (valid) begin
                    busy         <= 1'b1;
                    counter      <= 3'd1;

                    a_r          <= a;
                    b_r          <= b;

                    special_case <= 1'b0;
                    special_z    <= 32'd0;

                    product      <= 50'd0;
                    guard_bit    <= 1'b0;
                    round_bit    <= 1'b0;
                    sticky       <= 1'b0;
                end
            end else begin
                case (counter)

                    // Stage 1: unpack
                    3'd1: begin
                        a_m <= {1'b0, a_r[22:0]};
                        b_m <= {1'b0, b_r[22:0]};

                        a_e <= {2'b00, a_r[30:23]} - 10'd127;
                        b_e <= {2'b00, b_r[30:23]} - 10'd127;

                        a_s <= a_r[31];
                        b_s <= b_r[31];

                        counter <= 3'd2;
                    end

                    // Stage 2: specials + denorm setup
                    3'd2: begin
                        if (a_is_nan || b_is_nan) begin
                            special_case <= 1'b1;
                            special_z    <= 32'h7FC0_0000;
                        end else if (a_is_inf) begin
                            if (b_is_zero) begin
                                special_case <= 1'b1;
                                special_z    <= 32'h7FC0_0000;
                            end else begin
                                special_case <= 1'b1;
                                special_z    <= { (a_s ^ b_s), 8'hFF, 23'd0 };
                            end
                        end else if (b_is_inf) begin
                            if (a_is_zero) begin
                                special_case <= 1'b1;
                                special_z    <= 32'h7FC0_0000;
                            end else begin
                                special_case <= 1'b1;
                                special_z    <= { (a_s ^ b_s), 8'hFF, 23'd0 };
                            end
                        end else if (a_is_zero || b_is_zero) begin
                            special_case <= 1'b1;
                            special_z    <= { (a_s ^ b_s), 8'd0, 23'd0 };
                        end else begin
                            if (expA == 8'h00) begin
                                a_e <= -10'sd126;
                            end else begin
                                a_m[23] <= 1'b1;
                            end

                            if (expB == 8'h00) begin
                                b_e <= -10'sd126;
                            end else begin
                                b_m[23] <= 1'b1;
                            end
                        end

                        counter <= 3'd3;
                    end

                    // Stage 3: normalize inputs
                    3'd3: begin
                        if (!special_case) begin
                            if (!a_m[23]) begin
                                a_m <= a_m << 1;
                                a_e <= a_e - 10'sd1;
                            end
                            if (!b_m[23]) begin
                                b_m <= b_m << 1;
                                b_e <= b_e - 10'sd1;
                            end
                        end
                        counter <= 3'd4;
                    end

                    // Stage 4: sign/exponent/product
                    3'd4: begin
                        if (!special_case) begin
                            z_s     <= a_s ^ b_s;
                            z_e     <= a_e + b_e + 10'sd1;
                            product <= a_m * b_m * 50'd4;
                        end
                        counter <= 3'd5;
                    end

                    // Stage 5: extract mantissa + GRs
                    3'd5: begin
                        if (!special_case) begin
                            z_m       <= product[49:26];
                            guard_bit <= product[25];
                            round_bit <= product[24];
                            sticky    <= (product[23:0] != 0);
                        end
                        counter <= 3'd6;
                    end

                    // Stage 6: normalize/round
                    3'd6: begin
                        if (!special_case) begin
                            reg [23:0] zm_tmp;
                            reg  [9:0] ze_tmp;
                            reg        g_tmp, r_tmp, s_tmp;
                            reg [24:0] inc;
                            integer    sh, k;
                            reg        lost_any;

                            zm_tmp = z_m;
                            ze_tmp = z_e;
                            g_tmp  = guard_bit;
                            r_tmp  = round_bit;
                            s_tmp  = sticky;

                            // Underflow shift to exponent -126
                            if ($signed(ze_tmp) < -126) begin
                                sh = (-126 - $signed(ze_tmp));
                                lost_any = 1'b0;

                                // any bits shifted out from zm_tmp contribute to sticky
                                if (sh > 0) begin
                                    if (sh >= 24) begin
                                        // everything shifts out
                                        if (zm_tmp != 0) lost_any = 1'b1;
                                        zm_tmp = 24'd0;
                                    end else begin
                                        // loop over bits [0 .. sh-1]
                                        for (k = 0; k < 24; k = k + 1) begin
                                            if (k < sh) begin
                                                if (zm_tmp[k]) lost_any = 1'b1;
                                            end
                                        end
                                        zm_tmp = zm_tmp >> sh;
                                    end

                                    // previous guard/round also become sticky when we shift hard
                                    if (g_tmp) lost_any = 1'b1;
                                    if (r_tmp) lost_any = 1'b1;

                                    s_tmp = s_tmp | lost_any;

                                    ze_tmp = -10'sd126;
                                    g_tmp  = 1'b0;
                                    r_tmp  = 1'b0;
                                end
                            end
                            // Normalize if MSB not set
                            else if (zm_tmp[23] == 1'b0) begin
                                ze_tmp = ze_tmp - 10'sd1;
                                zm_tmp = {zm_tmp[22:0], g_tmp};
                                g_tmp  = r_tmp;
                                r_tmp  = 1'b0;
                            end

                            // RNE
                            if (g_tmp && (r_tmp | s_tmp | zm_tmp[0])) begin
                                inc = {1'b0, zm_tmp} + 25'd1;
                                if (inc[24]) begin
                                    zm_tmp = 24'h800000;
                                    ze_tmp = ze_tmp + 10'sd1;
                                end else begin
                                    zm_tmp = inc[23:0];
                                end
                            end

                            z_m       <= zm_tmp;
                            z_e       <= ze_tmp;
                            guard_bit <= g_tmp;
                            round_bit <= r_tmp;
                            sticky    <= s_tmp;
                        end
                        counter <= 3'd7;
                    end

                    // Stage 7: pack
                    3'd7: begin
                        if (special_case) begin
                            z <= special_z;
                        end else begin
                            z[31]    <= z_s;
                            z[30:23] <= z_e[7:0] + 8'd127;
                            z[22:0]  <= z_m[22:0];

                            if (($signed(z_e) == -126) && (z_m[23] == 1'b0))
                                z[30:23] <= 8'd0;

                            if ($signed(z_e) > 127) begin
                                z[31]    <= z_s;
                                z[30:23] <= 8'hFF;
                                z[22:0]  <= 23'd0;
                            end
                        end

                        busy      <= 1'b0;
                        out_valid <= 1'b1;
                        counter   <= 3'd0;
                    end

                    default: begin
                        busy    <= 1'b0;
                        counter <= 3'd0;
                    end
                endcase
            end
        end
    end

endmodule
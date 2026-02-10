`timescale 1ns / 1ps

module fpmult #(parameter int P = 8, parameter int Q = 8) (
    input  logic rst_in_N,           // synchronous active-low reset
    input  logic clk_in,             // clock
    input  logic [P+Q-1:0] x_in,     // input X; x_in[P+Q-1] is the sign bit
    input  logic [P+Q-1:0] y_in,     // input Y: y_in[P+Q-1] is the sign bit
    input  logic [1:0] round_in,     // rounding mode specifier
    input  logic start_in,           // signal to start multiplication
    output logic [P+Q-1:0] p_out,    // output P: p_out[P+Q-1] is the sign bit
    output logic [3:0] oor_out,      // out-of-range indicator vector
    output logic valid_out,          // the outputs are valid
    output logic ready_out           // the FPM is ready to receive new inputs
);

// Input handling -> (multcontrol->fracmult) & (exponent handler / adder)
logic[P+Q:0] x_fix;
logic[P+Q:0] y_fix;

// Exponent adding -> x-exp + y-exp - (127 for 8 bit exponent width)
logic [8:0] exponent;
logic [7:0] fix_exp;
logic x_hidden;
logic y_hidden;

// Sign handling -> x-sign ^ y-sign
logic sign;

// Round mode
logic[1:0] round_reg;

logic [15:0] product;
logic [15:0] fix_prod;

logic [3:0] oor_found;
logic done;
logic adx;

multcontrol mc (
    .a(x_fix[15:8]),
    .b(y_fix[15:8]),
    .clk_in(clk_in),
    .rst_n(rst_in_N),
    .adx(adx),
    .p(product),
    .mdone(done),
    .ready(ready_out)
);

oor_input oor (
    .x(x_in),
    .y(y_in),
    .clk_in(clk_in),
    .start_in(start_in),
    .new_prod(fix_prod),
    .oor_found(oor_found)
);


logic [1:0] inc_exp;
logic [6:0] mantissa_out;
round rd(
    .round_in(round_reg),
    .sign(sign),
    .acc_reg(product),
    .mantissa_out(mantissa_out),
    .inc_exp(inc_exp)
);


// Output assembling {sign, exponent, fraction};
always @(posedge clk_in) begin
    if (!rst_in_N) begin
        x_fix <= 0;
        y_fix <= 0;
        exponent <= 0;
        sign <= 0;
        adx <= 0;
        valid_out <= 0;
        round_reg <= 0;
    end
    else begin
        if (start_in) begin
            // All 0 exponent value signifies leading bit == 0.
            x_hidden = (x_in[14:7] != 0);
            y_hidden = (y_in[14:7] != 0);
            x_fix <= {x_in[P+Q-1], {x_hidden, x_in[6:0]}, x_in[14:7]};
            y_fix <= {y_in[P+Q-1], {y_hidden, y_in[6:0]}, y_in[14:7]};
            exponent <= x_in[14:7] + y_in[14:7];
            sign <= x_in[P+Q-1] ^ y_in[P+Q-1];
            round_reg <= round_in;
            adx <= 1;
            valid_out <= 0;
        end
        else if (done) begin
            // might have to wait to do this part until we round?
            // have done flag sent to rounding / normalization module
            // that module does the rounding and returns a different flag when done
            // come back and potentially normalize again based on input?
            // also have some code that adjusts for 0 input. Potentially in rounding?
            if (oor_found != '0) begin
                p_out <= fix_prod;
                oor_out <= oor_found;
                valid_out <= 1;
                adx <= 0;
            end else begin
                logic [9:0] tmp_exp;
                tmp_exp = {1'b0, exponent} + {8'b00000000, inc_exp};
                if (tmp_exp > 381) begin
                    fix_exp = '1;
                end else if (tmp_exp < 127) begin
                    fix_exp = '0;
                end else begin
                    fix_exp = tmp_exp[7:0] - 127;
                end
                /*
                if (product[15]) begin
                    fix_exp += 1;
                    p_out <= {sign, fix_exp, product[14:8]};
                end
                else begin
                    p_out <= {sign, fix_exp, product[13:7]};
                end
                */
                p_out <= {sign, fix_exp, mantissa_out};
                if (product == '0) begin
                    if (fix_exp == '0) begin
                        oor_out[3] <= 1;
                    end else if (fix_exp == '1) begin
                        oor_out[2] <= 1;
                    end
                end else begin
                    if (fix_exp == '1) begin
                        oor_out[1] <= 1;
                    end else if (fix_exp == '0) begin
                        oor_out[0] <= 1;
                    end
                end
                valid_out <= 1;
                adx <= 0;
            end
        end
    end
end
endmodule

// @TODO - add rounding module that also handles first normalization and perhaps shifting based on normal vs. subnormal

module oor_input (
    input  logic [15:0] x,
    input  logic [15:0] y,
    input  logic        clk_in,
    input  logic        start_in,
    output logic [15:0] new_prod,
    output logic [3:0]  oor_found
);

    logic [7:0] x_exp;
    logic [7:0] y_exp;

    logic [6:0] x_frac;
    logic [6:0] y_frac;

    logic       x_sign;
    logic       y_sign;
    logic       sign;

    logic x_nan;
    logic y_nan;
    logic x_inf;
    logic y_inf; 
    logic x_zero;
    logic y_zero;

    logic in_latched;

    assign x_nan = ((x_exp == '1) && (x_frac != '0));
    assign y_nan = ((y_exp == '1) && (y_frac != '0));
    assign x_inf = ((x_exp == '1) && (x_frac == '0));
    assign y_inf = ((y_exp == '1) && (y_frac == '0));
    assign x_zero = ((x_exp == '0) && (x_frac == '0));
    assign y_zero = ((y_exp == '0) && (y_frac == '0));

    assign sign = x_sign ^ y_sign;

    always @(posedge clk_in) begin
        if (start_in) begin
            x_frac <= x[6:0];
            x_exp <= x[14:7];
            y_frac <= y[6:0];
            y_exp <= y[14:7];
            x_sign <= x[15];
            y_sign <= y[15];
            in_latched <= 1;
        end
        if (in_latched) begin
            if (x_nan || y_nan) begin
                new_prod <= {1'b0, 8'hFF, 7'b1};
                oor_found[1] <= 1;
            end else if (x_inf || y_inf) begin
                new_prod <= {sign, 8'hFF, 7'b0};
                oor_found[2] <= 1;
            end else if (x_zero || y_zero) begin
                new_prod <= {sign, 8'h00, 7'b0};
                oor_found[3] <= 1;
            end else begin
                oor_found <= 0;
            end
        end
    end
endmodule


module multcontrol (
    input  logic [7:0]  a,              // Multiplier
    input  logic [7:0]  b,              // Multiplicand
    input  logic clk_in,                // Clock
    input  logic rst_n,                 // Reset-low signal (INITIAL STATE)
    input  logic adx,                   // Start mult flag 
    output logic [15:0] p,              // Product
    output logic mdone,                 // Mult complete flag
    output logic ready                  // Ready to receive new input
);

// state == 0: IDLE/Waiting
// state == 1: LOAD/Initializing
// state == 2: Computing/Working
logic[1:0] state;

// Flag to load registers in fracmult module
logic load;

// Flag to begin computation
logic computing;

fracmult fm (
    .a(a),
    .b(b),
    .clk_in(clk_in),
    .load(load),
    .computing(computing),
    .rst_n(rst_n),
    .p(p),
    .done(mdone)
);

// Loop call fracmult module
always @(posedge clk_in) begin
    // $display(" MULT-CONTROL ADX UPDATE: %b", adx);
    if (!rst_n) begin
        // $display("RESETTING");
        state <= 0;
        load <= 0;
        computing <= 0;
        ready <= 1;
    end
    else begin
        case (state)
            0: begin // IDLE
                // $display("IDLE");
                ready <= 1;
                if (adx) begin
                    // $display("BEGIN LOAD");
                    load <= 1;
                    state <= 1;
                end
            end
            1: begin // LOAD
                // $display("LOAD");
                ready <= 0;
                load <= 0;
                computing <= 1;
                state <= 2;
            end
            2: begin // COMPUTATION
                // $display("COMPUTING");
                if (mdone) begin
                    // $display("COMPLETE");
                    computing <= 0;
                    state <= 0;
                end
            end
        endcase
    end
end

endmodule

// Module responsible for shift-add multiplication
module fracmult (
    input  logic [7:0]  a,              // Multiplier
    input  logic [7:0]  b,              // Multiplicand
    input  logic clk_in,                // Clock
    input  logic load,                  // Start signal (LOAD)
    input  logic computing,             // Computing product flag
    input  logic rst_n,                 // Reset-low signal (INITIAL STATE)
    output logic [15:0] p,              // Product
    output logic done                   // Done w/ Multiplication flag 
);

logic [7:0] b_reg;
logic [16:0] acc_reg;
integer counter;

assign p = acc_reg[15:0];

always @(posedge clk_in) begin
    if (load) begin
        counter <= 8;
        b_reg <= b;
        acc_reg <= {9'b0, a};
        done <= 0;
    end
    else if (computing && !done) begin
        // $display("here: %d", done);
        logic [16:0] next_acc;
        next_acc = acc_reg;

        if (acc_reg[0]) begin
            next_acc = acc_reg + {1'b0, b_reg, 8'b0};
        end
        acc_reg <= next_acc >> 1;
        counter <= counter - 1;
        done <= (counter == 1);
    end
    else if (done) begin
        done <= 0;
    end
end 

endmodule


module round (
    input   logic [1:0] round_in,     // rounding mode specifier
    input   logic sign,
    input   logic [15:0] acc_reg,
    output  logic [6:0] mantissa_out,
    output  logic [1:0] inc_exp
);
    // relevant wires for future computation
        logic signbar;
        not(signbar, sign);

        logic [1:0] round_in_bar;
        assign round_in_bar = ~round_in;

        logic r;
        logic g;
        logic s;
        assign r = acc_reg[7];
        assign g = acc_reg[6];
        or(s, acc_reg[0],
                acc_reg[1],
                acc_reg[2],
                acc_reg[3],
                acc_reg[4],
                acc_reg[5]);

        logic adv, advbar;
        assign adv = acc_reg[15];
        not(advbar, adv);

        logic _tmp0, _tmp1;
        logic nonzerotrail;
        or(_tmp0, g, s);
        and(_tmp1, adv, r);
        or(nonzerotrail, _tmp0, _tmp1);

    // first renormalize

        // @NOTE: we can probably get away with only storing the most significant P bits in sh.
        // shift acc_reg left by 1 bit (if needed) so that there is a 1 in sh[15]
        logic [15:0] sh;
        and(sh[0], adv, acc_reg[0]); // index 0 of sh is only 1 if it is so in acc_reg and acc_reg is not advanced
        generate
            for (genvar i = 1; i < 16; i++) begin
                logic tmp0, tmp1;
                and(tmp0, adv, acc_reg[i]);
                and(tmp1, advbar, acc_reg[i-1]);
                or(sh[i], tmp0, tmp1);
            end
        endgenerate


    
    // next we create circuit for rup signal which determines if we round up the mantissa
        logic rup;
        // RTN/E
            /*
                if (adv) {
                    round up on r & ( g | s | tiebreak )
                }
                else {
                    round up on g & ( s | tiebreak )
                }
            */
            logic rup_and_RTNE;
            logic tiebreak;
            assign tiebreak = sh[8]; // round to even
            logic advrd; // whether we round in case of adv
            logic nadvrd; // whether we round in case of NOT adv
            logic s_tie;
            or(s_tie, s, tiebreak);
            logic tmp;
            or(tmp, g, s_tie);
            and(advrd, r, tmp, adv);
            and(nadvrd, g, s_tie, advbar);
            logic rupRTNE;  // round up (in case of RTN/E)
            or(rupRTNE, advrd, nadvrd);
            and(rup_and_RTNE, rupRTNE, round_in_bar[1], round_in_bar[0]);
        // RTZ
            // no contribution to this circuit
        // RD
            logic rup_and_RD;
            and(rup_and_RD, nonzerotrail, sign, round_in[1], round_in_bar[0]);
        // RU
            logic rup_and_RU;
            and(rup_and_RU, nonzerotrail, signbar, round_in[1], round_in[0]);

        // final gate for rup signal
            or(rup, rup_and_RTNE, rup_and_RD, rup_and_RU);

    // round + final renormalize
        logic [8:0] rdd; // full mantissa in case of round up
        assign rdd = {1'b0, sh[15:8]} + 1;

        logic [8:0] bm;
        assign bm = rup ? rdd : {1'b0, sh[15:8]};

        logic nxtadv;
        assign nxtadv = bm[8];

        assign inc_exp = {1'b0, adv} + {1'b0, nxtadv};

        generate
            for (genvar i = 0; i < 7; i++) begin
                mux2 mx(bm[i+1], bm[i], nxtadv, mantissa_out[i]);
            end
        endgenerate

endmodule


// s ? a : b
module mux2 (
    input a,
    input b,
    input s,
  /* verilator lint_off UNOPTFLAT */
    output y
  /* verilator lint_on UNOPTFLAT */
);
  logic t_1, t_2, s_bar;
  and (t_1, a, s);
  and (t_2, b, s_bar);
  not (s_bar, s);
  or (y, t_1, t_2);
endmodule : mux2

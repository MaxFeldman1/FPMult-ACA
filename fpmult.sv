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
logic[7:0] exponent;

// Sign handling -> x-sign ^ y-sign
logic sign;

// Round mode
logic[1:0] round_reg;

logic[15:0] product;
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


logic [1:0] inc_exp;
logic [6:0] mantissa_out;
/*
logic adv, advbar, advrd, nadvrd, rup;
logic [8:0] rdd, bm;
*/

round rd(
    .round_in(round_reg),
    .sign(sign),
    .acc_reg(product),
    .mantissa_out(mantissa_out),
    .inc_exp(inc_exp)
/*
    .adv(adv),
    .advbar(advbar),
    .advrd(advrd),
    .nadvrd(nadvrd),
    .rdd(rdd),
    .bm(bm)
*/
);

// Output assembling {sign, exponent, fraction};
always @(edge clk_in) begin
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
            x_fix <= {x_in[P+Q-1], {1'b1, x_in[6:0]}, x_in[14:7]};
            y_fix <= {y_in[P+Q-1], {1'b1, y_in[6:0]}, y_in[14:7]};
            exponent <= x_in[14:7] + y_in[14:7] - 127;
            sign <= x_in[P+Q-1] ^ y_in[P+Q-1];
            round_reg <= round_in;
            adx <= 1;
            valid_out <= 0;
        end
        else if (done) begin
            // @TODO we can check for exponent overflow by using increasing capacity and checking top bit
            logic [8:0] tmp_exp;
            // $display("adv advbar advrd nadvrd rup %b %b %b %b %b, \t rdd %b %b %b", adv, advbar, advrd, nadvrd, rup, rdd, bm, mantissa_out);
            // $display("round_reg rup sh %b %b %b:%b", round_reg, rup, sh[15:8], sh[7:0]);
            tmp_exp = {1'b0, exponent} + {7'b0000000, inc_exp};
            p_out <= {sign, tmp_exp[7:0], mantissa_out};

            oor_out <= 0;
            valid_out <= 1;
            adx <= 0;
        end
    end
end
endmodule

// @TODO - add rounding module that also handles first normalization and perhaps shifting based on normal vs. subnormal


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

        next_acc = acc_reg[0] ? acc_reg + {1'b0, b_reg, 8'b0} : acc_reg;
        acc_reg <= next_acc >> 1;
        counter <= counter - 1;
        done <= (counter == 1);
    end
    else if (done) begin
        done <= 0;
    end
end 

endmodule

// for now we do RTN/E
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

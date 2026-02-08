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

// Output assembling {sign, exponent, fraction};
always @(edge clk_in) begin
    if (start_in) begin
        // $display("START_IN %d %d %d", x_in[14:7], y_in[14:7], x_in[14:7] + y_in[14:7] -2 * 127);
        $display("START_IN - SET");
        x_fix <= {x_in[P+Q-1], {1'b1, x_in[6:0]}, x_in[14:7]};
        y_fix <= {y_in[P+Q-1], {1'b1, y_in[6:0]}, y_in[14:7]};
        exponent <= x_in[14:7] + y_in[14:7] - 127;
        sign <= x_in[P+Q-1] ^ y_in[P+Q-1];
        adx <= 1;
        valid_out <= 0;
    end
    if (done) begin 
        //$display("EXPONENT CHECK, %d", exponent-127);
        if (product[15]) begin
             // @TODO check exponent overflow
            logic[7:0] tmp_exp;
            tmp_exp = exponent + 1;
            p_out <= {sign, tmp_exp, product[14:8]};
        end
        else begin
            p_out <= {sign, exponent, product[13:7]};
        end
        // $display("OUTPUT (non-truncated): 0b%b, OUTPUT (truncated): 0b%b", product, product[14:8]);
        oor_out <= 0;
        valid_out <= 1;
        adx <= 0;
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
    $display(" MULT-CONTROL ADX: %b", adx);
    case (state)
        0: begin // IDLE
            ready <= 1;
            if (adx) begin
                load <= 1;
                state <= 1;
            end
        end
        1: begin // LOAD
            ready <= 0;
            load <= 0;
            computing <= 1;
            state <= 2;
        end
        2: begin // COMPUTATION
            if (mdone) begin
                computing <= 0;
                state <= 0;
            end
        end
    endcase
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
    // $display("---- CLK_IN %b, %b", rst_n, load);
    if (load) begin
        counter <= 8;
        b_reg <= b;
        acc_reg <= {9'b0, a};
        done <= 0;
        // $display("ld here: %d", done);
    end
    else if (computing & !done) begin
        // $display("here: %d", done);
        if (acc_reg[0]) begin
            acc_reg <= {1'b0, acc_reg[16:8] + b_reg, acc_reg[7:1]}; 
        end
        else begin
            acc_reg <= acc_reg >> 1;
        end
        done <= (counter == 1);
        counter <= counter - 1;
        // $display("AFTER STEP: acc_reg: 0b%b, b_reg: 0b%b", acc_reg, b_reg);
    end
end 

endmodule
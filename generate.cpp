#include <iostream>
#include <iomanip>
#include <stdfloat>
#include <random>
#include <bit>
#include <cmath>
#include <cfenv> // For floating-point environment

using bf16 = std::bfloat16_t;

uint16_t to_hex(bf16 value) {
    return std::bit_cast<uint16_t>(value);
}

// Function to calculate result based on rounding mode
bf16 calculate_result(bf16 a, bf16 b, int mode_val) {
    float fa = static_cast<float>(a);
    float fb = static_cast<float>(b);
    
    switch(mode_val) {
        case 0b01: std::fesetround(FE_TOWARDZERO); break; // RTZ
        case 0b10: std::fesetround(FE_DOWNWARD);   break; // RD
        case 0b11: std::fesetround(FE_UPWARD);     break; // RU
        case 0b00: 
        default:   std::fesetround(FE_TONEAREST);  break; // RNE
    }
    
    return static_cast<bf16>(fa * fb);
}

int main() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint16_t> dis(0x0000, 0xFFFF);
    // Distribution for rounding modes 0-3
    std::uniform_int_distribution<int> mode_dis(0, 3);

    for (int i = 0; i < 40; ++i) {
        bf16 a = std::bit_cast<bf16>(dis(gen));
        bf16 b = std::bit_cast<bf16>(dis(gen));
        int mode_val = mode_dis(gen); // Randomly pick 00, 01, 10, or 11

        bf16 result = calculate_result(a, b, mode_val);

        // --- Calculate Flags (OOR) ---
        uint8_t oor = 0;
        float res_f = static_cast<float>(result);
        
        if (res_f == 0.0f)           oor |= (1 << 3); // Zero flag
        if (std::isinf(res_f))       oor |= (1 << 2); // Infinity flag
        if (std::isnan(res_f))       oor |= (1 << 1); // NaN flag
        
        // Subnormal check for bfloat16 (Smallest normal is 2^-126)
        if (res_f != 0.0f && std::abs(res_f) < 1.17549435e-38f) {
            oor |= (1 << 0); 
        }

        // --- Pack the Line (54 bits) ---
        // [53:52] round_mode | [51:36] a | [35:20] b | [19:4] res | [3:0] oor
        uint64_t packed_line = 0;
        packed_line |= (static_cast<uint64_t>(mode_val) << 52);
        packed_line |= (static_cast<uint64_t>(to_hex(a)) << 36);
        packed_line |= (static_cast<uint64_t>(to_hex(b)) << 20);
        packed_line |= (static_cast<uint64_t>(to_hex(result)) << 4);
        packed_line |= (static_cast<uint64_t>(oor) & 0xF);

        // Print 14 hex digits (covers 54 bits)
        std::cout << std::hex << std::setfill('0') << std::setw(14) << packed_line << std::endl;
    }

    return 0;
}